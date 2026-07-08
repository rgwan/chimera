// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Immediate-ALU chain on R0L:
//   mov #0x0F ; and #0x3C -> 0x0C ; or #0x30 -> 0x3C ; add #0x04 -> 0x40 ;
//   cmp #0x40 -> Z=1.  Final R0 = 0x0040, ccr H N Z V C = 0 0 1 0 0.
`timescale 1ns / 1ps
module tb_core_imm;
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

  wire [15:0] r0    = dut.h8rf.dbg[15:0];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0]=8'hF8; mem[1]=8'h0F; // mov.b #0x0F,R0L
    mem[2]=8'hE8; mem[3]=8'h3C; // and.b #0x3C,R0L -> 0x0C
    mem[4]=8'hC8; mem[5]=8'h30; // or.b  #0x30,R0L -> 0x3C
    mem[6]=8'h88; mem[7]=8'h04; // add.b #0x04,R0L -> 0x40
    mem[8]=8'hA8; mem[9]=8'h40; // cmp.b #0x40,R0L -> Z=1
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (60) @(posedge clock); #1;
    if (r0    !== 16'h0040) begin $display("FAIL R0=%h exp 0040", r0); fails = fails + 1; end
    if (hnzvc !== 5'b00100) begin $display("FAIL hnzvc=%b exp 00100", hnzvc); fails = fails + 1; end
    if (fails == 0) $display("CORE-IMM PASS: R0=%h hnzvc=%b (and/or/add/cmp)", r0, hnzvc);
    else            $display("CORE-IMM FAIL: %0d", fails);
    $finish;
  end
endmodule
