#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import re
import sys
from pathlib import Path

import yaml


REPO_ROOT = Path(__file__).resolve().parents[1]
CASE_PATHS = [
    REPO_ROOT / "isa" / "h8300_base_cases.yaml",
    REPO_ROOT / "isa" / "h8300_legacy_cases.yaml",
]
SAIL_PATH = REPO_ROOT / "sail" / "h8300.sail"
OUT_DIR = REPO_ROOT / "result" / "isa-cases"
PROFILE_SAIL_ENUM = {
    "h8300_base": "H8_BASE",
    "h8300_legacy": "H8_LEGACY",
}

ID_RE = re.compile(r"^h8_[a-z0-9_]+$")
FIELD_RE = re.compile(r"^[a-z][a-z0-9_]*$")
BRANCH_CASE_RE = re.compile(
    r"^h8_(bra|brn|bhi|bls|bcc|bcs|bne|beq|bvc|bvs|bpl|bmi|bge|blt|bgt|ble)_rel8_(taken|not_taken)$"
)
NIBBLE_RE = re.compile(r"^[0-9a-f]$")
WORD_RE = re.compile(r"^0x[0-9a-f]{4}$")
BYTE_RE = re.compile(r"^0x[0-9a-f]{2}$")
WMASK_RE = re.compile(r"^[01]{2}$")
BYTE_REG_RE = re.compile(r"^r[0-7][hl]$")
WORD_REG_RE = re.compile(r"^[re][0-7]$")
HNZVC_INITIAL_RE = re.compile(r"^[01]{5}$")
HNZVC_EXPECTED_RE = re.compile(r"^[01x]{5}$")
TRACE_KINDS = {"bits", "bool", "enum", "uint"}
TRACE_REQUIRED_FIELDS = {
    "valid",
    "start_pc",
    "pc",
    "instruction_id",
    "trap",
    "ccr_hnzvc",
    "gpr_write_count",
    "mem_access_count",
}
TRACE_REG_FIELDS = {"gpr_write_count", "gpr_write0_name", "gpr_write0_value"}
TRACE_REG_MULTI_FIELDS = TRACE_REG_FIELDS | {"gpr_write1_name", "gpr_write1_value"}
TRACE_MEM_FIELDS = {
    "mem_access_count",
    "mem0_kind",
    "mem0_addr",
    "mem0_wmask",
    "mem0_wdata",
    "mem0_rdata",
}
TRACE_MEM_MULTI_FIELDS = TRACE_MEM_FIELDS | {
    "mem1_kind",
    "mem1_addr",
    "mem1_wmask",
    "mem1_wdata",
    "mem1_rdata",
}
BRANCH_CODES = {
    "bra": 0x0,
    "brn": 0x1,
    "bhi": 0x2,
    "bls": 0x3,
    "bcc": 0x4,
    "bcs": 0x5,
    "bne": 0x6,
    "beq": 0x7,
    "bvc": 0x8,
    "bvs": 0x9,
    "bpl": 0xA,
    "bmi": 0xB,
    "bge": 0xC,
    "blt": 0xD,
    "bgt": 0xE,
    "ble": 0xF,
}
BRANCH_REQUIRED_OUTCOMES = {
    name: ({"taken"} if name == "bra" else {"not_taken"} if name == "brn" else {"taken", "not_taken"})
    for name in BRANCH_CODES
}


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


def validate_memory_map(mem: object, path: str, errors: list[str]) -> None:
    mem_map = expect_dict(errors, mem, path)
    for addr, value in mem_map.items():
        validate_hex(addr, WORD_RE, f"{path}.{addr}", errors)
        validate_hex(value, BYTE_RE, f"{path}.{addr}", errors)


def validate_memory_access(access: object, path: str, errors: list[str]) -> dict[str, object]:
    item = expect_dict(errors, access, path)
    kind = item.get("kind")
    if kind not in {"read", "write"}:
        fail(errors, f"{path}.kind", "expected read or write")
    width = item.get("width")
    if width not in {"byte", "word"}:
        fail(errors, f"{path}.width", "expected byte or word")
    validate_hex(item.get("addr"), WORD_RE, f"{path}.addr", errors)

    if kind == "read":
        validate_hex(item.get("rdata"), WORD_RE, f"{path}.rdata", errors)
        if "wmask" in item:
            validate_hex(item.get("wmask"), WMASK_RE, f"{path}.wmask", errors)
        if "wdata" in item:
            validate_hex(item.get("wdata"), WORD_RE, f"{path}.wdata", errors)
    elif kind == "write":
        validate_hex(item.get("wmask"), WMASK_RE, f"{path}.wmask", errors)
        validate_hex(item.get("wdata"), WORD_RE, f"{path}.wdata", errors)
        if "rdata" in item:
            validate_hex(item.get("rdata"), WORD_RE, f"{path}.rdata", errors)

    if width == "word" and kind == "write" and item.get("wmask") != "11":
        fail(errors, f"{path}.wmask", "word write must enable both bytes")
    return item


def word_from_memory_map(
    mem_map: dict[str, object],
    addr: object,
    path: str,
    errors: list[str],
) -> str | None:
    if not isinstance(addr, str) or WORD_RE.fullmatch(addr) is None:
        return None
    base = int(addr, 16)
    if base & 1:
        fail(errors, path, "word access address must be even")
        return None

    hi_addr = f"0x{base:04x}"
    lo_addr = f"0x{(base + 1) & 0xffff:04x}"
    missing = [name for name in (hi_addr, lo_addr) if name not in mem_map]
    if missing:
        fail(errors, path, f"word access missing bytes: {', '.join(missing)}")
        return None

    hi = mem_map.get(hi_addr)
    lo = mem_map.get(lo_addr)
    if not isinstance(hi, str) or BYTE_RE.fullmatch(hi) is None:
        return None
    if not isinstance(lo, str) or BYTE_RE.fullmatch(lo) is None:
        return None
    return f"0x{((int(hi, 16) << 8) | int(lo, 16)):04x}"


def validate_word_memory_access(
    initial: dict[str, object],
    expected: dict[str, object],
    access: dict[str, object],
    path: str,
    errors: list[str],
) -> None:
    if access.get("width") != "word":
        return

    kind = access.get("kind")
    if kind == "read":
        if access.get("wmask", "00") != "00":
            fail(errors, f"{path}.access.wmask", "word read must not enable writes")
        if access.get("wdata", "0x0000") != "0x0000":
            fail(errors, f"{path}.access.wdata", "word read must not carry write data")
        word = word_from_memory_map(initial, access.get("addr"), f"{path}.initial", errors)
        if word is not None and access.get("rdata") != word:
            fail(errors, f"{path}.access.rdata", f"expected {word}")
    elif kind == "write":
        word = word_from_memory_map(expected, access.get("addr"), f"{path}.expected", errors)
        if word is not None and access.get("wdata") != word:
            fail(errors, f"{path}.access.wdata", f"expected {word}")


def validate_case_memory(memory: object, path: str, errors: list[str]) -> dict[str, object]:
    item = expect_dict(errors, memory, path)
    initial = expect_dict(errors, item.get("initial", {}), f"{path}.initial")
    expected = expect_dict(errors, item.get("expected", {}), f"{path}.expected")
    validate_memory_map(initial, f"{path}.initial", errors)
    validate_memory_map(expected, f"{path}.expected", errors)

    if "accesses" in item:
        accesses = expect_list(errors, item.get("accesses"), f"{path}.accesses")
        if not 1 <= len(accesses) <= 2:
            fail(errors, f"{path}.accesses", "expected one or two accesses")
        for index, access_item in enumerate(accesses):
            access = validate_memory_access(access_item, f"{path}.accesses[{index}]", errors)
            validate_word_memory_access(initial, expected, access, f"{path}.accesses[{index}]", errors)
        return item

    access = validate_memory_access(item.get("access"), f"{path}.access", errors)
    validate_word_memory_access(initial, expected, access, path, errors)
    return item


def validate_sail_symbols(sail: dict[str, object], path: str, sail_text: str, errors: list[str]) -> None:
    for field in ("decode", "execute"):
        symbol = sail.get(field)
        if not isinstance(symbol, str) or re.search(rf"\b{re.escape(symbol)}\b", sail_text) is None:
            fail(errors, f"{path}.{field}", "symbol not found in Sail model")


def branch_taken(name: str, hnzvc: str) -> bool:
    n = hnzvc[1] == "1"
    z = hnzvc[2] == "1"
    v = hnzvc[3] == "1"
    c = hnzvc[4] == "1"
    return {
        "bra": True,
        "brn": False,
        "bhi": not c and not z,
        "bls": c or z,
        "bcc": not c,
        "bcs": c,
        "bne": not z,
        "beq": z,
        "bvc": not v,
        "bvs": v,
        "bpl": not n,
        "bmi": n,
        "bge": n == v,
        "blt": n != v,
        "bgt": not z and n == v,
        "ble": z or n != v,
    }[name]


def branch_target(pc: int, disp8: int, taken: bool) -> int:
    next_pc = (pc + 2) & 0xFFFF
    if not taken:
        return next_pc
    signed_disp = disp8 - 0x100 if disp8 & 0x80 else disp8
    return (next_pc + signed_disp) & 0xFFFF


def validate_branch_case(
    case: dict[str, object],
    path: str,
    coverage: dict[str, set[str]],
    errors: list[str],
) -> None:
    case_id = case.get("id")
    if not isinstance(case_id, str):
        return
    match = BRANCH_CASE_RE.fullmatch(case_id)
    if match is None:
        return
    name, outcome = match.groups()
    coverage.setdefault(name, set()).add(outcome)
    if case.get("instruction") != "h8_branch_rel8":
        fail(errors, f"{path}.instruction", "branch case must use h8_branch_rel8")

    words = expect_list(errors, case.get("words"), f"{path}.words")
    if len(words) != 1:
        fail(errors, f"{path}.words", "branch case must use one word")
        return
    word = parse_word(words[0], f"{path}.words[0]", errors)
    expected_word = 0x4000 | (BRANCH_CODES[name] << 8) | (word & 0xFF)
    if word != expected_word:
        fail(errors, f"{path}.words[0]", "branch condition does not match case id")
    if word & 0x1:
        fail(errors, f"{path}.words[0]", "branch displacement must be even")

    initial = expect_dict(errors, case.get("initial"), f"{path}.initial")
    expected = expect_dict(errors, case.get("expected"), f"{path}.expected")
    hnzvc = initial.get("ccr_hnzvc")
    if not isinstance(hnzvc, str) or HNZVC_INITIAL_RE.fullmatch(hnzvc) is None:
        return
    actual_taken = branch_taken(name, hnzvc)
    if (outcome == "taken") != actual_taken:
        fail(errors, f"{path}.initial.ccr_hnzvc", "does not match branch outcome")
    pc = parse_word(initial.get("pc"), f"{path}.initial.pc", errors)
    expected_pc = branch_target(pc, word & 0xFF, actual_taken)
    case_pc = parse_word(expected.get("pc"), f"{path}.expected.pc", errors)
    if case_pc != expected_pc:
        fail(errors, f"{path}.expected.pc", f"expected 0x{expected_pc:04x}")


def validate_branch_coverage(coverage: dict[str, set[str]], errors: list[str]) -> None:
    for name, required in BRANCH_REQUIRED_OUTCOMES.items():
        missing = required - coverage.get(name, set())
        if missing:
            fail(errors, "cases", f"missing {name} branch cases: {', '.join(sorted(missing))}")


def validate_retire_trace_shape(trace: object, root: dict[str, object], errors: list[str]) -> set[str]:
    path = "retire_trace"
    item = expect_dict(errors, trace, path)
    if item.get("schema") != 1:
        fail(errors, f"{path}.schema", "expected schema 1")
    if item.get("record") != "h8_retire":
        fail(errors, f"{path}.record", "expected h8_retire")

    compare_fields = expect_list(errors, item.get("compare_fields"), f"{path}.compare_fields")
    if compare_fields != root.get("retire_compare"):
        fail(errors, f"{path}.compare_fields", "does not match retire_compare")

    field_names: set[str] = set()
    fields = expect_list(errors, item.get("fields"), f"{path}.fields")
    for index, field in enumerate(fields):
        field_path = f"{path}.fields[{index}]"
        field_item = expect_dict(errors, field, field_path)
        name = field_item.get("name")
        if not isinstance(name, str) or FIELD_RE.fullmatch(name) is None:
            fail(errors, f"{field_path}.name", "bad field name")
        elif name in field_names:
            fail(errors, f"{field_path}.name", "duplicate field name")
        else:
            field_names.add(name)

        kind = field_item.get("kind")
        if kind not in TRACE_KINDS:
            fail(errors, f"{field_path}.kind", "bad field kind")
        if kind in {"bits", "uint"} and not isinstance(field_item.get("bits"), int):
            fail(errors, f"{field_path}.bits", "expected integer width")
        if not isinstance(field_item.get("source"), str) or not field_item.get("source"):
            fail(errors, f"{field_path}.source", "expected source string")
        if not isinstance(field_item.get("required"), bool):
            fail(errors, f"{field_path}.required", "expected bool")

    missing = TRACE_REQUIRED_FIELDS - field_names
    if missing:
        fail(errors, f"{path}.fields", f"missing required fields: {', '.join(sorted(missing))}")
    return field_names


def validate_retire_trace_effects(
    instructions: dict[str, dict[str, object]],
    trace_fields: set[str],
    errors: list[str],
) -> None:
    if not TRACE_REG_FIELDS <= trace_fields:
        fail(errors, "retire_trace.fields", "missing register write fields")
    if not TRACE_MEM_FIELDS <= trace_fields:
        fail(errors, "retire_trace.fields", "missing memory access fields")

    for instr_id, instruction in instructions.items():
        effects = instruction.get("effects")
        if not isinstance(effects, list):
            continue
        if "pc" in effects and "pc" not in trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "pc effect lacks trace pc")
        if "branch" in effects and "pc" not in trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "branch effect lacks trace pc")
        if "ccr_hnzvc" in effects and "ccr_hnzvc" not in trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "flag effect lacks trace ccr_hnzvc")
        if "ccr_nzv" in effects and "ccr_hnzvc" not in trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "flag effect lacks trace ccr_hnzvc")
        if any(effect in {"rd8", "rd16", "addr_update"} for effect in effects) and not TRACE_REG_FIELDS <= trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "register effect lacks trace writeback")
        if "addr_update" in effects and any(effect in {"rd8", "rd16"} for effect in effects):
            if not TRACE_REG_MULTI_FIELDS <= trace_fields:
                fail(errors, f"instructions.{instr_id}.effects", "multi-register effect lacks trace writeback")
        if any(effect in {"mem_read", "mem_write"} for effect in effects) and not TRACE_MEM_FIELDS <= trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "memory effect lacks trace access")
        if all(effect in effects for effect in ("mem_read", "mem_write")) and not TRACE_MEM_MULTI_FIELDS <= trace_fields:
            fail(errors, f"instructions.{instr_id}.effects", "multi-memory effect lacks trace access")


def build_trace_expectation(
    case: dict[str, object],
    instruction: dict[str, object] | None,
    path: str,
    errors: list[str],
) -> dict[str, object]:
    initial = expect_dict(errors, case.get("initial"), f"{path}.initial")
    expected = expect_dict(errors, case.get("expected"), f"{path}.expected")
    expected_hnzvc = expected.get("ccr_hnzvc")
    if expected_hnzvc == "preserve":
        expected_hnzvc = initial.get("ccr_hnzvc")

    trace = {
        "case_id": case.get("id"),
        "valid": True,
        "start_pc": initial.get("pc"),
        "pc": expected.get("pc"),
        "instruction_id": case.get("instruction"),
        "trap": expected.get("trap"),
        "ccr_hnzvc": expected_hnzvc,
        "gpr_write_count": 0,
        "mem_access_count": 0,
    }

    effects = instruction.get("effects") if isinstance(instruction, dict) else []
    expected_regs = expect_dict(errors, expected.get("regs", {}), f"{path}.expected.regs")
    if isinstance(effects, list) and any(effect in {"rd8", "rd16", "addr_update"} for effect in effects):
        if not 1 <= len(expected_regs) <= 2:
            fail(errors, f"{path}.expected.regs", "register write case must name one or two writebacks")
        else:
            trace["gpr_write_count"] = len(expected_regs)
            for reg_index, (name, value) in enumerate(expected_regs.items()):
                trace[f"gpr_write{reg_index}_name"] = name
                trace[f"gpr_write{reg_index}_value"] = value
    if isinstance(effects, list) and any(effect in {"mem_read", "mem_write"} for effect in effects):
        memory = expect_dict(errors, case.get("memory"), f"{path}.memory")
        raw_accesses = memory.get("accesses")
        if isinstance(raw_accesses, list):
            accesses = [access for access in raw_accesses if isinstance(access, dict)]
        else:
            access = expect_dict(errors, memory.get("access"), f"{path}.memory.access")
            accesses = [access]
        trace["mem_access_count"] = len(accesses)
        for access_index, access in enumerate(accesses):
            trace.update({
                f"mem{access_index}_kind": access.get("kind"),
                f"mem{access_index}_addr": access.get("addr"),
                f"mem{access_index}_wmask": access.get("wmask", "00"),
                f"mem{access_index}_wdata": access.get("wdata", "0x0000"),
                f"mem{access_index}_rdata": access.get("rdata", "0x0000"),
            })
    return trace


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
) -> dict[str, object]:
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
    if item.get("check_area") not in {"decode", "execute", "flags", "branch", "trap", "memory"}:
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

    initial_hnzvc = initial.get("ccr_hnzvc")
    if not isinstance(initial_hnzvc, str) or HNZVC_INITIAL_RE.fullmatch(initial_hnzvc) is None:
        fail(errors, f"{path}.initial.ccr_hnzvc", "bad HNZVC value")

    expected_hnzvc = expected.get("ccr_hnzvc")
    if (
        expected_hnzvc != "preserve"
        and (not isinstance(expected_hnzvc, str) or HNZVC_EXPECTED_RE.fullmatch(expected_hnzvc) is None)
    ):
        fail(errors, f"{path}.expected.ccr_hnzvc", "bad HNZVC value")

    if not isinstance(expected.get("trap"), bool):
        fail(errors, f"{path}.expected.trap", "expected bool")

    instruction = instructions.get(instruction_id) if isinstance(instruction_id, str) else None
    effects = instruction.get("effects") if isinstance(instruction, dict) else []
    if isinstance(effects, list) and any(effect in {"mem_read", "mem_write"} for effect in effects):
        validate_case_memory(item.get("memory"), f"{path}.memory", errors)
    elif "memory" in item:
        validate_case_memory(item.get("memory"), f"{path}.memory", errors)
    return build_trace_expectation(item, instruction, path, errors)


def validate_reject_case(
    case: object,
    index: int,
    ids: set[str],
    errors: list[str],
) -> None:
    path = f"reject_cases[{index}]"
    item = expect_dict(errors, case, path)
    case_id = item.get("id")
    if not isinstance(case_id, str) or ID_RE.fullmatch(case_id) is None:
        fail(errors, f"{path}.id", "bad canonical id")
    elif case_id in ids:
        fail(errors, f"{path}.id", "duplicate canonical id")
    else:
        ids.add(case_id)

    if item.get("status") != "rejected":
        fail(errors, f"{path}.status", "expected rejected")
    if item.get("check_area") != "trap":
        fail(errors, f"{path}.check_area", "expected trap")

    assembler = expect_list(errors, item.get("assembler"), f"{path}.assembler")
    if not assembler or not all(isinstance(line, str) and line for line in assembler):
        fail(errors, f"{path}.assembler", "empty assembler")

    words = expect_list(errors, item.get("words"), f"{path}.words")
    if not words:
        fail(errors, f"{path}.words", "empty words")
    for word_index, word in enumerate(words):
        validate_hex(word, WORD_RE, f"{path}.words[{word_index}]", errors)

    keys = expect_list(errors, item.get("decode_keys"), f"{path}.decode_keys")
    for key_index, key in enumerate(keys):
        if not isinstance(key, str) or NIBBLE_RE.fullmatch(key) is None:
            fail(errors, f"{path}.decode_keys[{key_index}]", "decode key must be one nibble")

    initial = expect_dict(errors, item.get("initial"), f"{path}.initial")
    expected = expect_dict(errors, item.get("expected"), f"{path}.expected")
    validate_hex(initial.get("pc"), WORD_RE, f"{path}.initial.pc", errors)
    validate_hex(expected.get("pc"), WORD_RE, f"{path}.expected.pc", errors)
    validate_regs(initial.get("regs", {}), f"{path}.initial.regs", errors)
    validate_regs(expected.get("regs", {}), f"{path}.expected.regs", errors)

    initial_hnzvc = initial.get("ccr_hnzvc")
    if not isinstance(initial_hnzvc, str) or HNZVC_INITIAL_RE.fullmatch(initial_hnzvc) is None:
        fail(errors, f"{path}.initial.ccr_hnzvc", "bad HNZVC value")

    expected_hnzvc = expected.get("ccr_hnzvc")
    if (
        expected_hnzvc != "preserve"
        and (not isinstance(expected_hnzvc, str) or HNZVC_EXPECTED_RE.fullmatch(expected_hnzvc) is None)
    ):
        fail(errors, f"{path}.expected.ccr_hnzvc", "bad HNZVC value")

    if expected.get("trap") is not True:
        fail(errors, f"{path}.expected.trap", "expected true")
    if "memory" in item:
        memory = expect_dict(errors, item.get("memory"), f"{path}.memory")
        validate_memory_map(memory.get("initial", {}), f"{path}.memory.initial", errors)
        validate_memory_map(memory.get("expected", {}), f"{path}.memory.expected", errors)


def validate_table(table: object, sail_text: str) -> tuple[list[str], dict[str, object]]:
    errors: list[str] = []
    root = expect_dict(errors, table, "root")
    if root.get("schema") != 1:
        fail(errors, "schema", "expected schema 1")
    profile = root.get("profile")
    if profile not in PROFILE_SAIL_ENUM:
        fail(errors, "profile", "unknown profile")
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
    retire_compare = expect_list(errors, root.get("retire_compare"), "retire_compare")
    if retire_compare != ["pc", "regs", "ccr_hnzvc", "trap", "memory"]:
        fail(errors, "retire_compare", "unexpected compare fields")
    trace_fields = validate_retire_trace_shape(root.get("retire_trace"), root, errors)

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
    validate_retire_trace_effects(instructions, trace_fields, errors)

    case_ids: set[str] = set()
    branch_coverage: dict[str, set[str]] = {}
    trace_expectations: list[dict[str, object]] = []
    cases = expect_list(errors, root.get("cases"), "cases")
    for index, case in enumerate(cases):
        if isinstance(case, dict):
            validate_branch_case(case, f"cases[{index}]", branch_coverage, errors)
        trace_expectations.append(validate_case(case, index, sail_text, case_ids, instructions, errors))
    if profile == "h8300_base":
        validate_branch_coverage(branch_coverage, errors)

    reject_cases = expect_list(errors, root.get("reject_cases", []), "reject_cases")
    if profile != "h8300_base" and reject_cases:
        fail(errors, "reject_cases", "only h8300_base may define reject cases")
    for index, case in enumerate(reject_cases):
        validate_reject_case(case, index, case_ids, errors)

    summary = {
        "case_count": len(cases),
        "decode_key_bits_max": root.get("decode_key_bits_max"),
        "fetch_word_bits": root.get("fetch_word_bits"),
        "instruction_count": len(instruction_rows),
        "profile": root.get("profile"),
        "retire_trace_case_count": len(trace_expectations),
        "retire_trace_field_count": len(trace_fields),
        "reject_case_count": len(reject_cases),
        "schema": root.get("schema"),
        "storage_word_bits": root.get("storage_word_bits"),
    }
    return errors, summary


def main() -> int:
    sail_text = SAIL_PATH.read_text(encoding="utf-8")
    errors: list[str] = []
    tables = []
    for case_path in CASE_PATHS:
        table = yaml.safe_load(case_path.read_text(encoding="utf-8"))
        table_errors, summary = validate_table(table, sail_text)
        errors.extend(f"{case_path.relative_to(REPO_ROOT)}: {error}" for error in table_errors)
        tables.append({
            "case_table": str(case_path.relative_to(REPO_ROOT)),
            "status": "fail" if table_errors else "pass",
            "summary": summary,
            "errors": table_errors,
        })
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    report = {
        "status": "fail" if errors else "pass",
        "table_count": len(tables),
        "tables": tables,
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
