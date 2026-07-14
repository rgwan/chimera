#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# Elaborate the Chimera core to SystemVerilog: scala-cli config -> design ->
# firtool. Run inside a zaozi dev shell that provides scala-cli, firtool, and
# these env vars: ZAOZI_JAR, CIRCT_INSTALL_PATH, MLIR_INSTALL_PATH.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$here/src"
out="${CHIMERA_RTL_OUT:-$here/generated}"
# With a debug module (dm) on, the elaborated top is CoreTop (Core + JTAG DTM);
# an explicit TOP still wins for module-level builds (TOP=Microsequencer, etc.).
# A self-hosted-only build (hardwareBreakpoint / singleStep without dm) keeps
# Core as the top.
if [ -n "${TOP:-}" ]; then
  mod="$TOP"
elif [ "${AXIL:-false}" = "true" ]; then
  mod="CoreTopAxi"
elif [ "${DM:-false}" = "true" ]; then
  mod="CoreTop"
else
  mod="Core"
fi
top="com.vowstar.chimera.$mod"

: "${ZAOZI_JAR:?set ZAOZI_JAR to the zaozi elaborator.jar}"
: "${CIRCT_INSTALL_PATH:?set CIRCT_INSTALL_PATH}"
: "${MLIR_INSTALL_PATH:?set MLIR_INSTALL_PATH}"
: "${JAVA_HOME:?set JAVA_HOME to JDK 25}"

mkdir -p "$out"

# Clear stale elaboration collateral so a run is never polluted by a previous
# top / config. Each design pass re-emits one mlirbc per module in the current
# top and firtool re-lowers the full set, so nothing needed is lost. Without
# this a debug=true build leaves CoreTop.sv / JtagDtm.sv behind, and a later
# debug=false sim that globs generated/*.sv would compile them against a
# debug-less Core and fail.
rm -f "$out"/*.sv "$out"/*.mlirbc "$out"/urom.memh

scala_args=(
  --server=false
  --extra-jars "$ZAOZI_JAR"
  --scala-version 3.7.4
  --java-home "$JAVA_HOME"
  -O=-experimental
  --java-opt --enable-native-access=ALL-UNNAMED
  --java-opt --enable-preview
  --java-opt "-Djava.library.path=$CIRCT_INSTALL_PATH/lib:$MLIR_INSTALL_PATH/lib"
  --main-class "$top"
)

echo "[chimera-rtl] config"
# dm implies dtm; the debug preset elaborates CoreTop which needs both. Default
# dtm to the dm value so a plain DM=true build satisfies the dm=>dtm require.
scala-cli run "${scala_args[@]}" "$src" -- \
  config "$out/config.json" --h8300h "${H8300H:-false}" \
  --strictDecode "${STRICT_DECODE:-false}" --romHex "${ROM_HEX:-false}" \
  --ccrUbit "${CCR_UBIT:-false}" --pipeline "${PIPELINE:-false}" \
  --dm "${DM:-false}" --dtm "${DTM:-${DM:-false}}" \
  --hardwareBreakpoint "${HW_BREAKPOINT:-false}" \
  --hwBreakpointCount "${HW_BREAKPOINT_COUNT:-0}" \
  --singleStep "${SINGLE_STEP:-false}" \
  --dmAutoHalt "${DM_AUTO_HALT:-${DM:-false}}" \
  --formal "${FORMAL:-false}" --formalBroken "${FORMAL_BROKEN:-false}" \
  --axilite "${AXIL:-false}" --axiDataWidth "${AXI_DATA_WIDTH:-32}" \
  --dbgBase "${DBG_BASE:-65280}"

echo "[chimera-rtl] design"
( cd "$out" && scala-cli run "${scala_args[@]}" "$src" -- design "$out/config.json" )

echo "[chimera-rtl] firtool"
# The design pass emits one mlirbc per module; lower each to its own .sv. Core's
# DV layer also emits layers-Core-DV.sv / ref_Core.sv collateral (production sims
# exclude those; trace sims include them).
for f in "$out"/*.mlirbc; do
  firtool "$f" --split-verilog -disable-all-randomization -O=release \
    --lowering-options=disallowLocalVariables,disallowPackedArrays,locationInfoStyle=none \
    -o "$out"
done

if [ "${ROM_HEX:-false}" = "true" ]; then
  cp "$here/verilog/MicrocodeRomHex.sv" "$out/MicrocodeRom.sv"
  rm -f "$out"/layers-MicrocodeRom-DV.sv
fi

echo "[chimera-rtl] wrote SystemVerilog to $out"
