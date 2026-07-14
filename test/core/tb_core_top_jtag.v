// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Drives the CoreTop through its JTAG pins only: bit-bang the TAP, read IDCODE,
// halt via CONTROL, poll STATUS for is_halted, round-trip a RAM word through
// CONTROL memWrite/memRead, set and read back the PC, resume, and confirm
// is_halted clears. A synchronous RAM model sits on the core bus.
`timescale 1ns / 1ps
module tb_core_top_jtag;
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

  integer     i, errors;

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

  localparam [3:0] IR_STATUS = 4'h0, IR_IDCODE = 4'h1, IR_CONTROL = 4'h2,
                   IR_BYPASS = 4'hF;
  localparam [3:0] CMD_MEMWR = 4'd1, CMD_SETPC = 4'd2, CMD_HALT = 4'd3,
                   CMD_RESUME = 4'd4, CMD_READPC = 4'd5, CMD_MEMRD = 4'd6;

  wire [15:0] pc = dut.core.intrf.dbgPc;

  task check(input cond, input [255:0] tag);
    if (!cond) begin
      errors = errors + 1;
      $display("JTAG FAIL: %0s pc=%h", tag, pc);
    end
  endtask

  // One TCK cycle: present tms/tdi, let the core clock run several cycles per
  // TCK phase (slow TCK vs fast core), sample tdo (valid before the shift edge),
  // then pulse TCK. The DTM shifts / loads on the rising edge.
  reg sampled;
  task tick(input tms_v, input tdi_v);
    begin
      tms = tms_v; tdi = tdi_v;
      repeat (4) @(posedge clock);
      sampled = tdo;          // LSB currently presented by the selected register
      tck = 1'b1;             // rising edge: shift / load / advance state
      repeat (4) @(posedge clock);
      tck = 1'b0;
      repeat (4) @(posedge clock);
    end
  endtask

  // Move to Test-Logic-Reset (5 TMS=1) then Run-Test/Idle.
  task tap_reset;
    begin
      repeat (5) tick(1'b1, 1'b0);
      tick(1'b0, 1'b0); // -> Run-Test/Idle
    end
  endtask

  // Shift a new IR (from RTI): Select-DR,Select-IR,Capture-IR,Shift-IR..Update.
  task shift_ir(input [3:0] value);
    begin
      tick(1'b1, 1'b0); // RTI -> Select-DR
      tick(1'b1, 1'b0); // -> Select-IR
      tick(1'b0, 1'b0); // -> Capture-IR
      tick(1'b0, 1'b0); // Capture-IR -> Shift-IR (register loaded)
      tick(1'b0, value[0]); // Shift-IR bit0
      tick(1'b0, value[1]);
      tick(1'b0, value[2]);
      tick(1'b1, value[3]); // last bit + exit1
      tick(1'b1, 1'b0); // -> Update-IR
      tick(1'b0, 1'b0); // -> Run-Test/Idle
    end
  endtask

  // Shift a DR of `n` bits: write `wdata`, capture read into `rdata`.
  // The Capture-DR->Shift-DR edge loads the register; from Shift-DR the LSB is
  // presented, so sample-then-shift on each of the n bits.
  reg [63:0] rdata;
  task shift_dr(input integer n, input [63:0] wdata);
    begin
      rdata = 64'd0;
      tick(1'b1, 1'b0); // RTI -> Select-DR
      tick(1'b0, 1'b0); // Select-DR -> Capture-DR
      tick(1'b0, 1'b0); // Capture-DR -> Shift-DR (register now loaded)
      for (i = 0; i < n; i = i + 1) begin
        // tick samples the presented LSB (bit i) before its shift edge.
        tick((i == n - 1) ? 1'b1 : 1'b0, wdata[i]); // shift; last bit -> Exit1
        rdata[i] = sampled;
      end
      tick(1'b1, 1'b0); // Exit1-DR -> Update-DR
      tick(1'b0, 1'b0); // -> Run-Test/Idle
    end
  endtask

  // Assemble a 37-bit CONTROL word: [3:0]cmd [19:4]addr [35:20]data [36]go/ip.
  // On write bit36 is the launch strobe; on read it is in_progress.
  function [63:0] ctl_word(input go, input [3:0] cmd, input [15:0] a, input [15:0] d);
    ctl_word = {27'd0, go, d, a, cmd};
  endfunction

  // Issue a CONTROL command (go=1) then poll in_progress (bit 36) with go=0.
  reg [15:0] ctl_read;
  task control_cmd(input [3:0] cmd, input [15:0] a, input [15:0] d);
    integer guard;
    begin
      shift_ir(IR_CONTROL);
      shift_dr(37, ctl_word(1'b1, cmd, a, d)); // launch
      guard = 0;
      rdata[36] = 1'b1;
      while (rdata[36] && guard < 200) begin
        shift_dr(37, ctl_word(1'b0, cmd, a, d)); // read-only poll (no re-launch)
        guard = guard + 1;
      end
      check(!rdata[36], "control cmd completed");
      ctl_read = rdata[35:20];
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00; // all NOP
    mem[16'h0002] = 8'h02; mem[16'h0003] = 8'h00; // reset SP = 0x0200
    mem[16'h0006] = 8'h00; mem[16'h0007] = 8'h30; // reset PC = 0x0030
    errors = 0; irq = 0; nmi = 0; reset = 1;
    tck = 0; tms = 1; tdi = 0; trst = 1;
    sampled = 0; rdata = 0;
    repeat (4) @(posedge clock);
    reset = 0;
    // The DTM reset is synchronous to TCK: pulse TCK a few times with TRST held
    // so its flops clear, then release TRST.
    repeat (3) begin
      repeat (2) @(posedge clock); tck = 1'b1;
      repeat (2) @(posedge clock); tck = 1'b0;
    end
    trst = 1'b0;
    repeat (20) @(posedge clock);

    // TAP reset, then read IDCODE.
    tap_reset;
    shift_ir(IR_IDCODE);
    shift_dr(32, 64'd0);
    $display("JTAG IDCODE = %h", rdata[31:0]);
    check(rdata[31:0] === 32'h00114514, "IDCODE matches param");

    // Halt the core.
    control_cmd(CMD_HALT, 16'h0000, 16'h0000);

    // Poll STATUS until is_halted (bit0) is set.
    shift_ir(IR_STATUS);
    i = 0; rdata[0] = 1'b0;
    while (!rdata[0] && i < 100) begin shift_dr(23, 64'd0); i = i + 1; end
    check(rdata[0] === 1'b1, "STATUS is_halted set after halt");
    check(rdata[17:2] === 16'hFF00, "STATUS dbg_base = dbgBase param");
    check(rdata[21:18] === 4'd0, "STATUS hwbp_count = 0 (no hardwareBreakpoint)");
    check(rdata[22] === 1'b1, "STATUS dmactive set once a debugger is present");

    // memWrite then memRead round-trip.
    control_cmd(CMD_MEMWR, 16'h0300, 16'hBEEF);
    check({mem[16'h0300], mem[16'h0301]} === 16'hBEEF, "memWrite RAM updated");
    control_cmd(CMD_MEMRD, 16'h0300, 16'h0000);
    check(ctl_read === 16'hBEEF, "memRead returns written word");

    // A second address to prove addr routing.
    control_cmd(CMD_MEMWR, 16'h0400, 16'h1234);
    control_cmd(CMD_MEMRD, 16'h0400, 16'h0000);
    check(ctl_read === 16'h1234, "memRead second address");

    // Set PC then read it back through CONTROL readPC.
    control_cmd(CMD_SETPC, 16'h0040, 16'h0000);
    check(pc === 16'h0040, "setPC updated PC");
    control_cmd(CMD_READPC, 16'h0000, 16'h0000);
    check(ctl_read === 16'h0040, "readPC returns the set PC");

    // Resume and confirm is_halted clears.
    control_cmd(CMD_RESUME, 16'h0000, 16'h0000);
    shift_ir(IR_STATUS);
    i = 0; rdata[0] = 1'b1;
    while (rdata[0] && i < 100) begin shift_dr(23, 64'd0); i = i + 1; end
    check(rdata[0] === 1'b0, "STATUS is_halted clears after resume");

    if (errors == 0)
      $display("JTAG PASS: idcode, halt, memWrite/memRead, setPC, readPC, resume");
    else
      $display("JTAG FAILED with %0d error(s)", errors);
    $finish;
  end

  initial begin
    #5000000;
    $display("JTAG TIMEOUT");
    $finish;
  end
endmodule
