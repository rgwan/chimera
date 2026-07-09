// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Byte-register bit operations: direct bit index, register bit index, and C-only
// flag updates.
`timescale 1ns / 1ps
module tb_core_bit_reg;
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
    mem[0] =8'h79; mem[1] =8'h00; mem[2] =8'h00; mem[3] =8'h00; // mov.w #0,R0
    mem[4] =8'h70; mem[5] =8'h08;                              // bset #0,R0L
    mem[6] =8'h71; mem[7] =8'h38;                              // bnot #3,R0L
    mem[8] =8'h72; mem[9] =8'h28;                              // bclr #2,R0L
    mem[10]=8'h07; mem[11]=8'h81;                              // ldc #0x81,ccr
    mem[12]=8'h67; mem[13]=8'h18;                              // bst #1,R0L
    mem[14]=8'h67; mem[15]=8'h88;                              // bist #0,R0L
    mem[16]=8'h79; mem[17]=8'h01; mem[18]=8'h82; mem[19]=8'h00; // mov.w #0x8200,R1
    mem[20]=8'h60; mem[21]=8'h18;                              // bset R1H,R0L
    mem[22]=8'h62; mem[23]=8'h18;                              // bclr R1H,R0L
    mem[24]=8'h61; mem[25]=8'h18;                              // bnot R1H,R0L
    mem[26]=8'h63; mem[27]=8'h18;                              // btst R1H,R0L
    mem[28]=8'h79; mem[29]=8'h02; mem[30]=8'h00; mem[31]=8'h08; // mov.w #8,R2
    mem[32]=8'h79; mem[33]=8'h05; mem[34]=8'h00; mem[35]=8'h00; // mov.w #0,R5
    mem[36]=8'h77; mem[37]=8'h3a;                              // bld #3,R2L
    mem[38]=8'h67; mem[39]=8'h0d;                              // bst #0,R5L
    mem[40]=8'h77; mem[41]=8'hba;                              // bild #3,R2L
    mem[42]=8'h67; mem[43]=8'h1d;                              // bst #1,R5L
    mem[44]=8'h74; mem[45]=8'h88;                              // bior #0,R0L
    mem[46]=8'h67; mem[47]=8'h2d;                              // bst #2,R5L
    mem[48]=8'h75; mem[49]=8'h28;                              // bxor #2,R0L
    mem[50]=8'h67; mem[51]=8'h3d;                              // bst #3,R5L
    mem[52]=8'h77; mem[53]=8'h3a;                              // bld #3,R2L
    mem[54]=8'h76; mem[55]=8'h18;                              // band #1,R0L
    mem[56]=8'h67; mem[57]=8'h4d;                              // bst #4,R5L
    mem[58]=8'h76; mem[59]=8'h98;                              // biand #1,R0L
    mem[60]=8'h67; mem[61]=8'h5d;                              // bst #5,R5L
    mem[62]=8'h40; mem[63]=8'hfe;                              // halt loop
    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (320) @(posedge clock); #1;

    if (r0 !== 16'h000e) begin $display("FAIL R0=%h exp 000e", r0); fails=fails+1; end
    if (r1 !== 16'h8200) begin $display("FAIL R1=%h exp 8200", r1); fails=fails+1; end
    if (r2 !== 16'h0008) begin $display("FAIL R2=%h exp 0008", r2); fails=fails+1; end
    if (r5 !== 16'h0015) begin $display("FAIL R5=%h exp 0015", r5); fails=fails+1; end
    if (hnzvc !== 5'b00100) begin $display("FAIL hnzvc=%b exp 00100", hnzvc); fails=fails+1; end

    if (fails == 0) $display("CORE-BIT-REG PASS: R0=%h R5=%h hnzvc=%b", r0, r5, hnzvc);
    else            $display("CORE-BIT-REG FAIL: %0d", fails);
    $finish;
  end
endmodule
