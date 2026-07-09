// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Generic ISA-case runner: loads a memory image (+hex=<file>) built by
// check_exec_sail.py (state-preload prologue + the case instruction + NOPs),
// runs, and dumps architectural state for retire comparison.
`timescale 1ns / 1ps
module tb_isa_case;
  reg         clock, reset, irq, nmi;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  reg [1023:0] hexpath;
  reg [15:0] mem_probe [0:15];
  reg [15:0] mp0, mp1, mp2, mp3, mp4, mp5, mp6, mp7;
  reg [15:0] mp8, mp9, mp10, mp11, mp12, mp13, mp14, mp15;
  integer     mem_probe_count;
  integer     i;
  integer     stop_fetch;
  integer     fetch_count;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  always @(*) begin
    bus_rdy   = 1'b1;
    bus_rdata = {mem[bus_addr], mem[(bus_addr + 16'd1) & 16'hFFFF]};
  end
  // store: byte-masked big-endian write
  always @(posedge clock) if (bus_req && bus_we) begin
    if (bus_wmask[1]) mem[bus_addr]                    <= bus_wdata[15:8];
    if (bus_wmask[0]) mem[(bus_addr + 16'd1) & 16'hFFFF] <= bus_wdata[7:0];
  end

  initial clock = 0;
  always #5 clock = ~clock;

  task dump_state;
    begin
      $display("R %h %h %h %h %h %h %h %h",
        dut.h8rf.dbg[15:0],   dut.h8rf.dbg[31:16],  dut.h8rf.dbg[47:32],  dut.h8rf.dbg[63:48],
        dut.h8rf.dbg[79:64],  dut.h8rf.dbg[95:80],  dut.h8rf.dbg[111:96], dut.h8rf.dbg[127:112]);
      $display("C %b", dut.ccr.hnzvc);
      $display("P %h", dut.intrf.dbgPc);
      for (i = 0; i < mem_probe_count; i = i + 1)
        $display("M %04h %02h", mem_probe[i], mem[mem_probe[i]]);
    end
  endtask

  initial begin
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    if (!$value$plusargs("hex=%s", hexpath)) begin $display("NO-HEX"); $finish; end
    if (!$value$plusargs("stop_fetch=%d", stop_fetch)) stop_fetch = 0;
    mem_probe_count = 0;
    if ($value$plusargs("m0=%h",  mp0))  begin mem_probe[0]  = mp0;  mem_probe_count = 1;  end
    if ($value$plusargs("m1=%h",  mp1))  begin mem_probe[1]  = mp1;  mem_probe_count = 2;  end
    if ($value$plusargs("m2=%h",  mp2))  begin mem_probe[2]  = mp2;  mem_probe_count = 3;  end
    if ($value$plusargs("m3=%h",  mp3))  begin mem_probe[3]  = mp3;  mem_probe_count = 4;  end
    if ($value$plusargs("m4=%h",  mp4))  begin mem_probe[4]  = mp4;  mem_probe_count = 5;  end
    if ($value$plusargs("m5=%h",  mp5))  begin mem_probe[5]  = mp5;  mem_probe_count = 6;  end
    if ($value$plusargs("m6=%h",  mp6))  begin mem_probe[6]  = mp6;  mem_probe_count = 7;  end
    if ($value$plusargs("m7=%h",  mp7))  begin mem_probe[7]  = mp7;  mem_probe_count = 8;  end
    if ($value$plusargs("m8=%h",  mp8))  begin mem_probe[8]  = mp8;  mem_probe_count = 9;  end
    if ($value$plusargs("m9=%h",  mp9))  begin mem_probe[9]  = mp9;  mem_probe_count = 10; end
    if ($value$plusargs("m10=%h", mp10)) begin mem_probe[10] = mp10; mem_probe_count = 11; end
    if ($value$plusargs("m11=%h", mp11)) begin mem_probe[11] = mp11; mem_probe_count = 12; end
    if ($value$plusargs("m12=%h", mp12)) begin mem_probe[12] = mp12; mem_probe_count = 13; end
    if ($value$plusargs("m13=%h", mp13)) begin mem_probe[13] = mp13; mem_probe_count = 14; end
    if ($value$plusargs("m14=%h", mp14)) begin mem_probe[14] = mp14; mem_probe_count = 15; end
    if ($value$plusargs("m15=%h", mp15)) begin mem_probe[15] = mp15; mem_probe_count = 16; end
    $readmemh(hexpath, mem);
    irq = 0; nmi = 0; reset = 1;
    repeat (4) @(posedge clock);
    reset = 0;
    fetch_count = 0;
    for (i = 0; i < 4000; i = i + 1) begin
      @(posedge clock);
      if (dut.useq.upc == 9'h101) begin
        fetch_count = fetch_count + 1;
        if (stop_fetch != 0 && fetch_count >= stop_fetch) begin
          #1; dump_state; $finish;
        end
      end
    end
    #1; dump_state;
    $finish;
  end
endmodule
