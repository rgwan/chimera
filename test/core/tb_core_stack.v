// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Pre-decrement / post-increment round trip (stack primitives, general Rn):
//   R2=0x0200 ; mov.w R1,@-R2 (R2->0x01FE, push) ; mov.w @R2+,R3 (pop, R2->0x0200)
// -> R3 = 0x1234 and R2 restored to 0x0200.
`timescale 1ns / 1ps
module tb_core_stack;
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

  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                    <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0]=8'h79; mem[1]=8'h01; mem[2]=8'h12; mem[3]=8'h34; // mov.w #0x1234,R1
    mem[4]=8'h79; mem[5]=8'h02; mem[6]=8'h02; mem[7]=8'h00; // mov.w #0x0200,R2
    mem[8]=8'h6D; mem[9]=8'hA1;                             // mov.w R1,@-R2
    mem[10]=8'h6D; mem[11]=8'h23;                           // mov.w @R2+,R3
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (70) @(posedge clock); #1;
    if (r3 !== 16'h1234) begin $display("FAIL R3=%h exp 1234 (pop)", r3); fails=fails+1; end
    if (r2 !== 16'h0200) begin $display("FAIL R2=%h exp 0200 (SP not restored)", r2); fails=fails+1; end
    if (mem[16'h01FE] !== 8'h12 || mem[16'h01FF] !== 8'h34) begin
      $display("FAIL mem[01FE]=%h%h exp 1234", mem[16'h01FE], mem[16'h01FF]); fails=fails+1; end
    if (fails == 0) $display("CORE-STACK PASS: pushed @-R2, popped @R2+, R3=%h R2=%h", r3, r2);
    else            $display("CORE-STACK FAIL: %0d", fails);
    $finish;
  end
endmodule
