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

from cocotb_tools.runner import get_results, get_runner

REPO = Path(__file__).resolve().parents[3]
GENERATED = REPO / "rtl" / "generated"
HERE = Path(__file__).resolve().parent
TOPLEVEL = "Core"

CONFIGS = {
    "base": {"env": {}, "modules": [
        "test_exec", "test_exec_flow", "test_exec_mem",
        "test_exec_irq", "test_exec_sleep",
    ]},
    "strict": {"env": {"STRICT_DECODE": "true"}, "modules": [
        "test_exec_strict", "test_exec_trapa", "test_exec_sleep",
    ]},
    "ubit": {"env": {"CCR_UBIT": "true"}, "modules": ["test_exec_ubit"]},
    "hwbp_self": {"env": {
        "HW_BREAKPOINT": "true", "HW_BREAKPOINT_COUNT": "2", "DBG_BASE": "65280",
    }, "modules": ["test_exec_hwbp_self"]},
    "step_self": {"env": {"SINGLE_STEP": "true", "DBG_BASE": "65280"},
                  "modules": ["test_exec_step_self"]},
    "trap2": {"env": {
        "SINGLE_STEP": "true", "HW_BREAKPOINT": "true",
        "HW_BREAKPOINT_COUNT": "2", "DBG_BASE": "65280",
    }, "modules": ["test_exec_trap2"]},
    # ROM_HEX swaps in the $readmemh microcode ROM; its image path is relative
    # to the sim cwd, so the test runs from rtl/generated.
    "romhex": {"env": {"ROM_HEX": "true"}, "modules": ["test_exec_sleep"],
               "test_dir": "generated"},
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
    test_dir = GENERATED if cfg.get("test_dir") else None
    for module in cfg["modules"]:
        results = runner.test(
            hdl_toplevel=TOPLEVEL,
            test_module=module,
            timescale=("1ns", "1ps"),
            results_xml=f"{name}_{module}.results.xml",
            extra_env=extra_env,
            test_dir=test_dir,
        )
        # The sim exits 0 even when tests fail; gate on the recorded results.
        num_tests, num_failed = get_results(results)
        if num_failed or not num_tests:
            raise SystemExit(f"{name}/{module}: {num_failed}/{num_tests} tests failed")


def main():
    for name in sys.argv[1:] or list(CONFIGS):
        run_config(name)


if __name__ == "__main__":
    main()
