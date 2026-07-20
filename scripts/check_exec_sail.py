#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Execution-equivalence gate: run isa/*.yaml cases on the RTL and compare the
retired register file and CCR to the Sail-derived expected state.

The image carries reset SP/PC vector entries that boot into the prologue.
State is preloaded with a mov.w/ldc prologue, so no debug backdoor is needed;
only cases whose instruction is implemented in microcode are run (others are
skipped and counted). All cases run in one Icarus sim process through the
batch runner test/cocotb/isa/run_isa.py, which the caller must have built.
"""
import json
import os
import subprocess
import sys
import tempfile
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
    "h8_divxu_r8_r16",
    "h8_branch_rel8", "h8_bsr_rel8",
    "h8_jmp_r16i", "h8_jmp_abs16", "h8_jmp_abs8i",
    "h8_jsr_r16i", "h8_jsr_abs16", "h8_jsr_abs8i",
    "h8_rts", "h8_rte",
}

PROLOGUE_BASE = 0x0030  # first address past the platform vector table
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


def boot_vectors(initial):
    """Reset SP (0x0002) and entry PC (0x0006) halfwords of the vector table."""
    sp = reg_word(initial.get("regs", {})).get(7, 0)
    return {0x0002: (sp >> 8) & 0xFF, 0x0003: sp & 0xFF,
            0x0006: (PROLOGUE_BASE >> 8) & 0xFF, 0x0007: PROLOGUE_BASE & 0xFF}


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
    pre_end = PROLOGUE_BASE + len(pre)
    initial_pc = parse_hex(case["initial"].get("pc", "0x0000"))
    jump_to_initial = initial_pc >= pre_end + 4
    start = initial_pc if jump_to_initial else pre_end
    if start & 1:
        raise ValueError(f"{case['id']}: odd case start 0x{start:04x}")
    image = boot_vectors(case["initial"])
    image.update({PROLOGUE_BASE + off: byte for off, byte in enumerate(pre)})
    if jump_to_initial:
        for offset, byte in enumerate([0x5A, 0x00, (start >> 8) & 0xFF, start & 0xFF]):
            image[pre_end + offset] = byte
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


def batch_run(manifest):
    """Run every manifest entry in one sim process; return {id: result}."""
    with tempfile.TemporaryDirectory() as tmp:
        man_path = Path(tmp) / "manifest.json"
        res_path = Path(tmp) / "results.json"
        man_path.write_text(json.dumps(manifest))
        env = dict(os.environ, ISA_MANIFEST=str(man_path),
                   ISA_RESULTS=str(res_path))
        proc = subprocess.run(
            [sys.executable, str(ROOT / "test/cocotb/isa/run_isa.py"), "run"],
            cwd=ROOT, env=env, capture_output=True, text=True, timeout=1800,
        )
        if proc.returncode or not res_path.exists():
            raise RuntimeError((proc.stdout + proc.stderr).strip()[-2000:])
        return {r["id"]: r for r in json.loads(res_path.read_text())}


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


def compare_case(case, start, exp_mem, result):
    regs = result["regs"]
    ccr = result["ccr"]
    pc = result["pc"]
    mem = {int(a): v for a, v in result["mem"].items()}
    exp_regs, exp_ccr = expected_state(case["initial"], case["expected"])
    exp_pc = expected_pc(case, start)
    ok = pc == exp_pc and ccr_matches(ccr, exp_ccr) \
        and all(regs[n] == exp_regs[n] for n in range(8)) \
        and all(mem.get(a) == v for a, v in exp_mem.items())
    if ok:
        return True, None
    return False, (f"{case['id']}: regs={regs} ccr={ccr} pc={pc} "
                   f"mem={mem} exp_regs={[exp_regs[n] for n in range(8)]} "
                   f"exp_ccr={exp_ccr} exp_pc={exp_pc} exp_mem={exp_mem}")


def main():
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

    manifest = []
    metas = {}
    for case in work:
        try:
            image, start, stop_fetch = prepared_image(case)
            exp_mem = memory_expected(case, start)
        except Exception as exc:
            failed += 1
            fails.append(f"{case['id']}: {type(exc).__name__}: {exc}")
            continue
        manifest.append({
            "id": case["id"],
            "image": {str(a): b for a, b in image.items()},
            "stop_fetch": stop_fetch,
            "probes": sorted(exp_mem),
        })
        metas[case["id"]] = (case, start, exp_mem)

    try:
        results = batch_run(manifest)
    except Exception as exc:
        sys.exit(f"batch sim failed: {exc}")
    for entry in manifest:
        case, start, exp_mem = metas[entry["id"]]
        result = results.get(entry["id"])
        if result is None:
            failed += 1
            fails.append(f"{case['id']}: no result from batch sim")
            continue
        ok, fail = compare_case(case, start, exp_mem, result)
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
