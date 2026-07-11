// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Microcode-poll interrupt: the fetch mainloop polls between retires and enters
// irq_proc when an interrupt is pending. Entry acks the latch and sets CCR.I;
// an IRQ raised inside the handler waits for its RTE even with CCR.I clear.
`timescale 1ns / 1ps
module tb_core_irq;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  integer     i, handler_count, fails;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [8:0] IRQ_PROC = 9'h130;   // FetchEntry(0x100) + 0x30

  wire [15:0] pc = dut.intrf.dbgPc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                      <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  initial clock = 0;
  always #5 clock = ~clock;

  always @(posedge clock)
    if (!reset && dut.useq.upc == IRQ_PROC) handler_count = handler_count + 1;

  task check(input cond, input [255:0] tag);
    if (!cond) begin
      fails = fails + 1;
      $display("CORE-IRQ FAIL: %0s count=%0d iflag=%b pc=%h",
               tag, handler_count, dut.ccr.iFlag, pc);
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP
    // platform vector table: SP, entry PC, IRQ0
    mem[16'h0002] = 8'h02; mem[16'h0003] = 8'h00;  // reset SP = 0x0200
    mem[16'h0006] = 8'h00; mem[16'h0007] = 8'h30;  // reset PC = 0x0030
    mem[16'h0018] = 8'h00; mem[16'h0019] = 8'h80;  // IRQ0     = 0x0080
    // main at 0x30: unmask irq (reset holds I set), then halt loop
    mem[16'h0030] = 8'h06; mem[16'h0031] = 8'h7f;  // andc #0x7f, ccr
    mem[16'h0032] = 8'h40; mem[16'h0033] = 8'hfe;  // bra -2
    // handler at 0x80: clear I, nop sled, rte
    mem[16'h0080] = 8'h06; mem[16'h0081] = 8'h7f;  // andc #0x7f, ccr
    mem[16'h008e] = 8'h56; mem[16'h008f] = 8'h70;  // rte
    handler_count = 0; fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (40) @(posedge clock); #1;
    check(handler_count == 0 && dut.ccr.iFlag === 1'b0,
          "boot: andc unmasked, no entry");
    // first IRQ: handler entered once, entry sets I
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    wait (bus_req && !bus_we && bus_addr == 16'h0080); #1;
    check(handler_count == 1 && dut.ccr.iFlag === 1'b1, "entry: taken once, I set");
    // second IRQ inside the handler: blocked by irqActive even after andc
    wait (bus_req && !bus_we && bus_addr == 16'h0086); #1;
    check(dut.ccr.iFlag === 1'b0, "handler: andc cleared I");
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    repeat (2) @(posedge clock); #1;
    check(handler_count == 1, "nested: held until rte");
    // after RTE the pending IRQ is taken, then the core returns to the loop
    repeat (80) @(posedge clock); #1;
    check(handler_count == 2, "pending: taken after rte");
    check(dut.ccr.iFlag === 1'b0 && pc >= 16'h0032 && pc <= 16'h0035,
          "resume: I restored, halted in main");
    if (fails == 0)
      $display("CORE-IRQ PASS: entry once, irqActive holds nested irq, rte releases");
    $finish;
  end
endmodule
