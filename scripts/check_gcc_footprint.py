#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

"""Emit the first h8300-elf-gcc instruction footprint under result/."""

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

SNIPPETS = {
    "leaf_int": (
        "int leaf_int(int a, int b, int c) {"
        " int x = a + b; int y = x - c; return y > b ? y : b; }"
    ),
    "byte_ptr": (
        "unsigned char byte_ptr(unsigned char *p, unsigned char v) {"
        " unsigned char x = p[1]; p[0] = (unsigned char)(x + v); return p[0]; }"
    ),
    "word_ptr": (
        "unsigned int word_ptr(unsigned int *p, unsigned int v) {"
        " unsigned int x = p[1]; p[0] = x + v; return p[0]; }"
    ),
}
COMPILE_FLAGS = [
    "-Os", "-S", "-ffreestanding", "-fno-builtin", "-fomit-frame-pointer",
]

OBJDUMP_RE = re.compile(r"^\s*[0-9a-f]+:\s+([0-9a-f]{2}(?: [0-9a-f]{2})*)\s+(\S+)")
DISPATCH_KEY_RE = re.compile(r"^\s*(0x[0-9a-f]{2}) ->", re.M)
DISPATCH_RANGE_RE = re.compile(r"\((0x[0-9a-f]+) to (0x[0-9a-f]+)\)\.map")
REGREG_RE = re.compile(r"regReg2\(\s*(0x[0-9a-f]+)")
FORBIDDEN_RE = re.compile(r"(movfpe|movtpe|eepmov|mul|div)", re.I)


def run(cmd, cwd):
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, check=False)


def tool_info(tool):
    path = shutil.which(tool)
    if path is None:
        return {"available": False}
    version = run([tool, "--version"], REPO_ROOT)
    line = version.stdout.strip().splitlines()[0] if version.stdout.strip() else ""
    return {"available": True, "path": path, "version": line}


def unique_in_order(items):
    seen = set()
    out = []
    for item in items:
        if item not in seen:
            seen.add(item)
            out.append(item)
    return out


def rtl_dispatch_set():
    """Return coarse dispatch values present in the microcode source."""
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
    src = work / f"{name}.c"
    asm = work / f"{name}.s"
    obj = work / f"{name}.o"
    src.write_text(source + "\n", encoding="utf-8")
    compile_step = run(
        [GCC, *COMPILE_FLAGS, "-o", str(asm), str(src)],
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
    if dump.returncode != 0:
        return {"snippet": name, "status": "objdump_failed",
                "error": dump.stderr.strip().splitlines()[-1:] or [""]}
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
            "snippet": name,
            "words": "".join(byte_list),
            "mnemonic": m.group(2),
            "isa_id": isa_id,
            "dispatch": f"0x{dispatch:02x}",
            "rtl_implemented": None if rtl_dispatch is None else dispatch in rtl_dispatch,
        })
    return {"snippet": name, "status": "ok", "instructions": instructions}


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    tools = {tool: tool_info(tool) for tool in (GCC, AS, OBJDUMP)}
    missing_tools = sorted(tool for tool, info in tools.items() if not info["available"])
    if missing_tools:
        report = {
            "status": "blocked",
            "missing_tools": missing_tools,
            "compiler": tools[GCC],
            "snippets": sorted(SNIPPETS),
        }
        (OUT_DIR / "gcc-footprint.json").write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        print("gcc footprint blocked: missing " + ", ".join(missing_tools))
        return 1

    encodings = cdd.load_encodings()
    rtl_dispatch = rtl_dispatch_set()
    work = OUT_DIR / "work"
    work.mkdir(parents=True, exist_ok=True)

    results = [disassemble(name, src, encodings, rtl_dispatch, work)
               for name, src in sorted(SNIPPETS.items())]

    emitted = [i for r in results if r["status"] == "ok" for i in r["instructions"]]
    mapped = unique_in_order(i["isa_id"] for i in emitted if i["isa_id"] != "illegal")
    unmapped = [
        {k: i[k] for k in ("snippet", "words", "mnemonic", "dispatch")}
        for i in emitted if i["isa_id"] == "illegal"
    ]
    forbidden = [
        {k: i[k] for k in ("snippet", "words", "mnemonic", "isa_id")}
        for i in emitted
        if FORBIDDEN_RE.search(i["mnemonic"]) or FORBIDDEN_RE.search(i["isa_id"])
    ]
    missing_rtl = unique_in_order(
        i["isa_id"] for i in emitted
        if i["isa_id"] != "illegal" and i["rtl_implemented"] is False
    )
    failed = [r for r in results if r["status"] != "ok"]
    status = "ok" if not failed and not unmapped and not forbidden else "failed"

    report = {
        "status": status,
        "compiler": tools[GCC],
        "compile_flags": COMPILE_FLAGS,
        "assembler": tools[AS],
        "objdump": tools[OBJDUMP],
        "rtl_coverage_source": None if rtl_dispatch is None
        else str(MICROCODE.relative_to(REPO_ROOT)),
        "emitted_instruction_ids": mapped,
        "unmapped_encodings": unmapped,
        "forbidden_instructions": forbidden,
        "missing_rtl_instruction_ids": missing_rtl,
        "smallest_next_rtl_slice": missing_rtl,
        "snippets": results,
    }
    (OUT_DIR / "gcc-footprint.json").write_text(
        json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    tag = "ok" if status == "ok" else "failed"
    print(f"gcc footprint {tag}: {len(mapped)} isa ids emitted, "
          f"{len(missing_rtl)} missing in RTL, {len(unmapped)} unmapped")
    if failed:
        print("failed snippets: " + ", ".join(f"{r['snippet']}:{r['status']}" for r in failed))
    if missing_rtl:
        print("missing RTL instruction ids: " + ", ".join(missing_rtl))
    if unmapped:
        print("unmapped encodings: " + ", ".join(f"{u['words']}:{u['mnemonic']}" for u in unmapped))
    if forbidden:
        print("forbidden instructions: " + ", ".join(
            f"{i['words']}:{i['mnemonic']}:{i['isa_id']}" for i in forbidden))
    return 0 if status == "ok" else 1


if __name__ == "__main__":
    sys.exit(main())
