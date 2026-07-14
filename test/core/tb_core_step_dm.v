// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Debugger-present single-step. The DM is active; the debugger arms the STEP
// control register (dbgBase word 0) through DM memWrite, then resumes. With a
// debugger present a step fire parks the core in DebugEntry (is_halted rises)
// instead of trapping: exactly one instruction retires per resume. The PC read
// back through the DM advances one instruction each step.
`timescale 1ns / 1ps
module tb_core_step_dm;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  wire        core_sleeping, is_halted;

  reg         dbg_dmactive, dbg_req;
  reg  [2:0]  dbg_cmd;
  reg  [15:0] dbg_addr, dbg_dataFromHost;
  wire        dbg_ack, dbg_halted;
  wire [15:0] dbg_dataToHost;

  integer     i, errors;
  reg  [15:0] pc0, pc1, pc2;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .is_halted(is_halted),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy),
    .dbg_dmactive(dbg_dmactive), .dbg_req(dbg_req), .dbg_cmd(dbg_cmd),
    .dbg_addr(dbg_addr), .dbg_dataFromHost(dbg_dataFromHost),
    .dbg_ack(dbg_ack), .dbg_dataToHost(dbg_dataToHost), .dbg_halted(dbg_halted));

  localparam [2:0] CMD_MEMWR = 3'd1, CMD_HALT = 3'd3, CMD_RESUME = 3'd4,
                   CMD_READPC = 3'd5;

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
      $display("STEP-DM FAIL: %0s pc=%h halted=%b is_halted=%b ack=%b",
               tag, pc, dbg_halted, is_halted, dbg_ack);
    end
  endtask

  reg [15:0] rdpc;
  task dm_cmd(input [2:0] cmd, input [15:0] a, input [15:0] d);
    begin
      dbg_cmd = cmd; dbg_addr = a; dbg_dataFromHost = d; dbg_req = 1'b1;
      i = 0;
      while (!dbg_ack && i < 400) begin @(posedge clock); i = i + 1; end
      check(dbg_ack, "command acked");
      rdpc = dbg_dataToHost;
      dbg_req = 1'b0;
      while (dbg_ack && i < 800) begin @(posedge clock); i = i + 1; end
    end
  endtask

  task dm_resume;
    begin
      dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
      i = 0;
      while (dbg_halted && i < 300) begin @(posedge clock); i = i + 1; end
      dbg_req = 1'b0;
      // Run until the step re-parks the core.
      i = 0;
      while (!is_halted && i < 400) begin @(posedge clock); i = i + 1; end
      repeat (2) @(posedge clock);
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;   // all NOP (1 word each)
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    // Program: three NOPs then a marker. Each NOP is one word (PC += 2).

    errors = 0; irq = 0; nmi = 0; reset = 1;
    dbg_dmactive = 0; dbg_req = 0; dbg_cmd = 0; dbg_addr = 0; dbg_dataFromHost = 0;
    repeat (4) @(posedge clock);
    reset = 0;
    repeat (30) @(posedge clock); #1;
    check(!is_halted, "running before attach");

    // Attach and halt.
    dbg_dmactive = 1'b1;
    repeat (3) @(posedge clock);
    dm_cmd(CMD_HALT, 16'h0000, 16'h0000); #1;
    check(is_halted, "DM halt parked the core");

    // Set PC to 0x0030 and arm continuous single-step via STEP word 0.
    dm_cmd(3'd2 /*SetPc*/, 16'h0030, 16'h0000); #1;    // PC = 0x0030
    dm_cmd(CMD_MEMWR, 16'hFF00, 16'h0001); #1;         // STEP: EN=1 (continuous)

    // Read PC before stepping.
    dm_cmd(CMD_READPC, 16'h0000, 16'h0000); pc0 = rdpc; #1;
    check(pc0 == 16'h0030, "PC starts at 0x0030");

    // Step one instruction: resume, the step parks after one retire.
    dm_resume; #1;
    check(is_halted, "one step re-parked the core in DebugEntry");
    dm_cmd(CMD_READPC, 16'h0000, 16'h0000); pc1 = rdpc; #1;
    check(pc1 == 16'h0032, "PC advanced one instruction (0x0032)");

    // Step again.
    dm_resume; #1;
    check(is_halted, "second step re-parked the core");
    dm_cmd(CMD_READPC, 16'h0000, 16'h0000); pc2 = rdpc; #1;
    check(pc2 == 16'h0034, "PC advanced a second instruction (0x0034)");

    // Disable step, resume: the core must run free (is_halted clears).
    dm_cmd(CMD_MEMWR, 16'hFF00, 16'h0000); #1;         // STEP: EN=0
    dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
    i = 0;
    while (dbg_halted && i < 300) begin @(posedge clock); i = i + 1; end
    dbg_req = 1'b0;
    repeat (10) @(posedge clock); #1;
    check(!is_halted, "step disabled: core runs free");

    if (errors == 0)
      $display("STEP-DM PASS: one instruction per resume, PC advances 0x30->0x32->0x34");
    else
      $display("STEP-DM FAIL: %0d", errors);
    $finish;
  end
endmodule
