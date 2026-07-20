# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Self-hosted hardware breakpoint (no debug module). Ports
test/core/tb_core_hwbp_selfhosted.v: the program arms HWBP0 through MMIO, the
fire traps to the TRAP #2 handler which disables the comparator and returns;
is_halted must never rise in self-hosted mode."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from executil import RamSlave, init_core, reg


def start_halt_monitor(dut):
    state = {"saw": False}

    async def mon():
        while True:
            await RisingEdge(dut.clock)
            rv = dut.reset.value
            hv = dut.is_halted.value
            if rv.is_resolvable and int(rv) == 0 \
                    and hv.is_resolvable and int(hv) == 1:
                state["saw"] = True

    cocotb.start_soon(mon())
    return state


@cocotb.test()
async def exec_hwbp_self(dut):
    ram = RamSlave(dut)
    ram.load({"prog": [
        0x79, 0x00, 0x00, 0x50,  # mov.w #0x0050,R0
        0x6B, 0x80, 0xFF, 0x08,  # mov.w R0,@0xFF08 (HWBP0 ADDR)
        0x79, 0x00, 0x00, 0x01,  # mov.w #0x0001,R0
        0x6B, 0x80, 0xFF, 0x0A,  # mov.w R0,@0xFF0A (HWBP0 CTL: EN, instr)
    ], "data": {
        0x0014: 0x00, 0x0015: 0x80,  # trap #2 vector -> 0x0080
        0x0050: 0x79, 0x0051: 0x04, 0x0052: 0x12, 0x0053: 0x34,  # marker R4
        0x0054: 0x40, 0x0055: 0xFE,  # spin
        0x0080: 0x79, 0x0081: 0x06, 0x0082: 0x00, 0x0083: 0x00,  # R6=0
        0x0084: 0x6B, 0x0085: 0x86, 0x0086: 0xFF, 0x0087: 0x0A,  # disable bp
        0x0088: 0x79, 0x0089: 0x05, 0x008A: 0xBE, 0x008B: 0xEF,  # R5=0xBEEF
        0x008C: 0x56, 0x008D: 0x70,  # rte
    }})
    halt = start_halt_monitor(dut)
    await init_core(dut, ram)
    await ClockCycles(dut.clock, 400)

    assert reg(dut, 5) == 0xBEEF, f"handler did not run (R5=0x{reg(dut, 5):04x})"
    assert reg(dut, 4) == 0x1234, f"RTE did not resume the marker (R4=0x{reg(dut, 4):04x})"
    assert not halt["saw"], "is_halted asserted in self-hosted mode"
    dut._log.info("EXEC hwbp_self PASS")
