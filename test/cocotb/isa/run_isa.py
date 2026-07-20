# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build base Core and run the batch ISA-case sim on Icarus.

    python test/cocotb/isa/run_isa.py build
    ISA_MANIFEST=... ISA_RESULTS=... python test/cocotb/isa/run_isa.py run

`build` regenerates the RTL and compiles it; `run` reuses that build and
executes every manifest case in one sim process. check_exec_sail.py drives the
run mode. Invoke inside `nix develop .#cocotb`.
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
BUILD_DIR = GENERATED / "cocotb_isa_build"


def rtl_sources():
    return sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )


def _runner(always):
    runner = get_runner("icarus")
    runner.build(
        sources=rtl_sources(),
        hdl_toplevel=TOPLEVEL,
        build_dir=BUILD_DIR,
        always=always,
        build_args=["-g2012"],
        timescale=("1ns", "1ps"),
    )
    return runner


def do_build():
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, check=True)
    assert (GENERATED / f"{TOPLEVEL}.sv").exists(), f"{TOPLEVEL}.sv not generated"
    _runner(always=True)


def do_run():
    for var in ("ISA_MANIFEST", "ISA_RESULTS"):
        assert os.environ.get(var), f"{var} not set"
    runner = _runner(always=False)
    extra_env = {"PYTHONPATH": os.pathsep.join(
        [str(HERE), os.environ.get("PYTHONPATH", "")]
    )}
    for var in ("ISA_MANIFEST", "ISA_RESULTS"):
        extra_env[var] = os.environ[var]
    results = runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module="test_isa",
        timescale=("1ns", "1ps"),
        results_xml="test_isa.results.xml",
        extra_env=extra_env,
    )
    # The sim exits 0 even when tests fail; gate on the recorded results.
    num_tests, num_failed = get_results(results)
    if num_failed or not num_tests:
        raise SystemExit(f"isa batch: {num_failed}/{num_tests} tests failed")


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "run"
    if mode == "build":
        do_build()
    elif mode == "run":
        do_run()
    else:
        raise SystemExit(f"usage: run_isa.py [build|run] (got {mode!r})")


if __name__ == "__main__":
    main()
