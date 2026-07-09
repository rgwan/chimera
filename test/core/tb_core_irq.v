// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Microcode-poll interrupt: the fetch mainloop polls between retires and enters
// irq_proc when an interrupt is pending. Entry acks the latch and sets CCR.I.
`timescale 1ns / 1ps
module tb_core_irq;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  integer     i, handler_count;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [8:0] IRQ_PROC = 9'h130;   // FetchEntry(0x100) + 0x30

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

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP
    handler_count = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (16) @(posedge clock);
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    repeat (20) @(posedge clock);
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    repeat (20) @(posedge clock); #1;
    if (handler_count == 1 && dut.ccr.iFlag === 1'b1 && dut.intrf.dbgPc >= 16'h0010)
      $display("CORE-IRQ PASS: handler entered once, I set, program continued (pc=%h)",
               dut.intrf.dbgPc);
    else
      $display("CORE-IRQ FAIL: count=%0d iflag=%b pc=%h",
               handler_count, dut.ccr.iFlag, dut.intrf.dbgPc);
    $finish;
  end
endmodule
