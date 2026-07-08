#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import yaml

import check_isa_cases


REPO_ROOT = Path(__file__).resolve().parents[1]
CASE_PATH = REPO_ROOT / "isa" / "h8300_base_cases.yaml"
OUT_DIR = REPO_ROOT / "result" / "gnu-oracle"
SAIL_RESULT_RE = re.compile(r"Result = (true|false)")


def run(
    cmd: list[str],
    log_path: Path,
    cwd: Path,
    stdin: str | None = None,
) -> dict[str, object]:
    with log_path.open("w", encoding="utf-8") as log_file:
        completed = subprocess.run(
            cmd,
            cwd=cwd,
            input=stdin,
            text=True,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            check=False,
        )
    return {
        "command": cmd,
        "log": str(log_path.relative_to(REPO_ROOT)),
        "returncode": completed.returncode,
        "status": "pass" if completed.returncode == 0 else "fail",
    }


def expected_hex(case: dict[str, object]) -> str:
    words = case["words"]
    return "".join(str(word)[2:].lower() for word in words)


def program_bytes(case: dict[str, object]) -> list[int]:
    bytes_out = []
    for word in case["words"]:
        value = int(str(word), 16)
        bytes_out.extend([(value >> 8) & 0xFF, value & 0xFF])
    return bytes_out


def asm_text(case: dict[str, object]) -> str:
    lines = [
        ".text",
        ".global _start",
        "_start:",
    ]
    for line in case["assembler"]:
        text = str(line)
        if text.endswith(":") or text.startswith(" "):
            lines.append(text)
        else:
            lines.append(f"  {text}")
    return "\n".join(lines) + "\n"


def assemble_case(case: dict[str, object], work_root: Path) -> dict[str, object]:
    case_id = str(case["id"])
    work = work_root / case_id
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / "case.s").write_text(asm_text(case), encoding="utf-8")

    steps = [
        run(["h8300-elf-as", "-o", "case.o", "case.s"], work / "as.log", work),
        run(["h8300-elf-ld", "-Ttext=0", "-e", "_start", "-o", "case.elf", "case.o"], work / "ld.log", work),
        run(["h8300-elf-objdump", "-f", "case.elf"], work / "objdump-file.log", work),
        run(["h8300-elf-objdump", "-d", "case.elf"], work / "objdump-disasm.log", work),
        run(["h8300-elf-objcopy", "-O", "binary", "-j", ".text", "case.elf", "case.bin"], work / "objcopy.log", work),
    ]

    actual = ""
    bin_path = work / "case.bin"
    if bin_path.is_file():
        actual = bin_path.read_bytes().hex()
    want = expected_hex(case)
    status = "pass" if all(step["status"] == "pass" for step in steps) and actual == want else "fail"
    return {
        "actual_hex": actual,
        "expected_hex": want,
        "logs": {Path(str(step["log"])).name: step["log"] for step in steps},
        "status": status,
        "steps": steps,
    }


def sail_ccr_expr(hnzvc: str) -> str:
    return (
        "struct {"
        "i = 0b1, "
        "u6 = 0b0, "
        f"h = 0b{hnzvc[0]}, "
        "u4 = 0b0, "
        f"n = 0b{hnzvc[1]}, "
        f"z = 0b{hnzvc[2]}, "
        f"v = 0b{hnzvc[3]}, "
        f"c = 0b{hnzvc[4]}"
        "}"
    )


def sail_reg_ref(name: str) -> str:
    if len(name) == 2:
        index = int(name[1])
        return str(index + 8 if name[0] == "e" else index)
    reg = name[1]
    high = "true" if name[2] == "h" else "false"
    return f"struct {{reg = {reg}, high = {high}}}"


def apply_reg(regs: list[int], name: str, value: str) -> None:
    val = int(value, 16)
    index = int(name[1])
    if name[0] == "e":
        index += 8
    if len(name) == 2:
        regs[index] = val & 0xFFFF
    elif name[2] == "h":
        regs[index] = ((val & 0xFF) << 8) | (regs[index] & 0x00FF)
    else:
        regs[index] = (regs[index] & 0xFF00) | (val & 0xFF)


def expected_regs(case: dict[str, object]) -> list[int]:
    regs = [0] * 16
    for name, value in dict(case["initial"].get("regs", {})).items():
        apply_reg(regs, name, value)
    for name, value in dict(case["expected"].get("regs", {})).items():
        apply_reg(regs, name, value)
    return regs


def memory_map(case: dict[str, object], field: str) -> dict[str, str]:
    memory = case.get("memory", {})
    if not isinstance(memory, dict):
        return {}
    values = memory.get(field, {})
    return dict(values) if isinstance(values, dict) else {}


def sorted_memory_items(values: dict[str, str]) -> list[tuple[str, str]]:
    return sorted(values.items(), key=lambda item: int(item[0], 16))


def set_reg_expr(state_name: str, name: str, value: str) -> str:
    if len(name) == 2:
        return f"write_r16({state_name}, {sail_reg_ref(name)}, {value})"
    return f"write_r8({state_name}, {sail_reg_ref(name)}, {value})"


def combine_bool_expr(checks: list[str]) -> str:
    expr = "true"
    for check in reversed(checks):
        expr = f"if {check} then {expr} else false"
    return expr


def sail_ccr_checks(hnzvc: str) -> list[str]:
    fields = ("h", "n", "z", "v", "c")
    return [
        f"(res.st.ccr.{field} == 0b{value})"
        for field, value in zip(fields, hnzvc)
        if value != "x"
    ]


def sail_case_body(case: dict[str, object]) -> str:
    initial = case["initial"]
    expected = case["expected"]
    byte_literal = ", ".join(f"0x{value:02X}" for value in program_bytes(case))
    initial_hnzvc = str(initial["ccr_hnzvc"])
    expected_hnzvc = str(expected["ccr_hnzvc"])
    if expected_hnzvc == "preserve":
        expected_hnzvc = initial_hnzvc

    lines = [
        "{",
        "  let reset = h8_reset();",
        f"  let st0 = {{reset with pc = {initial['pc']}, ccr = {sail_ccr_expr(initial_hnzvc)}}};",
    ]
    state_name = "st0"
    for index, (name, value) in enumerate(dict(initial.get("regs", {})).items(), start=1):
        next_name = f"st{index}"
        lines.append(f"  let {next_name} = {set_reg_expr(state_name, name, value)};")
        state_name = next_name
    lines.append(f"  let mem0 = h8_load_bytes(h8_empty_mem(), {initial['pc']}, [{byte_literal}]);")
    mem_name = "mem0"
    for index, (addr, value) in enumerate(sorted_memory_items(memory_map(case, "initial")), start=1):
        next_name = f"mem{index}"
        lines.append(f"  let {next_name} = h8_mem_write8({mem_name}, {addr}, {value});")
        mem_name = next_name
    lines.append(f"  let mach1 = h8_make_machine({state_name}, {mem_name});")
    lines.append("  let res = h8_run(mach1, 1);")
    checks = [
        f"(res.st.pc == {expected['pc']})",
        "(res.trap)" if expected["trap"] else "(not_bool(res.trap))",
    ]
    checks.extend(sail_ccr_checks(expected_hnzvc))
    for index, value in enumerate(expected_regs(case)):
        checks.append(f"(read_r16(res.st, {index}) == 0x{value:04X})")
    for addr, value in sorted_memory_items(memory_map(case, "expected")):
        checks.append(f"(h8_mem_read8(res.mem, {addr}) == {value})")
    lines.append(f"  {combine_bool_expr(checks)}")
    lines.append("}")
    return "\n".join(lines)


def write_sail_case_project(case: dict[str, object], work: Path) -> None:
    (work / "prelude.sail").symlink_to(REPO_ROOT / "sail" / "prelude.sail")
    (work / "h8300.sail").symlink_to(REPO_ROOT / "sail" / "h8300.sail")
    (work / "oracle_case.sail").write_text(
        f"function gnu_oracle_case() -> bool = {sail_case_body(case)}\n",
        encoding="utf-8",
    )
    (work / "oracle_case.sail_project").write_text(
        "prelude {\n"
        "  files\n"
        "    prelude.sail\n"
        "}\n"
        "\n"
        "h8300 {\n"
        "  requires prelude\n"
        "  files\n"
        "    h8300.sail\n"
        "}\n"
        "\n"
        "oracle {\n"
        "  requires prelude\n"
        "  requires h8300\n"
        "  files\n"
        "    oracle_case.sail\n"
        "}\n",
        encoding="utf-8",
    )


def sail_function_name(case: dict[str, object]) -> str:
    return f"gnu_oracle_case_{case['id']}"


def write_sail_cases_project(cases: list[dict[str, object]], work: Path) -> None:
    shutil.rmtree(work, ignore_errors=True)
    work.mkdir(parents=True)
    (work / "prelude.sail").symlink_to(REPO_ROOT / "sail" / "prelude.sail")
    (work / "h8300.sail").symlink_to(REPO_ROOT / "sail" / "h8300.sail")
    bodies = []
    for case in cases:
        bodies.append(f"function {sail_function_name(case)}() -> bool = {sail_case_body(case)}\n")
    (work / "oracle_cases.sail").write_text("\n".join(bodies), encoding="utf-8")
    (work / "oracle_cases.sail_project").write_text(
        "prelude {\n"
        "  files\n"
        "    prelude.sail\n"
        "}\n"
        "\n"
        "h8300 {\n"
        "  requires prelude\n"
        "  files\n"
        "    h8300.sail\n"
        "}\n"
        "\n"
        "oracle {\n"
        "  requires prelude\n"
        "  requires h8300\n"
        "  files\n"
        "    oracle_cases.sail\n"
        "}\n",
        encoding="utf-8",
    )


def run_sail_cases(cases: list[dict[str, object]], log_path: Path) -> dict[str, dict[str, object]]:
    work = log_path.parent
    write_sail_cases_project(cases, work)
    cmd = [
        "sail",
        "--no-color",
        "--project",
        "oracle_cases.sail_project",
        "--all-modules",
        "-i",
    ]
    stdin = "".join(f"{sail_function_name(case)}()\n:run\n" for case in cases)
    result = run(cmd, log_path, work, stdin)
    log_text = log_path.read_text(encoding="utf-8")
    values = SAIL_RESULT_RE.findall(log_text)
    output: dict[str, dict[str, object]] = {}
    for index, case in enumerate(cases):
        status = "fail"
        if result["status"] == "pass" and index < len(values) and values[index] == "true":
            status = "pass"
        output[str(case["id"])] = {
            "log": result["log"],
            "status": status,
        }
    return output


def run_sail_case(case: dict[str, object], log_path: Path) -> dict[str, object]:
    work = log_path.parent
    write_sail_case_project(case, work)
    cmd = [
        "sail",
        "--no-color",
        "--project",
        "oracle_case.sail_project",
        "--all-modules",
        "-i",
    ]
    result = run(cmd, log_path, work, "gnu_oracle_case()\n:run\n")
    log_text = log_path.read_text(encoding="utf-8")
    if "Result = true" not in log_text:
        result["status"] = "fail"
    return result


def load_table() -> dict[str, object]:
    table = yaml.safe_load(CASE_PATH.read_text(encoding="utf-8"))
    sail_text = (REPO_ROOT / "sail" / "h8300.sail").read_text(encoding="utf-8")
    errors, _summary = check_isa_cases.validate_table(table, sail_text)
    if errors:
        raise ValueError("\n".join(errors))
    return table


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    work_root = OUT_DIR / "work"
    work_root.mkdir(parents=True, exist_ok=True)
    table = load_table()
    cases = table["cases"]

    results = []
    sail_results = run_sail_cases(cases, work_root / "sail-all" / "sail.log")
    for case in cases:
        gnu = assemble_case(case, work_root)
        sail = sail_results[str(case["id"])]
        status = "pass" if gnu["status"] == "pass" and sail["status"] == "pass" else "fail"
        results.append({
            "actual_hex": gnu["actual_hex"],
            "case_id": case["id"],
            "expected_hex": gnu["expected_hex"],
            "gnu_status": gnu["status"],
            "instruction": case["instruction"],
            "sail_log": sail["log"],
            "sail_status": sail["status"],
            "status": status,
        })

    status = "pass" if all(result["status"] == "pass" for result in results) else "fail"
    report = {
        "case_count": len(results),
        "case_table": str(CASE_PATH.relative_to(REPO_ROOT)),
        "cases": results,
        "status": status,
    }
    report_path = OUT_DIR / "gnu-oracle.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"gnu oracle {status}: {report_path.relative_to(REPO_ROOT)}")
    if status != "pass":
        for result in results:
            if result["status"] != "pass":
                print(f"{result['case_id']}: gnu={result['gnu_status']} sail={result['sail_status']}")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    sys.exit(main())
