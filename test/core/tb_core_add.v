// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Execution check for mov.b #imm and reg-reg add.b: run
//   mov.b #5,R0L ; mov.b #3,R1L ; add.b R1L,R0L
// and confirm R0 = 8, R1 = 3 via the H8RegFile state tap. Behavioral BE SRAM.
`timescale 1ns / 1ps
module tb_core_add;
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

  wire [127:0] regs = dut.h8rf.dbg;   // R7..R0 (R0 in low bits)
  wire [15:0]  r0   = regs[15:0];
  wire [15:0]  r1   = regs[31:16];

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // NOP fill
    mem[0] = 8'hF8; mem[1] = 8'h05; // mov.b #0x05,R0L
    mem[2] = 8'hF9; mem[3] = 8'h03; // mov.b #0x03,R1L
    mem[4] = 8'h08; mem[5] = 8'h98; // add.b R1L,R0L
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (40) @(posedge clock); #1;
    if (r0 !== 16'h0008) begin $display("FAIL R0=%h exp 0008", r0); fails = fails + 1; end
    if (r1 !== 16'h0003) begin $display("FAIL R1=%h exp 0003", r1); fails = fails + 1; end
    if (fails == 0) $display("CORE-ADD PASS: R0=%h R1=%h (5+3=8)", r0, r1);
    else            $display("CORE-ADD FAIL: %0d", fails);
    $finish;
  end
endmodule
