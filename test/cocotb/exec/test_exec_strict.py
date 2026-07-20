# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""Execution cases needing STRICT_DECODE=true, where guarded/rejected opcode
aliases must decode illegal. Ports test/core/tb_core_{word_reg,ccr,adds_subs,
mulxu,divxu}.v."""

from executil import C, H, N, V, Z, make_tests

CASES = {
    # add/mov/sub/cmp.w with a trailing guarded invalid alias (09 18).
    "word_reg": {
        "prog": [
            0x79, 0x01, 0x00, 0x01,  # mov.w #0x0001,R1
            0x79, 0x00, 0x7F, 0xFF,  # mov.w #0x7fff,R0
            0x09, 0x10,              # add.w R1,R0
            0x0D, 0x02,              # mov.w R0,R2
            0x79, 0x03, 0x80, 0x00,  # mov.w #0x8000,R3
            0x79, 0x04, 0x00, 0x01,  # mov.w #0x0001,R4
            0x19, 0x43,              # sub.w R4,R3
            0x1D, 0x20,              # cmp.w R2,R0
            0x09, 0x18,              # guarded invalid alias
        ],
        "cycles": 170,
        "regs": {0: 0x8000, 1: 0x0001, 2: 0x8000, 3: 0x7FFF, 4: 0x0001},
        "ccr": Z,
    },
    # ldc/stc/orc/xorc/andc round trips; rejected stc/ldc aliases then halt.
    "ccr": {
        "prog": [
            0x07, 0xA5, 0x02, 0x08,  # ldc #0xa5 ; stc ccr,R0L
            0x07, 0x00, 0x04, 0x21,  # ldc #0 ; orc #0x21
            0x02, 0x09,              # stc ccr,R1L
            0x07, 0xA3, 0x05, 0x23,  # ldc #0xa3 ; xorc #0x23
            0x02, 0x0A,              # stc ccr,R2L
            0x07, 0xBF, 0x06, 0x2C,  # ldc #0xbf ; andc #0x2c
            0x02, 0x0B,              # stc ccr,R3L
            0x02, 0x18, 0x03, 0x19,  # rejected stc/ldc aliases
            0x40, 0xFE,              # halt
        ],
        "cycles": 150,
        "regs": {0: 0x00A5, 1: 0x0021, 2: 0x0080, 3: 0x002C},
        "ccr": H | N | Z,
    },
    # adds/subs word scale ops preserve CCR (preloaded 0x23); rejected alias.
    "adds_subs": {
        "prog": [
            0x79, 0x00, 0x12, 0x34,  # mov.w #0x1234,R0
            0x79, 0x04, 0x00, 0xFF,  # mov.w #0x00ff,R4
            0x79, 0x07, 0xFF, 0xFF,  # mov.w #0xffff,R7
            0x79, 0x03, 0x00, 0x00,  # mov.w #0x0000,R3
            0x07, 0x23,              # ldc #0x23,ccr
            0x0B, 0x04,              # adds #1,R4
            0x0B, 0x87,              # adds #2,R7
            0x1B, 0x03,              # subs #1,R3
            0x1B, 0x87,              # subs #2,R7
            0x0B, 0x08,              # rejected alias
            0x40, 0xFE,              # halt
        ],
        "cycles": 170,
        "regs": {0: 0x1234, 3: 0xFFFF, 4: 0x0100, 7: 0xFFFF},
        "ccr": H | V | C,
    },
    # two mulxu with CCR snapshots into R5 halves proving CCR preservation.
    "mulxu": {
        "prog": [
            0x79, 0x00, 0x12, 0x34,  # mov.w #0x1234,R0
            0x79, 0x03, 0xAB, 0x34,  # mov.w #0xab34,R3
            0x07, 0x23,              # ldc #0x23,ccr
            0x50, 0x03,              # mulxu R0H,R3
            0x02, 0x0D,              # stc ccr,R5L
            0x79, 0x00, 0x00, 0xFF,  # mov.w #0x00ff,R0
            0x79, 0x01, 0x00, 0x02,  # mov.w #0x0002,R1
            0x07, 0xA5,              # ldc #0xa5,ccr
            0x50, 0x81,              # mulxu R0L,R1
            0x02, 0x05,              # stc ccr,R5H
            0x50, 0x08,              # rejected alias
            0x40, 0xFE,              # halt
        ],
        "cycles": 560,
        "regs": {0: 0x00FF, 1: 0x01FE, 3: 0x03A8, 5: 0xA523},
        "ccr": H | Z | C,
    },
    # four divxu including a zero divisor (result register unchanged); CCR
    # snapshots into R7/R5 halves.
    "divxu": {
        "prog": [
            0x79, 0x00, 0x00, 0x12,  # mov.w #0x0012,R0
            0x79, 0x01, 0x02, 0x34,  # mov.w #0x0234,R1
            0x07, 0x2F,              # ldc #0x2f,ccr
            0x51, 0x81,              # divxu R0L,R1
            0x02, 0x0F,              # stc ccr,R7L
            0x79, 0x02, 0x80, 0x00,  # mov.w #0x8000,R2
            0x79, 0x04, 0x40, 0x01,  # mov.w #0x4001,R4
            0x07, 0x01,              # ldc #0x01,ccr
            0x51, 0x24,              # divxu R2H,R4
            0x02, 0x07,              # stc ccr,R7H
            0x79, 0x00, 0x00, 0x00,  # mov.w #0x0000,R0
            0x79, 0x03, 0xBE, 0xEF,  # mov.w #0xbeef,R3
            0x07, 0x2B,              # ldc #0x2b,ccr
            0x51, 0x03,              # divxu R0H,R3 (zero divisor)
            0x02, 0x0D,              # stc ccr,R5L
            0x79, 0x00, 0x00, 0x01,  # mov.w #0x0001,R0
            0x79, 0x06, 0xFF, 0xFF,  # mov.w #0xffff,R6
            0x07, 0x25,              # ldc #0x25,ccr
            0x51, 0x86,              # divxu R0L,R6
            0x02, 0x05,              # stc ccr,R5H
            0x51, 0x08,              # rejected alias
            0x40, 0xFE,              # halt
        ],
        "cycles": 2440,
        "regs": {
            1: 0x061F, 3: 0xBEEF, 4: 0x0180,
            5: 0x2127, 6: 0x00FF, 7: 0x0923,
        },
        "ccr": H | C,
    },
}

make_tests(CASES, globals())
