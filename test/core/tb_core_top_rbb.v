// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Simulation harness that exposes the CoreTop JTAG TAP over a TCP socket using
// the remote-bitbang single-char protocol (see rbb_vpi.c). An external host
// tool (jtag2gdb, sim_socket backend) connects and bit-bangs the DUT. A
// synchronous RAM model sits on the core bus, matching tb_core_top_jtag.v.
`timescale 1ns / 1ps
module tb_core_top_rbb;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  wire        core_sleeping;

  reg         tck, tms, tdi, trst;
  wire        tdo;

  integer     i, port;

  CoreTop dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy),
    .tck(tck), .trst(trst), .tms(tms), .tdi(tdi), .tdo(tdo));

  // Core-domain bus: combinational read, synchronous write.
  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                      <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end

  initial clock = 0;
  always #5 clock = ~clock; // 100 MHz core

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP
    mem[16'h0002] = 8'h02; mem[16'h0003] = 8'h00; // reset SP = 0x0200
    mem[16'h0006] = 8'h00; mem[16'h0007] = 8'h30; // reset PC = 0x0030
    irq = 0; nmi = 0; reset = 1;
    tck = 0; tms = 1; tdi = 0; trst = 1;

    if (!$value$plusargs("port=%d", port)) port = 2542;

    // The DTM reset is synchronous to TCK: pulse TCK with TRST asserted so the
    // TCK-domain flops clear to defined values before the core sees the debug
    // port. Otherwise the uninitialised DTM outputs (req/cmd/dmactive) drive X
    // into the core once reset releases.
    repeat (4) @(posedge clock);
    repeat (3) begin
      repeat (2) @(posedge clock); tck = 1'b1;
      repeat (2) @(posedge clock); tck = 1'b0;
    end
    reset = 0;
    repeat (20) @(posedge clock);
    // Wait for the host tool to attach, then service one command per core clock.
    $rbb_listen(port);
    forever begin
      @(posedge clock);
      $rbb_step(tdo);
    end
  end

  // Safety timeout so a stuck run cannot hang CI.
  initial begin
    #2000000000; // 2 ms sim time
    $display("RBB TIMEOUT");
    $finish;
  end
endmodule
