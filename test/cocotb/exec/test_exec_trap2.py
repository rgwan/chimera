# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""TRAP #2 suppression with a nested NMI. Ports
test/core/tb_core_trap2_suppress.v: HWBP1 is armed mid-handler; an NMI pulsed
right after handler entry must not lift the suppression on its RTE, so the
handler runs exactly once and the program resumes."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from executil import RamSlave, init_core, reg
from test_exec_hwbp_self import start_halt_monitor


@cocotb.test()
async def exec_trap2(dut):
    ram = RamSlave(dut)
    ram.load({"prog": [
        0x79, 0x00, 0x00, 0x50,  # mov.w #0x0050,R0
        0x6B, 0x80, 0xFF, 0x08,  # HWBP0 ADDR = 0x0050
        0x79, 0x00, 0x00, 0x01,  # mov.w #0x0001,R0
        0x6B, 0x80, 0xFF, 0x0A,  # HWBP0 CTL: EN, instr
        0x79, 0x00, 0x00, 0x84,  # mov.w #0x0084,R0
        0x6B, 0x80, 0xFF, 0x0C,  # HWBP1 ADDR = 0x0084 (mid-handler)
        0x79, 0x00, 0x00, 0x01,  # mov.w #0x0001,R0
        0x6B, 0x80, 0xFF, 0x0E,  # HWBP1 CTL: EN, instr
    ], "data": {
        0x0014: 0x00, 0x0015: 0x80,  # trap #2 vector -> 0x0080
        0x000E: 0x00, 0x000F: 0x98,  # NMI vector -> 0x0098
        0x0050: 0x79, 0x0051: 0x04, 0x0052: 0x12, 0x0053: 0x34,  # marker R4
        0x0054: 0x40, 0x0055: 0xFE,  # spin
        0x0080: 0x0A, 0x0081: 0x0D,  # inc.b R5L (entry witness)
        0x0082: 0x79, 0x0083: 0x06, 0x0084: 0x00, 0x0085: 0x00,  # R6=0 (0x0084 mid-instr)
        0x0086: 0x6B, 0x0087: 0x86, 0x0088: 0xFF, 0x0089: 0x0A,  # disable HWBP0
        0x008A: 0x79, 0x008B: 0x06, 0x008C: 0x00, 0x008D: 0x00,  # R6=0
        0x008E: 0x6B, 0x008F: 0x86, 0x0090: 0xFF, 0x0091: 0x0E,  # disable HWBP1
        0x0092: 0x56, 0x0093: 0x70,  # rte
        0x0098: 0x56, 0x0099: 0x70,  # nmi handler: rte
    }})
    halt = start_halt_monitor(dut)
    await init_core(dut, ram)

    # Pulse NMI one cycle right after the handler entry fetch.
    for _ in range(400):
        await RisingEdge(dut.clock)
        pv = dut.intrf.dbgPc.value
        if pv.is_resolvable and int(pv) == 0x0080:
            break
    else:
        raise AssertionError("handler entry (pc=0x0080) never seen")
    await RisingEdge(dut.clock)
    dut.nmi.value = 1
    await RisingEdge(dut.clock)
    dut.nmi.value = 0
    await ClockCycles(dut.clock, 600)

    assert reg(dut, 5) & 0xFF == 1, \
        f"handler entry count R5=0x{reg(dut, 5):04x} (want 1, nested fire?)"
    assert reg(dut, 4) == 0x1234, f"RTE did not resume (R4=0x{reg(dut, 4):04x})"
    assert not halt["saw"], "is_halted asserted in self-hosted mode"
    dut._log.info("EXEC trap2 PASS")
