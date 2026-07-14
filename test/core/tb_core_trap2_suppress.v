// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Trap-2 suppression (self-hosted, no debug module). Two hardware breakpoints
// are armed: HWBP0 on a main-program address and HWBP1 on an address INSIDE the
// TRAP #2 handler. HWBP0 fires and enters the handler. While the handler runs,
// the trap-2 suppression FSM must block HWBP1 from re-firing (no nested park /
// no nested trap): the handler runs to completion exactly once and RTE resumes
// the program. After RTE the suppression is lifted; a witness confirms the
// handler ran a single time (R5 == 1) and is_halted stayed low throughout.
`timescale 1ns / 1ps
module tb_core_trap2_suppress;
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
    mem[16'h000E]=8'h00; mem[16'h000F]=8'h98;  // NMI vector -> 0x0098

    // ---- main program at 0x0030: arm HWBP0=0x0050, HWBP1=0x0084 ----
    //   mov.w #0x0050,R0 ; mov.w R0,@0xFF08  (HWBP0 ADDR)
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h00; mem[16'h0032]=8'h00; mem[16'h0033]=8'h50;
    mem[16'h0034]=8'h6b; mem[16'h0035]=8'h80; mem[16'h0036]=8'hFF; mem[16'h0037]=8'h08;
    //   mov.w #0x0001,R0 ; mov.w R0,@0xFF0A  (HWBP0 CTL: EN, instr)
    mem[16'h0038]=8'h79; mem[16'h0039]=8'h00; mem[16'h003A]=8'h00; mem[16'h003B]=8'h01;
    mem[16'h003C]=8'h6b; mem[16'h003D]=8'h80; mem[16'h003E]=8'hFF; mem[16'h003F]=8'h0A;
    //   mov.w #0x0084,R0 ; mov.w R0,@0xFF0C  (HWBP1 ADDR, inside handler)
    mem[16'h0040]=8'h79; mem[16'h0041]=8'h00; mem[16'h0042]=8'h00; mem[16'h0043]=8'h84;
    mem[16'h0044]=8'h6b; mem[16'h0045]=8'h80; mem[16'h0046]=8'hFF; mem[16'h0047]=8'h0C;
    //   mov.w #0x0001,R0 ; mov.w R0,@0xFF0E  (HWBP1 CTL: EN, instr)
    mem[16'h0048]=8'h79; mem[16'h0049]=8'h00; mem[16'h004A]=8'h00; mem[16'h004B]=8'h01;
    mem[16'h004C]=8'h6b; mem[16'h004D]=8'h80; mem[16'h004E]=8'hFF; mem[16'h004F]=8'h0E;
    // marker at 0x0050 (HWBP0 addr): mov.w #0x1234,R4 (runs after handler clears bp).
    mem[16'h0050]=8'h79; mem[16'h0051]=8'h04; mem[16'h0052]=8'h12; mem[16'h0053]=8'h34;
    // spin: bra . at 0x0054
    mem[16'h0054]=8'h40; mem[16'h0055]=8'hFE;

    // ---- trap #2 handler at 0x0080 ----
    //   inc.b R5l  (0x0A0D): entry witness / counter.
    mem[16'h0080]=8'h0A; mem[16'h0081]=8'h0D;
    //   disable HWBP0 so RTE resumes: mov.w #0x0000,R6 ; mov.w R6,@0xFF0A
    mem[16'h0082]=8'h79; mem[16'h0083]=8'h06;               // <- 0x0084 is the 2nd
    mem[16'h0084]=8'h00; mem[16'h0085]=8'h00;               //    word of this instr;
    mem[16'h0086]=8'h6b; mem[16'h0087]=8'h86; mem[16'h0088]=8'hFF; mem[16'h0089]=8'h0A;
    //   also disable HWBP1: mov.w #0x0000,R6 ; mov.w R6,@0xFF0E
    mem[16'h008A]=8'h79; mem[16'h008B]=8'h06; mem[16'h008C]=8'h00; mem[16'h008D]=8'h00;
    mem[16'h008E]=8'h6b; mem[16'h008F]=8'h86; mem[16'h0090]=8'hFF; mem[16'h0091]=8'h0E;
    //   rte
    mem[16'h0092]=8'h56; mem[16'h0093]=8'h70;

    // ---- NMI handler at 0x0098: just rte (nested inside the trap-2 handler) ----
    mem[16'h0098]=8'h56; mem[16'h0099]=8'h70;

    fails = 0; saw_halted = 0; irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;

    // Pulse NMI once, just after the trap-2 handler is entered (PC reaches the
    // handler body). If the NMI's RTE wrongly lifted the suppression, HWBP1 (at
    // 0x0084, still armed at that point) would re-fire and bump R5 past 1.
    i = 0;
    while ((pc !== 16'h0080) && i < 400) begin @(posedge clock); i = i + 1; end
    @(posedge clock);
    nmi = 1'b1; @(posedge clock); nmi = 1'b0;

    repeat (600) @(posedge clock); #1;

    // The handler ran exactly ONCE despite HWBP1 covering an address it fetches.
    if (r5[7:0] !== 8'd1) begin
      $display("TRAP2-SUPPRESS FAIL: handler entry count R5=%h (want 1, nested fire?)", r5);
      fails=fails+1; end
    // The program reached the marker after RTE.
    if (r4 !== 16'h1234) begin
      $display("TRAP2-SUPPRESS FAIL: RTE did not resume the program (R4=%h)", r4);
      fails=fails+1; end
    if (saw_halted) begin
      $display("TRAP2-SUPPRESS FAIL: is_halted asserted in self-hosted mode"); fails=fails+1; end

    if (fails == 0)
      $display("TRAP2-SUPPRESS PASS: handler bp suppressed across a nested NMI, single entry, RTE resumes");
    else
      $display("TRAP2-SUPPRESS FAIL: %0d", fails);
    $finish;
  end
endmodule
