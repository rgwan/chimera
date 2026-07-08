// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Exhaustive decoder-equivalence bench: drive every 16-bit word through the
// elaborated CoarseDecoder and compare dispatch against the golden
// pre_decoded_instr (expected.mem, generated from isa/decode_dispatch_golden.csv).
`timescale 1ns / 1ps
module tb_coarse_decoder;
  reg  [15:0] word;
  wire [7:0]  dispatch;
  reg  [7:0]  expected [0:65535];
  integer i, mism;

  CoarseDecoder dut (.word(word), .dispatch(dispatch));

  initial begin
    $readmemh("expected.mem", expected);
    mism = 0;
    for (i = 0; i < 65536; i = i + 1) begin
      word = i[15:0];
      #1;
      if (dispatch !== expected[i]) begin
        if (mism < 10)
          $display("MISMATCH word=%04h dispatch=%02h expected=%02h",
                   word, dispatch, expected[i]);
        mism = mism + 1;
      end
    end
    if (mism == 0)
      $display("DECODE-EQUIV PASS: 65536/65536 match golden pre_decoded_instr");
    else
      $display("DECODE-EQUIV FAIL: %0d mismatches", mism);
    $finish;
  end
endmodule
