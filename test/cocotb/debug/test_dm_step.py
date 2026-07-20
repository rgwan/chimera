# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Debugger-present single-step on Core, driven through the DM port.

Mirrors test/core/tb_core_step_dm.v: the debugger arms the STEP control word
(dbgBase word 0) through DM memWrite, then resumes. With a debugger present a
step fire parks the core in DebugEntry (is_halted rises) instead of trapping;
exactly one instruction retires per resume and the PC read back advances by one.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from dmutil import CMD_HALT, CMD_MEMWR, CMD_READPC, CMD_SETPC, dm_cmd, dm_init

STEP_CTL = 0xFF00


async def step_once(dut, guard=400):
    """Resume for one step; the STEP fire re-parks the core."""
    dut.dbg_cmd.value = 4  # RESUME
    dut.dbg_req.value = 1
    n = 0
    while int(dut.dbg_halted.value) and n < 300:
        await RisingEdge(dut.clock)
        n += 1
    dut.dbg_req.value = 0
    n = 0
    while not int(dut.is_halted.value) and n < guard:
        await RisingEdge(dut.clock)
        n += 1
    await ClockCycles(dut.clock, 2)
    return int(dut.is_halted.value)


@cocotb.test()
async def dm_step(dut):
    await dm_init(dut)  # all-NOP memory: each NOP is one word, PC += 2
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 30)
    assert not int(dut.is_halted.value), "running before attach"

    # Attach and halt.
    dut.dbg_dmactive.value = 1
    await ClockCycles(dut.clock, 3)
    await dm_cmd(dut, CMD_HALT)
    assert int(dut.is_halted.value), "DM halt did not park the core"

    # Set PC to 0x0030 and arm continuous single-step.
    await dm_cmd(dut, CMD_SETPC, 0x0030)
    await dm_cmd(dut, CMD_MEMWR, STEP_CTL, 0x0001)
    assert await dm_cmd(dut, CMD_READPC) == 0x0030, "PC not at 0x0030"

    # Each resume retires exactly one instruction; PC advances 0x30 -> 0x32 -> 0x34.
    assert await step_once(dut), "first step did not re-park"
    assert await dm_cmd(dut, CMD_READPC) == 0x0032, "PC not 0x0032 after one step"
    assert await step_once(dut), "second step did not re-park"
    assert await dm_cmd(dut, CMD_READPC) == 0x0034, "PC not 0x0034 after two steps"

    # Disable step, resume: the core runs free.
    await dm_cmd(dut, CMD_MEMWR, STEP_CTL, 0x0000)
    dut.dbg_cmd.value = 4  # RESUME
    dut.dbg_req.value = 1
    n = 0
    while int(dut.dbg_halted.value) and n < 300:
        await RisingEdge(dut.clock)
        n += 1
    dut.dbg_req.value = 0
    await ClockCycles(dut.clock, 10)
    assert not int(dut.is_halted.value), "step disabled: core did not run free"

    dut._log.info("DM-STEP PASS: one instruction per resume, PC 0x30->0x32->0x34")
