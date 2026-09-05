#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Lower temporal operators to registers and comb, retrying a tool crash.
#
# Usage: formal/ltl_lower.sh <in.mlir> <out.mlir>
#
# lower-ltl-to-core faults intermittently inside eraseDeadLTLTree, at roughly
# one run in five on this design. It is not a resource limit: the rate is
# unchanged with an unlimited stack and with MLIR threading disabled, so it is
# a memory-safety fault whose trigger moves with the allocator.
#
# Only a crash is retried. A clean non-zero exit is a real tool error and is
# reported with its diagnostic, because retrying it eight times would hide it.
# The retry rests on the pass being deterministic when it completes, so that
# is checked rather than assumed: the run is repeated and the two outputs must
# match before either is accepted.
set -uo pipefail

in="${1:?usage: ltl_lower.sh <in.mlir> <out.mlir>}"
out="${2:?usage: ltl_lower.sh <in.mlir> <out.mlir>}"
tries="${LTL_LOWER_TRIES:-8}"
pipeline='builtin.module(hw.module(lower-ltl-to-core,lower-seq-shiftreg,
  lower-seq-compreg-ce,canonicalize))'

err="$(mktemp)"; tmp="$(mktemp)"; ref="$(mktemp)"
trap 'rm -f "$err" "$tmp" "$ref"' EXIT

run() {  # <dest> -> 0 ok, 1 tool error, 2 crash
  local rc
  circt-opt "$in" --pass-pipeline="$pipeline" -o "$1" 2>"$err"; rc=$?
  [ "$rc" = 0 ] && return 0
  # 130 and 143 are the user interrupting, not the pass faulting.
  case $rc in 130|143) echo "[formal] interrupted" >&2; exit "$rc" ;; esac
  [ "$rc" -ge 128 ] && return 2
  return 1
}

got=0
for _ in $(seq 1 "$tries"); do
  run "$tmp"; case $? in
    0) got=1; break ;;
    1) echo "[formal] lowering failed on $in" >&2; cat "$err" >&2; exit 2 ;;
  esac
done
[ "$got" = 1 ] || {
  echo "[formal] lowering crashed $tries times on $in" >&2
  cat "$err" >&2; exit 2
}

# A second completed run must agree, or the crash is corrupting the result and
# retrying is not sound. It has to complete first, or the mismatch below would
# blame nondeterminism for what was really more crashes.
got=0
for _ in $(seq 1 "$tries"); do
  run "$ref"; case $? in
    0) got=1; break ;;
    1) echo "[formal] lowering failed on the confirming run of $in" >&2
       cat "$err" >&2; exit 2 ;;
  esac
done
[ "$got" = 1 ] || {
  echo "[formal] confirming lowering crashed $tries times on $in" >&2
  cat "$err" >&2; exit 2
}
cmp -s "$tmp" "$ref" || {
  echo "[formal] two lowerings of $in disagree; the retry is not sound" >&2
  exit 2
}

mv "$tmp" "$out" || { echo "[formal] could not write $out" >&2; exit 2; }
trap 'rm -f "$err" "$ref"' EXIT
