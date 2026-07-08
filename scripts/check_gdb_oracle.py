#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import re
import shutil
import sys
from pathlib import Path

import yaml

import check_isa_cases
from check_gnu_oracle import (
    REPO_ROOT,
    apply_reg,
    expected_regs,
    memory_map,
    program_bytes,
    run,
    sorted_memory_items,
)


OUT_DIR = REPO_ROOT / "result" / "gdb-oracle"
GDB = "h8300-elf-gdb"
AS = "h8300-elf-as"
LD = "h8300-elf-ld"

# The GNU H8/300 simulator does not model the half-carry flag at all.
UNMODELED_FLAGS = frozenset("H")
UNMODELED_FLAG_REASON = "gdb_sim_unmodeled"

# Flags whose simulator result diverges from the H8/300 datasheet for a
# specific instruction; the rest of that instruction is still compared.
DIVERGENT_FLAGS = {
    "h8_inc8_r8": frozenset("V"),
    "h8_dec8_r8": frozenset("V"),
    "h8_neg8_r8": frozenset("V"),
}
DIVERGENT_FLAG_REASON = "gdb_sim_divergent_flag"

# Instructions the simulator executes with datasheet-divergent addressing
# or results; abstained from rather than compared.
SIM_DIVERGENT = {
    "h8_mov8_abs8_r8": "8-bit absolute @aa:8 maps to 0x00xx, not 0xFFxx",
    "h8_mov8_r8_abs8": "8-bit absolute @aa:8 maps to 0x00xx, not 0xFFxx",
    "h8_bit_abs8_read": "8-bit absolute @aa:8 maps to 0x00xx, not 0xFFxx",
    "h8_bit_abs8_write": "8-bit absolute @aa:8 maps to 0x00xx, not 0xFFxx",
    "h8_daa8_r8": "decimal adjust carry and result differ from datasheet",
    "h8_das8_r8": "decimal adjust carry and result differ from datasheet",
    "h8_divxu_r8_r16": "divide-by-zero result differs from datasheet",
    "h8_mov16_r16_pr16": "self-referential pre-decrement store differs",
    "h8_mov8_r8_pr16": "self-referential pre-decrement store differs",
    "h8_subx8_r8_r8": "subx does not model sticky zero",
    "h8_rte": "rte restores ccr differently from datasheet",
}
SIM_DIVERGENT_REASON = "gdb_sim_divergent_instruction"

# CCR bit position of each flag in the HNZVC string order.
CCR_BITS = (5, 3, 2, 1, 0)
CCR_I = 1 << 7
LINE_RE = re.compile(r"^(PC|CCR|R[0-7]|MEM) (?:(0x[0-9a-f]+) )?([0-9a-f]+)$", re.M)


def gdb_reg(index: int) -> str:
    # The H8/300 sim names general register 7 as sp.
    return "$sp" if index == 7 else f"$r{index}"


def ccr_byte(hnzvc: str) -> int:
    value = CCR_I  # match the model's reset I=1 so stc stores the same byte.
    for flag, bit in zip(hnzvc, CCR_BITS):
        if flag == "1":
            value |= 1 << bit
    return value


def ccr_extract(byte: int) -> str:
    return "".join("1" if byte & (1 << bit) else "0" for bit in CCR_BITS)


def initial_reg_values(case: dict[str, object]) -> list[int]:
    regs = [0] * 16
    for name, value in dict(case["initial"].get("regs", {})).items():
        apply_reg(regs, name, value)
    return regs


def applicability(case: dict[str, object]) -> str | None:
    if str(case.get("status")) == "rejected":
        return "rejected_encoding_no_sim_semantics"
    if case["expected"].get("trap"):
        return "expected_trap_no_sim_semantics"
    if any(initial_reg_values(case)[8:]) or any(expected_regs(case)[8:]):
        return "extended_registers_absent"
    if str(case.get("instruction")) in SIM_DIVERGENT:
        return SIM_DIVERGENT_REASON
    return None


def abstain_reason_text(case: dict[str, object], reason_code: str) -> str:
    if reason_code == SIM_DIVERGENT_REASON:
        return SIM_DIVERGENT[str(case.get("instruction"))]
    return {
        "expected_trap_no_sim_semantics": "expected trap has no sim semantics",
        "extended_registers_absent": "extended registers absent from H8/300 sim",
        "rejected_encoding_no_sim_semantics": "rejected encoding has no sim trap semantics",
    }[reason_code]


def excluded_ccr_flags(case: dict[str, object]) -> list[dict[str, str]]:
    excluded = [{"flag": flag, "reason_code": UNMODELED_FLAG_REASON} for flag in sorted(UNMODELED_FLAGS)]
    for flag in sorted(DIVERGENT_FLAGS.get(str(case.get("instruction")), frozenset())):
        excluded.append({"flag": flag, "reason_code": DIVERGENT_FLAG_REASON})
    return excluded


def compared_ccr_flags(case: dict[str, object]) -> list[str]:
    excluded = {item["flag"] for item in excluded_ccr_flags(case)}
    return [flag for flag in "HNZVC" if flag not in excluded]


def comparison_scope(case: dict[str, object]) -> dict[str, object]:
    expected_memory = memory_map(case, "expected")
    return {
        "ccr_flags_compared": compared_ccr_flags(case),
        "ccr_flags_excluded": excluded_ccr_flags(case),
        "fields": ["pc", "regs", "ccr_hnzvc", "memory"],
        "memory_addresses_compared": sorted(expected_memory, key=lambda addr: int(addr, 16)),
    }


def words_asm(case: dict[str, object]) -> str:
    body = "\n".join(f"  .byte 0x{byte:02x}" for byte in program_bytes(case))
    return ".text\n.global _start\n_start:\n" + body + "\n"


def build_elf(case: dict[str, object], work: Path) -> list[dict[str, object]]:
    pc = str(case["initial"]["pc"])
    (work / "case.s").write_text(words_asm(case), encoding="utf-8")
    return [
        run([AS, "-o", "case.o", "case.s"], work / "as.log", work),
        run([LD, f"-Ttext={pc}", "-e", "_start", "-o", "case.elf", "case.o"], work / "ld.log", work),
    ]


def gdb_command(case: dict[str, object], work: Path) -> list[str]:
    initial = case["initial"]
    pc = str(initial["pc"])
    regs = initial_reg_values(case)
    cmd = [
        GDB,
        "-nx",
        "-batch",
        "-ex",
        "set architecture h8300",
        "-ex",
        "file case.elf",
        "-ex",
        "target sim",
        "-ex",
        "load",
        "-ex",
        f"break *{pc}",
        "-ex",
        "run",
    ]
    for index in range(8):
        cmd += ["-ex", f"set {gdb_reg(index)} = 0x{regs[index]:04x}"]
    cmd += ["-ex", f"set $ccr = 0x{ccr_byte(str(initial['ccr_hnzvc'])):02x}"]
    for addr, value in sorted_memory_items(memory_map(case, "initial")):
        cmd += ["-ex", f"set {{char}}{addr} = {value}"]
    cmd += ["-ex", "stepi"]
    cmd += ["-ex", 'printf "PC %x\\n", $pc']
    cmd += ["-ex", 'printf "CCR %x\\n", $ccr']
    for index in range(8):
        cmd += ["-ex", f'printf "R{index} %x\\n", {gdb_reg(index)}']
    for addr, _value in sorted_memory_items(memory_map(case, "expected")):
        cmd += ["-ex", f'printf "MEM {addr} %x\\n", *(unsigned char*){addr}']
    return cmd


def parse_dump(log_text: str) -> dict[str, int] | None:
    dump: dict[str, int] = {}
    for tag, addr, value in LINE_RE.findall(log_text):
        if tag == "MEM":
            dump[f"MEM:{int(addr, 16)}"] = int(value, 16) & 0xFF
        elif tag == "CCR":
            dump["CCR"] = int(value, 16) & 0xFF
        else:
            # sim registers are 32-bit; a set bit15 sign-extends under %x.
            dump[tag] = int(value, 16) & 0xFFFF
    return dump if "PC" in dump and "CCR" in dump else None


def compare(case: dict[str, object], dump: dict[str, int]) -> list[str]:
    diffs: list[str] = []
    expected = case["expected"]
    want_pc = int(str(expected["pc"]), 16)
    if dump["PC"] != want_pc:
        diffs.append(f"pc {dump['PC']:#06x} != {want_pc:#06x}")

    want_ccr = str(expected["ccr_hnzvc"])
    if want_ccr == "preserve":
        want_ccr = str(case["initial"]["ccr_hnzvc"])
    excluded = UNMODELED_FLAGS | DIVERGENT_FLAGS.get(str(case.get("instruction")), frozenset())
    got_ccr = ccr_extract(dump["CCR"])
    for name, want, got in zip("HNZVC", want_ccr, got_ccr):
        if name in excluded:
            continue
        if want != "x" and want != got:
            diffs.append(f"ccr {name} {got} != {want}")

    for index, want in enumerate(expected_regs(case)[:8]):
        got = dump[f"R{index}"]
        if got != want:
            diffs.append(f"r{index} {got:#06x} != {want:#06x}")

    for addr, value in sorted_memory_items(memory_map(case, "expected")):
        key = f"MEM:{int(addr, 16)}"
        want = int(str(value), 16)
        if dump.get(key) != want:
            diffs.append(f"mem[{addr}] {dump.get(key)} != {want}")
    return diffs


def case_instruction_metadata(case: dict[str, object], instructions: dict[str, dict[str, object]]) -> dict[str, object]:
    instruction = instructions.get(str(case.get("instruction")), {})
    sail = instruction.get("sail") if isinstance(instruction, dict) else {}
    return {
        "effects": instruction.get("effects", []),
        "length_bytes": instruction.get("length_bytes"),
        "sail_decode": sail.get("decode") if isinstance(sail, dict) else None,
        "sail_execute": sail.get("execute") if isinstance(sail, dict) else None,
    }


def check_case(case: dict[str, object], work: Path) -> dict[str, object]:
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    skip = applicability(case)
    if skip is not None:
        return {
            "blocking": False,
            "reason": abstain_reason_text(case, skip),
            "reason_code": skip,
            "status": "abstain",
        }

    steps = build_elf(case, work)
    if any(step["status"] != "pass" for step in steps):
        return {"status": "fail", "reason": "assemble/link failed", "log": steps[-1]["log"]}

    result = run(gdb_command(case, work), work / "gdb.log", work)
    log_text = (work / "gdb.log").read_text(encoding="utf-8")
    dump = parse_dump(log_text)
    if result["status"] != "pass" or dump is None:
        return {"status": "fail", "reason": "gdb sim run failed", "log": result["log"]}

    diffs = compare(case, dump)
    return {
        "status": "pass" if not diffs else "fail",
        "comparison_scope": comparison_scope(case),
        "diffs": diffs,
        "log": result["log"],
    }


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    work_root = OUT_DIR / "work"

    results = []
    blocking_errors = []
    for case_path in check_isa_cases.CASE_PATHS:
        sail_text = (REPO_ROOT / "sail" / "h8300.sail").read_text(encoding="utf-8")
        table = yaml.safe_load(case_path.read_text(encoding="utf-8"))
        table_errors, _summary = check_isa_cases.validate_table(table, sail_text)
        if table_errors:
            blocking_errors.extend(f"{case_path.relative_to(REPO_ROOT)}: {error}" for error in table_errors)
            continue
        profile = str(table["profile"])
        instructions = {
            str(instruction["id"]): instruction
            for instruction in table.get("instructions", [])
            if isinstance(instruction, dict) and isinstance(instruction.get("id"), str)
        }
        cases = list(table.get("cases", [])) + list(table.get("reject_cases", []))
        for case in cases:
            outcome = check_case(case, work_root / profile / str(case["id"]))
            results.append({
                "case_id": case["id"],
                "case_table": str(case_path.relative_to(REPO_ROOT)),
                "check_area": case.get("check_area"),
                "instruction": case.get("instruction", "reserved"),
                "instruction_metadata": case_instruction_metadata(case, instructions),
                "profile": profile,
                "words": case.get("words", []),
                **outcome,
            })

    failed = [r for r in results if r["status"] == "fail"]
    skipped = [r for r in results if r["status"] == "abstain"]
    passed = [r for r in results if r["status"] == "pass"]
    skip_reasons: dict[str, int] = {}
    for result in skipped:
        reason = str(result.get("reason_code", "unknown"))
        skip_reasons[reason] = skip_reasons.get(reason, 0) + 1
    if not passed:
        blocking_errors.append("no comparable GDB oracle cases")
    status = "fail" if failed or blocking_errors else "pass"
    report = {
        "abstained_case_count": len(skipped),
        "abstained_cases": skipped,
        "abstain_status": "non_blocking",
        "blocking_errors": blocking_errors,
        "case_input_count": len(results),
        "case_source_policy": {
            "isa_yaml_cases_are_third_party_oracle_data": True,
            "sail_implementer_must_not_edit_cases": True,
        },
        "compared_case_count": len(passed),
        "compared_cases": passed,
        "compared_fail_count": len(failed),
        "compared_pass_count": len(passed),
        "divergent_flags_by_instruction": {
            name: sorted(flags) for name, flags in sorted(DIVERGENT_FLAGS.items())
        },
        "failed_cases": failed,
        "global_excluded_flags": [{"flag": flag, "reason_code": UNMODELED_FLAG_REASON} for flag in sorted(UNMODELED_FLAGS)],
        "limitations": [
            "gdb simulator evidence is independent execution evidence, not the ISA specification",
            "abstained cases are advisory, not pass evidence",
            "memory comparison is final-state only",
        ],
        "pass_count": sum(1 for r in results if r["status"] == "pass"),
        "per_instruction_excluded_flags": [
            {"flags": sorted(flags), "instruction": name, "reason_code": DIVERGENT_FLAG_REASON}
            for name, flags in sorted(DIVERGENT_FLAGS.items())
        ],
        "report_schema": 2,
        "sim_divergent_instructions": dict(sorted(SIM_DIVERGENT.items())),
        "skip_count": len(skipped),
        "skip_reason_counts": dict(sorted(skip_reasons.items())),
        "status": status,
        "unmodeled_flags": sorted(UNMODELED_FLAGS),
    }
    report_path = OUT_DIR / "gdb-oracle.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"gdb oracle {status}: {report['compared_case_count']} compare, "
        f"{report['abstained_case_count']} abstain, {len(failed)} fail: "
        f"{report_path.relative_to(REPO_ROOT)}"
    )
    for error in blocking_errors:
        print(error)
    for result in failed:
        print(f"{result['case_id']}: {result.get('reason', '; '.join(result.get('diffs', [])))}")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
