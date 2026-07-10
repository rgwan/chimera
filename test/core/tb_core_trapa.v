// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns / 1ps
module tb_core_trapa;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  reg  [15:0] write_addr [0:5];
  reg  [15:0] write_data [0:5];
  reg  [1:0]  write_mask [0:5];
  reg         saw_vec0, saw_vec1, saw_vec2, saw_vec3, saw_nmi;
  integer     i, fails, write_count;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  wire [15:0] r0 = dut.h8rf.dbg[15:0];
  wire [15:0] r1 = dut.h8rf.dbg[31:16];
  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];
  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [15:0] r5 = dut.h8rf.dbg[95:80];
  wire [15:0] r6 = dut.h8rf.dbg[111:96];
  wire [15:0] r7 = dut.h8rf.dbg[127:112];
  wire [15:0] pc = dut.intrf.dbgPc;
  wire [8:0]  upc = dut.useq.cur;

  always @(*) begin
    bus_rdy = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hffff]};
  end

  always @(posedge clock) if (bus_req) begin
    if (bus_we) begin
      if (write_count < 6) begin
        write_addr[write_count] <= bus_addr;
        write_data[write_count] <= bus_wdata;
        write_mask[write_count] <= bus_wmask;
      end
      write_count <= write_count + 1;
      if (bus_wmask[1]) mem[bus_addr] <= bus_wdata[15:8];
      if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hffff] <= bus_wdata[7:0];
    end else begin
      if (bus_addr == 16'h0006) saw_nmi <= 1'b1;
      if (bus_addr == 16'h0008) saw_vec0 <= 1'b1;
      if (bus_addr == 16'h000a) saw_vec1 <= 1'b1;
      if (bus_addr == 16'h000c) saw_vec2 <= 1'b1;
      if (bus_addr == 16'h000e) saw_vec3 <= 1'b1;
    end
  end

  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0006]=8'h01; mem[16'h0007]=8'h60;
    mem[16'h0008]=8'h01; mem[16'h0009]=8'h20;
    mem[16'h000a]=8'h01; mem[16'h000b]=8'h30;
    mem[16'h000c]=8'h01; mem[16'h000d]=8'h50;
    mem[16'h000e]=8'h01; mem[16'h000f]=8'h40;

    mem[16'h0100]=8'h79; mem[16'h0101]=8'h07;
    mem[16'h0102]=8'h02; mem[16'h0103]=8'h00;
    mem[16'h0104]=8'h57; mem[16'h0105]=8'h21;
    mem[16'h0106]=8'hf1; mem[16'h0107]=8'h55;
    mem[16'h0108]=8'h07; mem[16'h0109]=8'ha5;
    mem[16'h010a]=8'h57; mem[16'h010b]=8'h00;
    mem[16'h010c]=8'hf9; mem[16'h010d]=8'h11;
    mem[16'h010e]=8'h57; mem[16'h010f]=8'h10;
    mem[16'h0110]=8'hfa; mem[16'h0111]=8'h22;
    mem[16'h0112]=8'h57; mem[16'h0113]=8'h30;
    mem[16'h0114]=8'hfb; mem[16'h0115]=8'h33;
    mem[16'h0116]=8'h57; mem[16'h0117]=8'h20;
    mem[16'h0118]=8'hfe; mem[16'h0119]=8'h44;

    mem[16'h0120]=8'hf8; mem[16'h0121]=8'ha0;
    mem[16'h0122]=8'h56; mem[16'h0123]=8'h70;
    mem[16'h0130]=8'hfc; mem[16'h0131]=8'ha1;
    mem[16'h0132]=8'h56; mem[16'h0133]=8'h70;
    mem[16'h0140]=8'hfd; mem[16'h0141]=8'ha3;
    mem[16'h0142]=8'h56; mem[16'h0143]=8'h70;
    mem[16'h0150]=8'hfe; mem[16'h0151]=8'he2;
    mem[16'h0152]=8'h56; mem[16'h0153]=8'h70;
    mem[16'h0160]=8'hfe; mem[16'h0161]=8'hee;
    mem[16'h0162]=8'h56; mem[16'h0163]=8'h70;

    fails = 0; write_count = 0;
    saw_vec0 = 0; saw_vec1 = 0; saw_vec2 = 0; saw_vec3 = 0; saw_nmi = 0;
    irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;

    wait (bus_req && !bus_we && bus_addr == 16'h0116);
    nmi = 1;
    repeat (2) @(posedge clock);
    nmi = 0;
    repeat (100) @(posedge clock); #1;

    if (r0 !== 16'h00a0 || r1 !== 16'h5511 || r2 !== 16'h0022 ||
        r3 !== 16'h0033 || r4 !== 16'h00a1 || r5 !== 16'h00a3 ||
        r6 !== 16'h0000)
      begin $display("FAIL registers %h %h %h %h %h %h %h", r0, r1, r2, r3, r4, r5, r6); fails=fails+1; end
    if (r7 !== 16'h0200) begin $display("FAIL SP=%h", r7); fails=fails+1; end
    if (pc !== 16'h0118 || upc !== 9'h089)
      begin $display("FAIL debug pc=%h upc=%h", pc, upc); fails=fails+1; end
    if (!dut.irqctl.nmiLatch || dut.useq.trapPend)
      begin $display("FAIL pending nmi=%b trap=%b", dut.irqctl.nmiLatch, dut.useq.trapPend); fails=fails+1; end
    if (!saw_vec0 || !saw_vec1 || !saw_vec3 || saw_vec2 || saw_nmi)
      begin $display("FAIL vectors nmi=%b v0=%b v1=%b v2=%b v3=%b", saw_nmi, saw_vec0, saw_vec1, saw_vec2, saw_vec3); fails=fails+1; end
    if (write_count !== 6) begin $display("FAIL write count=%0d", write_count); fails=fails+1; end
    for (i = 0; i < 6; i = i + 1) begin
      if (write_addr[i] !== ((i & 1) ? 16'h01fc : 16'h01fe) || write_mask[i] !== 2'b11)
        begin $display("FAIL write[%0d] addr=%h mask=%b", i, write_addr[i], write_mask[i]); fails=fails+1; end
    end
    if (write_data[0] !== 16'h010c || write_data[1] !== 16'ha500 ||
        write_data[2] !== 16'h0110 || write_data[3] !== 16'ha100 ||
        write_data[4] !== 16'h0114 || write_data[5] !== 16'ha100)
      begin $display("FAIL frame data %h %h %h %h %h %h", write_data[0], write_data[1], write_data[2], write_data[3], write_data[4], write_data[5]); fails=fails+1; end

    if (fails == 0)
      $display("CORE-TRAPA PASS: strict decode, IRQ vectors, frame, debug priority");
    else
      $display("CORE-TRAPA FAIL: %0d", fails);
    $finish;
  end
endmodule
