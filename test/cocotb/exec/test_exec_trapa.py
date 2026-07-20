# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""TRAPA under strict decode. Ports test/core/tb_core_trapa.v: three software
traps stack frames and vector; trapa #2 routes to the debug slot instead of its
normal vector; an NMI raised at the end stays latched behind the debug-priority
stall; the trap flow never asserts core_sleeping."""

import cocotb
from cocotb.triggers import ClockCycles, RisingEdge

from executil import RamSlave, init_core

CASE_DATA = {
    0x000E: 0x01, 0x000F: 0x60,  # NMI vector
    0x0010: 0x01, 0x0011: 0x20,  # trapa #0
    0x0012: 0x01, 0x0013: 0x30,  # trapa #1
    0x0014: 0x01, 0x0015: 0x50,  # trapa #2 (debug route)
    0x0016: 0x01, 0x0017: 0x40,  # trapa #3
    0x0120: 0xF8, 0x0121: 0xA0, 0x0122: 0x56, 0x0123: 0x70,  # h0: R0L=0xa0, rte
    0x0130: 0xFC, 0x0131: 0xA1, 0x0132: 0x56, 0x0133: 0x70,  # h1: R4L=0xa1, rte
    0x0140: 0xFD, 0x0141: 0xA3, 0x0142: 0x56, 0x0143: 0x70,  # h3: R5L=0xa3, rte
    0x0150: 0xFE, 0x0151: 0xE2, 0x0152: 0x56, 0x0153: 0x70,  # h2: R6L=0xe2, rte
    0x0160: 0xFE, 0x0161: 0xEE, 0x0162: 0x56, 0x0163: 0x70,  # nmi: R6L=0xee, rte
}

CASE_PROG = [
    0x79, 0x07, 0x02, 0x00,  # mov.w #0x0200,R7
    0x57, 0x21,              # trapa #0
    0xF1, 0x55,              # mov.b #0x55,R1H
    0x07, 0xA5,              # ldc #0xa5,ccr
    0x57, 0x00,              # trapa #0
    0xF9, 0x11,              # mov.b #0x11,R1L
    0x57, 0x10,              # trapa #1
    0xFA, 0x22,              # mov.b #0x22,R2L
    0x57, 0x30,              # trapa #3
    0xFB, 0x33,              # mov.b #0x33,R3L
    0x57, 0x20,              # trapa #2 (debug route)
    0xFE, 0x44,              # mov.b #0x44,R6L (never retires)
]


@cocotb.test()
async def exec_trapa(dut):
    ram = RamSlave(dut)
    ram.load({"pc": 0x0100, "prog": CASE_PROG, "data": CASE_DATA})

    writes = []
    seen = {0x000E: False, 0x0010: False, 0x0012: False,
            0x0014: False, 0x0016: False}

    async def mon():
        while True:
            await RisingEdge(dut.clock)
            rv = dut.reset.value
            if not rv.is_resolvable or int(rv) == 1:
                continue
            sv = dut.core_sleeping.value
            assert not (sv.is_resolvable and int(sv) == 1), \
                "core_sleeping asserted during trap flow"
            req = dut.bus_req.value
            we = dut.bus_we.value
            if not (req.is_resolvable and we.is_resolvable) or int(req) == 0:
                continue
            if int(we) == 1:
                writes.append((int(dut.bus_addr.value),
                               int(dut.bus_wdata.value),
                               int(dut.bus_wmask.value)))
            else:
                addr = int(dut.bus_addr.value)
                if addr in seen:
                    seen[addr] = True

    cocotb.start_soon(mon())
    await init_core(dut, ram)

    # Run to the fetch after trapa #2's mov, then raise NMI behind the stall.
    for _ in range(800):
        await RisingEdge(dut.clock)
        req = dut.bus_req.value
        we = dut.bus_we.value
        if req.is_resolvable and we.is_resolvable and int(req) == 1 \
                and int(we) == 0 and int(dut.bus_addr.value) == 0x0116:
            break
    else:
        raise AssertionError("fetch of 0x0116 never seen")
    dut.nmi.value = 1
    await ClockCycles(dut.clock, 2)
    dut.nmi.value = 0
    await ClockCycles(dut.clock, 100)

    regs = int(dut.h8rf.dbg.value)

    def r(n):
        return (regs >> (16 * n)) & 0xFFFF

    exp = {0: 0x00A0, 1: 0x5511, 2: 0x0022, 3: 0x0033,
           4: 0x00A1, 5: 0x00A3, 6: 0x0000, 7: 0x0200}
    for n, e in exp.items():
        assert r(n) == e, f"R{n}=0x{r(n):04x} exp 0x{e:04x}"
    pc = int(dut.intrf.dbgPc.value)
    upc = int(dut.useq.cur.value)
    assert pc == 0x0118 and upc == 0x089, \
        f"debug stall pc=0x{pc:04x} upc=0x{upc:03x} exp 0118/089"
    assert int(dut.irqctl.nmiLatch.value) == 1, "NMI not latched behind debug"
    assert int(dut.useq.trapPend.value) == 0, "trapPend still set"
    assert seen[0x0010] and seen[0x0012] and seen[0x0016], "vector reads missing"
    assert not seen[0x0014] and not seen[0x000E], \
        "trapa #2 or NMI vector wrongly read"
    assert len(writes) == 6, f"write count {len(writes)} exp 6"
    exp_data = [0x010C, 0xA500, 0x0110, 0xA100, 0x0114, 0xA100]
    for i, (addr, data, mask) in enumerate(writes):
        exp_addr = 0x01FC if i & 1 else 0x01FE
        assert addr == exp_addr and mask == 0b11, \
            f"write[{i}] addr=0x{addr:04x} mask={mask:02b} exp 0x{exp_addr:04x}/11"
        assert data == exp_data[i], \
            f"write[{i}] data=0x{data:04x} exp 0x{exp_data[i]:04x}"
    dut._log.info("EXEC trapa PASS")
