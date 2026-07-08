// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// A real loop (backward branch, negative disp):
//   loop: add.b #1,R0L ; cmp.b #3,R0L ; bne loop
// R0 counts 1,2,3 and exits when R0==3. Final R0 = 3.
`timescale 1ns / 1ps
module tb_core_loop;
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
    mem[0]=8'h88; mem[1]=8'h01;  // add.b #1,R0L
    mem[2]=8'hA8; mem[3]=8'h03;  // cmp.b #3,R0L
    mem[4]=8'h46; mem[5]=8'hFA;  // bne -6  (back to addr 0)
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (100) @(posedge clock); #1;
    if (r0 !== 16'h0003) begin $display("FAIL R0=%h exp 0003", r0); fails=fails+1; end
    if (fails == 0) $display("CORE-LOOP PASS: R0=%h (counted to 3)", r0);
    else            $display("CORE-LOOP FAIL: %0d", fails);
    $finish;
  end
endmodule
