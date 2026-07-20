# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Debugger-present hardware breakpoint on Core, driven through the DM port.

Mirrors test/core/tb_core_hwbp_dm.v: the comparator is programmed through DM
memWrite (same MMIO decode as a core access); reaching the armed address parks
the core in DebugEntry (is_halted rises) and a DM resume clears it. A concurrent
DM haltreq and HWBP fire resolve to a single park.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from dmutil import CMD_HALT, CMD_MEMWR, dm_cmd, dm_init, dm_resume

HWBP0_ADDR = 0xFF08
HWBP0_CTL = 0xFF0A
BP_TARGET = 0x0050


async def wait_halted(dut, guard=400):
    n = 0
    while not int(dut.is_halted.value) and n < guard:
        await RisingEdge(dut.clock)
        n += 1
    return int(dut.is_halted.value)


@cocotb.test()
async def dm_hwbp(dut):
    ram = await dm_init(dut)
    # A marker instruction (mov.w #0x1234,R4) sits at the breakpoint address.
    ram.mem[BP_TARGET + 0] = 0x79
    ram.mem[BP_TARGET + 1] = 0x04
    ram.mem[BP_TARGET + 2] = 0x12
    ram.mem[BP_TARGET + 3] = 0x34

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 30)
    assert not int(dut.is_halted.value), "running before attach"

    # Attach, halt, program the comparator through DM memWrite.
    dut.dbg_dmactive.value = 1
    await ClockCycles(dut.clock, 3)
    await dm_cmd(dut, CMD_HALT)
    assert int(dut.is_halted.value), "DM halt did not park the core"
    await dm_cmd(dut, CMD_MEMWR, HWBP0_ADDR, BP_TARGET)
    await dm_cmd(dut, CMD_MEMWR, HWBP0_CTL, 0x0001)  # EN, instruction match

    # Resume; the core runs to the armed address and the breakpoint re-parks it.
    await dm_resume(dut)
    assert await wait_halted(dut), "HWBP fire did not park the core"
    assert int(dut.dbg_halted.value), "DM did not see the HWBP park"

    # Park is held with no new DM command.
    await ClockCycles(dut.clock, 20)
    assert int(dut.is_halted.value), "park not held"

    # Disable the breakpoint, resume: the core runs free.
    await dm_cmd(dut, CMD_MEMWR, HWBP0_CTL, 0x0000)
    await dm_resume(dut)
    await ClockCycles(dut.clock, 10)
    assert not int(dut.is_halted.value), "DM resume did not clear the park"

    # Concurrent DM haltreq + HWBP fire converge on one park a single resume clears.
    await dm_cmd(dut, CMD_HALT)
    await dm_cmd(dut, CMD_MEMWR, HWBP0_ADDR, BP_TARGET)
    await dm_cmd(dut, CMD_MEMWR, HWBP0_CTL, 0x0001)
    # Release the park, then immediately re-request halt with a fresh req edge.
    await dm_resume(dut)
    dut.dbg_cmd.value = CMD_HALT
    dut.dbg_req.value = 1
    assert await wait_halted(dut), "concurrent haltreq + HWBP: no single park"
    dut.dbg_req.value = 0
    await ClockCycles(dut.clock, 3)
    assert int(dut.is_halted.value), "converged park not stable"
    await dm_cmd(dut, CMD_MEMWR, HWBP0_CTL, 0x0000)
    await dm_resume(dut)
    await ClockCycles(dut.clock, 10)
    assert not int(dut.is_halted.value), "single resume did not clear converged park"

    dut._log.info("DM-HWBP PASS: DM-programmed bp parks in DebugEntry, resume clears")
