// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Memory-bit prefixes: abs8/r16i read flags and byte RMW writeback.
`timescale 1ns / 1ps
module tb_core_bit_mem;
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

  localparam [15:0] P = 16'h0030;  // program base, past the vector table

  wire [15:0] r1 = dut.h8rf.dbg[31:16];
  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [4:0]  hnzvc = dut.ccr.hnzvc;

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
    // platform vector table: SP from 0x0002, entry PC from 0x0006
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;               // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;               // reset PC = 0x0030
    mem[P+0] =8'h07; mem[P+1] =8'h81;                              // ldc #0x81,ccr
    mem[P+2] =8'h7e; mem[P+3] =8'h40; mem[P+4] =8'h73; mem[P+5] =8'h30; // btst #3,@ff40
    mem[P+6] =8'h7e; mem[P+7] =8'h41; mem[P+8] =8'h77; mem[P+9] =8'h50; // bld #5,@ff41
    mem[P+10]=8'h7e; mem[P+11]=8'h41; mem[P+12]=8'h74; mem[P+13]=8'h90; // bior #1,@ff41
    mem[P+14]=8'h7e; mem[P+15]=8'h41; mem[P+16]=8'h75; mem[P+17]=8'h50; // bxor #5,@ff41
    mem[P+18]=8'h7e; mem[P+19]=8'h41; mem[P+20]=8'h76; mem[P+21]=8'h50; // band #5,@ff41
    mem[P+22]=8'h7f; mem[P+23]=8'h40; mem[P+24]=8'h70; mem[P+25]=8'h20; // bset #2,@ff40
    mem[P+26]=8'hfc; mem[P+27]=8'h01;                              // mov.b #1,R4L
    mem[P+28]=8'h7f; mem[P+29]=8'h41; mem[P+30]=8'h61; mem[P+31]=8'hc0; // bnot R4L,@ff41
    mem[P+32]=8'h07; mem[P+33]=8'h81;                              // ldc #0x81,ccr
    mem[P+34]=8'h7f; mem[P+35]=8'h41; mem[P+36]=8'h67; mem[P+37]=8'h60; // bst #6,@ff41
    mem[P+38]=8'h7f; mem[P+39]=8'h41; mem[P+40]=8'h67; mem[P+41]=8'hf0; // bist #7,@ff41
    mem[P+42]=8'h79; mem[P+43]=8'h01; mem[P+44]=8'h01; mem[P+45]=8'h41; // mov.w #0141,R1
    mem[P+46]=8'h7c; mem[P+47]=8'h10; mem[P+48]=8'h63; mem[P+49]=8'hc0; // btst R4L,@R1
    mem[P+50]=8'h7c; mem[P+51]=8'h10; mem[P+52]=8'h77; mem[P+53]=8'hf0; // bild #7,@R1
    mem[P+54]=8'h7d; mem[P+55]=8'h10; mem[P+56]=8'h72; mem[P+57]=8'h10; // bclr #1,@R1
    mem[P+58]=8'h7d; mem[P+59]=8'h10; mem[P+60]=8'h67; mem[P+61]=8'h70; // bst #7,@R1
    mem[P+62]=8'h40; mem[P+63]=8'hfe;                              // halt loop
    mem[16'hff40] = 8'h00;
    mem[16'hff41] = 8'ha0;
    mem[16'h0141] = 8'h02;

    fails = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (560) @(posedge clock); #1;

    if (r1 !== 16'h0141) begin $display("FAIL R1=%h exp 0141", r1); fails=fails+1; end
    if (r4 !== 16'h0001) begin $display("FAIL R4=%h exp 0001", r4); fails=fails+1; end
    if (hnzvc !== 5'b00001) begin $display("FAIL hnzvc=%b exp 00001", hnzvc); fails=fails+1; end
    if (mem[16'hff40] !== 8'h04) begin $display("FAIL MFF40=%h exp 04", mem[16'hff40]); fails=fails+1; end
    if (mem[16'hff41] !== 8'h62) begin $display("FAIL MFF41=%h exp 62", mem[16'hff41]); fails=fails+1; end
    if (mem[16'h0141] !== 8'h80) begin $display("FAIL M0141=%h exp 80", mem[16'h0141]); fails=fails+1; end

    if (fails == 0) $display("CORE-BIT-MEM PASS: memory-bit prefixes");
    else            $display("CORE-BIT-MEM FAIL: %0d", fails);
    $finish;
  end
endmodule
