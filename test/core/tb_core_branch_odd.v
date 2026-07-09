// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Odd-displacement branch target aligns down to even (no trap):
//   mov #1,R0L ; bra +5  ->  target (4+5)&~1 = 8, where mov #0x42,R0L lives.
// An unaligned target (9) would misdecode mem[9..10] and never set R0=0x42.
`timescale 1ns / 1ps
module tb_core_branch_odd;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  integer     i, fails;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  wire [15:0] r0 = dut.h8rf.dbg[15:0];

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0]=8'hF8; mem[1]=8'h01;  // mov.b #1,R0L
    mem[2]=8'h40; mem[3]=8'h05;  // bra +5  -> target aligns to 8
    mem[8]=8'hF8; mem[9]=8'h42;  // mov.b #0x42,R0L (at the even-aligned target)
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (40) @(posedge clock); #1;
    if (r0 !== 16'h0042) begin $display("FAIL R0=%h exp 0042 (odd target not aligned?)", r0); fails=fails+1; end
    if (fails == 0) $display("CORE-BRANCH-ODD PASS: R0=%h (bra +5 aligned to 8)", r0);
    else            $display("CORE-BRANCH-ODD FAIL: %0d", fails);
    $finish;
  end
endmodule
