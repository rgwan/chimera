# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Score a CoreMark run log from the bench testbench.

Require the CoreMark self-validation line and the BENCH-EXIT cycle window,
then print CoreMark/MHz = iterations * 1e6 / cycles.
"""
import argparse
import re
from pathlib import Path


def score(log: str, iterations: int) -> int:
    text = Path(log).read_text(encoding="utf-8", errors="replace")
    m = re.search(r"BENCH-EXIT code=\d+ start=(\d+) stop=(\d+) cycles=(\d+)",
                  text)
    if not m:
        print("bench score FAIL: no BENCH-EXIT record (timeout or crash)")
        return 1
    if "Correct operation validated" not in text:
        print("bench score FAIL: CoreMark validation line missing")
        return 1
    cycles = int(m.group(3))
    if cycles <= 0:
        print("bench score FAIL: empty timing window")
        return 1
    print(f"coremark: {iterations} iterations, {cycles} cycles, "
          f"{cycles / iterations:.0f} cycles/iteration")
    print(f"CoreMark/MHz: {iterations * 1e6 / cycles:.4f} "
          f"(rtl cycle-accurate estimate, not EEMBC-certified)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--score", metavar="LOG", required=True)
    ap.add_argument("--iterations", type=int, default=1)
    args = ap.parse_args()
    return score(args.score, args.iterations)


if __name__ == "__main__":
    raise SystemExit(main())
