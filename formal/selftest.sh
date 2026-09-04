#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Prove the formal harness can fail. Each case damages a lowered module the way
# a real regression would and requires run_bmc.sh to report it, so "the gate is
# green" carries information.
#
# Usage: formal/selftest.sh [lowered.mlir]
#   With no argument it lowers the decoder itself, which is the cheapest module
#   and the only way to be sure the positive control really is the honest one:
#   check-formal-decode leaves the broken variant behind.
# Run inside `nix develop`.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fails=0

src="${1:-}"
if [ -z "$src" ]; then
  TOP=CoarseDecoder DM=false DTM=false FORMAL_BROKEN=0 \
    bash "$here/lower.sh" CoarseDecoder "$work/gen" >/dev/null 2>&1 ||
    { echo "[selftest] could not lower the decoder" >&2; exit 2; }
  src="$work/gen/CoarseDecoder_bmc.mlir"
fi
[ -f "$src" ] || { echo "[selftest] missing $src" >&2; exit 2; }

# want <expected-exit> <case-name> <labels> <file>
want() {
  local exp="$1" name="$2" labels="$3" file="$4" rc
  EXPECT_LABELS="$labels" bash "$here/run_bmc.sh" CoarseDecoder 1 "$file" \
    >/dev/null 2>&1
  rc=$?
  if [ "$rc" = "$exp" ]; then
    printf '[selftest] ok    %-28s exit %s\n' "$name" "$rc"
  else
    printf '[selftest] FAIL  %-28s exit %s, wanted %s\n' "$name" "$rc" "$exp"
    fails=$((fails + 1))
  fi
}

cp "$src" "$work/honest.mlir"
want 0 honest dispatch_bucket_tag "$work/honest.mlir"

# Exit 1 is the verdict the whole gate rests on, so it gets a case of its own:
# without it a violation reported as 0 would surface as an RTL regression.
TOP=CoarseDecoder DM=false DTM=false FORMAL_BROKEN=1 \
  bash "$here/lower.sh" CoarseDecoder "$work/broken" >/dev/null 2>&1 ||
  { echo "[selftest] could not lower the broken decoder" >&2; exit 2; }
want 1 property-violated dispatch_bucket_tag "$work/broken/CoarseDecoder_bmc.mlir"

grep -v 'verif\.assert' "$src" > "$work/noassert.mlir"
want 2 property-deleted dispatch_bucket_tag "$work/noassert.mlir"

sed 's/label "dispatch_bucket_tag"/label "renamed"/' "$src" \
  > "$work/renamed.mlir"
want 2 property-renamed dispatch_bucket_tag "$work/renamed.mlir"

want 2 label-set-mismatch not_the_label "$work/honest.mlir"

want 2 missing-file dispatch_bucket_tag "$work/absent.mlir"

sed 's/^  hw\.module @CoarseDecoder/  hw.module @Other/' "$src" \
  > "$work/wrongmod.mlir"
want 2 module-not-found dispatch_bucket_tag "$work/wrongmod.mlir"

if [ "$fails" = 0 ]; then
  echo "[selftest] harness rejects every injected fault"
else
  echo "[selftest] $fails case(s) the harness failed to reject" >&2
  exit 1
fi
