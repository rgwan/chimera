# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Interrupt-entry, vectoring, and RTE cases (base Core config). Ports
test/core/tb_core_{irq,irq_entry,irq_vector,rte}.v. The IRQ microcode entry is
observed through dut.useq.upc; I-flag through dut.ccr.iFlag; PC through
dut.intrf.dbgPc."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from executil import C, H, N, V, RamSlave, init_core

IRQ_PROC = 0x130


def start_upc_counter(dut, target):
    """Count cycles the microsequencer sits at target, like the Verilog
    always-block monitors."""
    state = {"n": 0}

    async def mon():
        while True:
            await RisingEdge(dut.clock)
            rv = dut.reset.value
            uv = dut.useq.upc.value
            if rv.is_resolvable and int(rv) == 0 \
                    and uv.is_resolvable and int(uv) == target:
                state["n"] += 1

    cocotb.start_soon(mon())
    return state


async def wait_fetch(dut, addr, guard=600):
    for _ in range(guard):
        await RisingEdge(dut.clock)
        req = dut.bus_req.value
        we = dut.bus_we.value
        if not (req.is_resolvable and we.is_resolvable):
            continue
        if req == 1 and we == 0 and int(dut.bus_addr.value) == addr:
            return
    raise AssertionError(f"fetch of 0x{addr:04x} never seen")


async def pulse(sig, clock, cycles=2):
    sig.value = 1
    await ClockCycles(clock, cycles)
    sig.value = 0


@cocotb.test()
async def exec_irq(dut):
    """Unmasked IRQ enters once and sets I; the handler clears I; a nested IRQ
    holds until rte, then the pending entry is taken."""
    ram = RamSlave(dut)
    ram.load({"prog": [], "data": {
        0x0018: 0x00, 0x0019: 0x80,              # IRQ0 vector -> 0x0080
        0x0030: 0x06, 0x0031: 0x7F,              # main: andc #0x7f,ccr
        0x0032: 0x40, 0x0033: 0xFE,              # bra -2
        0x0080: 0x06, 0x0081: 0x7F,              # handler: andc #0x7f,ccr
        0x008E: 0x56, 0x008F: 0x70,              # rte
    }})
    count = start_upc_counter(dut, IRQ_PROC)
    await init_core(dut, ram)

    await ClockCycles(dut.clock, 40)
    assert count["n"] == 0 and int(dut.ccr.iFlag.value) == 0, \
        "boot: andc unmasked, no entry"

    await pulse(dut.irq, dut.clock)
    await wait_fetch(dut, 0x0080)
    assert count["n"] == 1 and int(dut.ccr.iFlag.value) == 1, \
        "entry: taken once, I set"

    await wait_fetch(dut, 0x0086)
    assert int(dut.ccr.iFlag.value) == 0, "handler: andc cleared I"

    await pulse(dut.irq, dut.clock)
    await ClockCycles(dut.clock, 2)
    assert count["n"] == 1, "nested: held until rte"

    await ClockCycles(dut.clock, 80)
    pc = int(dut.intrf.dbgPc.value)
    assert count["n"] == 2, "pending: taken after rte"
    assert int(dut.ccr.iFlag.value) == 0 and 0x0032 <= pc <= 0x0035, \
        f"resume: I restored, halted in main (pc=0x{pc:04x})"
    dut._log.info("EXEC irq PASS")


@cocotb.test()
async def exec_irq_entry(dut):
    """IRQ vector entry stacks CCR and the return PC, the handler runs, and
    RTE restores CCR and resumes at the halt loop."""
    ram = RamSlave(dut)
    ram.load({"pc": 0x0100, "prog": [
        0x79, 0x07, 0x02, 0x00,  # mov.w #0x0200,R7
        0x79, 0x01, 0xBE, 0xEF,  # mov.w #0xBEEF,R1
        0x07, 0x2B,              # ldc #0x2B,ccr
        0x40, 0xFE,              # halt: bra -2
    ], "data": {
        0x0018: 0x01, 0x0019: 0x20,              # IRQ0 vector -> 0x0120
        0x0120: 0x79, 0x0121: 0x02, 0x0122: 0xCA, 0x0123: 0xFE,  # mov.w #0xCAFE,R2
        0x0124: 0x56, 0x0125: 0x70,              # rte
    }})
    await init_core(dut, ram)
    await ClockCycles(dut.clock, 40)
    await pulse(dut.irq, dut.clock)
    await ClockCycles(dut.clock, 120)

    regs = int(dut.h8rf.dbg.value)
    r1, r2, r7 = (regs >> 16) & 0xFFFF, (regs >> 32) & 0xFFFF, (regs >> 112) & 0xFFFF
    assert r1 == 0xBEEF, f"R1=0x{r1:04x} exp BEEF"
    assert r2 == 0xCAFE, f"R2=0x{r2:04x} exp CAFE"
    assert r7 == 0x0200, f"R7=0x{r7:04x} exp 0200"
    hnzvc = int(dut.ccr.hnzvc.value)
    assert hnzvc == (H | N | V | C), f"hnzvc=0b{hnzvc:05b} exp 0b11011"
    assert int(dut.ccr.iFlag.value) == 0, "I not cleared after RTE"
    assert ram.mem[0x01FC] == 0x2B and ram.mem[0x01FD] == 0x00, "stacked CCR"
    assert ram.mem[0x01FE] == 0x01 and ram.mem[0x01FF] == 0x0A, "stacked PC"
    dut._log.info("EXEC irq_entry PASS")


@cocotb.test()
async def exec_irq_vector(dut):
    """NMI at 0x0E, IRQ at 0x18+2*irq_number, and vt_base relocation of the
    whole table."""
    ram = RamSlave(dut)
    ram.load({"prog": [], "data": {
        0x000E: 0x00, 0x000F: 0x60,              # NMI -> 0x0060
        0x001C: 0x00, 0x001D: 0x70,              # IRQ2 -> 0x0070
        0x0022: 0x00, 0x0023: 0x80,              # IRQ5 -> 0x0080
        0x0030: 0x06, 0x0031: 0x7F,              # main: andc #0x7f,ccr
        0x0032: 0x40, 0x0033: 0xFE,              # bra -2
        0x0060: 0x79, 0x0061: 0x02, 0x0062: 0x22, 0x0063: 0x22,  # nmi: R2=0x2222
        0x0064: 0x56, 0x0065: 0x70,
        0x0070: 0x79, 0x0071: 0x01, 0x0072: 0x11, 0x0073: 0x11,  # irq2: R1=0x1111
        0x0074: 0x56, 0x0075: 0x70,
        0x0080: 0x79, 0x0081: 0x03, 0x0082: 0x33, 0x0083: 0x33,  # irq5: R3=0x3333
        0x0084: 0x56, 0x0085: 0x70,
    }})
    await init_core(dut, ram)
    dut.irq_number.value = 2
    await ClockCycles(dut.clock, 40)

    def r(n):
        return (int(dut.h8rf.dbg.value) >> (16 * n)) & 0xFFFF

    assert r(7) == 0x0200, f"boot SP=0x{r(7):04x} exp 0200"
    await pulse(dut.nmi, dut.clock)
    await ClockCycles(dut.clock, 60)
    assert r(2) == 0x2222, f"nmi R2=0x{r(2):04x} exp 2222"
    assert r(1) == 0 and r(3) == 0, "nmi hit an irq slot"
    await pulse(dut.irq, dut.clock)
    await ClockCycles(dut.clock, 60)
    assert r(1) == 0x1111, f"irq2 R1=0x{r(1):04x} exp 1111"
    dut.irq_number.value = 5
    await pulse(dut.irq, dut.clock)
    await ClockCycles(dut.clock, 60)
    assert r(3) == 0x3333, f"irq5 R3=0x{r(3):04x} exp 3333"
    assert r(7) == 0x0200, f"final SP=0x{r(7):04x} exp 0200"

    # Relocated table at 0x0100 (vt_base=1): fresh image, re-reset.
    dut.reset.value = 1
    ram.mem[:] = bytearray(0x10000)
    for addr, b in {
        0x0102: 0x03, 0x0103: 0x00,              # reset SP = 0x0300
        0x0106: 0x01, 0x0107: 0x30,              # reset PC = 0x0130
        0x010E: 0x01, 0x010F: 0x60,              # NMI -> 0x0160
        0x011C: 0x01, 0x011D: 0x70,              # IRQ2 -> 0x0170
        0x0130: 0x06, 0x0131: 0x7F,              # main: andc #0x7f,ccr
        0x0132: 0x40, 0x0133: 0xFE,              # bra -2
        0x0160: 0x79, 0x0161: 0x04, 0x0162: 0x44, 0x0163: 0x44,  # nmi: R4=0x4444
        0x0164: 0x56, 0x0165: 0x70,
        0x0170: 0x79, 0x0171: 0x05, 0x0172: 0x55, 0x0173: 0x55,  # irq2: R5=0x5555
        0x0174: 0x56, 0x0175: 0x70,
    }.items():
        ram.mem[addr] = b
    dut.vt_base.value = 1
    dut.irq_number.value = 2
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 40)

    assert r(7) == 0x0300, f"vt boot SP=0x{r(7):04x} exp 0300"
    await pulse(dut.nmi, dut.clock)
    await ClockCycles(dut.clock, 60)
    assert r(4) == 0x4444, f"vt nmi R4=0x{r(4):04x} exp 4444"
    await pulse(dut.irq, dut.clock)
    await ClockCycles(dut.clock, 60)
    assert r(5) == 0x5555, f"vt irq2 R5=0x{r(5):04x} exp 5555"
    dut._log.info("EXEC irq_vector PASS")


@cocotb.test()
async def exec_rte(dut):
    """RTE pops CCR then PC from a hand-built frame and lands on the halt."""
    ram = RamSlave(dut)
    ram.load({"sp": 0x01FC, "prog": [
        0x79, 0x07, 0x01, 0xFC,  # mov.w #0x01FC,R7 (SP)
        0x56, 0x70,              # rte
    ], "data": {
        0x01FC: 0xAB, 0x01FD: 0xCD,              # stacked CCR word
        0x01FE: 0x12, 0x01FF: 0x34,              # stacked PC = 0x1234
        0x1234: 0x40, 0x1235: 0xFE,              # handler: bra -2
    }})
    await init_core(dut, ram)
    await ClockCycles(dut.clock, 80)

    pc = int(dut.intrf.dbgPc.value)
    assert pc in (0x1234, 0x1236), f"pc=0x{pc:04x} exp ~1234"
    r7 = (int(dut.h8rf.dbg.value) >> 112) & 0xFFFF
    assert r7 == 0x0200, f"R7=0x{r7:04x} exp 0200 (SP after +4)"
    hnzvc = int(dut.ccr.hnzvc.value)
    assert hnzvc == (H | N | V | C), f"hnzvc=0b{hnzvc:05b} exp 0b11011"
    dut._log.info("EXEC rte PASS")
