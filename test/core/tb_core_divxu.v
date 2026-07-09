// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// DIVXU restoring-division checks, including zero divisor.
`timescale 1ns / 1ps
module tb_core_divxu;
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

  wire [15:0] r1 = dut.h8rf.dbg[31:16];
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
    mem[0] =8'h79; mem[1] =8'h00; mem[2] =8'h00; mem[3] =8'h12; // mov.w #0x0012,R0
    mem[4] =8'h79; mem[5] =8'h01; mem[6] =8'h02; mem[7] =8'h34; // mov.w #0x0234,R1
    mem[8] =8'h07; mem[9] =8'h2f;                              // ldc #0x2f,ccr
    mem[10]=8'h51; mem[11]=8'h81;                              // divxu R0L,R1
    mem[12]=8'h02; mem[13]=8'h0f;                              // stc ccr,R7L
    mem[14]=8'h79; mem[15]=8'h02; mem[16]=8'h80; mem[17]=8'h00; // mov.w #0x8000,R2
    mem[18]=8'h79; mem[19]=8'h04; mem[20]=8'h40; mem[21]=8'h01; // mov.w #0x4001,R4
    mem[22]=8'h07; mem[23]=8'h01;                              // ldc #0x01,ccr
    mem[24]=8'h51; mem[25]=8'h24;                              // divxu R2H,R4
    mem[26]=8'h02; mem[27]=8'h07;                              // stc ccr,R7H
    mem[28]=8'h79; mem[29]=8'h00; mem[30]=8'h00; mem[31]=8'h00; // mov.w #0x0000,R0
    mem[32]=8'h79; mem[33]=8'h03; mem[34]=8'hbe; mem[35]=8'hef; // mov.w #0xbeef,R3
    mem[36]=8'h07; mem[37]=8'h2b;                              // ldc #0x2b,ccr
    mem[38]=8'h51; mem[39]=8'h03;                              // divxu R0H,R3
    mem[40]=8'h02; mem[41]=8'h0d;                              // stc ccr,R5L
    mem[42]=8'h79; mem[43]=8'h00; mem[44]=8'h00; mem[45]=8'h01; // mov.w #0x0001,R0
    mem[46]=8'h79; mem[47]=8'h06; mem[48]=8'hff; mem[49]=8'hff; // mov.w #0xffff,R6
    mem[50]=8'h07; mem[51]=8'h25;                              // ldc #0x25,ccr
    mem[52]=8'h51; mem[53]=8'h86;                              // divxu R0L,R6
    mem[54]=8'h02; mem[55]=8'h05;                              // stc ccr,R5H
    mem[56]=8'h51; mem[57]=8'h08;                              // rejected alias
    mem[58]=8'h40; mem[59]=8'hfe;                              // halt

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (2400) @(posedge clock); #1;

    if (r1 !== 16'h061f) begin $display("FAIL R1=%h exp 061f", r1); fails=fails+1; end
    if (r3 !== 16'hbeef) begin $display("FAIL R3=%h exp beef", r3); fails=fails+1; end
    if (r4 !== 16'h0180) begin $display("FAIL R4=%h exp 0180", r4); fails=fails+1; end
    if (r5 !== 16'h2127) begin $display("FAIL R5=%h exp 2127", r5); fails=fails+1; end
    if (r6 !== 16'h00ff) begin $display("FAIL R6=%h exp 00ff", r6); fails=fails+1; end
    if (r7 !== 16'h0923) begin $display("FAIL R7=%h exp 0923", r7); fails=fails+1; end
    if (hnzvc !== 5'b10001) begin $display("FAIL hnzvc=%b exp 10001", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-DIVXU PASS: unsigned byte division");
    else            $display("CORE-DIVXU FAIL: %0d", fails);
    $finish;
  end
endmodule
