// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// ALU unit vectors (hand-computed H8 arithmetic). Checks raw result and the
// raw C/V/H the FlagUnit later selects. Op codes match AluOp in ChimeraDefs.
`timescale 1ns / 1ps
module tb_alu;
  reg  [15:0] a, b;
  reg         cin, word;
  reg  [3:0]  op;
  wire [15:0] y;
  wire        cout, vout, hout;
  integer     fails = 0;

  Alu dut (.a(a), .b(b), .cin(cin), .op(op), .word(word),
           .y(y), .cout(cout), .vout(vout), .hout(hout));

  // op codes; compare = SUB without writeback, not = XOR with 0xff
  localparam ADD=0, SUB=1, ADC=2, SBC=3, ANDo=4, ORo=5, XORo=6,
             PASS=8, SHAR=10, SHR1=11, ROL=12, ROR=13, RORC=14;

  task chk(input [3:0] o, input [15:0] ia, input [15:0] ib, input ic, input iw,
           input [15:0] ey, input ec, input ev, input eh, input ckh);
    reg [15:0] my;
    begin
      op=o; a=ia; b=ib; cin=ic; word=iw; #1;
      my = iw ? y : {8'h00, y[7:0]};
      if (my !== (iw ? ey : {8'h00, ey[7:0]})) begin
        $display("FAIL y op=%0d a=%h b=%h -> %h exp %h", o, ia, ib, y, ey);
        fails=fails+1; end
      if (cout !== ec) begin
        $display("FAIL cout op=%0d a=%h b=%h -> %b exp %b", o, ia, ib, cout, ec);
        fails=fails+1; end
      if (vout !== ev) begin
        $display("FAIL vout op=%0d a=%h b=%h -> %b exp %b", o, ia, ib, vout, ev);
        fails=fails+1; end
      if (ckh && (hout !== eh)) begin
        $display("FAIL hout op=%0d a=%h b=%h -> %b exp %b", o, ia, ib, hout, eh);
        fails=fails+1; end
    end
  endtask

  initial begin
    //   op    a       b      cin word  y      c v h ckh
    chk(ADD, 16'h05, 16'h03, 0, 0, 16'h08, 0,0,0, 1);
    chk(ADD, 16'hFF, 16'h01, 0, 0, 16'h00, 1,0,1, 1);
    chk(ADD, 16'h7F, 16'h01, 0, 0, 16'h80, 0,1,1, 1);
    chk(ADD, 16'h80, 16'h80, 0, 0, 16'h00, 1,1,0, 1);
    chk(ADD, 16'hFF05,16'h0003,0,0, 16'h08, 0,0,0, 1); // byte carry ignores high byte
    chk(ADC, 16'h05, 16'h03, 1, 0, 16'h09, 0,0,0, 1);
    chk(ADC, 16'h0F, 16'h00, 1, 0, 16'h10, 0,0,1, 1);
    chk(SUB, 16'h05, 16'h03, 0, 0, 16'h02, 0,0,0, 1);
    chk(SUB, 16'h00, 16'h01, 0, 0, 16'hFF, 1,0,1, 1);
    chk(SUB, 16'h80, 16'h01, 0, 0, 16'h7F, 0,1,1, 1);
    chk(SUB, 16'h05, 16'h05, 0, 0, 16'h00, 0,0,0, 1); // compare form
    chk(SBC, 16'h05, 16'h03, 1, 0, 16'h01, 0,0,0, 1);
    chk(SBC, 16'h05, 16'h03, 0, 0, 16'h02, 0,0,0, 1);
    chk(SBC, 16'h00, 16'h00, 1, 0, 16'hFF, 1,0,1, 1);
    chk(ANDo,16'h0F, 16'hF0, 0, 0, 16'h00, 1,0,0, 0); // cout=a[0]=1 (unused)
    chk(ORo, 16'h0F, 16'hF0, 0, 0, 16'hFF, 1,0,0, 0);
    chk(XORo,16'hFF, 16'h0F, 0, 0, 16'hF0, 1,0,0, 0);
    chk(XORo,16'h0F, 16'hFF, 0, 0, 16'hF0, 1,0,0, 0); // not form
    chk(ADD, 16'h81, 16'h81, 0, 0, 16'h02, 1,1,0, 1); // left shift SHLL/SHAL raw
    chk(SHR1,16'h81, 16'h00, 0, 0, 16'h40, 1,0,0, 0); // SHLR
    chk(SHAR,16'h81, 16'h00, 0, 0, 16'hC0, 1,0,0, 0);
    chk(ROR, 16'h01, 16'h00, 0, 0, 16'h80, 1,0,0, 0);
    chk(RORC,16'h00, 16'h00, 1, 0, 16'h80, 0,0,0, 0);
    chk(ROL, 16'h81, 16'h81, 0, 0, 16'h03, 1,0,0, 0); // ROTL: caller sets b=a, cin=old bit7
    chk(ADC, 16'h80, 16'h80, 0, 0, 16'h00, 1,1,0, 0); // ROTXL raw (V zeroed later)
    chk(ADD, 16'h7FFF,16'h0001,0,1, 16'h8000,0,1,1, 1); // word
    chk(ADD, 16'hFFFF,16'h0001,0,1, 16'h0000,1,0,1, 1);

    if (fails==0) $display("ALU-UNIT PASS: all vectors match");
    else          $display("ALU-UNIT FAIL: %0d mismatches", fails);
    $finish;
  end
endmodule
