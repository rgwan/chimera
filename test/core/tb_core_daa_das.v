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
    .irq_number(3'd0), .vt_base(8'd0),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [15:0] P = 16'h0030;  // program base, past the vector table

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
    // platform vector table: SP from 0x0002, entry PC from 0x0006
    mem[16'h0002]=8'h00; mem[16'h0003]=8'h00;               // reset SP = 0x0000, R7H stays 0
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;               // reset PC = 0x0030
    mem[P+0] =8'h07; mem[P+1] =8'h00; mem[P+2] =8'hf0; mem[P+3] =8'h09;
    mem[P+4] =8'h0f; mem[P+5] =8'h00;                              // daa r0h
    mem[P+6] =8'h07; mem[P+7] =8'h00; mem[P+8] =8'hf9; mem[P+9] =8'h0a;
    mem[P+10]=8'h0f; mem[P+11]=8'h09;                              // daa r1l
    mem[P+12]=8'h07; mem[P+13]=8'h00; mem[P+14]=8'hf2; mem[P+15]=8'ha0;
    mem[P+16]=8'h0f; mem[P+17]=8'h02; mem[P+18]=8'h02; mem[P+19]=8'h0d; // stc r5l
    mem[P+20]=8'h07; mem[P+21]=8'h21; mem[P+22]=8'hff; mem[P+23]=8'h33;
    mem[P+24]=8'h0f; mem[P+25]=8'h0f; mem[P+26]=8'h02; mem[P+27]=8'h0e; // stc r6l
    mem[P+28]=8'h07; mem[P+29]=8'h00; mem[P+30]=8'hf3; mem[P+31]=8'h99;
    mem[P+32]=8'h1f; mem[P+33]=8'h03;                              // das r3h
    mem[P+34]=8'h07; mem[P+35]=8'h20; mem[P+36]=8'hfb; mem[P+37]=8'h06;
    mem[P+38]=8'h1f; mem[P+39]=8'h0b; mem[P+40]=8'h02; mem[P+41]=8'h05; // stc r5h
    mem[P+42]=8'h07; mem[P+43]=8'h01; mem[P+44]=8'hf4; mem[P+45]=8'h70;
    mem[P+46]=8'h1f; mem[P+47]=8'h04;                              // das r4h
    mem[P+48]=8'h07; mem[P+49]=8'h21; mem[P+50]=8'hfc; mem[P+51]=8'h66;
    mem[P+52]=8'h1f; mem[P+53]=8'h0c; mem[P+54]=8'h02; mem[P+55]=8'h06; // stc r6h
    mem[P+56]=8'h40; mem[P+57]=8'hfe;

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (460) @(posedge clock); #1;

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
