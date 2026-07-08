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
    "h8_daa8_r8": frozenset("NZC"),
    "h8_das8_r8": frozenset("NZC"),
    "h8_rte": frozenset("NZVC"),
    "h8_subx8_r8_r8": frozenset("ZV"),
}
DIVERGENT_FLAG_REASON = "gdb_sim_divergent_flag"
DIVERGENT_RESULT_BYTE_INSTRUCTIONS = {
    "h8_daa8_r8": "decimal adjust result byte differs",
    "h8_das8_r8": "decimal adjust result byte differs",
}
DIVERGENT_RESULT_BYTE_REASON = "gdb_sim_divergent_result_byte"
EXPECTED_TRAP_REASON = "expected_trap_no_sim_semantics"
REJECTED_ENCODING_REASON = "rejected_encoding_no_sim_semantics"
MIN_COMPARED_CASES = 246

# The sim resolves @aa:8 to 0x00aa instead of the datasheet 0xFFaa page;
# for these ops the case memory address is remapped down so the data-path
# result is still compared.
ABS8_INSTRUCTIONS = frozenset({
    "h8_mov8_abs8_r8",
    "h8_mov8_r8_abs8",
    "h8_bit_abs8_read",
    "h8_bit_abs8_write",
})

# Instructions the simulator executes with whole-result divergence.
SIM_DIVERGENT = {}
SIM_DIVERGENT_REASON = "gdb_sim_divergent_instruction"
SIM_DIVERGENT_CASES = {
    "h8_divxu_r0h_r1_zero_divisor": "divide-by-zero result differs",
    "h8_mov16_r1_pr1": "self-referential pre-decrement store differs",
    "h8_mov8_r1l_pr1": "self-referential pre-decrement store differs",
}
# The sim reads word/long memory at the literal address; the H8/300 forces
# even alignment by clearing bit0. Cases whose pointer register is odd are
# abstained rather than compared.
UNALIGNED_WORD_REASON = "gdb_sim_unaligned_word_access"
ABSTAIN_REASON_LIMITS = {
    EXPECTED_TRAP_REASON: 1,
    REJECTED_ENCODING_REASON: 4,
    SIM_DIVERGENT_REASON: 3,
    UNALIGNED_WORD_REASON: 1,
}

# CCR bit position of each flag in the HNZVC string order.
CCR_BITS = (5, 3, 2, 1, 0)
CCR_I = 1 << 7
LINE_RE = re.compile(r"^(PC|CCR|R[0-7]|MEM) (?:(0x[0-9a-f]+) )?([0-9a-f]+)$", re.M)


def gdb_reg(index: int) -> str:
    # The H8/300 sim names general register 7 as sp.
    return "$sp" if index == 7 else f"$r{index}"


def sim_mem_addr(instruction: str, addr: str) -> str:
    value = int(addr, 16)
    if instruction in ABS8_INSTRUCTIONS:
        value &= 0x00FF  # sim resolves @aa:8 to the zero page, not 0xFFaa.
    return f"0x{value:04x}"


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


def unaligned_word_access(case: dict[str, object]) -> bool:
    memory = case.get("memory")
    access = memory.get("access") if isinstance(memory, dict) else None
    if not isinstance(access, dict) or access.get("width") not in ("word", "long"):
        return False
    odd_ptr = int(str(access.get("addr", "0x0")), 16) | 1
    return any(int(str(v), 16) == odd_ptr for v in case["initial"].get("regs", {}).values())


def applicability(case: dict[str, object]) -> str | None:
    if str(case.get("status")) == "rejected":
        return REJECTED_ENCODING_REASON
    if case["expected"].get("trap"):
        return EXPECTED_TRAP_REASON
    if any(initial_reg_values(case)[8:]) or any(expected_regs(case)[8:]):
        return "extended_registers_absent"
    if str(case.get("id")) in SIM_DIVERGENT_CASES:
        return SIM_DIVERGENT_REASON
    if str(case.get("instruction")) in SIM_DIVERGENT:
        return SIM_DIVERGENT_REASON
    if unaligned_word_access(case):
        return UNALIGNED_WORD_REASON
    return None


def abstain_reason_text(case: dict[str, object], reason_code: str) -> str:
    if reason_code == SIM_DIVERGENT_REASON:
        case_id = str(case.get("id"))
        if case_id in SIM_DIVERGENT_CASES:
            return SIM_DIVERGENT_CASES[case_id]
        return SIM_DIVERGENT[str(case.get("instruction"))]
    return {
        EXPECTED_TRAP_REASON: "expected trap has no sim semantics",
        "extended_registers_absent": "extended registers absent from H8/300 sim",
        REJECTED_ENCODING_REASON: "rejected encoding has no sim trap semantics",
        UNALIGNED_WORD_REASON: "sim does not force even alignment on word access",
    }[reason_code]


def excluded_ccr_flags(case: dict[str, object]) -> list[dict[str, str]]:
    excluded = [{"flag": flag, "reason_code": UNMODELED_FLAG_REASON} for flag in sorted(UNMODELED_FLAGS)]
    for flag in sorted(DIVERGENT_FLAGS.get(str(case.get("instruction")), frozenset())):
        excluded.append({"flag": flag, "reason_code": DIVERGENT_FLAG_REASON})
    return excluded


def compared_ccr_flags(case: dict[str, object]) -> list[str]:
    excluded = {item["flag"] for item in excluded_ccr_flags(case)}
    return [flag for flag in "HNZVC" if flag not in excluded]


def r8_code_name(code: int) -> str:
    suffix = "h" if code & 0x8 == 0 else "l"
    return f"r{code & 0x7}{suffix}"


def excluded_register_bytes(case: dict[str, object]) -> list[dict[str, str]]:
    instruction = str(case.get("instruction"))
    if instruction not in DIVERGENT_RESULT_BYTE_INSTRUCTIONS:
        return []
    words = case.get("words", [])
    if not words:
        return []
    code = int(str(words[0]), 16) & 0xF
    return [{
        "byte": "high" if code & 0x8 == 0 else "low",
        "reason": DIVERGENT_RESULT_BYTE_INSTRUCTIONS[instruction],
        "reason_code": DIVERGENT_RESULT_BYTE_REASON,
        "register": f"r{code & 0x7}",
        "register_byte": r8_code_name(code),
    }]


def comparison_scope(case: dict[str, object]) -> dict[str, object]:
    expected_memory = memory_map(case, "expected")
    return {
        "ccr_flags_compared": compared_ccr_flags(case),
        "ccr_flags_excluded": excluded_ccr_flags(case),
        "fields": ["pc", "regs", "ccr_hnzvc", "memory"],
        "memory_addresses_compared": sorted(expected_memory, key=lambda addr: int(addr, 16)),
        "register_bytes_excluded": excluded_register_bytes(case),
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
    instruction = str(case.get("instruction"))
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
        cmd += ["-ex", f"set {{char}}{sim_mem_addr(instruction, addr)} = {value}"]
    cmd += ["-ex", "stepi"]
    cmd += ["-ex", 'printf "PC %x\\n", $pc']
    cmd += ["-ex", 'printf "CCR %x\\n", $ccr']
    for index in range(8):
        cmd += ["-ex", f'printf "R{index} %x\\n", {gdb_reg(index)}']
    for addr, _value in sorted_memory_items(memory_map(case, "expected")):
        target = sim_mem_addr(instruction, addr)
        cmd += ["-ex", f'printf "MEM {addr} %x\\n", *(unsigned char*){target}']
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

    excluded_bytes = {
        (int(str(item["register"])[1:]), str(item["byte"]))
        for item in excluded_register_bytes(case)
    }
    for index, want in enumerate(expected_regs(case)[:8]):
        got = dump[f"R{index}"]
        if (index, "high") in excluded_bytes or (index, "low") in excluded_bytes:
            for byte_name, shift in (("high", 8), ("low", 0)):
                if (index, byte_name) in excluded_bytes:
                    continue
                got_byte = (got >> shift) & 0xFF
                want_byte = (want >> shift) & 0xFF
                if got_byte != want_byte:
                    suffix = "h" if byte_name == "high" else "l"
                    diffs.append(f"r{index}{suffix} {got_byte:#04x} != {want_byte:#04x}")
            continue
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


def exception_coverage(results: list[dict[str, object]]) -> dict[str, object]:
    sim_hits = {name: [] for name in sorted(SIM_DIVERGENT)}
    case_hits = {name: [] for name in sorted(SIM_DIVERGENT_CASES)}
    unmodeled_hits = {flag: [] for flag in sorted(UNMODELED_FLAGS)}
    flag_hits = {
        name: {flag: [] for flag in sorted(flags)}
        for name, flags in sorted(DIVERGENT_FLAGS.items())
    }
    result_byte_hits = {name: [] for name in sorted(DIVERGENT_RESULT_BYTE_INSTRUCTIONS)}
    for result in results:
        instruction = str(result.get("instruction"))
        case_id = str(result.get("case_id"))
        if (
            result.get("status") == "abstain"
            and result.get("reason_code") == SIM_DIVERGENT_REASON
        ):
            if case_id in case_hits:
                case_hits[case_id].append(case_id)
            elif instruction in sim_hits:
                sim_hits[instruction].append(case_id)
        scope = result.get("comparison_scope")
        if not isinstance(scope, dict):
            continue
        excluded = scope.get("ccr_flags_excluded")
        if isinstance(excluded, list):
            for item in excluded:
                if not isinstance(item, dict):
                    continue
                flag = item.get("flag")
                reason = item.get("reason_code")
                if reason == UNMODELED_FLAG_REASON and flag in unmodeled_hits:
                    unmodeled_hits[str(flag)].append(case_id)
                if reason == DIVERGENT_FLAG_REASON:
                    if instruction in flag_hits and flag in flag_hits[instruction]:
                        flag_hits[instruction][str(flag)].append(case_id)
        reg_excluded = scope.get("register_bytes_excluded")
        if isinstance(reg_excluded, list):
            for item in reg_excluded:
                if not isinstance(item, dict):
                    continue
                if item.get("reason_code") == DIVERGENT_RESULT_BYTE_REASON:
                    if instruction in result_byte_hits:
                        result_byte_hits[instruction].append(case_id)

    unused_sim = sorted(name for name, case_ids in sim_hits.items() if not case_ids)
    unused_cases = sorted(
        name for name, case_ids in case_hits.items() if not case_ids
    )
    unused_unmodeled = sorted(
        flag for flag, case_ids in unmodeled_hits.items() if not case_ids
    )
    unused_flags = {
        name: sorted(flag for flag, case_ids in flags.items() if not case_ids)
        for name, flags in flag_hits.items()
    }
    unused_flags = {name: flags for name, flags in unused_flags.items() if flags}
    unused_result_bytes = sorted(
        name for name, case_ids in result_byte_hits.items() if not case_ids
    )
    return {
        "divergent_flag_hits": flag_hits,
        "divergent_result_byte_hits": result_byte_hits,
        "sim_divergent_case_hits": case_hits,
        "sim_divergent_hits": sim_hits,
        "unused_divergent_flag_exceptions": unused_flags,
        "unused_divergent_result_byte_exceptions": unused_result_bytes,
        "unused_sim_divergent_case_exceptions": unused_cases,
        "unused_sim_divergent_exceptions": unused_sim,
        "unused_unmodeled_flag_exceptions": unused_unmodeled,
        "unmodeled_flag_hits": unmodeled_hits,
    }


def abstain_policy(
    skip_reasons: dict[str, int], compared_count: int
) -> dict[str, object]:
    unexpected = sorted(set(skip_reasons) - set(ABSTAIN_REASON_LIMITS))
    over_limit = {
        reason: {"count": count, "limit": ABSTAIN_REASON_LIMITS[reason]}
        for reason, count in sorted(skip_reasons.items())
        if reason in ABSTAIN_REASON_LIMITS and count > ABSTAIN_REASON_LIMITS[reason]
    }
    return {
        "compared_case_count": compared_count,
        "expected_reason_max_counts": dict(sorted(ABSTAIN_REASON_LIMITS.items())),
        "min_compared_case_count": MIN_COMPARED_CASES,
        "reason_over_limit": over_limit,
        "unexpected_reason_codes": unexpected,
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
    policy = abstain_policy(skip_reasons, len(passed))
    if not passed:
        blocking_errors.append("no comparable GDB oracle cases")
    if len(passed) < MIN_COMPARED_CASES:
        blocking_errors.append(
            f"GDB oracle compared cases below floor: {len(passed)} < {MIN_COMPARED_CASES}"
        )
    if policy["unexpected_reason_codes"]:
        blocking_errors.append(
            "unexpected GDB abstain reasons: "
            + ", ".join(policy["unexpected_reason_codes"])
        )
    if policy["reason_over_limit"]:
        items = [
            f"{reason}:{entry['count']}>{entry['limit']}"
            for reason, entry in sorted(policy["reason_over_limit"].items())
        ]
        blocking_errors.append(
            "GDB abstain reason count over limit: " + "; ".join(items)
        )
    exceptions = exception_coverage(results)
    if exceptions["unused_sim_divergent_exceptions"]:
        names = ", ".join(exceptions["unused_sim_divergent_exceptions"])
        blocking_errors.append(
            f"unused GDB simulator divergent instruction exceptions: {names}"
        )
    if exceptions["unused_sim_divergent_case_exceptions"]:
        names = ", ".join(exceptions["unused_sim_divergent_case_exceptions"])
        blocking_errors.append(
            f"unused GDB simulator divergent case exceptions: {names}"
        )
    if exceptions["unused_unmodeled_flag_exceptions"]:
        flags = ", ".join(exceptions["unused_unmodeled_flag_exceptions"])
        blocking_errors.append(f"unused GDB unmodeled flag exceptions: {flags}")
    if exceptions["unused_divergent_flag_exceptions"]:
        items = [
            f"{name}:{','.join(flags)}"
            for name, flags in sorted(
                exceptions["unused_divergent_flag_exceptions"].items()
            )
        ]
        blocking_errors.append(
            "unused GDB divergent flag exceptions: " + "; ".join(items)
        )
    if exceptions["unused_divergent_result_byte_exceptions"]:
        names = ", ".join(exceptions["unused_divergent_result_byte_exceptions"])
        blocking_errors.append(
            f"unused GDB divergent result-byte exceptions: {names}"
        )
    status = "fail" if failed or blocking_errors else "pass"
    report = {
        "abstained_case_count": len(skipped),
        "abstained_cases": skipped,
        "abstain_policy": policy,
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
        "divergent_result_byte_instructions": dict(
            sorted(DIVERGENT_RESULT_BYTE_INSTRUCTIONS.items())
        ),
        "exception_coverage": exceptions,
        "failed_cases": failed,
        "global_excluded_flags": [
            {"flag": flag, "reason_code": UNMODELED_FLAG_REASON}
            for flag in sorted(UNMODELED_FLAGS)
        ],
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
        "sim_divergent_cases": dict(sorted(SIM_DIVERGENT_CASES.items())),
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
