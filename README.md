# Chimera

Chimera is an MIT-licensed CPU core targeting Renesas H8/300 ISA compatibility.

H8/300 is easier for modern SDKs and HALs than 8051 or AVR because memory
and I/O share one flat memory-mapped address space.

![Chimera core](doc/diagrams/chimera-core.drawio.svg)

Hybrid-microcode, multi-cycle, FPGA-first. Hardware does coarse pre-decode;
a 512 × 36 microcode ROM does fine decode and execution. The full base
H8/300 instruction set is implemented and verified against a Sail model.

## Configurations

| | `lean` (default) | `strict` |
|---|---|---|
| Illegal encodings | undefined behavior | guarded, retire as no-op |
| Core area (LUT4, µROM as BRAM) | 751 | 802 |

`STRICT_DECODE=true` selects `strict`. Details and the full comparison are in
[doc/microarchitecture.md](doc/microarchitecture.md).

## Build and verify

```bash
nix develop
make rtl-verilog     # elaborate to SystemVerilog
make check-exec-sail # RTL retire trace vs Sail model
make verify-smoke    # all verification gates
```
