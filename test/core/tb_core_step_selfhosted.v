// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Self-hosted single-step (no debug module). A program arms one-shot single-step
// through the MMIO STEP register at dbgBase=0xFF00, then executes a run of NOPs.
// Each retired instruction fires the step, which redirects to the TRAP #2 handler
// (not DebugEntry): is_halted must stay LOW. The handler counts the steps and
// re-arms one-shot for a fixed number of iterations, then leaves STEP disabled so
// the program runs on to a marker. A step fire is suppressed while the handler
// itself runs, so the handler's own instructions never re-trigger the step.
`timescale 1ns / 1ps
module tb_core_step_selfhosted;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  wire        core_sleeping, is_halted;
  integer     i, fails;
  reg         saw_halted;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .is_halted(is_halted),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [15:0] r5 = dut.h8rf.dbg[95:80];

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                      <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  always @(posedge clock) if (!reset && is_halted) saw_halted <= 1'b1;

  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;   // all NOP
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    mem[16'h0014]=8'h00; mem[16'h0015]=8'h80;  // trap #2 vector -> 0x0080

    // ---- main program at 0x0030 ----
    //   mov.w #0x0003,R0 ; mov.w R0,@0xFF00  (STEP: EN=1, ONESHOT=1)
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h00; mem[16'h0032]=8'h00; mem[16'h0033]=8'h03;
    mem[16'h0034]=8'h6b; mem[16'h0035]=8'h80; mem[16'h0036]=8'hFF; mem[16'h0037]=8'h00;
    // A run of NOPs from 0x0038 upward; each retired instruction steps.
    // marker: mov.w #0x1234,R4 at 0x0050 (executes once STEP is left disabled).
    mem[16'h0050]=8'h79; mem[16'h0051]=8'h04; mem[16'h0052]=8'h12; mem[16'h0053]=8'h34;
    // spin: bra . (branch to self) so PC settles at 0x0054
    mem[16'h0054]=8'h40; mem[16'h0055]=8'hFE;

    // ---- trap #2 handler at 0x0080 ----
    //   inc.b R5l  (0x0A0D): count this step.  (R5 low byte = reg field 0x0D)
    mem[16'h0080]=8'h0A; mem[16'h0081]=8'h0D;
    //   cmp.b #4,R5l (0xAD04): have we stepped 4 times?  (0xA0|0xD, imm)
    mem[16'h0082]=8'hAD; mem[16'h0083]=8'h04;
    //   beq 0x008E (skip re-arm)  (0x47 offset +8 to 0x008E)
    mem[16'h0084]=8'h47; mem[16'h0085]=8'h08;
    //   re-arm one-shot: mov.w #0x0003,R6 ; mov.w R6,@0xFF00
    mem[16'h0086]=8'h79; mem[16'h0087]=8'h06; mem[16'h0088]=8'h00; mem[16'h0089]=8'h03;
    mem[16'h008A]=8'h6b; mem[16'h008B]=8'h86; mem[16'h008C]=8'hFF; mem[16'h008D]=8'h00;
    //   rte (0x008E)
    mem[16'h008E]=8'h56; mem[16'h008F]=8'h70;

    fails = 0; saw_halted = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;

    repeat (900) @(posedge clock); #1;

    // The handler ran exactly 4 times (R5 low byte == 4).
    if (r5[7:0] !== 8'd4) begin
      $display("STEP-SELF FAIL: step count R5=%h (want 4)", r5); fails=fails+1; end
    // The marker instruction ran once STEP was left disabled.
    if (r4 !== 16'h1234) begin
      $display("STEP-SELF FAIL: program did not reach the marker (R4=%h)", r4);
      fails=fails+1; end
    if (saw_halted) begin
      $display("STEP-SELF FAIL: is_halted asserted in self-hosted mode"); fails=fails+1; end

    if (fails == 0)
      $display("STEP-SELF PASS: step -> trap#2 handler x4, is_halted low, program resumes");
    else
      $display("STEP-SELF FAIL: %0d", fails);
    $finish;
  end
endmodule
