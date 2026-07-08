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
BIT_MEMORY_REQUIRED_OPS = {
    "h8_bit_abs8_read": {"band", "biand", "bild", "bior", "bixor", "bld", "bor", "btst", "bxor"},
    "h8_bit_abs8_write": {"bclr", "bist", "bnot", "bset", "bst"},
    "h8_bit_r16i_read": {"band", "biand", "bild", "bior", "bixor", "bld", "bor", "btst", "bxor"},
    "h8_bit_r16i_write": {"bclr", "bist", "bnot", "bset", "bst"},
}


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
        "bit_memory_subop_coverage": bit_memory_coverage,
        "case_count_by_check_area": dict(sorted(area_counts.items())),
        "case_count_by_constructor": case_count_by_constructor,
        "case_evidence_by_constructor": case_evidence,
        "case_table_summaries": case_table_summaries,
        "constructor_evidence": constructor_evidence,
        "constructors_with_decode_only_cases": sorted(constructors_with_decode_only_cases),
        "constructors_without_case_evidence": sorted(constructors_without_case_evidence),
        "constructors_without_semantic_cases": constructors_without_semantic_cases,
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
        "profile_count": len(tables),
        "report_schema": 2,
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
        f"bit_subop_gaps={bit_memory_gap_count}"
    )
    if blocking_errors:
        for error in blocking_errors:
            print(error)
    return 1 if blocking_errors else 0


if __name__ == "__main__":
    sys.exit(main())
