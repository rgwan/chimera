// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// CCR direct-op check: stc, ldc register, and immediate CCR logic.
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
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
    .irq_number(3'd0), .vt_base(8'd0),
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
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00; // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30; // reset PC = 0x0030
    mem[16'h0030]=8'h07; mem[16'h0031]=8'ha5; // ldc #0xa5,ccr
    mem[16'h0032]=8'h02; mem[16'h0033]=8'h08; // stc ccr,R0L
    mem[16'h0034]=8'h07; mem[16'h0035]=8'h00; // ldc #0,ccr
    mem[16'h0036]=8'h04; mem[16'h0037]=8'h21; // orc #0x21,ccr
    mem[16'h0038]=8'h02; mem[16'h0039]=8'h09; // stc ccr,R1L
    mem[16'h003a]=8'h07; mem[16'h003b]=8'ha3; // ldc #0xa3,ccr
    mem[16'h003c]=8'h05; mem[16'h003d]=8'h23; // xorc #0x23,ccr
    mem[16'h003e]=8'h02; mem[16'h003f]=8'h0a; // stc ccr,R2L
    mem[16'h0040]=8'h07; mem[16'h0041]=8'hbf; // ldc #0xbf,ccr
    mem[16'h0042]=8'h06; mem[16'h0043]=8'h2c; // andc #0x2c,ccr
    mem[16'h0044]=8'h02; mem[16'h0045]=8'h0b; // stc ccr,R3L
    mem[16'h0046]=8'h02; mem[16'h0047]=8'h18; // rejected stc alias
    mem[16'h0048]=8'h03; mem[16'h0049]=8'h19; // rejected ldc alias
    mem[16'h004a]=8'h40; mem[16'h004b]=8'hfe; // halt
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (150) @(posedge clock); #1;

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
