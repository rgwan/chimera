// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// IRQ0 entry pushes PC and CCR, vectors through the 0x0018 table slot, then RTE
// restores the interrupted context.
`timescale 1ns / 1ps
module tb_core_irq_entry;
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

  wire [15:0] r1    = dut.h8rf.dbg[31:16];
  wire [15:0] r2    = dut.h8rf.dbg[47:32];
  wire [15:0] r7    = dut.h8rf.dbg[127:112];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;
  wire        iflag = dut.ccr.iFlag;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                      <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;             // reset SP = 0x0200
    mem[16'h0006]=8'h01; mem[16'h0007]=8'h00;             // reset PC = 0x0100
    mem[16'h0018]=8'h01; mem[16'h0019]=8'h20;             // IRQ0 vector -> 0x0120
    mem[16'h0100]=8'h79; mem[16'h0101]=8'h07;             // mov.w #0x0200,R7
    mem[16'h0102]=8'h02; mem[16'h0103]=8'h00;
    mem[16'h0104]=8'h79; mem[16'h0105]=8'h01;             // mov.w #0xBEEF,R1
    mem[16'h0106]=8'hBE; mem[16'h0107]=8'hEF;
    mem[16'h0108]=8'h07; mem[16'h0109]=8'h2B;             // ldc #0x2B,ccr
    mem[16'h010A]=8'h40; mem[16'h010B]=8'hFE;             // halt: bra -2
    mem[16'h0120]=8'h79; mem[16'h0121]=8'h02;             // handler: mov.w #0xCAFE,R2
    mem[16'h0122]=8'hCA; mem[16'h0123]=8'hFE;
    mem[16'h0124]=8'h56; mem[16'h0125]=8'h70;             // rte

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (40) @(posedge clock);
    irq = 1; repeat (2) @(posedge clock); irq = 0;
    repeat (120) @(posedge clock); #1;

    if (r1 !== 16'hBEEF) begin $display("FAIL R1=%h exp BEEF", r1); fails=fails+1; end
    if (r2 !== 16'hCAFE) begin $display("FAIL R2=%h exp CAFE", r2); fails=fails+1; end
    if (r7 !== 16'h0200) begin $display("FAIL R7=%h exp 0200", r7); fails=fails+1; end
    if (hnzvc !== 5'b11011) begin $display("FAIL hnzvc=%b exp 11011", hnzvc); fails=fails+1; end
    if (iflag !== 1'b0) begin $display("FAIL I=%b exp 0 after RTE", iflag); fails=fails+1; end
    if (mem[16'h01FC] !== 8'h2B || mem[16'h01FD] !== 8'h00) begin
      $display("FAIL stacked CCR=%h%h exp 2B00", mem[16'h01FC], mem[16'h01FD]);
      fails=fails+1;
    end
    if (mem[16'h01FE] !== 8'h01 || mem[16'h01FF] !== 8'h0A) begin
      $display("FAIL stacked PC=%h%h exp 010A", mem[16'h01FE], mem[16'h01FF]);
      fails=fails+1;
    end
    if (fails == 0)
      $display("CORE-IRQ-ENTRY PASS: vector entry, frame, RTE restore");
    else
      $display("CORE-IRQ-ENTRY FAIL: %0d", fails);
    $finish;
  end
endmodule
