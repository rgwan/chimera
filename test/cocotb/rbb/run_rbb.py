# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build and run the remote-bitbang CoreTop sim for the gdb end-to-end gate.

Split into two modes so the socket opens quickly when the host tool attaches:

    python test/cocotb/rbb/run_rbb.py build   # elaborate + Verilator compile
    RBB_PORT=2542 python test/cocotb/rbb/run_rbb.py run   # start the server

`build` regenerates CoreTop (DM + hardware breakpoints) and compiles it. `run`
reuses that build (Verilator make is a no-op if current) and runs the cocotb
remote-bitbang server, which listens on RBB_PORT. Invoke inside
`nix develop .#cocotb`. scripts/run_gdb_e2e.sh orchestrates the attach.
"""

import os
import subprocess
import sys
from pathlib import Path

from cocotb_tools.runner import get_runner

REPO = Path(__file__).resolve().parents[3]
GENERATED = REPO / "rtl" / "generated"
HERE = Path(__file__).resolve().parent
TOPLEVEL = "CoreTop"
BUILD_DIR = GENERATED / "cocotb_rbb_build"

BUILD_ENV = {
    "DM": "true",
    "HW_BREAKPOINT": "true",
    "HW_BREAKPOINT_COUNT": "2",
    "DBG_BASE": "65280",
}

BUILD_ARGS = [
    "--timing",
    "-CFLAGS", "-std=c++20 -fcoroutines",
    "-Wno-WIDTH",
    "-Wno-SELRANGE",
    "-Wno-BLKANDNBLK",
    "-Wno-MINTYPMAXDLY",
    "-Wno-CASEINCOMPLETE",
    "-Wno-UNOPTFLAT",
    "--bbox-unsup",
]


def rtl_sources():
    return sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )


def _runner(always):
    runner = get_runner("verilator")
    runner.build(
        sources=rtl_sources(),
        hdl_toplevel=TOPLEVEL,
        build_dir=BUILD_DIR,
        always=always,
        build_args=BUILD_ARGS,
    )
    return runner


def do_build():
    env = dict(os.environ, TOP=TOPLEVEL, **BUILD_ENV)
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, env=env, check=True)
    assert (GENERATED / f"{TOPLEVEL}.sv").exists(), f"{TOPLEVEL}.sv not generated"
    _runner(always=True)


def do_run():
    runner = _runner(always=False)
    extra_env = {"PYTHONPATH": os.pathsep.join(
        [str(HERE), os.environ.get("PYTHONPATH", "")]
    )}
    runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module="test_rbb",
        timescale=("1ns", "1ps"),
        results_xml="test_rbb.results.xml",
        extra_env=extra_env,
    )


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "build"
    if mode == "build":
        do_build()
    elif mode == "run":
        do_run()
    else:
        raise SystemExit(f"usage: run_rbb.py [build|run] (got {mode!r})")


if __name__ == "__main__":
    main()
