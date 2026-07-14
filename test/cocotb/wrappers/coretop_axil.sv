// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Rename wrapper: exposes canonical AXI-Lite master signal names
// (m_axil_awaddr, m_axil_wvalid, ...) so cocotbext-axi's
// AxiLiteBus.from_prefix(dut, "m_axil") binds directly. The generated
// CoreTopAxi emits firtool-style flat names (axil_aw_bits_addr, ...); this
// wrapper is the only place that mapping lives.

module coretop_axil (
  input         clock,
  input         reset,
  input         irq,
  input         nmi,
  input  [2:0]  irq_number,
  input  [7:0]  vt_base,
  output        core_sleeping,

  // AXI-Lite master, canonical names (prefix m_axil).
  output [31:0] m_axil_awaddr,
  output [2:0]  m_axil_awprot,
  output        m_axil_awvalid,
  input         m_axil_awready,

  output [31:0] m_axil_wdata,
  output [3:0]  m_axil_wstrb,
  output        m_axil_wvalid,
  input         m_axil_wready,

  input  [1:0]  m_axil_bresp,
  input         m_axil_bvalid,
  output        m_axil_bready,

  output [31:0] m_axil_araddr,
  output [2:0]  m_axil_arprot,
  output        m_axil_arvalid,
  input         m_axil_arready,

  input  [31:0] m_axil_rdata,
  input  [1:0]  m_axil_rresp,
  input         m_axil_rvalid,
  output        m_axil_rready
);

  CoreTopAxi u_dut (
    .clock             (clock),
    .reset             (reset),
    .irq               (irq),
    .nmi               (nmi),
    .irq_number        (irq_number),
    .vt_base           (vt_base),
    .core_sleeping     (core_sleeping),

    .axil_aw_valid     (m_axil_awvalid),
    .axil_aw_ready     (m_axil_awready),
    .axil_aw_bits_addr (m_axil_awaddr),
    .axil_aw_bits_prot (m_axil_awprot),

    .axil_w_valid      (m_axil_wvalid),
    .axil_w_ready      (m_axil_wready),
    .axil_w_bits_data  (m_axil_wdata),
    .axil_w_bits_strb  (m_axil_wstrb),

    .axil_b_valid      (m_axil_bvalid),
    .axil_b_ready      (m_axil_bready),
    .axil_b_bits_resp  (m_axil_bresp),

    .axil_ar_valid     (m_axil_arvalid),
    .axil_ar_ready     (m_axil_arready),
    .axil_ar_bits_addr (m_axil_araddr),
    .axil_ar_bits_prot (m_axil_arprot),

    .axil_r_valid      (m_axil_rvalid),
    .axil_r_ready      (m_axil_rready),
    .axil_r_bits_data  (m_axil_rdata),
    .axil_r_bits_resp  (m_axil_rresp)
  );

endmodule
