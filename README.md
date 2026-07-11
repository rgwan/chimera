# Chimera

Chimera is an MIT-licensed CPU core targeting Renesas H8/300 ISA compatibility.

H8/300 is easier for modern SDKs and HALs than 8051 or AVR because memory
and I/O share one flat memory-mapped address space.

![Chimera core](doc/diagrams/chimera-core.drawio.svg)

Hybrid-microcode, multi-cycle, FPGA-first. Hardware does coarse pre-decode;
a 512 × 36 microcode ROM does fine decode and execution. The full base
H8/300 instruction set is implemented and verified against a Sail model.

## Configurations

| Config | For | Headline |
|---|---|---|
| `lean` (default) | smallest core | 674 LUT4/5 @ 61 MHz (Anlogic EG4) |
| `strict` | illegal encodings retire as no-op | 821 LUT4 |
| `fpga` | lean with a block-RAM microcode ROM | 674 LUT4/5 + 2 BRAM 9K @ 61 MHz (Anlogic EG4) |
| `asic` | synthesis-ready file set | 7.4k gates, 1 GHz post-route |

Each builds with one line:

```bash
nix build .#rtl-lean                   # lean (default)
nix build .#rtl-strict                 # strict
nix build .#rtl-fpga                   # lean + block-RAM microcode ROM
nix build .#rtl-asic                   # synthesis file set
```

Full numbers and methods are in [doc/metrics.md](doc/metrics.md); the
design itself is in [doc/microarchitecture.md](doc/microarchitecture.md).

## Build and verify

```bash
nix develop
make rtl-verilog     # elaborate to SystemVerilog
make check-exec-sail # RTL retire trace vs Sail model
make verify-smoke    # all verification gates
```
