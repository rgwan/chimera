// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Register-indirect word store/load round trip:
//   R1=0x1234 ; R2=0x0100 ; mov.w R1,@R2 ; mov.w @R2,R3  ->  R3 = 0x1234.
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_mem;
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

  wire [15:0] r1 = dut.h8rf.dbg[31:16];
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
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h01; mem[16'h0032]=8'h12; mem[16'h0033]=8'h34; // mov.w #0x1234,R1
    mem[16'h0034]=8'h79; mem[16'h0035]=8'h02; mem[16'h0036]=8'h01; mem[16'h0037]=8'h00; // mov.w #0x0100,R2
    mem[16'h0038]=8'h69; mem[16'h0039]=8'hA1;                                           // mov.w R1,@R2
    mem[16'h003A]=8'h69; mem[16'h003B]=8'h23;                                           // mov.w @R2,R3
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (80) @(posedge clock); #1;
    if (r3 !== 16'h1234) begin $display("FAIL R3=%h exp 1234 (load)", r3); fails=fails+1; end
    if (r1 !== 16'h1234) begin $display("FAIL R1=%h exp 1234", r1); fails=fails+1; end
    if (r2 !== 16'h0100) begin $display("FAIL R2=%h exp 0100 (pointer moved?)", r2); fails=fails+1; end
    if (mem[16'h0100] !== 8'h12 || mem[16'h0101] !== 8'h34) begin
      $display("FAIL mem[0100]=%h%h exp 1234", mem[16'h0100], mem[16'h0101]); fails=fails+1; end
    if (fails == 0) $display("CORE-MEM PASS: stored R1 to @R2, loaded back R3=%h", r3);
    else            $display("CORE-MEM FAIL: %0d", fails);
    $finish;
  end
endmodule
