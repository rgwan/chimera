# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Validate the dispatch table and compare CoarseDecoder against it.

Env: COARSE_SV = path to the elaborated CoarseDecoder.sv
     (default rtl/generated/CoarseDecoder.sv). Requires iverilog + vvp.
"""
import argparse
import csv
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CSV = ROOT / "isa" / "decode_dispatch_golden.csv"
YAML = ROOT / "isa" / "h8300_base_cases.yaml"
TB = ROOT / "test" / "decode" / "tb_coarse_decoder.v"
SV = Path(os.environ.get("COARSE_SV", ROOT / "rtl" / "generated" / "CoarseDecoder.sv"))


CSV_HEADER = """# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
# Chimera decode-dispatch golden table (decoder-equivalence reference).
# Generated from isa/h8300_base_cases.yaml mask/match; do not hand-edit.
# isa_word: bits[15:8]=first opcode byte, [7:0]=second byte.
# dispatch = ISA ground truth from the instruction table.
# pre_decoded_instr = coarse-decode formula over the byte-swapped RTL IR.
first_byte,sb_lo,sb_hi,pre_decoded_instr,dispatch
"""


def load_encodings():
    root = yaml.safe_load(YAML.read_text(encoding="utf-8"))
    encodings = []
    for item in root["instructions"]:
        encoding = item.get("encoding")
        if encoding is None:
            continue
        encodings.append((
            item["id"],
            int(encoding["mask"], 16),
            int(encoding["match"], 16),
        ))
    return encodings


def isa_dispatch(encodings, first_byte, second_byte):
    word = (first_byte << 8) | second_byte
    matches = [
        instr_id
        for instr_id, mask, match in encodings
        if (word & mask) == match
    ]
    if len(matches) > 1:
        raise ValueError(f"ambiguous ISA dispatch for 0x{word:04x}: {matches}")
    return matches[0] if matches else "illegal"


def coarse_dispatch(first_byte, second_byte):
    d = (first_byte >> 7) & 1
    mf = (second_byte >> 7) & 1
    sym = ((first_byte >> 6) & 1) == ((first_byte >> 5) & 1)
    ooo_nz = ((first_byte >> 4) & 7) != 0
    if d:
        return 0x80 | ((first_byte >> 4) & 7)
    if sym and mf and ooo_nz:
        return 0xC0 | (first_byte & 0x3F)
    return first_byte


def generate_rows(encodings):
    rows = []
    for first_byte in range(256):
        start = 0
        last = None
        for second_byte in range(256):
            current = (
                coarse_dispatch(first_byte, second_byte),
                isa_dispatch(encodings, first_byte, second_byte),
            )
            if last is None:
                last = current
            elif current != last:
                rows.append((first_byte, start, second_byte - 1, *last))
                start = second_byte
                last = current
        rows.append((first_byte, start, 0xFF, *last))
    return rows


def write_generated(rows):
    with CSV.open("w", encoding="utf-8", newline="") as f:
        f.write(CSV_HEADER)
        writer = csv.writer(f, lineterminator="\n")
        for first_byte, lo, hi, pre, dispatch in rows:
            writer.writerow((
                f"0x{first_byte:02x}",
                f"0x{lo:02x}",
                f"0x{hi:02x}",
                f"0x{pre:02x}",
                dispatch,
            ))


def parse_csv_rows():
    rows = []
    with CSV.open(encoding="utf-8") as f:
        for row in csv.reader(f):
            if not row or row[0].startswith("#") or row[0] == "first_byte":
                continue
            if len(row) != 5:
                raise ValueError(f"bad CSV row: {row}")
            rows.append((
                int(row[0], 16),
                int(row[1], 16),
                int(row[2], 16),
                int(row[3], 16),
                row[4],
            ))
    return rows


def load_expected(encodings):
    expected = [None] * 65536
    errors = []
    for fb, lo, hi, pre, dispatch in parse_csv_rows():
        if not (0 <= fb <= 0xFF and 0 <= lo <= hi <= 0xFF and 0 <= pre <= 0xFF):
            errors.append(f"bad range: first=0x{fb:02x} lo=0x{lo:02x} hi=0x{hi:02x}")
            continue
        for sb in range(lo, hi + 1):
            word = (sb << 8) | fb
            if expected[word] is not None:
                errors.append(f"duplicate decoder word 0x{word:04x}")
                continue
            expected[word] = pre
            want_pre = coarse_dispatch(fb, sb)
            want_dispatch = isa_dispatch(encodings, fb, sb)
            if pre != want_pre:
                errors.append(
                    f"0x{fb:02x}{sb:02x}: pre=0x{pre:02x}, want 0x{want_pre:02x}"
                )
            if dispatch != want_dispatch:
                errors.append(
                    f"0x{fb:02x}{sb:02x}: dispatch={dispatch}, want {want_dispatch}"
                )
    gaps = [w for w, v in enumerate(expected) if v is None]
    if gaps:
        errors.append(f"golden table leaves {len(gaps)} words uncovered, e.g. {gaps[:5]}")
    if errors:
        sample = "\n".join(errors[:20])
        more = "" if len(errors) <= 20 else f"\n... {len(errors) - 20} more"
        sys.exit(f"decode dispatch table mismatch:\n{sample}{more}")
    return expected


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--regen", action="store_true")
    parser.add_argument("--table-only", action="store_true")
    args = parser.parse_args()

    encodings = load_encodings()
    if args.regen:
        write_generated(generate_rows(encodings))
        print(f"regenerated {CSV.relative_to(ROOT)}")
        if args.table_only:
            return

    expected = load_expected(encodings)
    if args.table_only:
        print(f"decode dispatch table OK: {CSV.relative_to(ROOT)}")
        return

    for tool in ("iverilog", "vvp"):
        if not shutil.which(tool):
            sys.exit(f"{tool} not found; run inside a shell that provides iverilog")
    if not SV.exists():
        sys.exit(f"{SV} not found; elaborate CoarseDecoder first (make rtl-verilog)")

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
