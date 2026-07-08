// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Multi-word fetch: mov.w #0x1234,R0 (4-byte) reads the ext word into R0 and
// advances PC by 4. R0 = 0x1234.
`timescale 1ns / 1ps
module tb_core_movw;
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

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0]=8'h79; mem[1]=8'h00; mem[2]=8'h12; mem[3]=8'h34; // mov.w #0x1234,R0
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (40) @(posedge clock); #1;
    if (r0 !== 16'h1234) begin $display("FAIL R0=%h exp 1234", r0); fails=fails+1; end
    if (fails == 0) $display("CORE-MOVW PASS: R0=%h (mov.w #imm16)", r0);
    else            $display("CORE-MOVW FAIL: %0d", fails);
    $finish;
  end
endmodule
