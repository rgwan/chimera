# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Non-destructive state readout through the program-buffer technique. Ports
test/core/tb_core_nondestruct.v: with the core halted, each GPR is read by
injecting MOV.W rN,@aa:16 + TRAPA #2 into a RAM work area, resuming, and
letting the trap re-park the core; ReadCcr stays stable across the whole
sequence and the architectural CCR survives the final resume. Runs on Icarus
for the dut.h8rf.dbg / dut.ccr.ccrByte reference taps."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

from dmutil import (
    CMD_HALT,
    CMD_MEMRD,
    CMD_MEMWR,
    CMD_READPC,
    CMD_SETPC,
    dm_cmd,
    dm_init,
)

CMD_READCCR = 7
CODE = 0x0300
DATA = 0x0310
TRAPA2 = 0x5720


def gpr(dut, n):
    return (int(dut.h8rf.dbg.value) >> (16 * n)) & 0xFFFF


async def resume_until_repark(dut, guard=400):
    """Resume, then wait for the injected TRAPA #2 to re-park the core."""
    dut.dbg_cmd.value = 4  # RESUME
    dut.dbg_req.value = 1
    n = 0
    while int(dut.dbg_halted.value) and n < 300:
        await RisingEdge(dut.clock)
        n += 1
    dut.dbg_req.value = 0
    n = 0
    while not int(dut.is_halted.value) and n < guard:
        await RisingEdge(dut.clock)
        n += 1
    assert int(dut.is_halted.value), "injected snippet did not re-park"
    await ClockCycles(dut.clock, 2)


async def pb_read_gpr(dut, n):
    """Save the work area and PC, inject MOV.W rN,@DATA + TRAPA #2, run it,
    read the landed value, then restore everything."""
    s_pc = await dm_cmd(dut, CMD_READPC)
    s_c0 = await dm_cmd(dut, CMD_MEMRD, CODE)
    s_c1 = await dm_cmd(dut, CMD_MEMRD, CODE + 2)
    s_c2 = await dm_cmd(dut, CMD_MEMRD, CODE + 4)
    s_d = await dm_cmd(dut, CMD_MEMRD, DATA)

    await dm_cmd(dut, CMD_MEMWR, CODE, 0x6B80 | n)
    await dm_cmd(dut, CMD_MEMWR, CODE + 2, DATA)
    await dm_cmd(dut, CMD_MEMWR, CODE + 4, TRAPA2)
    await dm_cmd(dut, CMD_SETPC, CODE)
    await resume_until_repark(dut)
    val = await dm_cmd(dut, CMD_MEMRD, DATA)

    await dm_cmd(dut, CMD_MEMWR, CODE, s_c0)
    await dm_cmd(dut, CMD_MEMWR, CODE + 2, s_c1)
    await dm_cmd(dut, CMD_MEMWR, CODE + 4, s_c2)
    await dm_cmd(dut, CMD_MEMWR, DATA, s_d)
    await dm_cmd(dut, CMD_SETPC, s_pc)
    return val


@cocotb.test()
async def dm_nondestruct(dut):
    ram = await dm_init(dut)
    for addr, b in {
        0x0030: 0x79, 0x0031: 0x01, 0x0032: 0x11, 0x0033: 0x11,  # R1=0x1111
        0x0034: 0x79, 0x0035: 0x02, 0x0036: 0x22, 0x0037: 0x22,  # R2=0x2222
        0x0038: 0x79, 0x0039: 0x03, 0x003A: 0x33, 0x003B: 0x33,  # R3=0x3333
        0x003C: 0x79, 0x003D: 0x04, 0x003E: 0x44, 0x003F: 0x44,  # R4=0x4444
        0x0040: 0x07, 0x0041: 0x2C,                              # ldc #0x2C,ccr
        0x0042: 0x40, 0x0043: 0xFE,                              # spin
    }.items():
        ram.mem[addr] = b
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    await ClockCycles(dut.clock, 120)

    dut.dbg_dmactive.value = 1
    await ClockCycles(dut.clock, 3)
    await dm_cmd(dut, CMD_HALT)
    assert int(dut.is_halted.value), "halt did not park"

    gpr_pre = [gpr(dut, n) for n in range(8)]
    ccr_read = await dm_cmd(dut, CMD_READCCR) & 0xFF

    gpr_post = [await pb_read_gpr(dut, n) for n in range(8)]

    ccr_again = await dm_cmd(dut, CMD_READCCR) & 0xFF
    assert ccr_again == ccr_read, \
        f"ReadCcr not stable (0x{ccr_again:02x} vs 0x{ccr_read:02x})"
    assert ccr_read == 0x2C, f"ReadCcr=0x{ccr_read:02x} (want 2C)"

    dut.dbg_cmd.value = 4  # RESUME
    dut.dbg_req.value = 1
    n = 0
    while int(dut.dbg_halted.value) and n < 300:
        await RisingEdge(dut.clock)
        n += 1
    dut.dbg_req.value = 0
    await ClockCycles(dut.clock, 20)
    ccr_after = int(dut.ccr.ccrByte.value)
    assert ccr_after == 0x2C, f"architectural CCR after resume=0x{ccr_after:02x}"

    for k in range(8):
        assert gpr_post[k] == gpr_pre[k], (
            f"r{k} via progbuf=0x{gpr_post[k]:04x} want 0x{gpr_pre[k]:04x}"
        )
    dut._log.info("DM-NONDESTRUCT PASS: progbuf GPR reads, CCR stable (0x%02x)", ccr_read)
