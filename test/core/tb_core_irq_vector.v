// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// NMI vectors through table address 6 and bypasses CCR.I; IRQ0 vectors through
// table address 8 and remains pending when NMI is serviced first.
`timescale 1ns / 1ps
module tb_core_irq_vector;
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

  wire [15:0] r1    = dut.h8rf.dbg[31:16];
  wire [15:0] r2    = dut.h8rf.dbg[47:32];
  wire [15:0] r7    = dut.h8rf.dbg[127:112];
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

  task load_program;
    input [7:0] ccr_init;
    begin
      for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
      mem[16'h0006]=8'h01; mem[16'h0007]=8'h30;           // NMI vector -> 0x0130
      mem[16'h0008]=8'h01; mem[16'h0009]=8'h20;           // IRQ0 vector -> 0x0120
      mem[16'h0100]=8'h79; mem[16'h0101]=8'h07;           // mov.w #0x0200,R7
      mem[16'h0102]=8'h02; mem[16'h0103]=8'h00;
      mem[16'h0104]=8'h07; mem[16'h0105]=ccr_init;        // ldc #ccr_init,ccr
      mem[16'h0106]=8'h40; mem[16'h0107]=8'hFE;           // halt: bra -2
      mem[16'h0120]=8'h79; mem[16'h0121]=8'h01;           // irq: mov.w #0x1111,R1
      mem[16'h0122]=8'h11; mem[16'h0123]=8'h11;
      mem[16'h0124]=8'h56; mem[16'h0125]=8'h70;           // rte
      mem[16'h0130]=8'h79; mem[16'h0131]=8'h02;           // nmi: mov.w #0x2222,R2
      mem[16'h0132]=8'h22; mem[16'h0133]=8'h22;
      mem[16'h0134]=8'h56; mem[16'h0135]=8'h70;           // rte
    end
  endtask

  task reset_core;
    begin
      irq = 0; nmi = 0; reset = 1;
      repeat (4) @(posedge clock);
      reset = 0;
      repeat (36) @(posedge clock);
    end
  endtask

  task pulse_nmi;
    begin
      nmi = 1; repeat (2) @(posedge clock); nmi = 0;
    end
  endtask

  task pulse_both;
    begin
      irq = 1; nmi = 1; repeat (2) @(posedge clock); irq = 0; nmi = 0;
    end
  endtask

  initial begin
    fails = 0;

    load_program(8'h80);
    reset_core();
    pulse_nmi();
    repeat (150) @(posedge clock); #1;
    if (r2 !== 16'h2222) begin $display("FAIL nmi r2=%h exp 2222", r2); fails=fails+1; end
    if (r1 !== 16'h0000) begin $display("FAIL masked irq ran r1=%h", r1); fails=fails+1; end
    if (r7 !== 16'h0200) begin $display("FAIL nmi R7=%h exp 0200", r7); fails=fails+1; end
    if (iflag !== 1'b1) begin $display("FAIL nmi I=%b exp 1", iflag); fails=fails+1; end

    load_program(8'h00);
    reset_core();
    pulse_both();
    repeat (240) @(posedge clock); #1;
    if (r2 !== 16'h2222) begin $display("FAIL priority nmi r2=%h exp 2222", r2); fails=fails+1; end
    if (r1 !== 16'h1111) begin $display("FAIL pending irq r1=%h exp 1111", r1); fails=fails+1; end
    if (r7 !== 16'h0200) begin $display("FAIL both R7=%h exp 0200", r7); fails=fails+1; end
    if (iflag !== 1'b0) begin $display("FAIL both I=%b exp 0", iflag); fails=fails+1; end

    if (fails == 0)
      $display("CORE-IRQ-VECTOR PASS: NMI and IRQ vectors selected");
    else
      $display("CORE-IRQ-VECTOR FAIL: %0d", fails);
    $finish;
  end
endmodule
