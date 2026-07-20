# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Batch ISA-case runner. Ports test/isa/tb_isa_case.v: each manifest entry
loads a memory image, runs until stop_fetch retire fetches (dut.useq.upc at the
fetch entry) or the cycle cap, then dumps regs/CCR/PC/memory probes. All cases
run in one sim process; results go to a JSON file for check_exec_sail.py.

The fetch counter samples upc before each clock edge and the final state right
after it, matching the Verilog posedge monitor and its #1 dump.

Env: ISA_MANIFEST (input JSON list), ISA_RESULTS (output JSON list).
"""

import json
import os

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

FETCH_UPC = 0x101
CYCLE_CAP = 4000


class Ram:
    def __init__(self, dut):
        self.dut = dut
        self.mem = bytearray(0x10000)

    def _drive_read(self):
        self.dut.bus_rdy.value = 1
        av = self.dut.bus_addr.value
        if not av.is_resolvable:
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

    def start(self):
        cocotb.start_soon(self._reads())
        cocotb.start_soon(self._writes())


async def run_one(dut, ram, entry):
    dut.reset.value = 1
    ram.mem[:] = bytearray(0x10000)
    for addr, byte in entry["image"].items():
        ram.mem[int(addr)] = byte
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0

    stop_fetch = entry.get("stop_fetch", 0)
    fetches = 0
    for _ in range(CYCLE_CAP):
        uv = dut.useq.upc.value
        upc = int(uv) if uv.is_resolvable else -1
        await RisingEdge(dut.clock)
        if upc == FETCH_UPC:
            fetches += 1
            if stop_fetch and fetches >= stop_fetch:
                break

    regs = int(dut.h8rf.dbg.value)
    return {
        "id": entry["id"],
        "regs": [(regs >> (16 * n)) & 0xFFFF for n in range(8)],
        "ccr": format(int(dut.ccr.hnzvc.value), "05b"),
        "pc": int(dut.intrf.dbgPc.value),
        "mem": {str(a): ram.mem[int(a)] for a in entry.get("probes", [])},
    }


@cocotb.test()
async def isa_cases(dut):
    manifest = json.loads(open(os.environ["ISA_MANIFEST"]).read())
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    dut.reset.value = 1
    ram = Ram(dut)
    ram.start()
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())

    results = []
    for entry in manifest:
        results.append(await run_one(dut, ram, entry))
    with open(os.environ["ISA_RESULTS"], "w") as f:
        json.dump(results, f)
    dut._log.info("ISA batch done: %d cases", len(results))
