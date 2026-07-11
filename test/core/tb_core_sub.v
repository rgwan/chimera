// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// reg-reg sub.b via the m-class dispatch (rs=R1L -> coarse 0xD8):
//   mov #8,R0L ; mov #3,R1L ; sub.b R1L,R0L  -> R0 = 5.
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_sub;
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
    mem[16'h0030]=8'hF8; mem[16'h0031]=8'h08; // mov.b #8,R0L
    mem[16'h0032]=8'hF9; mem[16'h0033]=8'h03; // mov.b #3,R1L
    mem[16'h0034]=8'h18; mem[16'h0035]=8'h98; // sub.b R1L,R0L  (rs=R1L -> 0xD8)
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (70) @(posedge clock); #1;
    if (r0 !== 16'h0005) begin $display("FAIL R0=%h exp 0005", r0); fails=fails+1; end
    if (fails == 0) $display("CORE-SUB PASS: R0=%h (8-3=5 via m-class)", r0);
    else            $display("CORE-SUB FAIL: %0d", fails);
    $finish;
  end
endmodule
