// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// RnH byte-register select: mov.b #5,R0H ; mov.b #3,R1H ; add.b R1H,R0H
// writes the HIGH byte, so R0 = 0x0800, R1 = 0x0300. Behavioral BE SRAM.
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_byte;
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

  wire [127:0] regs = dut.h8rf.dbg;
  wire [15:0]  r0   = regs[15:0];
  wire [15:0]  r1   = regs[31:16];

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0002] = 8'h02; mem[16'h0003] = 8'h00;   // reset SP = 0x0200
    mem[16'h0006] = 8'h00; mem[16'h0007] = 8'h30;   // reset PC = 0x0030
    mem[16'h0030] = 8'hF0; mem[16'h0031] = 8'h05;   // mov.b #0x05,R0H
    mem[16'h0032] = 8'hF1; mem[16'h0033] = 8'h03;   // mov.b #0x03,R1H
    mem[16'h0034] = 8'h08; mem[16'h0035] = 8'h10;   // add.b R1H,R0H
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (60) @(posedge clock); #1;
    if (r0 !== 16'h0800) begin $display("FAIL R0=%h exp 0800", r0); fails = fails + 1; end
    if (r1 !== 16'h0300) begin $display("FAIL R1=%h exp 0300", r1); fails = fails + 1; end
    if (fails == 0) $display("CORE-BYTE PASS: R0=%h R1=%h (RnH high-byte)", r0, r1);
    else            $display("CORE-BYTE FAIL: %0d", fails);
    $finish;
  end
endmodule
