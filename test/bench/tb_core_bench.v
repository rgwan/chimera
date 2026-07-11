// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Benchmark harness: loads a +hex image, echoes the MMIO console, latches
// the cycle counter on the timing writes, and finishes on the exit write.
`timescale 1ns / 1ps
module tb_core_bench;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  reg  [63:0] cycles, start_c, stop_c, max_cycles;
  reg  [1023:0] hexfile;
  integer     i;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [15:0] MMIO_BASE = 16'hff80;

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  wire mmio = bus_addr >= MMIO_BASE;
  always @(posedge clock) if (bus_req && bus_we && !mmio) begin
    if (bus_wmask[1]) mem[bus_addr]                      <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  initial clock = 0;
  always #5 clock = ~clock;

  always @(posedge clock) if (!reset) begin
    cycles <= cycles + 1;
    if (bus_req && bus_we && mmio) case (bus_addr)
      16'hff80: $write("%c", bus_wdata[7:0]);
      16'hff84: start_c <= cycles;
      16'hff86: stop_c  <= cycles;
      16'hff88: begin
        $display("");
        $display("BENCH-EXIT code=%0d start=%0d stop=%0d cycles=%0d",
                 bus_wdata, start_c, stop_c, stop_c - start_c);
        $finish;
      end
    endcase
    if (cycles >= max_cycles) begin
      $display("BENCH-TIMEOUT at %0d cycles", cycles);
      $finish;
    end
  end

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    if (!$value$plusargs("hex=%s", hexfile)) begin
      $display("BENCH-FAIL: +hex=<image> required"); $finish;
    end
    $readmemh(hexfile, mem);
    if (!$value$plusargs("max_cycles=%d", max_cycles)) max_cycles = 64'd50000000;
    cycles = 0; start_c = 0; stop_c = 0;
    irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
  end
endmodule
