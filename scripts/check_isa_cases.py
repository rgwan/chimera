#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import re
import sys
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
CASE_PATH = REPO_ROOT / "isa" / "h8300_base_cases.yaml"
SAIL_PATH = REPO_ROOT / "sail" / "h8300.sail"
OUT_DIR = REPO_ROOT / "result" / "isa-cases"

ID_RE = re.compile(r"^h8_[a-z0-9_]+$")
NIBBLE_RE = re.compile(r"^[0-9a-f]$")
WORD_RE = re.compile(r"^0x[0-9a-f]{4}$")
BYTE_REG_RE = re.compile(r"^r[0-7][hl]$")
WORD_REG_RE = re.compile(r"^r[0-7]$")
HNZVC_RE = re.compile(r"^[01]{5}$")


def fail(errors: list[str], path: str, message: str) -> None:
    errors.append(f"{path}: {message}")


def parse_word(value: object, path: str, errors: list[str]) -> int:
    validate_hex(value, WORD_RE, path, errors)
    return int(value, 16) if isinstance(value, str) and WORD_RE.fullmatch(value) is not None else 0


def expect_dict(errors: list[str], value: object, path: str) -> dict[str, object]:
    if isinstance(value, dict):
        return value
    fail(errors, path, "expected mapping")
    return {}


def expect_list(errors: list[str], value: object, path: str) -> list[object]:
    if isinstance(value, list):
        return value
    fail(errors, path, "expected list")
    return []


def validate_hex(value: object, pattern: re.Pattern[str], path: str, errors: list[str]) -> None:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        fail(errors, path, "bad hex spelling")


def validate_regs(regs: object, path: str, errors: list[str]) -> None:
    reg_map = expect_dict(errors, regs, path)
    for name, value in reg_map.items():
        if not isinstance(name, str) or (BYTE_REG_RE.fullmatch(name) is None and WORD_REG_RE.fullmatch(name) is None):
            fail(errors, f"{path}.{name}", "bad register name")
        if not isinstance(value, str):
            fail(errors, f"{path}.{name}", "bad register value")
            continue
        pattern = WORD_RE if WORD_REG_RE.fullmatch(name) is not None else re.compile(r"^0x[0-9a-f]{2}$")
        validate_hex(value, pattern, f"{path}.{name}", errors)


def validate_sail_symbols(sail: dict[str, object], path: str, sail_text: str, errors: list[str]) -> None:
    for field in ("decode", "execute"):
        symbol = sail.get(field)
        if not isinstance(symbol, str) or symbol not in sail_text:
            fail(errors, f"{path}.{field}", "symbol not found in Sail model")


def validate_instruction(
    instruction: object,
    index: int,
    sail_text: str,
    ids: set[str],
    encodings: list[tuple[str, int, int]],
    errors: list[str],
) -> None:
    path = f"instructions[{index}]"
    item = expect_dict(errors, instruction, path)
    instr_id = item.get("id")
    if not isinstance(instr_id, str) or ID_RE.fullmatch(instr_id) is None:
        fail(errors, f"{path}.id", "bad instruction id")
    elif instr_id in ids:
        fail(errors, f"{path}.id", "duplicate instruction id")
    else:
        ids.add(instr_id)

    if not isinstance(item.get("assembler_template"), str):
        fail(errors, f"{path}.assembler_template", "expected string")

    if item.get("length_bytes") not in {2, 4}:
        fail(errors, f"{path}.length_bytes", "expected 2 or 4")

    encoding = expect_dict(errors, item.get("encoding"), f"{path}.encoding")
    mask = parse_word(encoding.get("mask"), f"{path}.encoding.mask", errors)
    match = parse_word(encoding.get("match"), f"{path}.encoding.match", errors)
    if match & ~mask:
        fail(errors, f"{path}.encoding.match", "match sets bits outside mask")
    for other_id, other_mask, other_match in encodings:
        if ((match ^ other_match) & (mask & other_mask)) == 0:
            fail(errors, f"{path}.encoding", f"overlaps {other_id}")
    if isinstance(instr_id, str):
        encodings.append((instr_id, mask, match))

    expect_dict(errors, encoding.get("fields"), f"{path}.encoding.fields")
    validate_sail_symbols(expect_dict(errors, item.get("sail"), f"{path}.sail"), f"{path}.sail", sail_text, errors)
    effects = expect_list(errors, item.get("effects"), f"{path}.effects")
    if not effects or not all(isinstance(effect, str) and effect for effect in effects):
        fail(errors, f"{path}.effects", "empty effects")


def validate_case(
    case: object,
    index: int,
    sail_text: str,
    ids: set[str],
    instructions: dict[str, dict[str, object]],
    errors: list[str],
) -> None:
    path = f"cases[{index}]"
    item = expect_dict(errors, case, path)
    case_id = item.get("id")
    if not isinstance(case_id, str) or ID_RE.fullmatch(case_id) is None:
        fail(errors, f"{path}.id", "bad canonical id")
    elif case_id in ids:
        fail(errors, f"{path}.id", "duplicate canonical id")
    else:
        ids.add(case_id)

    if isinstance(case_id, str) and any(marker in case_id for marker in (".", "-")):
        fail(errors, f"{path}.id", "id must not use assembler spelling")

    instruction_id = item.get("instruction")
    if not isinstance(instruction_id, str) or instruction_id not in instructions:
        fail(errors, f"{path}.instruction", "unknown instruction id")

    if item.get("status") != "supported":
        fail(errors, f"{path}.status", "expected supported")
    if item.get("check_area") not in {"decode", "execute", "flags", "branch", "trap"}:
        fail(errors, f"{path}.check_area", "bad check area")

    assembler = expect_list(errors, item.get("assembler"), f"{path}.assembler")
    if not assembler or not all(isinstance(line, str) and line for line in assembler):
        fail(errors, f"{path}.assembler", "empty assembler")

    words = expect_list(errors, item.get("words"), f"{path}.words")
    if not words:
        fail(errors, f"{path}.words", "empty words")
    for word_index, word in enumerate(words):
        validate_hex(word, WORD_RE, f"{path}.words[{word_index}]", errors)
    if isinstance(instruction_id, str) and instruction_id in instructions:
        expected_length = instructions[instruction_id].get("length_bytes")
        if isinstance(expected_length, int) and len(words) * 2 != expected_length:
            fail(errors, f"{path}.words", "word count does not match instruction length")

    keys = expect_list(errors, item.get("decode_keys"), f"{path}.decode_keys")
    for key_index, key in enumerate(keys):
        if not isinstance(key, str) or NIBBLE_RE.fullmatch(key) is None:
            fail(errors, f"{path}.decode_keys[{key_index}]", "decode key must be one nibble")

    case_sail = expect_dict(errors, item.get("sail"), f"{path}.sail")
    validate_sail_symbols(case_sail, f"{path}.sail", sail_text, errors)
    if isinstance(instruction_id, str) and instruction_id in instructions:
        instruction_sail = instructions[instruction_id].get("sail")
        if isinstance(instruction_sail, dict):
            for field in ("decode", "execute"):
                if case_sail.get(field) != instruction_sail.get(field):
                    fail(errors, f"{path}.sail.{field}", "does not match instruction mapping")

    initial = expect_dict(errors, item.get("initial"), f"{path}.initial")
    expected = expect_dict(errors, item.get("expected"), f"{path}.expected")
    validate_hex(initial.get("pc"), WORD_RE, f"{path}.initial.pc", errors)
    validate_hex(expected.get("pc"), WORD_RE, f"{path}.expected.pc", errors)
    validate_regs(initial.get("regs", {}), f"{path}.initial.regs", errors)
    validate_regs(expected.get("regs", {}), f"{path}.expected.regs", errors)

    for state_name, state in (("initial", initial), ("expected", expected)):
        hnzvc = state.get("ccr_hnzvc")
        if hnzvc != "preserve" and (not isinstance(hnzvc, str) or HNZVC_RE.fullmatch(hnzvc) is None):
            fail(errors, f"{path}.{state_name}.ccr_hnzvc", "bad HNZVC value")

    if not isinstance(expected.get("trap"), bool):
        fail(errors, f"{path}.expected.trap", "expected bool")


def validate_table(table: object, sail_text: str) -> tuple[list[str], dict[str, object]]:
    errors: list[str] = []
    root = expect_dict(errors, table, "root")
    if root.get("schema") != 1:
        fail(errors, "schema", "expected schema 1")
    if root.get("profile") != "h8300_base":
        fail(errors, "profile", "expected h8300_base")
    if root.get("decode_key_bits_max") != 4:
        fail(errors, "decode_key_bits_max", "expected 4")
    if root.get("fetch_word_bits") != 16:
        fail(errors, "fetch_word_bits", "expected 16")
    storage_width = root.get("storage_word_bits")
    if not isinstance(storage_width, int) or storage_width % 9 != 0:
        fail(errors, "storage_word_bits", "expected multiple of 9")
    if root.get("byte_order") != "big":
        fail(errors, "byte_order", "expected big")
    if root.get("ccr_order") != "HNZVC":
        fail(errors, "ccr_order", "expected HNZVC")

    for audit_name in ("chip", "psychology"):
        audit = expect_list(errors, expect_dict(errors, root.get("audits"), "audits").get(audit_name), f"audits.{audit_name}")
        if not audit:
            fail(errors, f"audits.{audit_name}", "empty audit")

    instruction_ids: set[str] = set()
    encodings: list[tuple[str, int, int]] = []
    instructions: dict[str, dict[str, object]] = {}
    instruction_rows = expect_list(errors, root.get("instructions"), "instructions")
    for index, instruction in enumerate(instruction_rows):
        validate_instruction(instruction, index, sail_text, instruction_ids, encodings, errors)
        if isinstance(instruction, dict) and isinstance(instruction.get("id"), str):
            instructions[instruction["id"]] = instruction

    case_ids: set[str] = set()
    cases = expect_list(errors, root.get("cases"), "cases")
    for index, case in enumerate(cases):
        validate_case(case, index, sail_text, case_ids, instructions, errors)

    summary = {
        "case_count": len(cases),
        "decode_key_bits_max": root.get("decode_key_bits_max"),
        "fetch_word_bits": root.get("fetch_word_bits"),
        "instruction_count": len(instruction_rows),
        "profile": root.get("profile"),
        "schema": root.get("schema"),
        "storage_word_bits": root.get("storage_word_bits"),
    }
    return errors, summary


def main() -> int:
    table = yaml.safe_load(CASE_PATH.read_text(encoding="utf-8"))
    sail_text = SAIL_PATH.read_text(encoding="utf-8")
    errors, summary = validate_table(table, sail_text)
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    report = {
        "case_table": str(CASE_PATH.relative_to(REPO_ROOT)),
        "status": "fail" if errors else "pass",
        "summary": summary,
        "errors": errors,
    }
    report_path = OUT_DIR / "isa-cases.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"isa cases {report['status']}: {report_path.relative_to(REPO_ROOT)}")
    if errors:
        for error in errors:
            print(error)
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
