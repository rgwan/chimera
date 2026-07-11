// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Flag check: mov.b #0x7F,R0L ; mov.b #0x01,R1L ; add.b R1L,R0L
// -> R0 = 0x80, ccr H N Z V C = 1 1 0 1 0 (half-carry, negative, overflow).
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_flags;
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

  wire [15:0] r0    = dut.h8rf.dbg[15:0];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;   // H N Z V C

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
    mem[16'h0030] = 8'hF8; mem[16'h0031] = 8'h7F;   // mov.b #0x7F,R0L
    mem[16'h0032] = 8'hF9; mem[16'h0033] = 8'h01;   // mov.b #0x01,R1L
    mem[16'h0034] = 8'h08; mem[16'h0035] = 8'h98;   // add.b R1L,R0L
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (60) @(posedge clock); #1;
    if (r0    !== 16'h0080) begin $display("FAIL R0=%h exp 0080", r0); fails = fails + 1; end
    if (hnzvc !== 5'b11010) begin $display("FAIL hnzvc=%b exp 11010", hnzvc); fails = fails + 1; end
    if (fails == 0) $display("CORE-FLAGS PASS: R0=%h hnzvc=%b (H N Z V C)", r0, hnzvc);
    else            $display("CORE-FLAGS FAIL: %0d", fails);
    $finish;
  end
endmodule
