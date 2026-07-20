# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Shared harness for the Icarus execution cases.

A case spec is a dict: `prog` bytes at the entry PC, optional `data`
{addr: byte} preloads, optional `sp`/`pc` boot-vector overrides, `cycles` to
run, then checks: `regs` {n: word}, `ccr` (expected dut.ccr.hnzvc), `mem`
{addr: byte}. Architectural state is read through the hierarchical taps
dut.h8rf.dbg and dut.ccr.hnzvc, which Icarus surfaces.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

RESET_SP = 0x0200
RESET_PC = 0x0030

# hnzvc flag bits, matching dut.ccr.hnzvc (H N Z V C, H is the MSB).
H, N, Z, V, C = 0x10, 0x08, 0x04, 0x02, 0x01


class RamSlave:
    """Byte-addressed RAM on the core bus: combinational big-endian read,
    synchronous masked write. Unresolvable bus values are tolerated only while
    reset is asserted (Icarus powers up at X); after release they are errors."""

    def __init__(self, dut):
        self.dut = dut
        self.mem = bytearray(0x10000)

    def load(self, spec):
        self.mem[:] = bytearray(0x10000)
        sp = spec.get("sp", RESET_SP)
        pc = spec.get("pc", RESET_PC)
        self.mem[0x0002] = sp >> 8
        self.mem[0x0003] = sp & 0xFF
        self.mem[0x0006] = pc >> 8
        self.mem[0x0007] = pc & 0xFF
        for i, b in enumerate(spec["prog"]):
            self.mem[pc + i] = b
        for addr, b in spec.get("data", {}).items():
            self.mem[addr] = b

    def _in_reset(self):
        rv = self.dut.reset.value
        return not rv.is_resolvable or int(rv) == 1

    def _drive_read(self):
        self.dut.bus_rdy.value = 1
        av = self.dut.bus_addr.value
        if not av.is_resolvable:
            assert self._in_reset(), "bus_addr X after reset release"
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
            if not (req.is_resolvable and we.is_resolvable):
                assert self._in_reset(), "bus_req/bus_we X after reset release"
                continue
            if req == 1 and we == 1:
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


def check_state(dut, ram, name, spec):
    for n, exp in spec.get("regs", {}).items():
        got = reg(dut, n)
        assert got == exp, f"{name}: R{n}=0x{got:04x} exp 0x{exp:04x}"
    for n, exp in spec.get("regs_lo", {}).items():
        got = reg(dut, n) & 0xFF
        assert got == exp, f"{name}: R{n}L=0x{got:02x} exp 0x{exp:02x}"
    if "ccr" in spec:
        got = int(dut.ccr.hnzvc.value)
        assert got == spec["ccr"], (
            f"{name}: hnzvc=0b{got:05b} exp 0b{spec['ccr']:05b}"
        )
    for addr, exp in spec.get("mem", {}).items():
        got = ram.mem[addr]
        assert got == exp, f"{name}: mem[0x{addr:04x}]=0x{got:02x} exp 0x{exp:02x}"


async def init_core(dut, ram):
    """Drive inputs to reset state, start the RAM slave and clock, hold reset
    four cycles, then release it."""
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    cocotb.start_soon(ram.run())
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0


async def run_case(dut, name, spec):
    ram = RamSlave(dut)
    ram.load(spec)
    await init_core(dut, ram)
    await ClockCycles(dut.clock, spec["cycles"])

    check_state(dut, ram, name, spec)
    dut._log.info("EXEC %s PASS", name)
    return ram


def make_tests(cases, namespace):
    """Register one cocotb test per case in the caller's module namespace."""

    def make(name, spec):
        async def body(dut):
            await run_case(dut, name, spec)

        body.__name__ = f"exec_{name}"
        body.__qualname__ = body.__name__
        body.__module__ = namespace["__name__"]
        return cocotb.test()(body)

    for name, spec in cases.items():
        namespace[f"exec_{name}"] = make(name, spec)
