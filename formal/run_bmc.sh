#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Run circt-bmc on a stripped module MLIR produced by formal/lower.sh.
# circt-bmc JITs the SMT problem and dlopen's z3 as a shared library, so it
# needs libz3.so via --shared-libs; the flake exposes it as $Z3_LIB.
#
# Usage: formal/run_bmc.sh <ModuleName> [bound] [mlir]
#   Prints circt-bmc output and exits 0 only if the bound is reached with no
#   violations. A violated property (broken variant) exits non-zero.
# Run inside `nix develop`.
set -euo pipefail

mod="${1:?usage: run_bmc.sh <ModuleName> [bound] [mlir]}"
bound="${2:-20}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mlir="${3:-$here/gen/${mod}_bmc.mlir}"

: "${Z3_LIB:?set Z3_LIB to libz3.so (nix develop provides it)}"
[ -f "$mlir" ] || { echo "[formal] missing $mlir; run lower.sh first" >&2; exit 2; }

out="$(circt-bmc "$mlir" -b "$bound" --module "$mod" \
  --rising-clocks-only --shared-libs="$Z3_LIB" 2>&1)"
echo "$out"
grep -q "Bound reached with no violations" <<<"$out"
