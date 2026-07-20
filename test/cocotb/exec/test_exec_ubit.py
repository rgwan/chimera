# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""CCR user-bit case needing CCR_UBIT=true. Ports test/core/tb_core_ccr_ubit.v.
The full CCR byte is observed through stc into register low bytes: user bits
load (0x50), survive a flag update (0x5a = UI,U kept over N,V), and clear."""

from executil import make_tests

CASES = {
    "ccr_ubit": {
        "prog": [
            0x07, 0x50,  # ldc #0x50,ccr (UI=1,U=1)
            0x02, 0x08,  # stc ccr,R0L
            0xF9, 0x40,  # mov.b #0x40,R1L
            0x08, 0x99,  # add.b R1L,R1L -> 0x80, N=1 V=1
            0x02, 0x0A,  # stc ccr,R2L
            0x07, 0x00,  # ldc #0,ccr
            0x02, 0x0B,  # stc ccr,R3L
            0x40, 0xFE,  # halt
        ],
        "cycles": 120,
        "regs_lo": {0: 0x50, 2: 0x5A, 3: 0x00},
    },
}

make_tests(CASES, globals())
