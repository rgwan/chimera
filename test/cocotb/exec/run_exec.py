# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build Core per config and run the execution cases on Icarus.

Icarus exposes the internal register-file and CCR taps the cases read, which
Verilator does not surface by default. Each config selects a build env and the
test modules that need it. Invoke from the repo root inside
`nix develop .#cocotb`:

    python test/cocotb/exec/run_exec.py [base|strict|ubit ...]

With no argument all configs run.
"""

import os
import subprocess
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

REPO = Path(__file__).resolve().parents[3]
GENERATED = REPO / "rtl" / "generated"
HERE = Path(__file__).resolve().parent
TOPLEVEL = "Core"

CONFIGS = {
    "base": {"env": {}, "modules": ["test_exec"]},
    "strict": {"env": {"STRICT_DECODE": "true"}, "modules": ["test_exec_strict"]},
    "ubit": {"env": {"CCR_UBIT": "true"}, "modules": ["test_exec_ubit"]},
}


def rtl_sources():
    return sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )


def run_config(name):
    cfg = CONFIGS[name]
    env = dict(os.environ, **cfg["env"])
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, env=env, check=True)
    sources = rtl_sources()
    assert (GENERATED / f"{TOPLEVEL}.sv") in sources, f"{TOPLEVEL}.sv not generated"

    runner = get_runner("icarus")
    runner.build(
        sources=sources,
        hdl_toplevel=TOPLEVEL,
        build_dir=GENERATED / f"cocotb_exec_{name}_build",
        always=True,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    extra_env = {"PYTHONPATH": os.pathsep.join(
        [str(HERE), os.environ.get("PYTHONPATH", "")]
    )}
    for module in cfg["modules"]:
        runner.test(
            hdl_toplevel=TOPLEVEL,
            test_module=module,
            timescale=("1ns", "1ps"),
            results_xml=f"{module}.results.xml",
            extra_env=extra_env,
        )


def main():
    for name in sys.argv[1:] or list(CONFIGS):
        run_config(name)


if __name__ == "__main__":
    main()
