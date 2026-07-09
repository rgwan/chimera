// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Word register-register add/mov/sub/cmp smoke check.
`timescale 1ns / 1ps
module tb_core_word_reg;
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
  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [4:0]  ccr = dut.ccr.hnzvc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                    <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0] =8'h79; mem[1] =8'h01; mem[2] =8'h00; mem[3] =8'h01; // mov.w #0x0001,R1
    mem[4] =8'h79; mem[5] =8'h00; mem[6] =8'h7f; mem[7] =8'hff; // mov.w #0x7fff,R0
    mem[8] =8'h09; mem[9] =8'h10;                              // add.w R1,R0
    mem[10]=8'h0d; mem[11]=8'h02;                              // mov.w R0,R2
    mem[12]=8'h79; mem[13]=8'h03; mem[14]=8'h80; mem[15]=8'h00; // mov.w #0x8000,R3
    mem[16]=8'h79; mem[17]=8'h04; mem[18]=8'h00; mem[19]=8'h01; // mov.w #0x0001,R4
    mem[20]=8'h19; mem[21]=8'h43;                              // sub.w R4,R3
    mem[22]=8'h1d; mem[23]=8'h20;                              // cmp.w R2,R0
    mem[24]=8'h09; mem[25]=8'h18;                              // guarded invalid alias

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (150) @(posedge clock); #1;

    if (r0 !== 16'h8000) begin $display("FAIL R0=%h exp 8000", r0); fails=fails+1; end
    if (r1 !== 16'h0001) begin $display("FAIL R1=%h exp 0001", r1); fails=fails+1; end
    if (r2 !== 16'h8000) begin $display("FAIL R2=%h exp 8000", r2); fails=fails+1; end
    if (r3 !== 16'h7fff) begin $display("FAIL R3=%h exp 7fff", r3); fails=fails+1; end
    if (r4 !== 16'h0001) begin $display("FAIL R4=%h exp 0001", r4); fails=fails+1; end
    if (ccr !== 5'b00100) begin $display("FAIL CCR=%b exp 00100", ccr); fails=fails+1; end

    if (fails == 0) $display("CORE-WORD-REG PASS: add/mov/sub/cmp.w");
    else            $display("CORE-WORD-REG FAIL: %0d", fails);
    $finish;
  end
endmodule
