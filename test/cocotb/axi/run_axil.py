# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build CoreTopAxi and run the AXI-Lite bridge cocotb test on Verilator.

Uses the cocotb 2.0 runner API. The top is the canonical-name wrapper
`coretop_axil` (test/cocotb/wrappers/coretop_axil.sv), which renames the
firtool-flat axil_* ports to m_axil_* so AxiLiteBus.from_prefix binds. Invoke
from the repo root inside `nix develop .#cocotb`:

    python test/cocotb/axi/run_axil.py
"""

import os
import subprocess
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

REPO = Path(__file__).resolve().parents[3]
GENERATED = REPO / "rtl" / "generated"
WRAPPER = REPO / "test" / "cocotb" / "wrappers" / "coretop_axil.sv"
TOPLEVEL = "coretop_axil"


def build_rtl():
    env = dict(os.environ, AXIL="true", TOP="CoreTopAxi")
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, env=env, check=True)


def rtl_sources():
    gen = sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )
    return [WRAPPER, *gen]


def main():
    build_rtl()
    sources = rtl_sources()
    assert (GENERATED / "CoreTopAxi.sv") in sources, "CoreTopAxi.sv not generated"

    runner = get_runner("verilator")
    runner.build(
        sources=sources,
        hdl_toplevel=TOPLEVEL,
        build_dir=GENERATED / "cocotb_axi_build",
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
    results = runner.test(
        hdl_toplevel=TOPLEVEL,
        test_module="test_axil",
        timescale=("1ns", "1ps"),
        extra_env={"PYTHONPATH": os.pathsep.join([
            str(Path(__file__).resolve().parent),
            str(REPO / "test"),
            os.environ.get("PYTHONPATH", ""),
        ])},
    )
    # The sim exits 0 even when tests fail; gate on recorded results.
    num_tests, num_failed = get_results(results)
    if num_failed or not num_tests:
        raise SystemExit(f"axi: {num_failed}/{num_tests} tests failed")


if __name__ == "__main__":
    main()
