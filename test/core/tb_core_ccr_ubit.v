// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// ccr_ubit config: the CCR user bits UI (bit6) and U (bit4) are real storage.
// The direct CCR load path (LDC/ANDC/ORC/XORC) writes them; arithmetic flag
// updates leave them untouched. Build with CCR_UBIT=true.
`timescale 1ns / 1ps
module tb_core_ccr_ubit;
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

  wire [15:0] r0 = dut.h8rf.dbg[15:0];
  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00; // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30; // reset PC = 0x0030
    mem[16'h0030]=8'h07; mem[16'h0031]=8'h50; // ldc #0x50,ccr (UI=1,U=1)
    mem[16'h0032]=8'h02; mem[16'h0033]=8'h08; // stc ccr,R0L
    mem[16'h0034]=8'hf9; mem[16'h0035]=8'h40; // mov.b #0x40,R1L
    mem[16'h0036]=8'h08; mem[16'h0037]=8'h99; // add.b R1L,R1L -> 0x80, N=1 V=1
    mem[16'h0038]=8'h02; mem[16'h0039]=8'h0a; // stc ccr,R2L (user bits kept)
    mem[16'h003a]=8'h07; mem[16'h003b]=8'h00; // ldc #0,ccr (clears user bits)
    mem[16'h003c]=8'h02; mem[16'h003d]=8'h0b; // stc ccr,R3L
    mem[16'h003e]=8'h40; mem[16'h003f]=8'hfe; // halt
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (120) @(posedge clock); #1;

    // R0L = 0x50: UI and U readable after a direct load
    if (r0[7:0] !== 8'h50) begin
      $display("FAIL R0L=%h exp 50 (user bits loadable)", r0[7:0]); fails=fails+1;
    end
    // R2L = 0x5A: {I=0,UI=1,H=0,U=1,N=1,Z=0,V=1,C=0}; add.b kept user bits
    if (r2[7:0] !== 8'h5a) begin
      $display("FAIL R2L=%h exp 5a (flag update kept user bits)", r2[7:0]);
      fails=fails+1;
    end
    // R3L = 0x00: a direct load of zero clears the user bits again
    if (r3[7:0] !== 8'h00) begin
      $display("FAIL R3L=%h exp 00 (user bits clearable)", r3[7:0]); fails=fails+1;
    end

    if (fails == 0) $display("CORE-CCR-UBIT PASS: user bits load, hold, clear");
    else            $display("CORE-CCR-UBIT FAIL: %0d", fails);
    $finish;
  end
endmodule
