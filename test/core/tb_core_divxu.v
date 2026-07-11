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
    .irq_number(3'd0), .vt_base(8'd0),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [15:0] P = 16'h0030;  // program base, past the vector table

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
    // platform vector table: SP from 0x0002, entry PC from 0x0006
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;               // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;               // reset PC = 0x0030
    mem[P+0] =8'h79; mem[P+1] =8'h00; mem[P+2] =8'h00; mem[P+3] =8'h12; // mov.w #0x0012,R0
    mem[P+4] =8'h79; mem[P+5] =8'h01; mem[P+6] =8'h02; mem[P+7] =8'h34; // mov.w #0x0234,R1
    mem[P+8] =8'h07; mem[P+9] =8'h2f;                              // ldc #0x2f,ccr
    mem[P+10]=8'h51; mem[P+11]=8'h81;                              // divxu R0L,R1
    mem[P+12]=8'h02; mem[P+13]=8'h0f;                              // stc ccr,R7L
    mem[P+14]=8'h79; mem[P+15]=8'h02; mem[P+16]=8'h80; mem[P+17]=8'h00; // mov.w #0x8000,R2
    mem[P+18]=8'h79; mem[P+19]=8'h04; mem[P+20]=8'h40; mem[P+21]=8'h01; // mov.w #0x4001,R4
    mem[P+22]=8'h07; mem[P+23]=8'h01;                              // ldc #0x01,ccr
    mem[P+24]=8'h51; mem[P+25]=8'h24;                              // divxu R2H,R4
    mem[P+26]=8'h02; mem[P+27]=8'h07;                              // stc ccr,R7H
    mem[P+28]=8'h79; mem[P+29]=8'h00; mem[P+30]=8'h00; mem[P+31]=8'h00; // mov.w #0x0000,R0
    mem[P+32]=8'h79; mem[P+33]=8'h03; mem[P+34]=8'hbe; mem[P+35]=8'hef; // mov.w #0xbeef,R3
    mem[P+36]=8'h07; mem[P+37]=8'h2b;                              // ldc #0x2b,ccr
    mem[P+38]=8'h51; mem[P+39]=8'h03;                              // divxu R0H,R3
    mem[P+40]=8'h02; mem[P+41]=8'h0d;                              // stc ccr,R5L
    mem[P+42]=8'h79; mem[P+43]=8'h00; mem[P+44]=8'h00; mem[P+45]=8'h01; // mov.w #0x0001,R0
    mem[P+46]=8'h79; mem[P+47]=8'h06; mem[P+48]=8'hff; mem[P+49]=8'hff; // mov.w #0xffff,R6
    mem[P+50]=8'h07; mem[P+51]=8'h25;                              // ldc #0x25,ccr
    mem[P+52]=8'h51; mem[P+53]=8'h86;                              // divxu R0L,R6
    mem[P+54]=8'h02; mem[P+55]=8'h05;                              // stc ccr,R5H
    mem[P+56]=8'h51; mem[P+57]=8'h08;                              // rejected alias
    mem[P+58]=8'h40; mem[P+59]=8'hfe;                              // halt

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (2440) @(posedge clock); #1;

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
