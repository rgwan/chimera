// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

/** Microcode assembler. Author microwords symbolically with `MW(...)`; `words`
  * is the encoded 512 x 36 image the MicrocodeRom serves. Field positions follow
  * MicroWord. A round-trip self-check runs at elaboration.
  */
object MicrocodeImage:

  case class MW(
    lit:    Int     = 0,
    seq:    Int     = SeqSrc.Next,
    cond:   Int     = Cond.None,
    alu:    Int     = AluOp.Add,
    aSel:   Int     = ASel.H8,
    bSel:   Int     = BSel.H8,
    h8Idx:  Int     = H8Idx.RdReg,
    intIdx: Int     = IntIdx.PC,
    wsel:   Int     = WSel.H8,
    we:     Boolean = false,
    flag:   Int     = FlagCtl.None,
    bus:    Int     = BusCtl.None,
    size:   Int     = 0,
    call:   Boolean = false
  ):
    def encode: BigInt =
      def f(v: Int, r: (Int, Int)): BigInt =
        (BigInt(v) & ((BigInt(1) << (r._1 - r._2 + 1)) - 1)) << r._2
      f(lit, MicroWord.LITERAL) | f(seq, MicroWord.SEQ_SRC) | f(cond, MicroWord.COND) |
        f(alu, MicroWord.ALU_OP) | f(aSel, MicroWord.A_SEL) | f(bSel, MicroWord.B_SEL) |
        f(h8Idx, MicroWord.H8_IDX) | f(intIdx, MicroWord.INT_IDX) |
        f(wsel, MicroWord.WSEL) | (if we then BigInt(1) << MicroWord.REG_WE._2
                                   else BigInt(0)) |
        f(flag, MicroWord.FLAG_CTL) | f(bus, MicroWord.BUS_CTL) | f(size, MicroWord.SIZE) |
        (if call then BigInt(1) << MicroWord.CALL._2 else BigInt(0))

  private def field(w: BigInt, r: (Int, Int)): Int =
    ((w >> r._2) & ((BigInt(1) << (r._1 - r._2 + 1)) - 1)).toInt

  // Round-trip self-check: distinct value in every field survives encode with no
  // overlap. Pinned to an independently computed value. Runs at elaboration.
  private val probe = MW(lit = 0x1ab, seq = 3, cond = 5, alu = 9, aSel = 2, bSel = 3,
    h8Idx = 2, intIdx = 1, wsel = 1, we = true, flag = 4, bus = 3, size = 1, call = true)
  private val pw = probe.encode
  require(pw < (BigInt(1) << 36), "microword exceeds 36 bits")
  require(pw == BigInt("d5f66e79e", 16), "microword encoding value")
  require(
    field(pw, MicroWord.LITERAL) == 0x1ab && field(pw, MicroWord.SEQ_SRC) == 3 &&
      field(pw, MicroWord.COND) == 5 && field(pw, MicroWord.ALU_OP) == 9 &&
      field(pw, MicroWord.A_SEL) == 2 && field(pw, MicroWord.B_SEL) == 3 &&
      field(pw, MicroWord.H8_IDX) == 2 && field(pw, MicroWord.INT_IDX) == 1 &&
      field(pw, MicroWord.WSEL) == 1 && field(pw, MicroWord.REG_WE) == 1 &&
      field(pw, MicroWord.FLAG_CTL) == 4 && field(pw, MicroWord.BUS_CTL) == 3 &&
      field(pw, MicroWord.SIZE) == 1 && field(pw, MicroWord.CALL) == 1,
    "microword field packing"
  )

  /** Routines by ROM address. Empty entries default to the all-zero word
    * (SeqSrc.Next no-op); the fetch/dispatch and instruction routines land here.
    */
  val program: Map[Int, MW] = Map.empty

  private val depth = 512
  val words: Seq[BigInt] =
    if program.isEmpty then Seq.empty
    else (0 until depth).map(a => program.getOrElse(a, MW()).encode)
