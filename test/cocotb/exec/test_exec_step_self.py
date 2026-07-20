# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Self-hosted single-step (no debug module). Ports
test/core/tb_core_step_selfhosted.v: the program arms the one-shot STEP word,
the TRAP #2 handler counts four steps and re-arms, then leaves STEP off so the
marker retires; is_halted must never rise."""

import cocotb
from cocotb.triggers import ClockCycles

from executil import RamSlave, init_core, reg
from test_exec_hwbp_self import start_halt_monitor


@cocotb.test()
async def exec_step_self(dut):
    ram = RamSlave(dut)
    ram.load({"prog": [
        0x79, 0x00, 0x00, 0x03,  # mov.w #0x0003,R0
        0x6B, 0x80, 0xFF, 0x00,  # mov.w R0,@0xFF00 (STEP: EN, one-shot)
    ], "data": {
        0x0014: 0x00, 0x0015: 0x80,  # trap #2 vector -> 0x0080
        0x0050: 0x79, 0x0051: 0x04, 0x0052: 0x12, 0x0053: 0x34,  # marker R4
        0x0054: 0x40, 0x0055: 0xFE,  # spin
        0x0080: 0x0A, 0x0081: 0x0D,  # inc.b R5L (count the step)
        0x0082: 0xAD, 0x0083: 0x04,  # cmp.b #4,R5L
        0x0084: 0x47, 0x0085: 0x08,  # beq +8 (skip re-arm)
        0x0086: 0x79, 0x0087: 0x06, 0x0088: 0x00, 0x0089: 0x03,  # R6=0x0003
        0x008A: 0x6B, 0x008B: 0x86, 0x008C: 0xFF, 0x008D: 0x00,  # re-arm STEP
        0x008E: 0x56, 0x008F: 0x70,  # rte
    }})
    halt = start_halt_monitor(dut)
    await init_core(dut, ram)
    await ClockCycles(dut.clock, 900)

    assert reg(dut, 5) & 0xFF == 4, f"step count R5=0x{reg(dut, 5):04x} (want 4)"
    assert reg(dut, 4) == 0x1234, f"marker not reached (R4=0x{reg(dut, 4):04x})"
    assert not halt["saw"], "is_halted asserted in self-hosted mode"
    dut._log.info("EXEC step_self PASS")
