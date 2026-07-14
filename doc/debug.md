# Chimera Debug

Debug features are independent config knobs on a shared microcode-driven
datapath. Software breakpoints are always present. Single-step and
hardware breakpoints work self-hosted (program-driven MMIO) or through the
debug module (DM), which adds external-debugger access over a transport.
Every feature off (default) is byte-identical; numbers in
[metrics.md](metrics.md).

## Configuration

| Knob | Type | Effect |
|---|---|---|
| `dm` | Boolean | debug-module port for an external debugger; implies `dtm` |
| `dtm` | Boolean | JTAG debug-transport; required by `dm` |
| `hardwareBreakpoint` | Boolean | MMIO trigger unit (self-hosted or DM-driven) |
| `hwBreakpointCount` | Int (0..8) | comparator units; `>0` requires `hardwareBreakpoint` |
| `singleStep` | Boolean | MMIO single-step control register |
| `dbgBase` | Int (16-bit) | MMIO window base; required by `hardwareBreakpoint` or `singleStep` |
| `idcode` | Long | JTAG IDCODE value (default `0x00114514`) |

Derived: `debug = dm`, `mmio = hardwareBreakpoint || singleStep`.
Requires: `dm ⟹ dtm`; `hwBreakpointCount>0 ⟹ hardwareBreakpoint`;
`hardwareBreakpoint | singleStep ⟹ dbgBase`. Single-step and hardware
breakpoints are DM-independent.

## Self-hosted vs external

- Self-hosted: a program drives the `dbgBase` MMIO registers inside its
  own TRAP #2 handler. No DM. A trigger or step fires TRAP #2; the
  handler polls `STEP.PEND` / `HWBP_STAT`, reprograms, returns via RTE.
- External: `dm` + `dtm` + the `jtag2gdb` host tool drive mem/PC/halt and
  the same MMIO registers over JTAG.

## Routing

A software breakpoint (`TRAPA #2`), a hardware-breakpoint hit, or a
single-step boundary redirects to the reserved DebugEntry microcode when
a DM is present (`dmActive`), else to the TRAP #2 handler. Inside a
self-hosted TRAP #2 handler, further step/bp fires are suppressed and
restored at RTE unless the handler rewrote a debug register. Instruction
breakpoints fire before execution; data breakpoints fire after the access.

## JTAG debug-transport register map

Standard IEEE 1149.1 TAP, 4-bit IR (reset = IDCODE); the DRs share one
36-bit shift register (external scan lengths unchanged).

| IR | DR | Width | Access |
|---|---|---|---|
| `0x0` | STATUS | 23 | read-only |
| `0x1` | IDCODE | 32 | read-only |
| `0x2` | CONTROL | 36 | read/write |
| `0xF` | BYPASS | 1 | — |

STATUS, LSB-first: `[0]` is_halted, `[1]` is_sleeping, `[17:2]`
dbg_base, `[21:18]` hwbp_count, `[22]` dmactive. Served entirely by DTM
hardware; the host reads dbg_base to find the MMIO registers. dmactive
latches on the first CONTROL access and clears on TLR / TRST.

CONTROL, LSB-first: `[2:0]` cmd, `[18:3]` addr, `[34:19]` data
(write = dataFromHost, read = dataToHost), `[35]` in_progress / go-strobe.
A CONTROL Update with the top bit set launches a command; re-scanning it
clear polls in_progress without relaunching.

cmd encoding (3-bit): `0` Nop (a zeroed CONTROL is inert), `1` MemWrite,
`2` SetPc, `3` Halt, `4` Resume, `5` ReadPc, `6` MemRead, `7` ReadCcr
(non-destructive, from the CCR captured on park entry). Halt and Resume
are separate. in_progress means a command is running; is_halted means the
core is in debug mode.

## MMIO register map (`dbgBase`, 32-byte window)

16-bit words indexed by `addr[4:1]`:

| Offset | Register | Fields |
|---|---|---|
| `0x0` | STEP | `[0]` EN, `[1]` ONESHOT, `[2]` PEND (W1C), `[11:8]` HWBPCOUNT (read-only) |
| `0x2`..`0x6` | reserved | — |
| `0x8 + i*4` | HWBP_ADDR i | 16-bit compare address |
| `0xA + i*4` | HWBP_CTL i | `[0]` EN, `[1]` TYPE (0=instr,1=data), `[2]` RD, `[3]` WR |
| after last unit | HWBP_STAT | fired bits `[N-1:0]`, W1C |

HWBPCOUNT lets a self-hosted program discover the breakpoint count with
one load. Comparator fires are registered off the fetch / bus critical
path; a unit fires once per instruction and rearms at retire.

## Breakpoints and single-step

- Software: MemWrite `TRAPA #2` (`0x5720`) over the original word,
  restored by a second MemWrite. No dedicated registers.
- Hardware: HWBP_CTL selects instruction (before) or data (after, RD/WR
  qualified) match against HWBP_ADDR.
- Single-step: STEP.EN arms; one retire later `stepFire` redirects like a
  breakpoint. ONESHOT self-clears EN; PEND is the self-hosted witness.

## `jtag2gdb` host tool

Rust RSP front end for `h8300-elf-gdb`; backend is `ft232_mpsse` (FTDI
MPSSE for FPGA) or `sim_socket` (cocotb sim). The `g`/`G` block is 13 raw
registers = 26 bytes, big-endian per register (r0..r7, r7=sp, plus
sim-only counters zeroed by the bridge); CCR is a cooked pseudo-reg (gdb
Nr 13) via `p`/`P`, served by ReadCcr. GPRs go through the program buffer
(inject a MOV, run it, read a work area). Breakpoints advertise
`Z0`/swbreak with `TRAPA #2`; gdb does software single-step. An RTT
terminal mode reads a target-RAM control block over auto-halt mem access
(host-tool only, no extra RTL).

## Semihosting halt-first invariant

DM MemRead / MemWrite are halt-state-preserving and defined only while
halted; a running mem op is safely ignored. The host must Halt (wait for
STATUS.is_halted), access, then Resume. The DM auto-halt FSM collapses
that into one host command: while running it auto-halts at the next
retire, accesses, and auto-resumes; while halted it stays halted.

## Topology

See [diagrams/chimera-debug.drawio.svg](diagrams/chimera-debug.drawio.svg)
for the host chain, the TCK/core-clock CDC boundary, and the
`dmActive`-gated fork to DebugEntry (external) or the TRAP #2 handler
(self-hosted).

```
h8300-elf-gdb --RSP--> jtag2gdb --> FT232 / sim socket --> JTAG DTM --> DM --> Core
                          `-- RTT terminal

self-hosted:  program --> dbgBase MMIO (STEP / HWBP) --> TRAP #2 --> Core
```
