// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// bsr / rts round trip with the H8 stack (SP=R7):
//   SP=0x0300 ; bsr sub ; (sub: R2=0xCAFE; rts) ; R1=0xBEEF ; halt.
// After return: R1=0xBEEF (returned), R2=0xCAFE (sub ran), R7=0x0300 (SP restored).
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_jsr;
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
  wire [15:0] r7 = dut.h8rf.dbg[127:112];

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
    mem[16'h0002]=8'h03; mem[16'h0003]=8'h00;  // reset SP = 0x0300
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h07; mem[16'h0032]=8'h03; mem[16'h0033]=8'h00; // mov.w #0x0300,R7 (SP)
    mem[16'h0034]=8'h55; mem[16'h0035]=8'h0A;                                           // bsr +0x0A -> 0x40
    mem[16'h0036]=8'h79; mem[16'h0037]=8'h01; mem[16'h0038]=8'hBE; mem[16'h0039]=8'hEF; // mov.w #0xBEEF,R1 (after ret)
    mem[16'h003A]=8'h40; mem[16'h003B]=8'hFE;                                           // bra -2 (halt)
    mem[16'h0040]=8'h79; mem[16'h0041]=8'h02; mem[16'h0042]=8'hCA; mem[16'h0043]=8'hFE; // sub: mov.w #0xCAFE,R2
    mem[16'h0044]=8'h54; mem[16'h0045]=8'h70;                                           // rts
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (110) @(posedge clock); #1;
    if (r1 !== 16'hBEEF) begin $display("FAIL R1=%h exp BEEF (did not return?)", r1); fails=fails+1; end
    if (r2 !== 16'hCAFE) begin $display("FAIL R2=%h exp CAFE (sub not run?)", r2); fails=fails+1; end
    if (r7 !== 16'h0300) begin $display("FAIL R7=%h exp 0300 (SP not restored)", r7); fails=fails+1; end
    if (fails == 0) $display("CORE-JSR PASS: bsr/rts round trip R1=%h R2=%h SP=%h", r1, r2, r7);
    else            $display("CORE-JSR FAIL: %0d", fails);
    $finish;
  end
endmodule
