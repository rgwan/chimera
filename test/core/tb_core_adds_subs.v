// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// ADDS/SUBS word constants preserve CCR and reject noncanonical aliases.
`timescale 1ns / 1ps
module tb_core_adds_subs;
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
  wire [15:0] r3 = dut.h8rf.dbg[63:48];
  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [15:0] r7 = dut.h8rf.dbg[127:112];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[0] =8'h79; mem[1] =8'h00; mem[2] =8'h12; mem[3] =8'h34; // mov.w #0x1234,R0
    mem[4] =8'h79; mem[5] =8'h04; mem[6] =8'h00; mem[7] =8'hff; // mov.w #0x00ff,R4
    mem[8] =8'h79; mem[9] =8'h07; mem[10]=8'hff; mem[11]=8'hff; // mov.w #0xffff,R7
    mem[12]=8'h79; mem[13]=8'h03; mem[14]=8'h00; mem[15]=8'h00; // mov.w #0x0000,R3
    mem[16]=8'h07; mem[17]=8'h23;                              // ldc #0x23,ccr
    mem[18]=8'h0b; mem[19]=8'h04;                              // adds #1,R4
    mem[20]=8'h0b; mem[21]=8'h87;                              // adds #2,R7
    mem[22]=8'h1b; mem[23]=8'h03;                              // subs #1,R3
    mem[24]=8'h1b; mem[25]=8'h87;                              // subs #2,R7
    mem[26]=8'h0b; mem[27]=8'h08;                              // rejected alias
    mem[28]=8'h40; mem[29]=8'hfe;                              // halt
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (150) @(posedge clock); #1;

    if (r0 !== 16'h1234) begin $display("FAIL R0=%h exp 1234", r0); fails=fails+1; end
    if (r3 !== 16'hffff) begin $display("FAIL R3=%h exp ffff", r3); fails=fails+1; end
    if (r4 !== 16'h0100) begin $display("FAIL R4=%h exp 0100", r4); fails=fails+1; end
    if (r7 !== 16'hffff) begin $display("FAIL R7=%h exp ffff", r7); fails=fails+1; end
    if (hnzvc !== 5'b10011) begin $display("FAIL hnzvc=%b exp 10011", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-ADDS-SUBS PASS: word scale ops");
    else            $display("CORE-ADDS-SUBS FAIL: %0d", fails);
    $finish;
  end
endmodule
