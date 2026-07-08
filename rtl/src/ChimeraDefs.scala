// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

/** Microword field layout (36 bit = 4 x 9) and control-field encodings.
  * Elaboration-time constants shared by MicroDecode and the microcode image.
  */
object MicroWord:
  // (hi, lo) inclusive bit ranges.
  val LITERAL  = (35, 27) // absolute next-uPC target / immediate constant
  val SEQ_SRC  = (26, 25)
  val COND     = (24, 22)
  val ALU_OP   = (21, 18)
  val A_SEL    = (17, 15)
  val B_SEL    = (14, 12)
  val RD_GRP   = (11, 10)
  val REG_WE   = (9, 9)
  val FLAG_CTL = (8, 6)
  val BUS_CTL  = (5, 3)
  val MISC     = (2, 0)

/** next-uPC source select. */
object SeqSrc:
  val Next     = 0 // uPC + 1
  val Literal  = 1 // absolute branch to the literal field (gated by cond)
  val Dispatch = 2 // coarse dispatch / second-level jump-table
  val Return   = 3 // pop the call/return stack

/** Micro-branch predicate. */
object Cond:
  val None     = 0
  val Z        = 1
  val C        = 2
  val BusRdy   = 3
  val CcInstr  = 4 // branch condition selected from instr[11:8]
  val Irq      = 5 // pending interrupt latched

/** ALU operation. No barrel shift, no multiply/divide. Left shift (SHLL/SHAL)
  * and ROTXL reuse the adder (`r+r`, `adc r,r`); only right shift/rotate and the
  * `a[7]`-carry ROTL keep a path here.
  */
object AluOp:
  val Add   = 0
  val Sub   = 1
  val Adc   = 2
  val Sbc   = 3
  val And   = 4
  val Or    = 5
  val Xor   = 6
  val Not   = 7
  val Pass  = 8
  val Cmp   = 9
  val Shar  = 10 // arithmetic right
  val Shr1  = 11 // logical right
  val Rol   = 12 // rotate left (adder with cin = old bit7)
  val Ror   = 13 // rotate right
  val Rorc  = 14 // rotate right through carry
  val Rsvd  = 15

/** Flag update group (V/C come from hardware; N/Z/H are microcode). */
object FlagCtl:
  val None    = 0
  val Nz      = 1 // N,Z; clear V (MOV / logical)
  val AddSub  = 2 // H,N,Z + hardware V,C
  val Shift   = 3 // N,Z + shift V,C
  val StickyZ = 4 // SUBX: keep Z when result is zero
  val Bit     = 5 // BTST/BLD/Bxx C or Z only

/** Bus transaction. we=0 read, we=1 write with wmask byte enables. */
object BusCtl:
  val None  = 0
  val Fetch = 1
  val Read  = 2
  val Write = 3
  val Rmw   = 4

/** misc field bits. PC increment is a normal ALU write to PC in the internal
  * file, so misc only carries the operand size and the call flag.
  */
object Misc:
  val SizeWord = 0 // bit0: 0 = byte, 1 = word
  val Call     = 1 // bit1: with SeqSrc.Literal, push uPC+1 (subroutine call)

/** Coarse-decode buckets, for reference in CoarseDecoder. */
object Dispatch:
  val ImmAluBase = 0x80 // bucket A: {0x80 | ooo}
  val MClassBase = 0xc0 // bucket B: {0xc0 | word[5:0]}

/** Microcode address map. Instruction routines start at ROM[dispatch] (0x00-0xFF);
  * the reset/fetch mainloop lives in the upper half so the two never collide.
  */
object Ucode:
  val FetchEntry = 0x100
