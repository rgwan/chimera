#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import re
import sys
from pathlib import Path

import yaml

import check_isa_cases


REPO_ROOT = Path(__file__).resolve().parents[1]
SAIL_PATH = REPO_ROOT / "sail" / "h8300.sail"
OUT_DIR = REPO_ROOT / "result" / "sail-coverage"
CONSTRUCTOR_RE = re.compile(r"^\s*(H8_[A-Z0-9_]+)\s*:")
MATCH_CONSTRUCTOR_RE = re.compile(r"^\s*(H8_[A-Z0-9_]+)\b", re.MULTILINE)
MACHINE_EXECUTE_EFFECTS = {"addr_update", "mem_read", "mem_write"}
BIT_MEMORY_REQUIRED_OPS = {
    "h8_bit_abs8_read": {
        "band",
        "biand",
        "bild",
        "bior",
        "bixor",
        "bld",
        "bor",
        "btst",
        "bxor",
    },
    "h8_bit_abs8_write": {"bclr", "bist", "bnot", "bset", "bst"},
    "h8_bit_r16i_read": {
        "band",
        "biand",
        "bild",
        "bior",
        "bixor",
        "bld",
        "bor",
        "btst",
        "bxor",
    },
    "h8_bit_r16i_write": {"bclr", "bist", "bnot", "bset", "bst"},
}
BIT_MEMORY_CONSTRUCTORS = {
    "h8_bit_abs8_read": "H8_BIT_ABS8_READ",
    "h8_bit_abs8_write": "H8_BIT_ABS8_WRITE",
    "h8_bit_r16i_read": "H8_BIT_R16I_READ",
    "h8_bit_r16i_write": "H8_BIT_R16I_WRITE",
}
BIT_MEMORY_DECODE_FUNCTIONS = {
    "h8_bit_abs8_read": "h8_decode_bit_abs8_read",
    "h8_bit_abs8_write": "h8_decode_bit_abs8_write",
    "h8_bit_r16i_read": "h8_decode_bit_r16i_read",
    "h8_bit_r16i_write": "h8_decode_bit_r16i_write",
}
BIT_MEMORY_EXEC_HELPERS = {
    "h8_bit_abs8_read": "h8_bit_read_ccr",
    "h8_bit_abs8_write": "h8_bit_write_result",
    "h8_bit_r16i_read": "h8_bit_read_ccr",
    "h8_bit_r16i_write": "h8_bit_write_result",
}
BIT_OP_ENUM_RE = re.compile(
    r"\bH8_BIT_("
    + "|".join(
        sorted({op.upper() for ops in BIT_MEMORY_REQUIRED_OPS.values() for op in ops})
    )
    + r")\b"
)


def h8_constructors(sail_text: str) -> list[str]:
    marker = "union H8Inst = {"
    if marker not in sail_text:
        raise ValueError("H8Inst union not found")
    body = sail_text.split(marker, 1)[1].split("\n}", 1)[0]
    constructors = []
    for line in body.splitlines():
        match = CONSTRUCTOR_RE.match(line)
        if match is not None:
            constructors.append(match.group(1))
    if not constructors:
        raise ValueError("H8Inst constructors not found")
    return constructors


def load_tables(sail_text: str) -> tuple[list[dict[str, object]], list[str]]:
    errors = []
    tables = []
    for case_path in check_isa_cases.CASE_PATHS:
        table = yaml.safe_load(case_path.read_text(encoding="utf-8"))
        table_errors, _summary = check_isa_cases.validate_table(table, sail_text)
        errors.extend(f"{case_path.relative_to(REPO_ROOT)}: {error}" for error in table_errors)
        tables.append({
            "byte_order": table.get("byte_order"),
            "case_table": str(case_path.relative_to(REPO_ROOT)),
            "cases": table["cases"],
            "instructions": table["instructions"],
            "profile": table["profile"],
            "reject_cases": table.get("reject_cases", []),
        })
    return tables, errors


def increment(counter: dict[str, int], key: str) -> None:
    counter[key] = counter.get(key, 0) + 1


def bit_case_op(case: dict[str, object]) -> str | None:
    assembler = case.get("assembler")
    if not isinstance(assembler, list) or not assembler:
        return None
    first = assembler[0]
    if not isinstance(first, str):
        return None
    return first.strip().split(maxsplit=1)[0].lower()


def bit_memory_subop_coverage(tables: list[dict[str, object]]) -> dict[str, object]:
    coverage = {
        name: {
            "case_ids_by_op": {},
            "covered_ops": [],
            "missing_ops": sorted(required),
            "required_ops": sorted(required),
            "status": "incomplete",
        }
        for name, required in BIT_MEMORY_REQUIRED_OPS.items()
    }
    for table in tables:
        for case in table["cases"]:
            if not isinstance(case, dict):
                continue
            instruction = case.get("instruction")
            if instruction not in BIT_MEMORY_REQUIRED_OPS:
                continue
            op = bit_case_op(case)
            if op is None:
                continue
            entry = coverage[str(instruction)]
            ids_by_op = entry["case_ids_by_op"]
            ids_by_op.setdefault(op, []).append(str(case["id"]))

    for instruction, required in BIT_MEMORY_REQUIRED_OPS.items():
        entry = coverage[instruction]
        covered = set(entry["case_ids_by_op"])
        missing = sorted(required - covered)
        entry["case_ids_by_op"] = dict(sorted(entry["case_ids_by_op"].items()))
        entry["covered_ops"] = sorted(covered)
        entry["missing_ops"] = missing
        entry["status"] = "complete" if not missing else "incomplete"
    return coverage


def bit_memory_gap_summary(coverage: dict[str, object]) -> list[dict[str, object]]:
    gaps = []
    for instruction, entry in sorted(coverage.items()):
        missing = entry.get("missing_ops")
        if isinstance(missing, list) and missing:
            gaps.append({
                "instruction": instruction,
                "missing_ops": missing,
                "owner": "isa_yaml_cases",
            })
    return gaps


def sail_function_body(sail_text: str, function_name: str) -> str:
    start = sail_text.find(f"function {function_name}")
    if start < 0:
        raise ValueError(f"Sail function {function_name} not found")
    ends = [
        index
        for marker in ("\nfunction ", "\nval ", "\ntype ", "\nstruct ", "\nunion ")
        for index in [sail_text.find(marker, start + 1)]
        if index >= 0
    ]
    return sail_text[start:min(ends)] if ends else sail_text[start:]


def sail_bit_ops_in_function(sail_text: str, function_name: str) -> set[str]:
    body = sail_function_body(sail_text, function_name)
    return {match.group(1).lower() for match in BIT_OP_ENUM_RE.finditer(body)}


def sail_match_constructors(sail_text: str, function_name: str) -> set[str]:
    body = sail_function_body(sail_text, function_name)
    return set(MATCH_CONSTRUCTOR_RE.findall(body))


def machine_execute_coverage(
    sail_text: str,
    effects_by_constructor: dict[str, set[str]],
    instruction_mappings: dict[str, list[dict[str, object]]],
) -> dict[str, object]:
    handled = sail_match_constructors(sail_text, "h8_execute_machine")
    required = {}
    missing = []
    for constructor, effects in sorted(effects_by_constructor.items()):
        required_effects = sorted(effects & MACHINE_EXECUTE_EFFECTS)
        if not required_effects:
            continue
        instructions = sorted(
            {
                str(row["instruction"])
                for row in instruction_mappings.get(constructor, [])
                if "instruction" in row
            }
        )
        entry = {
            "effects": required_effects,
            "handled": constructor in handled,
            "instructions": instructions,
        }
        required[constructor] = entry
        if constructor not in handled:
            missing.append({"constructor": constructor, **entry})
    return {
        "handled_constructors": sorted(handled),
        "missing_constructors": missing,
        "missing_count": len(missing),
        "required_constructors": required,
        "required_effects": sorted(MACHINE_EXECUTE_EFFECTS),
        "status": "complete" if not missing else "incomplete",
    }


def big_endian_model_checks(
    sail_text: str,
    tables: list[dict[str, object]],
) -> dict[str, object]:
    read16_body = sail_function_body(sail_text, "h8_mem_read16")
    write16_body = sail_function_body(sail_text, "h8_mem_write16")
    fetch16_body = sail_function_body(sail_text, "h8_fetch16")
    load_body = sail_function_body(sail_text, "h8_load_bytes")
    step_body = sail_function_body(sail_text, "h8_step")
    branch_body = sail_function_body(sail_text, "h8_exec_branch")
    bsr_body = sail_function_body(sail_text, "h8_exec_bsr_rel8")
    checks = [
        {
            "name": "read16_high_byte_at_even_address",
            "status": "pass"
            if "h8_mem_read8(mem, word_addr) @ h8_mem_read8(mem, word_addr + 0x0001)"
            in read16_body
            else "fail",
        },
        {
            "name": "write16_high_byte_at_even_address",
            "status": "pass"
            if "h8_mem_write8(mem, word_addr, value[15 .. 8])" in write16_body
            else "fail",
        },
        {
            "name": "write16_low_byte_at_odd_address",
            "status": "pass"
            if "h8_mem_write8(mem1, word_addr + 0x0001, value[7 .. 0])" in write16_body
            else "fail",
        },
        {
            "name": "fetch16_high_byte_at_pc",
            "status": "pass"
            if "let word_addr = align_word_addr(addr);" in fetch16_body
            and "h8_mem_read8(mem, word_addr) @ h8_mem_read8(mem, word_addr + 0x0001)"
            in fetch16_body
            else "fail",
        },
        {
            "name": "load_bytes_preserves_list_order",
            "status": "pass" if "bytes[('n - 1) - i]" in load_body else "fail",
        },
        {
            "name": "step_aligns_pc_before_execute",
            "status": "pass"
            if "let fetch_pc : word = align_word_addr(m.st.pc);" in step_body
            and "h8_decode_execute_machine(aligned, first, ext)" in step_body
            else "fail",
        },
        {
            "name": "branch_target_aligns_word",
            "status": "pass"
            if "pc = align_word_addr(next_pc + sign_extend8_to16(disp))"
            in branch_body
            else "fail",
        },
        {
            "name": "bsr_target_aligns_word",
            "status": "pass"
            if "align_word_addr(return_pc + sign_extend8_to16(disp))" in bsr_body
            else "fail",
        },
    ]
    for table in tables:
        checks.append({
            "name": f"{table['case_table']}:byte_order_big",
            "status": "pass" if table.get("byte_order") == "big" else "fail",
        })
    failed = [check for check in checks if check["status"] != "pass"]
    return {
        "checks": checks,
        "gap_count": len(failed),
        "gaps": failed,
        "status": "pass" if not failed else "fail",
    }


def bit_memory_model_coverage(sail_text: str) -> dict[str, object]:
    machine_body = sail_function_body(sail_text, "h8_execute_machine")
    coverage = {}
    for instruction, required in BIT_MEMORY_REQUIRED_OPS.items():
        constructor = BIT_MEMORY_CONSTRUCTORS[instruction]
        decode_function = BIT_MEMORY_DECODE_FUNCTIONS[instruction]
        execute_helper = BIT_MEMORY_EXEC_HELPERS[instruction]
        decode_ops = sail_bit_ops_in_function(sail_text, decode_function)
        execute_ops = sail_bit_ops_in_function(sail_text, execute_helper)
        machine_handler = f"{constructor}(" in machine_body
        coverage[instruction] = {
            "constructor": constructor,
            "decode_function": decode_function,
            "decode_missing_ops": sorted(required - decode_ops),
            "decode_ops": sorted(decode_ops & required),
            "execute_helper": execute_helper,
            "execute_missing_ops": sorted(required - execute_ops),
            "execute_ops": sorted(execute_ops & required),
            "machine_handler": machine_handler,
            "required_ops": sorted(required),
            "status": "complete"
            if required <= decode_ops and required <= execute_ops and machine_handler
            else "incomplete",
        }
    return coverage


def bit_memory_model_gap_count(coverage: dict[str, object]) -> int:
    count = 0
    for entry in coverage.values():
        if not isinstance(entry, dict):
            continue
        count += len(entry.get("decode_missing_ops", []))
        count += len(entry.get("execute_missing_ops", []))
        count += 0 if entry.get("machine_handler") else 1
    return count


def main() -> int:
    sail_text = SAIL_PATH.read_text(encoding="utf-8")
    constructors = h8_constructors(sail_text)
    constructor_set = set(constructors)
    tables, blocking_errors = load_tables(sail_text)

    instruction_mappings: dict[str, list[dict[str, object]]] = {name: [] for name in constructors}
    case_evidence: dict[str, list[dict[str, str]]] = {name: [] for name in constructors}
    effects_by_constructor: dict[str, set[str]] = {name: set() for name in constructors}
    area_counts: dict[str, int] = {}
    duplicate_rows: list[str] = []
    instructions_without_case_evidence: list[str] = []
    case_table_summaries = []

    for table in tables:
        instructions = {}
        seen_in_table: set[str] = set()
        table_area_counts: dict[str, int] = {}
        for instruction in table["instructions"]:
            instruction_id = str(instruction["id"])
            sail = instruction.get("sail") if isinstance(instruction, dict) else None
            decode = sail.get("decode") if isinstance(sail, dict) else None
            if not isinstance(decode, str):
                continue
            if decode not in constructor_set:
                blocking_errors.append(f"{table['case_table']}: unknown Sail constructor {decode}")
                continue
            if decode in seen_in_table:
                duplicate_rows.append(f"{table['case_table']}: duplicate constructor {decode}")
            seen_in_table.add(decode)
            instructions[instruction_id] = instruction
            instruction_mappings[decode].append({
                "case_table": str(table["case_table"]),
                "effects": instruction.get("effects", []),
                "instruction": instruction_id,
                "profile": str(table["profile"]),
            })
            effects = instruction.get("effects")
            if isinstance(effects, list):
                effects_by_constructor[decode].update(str(effect) for effect in effects)

        used_instruction_ids: set[str] = set()
        for case in table["cases"]:
            if not isinstance(case, dict):
                continue
            instruction_id = case.get("instruction")
            if not isinstance(instruction_id, str):
                continue
            instruction = instructions.get(instruction_id)
            if instruction is None:
                blocking_errors.append(f"{table['case_table']}: unknown instruction {instruction_id}")
                continue
            case_sail = case.get("sail")
            decode = case_sail.get("decode") if isinstance(case_sail, dict) else None
            if not isinstance(decode, str):
                continue
            if decode not in constructor_set:
                blocking_errors.append(f"{table['case_table']}: unknown Sail constructor {decode}")
                continue
            used_instruction_ids.add(instruction_id)
            check_area = case.get("check_area")
            if not isinstance(check_area, str):
                continue
            increment(area_counts, check_area)
            increment(table_area_counts, check_area)
            case_evidence[decode].append({
                "case_table": str(table["case_table"]),
                "case": str(case["id"]),
                "check_area": check_area,
                "instruction": instruction_id,
                "profile": str(table["profile"]),
            })
        for instruction_id in sorted(set(instructions) - used_instruction_ids):
            instructions_without_case_evidence.append(f"{table['case_table']}: instruction {instruction_id}")
        case_table_summaries.append({
            "case_count": len(table["cases"]),
            "case_table": str(table["case_table"]),
            "check_area_counts": dict(sorted(table_area_counts.items())),
            "instruction_count": len(table["instructions"]),
            "profile": str(table["profile"]),
            "reject_case_count": len(table["reject_cases"]),
        })

    unmapped_constructors = sorted(name for name, rows in instruction_mappings.items() if not rows)
    if unmapped_constructors:
        blocking_errors.append("unmapped Sail constructors: " + ", ".join(unmapped_constructors))

    case_count_by_constructor = {}
    constructors_without_case_evidence = []
    constructors_with_decode_only_cases = []
    semantic_case_count_by_constructor = {}
    semantic_evidence_constructor_count = 0
    per_constructor_case_area_counts = {}
    for name, rows in case_evidence.items():
        constructor_area_counts: dict[str, int] = {}
        for row in rows:
            increment(constructor_area_counts, row["check_area"])
        semantic_case_count = sum(count for area, count in constructor_area_counts.items() if area != "decode")
        case_count_by_constructor[name] = len(rows)
        per_constructor_case_area_counts[name] = dict(sorted(constructor_area_counts.items()))
        semantic_case_count_by_constructor[name] = semantic_case_count
        if not rows:
            constructors_without_case_evidence.append(name)
        elif semantic_case_count == 0:
            constructors_with_decode_only_cases.append(name)
        else:
            semantic_evidence_constructor_count += 1

    constructors_without_semantic_cases = sorted(
        set(constructors_without_case_evidence) | set(constructors_with_decode_only_cases)
    )
    advisory_gaps = {
        "constructors_with_decode_only_cases": sorted(constructors_with_decode_only_cases),
        "constructors_without_case_evidence": sorted(constructors_without_case_evidence),
        "instructions_without_case_evidence": instructions_without_case_evidence,
    }
    advisory_gap_count = sum(len(items) for items in advisory_gaps.values())
    bit_memory_coverage = bit_memory_subop_coverage(tables)
    bit_memory_gap_count = sum(len(entry["missing_ops"]) for entry in bit_memory_coverage.values())
    bit_memory_gaps = bit_memory_gap_summary(bit_memory_coverage)
    bit_model_coverage = bit_memory_model_coverage(sail_text)
    bit_model_gap_count = bit_memory_model_gap_count(bit_model_coverage)
    if bit_model_gap_count:
        blocking_errors.append("incomplete Sail bit-memory model coverage")
    machine_coverage = machine_execute_coverage(
        sail_text,
        effects_by_constructor,
        instruction_mappings,
    )
    machine_gap_count = int(machine_coverage["missing_count"])
    if machine_gap_count:
        blocking_errors.append("incomplete Sail machine execute coverage")
    endian_checks = big_endian_model_checks(sail_text, tables)
    endian_gap_count = int(endian_checks["gap_count"])
    if endian_gap_count:
        blocking_errors.append("incomplete Sail big-endian model checks")

    instruction_mappings_by_constructor = {
        name: rows for name, rows in instruction_mappings.items() if rows
    }
    effects_report = {
        name: sorted(effects) for name, effects in effects_by_constructor.items() if effects
    }
    constructor_evidence = {
        name: {
            "case_count": len(rows),
            "case_count_by_check_area": per_constructor_case_area_counts[name],
            "semantic_case_count": semantic_case_count_by_constructor[name],
        }
        for name, rows in case_evidence.items()
    }

    base_reject_count = 0
    for table in tables:
        if table["profile"] == "h8300_base":
            base_reject_count += len(table["reject_cases"])

    constructor_coverage = {
        "constructor_count": len(constructors),
        "duplicate_constructor_mappings": duplicate_rows,
        "effects_by_constructor": effects_report,
        "instruction_mappings_by_constructor": instruction_mappings_by_constructor,
        "mapped_constructor_count": len(constructors) - len(unmapped_constructors),
        "unmapped_constructors": unmapped_constructors,
    }
    semantic_case_evidence = {
        "advisory_gap_count": advisory_gap_count,
        "advisory_gaps": advisory_gaps,
        "bit_memory_gap_summary": bit_memory_gaps,
        "bit_memory_missing_subop_count": bit_memory_gap_count,
        "bit_memory_model_coverage": bit_model_coverage,
        "bit_memory_model_gap_count": bit_model_gap_count,
        "bit_memory_subop_coverage": bit_memory_coverage,
        "big_endian_model_checks": endian_checks,
        "case_count_by_check_area": dict(sorted(area_counts.items())),
        "case_count_by_constructor": case_count_by_constructor,
        "case_evidence_by_constructor": case_evidence,
        "case_table_summaries": case_table_summaries,
        "constructor_evidence": constructor_evidence,
        "constructors_with_decode_only_cases": sorted(constructors_with_decode_only_cases),
        "constructors_without_case_evidence": sorted(constructors_without_case_evidence),
        "constructors_without_semantic_cases": constructors_without_semantic_cases,
        "machine_execute_coverage": machine_coverage,
        "machine_execute_gap_count": machine_gap_count,
        "oracle_gap_status": "non_blocking",
        "reject_case_count": base_reject_count,
        "semantic_case_count_by_constructor": semantic_case_count_by_constructor,
        "semantic_evidence_constructor_count": semantic_evidence_constructor_count,
    }
    report = {
        "blocking_errors": blocking_errors,
        "case_check_area_counts": dict(sorted(area_counts.items())),
        "case_source_policy": {
            "coverage_gaps_are_case_author_todos": True,
            "isa_yaml_cases_are_third_party_oracle_data": True,
            "sail_implementer_must_not_edit_cases": True,
        },
        "bit_memory_gap_summary": bit_memory_gaps,
        "bit_memory_missing_subop_count": bit_memory_gap_count,
        "bit_memory_model_coverage": bit_model_coverage,
        "bit_memory_model_gap_count": bit_model_gap_count,
        "big_endian_model_checks": endian_checks,
        "big_endian_model_gap_count": endian_gap_count,
        "constructor_coverage": constructor_coverage,
        "constructor_count": len(constructors),
        "covered_constructor_count": constructor_coverage["mapped_constructor_count"],
        "decode_only_constructors": semantic_case_evidence["constructors_with_decode_only_cases"],
        "duplicate_rows": duplicate_rows,
        "errors": blocking_errors,
        "limitations": [
            "semantic evidence is case-focused coverage, not operand-space closure",
            "third-party oracle gaps are advisory in this report",
        ],
        "machine_execute_coverage": machine_coverage,
        "machine_execute_gap_count": machine_gap_count,
        "profile_count": len(tables),
        "report_schema": 3,
        "reject_case_count": base_reject_count,
        "semantic_case_evidence": semantic_case_evidence,
        "semantic_covered_constructor_count": semantic_evidence_constructor_count,
        "status": "fail" if blocking_errors else "pass",
        "uncovered_instruction_rows": instructions_without_case_evidence,
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    report_path = OUT_DIR / "sail-coverage.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(
        f"sail coverage {report['status']}: {report_path.relative_to(REPO_ROOT)} "
        f"semantic={report['semantic_covered_constructor_count']}/{report['constructor_count']} "
        f"bit_subop_gaps={bit_memory_gap_count} "
        f"bit_model_gaps={bit_model_gap_count} "
        f"machine_gaps={machine_gap_count} "
        f"endian_gaps={endian_gap_count}"
    )
    if blocking_errors:
        for error in blocking_errors:
            print(error)
    return 1 if blocking_errors else 0


if __name__ == "__main__":
    sys.exit(main())
