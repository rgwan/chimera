#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Lower a formal-enabled Chimera module to HW/comb/seq/verif MLIR that
# circt-bmc accepts. Builds the debug + formal RTL for one module, runs
# firtool --ir-hw, and strips the DV-layer sv.macro.decl / emit.file
# collateral (unregistered `sv` dialect ops circt-bmc rejects).
#
# Usage: formal/lower.sh <ModuleName> [out_dir]
#   FORMAL_BROKEN=true selects the deliberately-broken property variant.
# Env: DM/HW_BREAKPOINT/... forwarded to rtl/build.sh via the caller.
# Run inside `nix develop` (provides firtool via CIRCT_INSTALL_PATH).
set -euo pipefail

mod="${1:?usage: lower.sh <ModuleName> [out_dir]}"
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/.." && pwd)"
out="${2:-$here/gen}"
mkdir -p "$out"

# Build the module with debug + formal on. DM=true reaches the debug
# collateral JtagDtm needs; FORMAL=true emits the (unlayered) assert.
TOP="$mod" DM="${DM:-true}" FORMAL=true \
  FORMAL_BROKEN="${FORMAL_BROKEN:-false}" \
  HW_BREAKPOINT="${HW_BREAKPOINT:-false}" \
  HW_BREAKPOINT_COUNT="${HW_BREAKPOINT_COUNT:-0}" \
  SINGLE_STEP="${SINGLE_STEP:-false}" \
  CHIMERA_RTL_OUT="$out" bash "$root/rtl/build.sh"

hw="$out/${mod}_hw.mlir"
firtool "$out/${mod}.mlirbc" --ir-hw -o "$hw"

# Strip DV-layer collateral: the `sv.macro.decl @layers_*` op and the
# `emit.file "layers-*.sv" { ... }` block. circt-bmc does not register the
# `sv` dialect, so these top-level ops make it fail to parse. Everything the
# property needs already lives inside hw.module @<mod>.
stripped="$out/${mod}_bmc.mlir"
awk '
  /^  sv\.macro\.decl / { next }
  /^  emit\.file / { skip = 1; depth = 0 }
  skip {
    n = gsub(/{/, "{"); depth += n
    m = gsub(/}/, "}"); depth -= m
    if (depth <= 0) skip = 0
    next
  }
  { print }
' "$hw" > "$stripped"

echo "[formal] lowered $mod -> $stripped"
