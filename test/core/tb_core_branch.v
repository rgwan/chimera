// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Bcc check: mov #1,R0L ; bra +2 (skip the next mov) ; mov #0xFF,R0L (skipped).
// If the branch is taken, R0 stays 0x01; if not, R0 becomes 0xFF.
`timescale 1ns / 1ps
module tb_core_branch;
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
    mem[0]=8'hF8; mem[1]=8'h01; // mov.b #0x01,R0L
    mem[2]=8'h40; mem[3]=8'h02; // bra +2  (target = 4+2 = 6, skips addr 4)
    mem[4]=8'hF8; mem[5]=8'hFF; // mov.b #0xFF,R0L (should be skipped)
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (40) @(posedge clock); #1;
    if (r0 !== 16'h0001) begin $display("FAIL R0=%h exp 0001 (branch not taken?)", r0); fails = fails + 1; end
    if (fails == 0) $display("CORE-BRANCH PASS: R0=%h (bra skipped the mov)", r0);
    else            $display("CORE-BRANCH FAIL: %0d", fails);
    $finish;
  end
endmodule
