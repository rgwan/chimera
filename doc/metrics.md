# Chimera Metrics

Measured numbers per configuration. Remeasure after RTL changes; the
microarchitecture itself is described in
[microarchitecture.md](microarchitecture.md).

## FPGA (evaluation standard)

The FPGA numbers of record come from the vendor place-and-route flow on
the EG4 target part. Lean configuration, microcode ROM in block RAM,
register file as distributed RAM:

| Metric | Value |
|---|---|
| Logic | 594 LUT4/5, 2 x 9K block RAM |
| Clock | 54 MHz |

yosys generic mapping (`synth -top Core -lut <k> -flatten`,
`MicrocodeRom` blackboxed, `H8RegFile` counted in) remains a quick local
trend proxy only:

| | `lean` (default) | `strict` |
|---|---|---|
| LUT4 / LUT5 | 803 / 627 | 821 / 678 |
| Microcode words | 379 / 512 | 401 / 512 |
| Logic depth (LUT5 levels, ROM register included) | 18 | 18 |

The vector-table boot and IRQ nesting rework costs about 52 LUT4 in this
proxy over the 594-LUT vendor run's RTL; 20 of those are the `vt_base`
relocation input (measured by tying it to zero). Vendor numbers predate
the rework.

## Benchmarks (rtl cycle-accurate, not certified)

`make bench-dhry` and `make bench-coremark` build with the pinned
base-H8/300 gcc-10 toolchain and count cycles in simulation:

| Metric | Value |
|---|---|
| Dhrystone | 6376 cycles/run, 0.089 DMIPS/MHz |
| CoreMark | 10.57M cycles/iteration, 0.095 CoreMark/MHz |

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
