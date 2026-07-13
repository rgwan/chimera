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
mod="${TOP:-Core}"
top="com.vowstar.chimera.$mod"

: "${ZAOZI_JAR:?set ZAOZI_JAR to the zaozi elaborator.jar}"
: "${CIRCT_INSTALL_PATH:?set CIRCT_INSTALL_PATH}"
: "${MLIR_INSTALL_PATH:?set MLIR_INSTALL_PATH}"
: "${JAVA_HOME:?set JAVA_HOME to JDK 25}"

mkdir -p "$out"

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
scala-cli run "${scala_args[@]}" "$src" -- \
  config "$out/config.json" --h8300h "${H8300H:-false}" \
  --strictDecode "${STRICT_DECODE:-false}" --romHex "${ROM_HEX:-false}" \
  --ccrUbit "${CCR_UBIT:-false}" --pipeline "${PIPELINE:-false}" \
  --debug "${DEBUG:-false}"

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
