// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// CCR register-load check: ldc RnL,ccr and a rejected alias in the same page.
`timescale 1ns / 1ps
module tb_core_ccr;
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
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0]=8'hf8; mem[1]=8'h2d; // mov.b #0x2d,R0L
    mem[2]=8'h03; mem[3]=8'h08; // ldc R0L,ccr
    mem[4]=8'h03; mem[5]=8'h19; // rejected alias
    mem[6]=8'h40; mem[7]=8'hfe; // halt
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (60) @(posedge clock); #1;

    if (r0 !== 16'h002d) begin $display("FAIL R0=%h exp 002d", r0); fails=fails+1; end
    if (hnzvc !== 5'b11101) begin $display("FAIL hnzvc=%b exp 11101", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-CCR PASS: ldc register updates CCR");
    else            $display("CORE-CCR FAIL: %0d", fails);
    $finish;
  end
endmodule
