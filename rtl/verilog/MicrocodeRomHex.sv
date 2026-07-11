// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Drop-in MicrocodeRom with the image loaded from urom.memh, so FPGA tools
// infer block RAM. rtl/build.sh swaps this in for the generated when-chain
// module when ROM_HEX=true; Core writes urom.memh at elaboration.
module MicrocodeRom(
  input  wire        clock,
  input  wire        reset,
  input  wire [8:0]  addr,
  output reg  [35:0] data
);
  reg [35:0] mem [0:511];
  initial begin
    $readmemh("../generated/urom.memh", mem);
  end
  // In reset force the fetch-entry word, like the generated module's reset
  // value; the address mux keeps the single synchronous read BRAM-inferable.
  always @(posedge clock) data <= mem[reset ? 9'h100 : addr];
endmodule
