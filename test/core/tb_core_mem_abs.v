// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Absolute-addressing load/store check: abs8, abs16, byte lanes, and rejected
// legacy peripheral slots.
// Boot follows the platform table: SP from 0x0002, entry PC from 0x0006.
`timescale 1ns / 1ps
module tb_core_mem_abs;
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
  wire [15:0] r1 = dut.h8rf.dbg[31:16];
  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [4:0]  ccr = dut.ccr.hnzvc;

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
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    mem[16'h0030]=8'h07; mem[16'h0031]=8'h23;                                           // ldc #0x23,ccr
    mem[16'h0032]=8'h28; mem[16'h0033]=8'h40;                                           // mov.b @0x40:8,R0L
    mem[16'h0034]=8'h38; mem[16'h0035]=8'h41;                                           // mov.b R0L,@0x41:8
    mem[16'h0036]=8'h6a; mem[16'h0037]=8'h02; mem[16'h0038]=8'h01; mem[16'h0039]=8'h44; // mov.b @0x0144:16,R2H
    mem[16'h003A]=8'h6a; mem[16'h003B]=8'h82; mem[16'h003C]=8'h01; mem[16'h003D]=8'h45; // mov.b R2H,@0x0145:16
    mem[16'h003E]=8'h6b; mem[16'h003F]=8'h01; mem[16'h0040]=8'h01; mem[16'h0041]=8'h40; // mov.w @0x0140:16,R1
    mem[16'h0042]=8'h6b; mem[16'h0043]=8'h81; mem[16'h0044]=8'h01; mem[16'h0045]=8'h42; // mov.w R1,@0x0142:16
    mem[16'h0046]=8'h6a; mem[16'h0047]=8'h48; mem[16'h0048]=8'h01; mem[16'h0049]=8'h40; // rejected base slot
    mem[16'h004A]=8'h6a; mem[16'h004B]=8'hc8; mem[16'h004C]=8'h01; mem[16'h004D]=8'h45; // rejected base slot
    mem[16'h004E]=8'hf4; mem[16'h004F]=8'h55;                                           // mov.b #0x55,R4H
    mem[16'hff40] = 8'h80;
    mem[16'hff41] = 8'haa;
    mem[16'h0140] = 8'h12;
    mem[16'h0141] = 8'h34;
    mem[16'h0142] = 8'haa;
    mem[16'h0143] = 8'h55;
    mem[16'h0144] = 8'h7f;
    mem[16'h0145] = 8'haa;

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (200) @(posedge clock); #1;

    if (r0 !== 16'h0080) begin $display("FAIL R0=%h exp 0080", r0); fails=fails+1; end
    if (r1 !== 16'h1234) begin $display("FAIL R1=%h exp 1234", r1); fails=fails+1; end
    if (r2 !== 16'h7f00) begin $display("FAIL R2=%h exp 7f00", r2); fails=fails+1; end
    if (r4 !== 16'h5500) begin $display("FAIL R4=%h exp 5500", r4); fails=fails+1; end
    if (ccr !== 5'b10001) begin $display("FAIL CCR=%b exp 10001", ccr); fails=fails+1; end
    if (mem[16'hff41] !== 8'h80) begin $display("FAIL MFF41=%h exp 80", mem[16'hff41]); fails=fails+1; end
    if (mem[16'h0142] !== 8'h12 || mem[16'h0143] !== 8'h34) begin
      $display("FAIL M0142=%h M0143=%h exp 12 34", mem[16'h0142], mem[16'h0143]); fails=fails+1; end
    if (mem[16'h0145] !== 8'h7f) begin $display("FAIL M0145=%h exp 7f", mem[16'h0145]); fails=fails+1; end

    if (fails == 0) $display("CORE-MEM-ABS PASS: absolute load/store and base rejects");
    else            $display("CORE-MEM-ABS FAIL: %0d", fails);
    $finish;
  end
endmodule
