<!--
SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
SPDX-License-Identifier: MIT
-->

# Formal verification

Bounded model checking with CIRCT-native `circt-bmc`, run directly on the
zaozi-emitted design. Properties live in the zaozi source as `Assert(...)`
behind `parameter.formal`, so production RTL is byte-identical with formal off.
No external harness.

## Run

```bash
make verify-formal          # all properties
make check-formal-debug     # JTAG go-strobe is the sole launch gate
make check-formal-core      # Core debug-FSM transition invariants
make check-formal-decode    # decoder bucket tagging over all 64K opcodes
make check-formal-selftest  # the harness rejects an injected fault
```

Each target requires exit 0 from the true property and exit 1 from its
deliberately-broken variant; anything else is a harness failure, never a caught
bug. `EXPECT_LABELS` names the assertions the checked file must carry, so a
deleted or renamed property cannot pass as "no violations".

## Properties

| Target | Module | Guarantee |
|---|---|---|
| debug | JtagDtm | `reqReg` rises only on `updateDr & isControl & goStrobe & !reqReg` — a stuck-high or undriven cmd never launches a command |
| core | Core | auto-halt always drops the latch and resumes on completion; trap-2 is single-entry (no clear under nested service, no double-set) |
| decode | CoarseDecoder | for all 65536 opcodes the dispatch address lies in the range its own bucket tag selects; the three ranges are disjoint by construction, so decode is also unambiguous |

The debug property is an SVA implication over the real flops. The core ones are
single-cycle transition invariants whose antecedent is delayed through a
formal-only shadow register, so they still skip the cycle in which that register
holds its seed. circt-bmc seeds registers arbitrarily and applies no reset,
which proves all of them over every state rather than only the reachable ones.
They constrain the FSM registers, not downstream datapath behavior.

## Flow

`formal/lower.sh <Module>` builds with the needed config plus `FORMAL=true`,
runs `firtool --ir-hw`, and strips the DV-layer `sv.macro.decl` / `emit.file`
collateral that circt-bmc rejects. `formal/run_bmc.sh <Module> <bound>` runs
`circt-bmc --rising-clocks-only --shared-libs=$Z3_LIB` (the flake exposes
`libz3.so`); `IGNORE_ASSERTS_UNTIL=N` skips the first N cycles. Module `Core`
has children that lower.sh leaves as `hw.module.extern`, which circt-bmc cannot
see through, so `check-formal-core` splices every child body into one module.
That splice also pulls each child's assertion in beside Core's, so
`formal/select_label.sh` gives every label its own copy and each is checked
alone. Each target writes its own `formal/gen` subdirectory, so they run under
`make -j`.

## Adding a property

1. In the module's zaozi source, add `if parameter.formal then Assert(expr.I,
   "label")`. Use an immediate boolean (`.I`): circt-bmc cannot legalize a
   `verif.assert` on an `!ltl.property`. For a cross-cycle relation delay the
   antecedent through a formal-only shadow register and set
   `IGNORE_ASSERTS_UNTIL` to its depth.
2. Add a `check-formal-<name>` target mirroring an existing one, with its
   `EXPECT_LABELS` and a broken variant behind `FORMAL_BROKEN`.
3. Fold it into `verify-formal`.
