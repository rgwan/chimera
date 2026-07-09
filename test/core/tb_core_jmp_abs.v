// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Absolute jmp/jsr forms: @aa:16 and @@aa:8.
`timescale 1ns / 1ps
module tb_core_jmp_abs;
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
  wire [15:0] r7 = dut.h8rf.dbg[127:112];
  wire [15:0] pc = dut.intrf.dbgPc;

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

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0] =8'h5a; mem[1] =8'h00; mem[2] =8'h00; mem[3] =8'h10; // jmp @0x0010:16
    mem[4] =8'hf8; mem[5] =8'hee;                              // skipped
    mem[16]=8'h79; mem[17]=8'h07; mem[18]=8'h03; mem[19]=8'h00; // mov.w #0x0300,R7
    mem[20]=8'hf8; mem[21]=8'h11;                              // mov.b #0x11,R0L
    mem[22]=8'h5b; mem[23]=8'h40;                              // jmp @@0x40:8
    mem[32]=8'hf9; mem[33]=8'h22;                              // mov.b #0x22,R1L
    mem[34]=8'h5e; mem[35]=8'h00; mem[36]=8'h00; mem[37]=8'h30; // jsr @0x0030:16
    mem[38]=8'hfa; mem[39]=8'h33;                              // mov.b #0x33,R2L
    mem[40]=8'h5f; mem[41]=8'h42;                              // jsr @@0x42:8
    mem[42]=8'hfb; mem[43]=8'h44;                              // mov.b #0x44,R3L
    mem[44]=8'h40; mem[45]=8'hfe;                              // halt
    mem[48]=8'hfc; mem[49]=8'haa;                              // mov.b #0xaa,R4L
    mem[50]=8'h54; mem[51]=8'h70;                              // rts
    mem[56]=8'hfd; mem[57]=8'hbb;                              // mov.b #0xbb,R5L
    mem[58]=8'h54; mem[59]=8'h70;                              // rts
    mem[16'h0040] = 8'h00;
    mem[16'h0041] = 8'h20;
    mem[16'h0042] = 8'h00;
    mem[16'h0043] = 8'h38;
    mem[16'h02fe] = 8'haa;
    mem[16'h02ff] = 8'h55;

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (170) @(posedge clock); #1;

    if (r0 !== 16'h0011) begin $display("FAIL R0=%h exp 0011", r0); fails=fails+1; end
    if (r1 !== 16'h0022) begin $display("FAIL R1=%h exp 0022", r1); fails=fails+1; end
    if (r2 !== 16'h0033) begin $display("FAIL R2=%h exp 0033", r2); fails=fails+1; end
    if (r3 !== 16'h0044) begin $display("FAIL R3=%h exp 0044", r3); fails=fails+1; end
    if (r4 !== 16'h00aa) begin $display("FAIL R4=%h exp 00aa", r4); fails=fails+1; end
    if (r5 !== 16'h00bb) begin $display("FAIL R5=%h exp 00bb", r5); fails=fails+1; end
    if (r7 !== 16'h0300) begin $display("FAIL R7=%h exp 0300 PC=%h", r7, pc); fails=fails+1; end
    if (mem[16'h02fe] !== 8'h00 || mem[16'h02ff] !== 8'h2a) begin
      $display("FAIL stack=%h%h exp 002a", mem[16'h02fe], mem[16'h02ff]); fails=fails+1; end

    if (fails == 0) $display("CORE-JMP-ABS PASS: absolute jmp/jsr forms");
    else            $display("CORE-JMP-ABS FAIL: %0d", fails);
    $finish;
  end
endmodule
