// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// SRAM wait-state checks for instruction fetch and word load/store.
`timescale 1ns / 1ps
module tb_core_wait;
  localparam [1:0] WAIT_FETCH = 2'd0;
  localparam [1:0] WAIT_READ  = 2'd1;
  localparam [1:0] WAIT_WRITE = 2'd2;

  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  reg         stall_fetch, stall_read, stall_write;
  integer     i, fails;
  integer     fetch_accepts, read_accepts, write_accepts;
  integer     read_reg_commits, read_ccr_commits, write_ccr_commits;
  integer     first_pc_commits;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(3'd0), .vt_base(8'd0),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  localparam [15:0] P = 16'h0030;  // program base, past the vector table

  wire [15:0]  pc   = dut.intrf.dbgPc;
  wire [127:0] regs = dut.h8rf.dbg;
  wire [7:0]   ccr  = dut.ccr.ccrByte;
  wire [8:0]   upc  = dut.useq.cur;
  wire [15:0]  r1   = regs[31:16];
  wire [15:0]  r2   = regs[47:32];
  wire [15:0]  r3   = regs[63:48];

  always @(*) begin
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hffff]};
    bus_rdy = 1'b1;
    if (bus_req && !bus_we && bus_addr == P && stall_fetch)
      bus_rdy = 1'b0;
    if (bus_req && !bus_we && bus_addr == 16'h0100 && stall_read)
      bus_rdy = 1'b0;
    if (bus_req && bus_we && bus_addr == 16'h0102 && stall_write)
      bus_rdy = 1'b0;
  end

  always @(posedge clock) begin
    if (!reset && bus_req && bus_rdy) begin
      if (!bus_we && bus_addr == P)
        fetch_accepts = fetch_accepts + 1;
      if (!bus_we && bus_addr == 16'h0100)
        read_accepts = read_accepts + 1;
      if (bus_we && bus_addr == 16'h0102)
        write_accepts = write_accepts + 1;
    end

    if (!reset && bus_req && !bus_we && bus_addr == 16'h0100) begin
      if (dut.h8rf.we && dut.h8rf.waddr == 3'd3)
        read_reg_commits = read_reg_commits + 1;
      if (dut.ccr.flagCtl != 3'b000)
        read_ccr_commits = read_ccr_commits + 1;
    end
    if (!reset && bus_req && bus_we && bus_addr == 16'h0102 &&
        dut.ccr.flagCtl != 3'b000)
      write_ccr_commits = write_ccr_commits + 1;
    if (!reset && dut.intrf.we && dut.intrf.waddr == 2'd0 &&
        dut.intrf.wdata == 16'h0032)
      first_pc_commits = first_pc_commits + 1;

    if (!reset && bus_req && bus_we && bus_rdy) begin
      if (bus_wmask[1]) mem[bus_addr] <= bus_wdata[15:8];
      if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hffff] <= bus_wdata[7:0];
    end
  end

  task automatic check_target_count;
    input [1:0] kind;
    input integer expected;
    input [8*5-1:0] label;
    integer actual;
    begin
      case (kind)
        WAIT_FETCH: actual = fetch_accepts;
        WAIT_READ:  actual = read_accepts;
        default:    actual = write_accepts;
      endcase
      if (actual != expected) begin
        $display("FAIL %0s accepts=%0d exp=%0d", label, actual, expected);
        fails = fails + 1;
      end
    end
  endtask

  task automatic exercise_wait;
    input [1:0] kind;
    input [15:0] expected_addr;
    input expected_we;
    input integer wait_cycles;
    input [8*5-1:0] label;
    reg [15:0]  held_pc, held_ir, held_ireg, held_temp;
    reg [127:0] held_regs;
    reg [7:0]   held_ccr;
    reg [8:0]   held_upc;
    reg [15:0]  held_addr, held_wdata;
    reg [1:0]   held_wmask;
    integer     n, timeout, accepts_before;
    integer     reg_commits_before, ccr_commits_before;
    begin
      timeout = 0;
      while (!(bus_req && bus_addr == expected_addr && bus_we == expected_we) &&
             timeout < 400) begin
        @(posedge clock); #1;
        timeout = timeout + 1;
      end
      if (timeout == 400) begin
        $display("FAIL %0s request timeout", label);
        $fatal(1);
      end

      held_pc    = pc;
      held_regs  = regs;
      held_ccr   = ccr;
      held_upc   = upc;
      held_ir    = dut.ir;
      held_ireg  = dut.intrf.ireg;
      held_temp  = dut.intrf.temp;
      held_addr  = bus_addr;
      held_wdata = bus_wdata;
      held_wmask = bus_wmask;
      case (kind)
        WAIT_FETCH: accepts_before = fetch_accepts;
        WAIT_READ:  accepts_before = read_accepts;
        default:    accepts_before = write_accepts;
      endcase
      reg_commits_before = read_reg_commits;
      if (kind == WAIT_READ)
        ccr_commits_before = read_ccr_commits;
      else
        ccr_commits_before = write_ccr_commits;

      for (n = 0; n < wait_cycles; n = n + 1) begin
        @(posedge clock); #1;
        if (bus_rdy !== 1'b0 || bus_req !== 1'b1 ||
            bus_addr !== held_addr || bus_we !== expected_we ||
            bus_wdata !== held_wdata || bus_wmask !== held_wmask) begin
          $display("FAIL %0s request changed during wait cycle %0d", label, n);
          fails = fails + 1;
        end
        if (pc !== held_pc || regs !== held_regs || ccr !== held_ccr ||
            upc !== held_upc || dut.ir !== held_ir ||
            dut.intrf.ireg !== held_ireg || dut.intrf.temp !== held_temp) begin
          $display("FAIL %0s state advanced during wait cycle %0d", label, n);
          fails = fails + 1;
        end
        if (dut.h8rf.we !== 1'b0 || dut.intrf.we !== 1'b0 ||
            dut.ccr.flagCtl !== 3'b000 || dut.ccr.ldWe !== 1'b0 ||
            dut.ccr.setI !== 1'b0) begin
          $display("FAIL %0s commit enable active during wait cycle %0d", label, n);
          fails = fails + 1;
        end
        check_target_count(kind, accepts_before, label);
        if (kind == WAIT_READ && read_reg_commits != reg_commits_before) begin
          $display("FAIL read register committed while rdy=0");
          fails = fails + 1;
        end
        if (kind == WAIT_READ && read_ccr_commits != ccr_commits_before) begin
          $display("FAIL read CCR committed while rdy=0");
          fails = fails + 1;
        end
        if (kind == WAIT_WRITE && write_ccr_commits != ccr_commits_before) begin
          $display("FAIL write CCR committed while rdy=0");
          fails = fails + 1;
        end
      end

      @(negedge clock);
      case (kind)
        WAIT_FETCH: stall_fetch = 1'b0;
        WAIT_READ:  stall_read  = 1'b0;
        default:    stall_write = 1'b0;
      endcase
      @(posedge clock); #1;
      check_target_count(kind, accepts_before + 1, label);
      if (kind == WAIT_READ && read_reg_commits != reg_commits_before + 1) begin
        $display("FAIL read register commits=%0d exp=%0d",
          read_reg_commits, reg_commits_before + 1);
        fails = fails + 1;
      end
      if (kind == WAIT_READ && read_ccr_commits != ccr_commits_before + 1) begin
        $display("FAIL read CCR commits=%0d exp=%0d",
          read_ccr_commits, ccr_commits_before + 1);
        fails = fails + 1;
      end
      if (kind == WAIT_WRITE && write_ccr_commits != ccr_commits_before + 1) begin
        $display("FAIL write CCR commits=%0d exp=%0d",
          write_ccr_commits, ccr_commits_before + 1);
        fails = fails + 1;
      end

      @(posedge clock); #1;
      check_target_count(kind, accepts_before + 1, label);
    end
  endtask

  initial clock = 0;
  always #5 clock = ~clock;

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    // platform vector table: SP from 0x0002, entry PC from 0x0006
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;               // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;               // reset PC = 0x0030
    mem[P+0] =8'h79; mem[P+1] =8'h01; mem[P+2] =8'h80; mem[P+3] =8'h01; // mov.w #0x8001,R1
    mem[P+4] =8'h79; mem[P+5] =8'h02; mem[P+6] =8'h01; mem[P+7] =8'h00; // mov.w #0x0100,R2
    mem[P+8] =8'h69; mem[P+9] =8'h23;                              // mov.w @R2,R3
    mem[P+10]=8'h79; mem[P+11]=8'h02; mem[P+12]=8'h01; mem[P+13]=8'h02; // mov.w #0x0102,R2
    mem[P+14]=8'h69; mem[P+15]=8'hA1;                              // mov.w R1,@R2
    mem[16'h0100] = 8'hbe;
    mem[16'h0101] = 8'hef;
    mem[16'h0102] = 8'h55;
    mem[16'h0103] = 8'haa;

    fails = 0;
    fetch_accepts = 0; read_accepts = 0; write_accepts = 0;
    read_reg_commits = 0; read_ccr_commits = 0; write_ccr_commits = 0;
    first_pc_commits = 0;
    stall_fetch = 1; stall_read = 1; stall_write = 1;
    irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    @(negedge clock); reset = 0;

    exercise_wait(WAIT_FETCH, P, 1'b0, 4, "fetch");
    if (dut.ir !== 16'h0179) begin
      $display("FAIL fetch IR=%h exp=0179", dut.ir);
      fails = fails + 1;
    end
    if (pc !== 16'h0032 || first_pc_commits != 1) begin
      $display("FAIL fetch PC=%h commits=%0d exp=0032/1", pc, first_pc_commits);
      fails = fails + 1;
    end

    // reset leaves CCR.I set, so the byte carries 0x80 on top of N
    exercise_wait(WAIT_READ, 16'h0100, 1'b0, 3, "read");
    if (r3 !== 16'hbeef || ccr !== 8'h88) begin
      $display("FAIL read R3=%h CCR=%h exp=beef/88", r3, ccr);
      fails = fails + 1;
    end

    exercise_wait(WAIT_WRITE, 16'h0102, 1'b1, 5, "write");
    if (mem[16'h0102] !== 8'h80 || mem[16'h0103] !== 8'h01 || ccr !== 8'h88) begin
      $display("FAIL write mem=%h%h CCR=%h exp=8001/88",
        mem[16'h0102], mem[16'h0103], ccr);
      fails = fails + 1;
    end

    repeat (8) @(posedge clock); #1;
    if (fetch_accepts != 1 || read_accepts != 1 || write_accepts != 1 ||
        read_reg_commits != 1 || read_ccr_commits != 1 || write_ccr_commits != 1 ||
        first_pc_commits != 1) begin
      $display("FAIL commit counts fetch=%0d read=%0d write=%0d r3=%0d rccr=%0d wccr=%0d pc=%0d",
        fetch_accepts, read_accepts, write_accepts, read_reg_commits,
        read_ccr_commits, write_ccr_commits, first_pc_commits);
      fails = fails + 1;
    end
    if (r1 !== 16'h8001 || r2 !== 16'h0102 || r3 !== 16'hbeef) begin
      $display("FAIL final R1=%h R2=%h R3=%h", r1, r2, r3);
      fails = fails + 1;
    end

    if (fails == 0)
      $display("CORE-WAIT PASS: fetch/read/write hold and commit once");
    else begin
      $display("CORE-WAIT FAIL: %0d", fails);
      $fatal(1);
    end
    $finish;
  end
endmodule
