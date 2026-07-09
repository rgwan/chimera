// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
`timescale 1ns/1ps

module tb_biu;
  reg  [15:0] addr;
  reg  [15:0] wdata;
  reg  [1:0]  busCtl;
  reg         word;
  wire [15:0] bus_addr;
  wire [15:0] bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we;
  wire [1:0]  bus_wmask;
  wire        bus_req;
  reg         bus_rdy;
  wire [15:0] rdata;
  wire        rdy;

  Biu dut (
    .addr(addr),
    .wdata(wdata),
    .busCtl(busCtl),
    .word(word),
    .bus_addr(bus_addr),
    .bus_wdata(bus_wdata),
    .bus_rdata(bus_rdata),
    .bus_we(bus_we),
    .bus_wmask(bus_wmask),
    .bus_req(bus_req),
    .bus_rdy(bus_rdy),
    .rdata(rdata),
    .rdy(rdy)
  );

  initial begin
    bus_rdata = 16'h1234;
    bus_rdy = 1'b1;

    addr = 16'h0100; wdata = 16'habab; busCtl = 2'd3; word = 1'b0; #1;
    if (bus_addr !== 16'h0100 || bus_wmask !== 2'b10 || !bus_we || !bus_req)
      $fatal(1, "even byte write lane failed");

    addr = 16'h0101; wdata = 16'hcdcd; busCtl = 2'd3; word = 1'b0; #1;
    if (bus_addr !== 16'h0100 || bus_wmask !== 2'b01 || bus_wdata !== 16'hcdcd)
      $fatal(1, "odd byte write lane failed");

    addr = 16'h0101; wdata = 16'hbeef; busCtl = 2'd3; word = 1'b1; #1;
    if (bus_addr !== 16'h0100 || bus_wmask !== 2'b11 || bus_wdata !== 16'hbeef)
      $fatal(1, "word write align failed");

    addr = 16'h0103; wdata = 16'h0000; busCtl = 2'd1; word = 1'b0; #1;
    if (bus_addr !== 16'h0102 || bus_wmask !== 2'b00 || bus_we || !bus_req)
      $fatal(1, "fetch align failed");

    if (rdata !== 16'h1234 || rdy !== 1'b1)
      $fatal(1, "response pass-through failed");

    $display("BIU PASS: big-endian byte lanes");
    $finish;
  end
endmodule
