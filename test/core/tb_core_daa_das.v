// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// DAA/DAS decimal-adjust checks with CCR snapshots captured by STC.
`timescale 1ns / 1ps
module tb_core_daa_das;
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
  wire [15:0] r5 = dut.h8rf.dbg[95:80];
  wire [15:0] r6 = dut.h8rf.dbg[111:96];
  wire [15:0] r7 = dut.h8rf.dbg[127:112];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0] =8'h07; mem[1] =8'h00; mem[2] =8'hf0; mem[3] =8'h09;
    mem[4] =8'h0f; mem[5] =8'h00;                              // daa r0h
    mem[6] =8'h07; mem[7] =8'h00; mem[8] =8'hf9; mem[9] =8'h0a;
    mem[10]=8'h0f; mem[11]=8'h09;                              // daa r1l
    mem[12]=8'h07; mem[13]=8'h00; mem[14]=8'hf2; mem[15]=8'ha0;
    mem[16]=8'h0f; mem[17]=8'h02; mem[18]=8'h02; mem[19]=8'h0d; // stc r5l
    mem[20]=8'h07; mem[21]=8'h21; mem[22]=8'hff; mem[23]=8'h33;
    mem[24]=8'h0f; mem[25]=8'h0f; mem[26]=8'h02; mem[27]=8'h0e; // stc r6l
    mem[28]=8'h07; mem[29]=8'h00; mem[30]=8'hf3; mem[31]=8'h99;
    mem[32]=8'h1f; mem[33]=8'h03;                              // das r3h
    mem[34]=8'h07; mem[35]=8'h20; mem[36]=8'hfb; mem[37]=8'h06;
    mem[38]=8'h1f; mem[39]=8'h0b; mem[40]=8'h02; mem[41]=8'h05; // stc r5h
    mem[42]=8'h07; mem[43]=8'h01; mem[44]=8'hf4; mem[45]=8'h70;
    mem[46]=8'h1f; mem[47]=8'h04;                              // das r4h
    mem[48]=8'h07; mem[49]=8'h21; mem[50]=8'hfc; mem[51]=8'h66;
    mem[52]=8'h1f; mem[53]=8'h0c; mem[54]=8'h02; mem[55]=8'h06; // stc r6h
    mem[56]=8'h40; mem[57]=8'hfe;

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (420) @(posedge clock); #1;

    if (r0 !== 16'h0900) begin $display("FAIL R0=%h exp 0900", r0); fails=fails+1; end
    if (r1 !== 16'h0010) begin $display("FAIL R1=%h exp 0010", r1); fails=fails+1; end
    if (r2 !== 16'h0000) begin $display("FAIL R2=%h exp 0000", r2); fails=fails+1; end
    if (r3 !== 16'h9900) begin $display("FAIL R3=%h exp 9900", r3); fails=fails+1; end
    if (r4 !== 16'h1000) begin $display("FAIL R4=%h exp 1000", r4); fails=fails+1; end
    if (r5 !== 16'h2405) begin $display("FAIL R5=%h exp 2405", r5); fails=fails+1; end
    if (r6 !== 16'h2529) begin $display("FAIL R6=%h exp 2529", r6); fails=fails+1; end
    if (r7 !== 16'h0099) begin $display("FAIL R7=%h exp 0099", r7); fails=fails+1; end
    if (hnzvc !== 5'b10101) begin $display("FAIL hnzvc=%b exp 10101", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-DAA-DAS PASS: decimal adjust");
    else            $display("CORE-DAA-DAS FAIL: %0d", fails);
    $finish;
  end
endmodule
