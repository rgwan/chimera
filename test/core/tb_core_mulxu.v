// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// MULXU shift-add checks, including CCR preservation.
`timescale 1ns / 1ps
module tb_core_mulxu;
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
  wire [15:0] r1 = dut.h8rf.dbg[31:16];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];
  wire [15:0] r5 = dut.h8rf.dbg[95:80];
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
    mem[4] =8'h79; mem[5] =8'h03; mem[6] =8'hab; mem[7] =8'h34; // mov.w #0xab34,R3
    mem[8] =8'h07; mem[9] =8'h23;                              // ldc #0x23,ccr
    mem[10]=8'h50; mem[11]=8'h03;                              // mulxu R0H,R3
    mem[12]=8'h02; mem[13]=8'h0d;                              // stc ccr,R5L
    mem[14]=8'h79; mem[15]=8'h00; mem[16]=8'h00; mem[17]=8'hff; // mov.w #0x00ff,R0
    mem[18]=8'h79; mem[19]=8'h01; mem[20]=8'h00; mem[21]=8'h02; // mov.w #0x0002,R1
    mem[22]=8'h07; mem[23]=8'ha5;                              // ldc #0xa5,ccr
    mem[24]=8'h50; mem[25]=8'h81;                              // mulxu R0L,R1
    mem[26]=8'h02; mem[27]=8'h05;                              // stc ccr,R5H
    mem[28]=8'h50; mem[29]=8'h08;                              // rejected alias
    mem[30]=8'h40; mem[31]=8'hfe;                              // halt

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (520) @(posedge clock); #1;

    if (r0 !== 16'h00ff) begin $display("FAIL R0=%h exp 00ff", r0); fails=fails+1; end
    if (r1 !== 16'h01fe) begin $display("FAIL R1=%h exp 01fe", r1); fails=fails+1; end
    if (r3 !== 16'h03a8) begin $display("FAIL R3=%h exp 03a8", r3); fails=fails+1; end
    if (r5 !== 16'ha523) begin $display("FAIL R5=%h exp a523", r5); fails=fails+1; end
    if (hnzvc !== 5'b10101) begin $display("FAIL hnzvc=%b exp 10101", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-MULXU PASS: unsigned byte multiply");
    else            $display("CORE-MULXU FAIL: %0d", fails);
    $finish;
  end
endmodule
