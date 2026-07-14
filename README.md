# Chimera

Chimera is an MIT-licensed CPU core targeting Renesas H8/300 ISA compatibility.

H8/300 is easier for modern SDKs and HALs than 8051 or AVR because memory
and I/O share one flat memory-mapped address space.

![Chimera core](doc/diagrams/chimera-core.drawio.svg)

Hybrid-microcode, multi-cycle, FPGA-first. Hardware does coarse pre-decode;
a 512 × 36 microcode ROM does fine decode and execution. The full base
H8/300 instruction set is implemented and verified against a Sail model.

## Configurations

Two target platforms, three tiers each. FPGA infers the microcode ROM as
block RAM; ASIC synthesizes it to gates (self-contained, no readmemh) and
emits a filelist.

| Tier | For |
|---|---|
| `lean` | smallest, single-cycle datapath, best same-clock IPC |
| `pipe` | two-stage microword pipeline, highest clock |
| `strict` | illegal encodings retire as no-op |

Each builds with one line:

```bash
nix build .#rtl-fpga-lean      # FPGA, BRAM ROM, single-cycle (smallest)
nix build .#rtl-fpga-pipe      # FPGA, BRAM ROM, pipelined (highest clock)
nix build .#rtl-fpga-strict    # FPGA, BRAM ROM, illegal-encoding guards
nix build .#rtl-asic-lean      # ASIC, gate ROM, single-cycle
nix build .#rtl-asic-pipe      # ASIC, gate ROM, pipelined
nix build .#rtl-asic-strict    # ASIC, gate ROM, illegal-encoding guards
```

On Anlogic EG4: `fpga-lean` is 674 LUT4/5 + 2 BRAM9K @ 61 MHz; `fpga-pipe`
is 698 LUT4/5 @ 92 MHz (+31% throughput, +15% cycle cost). Release tarballs
for every tier are attached to each tagged version.

Full numbers and methods are in [doc/metrics.md](doc/metrics.md); the
design itself is in [doc/microarchitecture.md](doc/microarchitecture.md).

Optional debug: software breakpoints (always on), self-hosted or external
single-step and hardware breakpoints, and a JTAG debug module driven by a
gdb host tool. See [doc/debug.md](doc/debug.md).

## Build and verify

```bash
nix develop
make rtl-verilog     # elaborate to SystemVerilog
make check-exec-sail # RTL retire trace vs Sail model
make verify-smoke    # all verification gates
```
