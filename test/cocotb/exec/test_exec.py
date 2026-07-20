# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""ALU and data-movement execution cases (base Core config). Ports
test/core/tb_core_{add,sub,byte,imm,flags,loop,movw,daa_das}.v."""

from executil import C, H, N, V, Z, make_tests

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
    # mov.w #0x1234,R0
    "movw": {
        "prog": [0x79, 0x00, 0x12, 0x34],
        "cycles": 60,
        "regs": {0: 0x1234},
    },
    # daa/das over ldc-preset flags; CCR snapshots land in R5/R6 halves via stc.
    # SP boots 0 so R7 only holds the last snapshot byte.
    "daa_das": {
        "sp": 0x0000,
        "prog": [
            0x07, 0x00, 0xF0, 0x09, 0x0F, 0x00,              # daa r0h (09+cc=0)
            0x07, 0x00, 0xF9, 0x0A, 0x0F, 0x09,              # daa r1l (0a -> 10)
            0x07, 0x00, 0xF2, 0xA0, 0x0F, 0x02, 0x02, 0x0D,  # daa r2h, stc r5l
            0x07, 0x21, 0xFF, 0x33, 0x0F, 0x0F, 0x02, 0x0E,  # daa r7l, stc r6l
            0x07, 0x00, 0xF3, 0x99, 0x1F, 0x03,              # das r3h (99 stays)
            0x07, 0x20, 0xFB, 0x06, 0x1F, 0x0B, 0x02, 0x05,  # das r3l, stc r5h
            0x07, 0x01, 0xF4, 0x70, 0x1F, 0x04,              # das r4h (borrow)
            0x07, 0x21, 0xFC, 0x66, 0x1F, 0x0C, 0x02, 0x06,  # das r4l, stc r6h
            0x40, 0xFE,                                       # halt
        ],
        "cycles": 460,
        "regs": {
            0: 0x0900, 1: 0x0010, 2: 0x0000, 3: 0x9900,
            4: 0x1000, 5: 0x2405, 6: 0x2529, 7: 0x0099,
        },
        "ccr": H | Z | C,
    },
}

make_tests(CASES, globals())
