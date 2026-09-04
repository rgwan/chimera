#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Emit a copy of an hw-dialect MLIR file carrying exactly one assertion.
#
# Usage: formal/select_label.sh <in.mlir> <label> <out.mlir>
#
# The flatten step splices every child body into one module, so a child's
# assertion lands beside the parent's. A run over the merged file cannot say
# which property a verdict belongs to, and a broken child satisfies the
# parent's mutation gate. Checking one label at a time removes both.
set -euo pipefail

in="${1:?usage: select_label.sh <in.mlir> <label> <out.mlir>}"
label="${2:?usage: select_label.sh <in.mlir> <label> <out.mlir>}"
out="${3:?usage: select_label.sh <in.mlir> <label> <out.mlir>}"

[ -f "$in" ] || { echo "[formal] missing $in" >&2; exit 2; }
grep -q "label \"$label\"" "$in" ||
  { echo "[formal] $in carries no assertion labelled $label" >&2; exit 2; }

awk -v keep="$label" '
  /verif\.assert/ { if (index($0, "label \"" keep "\"")) print; next }
  { print }
' "$in" > "$out"

kept="$(grep -c 'verif\.assert' "$out" || true)"
[ "$kept" = 1 ] ||
  { echo "[formal] $out kept $kept assertions, expected 1" >&2; exit 2; }
