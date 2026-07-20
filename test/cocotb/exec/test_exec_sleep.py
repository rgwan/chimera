# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Sleep park/wake sequencing. Ports test/core/tb_core_sleep.v; runs under the
base, STRICT_DECODE, and ROM_HEX configs (the microcode source must not change
sleep behavior). Phases: park with an idle bus, IRQ wake with the post-sleep
address stacked, masked-IRQ non-wake, NMI wake."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from executil import RamSlave, init_core

IRQ_PROC = 0x130
NMI_PROC = 0x1AB


@cocotb.test()
async def exec_sleep(dut):
    ram = RamSlave(dut)
    ram.load({"prog": [
        0x06, 0x7F,  # andc #0x7f,ccr (clear I)
        0x01, 0x80,  # sleep
        0xF8, 0x55,  # mov.b #0x55,R0L
        0x04, 0x80,  # orc #0x80,ccr (set I)
        0x01, 0x80,  # sleep
        0xF0, 0xAA,  # mov.b #0xaa,R0H
    ], "data": {
        0x000E: 0x01, 0x000F: 0x80,  # NMI vector -> 0x0180
        0x0018: 0x01, 0x0019: 0x80,  # IRQ0 vector -> 0x0180
        0x0180: 0x56, 0x0181: 0x70,  # handler: rte
    }})

    counts = {"irq": 0, "nmi": 0, "req": 0}

    async def mon():
        while True:
            await RisingEdge(dut.clock)
            rv = dut.reset.value
            if not rv.is_resolvable or int(rv) == 1:
                continue
            uv = dut.useq.upc.value
            if uv.is_resolvable:
                if int(uv) == IRQ_PROC:
                    counts["irq"] += 1
                if int(uv) == NMI_PROC:
                    counts["nmi"] += 1
            qv = dut.bus_req.value
            if qv.is_resolvable and int(qv) == 1:
                counts["req"] += 1
                sv = dut.core_sleeping.value
                assert not (sv.is_resolvable and int(sv) == 1), \
                    "bus active while core_sleeping"

    cocotb.start_soon(mon())
    await init_core(dut, ram)

    def pc():
        return int(dut.intrf.dbgPc.value)

    def r0():
        return int(dut.h8rf.dbg.value) & 0xFFFF

    # Park: sleep holds PC, core_sleeping asserted, bus idle.
    await ClockCycles(dut.clock, 60)
    assert pc() == 0x0034 and r0() & 0xFF == 0x00, "no wake: pc holds after sleep"
    assert int(dut.core_sleeping.value) == 1, "parked: core_sleeping asserted"
    req_mark = counts["req"]
    await ClockCycles(dut.clock, 20)
    assert counts["req"] == req_mark, "no wake: bus idle"

    # IRQ wake: handler entered, frame stacks the post-sleep address, resume.
    dut.irq.value = 1
    await ClockCycles(dut.clock, 2)
    dut.irq.value = 0
    await ClockCycles(dut.clock, 12)
    assert counts["irq"] == 1, "irq wake: handler entered"
    assert int(dut.core_sleeping.value) == 0, "irq wake: core_sleeping cleared"
    assert ram.mem[0x01FE] == 0x00 and ram.mem[0x01FF] == 0x34, \
        "irq wake: stacked pc"
    await ClockCycles(dut.clock, 40)
    assert r0() & 0xFF == 0x55, "irq wake: resumed after sleep"

    # Masked IRQ stays asleep; NMI still wakes.
    dut.irq.value = 1
    await ClockCycles(dut.clock, 2)
    dut.irq.value = 0
    await ClockCycles(dut.clock, 30)
    assert pc() == 0x003A and counts["irq"] == 1, "masked irq: still asleep"
    assert int(dut.core_sleeping.value) == 1, "masked irq: still parked"
    dut.nmi.value = 1
    await ClockCycles(dut.clock, 2)
    dut.nmi.value = 0
    await ClockCycles(dut.clock, 40)
    assert counts["nmi"] >= 1, "nmi wake: handler entered"
    assert (r0() >> 8) & 0xFF == 0xAA, "nmi wake: resumed after sleep"
    assert int(dut.core_sleeping.value) == 0, "nmi wake: core_sleeping cleared"
    dut._log.info("EXEC sleep PASS")
