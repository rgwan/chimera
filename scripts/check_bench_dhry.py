# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Audit a bench ELF against the decode golden table and score a run log.

--audit: every instruction word in the disassembly must map to a
non-illegal dispatch id (base-H8/300 only, all implemented in microcode).
--score: parse the testbench log, require the Dhrystone validation banner,
and print DMIPS per MHz (runs * 1e6 / cycles / 1757).
"""
import argparse
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from check_decode_dispatch import load_encodings, isa_dispatch

OBJDUMP = os.environ.get("BENCH_OBJDUMP", "h8300-elf-objdump")


def audit(elf: str) -> int:
    encodings = load_encodings()
    dis = subprocess.run([OBJDUMP, "-d", elf], capture_output=True,
                         text=True, check=True).stdout
    bad = {}
    for m in re.finditer(r"^\s*[0-9a-f]+:\s+((?:[0-9a-f]{2} )+)", dis, re.M):
        by = m.group(1).split()
        word = (int(by[0], 16) << 8) | int(by[1], 16)
        insn = isa_dispatch(encodings, word >> 8, word & 0xFF)
        if insn == "illegal":
            bad.setdefault(f"{word:04x}", 0)
            bad[f"{word:04x}"] += 1
    if bad:
        print(f"bench audit FAIL: illegal encodings {sorted(bad.items())}")
        return 1
    print("bench audit pass: all instruction words map to the base ISA")
    return 0


def score(log: str, runs: int) -> int:
    text = Path(log).read_text(encoding="utf-8", errors="replace")
    m = re.search(r"BENCH-EXIT code=\d+ start=(\d+) stop=(\d+) cycles=(\d+)",
                  text)
    if not m:
        print("bench score FAIL: no BENCH-EXIT record (timeout or crash)")
        return 1
    if "Final values of the variables used in the benchmark:" not in text:
        print("bench score FAIL: validation banner missing")
        return 1
    cycles = int(m.group(3))
    if cycles <= 0:
        print("bench score FAIL: empty timing window")
        return 1
    per_mhz = runs * 1e6 / cycles
    print(f"dhrystone: {runs} runs, {cycles} cycles, "
          f"{cycles / runs:.1f} cycles/run")
    print(f"dhrystones per second per MHz: {per_mhz:.1f}")
    print(f"DMIPS/MHz: {per_mhz / 1757.0:.4f} "
          f"(rtl cycle-accurate estimate)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--audit", metavar="ELF")
    ap.add_argument("--score", metavar="LOG")
    ap.add_argument("--runs", type=int, default=100)
    args = ap.parse_args()
    if args.audit:
        return audit(args.audit)
    if args.score:
        return score(args.score, args.runs)
    ap.error("need --audit or --score")
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
