# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Debug-module P0 primitives on Core, driven through the DM port (no JTAG).

Mirrors test/core/tb_core_debug.v: halt, memWrite, memRead-back, setPC, resume.
setPC is verified through the readPC primitive rather than an internal PC tap, so
the whole check runs against top-level ports on Verilator.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from dmutil import (
    CMD_HALT,
    CMD_MEMRD,
    CMD_MEMWR,
    CMD_READPC,
    CMD_RESUME,
    CMD_SETPC,
    dm_cmd,
    dm_init,
    dm_resume,
)


@cocotb.test()
async def dm_debug(dut):
    ram = await dm_init(dut)
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0

    # Boot and run a few NOP fetches: not halted before the debugger attaches.
    await ClockCycles(dut.clock, 40)
    assert not int(dut.dbg_halted.value), "halted before debugger attached"

    # Attach and halt.
    dut.dbg_dmactive.value = 1
    await ClockCycles(dut.clock, 3)
    await dm_cmd(dut, CMD_HALT)
    assert int(dut.dbg_halted.value), "core did not park on halt"

    # Memory write then read-back, twice, to prove data and address routing.
    await dm_cmd(dut, CMD_MEMWR, 0x0300, 0xBEEF)
    await ClockCycles(dut.clock, 2)
    assert ram.read_word(0x0300) == 0xBEEF, "memWrite RAM not updated"
    assert await dm_cmd(dut, CMD_MEMRD, 0x0300) == 0xBEEF, "memRead 0x0300"

    await dm_cmd(dut, CMD_MEMWR, 0x0400, 0x1234)
    await ClockCycles(dut.clock, 2)
    assert await dm_cmd(dut, CMD_MEMRD, 0x0400) == 0x1234, "memRead 0x0400"
    assert int(dut.dbg_halted.value), "not halted between commands"

    # setPC then readPC.
    await dm_cmd(dut, CMD_SETPC, 0x0040)
    assert await dm_cmd(dut, CMD_READPC) == 0x0040, "readPC after setPC"

    # Resume, run, halt again: PC must have advanced from the resume point.
    await dm_resume(dut)
    await ClockCycles(dut.clock, 20)
    assert not int(dut.dbg_halted.value), "still halted after resume"
    await dm_cmd(dut, CMD_HALT)
    assert await dm_cmd(dut, CMD_READPC) != 0x0040, "PC did not advance on resume"

    dut._log.info("DM-DEBUG PASS: halt, memWrite/memRead x2, setPC, readPC, resume")
