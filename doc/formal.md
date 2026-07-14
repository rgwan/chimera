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

The Core properties are single-cycle transition invariants over recomputed
next-state values; they hold from any initial register state (circt-bmc gives
registers arbitrary initial values — there is no reset). They constrain the FSM
registers, not downstream datapath behavior.

## Flow

`formal/lower.sh <Module>` builds with the needed config plus `FORMAL=true`,
runs `firtool --ir-hw`, and strips the DV-layer `sv.macro.decl` / `emit.file`
collateral that circt-bmc rejects. `formal/run_bmc.sh <Module> <bound>` runs
`circt-bmc --rising-clocks-only --shared-libs=$Z3_LIB` (the flake exposes
`libz3.so`). Module `Core` has children, so `check-formal-core` first splices
every child's lowered body into one self-contained module before checking.

## Adding a property

1. In the module's zaozi source, add `if parameter.formal then Assert(expr.I,
   "label")` where the signals are in scope. Use an immediate boolean (`.I`);
   `|=>` / `##` LTL delays do not lower in circt-bmc. For stateful logic assert a
   single-cycle relation over the register's recomputed next-state value.
2. Add a `check-formal-<name>` target mirroring an existing one, with a broken
   variant behind `FORMAL_BROKEN`.
3. Fold it into `verify-formal`.
