# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Remote-bitbang JTAG server for CoreTop as a cocotb coroutine.

Replaces test/core/rbb_vpi.c + tb_core_top_rbb.v: opens a TCP listener, accepts
one client, and services the OpenOCD remote_bitbang single-char protocol against
the CoreTop TAP pins, one command per core clock. An external host tool
(jtag2gdb, real gdb via the RSP server) attaches over the socket. A RAM slave on
the core bus lets the core execute so software breakpoints land in real memory.

Protocol (matches OpenOCD remote_bitbang):
  '0'..'7' -> set (tck,tms,tdi) = low 3 bits;  'R' -> reply TDO as '0'/'1';
  't'/'r'  -> assert / release TRST;  'Q' -> quit;  'B'/'b' -> ignored.

Port comes from the RBB_PORT env var (default 2542). CONNECT_TIMEOUT and
RUN_TIMEOUT bound the run so a stalled client cannot hang CI.
"""

import os
import socket

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

RESET_SP = 0x0200
RESET_PC = 0x0030
CONNECT_TIMEOUT = 2_000_000   # core clocks to wait for the client to attach
RUN_TIMEOUT = 20_000_000      # core clocks to service the client


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


def _tdo(dut):
    v = dut.tdo.value
    return b"1" if v.is_resolvable and int(v) else b"0"


@cocotb.test()
async def rbb_server(dut):
    port = int(os.environ.get("RBB_PORT", "2542"))

    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0
    dut.tck.value = 0
    dut.tms.value = 1
    dut.tdi.value = 0
    dut.trst.value = 1

    ram = RamSlave(dut)
    cocotb.start_soon(ram.run())
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())

    # DTM reset is synchronous to TCK: pulse TCK with TRST asserted so the
    # TCK-domain flops clear before the core sees the debug port.
    await ClockCycles(dut.clock, 4)
    for _ in range(3):
        await ClockCycles(dut.clock, 2)
        dut.tck.value = 1
        await ClockCycles(dut.clock, 2)
        dut.tck.value = 0
    dut.reset.value = 0
    await ClockCycles(dut.clock, 20)

    lsock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    lsock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    lsock.bind(("127.0.0.1", port))
    lsock.listen(1)
    lsock.setblocking(False)
    dut._log.info("rbb: listening on 127.0.0.1:%d", port)

    client = None
    for _ in range(CONNECT_TIMEOUT):
        await RisingEdge(dut.clock)
        try:
            client, _ = lsock.accept()
            break
        except BlockingIOError:
            continue
    assert client is not None, "no client attached within the connect window"
    client.setblocking(False)
    client.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    dut._log.info("rbb: client connected")

    for _ in range(RUN_TIMEOUT):
        await RisingEdge(dut.clock)
        try:
            data = client.recv(1)
        except BlockingIOError:
            continue
        if not data:
            break  # client closed the connection
        c = data[0]
        if 0x30 <= c <= 0x37:  # '0'..'7'
            v = c - 0x30
            dut.tck.value = (v >> 2) & 1
            dut.tms.value = (v >> 1) & 1
            dut.tdi.value = v & 1
        elif c == ord("R"):
            reply = _tdo(dut)
            while True:
                try:
                    client.send(reply)
                    break
                except BlockingIOError:
                    await RisingEdge(dut.clock)
        elif c == ord("t"):
            dut.trst.value = 1
        elif c == ord("r"):
            dut.trst.value = 0
        elif c == ord("Q"):
            dut._log.info("rbb: client quit")
            break
        # 'B', 'b', other -> ignore
    else:
        assert False, "run window elapsed before the client quit"

    client.close()
    lsock.close()
    dut._log.info("RBB DONE: served remote-bitbang client")
