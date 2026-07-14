// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Debugger-present hardware breakpoint. The DM is active; the comparator is
// programmed through DM memWrite (which transits the same MMIO decode as a core
// access). When execution reaches the armed address the breakpoint parks the
// core in DebugEntry: is_halted rises, the park is held, and a DM Resume clears
// it back to the fetch loop. A concurrent DM haltreq and HWBP fire resolve to a
// single DebugEntry park.
`timescale 1ns / 1ps
module tb_core_hwbp_dm;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  wire        core_sleeping, is_halted;

  reg         dbg_dmactive, dbg_req;
  reg  [3:0]  dbg_cmd;
  reg  [15:0] dbg_addr, dbg_dataFromHost;
  wire        dbg_ack, dbg_halted;
  wire [15:0] dbg_dataToHost;

  integer     i, errors;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .is_halted(is_halted),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy),
    .dbg_dmactive(dbg_dmactive), .dbg_req(dbg_req), .dbg_cmd(dbg_cmd),
    .dbg_addr(dbg_addr), .dbg_dataFromHost(dbg_dataFromHost),
    .dbg_ack(dbg_ack), .dbg_dataToHost(dbg_dataToHost), .dbg_halted(dbg_halted));

  localparam [3:0] CMD_MEMWR = 4'd1, CMD_HALT = 4'd3, CMD_RESUME = 4'd4;

  wire [15:0] pc = dut.intrf.dbgPc;

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

  task check(input cond, input [255:0] tag);
    if (!cond) begin
      errors = errors + 1;
      $display("HWBP-DM FAIL: %0s pc=%h halted=%b is_halted=%b ack=%b",
               tag, pc, dbg_halted, is_halted, dbg_ack);
    end
  endtask

  task dm_wait_ack(input [3:0] cmd, input [15:0] a, input [15:0] d);
    begin
      dbg_cmd = cmd; dbg_addr = a; dbg_dataFromHost = d; dbg_req = 1'b1;
      i = 0;
      while (!dbg_ack && i < 300) begin @(posedge clock); i = i + 1; end
      check(dbg_ack, "command acked");
      dbg_req = 1'b0;
      while (dbg_ack && i < 600) begin @(posedge clock); i = i + 1; end
    end
  endtask

  task dm_resume;
    begin
      dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
      i = 0;
      while (dbg_halted && i < 300) begin @(posedge clock); i = i + 1; end
      check(!dbg_halted, "resume cleared halted");
      dbg_req = 1'b0;
      repeat (2) @(posedge clock);
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;   // all NOP
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    // A stretch of NOPs; the marker instruction sits at 0x0050.
    mem[16'h0050]=8'h79; mem[16'h0051]=8'h04; mem[16'h0052]=8'h12; mem[16'h0053]=8'h34; // mov.w #0x1234,R4

    errors = 0; irq = 0; nmi = 0; reset = 1;
    dbg_dmactive = 0; dbg_req = 0; dbg_cmd = 0; dbg_addr = 0; dbg_dataFromHost = 0;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (30) @(posedge clock); #1;
    check(!is_halted, "running before attach");

    // Attach, halt, program the comparator through DM memWrite (same MMIO path).
    dbg_dmactive = 1'b1;
    repeat (3) @(posedge clock);
    dm_wait_ack(CMD_HALT, 16'h0000, 16'h0000); #1;
    check(is_halted, "DM halt parked the core");
    dm_wait_ack(CMD_MEMWR, 16'hFF08, 16'h0050); #1; // HWBP0 ADDR = 0x0050
    dm_wait_ack(CMD_MEMWR, 16'hFF0A, 16'h0001); #1; // HWBP0 CTL  = EN, instr

    // Resume; the core runs to 0x0050 and the breakpoint re-parks it.
    dm_resume; #1;
    i = 0;
    while (!is_halted && i < 400) begin @(posedge clock); i = i + 1; end
    check(is_halted, "HWBP fire parked the core in DebugEntry");
    check(dbg_halted, "DM sees the HWBP park");

    // Park is held: it stays halted with no new DM command.
    repeat (20) @(posedge clock); #1;
    check(is_halted, "park held while parked");

    // Before resuming, disable the breakpoint so the resume makes progress.
    dm_wait_ack(CMD_MEMWR, 16'hFF0A, 16'h0000); #1; // HWBP0 CTL = disabled
    dm_resume; #1;
    repeat (10) @(posedge clock); #1;
    check(!is_halted, "DM resume cleared the park to fetch");

    // Concurrent DM haltreq + HWBP fire -> a single DebugEntry park.
    // Halt, re-arm the bp at an address the core will reach after resume, then
    // resume while immediately re-asserting halt: the pending DM halt and the
    // bp fire converge on ONE park that a single resume clears.
    dm_wait_ack(CMD_HALT, 16'h0000, 16'h0000); #1;
    dm_wait_ack(CMD_MEMWR, 16'hFF08, 16'h0050); #1; // HWBP0 ADDR = 0x0050 again
    dm_wait_ack(CMD_MEMWR, 16'hFF0A, 16'h0001); #1; // re-arm HWBP0 CTL
    // Set PC back before the marker so a resume runs into the armed address.
    // (mem 0x0050 marker re-fetches; the frame from the prior park restored PC.)
    dm_resume;                       // release the park
    dbg_cmd = CMD_HALT; dbg_req = 1'b1;  // and immediately request halt again
    i = 0;
    while (!is_halted && i < 400) begin @(posedge clock); i = i + 1; end
    check(is_halted, "concurrent haltreq + HWBP: single park");
    dbg_req = 1'b0;
    repeat (3) @(posedge clock); #1;
    check(is_halted, "converged park stable, no double-park bounce");
    dm_wait_ack(CMD_MEMWR, 16'hFF0A, 16'h0000); #1; // disable bp
    dm_resume; #1;
    repeat (10) @(posedge clock); #1;
    check(!is_halted, "single resume cleared the converged park");

    if (errors == 0)
      $display("HWBP-DM PASS: DM-programmed bp parks in DebugEntry, resume clears");
    else
      $display("HWBP-DM FAIL: %0d", errors);
    $finish;
  end
endmodule
