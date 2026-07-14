# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""JTAG IDCODE smoke test for the Chimera DTM on Verilator.

Reads the DTM IDCODE (4-bit IR, IDCODE at IR=0x1, 32-bit DR) with the vendored
cocotbext.jtag TAP driver and checks it equals the Chimera idcode 0x00114514.
The core is fed an always-ready bus returning zero so its reset fetch never
stalls; the DTM lives in the TCK domain and is exercised purely over JTAG.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from cocotbext.jtag import JTAGBus, JTAGDevice, JTAGDriver

IDCODE = 0x00114514
IR_LEN = 4
IR_IDCODE = 0x1


class ChimeraDtm(JTAGDevice):
    def __init__(self):
        super().__init__(name="ChimeraDTM", idcode=IDCODE, ir_len=IR_LEN)
        self.add_jtag_reg("IDCODE", 32, IR_IDCODE)


async def core_bus(dut):
    """Trivial always-ready bus: rdy high, read data zero (reset fetch = NOP)."""
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    while True:
        await RisingEdge(dut.clock)
        dut.bus_rdy.value = 1
        dut.bus_rdata.value = 0


@cocotb.test()
async def idcode(dut):
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    # trst is active-high on this DTM; hold it deasserted and reset the TAP via
    # TMS (five TMS=1 cycles reach Test-Logic-Reset, which loads IR = IDCODE).
    dut.trst.value = 0

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    cocotb.start_soon(core_bus(dut))
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 4)

    bus = JTAGBus(dut, signals={"tck": "tck", "tms": "tms", "tdi": "tdi", "tdo": "tdo"})
    # cocotbext.jtag assumes an active-low TRSTn and, when it binds trst, parks it
    # at the deasserted-for-active-low level (1) -- which on this active-high trst
    # port holds the DTM in reset. Drop trst from the driver and reset the TAP via
    # TMS instead; trst stays 0 (deasserted) as set above.
    if hasattr(bus, "trst"):
        del bus.trst
    jtag = JTAGDriver(bus, period=100, unit="ns")
    jtag.add_device(ChimeraDtm())

    await jtag.reset_fsm()
    idcode = await jtag.read("IDCODE")
    assert idcode == IDCODE, f"IDCODE 0x{idcode:08x} != 0x{IDCODE:08x}"
    dut._log.info("JTAG IDCODE read back 0x%08x", idcode)
