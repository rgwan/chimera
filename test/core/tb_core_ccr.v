// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// CCR direct-op check: stc, ldc register, and immediate CCR logic.
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
  wire [15:0] r1 = dut.h8rf.dbg[31:16];
  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0] =8'h07; mem[1] =8'ha5; // ldc #0xa5,ccr
    mem[2] =8'h02; mem[3] =8'h08; // stc ccr,R0L
    mem[4] =8'h07; mem[5] =8'h00; // ldc #0,ccr
    mem[6] =8'h04; mem[7] =8'h21; // orc #0x21,ccr
    mem[8] =8'h02; mem[9] =8'h09; // stc ccr,R1L
    mem[10]=8'h07; mem[11]=8'ha3; // ldc #0xa3,ccr
    mem[12]=8'h05; mem[13]=8'h23; // xorc #0x23,ccr
    mem[14]=8'h02; mem[15]=8'h0a; // stc ccr,R2L
    mem[16]=8'h07; mem[17]=8'hbf; // ldc #0xbf,ccr
    mem[18]=8'h06; mem[19]=8'h2c; // andc #0x2c,ccr
    mem[20]=8'h02; mem[21]=8'h0b; // stc ccr,R3L
    mem[22]=8'h02; mem[23]=8'h18; // rejected stc alias
    mem[24]=8'h03; mem[25]=8'h19; // rejected ldc alias
    mem[26]=8'h40; mem[27]=8'hfe; // halt
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (130) @(posedge clock); #1;

    if (r0 !== 16'h00a5) begin $display("FAIL R0=%h exp 00a5", r0); fails=fails+1; end
    if (r1 !== 16'h0021) begin $display("FAIL R1=%h exp 0021", r1); fails=fails+1; end
    if (r2 !== 16'h0080) begin $display("FAIL R2=%h exp 0080", r2); fails=fails+1; end
    if (r3 !== 16'h002c) begin $display("FAIL R3=%h exp 002c", r3); fails=fails+1; end
    if (hnzvc !== 5'b11100) begin $display("FAIL hnzvc=%b exp 11100", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-CCR PASS: ccr direct ops");
    else            $display("CORE-CCR FAIL: %0d", fails);
    $finish;
  end
endmodule
