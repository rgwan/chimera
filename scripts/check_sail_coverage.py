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


def main() -> int:
    sail_text = SAIL_PATH.read_text(encoding="utf-8")
    constructors = h8_constructors(sail_text)
    constructor_set = set(constructors)
    tables, errors = load_tables(sail_text)

    coverage: dict[str, list[dict[str, str]]] = {name: [] for name in constructors}
    duplicate_rows: list[str] = []
    uncovered_instruction_rows: list[str] = []
    for table in tables:
        instructions = {}
        seen_in_table: set[str] = set()
        for instruction in table["instructions"]:
            instruction_id = str(instruction["id"])
            decode = str(instruction["sail"]["decode"])
            if decode not in constructor_set:
                errors.append(f"{table['case_table']}: unknown Sail constructor {decode}")
                continue
            if decode in seen_in_table:
                duplicate_rows.append(f"{table['case_table']}: duplicate constructor {decode}")
            seen_in_table.add(decode)
            instructions[instruction_id] = instruction

        used_instruction_ids: set[str] = set()
        for case in table["cases"]:
            instruction_id = str(case["instruction"])
            instruction = instructions.get(instruction_id)
            if instruction is None:
                errors.append(f"{table['case_table']}: unknown instruction {instruction_id}")
                continue
            decode = str(case["sail"]["decode"])
            if decode not in constructor_set:
                errors.append(f"{table['case_table']}: unknown Sail constructor {decode}")
                continue
            used_instruction_ids.add(instruction_id)
            coverage[decode].append({
                "case_table": str(table["case_table"]),
                "case": str(case["id"]),
                "instruction": instruction_id,
                "profile": str(table["profile"]),
            })
        for instruction_id in sorted(set(instructions) - used_instruction_ids):
            uncovered_instruction_rows.append(f"{table['case_table']}: instruction {instruction_id}")

    if uncovered_instruction_rows:
        errors.append("uncovered instruction rows: " + ", ".join(uncovered_instruction_rows))

    missing = sorted(name for name, rows in coverage.items() if not rows)
    if missing:
        errors.append("missing constructor coverage: " + ", ".join(missing))

    base_reject_count = 0
    for table in tables:
        if table["profile"] == "h8300_base":
            base_reject_count += len(table["reject_cases"])

    report = {
        "constructor_count": len(constructors),
        "covered_constructor_count": len(constructors) - len(missing),
        "coverage": coverage,
        "duplicate_rows": duplicate_rows,
        "errors": errors,
        "profile_count": len(tables),
        "reject_case_count": base_reject_count,
        "status": "fail" if errors else "pass",
        "uncovered_instruction_rows": uncovered_instruction_rows,
    }
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    report_path = OUT_DIR / "sail-coverage.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"sail coverage {report['status']}: {report_path.relative_to(REPO_ROOT)}")
    if errors:
        for error in errors:
            print(error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
