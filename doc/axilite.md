<!--
SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
SPDX-License-Identifier: MIT
-->

# Optional AXI-Lite bus

The core's native memory port is a simple 16-bit request/ready SRAM bus. The
`axilite` config wraps it in a `CoreTopAxi` top that exposes an AXI-Lite master
instead, for connecting the core to standard AXI fabric. Off by default; every
leaf module is byte-identical when off, so the lean/ASIC baselines are unchanged.

## Enable

```bash
AXIL=true TOP=CoreTopAxi bash rtl/build.sh   # axiDataWidth defaults to 32
```

## Adapter

`SramToAxiLite` (rtl/src/AxiLiteBridge.scala) bridges the internal bus to a
32-bit AXI-Lite master, one outstanding transaction (matching the SRAM
hold-req-until-ready contract):

- **Read** (`req & !we`): drive AR, accept R; `rdy` on the R beat.
- **Write** (`req & we`): drive AW and W independently, join, wait for B; `rdy`
  on the B beat.
- **Address**: the 16-bit core word address zero-extended, low two bits cleared
  (AXI-Lite requires a 4-byte-aligned address; WSTRB selects the lane).
- **Lane**: `addr[1]` picks the low or high 16-bit half of the 32-bit word.
- **Byte order**: the half is byte-swapped so the AXI byte image is H8
  big-endian (high byte at the lower byte address) — an external AXI peripheral
  reads the same bytes the core wrote. WSTRB carries the byte enables (`wmask`).
- `prot` is hardwired to 2 (data, non-secure, unprivileged).

A thin SV wrapper `test/cocotb/wrappers/coretop_axil.sv` renames the emitted
`axil_*` ports to canonical `m_axil_*` for standard AXI tooling.

## Verify

```bash
make check-axilite                              # off byte-identical + elaborate
nix develop .#cocotb --command make check-cocotb-axi
```

`check-cocotb-axi` boots the real core over a `cocotbext-axi` `AxiLiteRam` slave
and checks word/byte stores on both lanes, WSTRB, the read path, big-endian byte
order, and 4-byte address alignment.
