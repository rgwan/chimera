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
    "h8_add8_r8_r8", "h8_sub8_r8_r8", "h8_mov16_imm_r16",
    "h8_stc_ccr_r8", "h8_ldc_imm_ccr", "h8_ldc_r8_ccr",
    "h8_orc_imm_ccr", "h8_xorc_imm_ccr", "h8_andc_imm_ccr",
    "h8_or8_r8_r8", "h8_xor8_r8_r8", "h8_and8_r8_r8", "h8_cmp8_r8_r8",
    "h8_addx8_imm_r8", "h8_subx8_imm_r8",
    "h8_mov8_r8_r8", "h8_addx8_r8_r8", "h8_subx8_r8_r8",
    "h8_not8_r8", "h8_neg8_r8", "h8_inc8_r8", "h8_dec8_r8",
    "h8_shll8_r8", "h8_shal8_r8", "h8_shlr8_r8", "h8_shar8_r8",
    "h8_rotxl8_r8", "h8_rotl8_r8", "h8_rotxr8_r8", "h8_rotr8_r8",
    "h8_mov8_r16i_r8", "h8_mov8_r8_r16i",
    "h8_mov16_r16i_r16", "h8_mov16_r16_r16i",
    "h8_mov8_r16p_r8", "h8_mov8_r8_pr16",
    "h8_mov16_r16p_r16", "h8_mov16_r16_pr16",
    "h8_mov8_r16d16_r8", "h8_mov16_r16d16_r16",
    "h8_mov8_r8_r16d16", "h8_mov16_r16_r16d16",
    "h8_mov8_abs8_r8", "h8_mov8_r8_abs8",
    "h8_mov8_abs16_r8", "h8_mov8_r8_abs16",
    "h8_mov16_abs16_r16", "h8_mov16_r16_abs16",
    "h8_add16_r16_r16", "h8_sub16_r16_r16",
    "h8_cmp16_r16_r16", "h8_mov16_r16_r16",
    "h8_adds16_one_r16", "h8_adds16_two_r16",
    "h8_subs16_one_r16", "h8_subs16_two_r16",
    "h8_bset_imm3_r8", "h8_bnot_imm3_r8",
    "h8_bclr_imm3_r8", "h8_btst_imm3_r8",
    "h8_bset_r8_r8", "h8_bnot_r8_r8",
    "h8_bclr_r8_r8", "h8_btst_r8_r8",
    "h8_bst_imm3_r8", "h8_bist_imm3_r8",
    "h8_bld_imm3_r8", "h8_bild_imm3_r8",
    "h8_bor_imm3_r8", "h8_bior_imm3_r8",
    "h8_bxor_imm3_r8", "h8_bixor_imm3_r8",
    "h8_band_imm3_r8", "h8_biand_imm3_r8",
    "h8_bit_abs8_read", "h8_bit_abs8_write",
    "h8_bit_r16i_read", "h8_bit_r16i_write",
    "h8_daa8_r8", "h8_das8_r8",
    "h8_mulxu_r8_r16",
    "h8_branch_rel8", "h8_bsr_rel8",
    "h8_jmp_r16i", "h8_jmp_abs16", "h8_jmp_abs8i",
    "h8_jsr_r16i", "h8_jsr_abs16", "h8_jsr_abs8i",
    "h8_rts", "h8_rte",
}

MEM_PROBE_LIMIT = 16
ABSOLUTE_PC_INSTRUCTIONS = {
    "h8_jmp_r16i", "h8_jmp_abs16", "h8_jmp_abs8i",
    "h8_jsr_r16i", "h8_jsr_abs16", "h8_jsr_abs8i",
    "h8_rts", "h8_rte",
}
CALL_INSTRUCTIONS = {"h8_bsr_rel8", "h8_jsr_r16i", "h8_jsr_abs16", "h8_jsr_abs8i"}


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
    return 0x80 | (h << 5) | (n << 3) | (z << 2) | (v << 1) | c


def prologue(initial):
    """mov.w each preset word register, then ldc the exact initial CCR."""
    b = []
    for n in sorted(reg_word(initial.get("regs", {})).items()):
        idx, val = n
        b += [0x79, idx & 0x07, (val >> 8) & 0xFF, val & 0xFF]
    b += [0x07, ccr_imm8(initial.get("ccr_hnzvc", "00000"))]
    return b


def prologue_instruction_count(initial):
    return len(reg_word(initial.get("regs", {}))) + 1


def case_words(words):
    b = []
    for w in words:
        x = parse_hex(w)
        b += [(x >> 8) & 0xFF, x & 0xFF]
    return b


def expected_word_register(case, name):
    regs = reg_word(case.get("initial", {}).get("regs", {}))
    regs.update(reg_word(case.get("expected", {}).get("regs", {})))
    return regs[int(name[1])]


def instruction_len(case):
    return len(case.get("words", [])) * 2


def case_start(case, prologue_len):
    pc = parse_hex(case["initial"].get("pc", "0x0000"))
    return pc if pc >= prologue_len else prologue_len


def memory_expected(case, start):
    mem = case.get("memory", {}).get("expected", {})
    out = {parse_hex(a): parse_hex(v) & 0xFF for a, v in mem.items()}
    if case.get("instruction") in CALL_INSTRUCTIONS and out:
        sp = expected_word_register(case, "r7")
        ret = (start + instruction_len(case)) & 0xFFFF
        out[sp] = (ret >> 8) & 0xFF
        out[(sp + 1) & 0xFFFF] = ret & 0xFF
    return out


def prepared_image(case):
    pre = prologue(case["initial"])
    initial_pc = parse_hex(case["initial"].get("pc", "0x0000"))
    jump_to_initial = initial_pc >= len(pre)
    start = initial_pc if jump_to_initial else case_start(case, len(pre))
    if start & 1:
        raise ValueError(f"{case['id']}: odd case start 0x{start:04x}")
    image = {addr: byte for addr, byte in enumerate(pre)}
    if jump_to_initial:
        for offset, byte in enumerate([0x5A, 0x00, (start >> 8) & 0xFF, start & 0xFF]):
            image[len(pre) + offset] = byte
    for offset, byte in enumerate(case_words(case["words"])):
        image[start + offset] = byte
    for addr_s, val_s in case.get("memory", {}).get("initial", {}).items():
        addr = parse_hex(addr_s)
        byte = parse_hex(val_s) & 0xFF
        if addr in image and image[addr] != byte:
            raise ValueError(f"{case['id']}: memory at 0x{addr:04x} overlaps code")
        image[addr] = byte
    stop_fetch = prologue_instruction_count(case["initial"]) + (1 if jump_to_initial else 0) + 2
    return image, start, stop_fetch


def write_memh(path, image):
    next_addr = None
    with Path(path).open("w", encoding="utf-8") as f:
        for addr in sorted(image):
            if next_addr != addr:
                f.write(f"@{addr:04x}\n")
            f.write(f"{image[addr] & 0xFF:02x}\n")
            next_addr = addr + 1


def run(sim_bin, image, mem_addrs, stop_fetch):
    if len(mem_addrs) > MEM_PROBE_LIMIT:
        raise ValueError(f"too many memory probes: {len(mem_addrs)}")
    with tempfile.NamedTemporaryFile("w", suffix=".hex", delete=False) as f:
        path = f.name
    write_memh(path, image)
    try:
        args = ["vvp", sim_bin, f"+hex={path}", f"+stop_fetch={stop_fetch}"]
        args += [f"+m{i}={addr:04x}" for i, addr in enumerate(mem_addrs)]
        proc = subprocess.run(args, capture_output=True, text=True, timeout=60)
        if proc.returncode:
            raise RuntimeError((proc.stdout + proc.stderr).strip())
        out = proc.stdout
    finally:
        os.unlink(path)
    regs = ccr = pc = None
    mem = {}
    for line in out.splitlines():
        if line.startswith("R "):
            regs = [int(x, 16) for x in line.split()[1:9]]
        elif line.startswith("C "):
            ccr = line.split()[1]
        elif line.startswith("P "):
            pc = int(line.split()[1], 16)
        elif line.startswith("M "):
            _, addr, val = line.split()
            mem[int(addr, 16)] = int(val, 16)
    return regs, ccr, pc, mem


def expected_state(initial, expected):
    words = reg_word(initial.get("regs", {}))
    words = {n: words.get(n, 0) for n in range(8)}
    for n, v in reg_word(expected.get("regs", {})).items():
        words[n] = v
    exp_ccr = expected.get("ccr_hnzvc", "preserve")
    if exp_ccr == "preserve":
        exp_ccr = initial.get("ccr_hnzvc", "00000")
    return words, exp_ccr


def expected_pc(case, start):
    pc = parse_hex(case["expected"].get("pc", "0x0000"))
    if case.get("instruction") not in ABSOLUTE_PC_INSTRUCTIONS:
        pc = (pc + start - parse_hex(case["initial"].get("pc", "0x0000"))) & 0xFFFF
    return pc


def ccr_matches(actual, expected):
    return len(actual) == len(expected) and all(
        e == "x" or a == e for a, e in zip(actual, expected)
    )


def check_case(sim, case):
    try:
        image, start, stop_fetch = prepared_image(case)
        exp_mem = memory_expected(case, start)
        regs, ccr, pc, mem = run(sim, image, sorted(exp_mem), stop_fetch)
        exp_regs, exp_ccr = expected_state(case["initial"], case["expected"])
        exp_pc = expected_pc(case, start)
        ok = regs is not None and pc == exp_pc and ccr_matches(ccr, exp_ccr) \
            and all(regs[n] == exp_regs[n] for n in range(8)) \
            and all(mem.get(a) == v for a, v in exp_mem.items())
        if ok:
            return True, None
        return False, (f"{case['id']}: regs={regs} ccr={ccr} pc={pc} "
                       f"mem={mem} exp_regs={[exp_regs[n] for n in range(8)]} "
                       f"exp_ccr={exp_ccr} exp_pc={exp_pc} exp_mem={exp_mem}")
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
