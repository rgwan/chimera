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
# a memory-safety fault whose trigger moves with the allocator. A run that
# completes is deterministic, so retrying yields the same result a
# single-attempt run would have produced.
set -uo pipefail

in="${1:?usage: ltl_lower.sh <in.mlir> <out.mlir>}"
out="${2:?usage: ltl_lower.sh <in.mlir> <out.mlir>}"
tries="${LTL_LOWER_TRIES:-8}"

for _ in $(seq 1 "$tries"); do
  if circt-opt "$in" --pass-pipeline='builtin.module(hw.module(lower-ltl-to-core,
    lower-seq-shiftreg,lower-seq-compreg-ce,canonicalize))' -o "$out" 2>/dev/null
  then
    exit 0
  fi
done

echo "[formal] lower-ltl-to-core failed $tries times on $in" >&2
exit 2
