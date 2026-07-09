#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

"""Compiler footprint: what H8/300 instructions does h8300-elf-gcc emit for a
tiny C smoke, and which of them the RTL core does not yet implement.

Compiles freestanding snippets, disassembles the objects with objdump, maps
each emitted opcode to an isa instruction id (isa mask/match) and to the RTL
coarse-decode dispatch, and reports the ids the microcode program does not
cover. Consumes isa/*.yaml only as read-only metadata; touches no cases.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import check_decode_dispatch as cdd


REPO_ROOT = Path(__file__).resolve().parents[1]
OUT_DIR = REPO_ROOT / "result" / "gcc-footprint"
GCC = "h8300-elf-gcc"
AS = "h8300-elf-as"
OBJDUMP = "h8300-elf-objdump"
MICROCODE = REPO_ROOT / "rtl" / "src" / "MicrocodeAsm.scala"

# First compiler smoke: freestanding snippets (no libc, no libgcc link).
SNIPPETS = {
    "mov_imm": "int mov_imm(void) { return 0x2a; }",
    "add_reg": "int add_reg(int a, int b) { return a + b; }",
    "sub_reg": "int sub_reg(int a, int b) { return a - b; }",
    "logic": "unsigned char logic(unsigned char a, unsigned char b)"
             " { return (a & b) | (a ^ b); }",
    "shift": "unsigned char shift(unsigned char a) { return a << 1; }",
    "branch": "int pick(int a, int b) { return a > b ? a : b; }",
    "loop": "int accumulate(int n) { int s = 0;"
            " for (int i = 0; i < n; i++) s += i; return s; }",
}

OBJDUMP_RE = re.compile(r"^\s*[0-9a-f]+:\s+([0-9a-f]{2}(?: [0-9a-f]{2})*)\s+(\S+)")
DISPATCH_KEY_RE = re.compile(r"^\s*(0x[0-9a-f]{2}) ->", re.M)
DISPATCH_RANGE_RE = re.compile(r"\((0x[0-9a-f]+) to (0x[0-9a-f]+)\)\.map")
REGREG_RE = re.compile(r"regReg2\(\s*(0x[0-9a-f]+)")


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def rtl_dispatch_set():
    """Coarse-decode dispatch values the microcode program implements, or None
    when the RTL source is absent. Covers literal `0xNN ->` entry points and
    `regReg2(0xNN, ...)` reg-reg ops (base plus their 0xC0 m-class alias)."""
    if not MICROCODE.is_file():
        return None
    text = MICROCODE.read_text(encoding="utf-8")
    values = {int(v, 16) for v in DISPATCH_KEY_RE.findall(text)}
    for lo, hi in DISPATCH_RANGE_RE.findall(text):
        values.update(range(int(lo, 16), int(hi, 16) + 1))
    for base in (int(v, 16) for v in REGREG_RE.findall(text)):
        values.add(base)
        values.add(0xC0 | (base & 0x3F))
    return values


def disassemble(name, source, encodings, rtl_dispatch, work):
    # Compile to assembly with gcc, then assemble with the target as directly:
    # gcc's driver resolves an unprefixed `as` and would miss h8300-elf-as.
    src = work / f"{name}.c"
    asm = work / f"{name}.s"
    obj = work / f"{name}.o"
    src.write_text(source + "\n", encoding="utf-8")
    compile_step = run(
        [GCC, "-Os", "-S", "-ffreestanding", "-fno-builtin", "-fomit-frame-pointer",
         "-o", str(asm), str(src)],
        work,
    )
    if compile_step.returncode != 0 or not asm.is_file():
        return {"snippet": name, "status": "compile_failed",
                "error": compile_step.stderr.strip().splitlines()[-1:] or [""]}
    assemble_step = run([AS, "-o", str(obj), str(asm)], work)
    if assemble_step.returncode != 0 or not obj.is_file():
        return {"snippet": name, "status": "assemble_failed",
                "error": assemble_step.stderr.strip().splitlines()[-1:] or [""]}
    dump = run([OBJDUMP, "-d", str(obj)], work)
    instructions = []
    for line in dump.stdout.splitlines():
        m = OBJDUMP_RE.match(line)
        if m is None:
            continue
        byte_list = m.group(1).split()
        first = int(byte_list[0], 16)
        second = int(byte_list[1], 16) if len(byte_list) > 1 else 0
        isa_id = cdd.isa_dispatch(encodings, first, second)
        dispatch = cdd.coarse_dispatch(first, second)
        instructions.append({
            "words": "".join(byte_list),
            "mnemonic": m.group(2),
            "isa_id": isa_id,
            "dispatch": f"0x{dispatch:02x}",
            "rtl_implemented": None if rtl_dispatch is None else dispatch in rtl_dispatch,
        })
    return {"snippet": name, "status": "ok", "instructions": instructions}


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    if shutil.which(GCC) is None:
        report = {
            "status": "blocked",
            "blocker": f"{GCC} not on PATH; see doc note on the Nix cross-gcc build",
            "snippets": sorted(SNIPPETS),
        }
        (OUT_DIR / "gcc-footprint.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print(f"gcc footprint blocked: {GCC} unavailable")
        return 0

    encodings = cdd.load_encodings()
    rtl_dispatch = rtl_dispatch_set()
    work = OUT_DIR / "work"
    work.mkdir(parents=True, exist_ok=True)

    results = [disassemble(name, src, encodings, rtl_dispatch, work)
               for name, src in sorted(SNIPPETS.items())]

    emitted = [i for r in results if r["status"] == "ok" for i in r["instructions"]]
    mapped = sorted({i["isa_id"] for i in emitted if i["isa_id"] != "illegal"})
    unmapped = sorted({i["mnemonic"] for i in emitted if i["isa_id"] == "illegal"})
    missing_rtl = sorted({
        i["isa_id"] for i in emitted
        if i["isa_id"] != "illegal" and i["rtl_implemented"] is False
    })

    report = {
        "status": "ok",
        "compiler": GCC,
        "rtl_coverage_source": None if rtl_dispatch is None
        else str(MICROCODE.relative_to(REPO_ROOT)),
        "emitted_instruction_ids": mapped,
        "unmapped_mnemonics": unmapped,
        "missing_rtl_instruction_ids": missing_rtl,
        "snippets": results,
    }
    (OUT_DIR / "gcc-footprint.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    print(f"gcc footprint ok: {len(mapped)} isa ids emitted, "
          f"{len(missing_rtl)} missing in RTL, {len(unmapped)} unmapped")
    if missing_rtl:
        print("missing RTL instruction ids: " + ", ".join(missing_rtl))
    if unmapped:
        print("unmapped mnemonics: " + ", ".join(unmapped))
    return 0


if __name__ == "__main__":
    sys.exit(main())
