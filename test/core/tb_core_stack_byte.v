// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Byte pre-decrement / post-increment round trip.
`timescale 1ns / 1ps
module tb_core_stack_byte;
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
  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];
  wire [4:0]  ccr = dut.ccr.hnzvc;

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
    mem[0] =8'h79; mem[1] =8'h01; mem[2] =8'h02; mem[3] =8'h00; // mov.w #0x0200,R1
    mem[4] =8'h79; mem[5] =8'h02; mem[6] =8'h02; mem[7] =8'h02; // mov.w #0x0202,R2
    mem[8] =8'h07; mem[9] =8'h23;                              // ldc #0x23,ccr
    mem[10]=8'h6c; mem[11]=8'h18;                              // mov.b @R1+,R0L
    mem[12]=8'h6c; mem[13]=8'ha8;                              // mov.b R0L,@-R2
    mem[14]=8'h79; mem[15]=8'h03; mem[16]=8'h01; mem[17]=8'h41; // mov.w #0x0141,R3
    mem[18]=8'h6c; mem[19]=8'hbb;                              // mov.b R3L,@-R3
    mem[20]=8'h40; mem[21]=8'hfe;                              // halt
    mem[16'h0140] = 8'haa;
    mem[16'h0141] = 8'h55;
    mem[16'h0200] = 8'h80;
    mem[16'h0201] = 8'h55;

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (130) @(posedge clock); #1;

    if (r0 !== 16'h0080) begin $display("FAIL R0=%h exp 0080", r0); fails=fails+1; end
    if (r1 !== 16'h0201) begin $display("FAIL R1=%h exp 0201", r1); fails=fails+1; end
    if (r2 !== 16'h0201) begin $display("FAIL R2=%h exp 0201", r2); fails=fails+1; end
    if (r3 !== 16'h0140) begin $display("FAIL R3=%h exp 0140", r3); fails=fails+1; end
    if (mem[16'h0200] !== 8'h80 || mem[16'h0201] !== 8'h80) begin
      $display("FAIL mem[0200]=%h mem[0201]=%h exp 80 80",
        mem[16'h0200], mem[16'h0201]); fails=fails+1; end
    if (mem[16'h0140] !== 8'h41 || mem[16'h0141] !== 8'h55) begin
      $display("FAIL mem[0140]=%h mem[0141]=%h exp 41 55",
        mem[16'h0140], mem[16'h0141]); fails=fails+1; end
    if (ccr !== 5'b10001) begin $display("FAIL CCR=%b exp 10001", ccr); fails=fails+1; end

    if (fails == 0) $display("CORE-STACK-BYTE PASS: byte pre/post memory ops");
    else            $display("CORE-STACK-BYTE FAIL: %0d", fails);
    $finish;
  end
endmodule
