// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// rte pops CCR (high byte of mem[SP]) then PC, SP += 4 (oracle frame):
//   SP=0x01FC, mem[01FC..01FF]=AB CD 12 34 -> PC=0x1234, CCR hnzvc=11011, SP=0x0200.
// The handler at 0x1234 is a flag-neutral self-loop so the restored CCR is
// observable (a flag-setting handler would clobber it before we sample).
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_rte;
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

  wire [15:0] r7    = dut.h8rf.dbg[127:112];
  wire [15:0] pc    = dut.intrf.dbgPc;
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

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
    mem[16'h0002]=8'h01; mem[16'h0003]=8'hFC;  // reset SP = 0x01FC
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h07; mem[16'h0032]=8'h01; mem[16'h0033]=8'hFC; // mov.w #0x01FC,R7 (SP)
    mem[16'h0034]=8'h56; mem[16'h0035]=8'h70;                                           // rte
    mem[16'h01FC]=8'hAB; mem[16'h01FD]=8'hCD;               // stacked CCR word (AB = CCR)
    mem[16'h01FE]=8'h12; mem[16'h01FF]=8'h34;               // stacked PC = 0x1234
    mem[16'h1234]=8'h40; mem[16'h1235]=8'hFE;               // handler: bra -2 (flag-neutral halt)
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (80) @(posedge clock); #1;
    if (pc !== 16'h1234 && pc !== 16'h1236) begin $display("FAIL pc=%h exp ~1234", pc); fails=fails+1; end
    if (r7    !== 16'h0200) begin $display("FAIL R7=%h exp 0200 (SP)", r7); fails=fails+1; end
    if (hnzvc !== 5'b11011) begin $display("FAIL hnzvc=%b exp 11011 (CCR restore)", hnzvc); fails=fails+1; end
    if (fails == 0) $display("CORE-RTE PASS: PC=%h (->0x1234), SP=%h, hnzvc=%b", pc, r7, hnzvc);
    else            $display("CORE-RTE FAIL: %0d", fails);
    $finish;
  end
endmodule
