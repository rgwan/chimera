# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Full JTAG DTM test for the Chimera CoreTop on Verilator.

Drives the core through its JTAG pins only, mirroring test/core/tb_core_top_jtag.v:
read IDCODE, halt via CONTROL and poll in_progress, read STATUS fields, round-trip
two RAM words through CONTROL memWrite/memRead, set and read back the PC, resume,
and confirm is_halted clears. A Python RAM slave sits on the core's bus_* pins so
the DM mem primitives land in real memory.

The vendored cocotbext.jtag TAP driver models each DR with add_jtag_reg(name, width,
ir_addr); read()/write() scan IR then shift the DR LSB-first. Chimera trst is
active-high while the driver assumes active-low TRSTn, so trst is dropped from the
bus and the TAP is reset via TMS (reset_fsm, 5x TMS=1) with trst tied 0.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, Edge, RisingEdge

from cocotbext.jtag import JTAGBus, JTAGDevice, JTAGDriver

IDCODE = 0x00114514
IR_LEN = 4

IR_STATUS = 0x0
IR_IDCODE = 0x1
IR_CONTROL = 0x2

STATUS_W = 23
CONTROL_W = 37

CMD_MEMWR = 1
CMD_SETPC = 2
CMD_HALT = 3
CMD_RESUME = 4
CMD_READPC = 5
CMD_MEMRD = 6

DBG_BASE = 0xFF00
RESET_SP = 0x0200
RESET_PC = 0x0030


class ChimeraDtm(JTAGDevice):
    def __init__(self):
        super().__init__(name="ChimeraDTM", idcode=IDCODE, ir_len=IR_LEN)
        self.add_jtag_reg("IDCODE", 32, IR_IDCODE)
        self.add_jtag_reg("STATUS", STATUS_W, IR_STATUS)
        self.add_jtag_reg("CONTROL", CONTROL_W, IR_CONTROL, write=True)


def ctl_word(go, cmd, addr, data):
    """37-bit CONTROL word, LSB-first: cmd[3:0] addr[19:4] data[35:20] go[36]."""
    return (
        (cmd & 0xF)
        | ((addr & 0xFFFF) << 4)
        | ((data & 0xFFFF) << 20)
        | ((go & 0x1) << 36)
    )


class RamSlave:
    """Byte-addressed RAM on the core bus: combinational big-endian 16-bit read,
    synchronous masked write per bus_wmask. Mirrors tb_core_top_jtag.v."""

    def __init__(self, dut):
        self.dut = dut
        self.mem = bytearray(0x10000)
        self.mem[0x0002] = RESET_SP >> 8
        self.mem[0x0003] = RESET_SP & 0xFF
        self.mem[0x0006] = RESET_PC >> 8
        self.mem[0x0007] = RESET_PC & 0xFF

    def read_word(self, addr):
        hi = self.mem[addr & 0xFFFF]
        lo = self.mem[(addr + 1) & 0xFFFF]
        return (hi << 8) | lo

    def _drive_read(self):
        self.dut.bus_rdy.value = 1
        self.dut.bus_rdata.value = self.read_word(int(self.dut.bus_addr.value))

    async def _reads(self):
        # Combinational read: bus_rdata tracks bus_addr with no clock latency,
        # matching the Verilog RAM's always @(*).
        self._drive_read()
        while True:
            await Edge(self.dut.bus_addr)
            self._drive_read()

    async def _writes(self):
        while True:
            await RisingEdge(self.dut.clock)
            if self.dut.bus_req.value == 1 and self.dut.bus_we.value == 1:
                addr = int(self.dut.bus_addr.value)
                wdata = int(self.dut.bus_wdata.value)
                wmask = int(self.dut.bus_wmask.value)
                if wmask & 0b10:
                    self.mem[addr & 0xFFFF] = (wdata >> 8) & 0xFF
                if wmask & 0b01:
                    self.mem[(addr + 1) & 0xFFFF] = wdata & 0xFF
                self._drive_read()

    async def run(self):
        cocotb.start_soon(self._reads())
        await self._writes()


async def poll_control(jtag, guard=200):
    """Re-scan CONTROL with go=0 until in_progress (bit 36) clears; return the
    latched word so [35:20] can be read back."""
    word = await jtag.read("CONTROL")
    n = 0
    while (word >> 36) & 1 and n < guard:
        word = await jtag.read("CONTROL")
        n += 1
    assert not (word >> 36) & 1, "CONTROL command did not complete (in_progress stuck)"
    return word


async def control_cmd(jtag, cmd, addr=0, data=0):
    """Launch a CONTROL command (go=1) then poll in_progress to completion.
    Returns data[35:20] of the final read-back."""
    await jtag.write("CONTROL", ctl_word(1, cmd, addr, data))
    word = await poll_control(jtag)
    return (word >> 20) & 0xFFFF


async def read_status(jtag):
    return await jtag.read("STATUS")


@cocotb.test()
async def jtag_dtm(dut):
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    dut.trst.value = 0  # active-high; hold deasserted, reset the TAP via TMS

    ram = RamSlave(dut)
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    cocotb.start_soon(ram.run())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 8)

    bus = JTAGBus(dut, signals={"tck": "tck", "tms": "tms", "tdi": "tdi", "tdo": "tdo"})
    if hasattr(bus, "trst"):
        del bus.trst
    jtag = JTAGDriver(bus, period=100, unit="ns")
    jtag.add_device(ChimeraDtm())

    await jtag.reset_fsm()

    # IDCODE.
    idcode = await jtag.read("IDCODE")
    assert idcode == IDCODE, f"IDCODE 0x{idcode:08x} != 0x{IDCODE:08x}"

    # Halt, then poll in_progress -> 0.
    await control_cmd(jtag, CMD_HALT)

    # STATUS: is_halted, dbg_base, hwbp_count, dmactive.
    status = await read_status(jtag)
    for _ in range(100):
        if status & 0x1:
            break
        status = await read_status(jtag)
    assert status & 0x1, "STATUS is_halted not set after halt"
    dbg_base = (status >> 2) & 0xFFFF
    assert dbg_base == DBG_BASE, f"STATUS dbg_base 0x{dbg_base:04x} != 0x{DBG_BASE:04x}"
    hwbp = (status >> 18) & 0xF
    assert hwbp == 0, f"STATUS hwbp_count {hwbp} != 0"
    assert (status >> 22) & 0x1, "STATUS dmactive not set"

    # memWrite 0x0300 <- 0xBEEF, RAM holds it, memRead returns it.
    await control_cmd(jtag, CMD_MEMWR, 0x0300, 0xBEEF)
    await ClockCycles(dut.clock, 4)
    assert ram.read_word(0x0300) == 0xBEEF, "memWrite RAM not updated"
    val = await control_cmd(jtag, CMD_MEMRD, 0x0300)
    assert val == 0xBEEF, f"memRead 0x0300 returned 0x{val:04x} != 0xBEEF"

    # Second address to prove addr routing.
    await control_cmd(jtag, CMD_MEMWR, 0x0400, 0x1234)
    await ClockCycles(dut.clock, 4)
    val = await control_cmd(jtag, CMD_MEMRD, 0x0400)
    assert val == 0x1234, f"memRead 0x0400 returned 0x{val:04x} != 0x1234"

    # setPC then readPC.
    await control_cmd(jtag, CMD_SETPC, 0x0040)
    val = await control_cmd(jtag, CMD_READPC)
    assert val == 0x0040, f"readPC returned 0x{val:04x} != 0x0040"

    # Resume, confirm is_halted clears.
    await control_cmd(jtag, CMD_RESUME)
    status = await read_status(jtag)
    for _ in range(100):
        if not status & 0x1:
            break
        status = await read_status(jtag)
    assert not status & 0x1, "STATUS is_halted did not clear after resume"

    dut._log.info(
        "JTAG PASS: idcode, halt, status, memWrite/memRead x2, setPC, readPC, resume"
    )
