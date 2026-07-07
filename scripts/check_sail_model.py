#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

import json
import subprocess
import tempfile
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


def run_c_backend(log_path: Path) -> dict[str, object]:
    with tempfile.TemporaryDirectory(prefix="c-backend-", dir=OUT_DIR) as tmp_name:
        tmp = Path(tmp_name)
        (tmp / "prelude.sail").symlink_to(REPO_ROOT / "sail" / "prelude.sail")
        (tmp / "h8300.sail").symlink_to(REPO_ROOT / "sail" / "h8300.sail")
        (tmp / "main.sail").write_text(
            'function main() : unit -> unit = {\n'
            '  assert(h8_selftest(), "h8_selftest")\n'
            '}\n',
            encoding="utf-8",
        )
        (tmp / "h8300_c.sail_project").write_text(
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
            "main {\n"
            "  requires h8300\n"
            "  files\n"
            "    main.sail\n"
            "}\n",
            encoding="utf-8",
        )
        cmd = [
            "sail",
            "--no-color",
            "--project",
            str(tmp / "h8300_c.sail_project"),
            "--all-modules",
            "-c",
            "--c-build",
            "--c-no-mangle",
            "-o",
            str(tmp / "h8300_c"),
        ]
        build = run(cmd, log_path)
        exe = tmp / "h8300_c"
        if build["returncode"] != 0 or not exe.is_file():
            build["status"] = "fail"
            return build
        with log_path.open("a", encoding="utf-8") as log_file:
            completed = subprocess.run(
                [str(exe)],
                cwd=tmp,
                text=True,
                stdout=log_file,
                stderr=subprocess.STDOUT,
                check=False,
            )
        build["run_returncode"] = completed.returncode
        build["status"] = "pass" if completed.returncode == 0 else "fail"
        return build


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
        run_c_backend(OUT_DIR / "c-backend.log"),
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
