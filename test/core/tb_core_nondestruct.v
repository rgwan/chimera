// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Non-destructive CCR / register reads via the debug module. A short program
// sets known GPRs and a known CCR, then spins. The debugger halts, reads CCR
// (ReadCcr returns the CCR captured at park entry) and reads every GPR through
// the program-buffer path (which resumes an injected MOV snippet ending in
// TRAPA#2, perturbing the live N/Z/V flags). On the final resume the microcode
// restores CCR from the value captured at session entry, so architectural CCR
// and all GPRs are pristine: ReadCcr == the loaded CCR, and ccrByte after
// resume equals it, with no GPR changed.
`timescale 1ns / 1ps
module tb_core_nondestruct;
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

  integer     i, n, errors;
  reg  [7:0]  ccr_read, ccr_after;
  reg  [15:0] gpr_pre [0:7];
  reg  [15:0] gpr_post [0:7];

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0), .core_sleeping(core_sleeping),
    .is_halted(is_halted),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy),
    .dbg_dmactive(dbg_dmactive), .dbg_req(dbg_req), .dbg_cmd(dbg_cmd),
    .dbg_addr(dbg_addr), .dbg_dataFromHost(dbg_dataFromHost),
    .dbg_ack(dbg_ack), .dbg_dataToHost(dbg_dataToHost), .dbg_halted(dbg_halted));

  localparam [2:0] CMD_MEMWR = 3'd1, CMD_SETPC = 3'd2, CMD_HALT = 3'd3,
                   CMD_RESUME = 3'd4, CMD_READPC = 3'd5, CMD_MEMRD = 3'd6,
                   CMD_READCCR = 3'd7;
  localparam [15:0] CODE = 16'h0300, DATA = 16'h0310, TRAPA2 = 16'h5720;

  wire [7:0]  ccrByte = dut.ccr.ccrByte;
  // GPR word probes r0..r7 (dbg is {r7,r6,...,r0}, 16 bits each).
  function [15:0] gpr; input [3:0] idx; begin
    gpr = dut.h8rf.dbg[idx*16 +: 16]; end
  endfunction

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

  reg [15:0] rdat;
  task dm(input [2:0] cmd, input [15:0] a, input [15:0] d);
    begin
      dbg_cmd = cmd; dbg_addr = a; dbg_dataFromHost = d; dbg_req = 1'b1;
      i = 0; while (!dbg_ack && i < 500) begin @(posedge clock); i = i + 1; end
      if (!dbg_ack) begin errors = errors + 1; $display("NONDESTRUCT FAIL: no ack cmd=%0d", cmd); end
      rdat = dbg_dataToHost;
      dbg_req = 1'b0;
      while (dbg_ack && i < 900) begin @(posedge clock); i = i + 1; end
    end
  endtask

  // Program-buffer GPR read: inject MOV.W rN,@DATA ; TRAPA #2, resume, re-halt,
  // read DATA. Saves/restores code+data+PC (mirrors the Rust tool).
  reg [15:0] s_pc, s_c0, s_c1, s_c2, s_d;
  task pb_read_gpr(input [3:0] rn, output [15:0] val);
    begin
      dm(CMD_READPC, 0, 0); s_pc = rdat;
      dm(CMD_MEMRD, CODE, 0); s_c0 = rdat;
      dm(CMD_MEMRD, CODE+2, 0); s_c1 = rdat;
      dm(CMD_MEMRD, CODE+4, 0); s_c2 = rdat;
      dm(CMD_MEMRD, DATA, 0); s_d = rdat;
      dm(CMD_MEMWR, CODE,   16'h6B80 | rn); // MOV.W rN,@aa:16
      dm(CMD_MEMWR, CODE+2, DATA);
      dm(CMD_MEMWR, CODE+4, TRAPA2);
      dm(CMD_SETPC, CODE, 0);
      // Resume; the injected snippet re-parks via TRAPA #2.
      dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
      i = 0; while (dbg_halted && i < 300) begin @(posedge clock); i = i + 1; end
      dbg_req = 1'b0;
      i = 0; while (!is_halted && i < 400) begin @(posedge clock); i = i + 1; end
      repeat (2) @(posedge clock);
      dm(CMD_MEMRD, DATA, 0); val = rdat;
      // Restore work area + PC.
      dm(CMD_MEMWR, CODE,   s_c0);
      dm(CMD_MEMWR, CODE+2, s_c1);
      dm(CMD_MEMWR, CODE+4, s_c2);
      dm(CMD_MEMWR, DATA,   s_d);
      dm(CMD_SETPC, s_pc, 0);
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;  // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;  // reset PC = 0x0030

    // Program: set GPRs to distinct values, load a known CCR, then spin.
    //   mov.w #0x1111,R1 ; #0x2222,R2 ; #0x3333,R3 ; #0x4444,R4
    mem[16'h0030]=8'h79; mem[16'h0031]=8'h01; mem[16'h0032]=8'h11; mem[16'h0033]=8'h11;
    mem[16'h0034]=8'h79; mem[16'h0035]=8'h02; mem[16'h0036]=8'h22; mem[16'h0037]=8'h22;
    mem[16'h0038]=8'h79; mem[16'h0039]=8'h03; mem[16'h003A]=8'h33; mem[16'h003B]=8'h33;
    mem[16'h003C]=8'h79; mem[16'h003D]=8'h04; mem[16'h003E]=8'h44; mem[16'h003F]=8'h44;
    //   ldc #0x2C,ccr (07 2C): known CCR (I=0 UI=0 H=1 U=0 N=0 Z=1 V=1 C=0)
    mem[16'h0040]=8'h07; mem[16'h0041]=8'h2C;
    //   spin: bra . at 0x0042
    mem[16'h0042]=8'h40; mem[16'h0043]=8'hFE;

    errors = 0; irq = 0; nmi = 0; reset = 1;
    dbg_dmactive = 0; dbg_req = 0; dbg_cmd = 0; dbg_addr = 0; dbg_dataFromHost = 0;
    repeat (4) @(posedge clock); reset = 0;
    // Let the program set regs+CCR and settle in the spin.
    repeat (120) @(posedge clock); #1;

    dbg_dmactive = 1'b1;
    repeat (3) @(posedge clock);
    dm(CMD_HALT, 0, 0); #1;
    if (!is_halted) begin errors=errors+1; $display("NONDESTRUCT FAIL: halt"); end

    // Snapshot architectural GPRs at halt (pre-read reference).
    for (n = 0; n < 8; n = n + 1) gpr_pre[n] = gpr(n[3:0]);

    // ReadCcr returns the CCR captured at park entry.
    dm(CMD_READCCR, 0, 0); ccr_read = rdat[7:0]; #1;

    // Read every GPR through the program-buffer path (perturbs live N/Z/V).
    for (n = 0; n < 8; n = n + 1) pb_read_gpr(n[3:0], gpr_post[n]);

    // A second ReadCcr must still return the same captured CCR.
    dm(CMD_READCCR, 0, 0);
    if (rdat[7:0] !== ccr_read) begin
      errors=errors+1; $display("NONDESTRUCT FAIL: ReadCcr not stable (%h vs %h)",
        rdat[7:0], ccr_read); end

    // Final resume-to-program: microcode restores CCR to the captured value.
    dbg_cmd = CMD_RESUME; dbg_req = 1'b1;
    i = 0; while (dbg_halted && i < 300) begin @(posedge clock); i = i + 1; end
    dbg_req = 1'b0;
    repeat (20) @(posedge clock); #1;
    ccr_after = ccrByte;

    // Checks.
    if (ccr_read !== 8'h2C) begin
      errors=errors+1; $display("NONDESTRUCT FAIL: ReadCcr=%h (want 2C)", ccr_read); end
    if (ccr_after !== 8'h2C) begin
      errors=errors+1;
      $display("NONDESTRUCT FAIL: architectural CCR after resume=%h (want 2C)", ccr_after); end
    if ((gpr_read_check() != 0)) ; // reported inside

    if (errors == 0)
      $display("NONDESTRUCT PASS: CCR & all GPRs pristine after read+resume (CCR=%h)", ccr_after);
    else
      $display("NONDESTRUCT FAIL: %0d", errors);
    $finish;
  end

  function integer gpr_read_check; integer k; begin
    gpr_read_check = 0;
    for (k = 0; k < 8; k = k + 1) begin
      if (gpr_post[k] !== gpr_pre[k]) begin
        errors = errors + 1; gpr_read_check = 1;
        $display("NONDESTRUCT FAIL: r%0d read via progbuf = %h (want %h)",
          k, gpr_post[k], gpr_pre[k]);
      end
    end
  end endfunction
endmodule
