// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Self-hosted hardware breakpoint (no debug module). A program installs an
// instruction breakpoint via the MMIO trigger registers at dbgBase=0xFF00 and a
// TRAP #2 handler at vector 0x0014. When execution reaches the armed address the
// breakpoint fires and redirects to the TRAP #2 handler (not DebugEntry):
// is_halted must stay LOW, the handler runs, and RTE resumes the program.
`timescale 1ns / 1ps
module tb_core_hwbp_selfhosted;
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
  wire [15:0] pc = dut.intrf.dbgPc;

  // The 0xFF00 window is MMIO; the BIU suppresses the external request there, so
  // the model never sees those addresses and its RAM stays out of the window.
  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                      <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end
  // is_halted must never rise in self-hosted mode.
  always @(posedge clock) if (!reset && is_halted) saw_halted <= 1'b1;

  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;   // all NOP
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030
    mem[16'h0014]=8'h00; mem[16'h0015]=8'h80;  // trap #2 vector -> 0x0080

    // ---- main program at 0x0030 ----
    // arm instruction bp on address 0x0050 (the marker instruction below):
    //   mov.w #0x0050,R0 ; mov.w R0,@0xFF08   (HWBP0 ADDR)
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h00; mem[16'h0032]=8'h00; mem[16'h0033]=8'h50;
    mem[16'h0034]=8'h6b; mem[16'h0035]=8'h80; mem[16'h0036]=8'hFF; mem[16'h0037]=8'h08;
    //   mov.w #0x0001,R0 ; mov.w R0,@0xFF0A   (HWBP0 CTL: EN=1, instr)
    mem[16'h0038]=8'h79; mem[16'h0039]=8'h00; mem[16'h003A]=8'h00; mem[16'h003B]=8'h01;
    mem[16'h003C]=8'h6b; mem[16'h003D]=8'h80; mem[16'h003E]=8'hFF; mem[16'h003F]=8'h0A;
    // pad with NOPs up to the marker at 0x0050.
    // marker: mov.w #0x1234,R4  (executes only after the handler clears the bp)
    mem[16'h0050]=8'h79; mem[16'h0051]=8'h04; mem[16'h0052]=8'h12; mem[16'h0053]=8'h34;
    // spin: bra . (branch to self) so PC settles at 0x0054
    mem[16'h0054]=8'h40; mem[16'h0055]=8'hFE;

    // ---- trap #2 handler at 0x0080 ----
    //   mov.w #0x0000,R6 ; mov.w R6,@0xFF0A   (disable the bp so RTE resumes)
    mem[16'h0080]=8'h79; mem[16'h0081]=8'h06; mem[16'h0082]=8'h00; mem[16'h0083]=8'h00;
    mem[16'h0084]=8'h6b; mem[16'h0085]=8'h86; mem[16'h0086]=8'hFF; mem[16'h0087]=8'h0A;
    //   mov.w #0xBEEF,R5   (marker: handler ran)
    mem[16'h0088]=8'h79; mem[16'h0089]=8'h05; mem[16'h008A]=8'hBE; mem[16'h008B]=8'hEF;
    //   rte
    mem[16'h008C]=8'h56; mem[16'h008D]=8'h70;

    fails = 0; saw_halted = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;

    // Run long enough for arm, bp-fire, handler, RTE, resume.
    repeat (400) @(posedge clock); #1;

    if (r5 !== 16'hBEEF) begin
      $display("HWBP-SELF FAIL: handler did not run (R5=%h)", r5); fails=fails+1; end
    if (r4 !== 16'h1234) begin
      $display("HWBP-SELF FAIL: RTE did not resume the marker (R4=%h pc=%h)", r4, pc);
      fails=fails+1; end
    if (saw_halted) begin
      $display("HWBP-SELF FAIL: is_halted asserted in self-hosted mode"); fails=fails+1; end

    if (fails == 0)
      $display("HWBP-SELF PASS: bp -> trap#2 handler, is_halted low, RTE resumes");
    else
      $display("HWBP-SELF FAIL: %0d", fails);
    $finish;
  end
endmodule
