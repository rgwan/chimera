# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build base Core and run the execution-equivalence cases on Icarus.

Icarus exposes the internal register-file and CCR taps the cases read, which
Verilator does not surface by default. Invoke from the repo root inside
`nix develop .#cocotb`:

    python test/cocotb/exec/run_exec.py
"""

import os
import subprocess
from pathlib import Path

from cocotb_tools.runner import get_runner

REPO = Path(__file__).resolve().parents[3]
GENERATED = REPO / "rtl" / "generated"
HERE = Path(__file__).resolve().parent
TOPLEVEL = "Core"


def rtl_sources():
    return sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )


def main():
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, check=True)
    sources = rtl_sources()
    assert (GENERATED / f"{TOPLEVEL}.sv") in sources, f"{TOPLEVEL}.sv not generated"

    runner = get_runner("icarus")
    runner.build(
        sources=sources,
        hdl_toplevel=TOPLEVEL,
        build_dir=GENERATED / "cocotb_exec_build",
        always=True,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    extra_env = {"PYTHONPATH": os.pathsep.join(
        [str(HERE), os.environ.get("PYTHONPATH", "")]
    )}
    runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module="test_exec",
        timescale=("1ns", "1ps"),
        results_xml="test_exec.results.xml",
        extra_env=extra_env,
    )


if __name__ == "__main__":
    main()
