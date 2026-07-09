#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Execution-equivalence gate: run isa/*.yaml cases on the RTL and compare the
retired register file and CCR to the Sail-derived expected state.

State is preloaded with a mov.w/ldc prologue, so no debug backdoor is needed;
only cases whose instruction is implemented in microcode are run (others are
skipped and counted). Env SIM_BIN points at the compiled tb_isa_case runner.
"""
import os
import re
import subprocess
import sys
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
CASE_FILES = [ROOT / "isa" / "h8300_base_cases.yaml",
              ROOT / "isa" / "h8300_legacy_cases.yaml"]

# instructions whose microcode is implemented (register/CCR data effects)
IMPLEMENTED = {
    "h8_nop", "h8_mov8_imm_r8", "h8_add8_imm_r8", "h8_cmp8_imm_r8",
    "h8_or8_imm_r8", "h8_xor8_imm_r8", "h8_and8_imm_r8",
    "h8_add8_r8_r8", "h8_sub8_r8_r8", "h8_mov16_imm_r16", "h8_ldc_imm_ccr",
    "h8_or8_r8_r8", "h8_xor8_r8_r8", "h8_and8_r8_r8", "h8_cmp8_r8_r8",
    "h8_addx8_imm_r8", "h8_subx8_imm_r8",
    "h8_mov8_r8_r8", "h8_addx8_r8_r8", "h8_subx8_r8_r8",
    "h8_not8_r8", "h8_neg8_r8", "h8_inc8_r8", "h8_dec8_r8",
    "h8_shll8_r8", "h8_shal8_r8", "h8_shlr8_r8", "h8_shar8_r8",
    "h8_rotxl8_r8", "h8_rotl8_r8", "h8_rotxr8_r8", "h8_rotr8_r8",
    "h8_mov8_r16i_r8", "h8_mov8_r8_r16i",
    "h8_mov16_r16i_r16", "h8_mov16_r16_r16i",
    "h8_mov16_r16p_r16", "h8_mov16_r16_pr16",
    "h8_mov8_r16d16_r8", "h8_mov16_r16d16_r16",
    "h8_mov8_r8_r16d16", "h8_mov16_r16_r16d16",
    "h8_mov8_abs8_r8", "h8_mov8_r8_abs8",
    "h8_mov8_abs16_r8", "h8_mov8_r8_abs16",
    "h8_mov16_abs16_r16", "h8_mov16_r16_abs16",
    "h8_add16_r16_r16", "h8_sub16_r16_r16",
    "h8_cmp16_r16_r16", "h8_mov16_r16_r16",
}

MEM_PROBE_LIMIT = 16


def parse_hex(value):
    return int(str(value), 16)


def reg_word(regs):
    """Collapse a {r0l/r0h/r0: hex} dict into {index: 16-bit word}."""
    words = {}
    for name, val in regs.items():
        n = int(name[1])
        v = int(str(val), 16)
        cur = words.get(n, 0)
        if name.endswith("h"):
            cur = (cur & 0x00FF) | ((v & 0xFF) << 8)
        elif name.endswith("l"):
            cur = (cur & 0xFF00) | (v & 0xFF)
        else:
            cur = v & 0xFFFF
        words[n] = cur
    return words


def ccr_imm8(hnzvc):
    h, n, z, v, c = (int(x) for x in hnzvc)
    return (h << 5) | (n << 3) | (z << 2) | (v << 1) | c


def prologue(initial):
    """mov.w each preset word register, then ldc the exact initial CCR."""
    b = []
    for n in sorted(reg_word(initial.get("regs", {})).items()):
        idx, val = n
        b += [0x79, idx & 0x07, (val >> 8) & 0xFF, val & 0xFF]
    b += [0x07, ccr_imm8(initial.get("ccr_hnzvc", "00000"))]
    return b


def case_words(words):
    b = []
    for w in words:
        x = parse_hex(w)
        b += [(x >> 8) & 0xFF, x & 0xFF]
    return b


def memory_expected(case):
    mem = case.get("memory", {}).get("expected", {})
    return {parse_hex(a): parse_hex(v) & 0xFF for a, v in mem.items()}


def image_memory(case):
    code = prologue(case["initial"]) + case_words(case["words"])
    image = {addr: byte for addr, byte in enumerate(code)}
    for addr_s, val_s in case.get("memory", {}).get("initial", {}).items():
        addr = parse_hex(addr_s)
        byte = parse_hex(val_s) & 0xFF
        if addr in image and image[addr] != byte:
            raise ValueError(f"{case['id']}: memory at 0x{addr:04x} overlaps code")
        image[addr] = byte
    return image


def write_memh(path, image):
    next_addr = None
    with Path(path).open("w", encoding="utf-8") as f:
        for addr in sorted(image):
            if next_addr != addr:
                f.write(f"@{addr:04x}\n")
            f.write(f"{image[addr] & 0xFF:02x}\n")
            next_addr = addr + 1


def run(sim_bin, image, mem_addrs):
    if len(mem_addrs) > MEM_PROBE_LIMIT:
        raise ValueError(f"too many memory probes: {len(mem_addrs)}")
    with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
        path = f.name
    write_memh(path, image)
    try:
        args = ["vvp", sim_bin, f"+hex={path}"]
        args += [f"+m{i}={addr:04x}" for i, addr in enumerate(mem_addrs)]
        proc = subprocess.run(args, capture_output=True, text=True, timeout=60)
        if proc.returncode:
            raise RuntimeError((proc.stdout + proc.stderr).strip())
        out = proc.stdout
    finally:
        os.unlink(path)
    regs = ccr = None
    mem = {}
    for line in out.splitlines():
        if line.startswith("R "):
            regs = [int(x, 16) for x in line.split()[1:9]]
        elif line.startswith("C "):
            ccr = line.split()[1]
        elif line.startswith("M "):
            _, addr, val = line.split()
            mem[int(addr, 16)] = int(val, 16)
    return regs, ccr, mem


def expected_state(initial, expected):
    words = reg_word(initial.get("regs", {}))
    words = {n: words.get(n, 0) for n in range(8)}
    for n, v in reg_word(expected.get("regs", {})).items():
        words[n] = v
    exp_ccr = expected.get("ccr_hnzvc", "preserve")
    if exp_ccr == "preserve":
        exp_ccr = initial.get("ccr_hnzvc", "00000")
    return words, exp_ccr


def check_case(sim, case):
    try:
        exp_mem = memory_expected(case)
        image = image_memory(case)
        regs, ccr, mem = run(sim, image, sorted(exp_mem))
        exp_regs, exp_ccr = expected_state(case["initial"], case["expected"])
        ok = regs is not None and ccr == exp_ccr \
            and all(regs[n] == exp_regs[n] for n in range(8)) \
            and all(mem.get(a) == v for a, v in exp_mem.items())
        if ok:
            return True, None
        return False, (f"{case['id']}: regs={regs} ccr={ccr} "
                       f"mem={mem} exp_regs={[exp_regs[n] for n in range(8)]} "
                       f"exp_ccr={exp_ccr} exp_mem={exp_mem}")
    except Exception as exc:
        return False, f"{case['id']}: {type(exc).__name__}: {exc}"


def job_count():
    default = min(os.cpu_count() or 1, 8)
    try:
        return max(1, int(os.environ.get("CHECK_EXEC_SAIL_JOBS", default)))
    except ValueError:
        return default


def main():
    sim = os.environ.get("SIM_BIN")
    if not sim or not Path(sim).exists():
        sys.exit("SIM_BIN not set to a compiled tb_isa_case runner")
    passed = failed = skipped = 0
    fails = []
    work = []
    for cf in CASE_FILES:
        doc = yaml.safe_load(cf.read_text())
        for case in doc.get("cases", []):
            instr = case.get("instruction")
            if case.get("status") != "supported" or instr not in IMPLEMENTED \
                    or case.get("expected", {}).get("trap"):
                skipped += 1
                continue
            work.append(case)
    with ThreadPoolExecutor(max_workers=job_count()) as pool:
        for ok, fail in pool.map(lambda case: check_case(sim, case), work):
            if ok:
                passed += 1
            else:
                failed += 1
                fails.append(fail)
    for f in fails:
        print("  FAIL", f)
    tag = "EXEC-SAIL PASS" if failed == 0 else "EXEC-SAIL FAIL"
    print(f"{tag}: {passed} matched, {failed} failed, {skipped} skipped (unimplemented)")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
