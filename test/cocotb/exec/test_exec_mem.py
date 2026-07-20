# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Memory-addressing, stack, and fetch-stream cases (base Core config). Ports
test/core/tb_core_{mem,mem_byte,mem_disp,stack,stack_byte}.v and tb_core.v."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from executil import C, H, RESET_PC, RamSlave, make_tests

CASES = {
    # mov.w through @Rn: store then load back.
    "mem": {
        "prog": [
            0x79, 0x01, 0x12, 0x34,  # mov.w #0x1234,R1
            0x79, 0x02, 0x01, 0x00,  # mov.w #0x0100,R2
            0x69, 0xA1,              # mov.w R1,@R2
            0x69, 0x23,              # mov.w @R2,R3
        ],
        "cycles": 80,
        "regs": {1: 0x1234, 2: 0x0100, 3: 0x1234},
        "mem": {0x0100: 0x12, 0x0101: 0x34},
    },
    # mov.b through @Rn, both byte lanes, swap in memory.
    "mem_byte": {
        "prog": [
            0x79, 0x01, 0x01, 0x00,  # mov.w #0x0100,R1
            0x79, 0x02, 0x01, 0x01,  # mov.w #0x0101,R2
            0x07, 0x23,              # ldc #0x23,ccr
            0x68, 0x10,              # mov.b @R1,R0H
            0x68, 0x28,              # mov.b @R2,R0L
            0x68, 0xA0,              # mov.b R0H,@R2
            0x68, 0x98,              # mov.b R0L,@R1
        ],
        "data": {0x0100: 0x12, 0x0101: 0x34},
        "cycles": 110,
        "regs": {0: 0x1234, 1: 0x0100, 2: 0x0101},
        "ccr": H | C,
        "mem": {0x0100: 0x34, 0x0101: 0x12},
    },
    # mov @(d:16,Rn) load/store, byte and word, negative displacement.
    "mem_disp": {
        "prog": [
            0x79, 0x01, 0x01, 0x00,  # mov.w #0x0100,R1
            0x79, 0x02, 0x01, 0x44,  # mov.w #0x0144,R2
            0x07, 0x23,              # ldc #0x23,ccr
            0x6E, 0x18, 0x00, 0x40,  # mov.b @(0x40,R1),R0L
            0x6F, 0x23, 0xFF, 0xFC,  # mov.w @(-4,R2),R3
            0x6E, 0x98, 0x00, 0x42,  # mov.b R0L,@(0x42,R1)
            0x6F, 0x93, 0x00, 0x44,  # mov.w R3,@(0x44,R1)
            0xF4, 0x55,              # mov.b #0x55,R4H
        ],
        "data": {0x0140: 0x80, 0x0141: 0x00},
        "cycles": 130,
        "regs": {0: 0x0080, 1: 0x0100, 2: 0x0144, 3: 0x8000, 4: 0x5500},
        "ccr": H | C,
        "mem": {0x0142: 0x80, 0x0144: 0x80, 0x0145: 0x00},
    },
    # mov.w @-Rn push, @Rn+ pop, and the @-Rn self-store corner (old value).
    "stack": {
        "sp": 0x0220,
        "prog": [
            0x79, 0x01, 0x12, 0x34,  # mov.w #0x1234,R1
            0x79, 0x02, 0x02, 0x00,  # mov.w #0x0200,R2
            0x6D, 0xA1,              # mov.w R1,@-R2
            0x6D, 0x23,              # mov.w @R2+,R3
            0x79, 0x01, 0x01, 0x42,  # mov.w #0x0142,R1
            0x6D, 0x91,              # mov.w R1,@-R1 (stores old R1)
        ],
        "cycles": 115,
        "regs": {1: 0x0140, 2: 0x0200, 3: 0x1234},
        "mem": {0x01FE: 0x12, 0x01FF: 0x34, 0x0140: 0x01, 0x0141: 0x42},
    },
    # mov.b @Rn+ / @-Rn, and the byte @-Rn self-store corner.
    "stack_byte": {
        "sp": 0x0220,
        "prog": [
            0x79, 0x01, 0x02, 0x00,  # mov.w #0x0200,R1
            0x79, 0x02, 0x02, 0x02,  # mov.w #0x0202,R2
            0x07, 0x23,              # ldc #0x23,ccr
            0x6C, 0x18,              # mov.b @R1+,R0L
            0x6C, 0xA8,              # mov.b R0L,@-R2
            0x79, 0x03, 0x01, 0x41,  # mov.w #0x0141,R3
            0x6C, 0xBB,              # mov.b R3L,@-R3 (stores old R3L)
            0x40, 0xFE,              # halt
        ],
        "data": {0x0140: 0xAA, 0x0141: 0x55, 0x0200: 0x80, 0x0201: 0x55},
        "cycles": 150,
        "regs": {0: 0x0080, 1: 0x0201, 2: 0x0201, 3: 0x0140},
        "ccr": H | C,
        "mem": {0x0200: 0x80, 0x0201: 0x80, 0x0140: 0x41, 0x0141: 0x55},
    },
}

make_tests(CASES, globals())


@cocotb.test()
async def exec_smoke(dut):
    """NOP-fill boot: first fetch at the reset PC, then the fetch address
    stream steps by 2 per NOP."""
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0
    dut.bus_rdy.value = 1
    dut.bus_rdata.value = 0

    ram = RamSlave(dut)
    ram.load({"prog": []})
    cocotb.start_soon(ram.run())
    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())
    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0

    fetches = []
    for _ in range(300):
        await RisingEdge(dut.clock)
        await ReadOnly()
        req = dut.bus_req.value
        we = dut.bus_we.value
        if not (req.is_resolvable and we.is_resolvable):
            continue
        if req == 1 and we == 0:
            addr = int(dut.bus_addr.value)
            if addr >= RESET_PC and len(fetches) < 32:
                fetches.append(addr)

    assert len(fetches) >= 12, f"only {len(fetches)} fetches sampled"
    assert fetches[0] == RESET_PC, f"first fetch 0x{fetches[0]:04x} exp 0x{RESET_PC:04x}"
    for i in range(1, 12):
        assert fetches[i] == fetches[i - 1] + 2, (
            f"fetch[{i}]=0x{fetches[i]:04x} prev=0x{fetches[i-1]:04x}"
        )
    dut._log.info("EXEC smoke PASS: NOP loop, PC steps by 2")
