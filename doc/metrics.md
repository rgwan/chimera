# Chimera Metrics

Measured numbers per configuration. Remeasure after RTL changes; the
microarchitecture itself is described in
[microarchitecture.md](microarchitecture.md).

## FPGA area (yosys generic mapping)

Method: elaborate, then `synth -top Core -lut <k> -flatten` with
`MicrocodeRom` blackboxed (it maps to block RAM); `H8RegFile` counted in.
Vendor reports take precedence over these trend numbers.

| | `lean` (default) | `strict` |
|---|---|---|
| LUT4 / LUT5 | 751 / 612 | 802 / 620 |
| Microcode words | 371 / 512 | 393 / 512 |
| Logic depth (LUT5 levels, ROM register included) | 19 | 19 |

## ASIC (post-route)

16 nm 9T RVT, tt 0.8 V 25 C, place-and-route complete with zero routing
violations; microcode ROM implemented as gates. NAND2 equivalence uses the
minimum-drive two-input NAND cell area.

| Metric | Value |
|---|---|
| Gate count | about 7.4k NAND2 equivalents (2321 placed cells) |
| Cell area | 766 um2; 39.7 x 39.2 um core at 49 percent utilization |
| Clock | 1 GHz closed, 19 logic levels on the critical path |
| Power at 1 GHz | 0.89 mW dynamic, 0.36 uW leakage |
