# Chimera Metrics

Measured numbers per configuration. Remeasure after RTL changes; the
microarchitecture itself is described in
[microarchitecture.md](microarchitecture.md).

## FPGA (evaluation standard)

The FPGA numbers of record come from the vendor place-and-route flow on
the EG4 target part (high-effort synthesis and physical optimization).
Lean configuration with the vector-table boot, microcode ROM in block
RAM, register file as distributed RAM, `irq_number` and `vt_base` as
live top-level inputs:

| Metric | Value |
|---|---|
| Logic | 674 LUT4/5, 2 x 9K block RAM |
| Clock | 61 MHz (16.35 ns minimum period) |

yosys generic mapping (`synth -top Core -lut <k> -flatten`,
`MicrocodeRom` blackboxed, `H8RegFile` counted in) remains a quick local
trend proxy only:

| | `lean` (default) | `strict` |
|---|---|---|
| LUT4 / LUT5 | 803 / 627 | 821 / 678 |
| Microcode words | 379 / 512 | 401 / 512 |
| Logic depth (LUT5 levels, ROM register included) | 18 | 18 |

The vector-table boot and IRQ nesting rework costs about 52 LUT4 in this
proxy (38 in the vendor flow, whose pre-rework best was 636); 20 of those
are the `vt_base` relocation input (measured by tying it to zero).

## Debug configuration

Numbers for the external-debug build (`dm` + `dtm`, vendor place-and-route
on the EG4 target); `debug.md` describes the subsystem.

| Metric | Value |
|---|---|
| LUT4 delta vs debug-off | about +250 (JtagDtm 96 LUT4 / 107 DFF after the shared-DR trim, plus the in-core DM taps) |
| FF delta (single-step + trap-2) | about +6 |
| Fmax | about 57 MHz (critical path unchanged, ROM to CCR) |
| Debug off | byte-identical to `lean` |

The TD run of the full debug tier (P4) is 969 LUT / 180 registers at
56.7 MHz. Every debug knob off leaves each leaf module byte-identical, so
the `lean`/`pipe`/`strict` numbers above are unaffected.

## Benchmarks (rtl cycle-accurate, not certified)

`make bench-dhry` and `make bench-coremark` build with the pinned
base-H8/300 gcc-10 toolchain and count cycles in simulation:

| Metric | Chimera (lean) | Classic 8051 | Enhanced 8051 (STC8A8K64S4A) |
|---|---|---|---|
| Dhrystone | 4265 cycles/run, 0.134 DMIPS/MHz (9 ~ 14 times faster than 8051 at same frequency) | ~ 0.0094 DMIPS/MHz | ~0.09 DMIPS/MHz |
| CoreMark | 9.69M cycles/iteration, 0.103 CoreMark/MHz | No sufficient memory for 8051 to run CoreMark | Not tested yet |

Enhanced 8051 benchmark performance is from [this repo](https://github.com/tomzbj/dhrystone_score).


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
