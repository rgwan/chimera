<!--
SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
SPDX-License-Identifier: MIT
-->

# Formal verification

Bounded model checking with CIRCT-native `circt-bmc`, run directly on the
zaozi-emitted design. Properties are written in zaozi as `Assert(...)` behind
`parameter.formal`, so production RTL is byte-identical (formal off = zero
asserts). No yosys, SymbiYosys, or hand-written SVA harness.

## Run

```bash
make verify-formal        # all properties
make check-formal-debug   # JTAG go-strobe is the sole launch gate
make check-formal-core    # Core debug-FSM transition invariants
make check-formal-decode  # decoder totality over all 64K opcodes
```

Each target proves the true property (`Bound reached with no violations!`) and
requires its deliberately-broken variant to be caught (`Assertion can be
violated!`), so a check can never pass vacuously.

## Properties

| Target | Module | Guarantee |
|---|---|---|
| debug | JtagDtm | `reqReg` rises only on `updateDr & isControl & goStrobe & !reqReg` — a stuck-high or undriven cmd never launches a command |
| core | Core | auto-halt always drops the latch and resumes on completion; trap-2 is single-entry (no clear under nested service, no double-set); `dmPresent` disables trap-2 suppression |
| decode | CoarseDecoder | every one of the 65536 opcodes maps to exactly one of three disjoint dispatch buckets — decode is total and unambiguous |

The debug and core properties are single-cycle transition invariants: the
antecedent is delayed through a formal-only shadow register so the assertion
reads the real flop, not a hand-copied next-state expression. circt-bmc seeds
registers arbitrarily and applies no reset, so those targets skip the first
cycle, where the shadow register still holds its seed. They constrain the FSM
registers, not downstream datapath behavior.

## Flow

`formal/lower.sh <Module>` builds with the needed config plus `FORMAL=true`,
runs `firtool --ir-hw`, and strips the DV-layer `sv.macro.decl` / `emit.file`
collateral that circt-bmc rejects. `formal/run_bmc.sh <Module> <bound>` runs
`circt-bmc --rising-clocks-only --shared-libs=$Z3_LIB` (the flake exposes
`libz3.so`); `IGNORE_ASSERTS_UNTIL=N` skips the first N cycles. Module `Core`
has children, which lower.sh leaves as `hw.module.extern` — `--flatten-modules`
cannot inline those, so `check-formal-core` first splices every child's lowered
body into one self-contained module before checking.

## Adding a property

1. In the module's zaozi source, add `if parameter.formal then Assert(expr.I,
   "label")` where the signals are in scope. Use an immediate boolean (`.I`):
   firtool lowers `|=>` / `##` fine for SVA, but circt-bmc cannot legalize a
   `verif.assert` on an `!ltl.property`. For a cross-cycle relation delay the
   antecedent through a formal-only shadow register (`val aPast =
   RegInit(false.B); aPast := a`) and assert against the real register, then run
   with `IGNORE_ASSERTS_UNTIL` set to the shadow depth.
2. Add a `check-formal-<name>` target mirroring an existing one, with a broken
   variant behind `FORMAL_BROKEN`.
3. Fold it into `verify-formal`.
