// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Drives the debug-module port directly (no JTAG) and exercises the four P0
// primitives: halt, memory write, memory read-back, set-PC, resume. The core
// boots from the platform table (SP from 0x0002, PC from 0x0006) and runs NOPs
// until halted.
`timescale 1ns / 1ps
module tb_core_debug;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  wire        core_sleeping;

  // Debug-module port.
  reg         dbg_dmactive, dbg_req;
  reg  [2:0]  dbg_cmd;
  reg  [15:0] dbg_addr, dbg_dataFromHost;
  wire        dbg_ack, dbg_halted;
  wire [15:0] dbg_dataToHost;

  integer     i, errors;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy),
    .dbg_dmactive(dbg_dmactive), .dbg_req(dbg_req), .dbg_cmd(dbg_cmd),
    .dbg_addr(dbg_addr), .dbg_dataFromHost(dbg_dataFromHost),
    .dbg_ack(dbg_ack), .dbg_dataToHost(dbg_dataToHost), .dbg_halted(dbg_halted));

  localparam [2:0] CMD_MEMRD = 3'd0, CMD_MEMWR = 3'd1,
                   CMD_SETPC = 3'd2, CMD_HALT = 3'd3, CMD_RESUME = 3'd4;

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
      $display("CORE-DEBUG FAIL: %0s pc=%h halted=%b ack=%b toHost=%h",
               tag, pc, dbg_halted, dbg_ack, dbg_dataToHost);
    end
  endtask

  // Level handshake: raise req until ack, then drop and wait for ack to clear.
  task dm_wait_ack(input [2:0] cmd, input [15:0] a, input [15:0] d);
    begin
      dbg_cmd = cmd; dbg_addr = a; dbg_dataFromHost = d; dbg_req = 1'b1;
      i = 0;
      while (!dbg_ack && i < 200) begin @(posedge clock); i = i + 1; end
      check(dbg_ack, "command acked");
      dbg_req = 1'b0;
      while (dbg_ack && i < 400) begin @(posedge clock); i = i + 1; end
    end
  endtask

  // Resume never returns to the park word, so it clears halted instead of ack.
  task dm_resume;
    begin
      dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
      i = 0;
      while (dbg_halted && i < 200) begin @(posedge clock); i = i + 1; end
      check(!dbg_halted, "resume cleared halted");
      dbg_req = 1'b0;
      repeat (2) @(posedge clock);
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP
    mem[16'h0002] = 8'h02; mem[16'h0003] = 8'h00;  // reset SP = 0x0200
    mem[16'h0006] = 8'h00; mem[16'h0007] = 8'h30;  // reset PC = 0x0030
    errors = 0; irq = 0; nmi = 0; reset = 1;
    dbg_dmactive = 0; dbg_req = 0; dbg_cmd = 0; dbg_addr = 0; dbg_dataFromHost = 0;
    repeat (4) @(posedge clock);
    reset = 0;
    // Boot and run a few NOP fetches.
    repeat (40) @(posedge clock); #1;
    check(!dbg_halted, "running: not halted before debugger attaches");

    // Attach and halt.
    dbg_dmactive = 1'b1;
    repeat (3) @(posedge clock);
    dm_wait_ack(CMD_HALT, 16'h0000, 16'h0000); #1;
    check(dbg_halted, "halt: core parked");

    // Memory write then read-back.
    dm_wait_ack(CMD_MEMWR, 16'h0300, 16'hBEEF); #1;
    check({mem[16'h0300], mem[16'h0301]} === 16'hBEEF, "memwrite: RAM updated");
    dm_wait_ack(CMD_MEMRD, 16'h0300, 16'h0000); #1;
    check(dbg_dataToHost === 16'hBEEF, "memread: data returned to host");

    // A second address to prove addr routing.
    dm_wait_ack(CMD_MEMWR, 16'h0400, 16'h1234); #1;
    dm_wait_ack(CMD_MEMRD, 16'h0400, 16'h0000); #1;
    check(dbg_dataToHost === 16'h1234, "memread: second address");
    check(dbg_halted, "still halted between commands");

    // Set PC.
    dm_wait_ack(CMD_SETPC, 16'h0040, 16'h0000); #1;
    check(pc === 16'h0040, "setpc: PC updated");

    // Resume execution.
    dm_resume; #1;
    repeat (20) @(posedge clock); #1;
    check(!dbg_halted, "resume: running again");
    check(pc !== 16'h0040, "resume: PC advanced from resume point");

    if (errors == 0)
      $display("CORE-DEBUG PASS: halt, memwrite, memread, setpc, resume");
    $finish;
  end
endmodule
