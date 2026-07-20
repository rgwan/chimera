# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Shared helpers for the debug-module cocotb tests.

The tests drive Core's debug port directly (no JTAG): a level handshake raises
dbg_req until dbg_ack, then drops it and waits for ack to clear. A byte-addressed
RAM slave sits on the core bus so the DM mem primitives and instruction fetch
land in real memory. Mirrors test/core/tb_core_debug.v and the DM variants.
"""

import cocotb
from cocotb.triggers import RisingEdge

CMD_MEMWR = 1
CMD_SETPC = 2
CMD_HALT = 3
CMD_RESUME = 4
CMD_READPC = 5
CMD_MEMRD = 6

RESET_SP = 0x0200
RESET_PC = 0x0030


class RamSlave:
    """Byte-addressed RAM on the core bus: combinational big-endian 16-bit read,
    synchronous masked write per bus_wmask."""

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
        self._drive_read()
        while True:
            await self.dut.bus_addr.value_change
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


async def dm_init(dut):
    """Common reset/boot sequence; returns the RAM slave already running."""
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    dut.dbg_dmactive.value = 0
    dut.dbg_req.value = 0
    dut.dbg_cmd.value = 0
    dut.dbg_addr.value = 0
    dut.dbg_dataFromHost.value = 0
    ram = RamSlave(dut)
    cocotb.start_soon(ram.run())
    return ram


async def dm_cmd(dut, cmd, addr=0, data=0, guard=400):
    """Launch a DM command with the level handshake and return dbg_dataToHost
    captured at ack. Raises on ack timeout."""
    dut.dbg_cmd.value = cmd
    dut.dbg_addr.value = addr
    dut.dbg_dataFromHost.value = data
    dut.dbg_req.value = 1
    n = 0
    while not int(dut.dbg_ack.value) and n < guard:
        await RisingEdge(dut.clock)
        n += 1
    assert int(dut.dbg_ack.value), f"DM cmd {cmd} not acked"
    to_host = int(dut.dbg_dataToHost.value)
    dut.dbg_req.value = 0
    n = 0
    while int(dut.dbg_ack.value) and n < 2 * guard:
        await RisingEdge(dut.clock)
        n += 1
    return to_host


async def dm_resume(dut, guard=300):
    """Resume: never returns to the park word, so it clears dbg_halted instead
    of acking."""
    dut.dbg_cmd.value = CMD_RESUME
    dut.dbg_req.value = 1
    n = 0
    while int(dut.dbg_halted.value) and n < guard:
        await RisingEdge(dut.clock)
        n += 1
    assert not int(dut.dbg_halted.value), "resume did not clear halted"
    dut.dbg_req.value = 0
    await RisingEdge(dut.clock)
    await RisingEdge(dut.clock)
