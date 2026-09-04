<!--
SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
SPDX-License-Identifier: MIT
-->

# Formal verification

Bounded model checking with CIRCT-native `circt-bmc`, run on the zaozi-emitted
design. Properties live in the zaozi source as `Assert(...)` behind
`parameter.formal`, so production RTL is byte-identical with formal off.

## Run

```bash
make verify-formal          # all properties
make check-formal-debug     # JTAG go-strobe is the sole launch gate
make check-formal-core      # Core debug-FSM transition invariants
make check-formal-decode    # decoder bucket tagging over all 64K opcodes
make check-formal-selftest  # the harness rejects an injected fault
```

Each property target requires exit 0 from the true property and exit 1 from its
broken twin; anything else is a harness failure, never a caught bug. `EXPECT_LABELS`
names the assertions the checked file must carry, so a deleted or renamed
property cannot pass as "no violations".

## Properties

| Target | Module | Guarantee |
|---|---|---|
| debug | JtagDtm | `reqReg` rises only on `updateDr & isControl & goStrobe & !reqReg` — a stuck-high or undriven cmd never launches a command |
| core | Core | an auto-halt request latches the halt and its completion releases it; trap-2 suppression clears only on a non-nested RTE and sets only on the ack |
| decode | CoarseDecoder | for all 65536 opcodes the dispatch address lies in the range its own bucket tag selects; the three ranges are disjoint by construction, which the solver is not asked to show |

The debug and core properties are SVA implications over the real flops, each a
named clause with its own `FORMAL_BROKEN` index so none rides on another's twin;
the decode property is combinational. circt-bmc seeds registers arbitrarily and
drives reset freely, proving each clause over every state rather than only the
reachable ones, so a clause whose consequent is "still set" excludes reset.
They constrain the FSM registers, not the datapath.

## Flow

`formal/lower.sh <Module>` builds with `FORMAL=true`, runs `firtool --ir-hw`,
strips the DV-layer collateral circt-bmc rejects, and lowers temporal operators
to registers and comb. `formal/run_bmc.sh <Module> <bound>` runs `circt-bmc
--rising-clocks-only --shared-libs=$Z3_LIB`. Module `Core` has children that
stay `hw.module.extern`, which circt-bmc cannot see through, so
`check-formal-core` splices every child body into one module; that also pulls
each child's assertion in beside Core's, so `formal/select_label.sh` gives every
label its own copy. Each target owns a `formal/gen` subdirectory, so a stale
artefact from one cannot reach another.

## Adding a property

1. Open a `given ClockEvent` and add `if parameter.formal then
   Assert(a.S |=> b.S, "label")`. Usable operators: `|-> |=> ## & | ! intersect
   implies iff * #-# #=#`; `throughout`, `within`, `until` and `eventually` do
   not lower. An assumption cannot constrain the history a property samples, so
   every antecedent must be a design flop.
2. Give the clause its own `FORMAL_BROKEN` index and a twin that weakens the
   antecedent, never one that negates the consequent.
3. Add a `check-formal-<name>` target with its `EXPECT_LABELS`, and fold it
   into `verify-formal`.
