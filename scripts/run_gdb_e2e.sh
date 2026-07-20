#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
#
# End-to-end debug bring-up: launch the cocotb remote-bitbang server
# (test/cocotb/rbb) as a JTAG server and drive it with a jtag2gdb example over
# TCP. This packages the manual bring-up flow (build DM RTL, build the Rust tool,
# run the sim, attach) into one gate. Callers build the DM RTL sim first; this
# script only orchestrates the sim process, the host tool, and cleanup.
#
# The server does one accept(), so readiness is detected by passively polling the
# kernel socket table (/proc/net/tcp, ss fallback), never by a throwaway TCP
# probe that would consume that accept.
#
# Args:
#   $1  example name (sim_smoke | sim_bp | ...), default sim_bp
#   $2  TCP port, default 2542
#
# h8300-elf-gdb-in-the-loop is intentionally NOT wired here: the pure-Rust
# example is the CI gate. Driving real gdb through the RSP server is a manual
# bring-up step (jtag2gdb src/main.rs opens the RSP listener for that).
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
example="${1:-sim_bp}"
port="${2:-2542}"
gen="$here/rtl/generated"
build="$gen/cocotb_rbb_build"
log="$gen/sim_rbb_${port}.log"

test -d "$build" || { echo "missing $build (run 'run_rbb.py build' first)"; exit 1; }

sim_pid=""
cleanup() {
  if [ -n "$sim_pid" ] && kill -0 "$sim_pid" 2>/dev/null; then
    kill "$sim_pid" 2>/dev/null || true
    wait "$sim_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Build the example first: vvp startup (loading the multi-MB image, elaborating,
# running the reset sequence) can take several seconds before the VPI binds the
# port, and cargo's build should not eat into that window.
echo "[gdb-e2e] building example '$example'"
( cd "$here/tools/jtag2gdb" && cargo build --quiet --example "$example" )

# True if a LISTEN socket is open on 127.0.0.1:$port. Both probes are passive
# (they read kernel state, never open a TCP connection), so they do NOT consume
# the server's single accept() the way a /dev/tcp probe would.
port_hex=$(printf '%04X' "$port")
port_listening() {
  # Primary: /proc/net/tcp is always present on Linux. Column 2 is the local
  # address "HHHHHHHH:PPPP"; column 4 is the state (0A = LISTEN).
  if [ -r /proc/net/tcp ] &&
     awk -v p=":$port_hex" '$2 ~ p"$" && $4 == "0A" {found=1} END {exit !found}' \
       /proc/net/tcp 2>/dev/null; then
    return 0
  fi
  # Fallback: ss, if available.
  command -v ss >/dev/null 2>&1 && ss -ltn 2>/dev/null | grep -q ":$port "
}

echo "[gdb-e2e] launching sim on 127.0.0.1:$port"
( cd "$here" && RBB_PORT="$port" python3 test/cocotb/rbb/run_rbb.py run ) \
  > "$log" 2>&1 &
sim_pid=$!

# Wait (up to 60s) for the server to actually bind and listen; poll the kernel
# socket table rather than the sim's own log line.
echo "[gdb-e2e] waiting for sim to bind port $port"
listening=0
for _ in $(seq 1 600); do
  if port_listening; then listening=1; break; fi
  if ! kill -0 "$sim_pid" 2>/dev/null; then
    echo "[gdb-e2e] sim exited before binding port $port"
    cat "$log"
    exit 1
  fi
  sleep 0.1
done
if [ "$listening" != 1 ]; then
  echo "[gdb-e2e] sim never bound port $port within 60s"
  cat "$log"
  exit 1
fi

echo "[gdb-e2e] port listening; attaching jtag2gdb example '$example'"
( cd "$here/tools/jtag2gdb" && cargo run --quiet --example "$example" -- "127.0.0.1:$port" )

echo "[gdb-e2e] PASS ($example)"
