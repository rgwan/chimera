#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import subprocess
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
SAIL_PROJECT = REPO_ROOT / "sail" / "h8300.sail_project"
OUT_DIR = REPO_ROOT / "result" / "sail"


def run(cmd: list[str], log_path: Path, stdin: str | None = None) -> dict[str, object]:
    with log_path.open("w", encoding="utf-8") as log_file:
        completed = subprocess.run(
            cmd,
            cwd=REPO_ROOT,
            input=stdin,
            text=True,
            stdout=log_file,
            stderr=subprocess.STDOUT,
            check=False,
        )
    return {
        "command": cmd,
        "returncode": completed.returncode,
        "status": "pass" if completed.returncode == 0 else "fail",
        "log": str(log_path.relative_to(REPO_ROOT)),
    }


def main() -> int:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    steps = [
        run(
            ["sail", "--project", str(SAIL_PROJECT), "--all-modules", "--just-check"],
            OUT_DIR / "typecheck.log",
        ),
        run(
            ["sail", "--project", str(SAIL_PROJECT), "--all-modules", "--list-files"],
            OUT_DIR / "list-files.log",
        ),
        run(
            ["sail", "--no-color", "--project", str(SAIL_PROJECT), "--all-modules", "-i"],
            OUT_DIR / "selftest.log",
            "h8_selftest()\n:run\n",
        ),
    ]
    selftest_log = (OUT_DIR / "selftest.log").read_text(encoding="utf-8")
    if "Result = true" not in selftest_log:
        steps[-1]["status"] = "fail"
    status = "pass" if all(step["status"] == "pass" for step in steps) else "fail"
    report = {
        "model": "h8300",
        "status": status,
        "steps": steps,
    }
    report_path = OUT_DIR / "sail-model.json"
    report_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"sail model {status}: {report_path.relative_to(REPO_ROOT)}")
    if status != "pass":
        for step in steps:
            if step["status"] != "pass":
                print(f"--- {step['log']} ---")
                log_text = (REPO_ROOT / str(step["log"])).read_text(encoding="utf-8")
                print(log_text[-4000:], end="" if log_text.endswith("\n") else "\n")
    return 0 if status == "pass" else 1


if __name__ == "__main__":
    raise SystemExit(main())
