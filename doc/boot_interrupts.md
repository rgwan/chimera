# Chimera Boot and Interrupts

## Vector table (platform ABI)

32-bit slots; the fixed H8/300 configuration reads the low halfword of
each. All addresses are offset by `vt_base << 8`.

| Slot | Address read | Meaning |
|---|---|---|
| 0 | 0x0002 | reset SP |
| 1 | 0x0006 | reset PC |
| 2 | 0x000A | reserved |
| 3 | 0x000E | NMI |
| 4..7 | 0x0010 + 2t | TRAPA #t |
| 8.. | 0x0018 + 2i | IRQ #i (`irq_number` input) |

From NMI onward the physical addresses match H8/300 normal mode; the
extension is hardware SP load and the moved reset PC.

## Boot

Reset enters the microcode at its own entry whose first word is the
all-zero no-op (ROMs may miss the first read after reset). Microcode
then loads SP from 0x0002 and PC from 0x0006 over the bus and retires
into the fetch loop. CCR.I resets to 1: interrupts stay masked until
boot code has configured the sources and clears I (`andc #0x7f, ccr`).

## Interrupt behavior

- `irq` (level) latches; it is served at an instruction retire when no
  IRQ is already in service, no NMI is in service, and CCR.I is clear.
  The vector index is the `irq_number` input (default 3 bits), sampled
  at acceptance.
- Service pushes PC then CCR, sets I, reads the vector, and enters the
  handler. The handler's RTE restores CCR and PC and clears the
  in-service state; only then can the next IRQ be taken.
- NMI and debug requests may preempt a running IRQ handler. A nested
  RTE pops the innermost level first: after the NMI handler's RTE the
  interrupted IRQ handler continues.
- TRAPA #t (t = 0,1,3) enters through the same push/vector sequence at
  its own slot regardless of CCR.I; TRAPA #2 routes to the debug entry.

## Halt status (`core_sleeping`)

The top-level output `core_sleeping` is high while the core is parked in
the SLEEP wait loop and low otherwise. It is registered so it is
glitch-free for gating an external clock, and the SLEEP wait word issues
no bus request, so no transaction is in flight while it is asserted. A
TRAPA #2 without a debugger runs the normal exception flow and does not
assert it. A separate debug-halt status waits for the debug spec.

## Relocation (`vt_base`)

The 8-bit `vt_base` input ORs a page offset into every vector address:
`vt_base = 0x01` moves the whole table to 0x0100. A boot ROM can run
with one table and hand the application another by switching the pin
from external logic.
