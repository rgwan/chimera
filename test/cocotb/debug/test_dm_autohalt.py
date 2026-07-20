# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""DM auto-halt: mem commands issued while the core runs auto-halt, execute,
and auto-resume; issued while halted they leave the core parked. Ports
test/core/tb_core_autohalt.v. Runs on Icarus for the dut.intrf.dbgPc tap that
proves the core kept running past each command point."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from dmutil import CMD_HALT, CMD_MEMRD, CMD_MEMWR, dm_init, dm_resume


async def dm_oneshot(dut, cmd, addr=0, data=0, guard=400):
    """Level handshake like dm_cmd, but samples dbg_halted while waiting for
    ack; returns (dataToHost, saw_halt)."""
    dut.dbg_cmd.value = cmd
    dut.dbg_addr.value = addr
    dut.dbg_dataFromHost.value = data
    dut.dbg_req.value = 1
    saw_halt = False
    n = 0
    while n < guard:
        await RisingEdge(dut.clock)
        if int(dut.dbg_halted.value):
            saw_halt = True
        if int(dut.dbg_ack.value):
            break
        n += 1
    assert int(dut.dbg_ack.value), f"DM cmd {cmd} not acked"
    to_host = int(dut.dbg_dataToHost.value)
    dut.dbg_req.value = 0
    n = 0
    while int(dut.dbg_ack.value) and n < 2 * guard:
        await RisingEdge(dut.clock)
        n += 1
    return to_host, saw_halt


def pc(dut):
    return int(dut.intrf.dbgPc.value)


@cocotb.test()
async def dm_autohalt(dut):
    ram = await dm_init(dut)
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 40)
    assert not int(dut.dbg_halted.value), "halted before any command"

    dut.dbg_dmactive.value = 1
    await ClockCycles(dut.clock, 3)

    # memWrite while running: auto-halt, land in RAM, auto-resume.
    pc_before = pc(dut)
    _, saw = await dm_oneshot(dut, CMD_MEMWR, 0x0300, 0xBEEF)
    assert saw, "memwr(run): core did not auto-halt"
    assert ram.read_word(0x0300) == 0xBEEF, "memwr(run): RAM not updated"
    assert not int(dut.dbg_halted.value), "memwr(run): not auto-resumed"
    await ClockCycles(dut.clock, 30)
    assert not int(dut.dbg_halted.value), "memwr(run): stopped after resume"
    assert pc(dut) != pc_before, "memwr(run): PC did not advance"

    # memRead while running: same auto-halt round trip returns the data.
    pc_before = pc(dut)
    val, saw = await dm_oneshot(dut, CMD_MEMRD, 0x0300)
    assert saw, "memrd(run): core did not auto-halt"
    assert val == 0xBEEF, f"memrd(run): got 0x{val:04x}"
    assert not int(dut.dbg_halted.value), "memrd(run): not auto-resumed"
    await ClockCycles(dut.clock, 30)
    assert not int(dut.dbg_halted.value), "memrd(run): stopped after resume"
    assert pc(dut) != pc_before, "memrd(run): PC did not advance"

    # Second address proves routing while running.
    _, saw = await dm_oneshot(dut, CMD_MEMWR, 0x0400, 0x1234)
    assert saw, "memwr2(run): core did not auto-halt"
    val, _ = await dm_oneshot(dut, CMD_MEMRD, 0x0400)
    assert val == 0x1234, f"memrd2(run): got 0x{val:04x}"
    await ClockCycles(dut.clock, 20)
    assert not int(dut.dbg_halted.value), "second access: stopped"

    # Explicit halt: mem commands now keep the core parked.
    await dm_oneshot(dut, CMD_HALT)
    assert int(dut.dbg_halted.value), "explicit halt: not parked"
    await dm_oneshot(dut, CMD_MEMWR, 0x0500, 0xCAFE)
    assert ram.read_word(0x0500) == 0xCAFE, "halted memwr: RAM not updated"
    assert int(dut.dbg_halted.value), "halted memwr: resumed unexpectedly"
    val, _ = await dm_oneshot(dut, CMD_MEMRD, 0x0500)
    assert val == 0xCAFE, f"halted memrd: got 0x{val:04x}"
    assert int(dut.dbg_halted.value), "halted memrd: resumed unexpectedly"

    await dm_resume(dut)
    await ClockCycles(dut.clock, 20)
    assert not int(dut.dbg_halted.value), "explicit resume: still parked"
    dut._log.info("DM-AUTOHALT PASS: run-mode round trips, halted-mode stays parked")
