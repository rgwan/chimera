// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

/** Microword field layout (36 bit) — the microcode/datapath control contract.
  * Elaboration-time constants shared by MicroDecode and the microcode image.
  */
object MicroWord:
  // (hi, lo) inclusive bit ranges.
  val LITERAL  = (35, 27) // 9: next-uPC target (SeqSrc.Literal) / ALU const (BSel.Lit)
  val SEQ_SRC  = (26, 25)
  val COND     = (24, 22)
  val ALU_OP   = (21, 18)
  val A_SEL    = (17, 16) // ALU A source (ASel)
  val B_SEL    = (15, 14) // ALU B source (BSel)
  val H8_IDX   = (13, 12) // which OperandExtract field indexes the H8 file (H8Idx)
  val INT_IDX  = (11, 10) // internal-file index (IntIdx: PC/IREG/TEMP)
  val WSEL     = (9, 9)   // writeback target (WSel: 0 = H8, 1 = internal)
  val REG_WE   = (8, 8)
  val FLAG_CTL = (7, 5)
  val BUS_CTL  = (4, 3)   // BusCtl
  val SIZE     = (2, 2)   // 0 = byte, 1 = word
  val CALL     = (1, 1)   // with SeqSrc.Literal, push uPC+1 (subroutine call)
  val VCLEAR   = (0, 0)   // force V=0; with H8Idx.Ptr, also selects SP = R7

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
  val WordBad  = 6 // word-form guard selected from the current opcode page
  val NibbleBad = 7 // page-specific second-byte high-nibble guard

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
  val PassA = 15 // pass A (loads / moves: y = a)

/** Flag update group (V/C come from hardware; N/Z/H are microcode). */
object FlagCtl:
  val None    = 0
  val Nz      = 1 // N,Z; clear V (MOV / logical)
  val AddSub  = 2 // H,N,Z + hardware V,C
  val Shift   = 3 // N,Z + shift V,C
  val StickyZ = 4 // SUBX: keep Z when result is zero
  val Bit     = 5 // BTST/BLD/Bxx C or Z only
  val LoadCcr = 6 // direct CCR write
  val Nzv     = 7 // INC/DEC: N,Z + hardware V; preserve C,H

/** Bus transaction (2-bit). RMW is a Read then Write in microcode. */
object BusCtl:
  val None  = 0
  val Fetch = 1
  val Read  = 2
  val Write = 3

/** ALU A source. */
object ASel:
  val H8   = 0 // H8 register read (index from H8_IDX)
  val Int  = 1 // internal register read (index from INT_IDX)
  val Zero = 2
  val Mem  = 3 // BIU read data (natural big-endian, for loads / ext words)

/** ALU B source. */
object BSel:
  val H8   = 0
  val Imm8 = 1 // IR imm8, zero-extended
  val Int  = 2
  val Lit  = 3 // microword literal[7:0] as a constant (PC+=2, offsets)

/** Which OperandExtract field indexes the single H8 read/write port. */
object H8Idx:
  val RdImm = 0 // instr[3:0]   imm-ALU / mov-imm rd
  val RdReg = 1 // instr[11:8]  reg-reg / rd-only rd
  val RsReg = 2 // instr[15:12] reg-reg rs
  val Ptr   = 3 // instr[14:12] register-indirect pointer Rn (word reg)

/** Internal-file index. */
object IntIdx:
  val PC   = 0
  val IReg = 1
  val Temp = 2
  val CcrSrc = 3 // saved interrupt CCR source, not stored in IntRegFile

/** Writeback target. */
object WSel:
  val H8  = 0
  val Int = 1

/** Coarse-decode buckets, for reference in CoarseDecoder. */
object Dispatch:
  val ImmAluBase = 0x80 // bucket A: {0x80 | ooo}
  val MClassBase = 0xc0 // bucket B: {0xc0 | word[5:0]}

/** Microcode address map. Instruction routines start at ROM[dispatch] (0x00-0xFF);
  * the reset/fetch mainloop lives in the upper half so the two never collide.
  */
object Ucode:
  val FetchEntry = 0x100
  val BitPrefixExt = FetchEntry + 0xaf
  val BitPrefixPc = FetchEntry + 0xb0
  val BitPrefixGuard = FetchEntry + 0xb1
  val BitPrefixRead = FetchEntry + 0xb2
  val BitPrefixR16 = FetchEntry + 0xb3
  val BitRegIndex = FetchEntry + 0xb5
  val Daa = FetchEntry + 0xc0
  val Das = FetchEntry + 0xc2
  val Mulxu = FetchEntry + 0xc4
  val Divxu = FetchEntry + 0x03
  val DivxuSub = FetchEntry + 0xe7
