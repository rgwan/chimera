# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Build CoreTop (DM=true) and run the JTAG cocotb tests on Verilator.

Builds CoreTop once, runs the IDCODE smoke and the full DTM test (halt, status,
memWrite/memRead, setPC/readPC, resume). Uses the cocotb 2.0 runner API
(cocotb_tools.runner), not the legacy Makefile flow. Invoke from the repo root
inside `nix develop .#cocotb`:

    python test/cocotb/jtag/run_idcode.py
"""

import os
import subprocess
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

REPO = Path(__file__).resolve().parents[3]
GENERATED = REPO / "rtl" / "generated"
TOPLEVEL = "CoreTop"


def build_rtl():
    env = dict(os.environ, DM="true")
    subprocess.run(["bash", "rtl/build.sh"], cwd=REPO, env=env, check=True)


def rtl_sources():
    # Mirror the Makefile glob: every generated .sv except the DV layer-bind and
    # reference collateral, which need SV bind support unrelated to CoreTop.
    return sorted(
        p for p in GENERATED.glob("*.sv")
        if "layers-" not in p.name and not p.name.startswith("ref_")
    )


def main():
    build_rtl()
    sources = rtl_sources()
    assert (GENERATED / f"{TOPLEVEL}.sv") in sources, f"{TOPLEVEL}.sv not generated"

    runner = get_runner("verilator")
    runner.build(
        sources=sources,
        hdl_toplevel=TOPLEVEL,
        build_dir=REPO / "rtl" / "generated" / "cocotb_jtag_build",
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
        [str(Path(__file__).resolve().parent), os.environ.get("PYTHONPATH", "")]
    )}
    for test_module in ("test_idcode", "test_jtag_dtm"):
        results = runner.test(
            hdl_toplevel=TOPLEVEL,
            test_module=test_module,
            timescale=("1ns", "1ps"),
            results_xml=f"{test_module}.results.xml",
            extra_env=extra_env,
        )
        # The sim exits 0 even when tests fail; gate on recorded results.
        num_tests, num_failed = get_results(results)
        if num_failed or not num_tests:
            raise SystemExit(f"jtag: {num_failed}/{num_tests} tests failed")


if __name__ == "__main__":
    main()
