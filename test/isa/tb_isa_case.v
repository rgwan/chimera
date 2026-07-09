// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Generic ISA-case runner: loads a memory image (+hex=<file>) built by
// check_exec_sail.py (state-preload prologue + the case instruction + NOPs),
// runs, and dumps the final register file and CCR for retire comparison.
`timescale 1ns / 1ps
module tb_isa_case;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  reg [1023:0] hexpath;
  integer     i;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  // store: byte-masked big-endian write
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                    <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end

  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    if (!$value$plusargs("hex=%s", hexpath)) begin $display("NO-HEX"); $finish; end
    $readmemh(hexpath, mem);
    irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (400) @(posedge clock); #1;
    $display("R %h %h %h %h %h %h %h %h",
      dut.h8rf.dbg[15:0],   dut.h8rf.dbg[31:16],  dut.h8rf.dbg[47:32],  dut.h8rf.dbg[63:48],
      dut.h8rf.dbg[79:64],  dut.h8rf.dbg[95:80],  dut.h8rf.dbg[111:96], dut.h8rf.dbg[127:112]);
    $display("C %b", dut.ccr.hnzvc);
    $finish;
  end
endmodule
