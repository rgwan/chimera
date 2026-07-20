# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build Core with the debug module and run the DM cocotb tests on Verilator.

Each test needs a different RTL config, so the runner builds Core per selector,
then runs the matching test module against the Core toplevel. Invoke from the
repo root inside `nix develop .#cocotb`:

    python test/cocotb/debug/run_dm.py [debug|hwbp|step]

With no argument all three run.
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
    "debug": {"env": {"DM": "true"}, "test": "test_dm_debug"},
    "hwbp": {
        "env": {
            "DM": "true",
            "HW_BREAKPOINT": "true",
            "HW_BREAKPOINT_COUNT": "2",
            "DBG_BASE": "65280",
        },
        "test": "test_dm_hwbp",
    },
    "step": {
        "env": {"DM": "true", "SINGLE_STEP": "true", "DBG_BASE": "65280"},
        "test": "test_dm_step",
    },
}


def rtl_sources():
    return sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )


def run_one(name):
    cfg = CONFIGS[name]
    env = dict(os.environ, TOP=TOPLEVEL, **cfg["env"])
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, env=env, check=True)
    sources = rtl_sources()
    assert (GENERATED / f"{TOPLEVEL}.sv") in sources, f"{TOPLEVEL}.sv not generated"

    runner = get_runner("verilator")
    runner.build(
        sources=sources,
        hdl_toplevel=TOPLEVEL,
        build_dir=GENERATED / f"cocotb_dm_{name}_build",
        always=True,
        build_args=[
            "--timing",
            "-CFLAGS", "-std=c++20 -fcoroutines",
            "-Wno-WIDTH",
            "-Wno-SELRANGE",
            "-Wno-BLKANDNBLK",
            "-Wno-MINTYPMAXDLY",
            "-Wno-CASEINCOMPLETE",
            "-Wno-UNOPTFLAT",
            "--bbox-unsup",
        ],
    )
    extra_env = {"PYTHONPATH": os.pathsep.join(
        [str(HERE), os.environ.get("PYTHONPATH", "")]
    )}
    runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module=cfg["test"],
        timescale=("1ns", "1ps"),
        results_xml=f"{cfg['test']}.results.xml",
        extra_env=extra_env,
    )


def main():
    which = sys.argv[1:] or list(CONFIGS)
    for name in which:
        run_one(name)


if __name__ == "__main__":
    main()
