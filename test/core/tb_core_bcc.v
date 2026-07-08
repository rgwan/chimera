// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// BEQ taken and not-taken:
//   R0: mov #5 ; cmp #5 (Z=1) ; beq +2 ; mov #0xFF (skipped)   -> R0 = 5
//   R1: mov #5 ; cmp #3 (Z=0) ; beq +2 ; mov #0xAA (executes)  -> R1 = 0xAA
`timescale 1ns / 1ps
module tb_core_bcc;
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

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0]=8'hF8; mem[1]=8'h05;  // mov.b #5,R0L
    mem[2]=8'hA8; mem[3]=8'h05;  // cmp.b #5,R0L  -> Z=1
    mem[4]=8'h47; mem[5]=8'h02;  // beq +2        -> taken, skip addr 6
    mem[6]=8'hF8; mem[7]=8'hFF;  // mov.b #0xFF,R0L (skipped)
    mem[8]=8'hF9; mem[9]=8'h05;  // mov.b #5,R1L
    mem[10]=8'hA9; mem[11]=8'h03; // cmp.b #3,R1L -> Z=0
    mem[12]=8'h47; mem[13]=8'h02; // beq +2       -> not taken
    mem[14]=8'hF9; mem[15]=8'hAA; // mov.b #0xAA,R1L (executes)
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (80) @(posedge clock); #1;
    if (r0 !== 16'h0005) begin $display("FAIL R0=%h exp 0005 (beq-taken)", r0); fails=fails+1; end
    if (r1 !== 16'h00AA) begin $display("FAIL R1=%h exp 00AA (beq-not-taken)", r1); fails=fails+1; end
    if (fails == 0) $display("CORE-BCC PASS: R0=%h R1=%h (beq taken + not-taken)", r0, r1);
    else            $display("CORE-BCC FAIL: %0d", fails);
    $finish;
  end
endmodule
