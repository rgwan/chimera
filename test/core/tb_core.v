// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Core execution smoke: a NOP-filled memory should make the fetch address walk
// 0,2,4,6,... (fetch -> PC+=2 -> dispatch -> NOP -> fetch). Behavioral
// single-cycle big-endian SRAM.
`timescale 1ns / 1ps
module tb_core;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  integer     i, nf, fails;
  reg  [15:0] fetches [0:31];

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]}; // big-endian
  end

  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP (0x0000)
    nf = 0; fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    for (i = 0; i < 300; i = i + 1) begin
      @(posedge clock); #1;
      if (bus_req && !bus_we && nf < 32) begin fetches[nf] = bus_addr; nf = nf + 1; end
    end
    // invariant: each NOP advances PC by 2, so fetch addresses step by 2
    if (fetches[0] > 2) begin
      $display("FAIL first fetch=%h (want 0 or 2)", fetches[0]); fails = fails + 1;
    end
    for (i = 1; i < 12; i = i + 1)
      if (fetches[i] !== fetches[i-1] + 16'd2) begin
        $display("FAIL fetch[%0d]=%h prev=%h", i, fetches[i], fetches[i-1]);
        fails = fails + 1;
      end
    if (fails == 0 && nf >= 12)
      $display("CORE-EXEC PASS: NOP loop, PC steps by 2 (%0d fetches from %h)",
               nf, fetches[0]);
    else
      $display("CORE-EXEC FAIL: %0d bad, nf=%0d", fails, nf);
    $finish;
  end
endmodule
