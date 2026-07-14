// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Auto-halt-memop-resume: a memRead / memWrite issued while the core is RUNNING
// must auto-halt the core, perform the access, auto-resume, and let the program
// keep executing. A memRead / memWrite issued while already HALTED must leave the
// core halted (original semantics). One host command, no explicit halt/resume.
`timescale 1ns / 1ps
module tb_core_autohalt;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  wire        core_sleeping;

  reg         dbg_dmactive, dbg_req;
  reg  [3:0]  dbg_cmd;
  reg  [15:0] dbg_addr, dbg_dataFromHost;
  wire        dbg_ack, dbg_halted;
  wire [15:0] dbg_dataToHost;

  integer     i, errors;
  reg  [15:0] pc_before;
  reg         saw_halt;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy),
    .dbg_dmactive(dbg_dmactive), .dbg_req(dbg_req), .dbg_cmd(dbg_cmd),
    .dbg_addr(dbg_addr), .dbg_dataFromHost(dbg_dataFromHost),
    .dbg_ack(dbg_ack), .dbg_dataToHost(dbg_dataToHost), .dbg_halted(dbg_halted));

  localparam [3:0] CMD_MEMWR = 4'd1, CMD_HALT = 4'd3, CMD_RESUME = 4'd4,
                   CMD_MEMRD = 4'd6;

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
      $display("AUTOHALT FAIL: %0s pc=%h halted=%b ack=%b toHost=%h",
               tag, pc, dbg_halted, dbg_ack, dbg_dataToHost);
    end
  endtask

  // Issue one command WITHOUT an explicit halt. While the request is up, sample
  // whether the core ever parked (`saw_halt`) so a running command is proven to
  // auto-halt rather than being ignored. Level handshake: hold req until ack.
  task dm_oneshot(input [3:0] cmd, input [15:0] a, input [15:0] d);
    begin
      dbg_cmd = cmd; dbg_addr = a; dbg_dataFromHost = d; dbg_req = 1'b1;
      saw_halt = 1'b0;
      i = 0;
      while (!dbg_ack && i < 400) begin
        @(posedge clock);
        if (dbg_halted) saw_halt = 1'b1;
        i = i + 1;
      end
      check(dbg_ack, "command acked");
      dbg_req = 1'b0;
      while (dbg_ack && i < 800) begin @(posedge clock); i = i + 1; end
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
    // Boot and run NOPs; attach the debugger but do NOT halt.
    repeat (40) @(posedge clock); #1;
    dbg_dmactive = 1'b1;
    repeat (3) @(posedge clock); #1;
    check(!dbg_halted, "running before any command");

    // --- memWrite while RUNNING: auto-halt -> write -> auto-resume ---
    pc_before = pc;
    dm_oneshot(CMD_MEMWR, 16'h0300, 16'hBEEF); #1;
    check(saw_halt, "memwr(run): core auto-halted");
    check({mem[16'h0300], mem[16'h0301]} === 16'hBEEF, "memwr(run): RAM updated");
    check(!dbg_halted, "memwr(run): auto-resumed (not halted)");
    // Let the program run and confirm it keeps executing past the entry point.
    repeat (30) @(posedge clock); #1;
    check(!dbg_halted, "memwr(run): still running after resume");
    check(pc !== pc_before, "memwr(run): PC advanced past command point");

    // --- memRead while RUNNING: auto-halt -> read-back -> auto-resume ---
    pc_before = pc;
    dm_oneshot(CMD_MEMRD, 16'h0300, 16'h0000); #1;
    check(saw_halt, "memrd(run): core auto-halted");
    check(dbg_dataToHost === 16'hBEEF, "memrd(run): data returned to host");
    check(!dbg_halted, "memrd(run): auto-resumed (not halted)");
    repeat (30) @(posedge clock); #1;
    check(!dbg_halted, "memrd(run): still running after resume");
    check(pc !== pc_before, "memrd(run): PC advanced past command point");

    // --- second running access proves the FSM re-arms per command ---
    pc_before = pc;
    dm_oneshot(CMD_MEMWR, 16'h0400, 16'h1234); #1;
    check(saw_halt, "memwr2(run): core auto-halted");
    dm_oneshot(CMD_MEMRD, 16'h0400, 16'h0000); #1;
    check(dbg_dataToHost === 16'h1234, "memrd2(run): second address");
    repeat (20) @(posedge clock); #1;
    check(!dbg_halted, "second access: still running");

    // --- host-initiated HALT then memop: must STAY halted (wasRunning=0) ---
    dm_oneshot(CMD_HALT, 16'h0000, 16'h0000); #1;
    check(dbg_halted, "explicit halt: parked");
    dm_oneshot(CMD_MEMWR, 16'h0500, 16'hCAFE); #1;
    check({mem[16'h0500], mem[16'h0501]} === 16'hCAFE, "halted memwr: RAM updated");
    check(dbg_halted, "halted memwr: stays halted");
    dm_oneshot(CMD_MEMRD, 16'h0500, 16'h0000); #1;
    check(dbg_dataToHost === 16'hCAFE, "halted memrd: data returned");
    check(dbg_halted, "halted memrd: stays halted");

    // Explicit resume returns to running.
    dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
    i = 0;
    while (dbg_halted && i < 200) begin @(posedge clock); i = i + 1; end
    check(!dbg_halted, "explicit resume: running again");
    dbg_req = 1'b0;
    repeat (20) @(posedge clock);

    if (errors == 0)
      $display("AUTOHALT PASS: running memwr/memrd auto-halt-resume, halted stays halted");
    $finish;
  end
endmodule
