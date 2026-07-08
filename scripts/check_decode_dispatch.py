# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Decoder-equivalence gate: the elaborated CoarseDecoder must map every 16-bit
word to the golden pre_decoded_instr (isa/decode_dispatch_golden.csv).

Expands the golden table to all 65536 words, simulates the generated
CoarseDecoder.sv with iverilog, and fails on any mismatch or coverage gap.

Env: COARSE_SV = path to the elaborated CoarseDecoder.sv
     (default rtl/generated/CoarseDecoder.sv). Requires iverilog + vvp.
"""
import csv
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CSV = ROOT / "isa" / "decode_dispatch_golden.csv"
TB = ROOT / "test" / "decode" / "tb_coarse_decoder.v"
SV = Path(os.environ.get("COARSE_SV", ROOT / "rtl" / "generated" / "CoarseDecoder.sv"))


def load_expected():
    expected = [None] * 65536
    with open(CSV) as f:
        for row in csv.reader(f):
            if not row or row[0].startswith("#") or row[0] == "first_byte":
                continue
            fb = int(row[0], 16)
            lo = int(row[1], 16)
            hi = int(row[2], 16)
            pre = int(row[3], 16)
            # decoder word is BIU-byteswapped: first byte in [7:0], second in [15:8]
            for sb in range(lo, hi + 1):
                expected[(sb << 8) | fb] = pre
    gaps = [w for w, v in enumerate(expected) if v is None]
    if gaps:
        sys.exit(f"golden table leaves {len(gaps)} words uncovered, e.g. {gaps[:5]}")
    return expected


def main():
    for tool in ("iverilog", "vvp"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found; run inside a shell that provides iverilog")
    if not SV.exists():
        sys.exit(f"{SV} not found; elaborate CoarseDecoder first (make rtl-verilog)")

    expected = load_expected()
    with tempfile.TemporaryDirectory() as d:
        d = Path(d)
        (d / "expected.mem").write_text("".join(f"{v:02x}\n" for v in expected))
        subprocess.run(["iverilog", "-o", str(d / "sim"), str(TB), str(SV)], check=True)
        out = subprocess.run(["vvp", str(d / "sim")], cwd=d, capture_output=True,
                             text=True, check=True).stdout
    print(out.strip())
    if "DECODE-EQUIV PASS" not in out:
        sys.exit(1)


if __name__ == "__main__":
    main()
