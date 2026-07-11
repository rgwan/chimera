// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// SLEEP holds the microcode wait loop with no bus traffic until a wake event,
// then retires so the exception frame carries the next instruction address.
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_sleep;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  integer     i, irq_count, nmi_count, req_count, errors;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [8:0] IRQ_PROC = 9'h130;   // FetchEntry(0x100) + 0x30
  localparam [8:0] NMI_PROC = 9'h1ab;   // FetchEntry(0x100) + 0xab

  wire [15:0] r0 = dut.h8rf.dbg[15:0];
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

  always @(posedge clock) if (!reset) begin
    if (dut.useq.upc == IRQ_PROC) irq_count = irq_count + 1;
    if (dut.useq.upc == NMI_PROC) nmi_count = nmi_count + 1;
    if (bus_req) req_count = req_count + 1;
  end

  task check(input cond, input [127:0] tag);
    if (!cond) begin
      errors = errors + 1;
      $display("CORE-SLEEP FAIL: %0s pc=%h r0=%h irq=%0d nmi=%0d",
               tag, pc, r0, irq_count, nmi_count);
    end
  endtask

  integer req_mark;
  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP
    // platform vector table (low halfwords): SP, entry PC, NMI, IRQ0
    mem[16'h0002] = 8'h02; mem[16'h0003] = 8'h00;  // reset SP  = 0x0200
    mem[16'h0006] = 8'h00; mem[16'h0007] = 8'h30;  // reset PC  = 0x0030
    mem[16'h000e] = 8'h01; mem[16'h000f] = 8'h80;  // NMI       = 0x0180
    mem[16'h0018] = 8'h01; mem[16'h0019] = 8'h80;  // IRQ0      = 0x0180
    // main at 0x30: unmask irq, sleep, mark r0l, mask irq, sleep, mark r0h
    mem[16'h0030] = 8'h06; mem[16'h0031] = 8'h7f;  // andc #0x7f, ccr (clear I)
    mem[16'h0032] = 8'h01; mem[16'h0033] = 8'h80;  // sleep
    mem[16'h0034] = 8'hf8; mem[16'h0035] = 8'h55;  // mov.b #0x55, r0l
    mem[16'h0036] = 8'h04; mem[16'h0037] = 8'h80;  // orc #0x80, ccr (set I)
    mem[16'h0038] = 8'h01; mem[16'h0039] = 8'h80;  // sleep
    mem[16'h003a] = 8'hf0; mem[16'h003b] = 8'haa;  // mov.b #0xaa, r0h
    // handler at 0x0180: rte
    mem[16'h0180] = 8'h56; mem[16'h0181] = 8'h70;
    irq_count = 0; nmi_count = 0; req_count = 0; errors = 0;
    irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    // phase 1: boot loads SP/PC from the table, core parks in sleep
    repeat (60) @(posedge clock); #1;
    check(pc === 16'h0034 && r0[7:0] === 8'h00, "no wake: pc holds after sleep");
    req_mark = req_count;
    repeat (20) @(posedge clock); #1;
    check(req_count === req_mark, "no wake: bus idle");
    // phase 2: IRQ wakes, frame holds the next instruction address
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    repeat (12) @(posedge clock); #1;
    check(irq_count === 1, "irq wake: handler entered");
    check({mem[16'h01fe], mem[16'h01ff]} === 16'h0034, "irq wake: stacked pc");
    repeat (40) @(posedge clock); #1;
    check(r0[7:0] === 8'h55, "irq wake: resumed after sleep");
    // phase 3: masked IRQ does not wake, NMI does
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    repeat (30) @(posedge clock); #1;
    check(pc === 16'h003a && irq_count === 1, "masked irq: still asleep");
    nmi = 1; repeat (2) @(posedge clock); nmi = 0;
    repeat (40) @(posedge clock); #1;
    check(nmi_count >= 1, "nmi wake: handler entered");
    check(r0[15:8] === 8'haa, "nmi wake: resumed after sleep");
    if (errors == 0)
      $display("CORE-SLEEP PASS: boot, park, irq wake frame, mask, nmi wake");
    $finish;
  end
endmodule
