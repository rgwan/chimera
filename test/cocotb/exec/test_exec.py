# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Execution-equivalence cases on Core, run on Icarus so the architectural state
can be read through hierarchical taps (dut.h8rf.dbg, dut.ccr.hnzvc) the way the
Verilog benches did. Each case loads a small program, runs, and checks the
register file and CCR after retire. Ports test/core/tb_core_{add,sub,byte,imm,
flags,loop}.v.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

RESET_SP = 0x0200
RESET_PC = 0x0030

# hnzvc flag bits, matching dut.ccr.hnzvc (H N Z V C, H is the MSB).
H, N, Z, V, C = 0x10, 0x08, 0x04, 0x02, 0x01

CASES = {
    # mov.b #5,R0L ; mov.b #3,R1L ; add.b R1L,R0L
    "add": {
        "prog": [0xF8, 0x05, 0xF9, 0x03, 0x08, 0x98],
        "cycles": 60,
        "regs": {0: 0x0008, 1: 0x0003},
    },
    # mov.b #8,R0L ; mov.b #3,R1L ; sub.b R1L,R0L
    "sub": {
        "prog": [0xF8, 0x08, 0xF9, 0x03, 0x18, 0x98],
        "cycles": 70,
        "regs": {0: 0x0005},
    },
    # mov.b #5,R0H ; mov.b #3,R1H ; add.b R1H,R0H  (high byte lane)
    "byte": {
        "prog": [0xF0, 0x05, 0xF1, 0x03, 0x08, 0x10],
        "cycles": 60,
        "regs": {0: 0x0800, 1: 0x0300},
    },
    # mov.b #0x0F ; and.b #0x3C ; or.b #0x30 ; add.b #0x04 ; cmp.b #0x40 -> Z
    "imm": {
        "prog": [0xF8, 0x0F, 0xE8, 0x3C, 0xC8, 0x30, 0x88, 0x04, 0xA8, 0x40],
        "cycles": 80,
        "regs": {0: 0x0040},
        "ccr": Z,
    },
    # mov.b #0x7F,R0L ; mov.b #0x01,R1L ; add.b R1L,R0L -> H N V set
    "flags": {
        "prog": [0xF8, 0x7F, 0xF9, 0x01, 0x08, 0x98],
        "cycles": 60,
        "regs": {0: 0x0080},
        "ccr": H | N | V,
    },
    # add.b #1,R0L ; cmp.b #3,R0L ; bne -6  (count to 3)
    "loop": {
        "prog": [0x88, 0x01, 0xA8, 0x03, 0x46, 0xFA],
        "cycles": 120,
        "regs": {0: 0x0003},
    },
}


class RamSlave:
    """Byte-addressed RAM on the core bus: combinational big-endian read,
    synchronous masked write. load() reprograms it in place so one instance
    serves every case."""

    def __init__(self, dut):
        self.dut = dut
        self.mem = bytearray(0x10000)

    def load(self, prog):
        self.mem[:] = bytearray(0x10000)
        self.mem[0x0002] = RESET_SP >> 8
        self.mem[0x0003] = RESET_SP & 0xFF
        self.mem[0x0006] = RESET_PC >> 8
        self.mem[0x0007] = RESET_PC & 0xFF
        for i, b in enumerate(prog):
            self.mem[RESET_PC + i] = b

    def _drive_read(self):
        self.dut.bus_rdy.value = 1
        av = self.dut.bus_addr.value
        if not av.is_resolvable:  # X until reset settles on Icarus
            self.dut.bus_rdata.value = 0
            return
        addr = int(av)
        self.dut.bus_rdata.value = (self.mem[addr & 0xFFFF] << 8) | self.mem[
            (addr + 1) & 0xFFFF
        ]

    async def _reads(self):
        self._drive_read()
        while True:
            await self.dut.bus_addr.value_change
            self._drive_read()

    async def _writes(self):
        while True:
            await RisingEdge(self.dut.clock)
            req = self.dut.bus_req.value
            we = self.dut.bus_we.value
            if req.is_resolvable and we.is_resolvable and req == 1 and we == 1:
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


def reg(dut, n):
    return (int(dut.h8rf.dbg.value) >> (16 * n)) & 0xFFFF


@cocotb.test()
async def exec_suite(dut):
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0

    ram = RamSlave(dut)
    cocotb.start_soon(ram.run())
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())

    fails = []
    for name, spec in CASES.items():
        dut.reset.value = 1
        ram.load(spec["prog"])
        await ClockCycles(dut.clock, 4)
        dut.reset.value = 0
        await ClockCycles(dut.clock, spec["cycles"])

        for n, exp in spec["regs"].items():
            got = reg(dut, n)
            if got != exp:
                fails.append(f"{name}: R{n}=0x{got:04x} exp 0x{exp:04x}")
        if "ccr" in spec:
            got = int(dut.ccr.hnzvc.value)
            if got != spec["ccr"]:
                fails.append(f"{name}: hnzvc=0b{got:05b} exp 0b{spec['ccr']:05b}")
        dut._log.info("exec %s checked", name)

    assert not fails, "; ".join(fails)
    dut._log.info("EXEC PASS: %d cases", len(CASES))
