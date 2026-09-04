#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Run circt-bmc on a stripped module MLIR produced by formal/lower.sh.
# circt-bmc JITs the SMT problem and dlopen's z3 as a shared library, so it
# needs libz3.so via --shared-libs; the flake exposes it as $Z3_LIB.
#
# Usage: formal/run_bmc.sh <ModuleName> [bound] [mlir]
# Env:
#   EXPECT_LABELS       comma-separated assertion labels the file must carry,
#                       exactly. Required: circt-bmc reports "no violations"
#                       for a module holding zero properties, so the caller
#                       has to say what it expects to be checked.
#   IGNORE_ASSERTS_UNTIL=N  skip the first N cycles.
# Exit:
#   0  the property held to the bound
#   1  the property was violated (what a deliberately-broken variant must give)
#   2  the run itself failed: missing file, wrong label set, no property, or a
#      tool error. Never conflate this with 1; a lowering failure is not a
#      caught bug.
# Run inside `nix develop`.
set -uo pipefail

die() { echo "[formal] $*" >&2; exit 2; }

mod="${1:?usage: run_bmc.sh <ModuleName> [bound] [mlir]}"
bound="${2:-20}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mlir="${3:-$here/gen/${mod}_bmc.mlir}"
ignore="${IGNORE_ASSERTS_UNTIL:-0}"

: "${Z3_LIB:?set Z3_LIB to libz3.so (nix develop provides it)}"
[ -n "${EXPECT_LABELS:-}" ] || die "set EXPECT_LABELS to the labels $mod must carry"
[ -f "$mlir" ] || die "missing $mlir; run lower.sh first"

# The file must carry exactly the labels the caller named. This is what stops a
# renamed, deleted or constant-folded property from passing as "no violations".
got="$(grep -o 'verif\.assert[^\n]*label "[A-Za-z0-9_]*"' "$mlir" |
  sed 's/.*label "//; s/"//' | sort -u | paste -sd, -)"
want="$(tr ',' '\n' <<<"$EXPECT_LABELS" | sort -u | paste -sd, -)"
[ -n "$got" ] || die "$mlir carries no labelled verif.assert"
[ "$got" = "$want" ] || die "label set mismatch in $mlir: want [$want], got [$got]"

out="$(circt-bmc "$mlir" -b "$bound" --module "$mod" \
  --ignore-asserts-until="$ignore" \
  --rising-clocks-only --shared-libs="$Z3_LIB" 2>&1)"
echo "$out"

# circt-bmc prints the success line even for a module it found nothing to check
# in, so the warning has to be read before the verdict.
grep -q "no property provided to check" <<<"$out" &&
  die "circt-bmc found no property in $mod"

grep -q "Bound reached with no violations" <<<"$out" && exit 0
grep -q "Assertion can be violated" <<<"$out" && exit 1
die "circt-bmc gave no verdict for $mod"
