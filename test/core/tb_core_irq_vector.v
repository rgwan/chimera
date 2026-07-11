// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Platform vector map: NMI vectors through 0x0E, IRQ #i through 0x18+2i as
// selected by irq_number, and vt_base=1 relocates the whole table to 0x0100.
`timescale 1ns / 1ps
module tb_core_irq_vector;
  reg         clock, reset, irq, nmi;
  reg  [2:0]  irq_number;
  reg  [7:0]  vt_base;
  wire [15:0] bus_addr, bus_wdata;
  reg  [15:0] bus_rdata;
  wire        bus_we, bus_req;
  wire [1:0]  bus_wmask;
  reg         bus_rdy;
  reg  [7:0]  mem [0:65535];
  integer     i, fails;

  Core dut (.clock(clock), .reset(reset), .irq(irq), .nmi(nmi),
    .irq_number(irq_number), .vt_base(vt_base),
    .bus_addr(bus_addr), .bus_wdata(bus_wdata), .bus_rdata(bus_rdata),
    .bus_we(bus_we), .bus_wmask(bus_wmask), .bus_req(bus_req), .bus_rdy(bus_rdy));

  wire [15:0] r1 = dut.h8rf.dbg[31:16];
  wire [15:0] r2 = dut.h8rf.dbg[47:32];
  wire [15:0] r3 = dut.h8rf.dbg[63:48];
  wire [15:0] r4 = dut.h8rf.dbg[79:64];
  wire [15:0] r5 = dut.h8rf.dbg[95:80];
  wire [15:0] r7 = dut.h8rf.dbg[127:112];

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

  task reset_core;
    begin
      irq = 0; nmi = 0; reset = 1;
      repeat (4) @(posedge clock);
      reset = 0;
      repeat (40) @(posedge clock);
    end
  endtask

  task pulse_irq;
    begin
      irq = 1; repeat (2) @(posedge clock); irq = 0;
      repeat (60) @(posedge clock); #1;
    end
  endtask

  task pulse_nmi;
    begin
      nmi = 1; repeat (2) @(posedge clock); nmi = 0;
      repeat (60) @(posedge clock); #1;
    end
  endtask

  initial begin
    fails = 0;

    // phase 1: table at 0, NMI at 0x0E, IRQ #i at 0x18+2i
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0002]=8'h02; mem[16'h0003]=8'h00;             // reset SP = 0x0200
    mem[16'h0006]=8'h00; mem[16'h0007]=8'h30;             // reset PC = 0x0030
    mem[16'h000e]=8'h00; mem[16'h000f]=8'h60;             // NMI      -> 0x0060
    mem[16'h001c]=8'h00; mem[16'h001d]=8'h70;             // IRQ2     -> 0x0070
    mem[16'h0022]=8'h00; mem[16'h0023]=8'h80;             // IRQ5     -> 0x0080
    mem[16'h0030]=8'h06; mem[16'h0031]=8'h7f;             // main: andc #0x7f, ccr
    mem[16'h0032]=8'h40; mem[16'h0033]=8'hfe;             //       bra -2
    mem[16'h0060]=8'h79; mem[16'h0061]=8'h02;             // nmi:  mov.w #0x2222,R2
    mem[16'h0062]=8'h22; mem[16'h0063]=8'h22;
    mem[16'h0064]=8'h56; mem[16'h0065]=8'h70;             // rte
    mem[16'h0070]=8'h79; mem[16'h0071]=8'h01;             // irq2: mov.w #0x1111,R1
    mem[16'h0072]=8'h11; mem[16'h0073]=8'h11;
    mem[16'h0074]=8'h56; mem[16'h0075]=8'h70;             // rte
    mem[16'h0080]=8'h79; mem[16'h0081]=8'h03;             // irq5: mov.w #0x3333,R3
    mem[16'h0082]=8'h33; mem[16'h0083]=8'h33;
    mem[16'h0084]=8'h56; mem[16'h0085]=8'h70;             // rte

    vt_base = 8'd0; irq_number = 3'd2;
    reset_core();
    if (r7 !== 16'h0200) begin $display("FAIL boot SP=%h exp 0200", r7); fails=fails+1; end
    pulse_nmi();
    if (r2 !== 16'h2222) begin $display("FAIL nmi r2=%h exp 2222", r2); fails=fails+1; end
    if (r1 !== 16'h0000 || r3 !== 16'h0000)
      begin $display("FAIL nmi hit irq slot r1=%h r3=%h", r1, r3); fails=fails+1; end
    pulse_irq();
    if (r1 !== 16'h1111) begin $display("FAIL irq2 r1=%h exp 1111", r1); fails=fails+1; end
    irq_number = 3'd5;
    pulse_irq();
    if (r3 !== 16'h3333) begin $display("FAIL irq5 r3=%h exp 3333", r3); fails=fails+1; end
    if (r7 !== 16'h0200) begin $display("FAIL final SP=%h exp 0200", r7); fails=fails+1; end

    // phase 2: vt_base=1 puts the table at 0x0100
    for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
    mem[16'h0102]=8'h03; mem[16'h0103]=8'h00;             // reset SP = 0x0300
    mem[16'h0106]=8'h01; mem[16'h0107]=8'h30;             // reset PC = 0x0130
    mem[16'h010e]=8'h01; mem[16'h010f]=8'h60;             // NMI      -> 0x0160
    mem[16'h011c]=8'h01; mem[16'h011d]=8'h70;             // IRQ2     -> 0x0170
    mem[16'h0130]=8'h06; mem[16'h0131]=8'h7f;             // main: andc #0x7f, ccr
    mem[16'h0132]=8'h40; mem[16'h0133]=8'hfe;             //       bra -2
    mem[16'h0160]=8'h79; mem[16'h0161]=8'h04;             // nmi:  mov.w #0x4444,R4
    mem[16'h0162]=8'h44; mem[16'h0163]=8'h44;
    mem[16'h0164]=8'h56; mem[16'h0165]=8'h70;             // rte
    mem[16'h0170]=8'h79; mem[16'h0171]=8'h05;             // irq2: mov.w #0x5555,R5
    mem[16'h0172]=8'h55; mem[16'h0173]=8'h55;
    mem[16'h0174]=8'h56; mem[16'h0175]=8'h70;             // rte

    vt_base = 8'd1; irq_number = 3'd2;
    reset_core();
    if (r7 !== 16'h0300) begin $display("FAIL vt boot SP=%h exp 0300", r7); fails=fails+1; end
    pulse_nmi();
    if (r4 !== 16'h4444) begin $display("FAIL vt nmi r4=%h exp 4444", r4); fails=fails+1; end
    pulse_irq();
    if (r5 !== 16'h5555) begin $display("FAIL vt irq2 r5=%h exp 5555", r5); fails=fails+1; end

    if (fails == 0)
      $display("CORE-IRQ-VECTOR PASS: NMI 0x0E, IRQ 0x18+2i, vt_base relocation");
    else
      $display("CORE-IRQ-VECTOR FAIL: %0d", fails);
    $finish;
  end
endmodule
