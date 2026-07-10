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
    aux:    Boolean = false,
    vclr:   Boolean = false
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
        (if aux then BigInt(1) << MicroWord.SEQ_AUX._2 else BigInt(0)) |
        (if vclr then BigInt(1) << MicroWord.VCLEAR._2 else BigInt(0))

  private def field(w: BigInt, r: (Int, Int)): Int =
    ((w >> r._2) & ((BigInt(1) << (r._1 - r._2 + 1)) - 1)).toInt

  private def retire(mw: MW = MW()): MW =
    mw.copy(seq = SeqSrc.Return, aux = true)

  private val debugEntryWord = MW(seq = SeqSrc.Literal, lit = Ucode.DebugEntry)
  private val nmiEntryWord = MW(seq = SeqSrc.Literal, lit = Ucode.IrqEntry)
  private def bitIndexHead(target: Int) = MW(
    bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
    wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
    seq = SeqSrc.Literal, lit = target)
  private def bitDataExec(op: Int, writes: Boolean, flag: Int = FlagCtl.None,
                          clear: Boolean = false, index: Int = IntIdx.PC) =
    retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Imm8,
      intIdx = index, cond = Cond.IntBit, alu = op, flag = flag,
      wsel = WSel.H8, we = writes, vclr = clear))
  private def bitCcrExec(op: Int) = retire(MW(
    aSel = ASel.Special, bSel = BSel.Imm8, cond = Cond.IntBit,
    alu = op, flag = FlagCtl.Bit))
  private val bitBstEntry = MW(seq = SeqSrc.Literal, lit = Ucode.BitBstStart)
  private val bitPrefixR16 = MW(seq = SeqSrc.Literal, lit = Ucode.BitPrefixR16)
  private val bitPrefixExt = MW(
    aSel = ASel.Zero, bSel = BSel.Imm8, alu = AluOp.Pass,
    wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
    seq = SeqSrc.Literal, lit = Ucode.BitPrefixExt, aux = true)
  private val bitDispatchEntries = (
    Seq(0x60, 0xe0).map(_ -> bitIndexHead(Ucode.BitRegBset)) ++
    Seq(0x61, 0xe1).map(_ -> bitIndexHead(Ucode.BitRegBnot)) ++
    Seq(0x62, 0xe2).map(_ -> bitIndexHead(Ucode.BitRegBclr)) ++
    Seq(0x63, 0xe3).map(_ -> bitIndexHead(Ucode.BitRegBtst)) ++
    Seq(0x67, 0xe7).map(_ -> bitBstEntry) ++
    Seq(0x70 -> bitDataExec(AluOp.Or, true),
        0x71 -> bitDataExec(AluOp.Xor, true),
        0x72 -> bitDataExec(AluOp.And, true, clear = true),
        0x73 -> bitDataExec(AluOp.And, false, flag = FlagCtl.Bit)) ++
    Seq(0x74, 0xf4).map(_ -> bitCcrExec(AluOp.Or)) ++
    Seq(0x75, 0xf5).map(_ -> bitCcrExec(AluOp.Xor)) ++
    Seq(0x76, 0xf6).map(_ -> bitCcrExec(AluOp.And)) ++
    Seq(0x77, 0xf7).map(_ -> bitCcrExec(AluOp.Pass)) ++
    Seq(0x7c, 0x7d).map(_ -> bitPrefixR16) ++
    Seq(0x7e, 0x7f, 0xfe, 0xff).map(_ -> bitPrefixExt)).toMap

  // Round-trip self-check: distinct value in every field survives encode with no
  // overlap. Pinned to an independently computed value. Runs at elaboration.
  private val probe = MW(lit = 0x1ab, seq = 3, cond = 5, alu = 9, aSel = 2, bSel = 3,
    h8Idx = 2, intIdx = 1, wsel = 1, we = true, flag = 4, bus = 3, size = 1, aux = true,
    vclr = true)
  private val pw = probe.encode
  require(pw < (BigInt(1) << 36), "microword exceeds 36 bits")
  require(pw == BigInt("d5f66e79f", 16), "microword encoding value")
  require(
    field(pw, MicroWord.LITERAL) == 0x1ab && field(pw, MicroWord.SEQ_SRC) == 3 &&
      field(pw, MicroWord.COND) == 5 && field(pw, MicroWord.ALU_OP) == 9 &&
      field(pw, MicroWord.A_SEL) == 2 && field(pw, MicroWord.B_SEL) == 3 &&
      field(pw, MicroWord.H8_IDX) == 2 && field(pw, MicroWord.INT_IDX) == 1 &&
      field(pw, MicroWord.WSEL) == 1 && field(pw, MicroWord.REG_WE) == 1 &&
      field(pw, MicroWord.FLAG_CTL) == 4 && field(pw, MicroWord.BUS_CTL) == 3 &&
      field(pw, MicroWord.SIZE) == 1 && field(pw, MicroWord.SEQ_AUX) == 1 &&
      field(pw, MicroWord.VCLEAR) == 1,
    "microword field packing"
  )

  /** Two-source reg-reg byte op: stage rs into TEMP, then rd = rd OP TEMP.
    * AH=1 ops (mclass=true) also dispatch via the m-class alias {0xC0|disp[5:0]}. */
  private def regReg2(disp: Int, tail: Int, op: Int, flag: Int, writes: Boolean,
                      mclass: Boolean = true): Seq[(Int, MW)] =
    val stage = MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
                   wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
                   seq = SeqSrc.Literal, lit = tail)
    val entries = if mclass then Seq(disp, 0xc0 | (disp & 0x3f)) else Seq(disp)
    entries.map(_ -> stage) :+
      (tail -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int,
                  intIdx = IntIdx.Temp, alu = op, flag = flag, wsel = WSel.H8,
                  we = writes)))

  /** Word reg-reg op: guard bit7/bit3, then stage rs16 and operate on rd16. */
  private def regReg2Word(disp: Int, guard: Int, op: Int, flag: Int,
                          writes: Boolean): Seq[(Int, MW)] =
    Seq(disp -> MW(seq = SeqSrc.Literal, lit = guard),
        guard -> MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
        (guard + 1) -> MW(bSel = BSel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.Pass, size = 1,
                   wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
                   seq = SeqSrc.Literal, lit = guard + 2),
        (guard + 2) -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int,
                   intIdx = IntIdx.Temp, alu = op, flag = flag, size = 1,
                   wsel = WSel.H8, we = writes)))

  /** Single-operand +/-1 (INC/DEC): needs a Lit const, so it cannot also branch
    * in the same word. Jump to an upper routine: op with seq=Next, then a pure
    * jump back to fetch. */
  private def unary1(disp: Int, routine: Int, op: Int): Seq[(Int, MW)] =
    Seq(disp -> MW(seq = SeqSrc.Literal, lit = routine),
        routine -> MW(aSel = ASel.H8, bSel = BSel.Lit, lit = 1, h8Idx = H8Idx.RdReg,
                      alu = op, flag = FlagCtl.Nzv, wsel = WSel.H8, we = true,
                      seq = SeqSrc.Next),
        (routine + 1) -> retire())

  private def addsSubs(disp: Int, routine: Int, op: Int,
                       mclass: Boolean = false): Seq[(Int, MW)] =
    val entries = if mclass then Seq(disp, 0xc0 | (disp & 0x3f)) else Seq(disp)
    entries.map(_ -> MW(seq = SeqSrc.Literal, lit = routine)) ++
      Seq(routine -> MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal,
                        lit = Ucode.Retire),
        (routine + 1) -> MW(aSel = ASel.H8, bSel = BSel.Lit, lit = 0x100,
                      h8Idx = H8Idx.RdReg, alu = op, size = 1,
                      wsel = WSel.H8, we = true, seq = SeqSrc.Next),
        (routine + 2) -> retire())

  private def cmpIntGe(addr: Int, idx: Int, threshold: Int,
                       target: Int): Seq[(Int, MW)] =
    Seq(
      addr -> MW(aSel = ASel.Int, intIdx = idx, bSel = BSel.Lit,
                 lit = threshold, alu = AluOp.Sub, cond = Cond.AluGe),
      (addr + 1) -> MW(cond = Cond.AluGe, seq = SeqSrc.Literal, lit = target)
    )

  private def intBitBranch(addr: Int, bit5: Boolean, target: Int): (Int, MW) =
    addr -> MW(cond = Cond.IntBit, intIdx = IntIdx.Aux, vclr = bit5,
               seq = SeqSrc.Literal, lit = target)

  private def bcdAdjust(addr: Int, value: Int): Seq[(Int, MW)] =
    Seq(
      addr -> MW(bSel = BSel.Lit, lit = value, alu = AluOp.Pass,
                 wsel = WSel.Int, intIdx = IntIdx.Temp, we = true),
      (addr + 1) -> MW(seq = SeqSrc.Literal, lit = Ucode.BcdFinish)
    )

  private def bcd(): Seq[(Int, MW)] =
    val adj0 = Ucode.BcdAdjust
    val adj6 = adj0 + 2
    val adj60 = adj0 + 4
    val adj66 = adj0 + 6
    val daaC0H1 = Ucode.DaaDecision + 10
    val daaC1 = Ucode.DaaDecision + 15
    val daaC0LowBad = Ucode.DaaDecision + 7
    val dasC0H1 = Ucode.DasDecision + 3
    val dasC1 = Ucode.DasDecision + 17
    val dasC1H1 = dasC1 + 4
    val dasC1H0Lower = Ucode.DasDecision + 8
    Seq(
      0x0f -> MW(seq = SeqSrc.Literal, lit = Ucode.Daa),
      Ucode.Daa -> MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal,
                      lit = Ucode.Retire),
      (Ucode.Daa + 1) -> MW(aSel = ASel.Special, alu = AluOp.PassA,
                            wsel = WSel.Int, intIdx = IntIdx.Aux, we = true,
                            seq = SeqSrc.Literal, lit = Ucode.BcdCommon),
      0x1f -> MW(seq = SeqSrc.Literal, lit = Ucode.Das),
      Ucode.Das -> MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal,
                      lit = Ucode.Retire),
      (Ucode.Das + 1) -> MW(aSel = ASel.Special, bSel = BSel.Lit, lit = 0x40,
                            alu = AluOp.Or, wsel = WSel.Int,
                            intIdx = IntIdx.Aux, we = true),
      (Ucode.Das + 2) -> MW(seq = SeqSrc.Literal, lit = Ucode.BcdCommon),

      Ucode.BcdCommon -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
                            bSel = BSel.Lit, lit = 0x0f, alu = AluOp.And,
                            wsel = WSel.Int, intIdx = IntIdx.Temp, we = true),
      (Ucode.BcdCommon + 1) -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
                                  alu = AluOp.PassA, wsel = WSel.Int,
                                  intIdx = IntIdx.IReg, we = true),
      (Ucode.BcdCommon + 2) -> MW(lit = 3, aux = true),
      (Ucode.BcdCommon + 3) -> MW(aSel = ASel.Int, intIdx = IntIdx.IReg,
                                  alu = AluOp.Shr1, wsel = WSel.Int, we = true),
      (Ucode.BcdCommon + 4) -> MW(cond = Cond.LoopNZ, seq = SeqSrc.Literal,
                                  lit = Ucode.BcdCommon + 3),
      (Ucode.BcdCommon + 5) -> MW(cond = Cond.IntBit, intIdx = IntIdx.Aux,
                                  size = 1, seq = SeqSrc.Literal,
                                  lit = Ucode.DasDecision),
      (Ucode.BcdCommon + 6) -> MW(seq = SeqSrc.Literal,
                                  lit = Ucode.DaaDecision),

      intBitBranch(Ucode.DaaDecision, false, daaC1),
      intBitBranch(Ucode.DaaDecision + 1, true, daaC0H1),
      (Ucode.DaaDecision + 6) -> MW(seq = SeqSrc.Literal, lit = adj0),
      (Ucode.DaaDecision + 9) -> MW(seq = SeqSrc.Literal, lit = adj6),
      (Ucode.DaaDecision + 14) -> MW(seq = SeqSrc.Literal, lit = adj6),
      intBitBranch(daaC1, true, Ucode.DaaC1H1),
      (Ucode.DaaDecision + 20) -> MW(seq = SeqSrc.Literal, lit = adj60),
      (Ucode.DaaC1H1 + 4) -> MW(seq = SeqSrc.Literal, lit = adj66),

      intBitBranch(Ucode.DasDecision, false, dasC1),
      intBitBranch(Ucode.DasDecision + 1, true, dasC0H1),
      (Ucode.DasDecision + 2) -> MW(seq = SeqSrc.Literal, lit = adj0),
      (Ucode.DasDecision + 7) -> MW(seq = SeqSrc.Literal, lit = adj0),
      intBitBranch(dasC1, true, dasC1H1),
      (dasC1 + 3) -> MW(seq = SeqSrc.Literal, lit = adj0),
      (dasC1H0Lower + 2) -> MW(seq = SeqSrc.Literal, lit = adj60),
      (dasC1H1 + 2) -> MW(seq = SeqSrc.Literal, lit = adj0),
      (dasC1H1 + 5) -> MW(seq = SeqSrc.Literal, lit = adj0),

      Ucode.BcdFinish -> MW(cond = Cond.IntBit, intIdx = IntIdx.Aux,
                            size = 1, seq = SeqSrc.Literal,
                            lit = Ucode.BcdFinish + 4),
      (Ucode.BcdFinish + 1) -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
                                  bSel = BSel.Int, intIdx = IntIdx.Temp,
                                  alu = AluOp.Add, flag = FlagCtl.AddSub,
                                  wsel = WSel.H8, we = true),
      (Ucode.BcdFinish + 2) -> MW(aSel = ASel.Special, bSel = BSel.Lit,
                                  lit = 0x0d, alu = AluOp.And, wsel = WSel.Int,
                                  intIdx = IntIdx.Temp, we = true),
      (Ucode.BcdFinish + 3) -> MW(seq = SeqSrc.Literal,
                                  lit = Ucode.BcdFinish + 6),
      (Ucode.BcdFinish + 4) -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
                                  bSel = BSel.Int, intIdx = IntIdx.Temp,
                                  alu = AluOp.Sub, flag = FlagCtl.AddSub,
                                  wsel = WSel.H8, we = true),
      (Ucode.BcdFinish + 5) -> MW(aSel = ASel.Special, bSel = BSel.Lit,
                                  lit = 0x0c, alu = AluOp.And, wsel = WSel.Int,
                                  intIdx = IntIdx.Temp, we = true),
      (Ucode.BcdFinish + 6) -> MW(aSel = ASel.Int, intIdx = IntIdx.Aux,
                                  bSel = BSel.Lit, lit = 0xa3, alu = AluOp.And,
                                  wsel = WSel.Int, we = true),
      (Ucode.BcdFinish + 7) -> MW(aSel = ASel.Int, intIdx = IntIdx.Aux,
                                  bSel = BSel.Int, vclr = true, alu = AluOp.Or,
                                  wsel = WSel.Int, we = true),
      (Ucode.BcdFinish + 8) -> retire(MW(aSel = ASel.Int,
                                  intIdx = IntIdx.Aux, alu = AluOp.PassA,
                                  flag = FlagCtl.LoadCcr))
    ) ++
      cmpIntGe(Ucode.DaaDecision + 2, IntIdx.Temp, 10, daaC0LowBad) ++
      cmpIntGe(Ucode.DaaDecision + 4, IntIdx.IReg, 10, adj60) ++
      cmpIntGe(daaC0LowBad, IntIdx.IReg, 9, adj66) ++
      cmpIntGe(daaC0H1, IntIdx.Temp, 4, adj0) ++
      cmpIntGe(daaC0H1 + 2, IntIdx.IReg, 10, adj66) ++
      cmpIntGe(daaC1 + 1, IntIdx.IReg, 3, adj0) ++
      cmpIntGe(daaC1 + 3, IntIdx.Temp, 10, adj66) ++
      cmpIntGe(Ucode.DaaC1H1, IntIdx.IReg, 4, adj0) ++
      cmpIntGe(Ucode.DaaC1H1 + 2, IntIdx.Temp, 4, adj0) ++
      cmpIntGe(dasC0H1, IntIdx.IReg, 9, adj0) ++
      cmpIntGe(dasC0H1 + 2, IntIdx.Temp, 6, adj6) ++
      cmpIntGe(dasC1 + 1, IntIdx.IReg, 7, dasC1H0Lower) ++
      cmpIntGe(dasC1H0Lower, IntIdx.Temp, 10, adj0) ++
      cmpIntGe(dasC1H1, IntIdx.IReg, 6, dasC1H1 + 3) ++
      cmpIntGe(dasC1H1 + 3, IntIdx.Temp, 6, adj66) ++
      bcdAdjust(adj0, 0x00) ++ bcdAdjust(adj6, 0x06) ++
      bcdAdjust(adj60, 0x60) ++ bcdAdjust(adj66, 0x66)

  private def mulxu(base: Int): Seq[(Int, MW)] =
    val add = base + 10
    Seq(
      0x50 -> MW(seq = SeqSrc.Literal, lit = base),
      base -> MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
      (base + 1) -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
                       wsel = WSel.Int, intIdx = IntIdx.Temp, we = true),
      (base + 2) -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Lit,
                       lit = 0xff, alu = AluOp.And, size = 1,
                       wsel = WSel.Int, intIdx = IntIdx.IReg, we = true),
      (base + 3) -> MW(bSel = BSel.Lit, lit = 0, alu = AluOp.Pass,
                       h8Idx = H8Idx.RdReg, size = 1, wsel = WSel.H8, we = true),
      (base + 4) -> MW(lit = 7, aux = true),
      (base + 5) -> MW(cond = Cond.IntBit, intIdx = IntIdx.Temp,
                       seq = SeqSrc.Literal, lit = add),
      (base + 6) -> MW(aSel = ASel.Int, bSel = BSel.Int, intIdx = IntIdx.IReg,
                       alu = AluOp.Add, size = 1, wsel = WSel.Int, we = true),
      (base + 7) -> MW(aSel = ASel.Int, intIdx = IntIdx.Temp, alu = AluOp.Shr1,
                       wsel = WSel.Int, we = true),
      (base + 8) -> MW(cond = Cond.LoopNZ, seq = SeqSrc.Literal, lit = base + 5),
      (base + 9) -> retire(),
      add -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int,
                intIdx = IntIdx.IReg, alu = AluOp.Add, size = 1,
                wsel = WSel.H8, we = true, seq = SeqSrc.Literal,
                lit = base + 6)
    )

  private def divxu(base: Int, sub: Int): Seq[(Int, MW)] =
    val finish = base + 19
    require(sub == base + 20, "DIVXU subroutine placement")
    Seq(
      0x51 -> MW(seq = SeqSrc.Literal, lit = base),
      base -> MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
      (base + 1) -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
                       wsel = WSel.Int, intIdx = IntIdx.Temp, we = true),
      (base + 2) -> MW(aSel = ASel.Special, alu = AluOp.PassA,
                       wsel = WSel.Int, intIdx = IntIdx.Aux, we = true),
      (base + 3) -> MW(aSel = ASel.Int, intIdx = IntIdx.Aux,
                       bSel = BSel.Lit, lit = 2, alu = AluOp.And,
                       wsel = WSel.Int, we = true),
      (base + 4) -> MW(aSel = ASel.Int, intIdx = IntIdx.Temp,
                       alu = AluOp.PassA, flag = FlagCtl.Nz),
      (base + 5) -> MW(aSel = ASel.Special, bSel = BSel.Int,
                       intIdx = IntIdx.Aux, alu = AluOp.Or,
                       wsel = WSel.Int, we = true),
      (base + 6) -> MW(cond = Cond.Z, seq = SeqSrc.Literal, lit = finish),
      (base + 7) -> MW(bSel = BSel.Lit, lit = 0, alu = AluOp.Pass,
                       wsel = WSel.Int, intIdx = IntIdx.IReg, we = true),
      (base + 8) -> MW(lit = 15, aux = true),
      (base + 9) -> MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg,
                       alu = AluOp.Add, flag = FlagCtl.Shift, size = 1,
                       vclr = true, wsel = WSel.H8, we = true),
      (base + 10) -> MW(aSel = ASel.Int, bSel = BSel.Int,
                        intIdx = IntIdx.IReg, alu = AluOp.Adc, size = 1,
                        wsel = WSel.Int, we = true),
      (base + 11) -> MW(aSel = ASel.Int, bSel = BSel.Int,
                        intIdx = IntIdx.IReg, alu = AluOp.Sub, size = 1,
                        vclr = true, cond = Cond.AluGe),
      (base + 12) -> MW(cond = Cond.AluGe, seq = SeqSrc.Literal,
                        lit = sub),
      (base + 13) -> MW(cond = Cond.LoopNZ, seq = SeqSrc.Literal,
                        lit = base + 9),
      (base + 14) -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
                        bSel = BSel.Lit, lit = 0xff, alu = AluOp.And, size = 1,
                        wsel = WSel.Int, intIdx = IntIdx.Temp, we = true),
      (base + 15) -> MW(lit = 7, aux = true),
      (base + 16) -> MW(aSel = ASel.Int, bSel = BSel.Int,
                        intIdx = IntIdx.IReg, alu = AluOp.Add, size = 1,
                        wsel = WSel.Int, we = true),
      (base + 17) -> MW(cond = Cond.LoopNZ, seq = SeqSrc.Literal,
                        lit = base + 16),
      (base + 18) -> MW(aSel = ASel.Int, bSel = BSel.Int,
                        intIdx = IntIdx.IReg, alu = AluOp.Or, size = 1,
                        vclr = true, h8Idx = H8Idx.RdReg,
                        wsel = WSel.H8, we = true),
      finish -> retire(MW(aSel = ASel.Int, intIdx = IntIdx.Aux,
                          alu = AluOp.PassA, flag = FlagCtl.LoadCcr)),
      sub -> MW(aSel = ASel.Int, intIdx = IntIdx.IReg, bSel = BSel.Int,
                alu = AluOp.Sub, size = 1, vclr = true,
                wsel = WSel.Int, we = true),
      (sub + 1) -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Lit,
                      lit = 1, alu = AluOp.Or, size = 1, wsel = WSel.H8,
                      we = true),
      (sub + 2) -> MW(seq = SeqSrc.Literal, lit = base + 13)
    )

  /** Routines by ROM address, authored in strict-decode form. Instruction
    * routines sit at ROM[dispatch]; the fetch mainloop and multi-step tails
    * live in upper ROM (>= FetchEntry). Unlisted addresses read as the
    * all-zero word (SeqSrc.Next no-op).
    */
  private val strictProgram: Map[Int, MW] = Map(
    Ucode.Retire -> MW(seq = SeqSrc.Return),
    Ucode.DebugEntry -> debugEntryWord,
    Ucode.FetchEntry ->                       // issue fetch at PC
      MW(bus = BusCtl.Fetch, intIdx = IntIdx.PC),
    (Ucode.FetchEntry + 1) ->                 // PC += 2, then dispatch on the opcode
      MW(aSel = ASel.Int, bSel = BSel.Lit, lit = 2, alu = AluOp.Add,
         wsel = WSel.Int, intIdx = IntIdx.PC, we = true, seq = SeqSrc.Dispatch),
    Ucode.NmiEntry -> nmiEntryWord,
    // Interrupt entry pushes PC and saved CCR, then loads the latched vector.
    Ucode.IrqEntry ->                          // SP -= 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x31) ->               // mem[SP] = PC
      MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Int, intIdx = IntIdx.PC, alu = AluOp.PassA, size = 1),
    (Ucode.FetchEntry + 0x32) ->               // SP -= 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x33) ->               // mem[SP] = saved CCR in high byte
      MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Special, alu = AluOp.PassA, size = 1),
    (Ucode.FetchEntry + 0x34) ->               // PC = latched vector address
      MW(aSel = ASel.Zero, bSel = BSel.Lit, lit = 0x101, alu = AluOp.Pass,
         wsel = WSel.Int, intIdx = IntIdx.PC, we = true),
    (Ucode.FetchEntry + 0x35) ->               // PC = mem[PC]
      MW(bus = BusCtl.Read, intIdx = IntIdx.PC, aSel = ASel.Special, alu = AluOp.PassA,
         size = 1, wsel = WSel.Int, we = true, seq = SeqSrc.Literal,
         lit = Ucode.FetchEntry),

    // NOP (dispatch 0x00): return to fetch
    0x00 -> retire(),

    // ldc #imm8,ccr (dispatch 0x07): CCR := imm8 (I UI H U N Z V C)
    0x07 -> retire(MW(aSel = ASel.Zero, flag = FlagCtl.LoadCcr)),
    0x02 -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x9f),
    (Ucode.FetchEntry + 0x9f) ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
    (Ucode.FetchEntry + 0xa0) ->
      retire(MW(aSel = ASel.Special, alu = AluOp.PassA,
         h8Idx = H8Idx.RdReg, wsel = WSel.H8, we = true)),
    0x03 -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x9d),
    (Ucode.FetchEntry + 0x9d) ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
    (Ucode.FetchEntry + 0x9e) ->
      retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, flag = FlagCtl.LoadCcr)),
    0x04 -> retire(MW(aSel = ASel.Special, bSel = BSel.Imm8,
               alu = AluOp.Or, flag = FlagCtl.LoadCcr)),
    0x05 -> retire(MW(aSel = ASel.Special, bSel = BSel.Imm8,
               alu = AluOp.Xor, flag = FlagCtl.LoadCcr)),
    0x06 -> retire(MW(aSel = ASel.Special, bSel = BSel.Imm8,
               alu = AluOp.And, flag = FlagCtl.LoadCcr)),

    // not.b Rd (0x17): Rd = Rd ^ 0xff, set N/Z clear V
    0x17 -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Lit, lit = 0xff,
               alu = AluOp.Xor, flag = FlagCtl.Nz, wsel = WSel.H8, we = true)),
    // neg.b Rd (m-class 0xD7): Rd = 0 - Rd
    0xd7 -> retire(MW(aSel = ASel.Zero, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Sub,
               flag = FlagCtl.AddSub, wsel = WSel.H8, we = true)),

    // shift/rotate by 1 (left = adder reuse: b=a). vclr forces V=0 except SHAL.
    0x10 -> retire(MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Add,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // shll.b
    0xd0 -> retire(MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Add,
               flag = FlagCtl.Shift, wsel = WSel.H8, we = true)),   // shal.b (V=sign change)
    0x11 -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Shr1,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // shlr.b
    0xd1 -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Shar,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // shar.b
    0x12 -> retire(MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Adc,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // rotxl.b
    0xd2 -> retire(MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Rol,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // rotl.b
    0x13 -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Rorc,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // rotxr.b
    0xd3 -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Ror,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true)),   // rotr.b

    // Memory-bit prefixes build the byte address, read the extension word into
    // IR, read the target byte, then dispatch into the register bit-op routines.
    Ucode.BitPrefixR16 ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
    (Ucode.BitPrefixR16 + 1) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
         wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
         seq = SeqSrc.Literal, lit = Ucode.BitPrefixExt, aux = true),
    Ucode.BitPrefixExt ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.PC, size = 1,
         seq = SeqSrc.Literal, lit = Ucode.BitPrefixPc),
    Ucode.BitPrefixPc ->
      MW(aSel = ASel.Int, intIdx = IntIdx.PC, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Add, size = 1, wsel = WSel.Int, we = true),
    Ucode.BitPrefixGuard ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
    Ucode.BitPrefixRead ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, seq = SeqSrc.Dispatch),

    // Immediate-ALU page (dispatch 0x80|ooo). rd is instr[3:0]; imm8 the 2nd byte.
    // add.b #imm,Rd
    0x80 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Add,
               flag = FlagCtl.AddSub, wsel = WSel.H8, we = true)),
    // addx.b #imm,Rd: Rd = Rd + imm + C (normal Z)
    0x81 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Adc,
               flag = FlagCtl.AddSub, wsel = WSel.H8, we = true)),
    // subx.b #imm,Rd: Rd = Rd - imm - C (sticky Z)
    0x83 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Sbc,
               flag = FlagCtl.StickyZ, wsel = WSel.H8, we = true)),
    // cmp.b #imm,Rd (flags only, no writeback)
    0x82 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Sub,
               flag = FlagCtl.AddSub)),
    // or.b #imm,Rd
    0x84 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Or,
               flag = FlagCtl.Nz, wsel = WSel.H8, we = true)),
    // xor.b #imm,Rd
    0x85 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Xor,
               flag = FlagCtl.Nz, wsel = WSel.H8, we = true)),
    // and.b #imm,Rd
    0x86 -> retire(MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.And,
               flag = FlagCtl.Nz, wsel = WSel.H8, we = true)),
    // mov.b #imm8,Rd (dispatch 0x87): Rd = imm8, set N/Z, clear V
    0x87 -> retire(MW(bSel = BSel.Imm8, alu = AluOp.Pass, wsel = WSel.H8, h8Idx = H8Idx.RdImm,
               we = true, flag = FlagCtl.Nz)),

    // add.b Rs,Rd (dispatch 0x08): stage Rs into TEMP, then Rd = Rd + TEMP
    0x08 -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x10),
    (Ucode.FetchEntry + 0x10) ->
      retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int, intIdx = IntIdx.Temp,
         alu = AluOp.Add, flag = FlagCtl.AddSub, wsel = WSel.H8, we = true)),

    // sub.b Rs,Rd (dispatch 0x18, m-class alias 0xD8): rd = rd - rs. AH=1 ops
    // land at two coarse addresses depending on rs[3]; both route here.
    0x18 -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x11),
    0xd8 -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x11),
    (Ucode.FetchEntry + 0x11) ->
      retire(MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int, intIdx = IntIdx.Temp,
         alu = AluOp.Sub, flag = FlagCtl.AddSub, wsel = WSel.H8, we = true)),

    // mov.w #imm16,Rd (dispatch 0x79, 4-byte): Rd = ext word at PC; then PC += 2
    // (total +4) and fetch. Ext word is natural big-endian data (no byteswap).
    0x79 -> MW(bus = BusCtl.Read, intIdx = IntIdx.PC, aSel = ASel.Special,
               alu = AluOp.PassA, flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg,
               we = true, size = 1, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x40) ->               // PC += 2 (seq=Next avoids the lit clash)
      MW(aSel = ASel.Int, intIdx = IntIdx.PC, bSel = BSel.Lit, lit = 2, alu = AluOp.Add,
         wsel = WSel.Int, we = true),
    (Ucode.FetchEntry + 0x41) -> retire(),

    // mov.b @Rn,Rd (load 0x68) / mov.b Rs,@Rn (store, m-class 0xE8).
    0x68 -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x6e),
    0xe8 -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x6f),
    (Ucode.FetchEntry + 0x6e) ->
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special, alu = AluOp.PassA,
         flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg, we = true)),
    (Ucode.FetchEntry + 0x6f) ->
      retire(MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8, h8Idx = H8Idx.RdReg,
         alu = AluOp.PassA, flag = FlagCtl.Nz)),

    // mov.w @Rn,Rd (load 0x69) / mov.w Rs,@Rn (store, m-class 0xE9). Rn = bit3
    // field (word[6:4]); data reg = rdReg. The first word reads Rn into IREG.
    0x69 -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x50),
    0xe9 -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x51),
    (Ucode.FetchEntry + 0x50) ->               // load: Rd = mem[IREG]
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special, alu = AluOp.PassA,
         flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg, size = 1, we = true)),
    (Ucode.FetchEntry + 0x51) ->               // store: mem[IREG] = Rs (flags from Rs)
      retire(MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8, h8Idx = H8Idx.RdReg,
         alu = AluOp.PassA, flag = FlagCtl.Nz, size = 1)),

    // mov.w @Rn+,Rd (post-inc load 0x6D): addr = Rn (into IREG); Rn += 2; Rd = mem.
    0x6d -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x52),
    (Ucode.FetchEntry + 0x52) ->               // Rn += 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, bSel = BSel.Lit, lit = 2, alu = AluOp.Add,
         size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x53) ->               // Rd = mem[IREG]
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special, alu = AluOp.PassA,
         flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg, size = 1, we = true)),

    // mov.w Rs,@-Rn (pre-dec store, m-class 0xED): stage old Rs, then Rn -= 2.
    0xed -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x54),
    (Ucode.FetchEntry + 0x54) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, bSel = BSel.Lit, lit = 2, alu = AluOp.Sub,
         size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x55) ->
      retire(MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, aSel = ASel.Int, intIdx = IntIdx.Temp,
         alu = AluOp.PassA, flag = FlagCtl.Nz, size = 1)),

    // mov.b @Rn+,Rd (0x6C): addr = Rn; Rn += 1; Rd = mem[old Rn].
    0x6c -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0xa7),
    (Ucode.FetchEntry + 0xa7) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, bSel = BSel.Lit, lit = 1,
         alu = AluOp.Add, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0xa8) ->
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special, alu = AluOp.PassA,
         flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg, we = true)),

    // mov.b Rs,@-Rn (m-class 0xEC): stage old Rs, then Rn -= 1.
    0xec -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.PassA,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0xa9),
    (Ucode.FetchEntry + 0xa9) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, bSel = BSel.Lit, lit = 1,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0xaa) ->
      retire(MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, aSel = ASel.Int, intIdx = IntIdx.Temp,
         alu = AluOp.PassA, flag = FlagCtl.Nz)),

    // mov.b/w @(d16,Rn),Rd: IREG = ext@PC + Rn; then load through IREG.
    0x6e -> MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
               h8Idx = H8Idx.Ptr, alu = AluOp.Add, size = 1,
               wsel = WSel.Int, we = true, seq = SeqSrc.Literal,
               lit = Ucode.FetchEntry + 0x70),
    0x6f -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x82),
    (Ucode.FetchEntry + 0x70) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special, alu = AluOp.PassA,
         flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x71) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special, alu = AluOp.PassA,
         flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg, size = 1, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    0xee -> MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
               h8Idx = H8Idx.Ptr, alu = AluOp.Add, size = 1,
               wsel = WSel.Int, we = true, seq = SeqSrc.Literal,
               lit = Ucode.FetchEntry + 0x7e),
    0xef -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x7f),
    (Ucode.FetchEntry + 0x7e) ->
      MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8,
         h8Idx = H8Idx.RdReg, alu = AluOp.PassA, flag = FlagCtl.Nz,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x7f) ->
      MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x80) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         h8Idx = H8Idx.Ptr, alu = AluOp.Add, size = 1,
         wsel = WSel.Int, we = true, seq = SeqSrc.Literal,
         lit = Ucode.FetchEntry + 0x81),
    (Ucode.FetchEntry + 0x81) ->
      MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8,
         h8Idx = H8Idx.RdReg, alu = AluOp.PassA, flag = FlagCtl.Nz, size = 1,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x82) ->
      MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x83) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         h8Idx = H8Idx.Ptr, alu = AluOp.Add, size = 1,
         wsel = WSel.Int, we = true, seq = SeqSrc.Literal,
         lit = Ucode.FetchEntry + 0x71),

    (Ucode.FetchEntry + 0x84) ->
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, flag = FlagCtl.Nz, h8Idx = H8Idx.RdImm, we = true)),
    (Ucode.FetchEntry + 0x85) ->
      retire(MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8,
         h8Idx = H8Idx.RdImm, alu = AluOp.PassA, flag = FlagCtl.Nz)),
    0x6a -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x86),
    0xea -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x89),
    0x6b -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x8c),
    0xeb -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x8f),
    (Ucode.FetchEntry + 0x86) ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x87) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x88),
    (Ucode.FetchEntry + 0x88) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, flag = FlagCtl.Nz, h8Idx = H8Idx.RdReg, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x89) ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x8a) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x8b),
    (Ucode.FetchEntry + 0x8b) ->
      MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8,
         h8Idx = H8Idx.RdReg, alu = AluOp.PassA, flag = FlagCtl.Nz,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x8c) ->
      MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x8d) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x8e),
    (Ucode.FetchEntry + 0x8e) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, flag = FlagCtl.Nz, h8Idx = H8Idx.RdReg, size = 1, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x8f) ->
      MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x90) ->
      MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x91),
    (Ucode.FetchEntry + 0x91) ->
      MW(bus = BusCtl.Write, intIdx = IntIdx.IReg, aSel = ASel.H8,
         h8Idx = H8Idx.RdReg, alu = AluOp.PassA, flag = FlagCtl.Nz, size = 1,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),

    // Control transfer + stack. Bus ops using H8Idx.Ptr + vclr address SP directly.
    // jmp @Rn (0x59): PC = Rn.
    0x59 -> retire(MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.PC, we = true)),
    // bsr disp8 (0x55): push PC; PC += signext(disp8).
    0x55 -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x60),
    (Ucode.FetchEntry + 0x60) ->               // SP -= 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x61) ->               // mem[SP] = PC (return address)
      MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Int, intIdx = IntIdx.PC, alu = AluOp.PassA, size = 1),
    (Ucode.FetchEntry + 0x62) ->               // PC += signext(disp8)
      retire(MW(aSel = ASel.Int, intIdx = IntIdx.PC, bSel = BSel.Imm8, alu = AluOp.Add,
         size = 1, wsel = WSel.Int, we = true)),
    // rts (0x54): PC = mem[SP]; SP += 2. The final SP+=2 (Lit const) cannot also
    // branch, so it falls through (seq=Next) to a pure jump back to fetch.
    0x54 -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x63),
    (Ucode.FetchEntry + 0x63) ->               // PC = mem[SP]
      MW(bus = BusCtl.Read, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Special, alu = AluOp.PassA, size = 1, wsel = WSel.Int,
         intIdx = IntIdx.PC, we = true),
    (Ucode.FetchEntry + 0x64) ->               // SP += 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Add, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x65) -> retire(),
    // jsr @Rn (0x5D): stage target before SP changes so @SP aliases use old SP.
    0x5d -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, alu = AluOp.PassA, size = 1,
               wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x66),
    (Ucode.FetchEntry + 0x66) ->               // SP -= 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x67) ->               // mem[SP] = PC
      MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Int, intIdx = IntIdx.PC, alu = AluOp.PassA, size = 1),
    (Ucode.FetchEntry + 0x68) ->               // PC = staged Rn
      retire(MW(aSel = ASel.Int, intIdx = IntIdx.IReg, h8Idx = H8Idx.RsReg,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true)),
    // jmp/jsr absolute forms.
    0x5a -> retire(MW(bus = BusCtl.Read, intIdx = IntIdx.PC, aSel = ASel.Special,
               alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true)),
    0x5b -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x9b),
    0x5e -> MW(bus = BusCtl.Read, intIdx = IntIdx.IReg, aSel = ASel.Special,
               alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x93),
    (Ucode.FetchEntry + 0x93) ->
      MW(aSel = ASel.Int, intIdx = IntIdx.PC, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Add, size = 1, wsel = WSel.Int, we = true),
    (Ucode.FetchEntry + 0x94) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x95) ->
      MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Int, intIdx = IntIdx.PC, alu = AluOp.PassA, size = 1),
    (Ucode.FetchEntry + 0x96) ->
      retire(MW(aSel = ASel.Int, intIdx = IntIdx.IReg, h8Idx = H8Idx.RsReg,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true)),
    0x5f -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x97),
    (Ucode.FetchEntry + 0x97) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Sub, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x98) ->
      MW(bus = BusCtl.Write, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Int, intIdx = IntIdx.PC, alu = AluOp.PassA, size = 1),
    (Ucode.FetchEntry + 0x99) ->
      MW(aSel = ASel.Zero, bSel = BSel.Imm8, alu = AluOp.Pass,
         wsel = WSel.Int, intIdx = IntIdx.PC, we = true),
    (Ucode.FetchEntry + 0x9a) ->
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.PC, aSel = ASel.Special,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true)),
    (Ucode.FetchEntry + 0x9b) ->
      MW(aSel = ASel.Zero, bSel = BSel.Imm8, alu = AluOp.Pass,
         wsel = WSel.Int, intIdx = IntIdx.PC, we = true),
    (Ucode.FetchEntry + 0x9c) ->
      retire(MW(bus = BusCtl.Read, intIdx = IntIdx.PC, aSel = ASel.Special,
         alu = AluOp.PassA, size = 1, wsel = WSel.Int, we = true)),

    // rte (0x56): pop CCR (high byte of mem[SP]) then PC; SP += 4.
    0x56 -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x69),
    (Ucode.FetchEntry + 0x69) ->               // CCR = mem[SP][15:8]
      MW(bus = BusCtl.Read, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Special, flag = FlagCtl.LoadCcr),
    (Ucode.FetchEntry + 0x6a) ->               // SP += 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Add, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x6b) ->               // PC = mem[SP]
      MW(bus = BusCtl.Read, h8Idx = H8Idx.Ptr, vclr = true,
         aSel = ASel.Special, alu = AluOp.PassA, size = 1, wsel = WSel.Int,
         intIdx = IntIdx.PC, we = true),
    (Ucode.FetchEntry + 0x6c) ->               // SP += 2
      MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr, vclr = true, bSel = BSel.Lit, lit = 2,
         alu = AluOp.Add, size = 1, wsel = WSel.H8, we = true),
    (Ucode.FetchEntry + 0x6d) -> retire(),

    0x57 -> MW(seq = SeqSrc.Literal, lit = Ucode.Trapa),
    Ucode.Trapa ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
    (Ucode.Trapa + 1) -> MW(seq = SeqSrc.Dispatch, aux = true),

    0x01 -> MW(seq = SeqSrc.Literal, lit = Ucode.Sleep),
    Ucode.Sleep ->
      MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal, lit = Ucode.Retire),
    (Ucode.Sleep + 1) ->                       // wait here until a wake event
      MW(cond = Cond.WordBad, seq = SeqSrc.Literal, lit = Ucode.Sleep + 1),
    (Ucode.Sleep + 2) -> retire(),

    // Bcc shared routine: taken -> PC += signext(disp8); not taken -> fetch.
    // cond nibble drives the CcInstr predicate (evaluated in Core).
    (Ucode.FetchEntry + 0x20) ->
      MW(seq = SeqSrc.Literal, cond = Cond.CcInstr, lit = Ucode.FetchEntry + 0x22),
    (Ucode.FetchEntry + 0x21) -> retire(),
    (Ucode.FetchEntry + 0x22) ->
      retire(MW(aSel = ASel.Int, bSel = BSel.Imm8, intIdx = IntIdx.PC, alu = AluOp.Add,
         wsel = WSel.Int, we = true))
  ) ++ (0x40 to 0x4f).map(a =>
    a -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x20)).toMap ++
    (0x20 to 0x2f).map(a =>
      a -> MW(aSel = ASel.Zero, bSel = BSel.Imm8, alu = AluOp.Pass,
              wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
              seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x84)).toMap ++
    (0x30 to 0x3f).map(a =>
      a -> MW(aSel = ASel.Zero, bSel = BSel.Imm8, alu = AluOp.Pass,
              wsel = WSel.Int, intIdx = IntIdx.IReg, we = true,
              seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x85)).toMap ++
    // reg-reg logical/compare (m-class): or/xor/and set N,Z clear V; cmp no write
    regReg2(0x14, Ucode.FetchEntry + 0x13, AluOp.Or,  FlagCtl.Nz,     true).toMap ++
    regReg2(0x15, Ucode.FetchEntry + 0x14, AluOp.Xor, FlagCtl.Nz,     true).toMap ++
    regReg2(0x16, Ucode.FetchEntry + 0x15, AluOp.And, FlagCtl.Nz,     true).toMap ++
    regReg2(0x1c, Ucode.FetchEntry + 0x16, AluOp.Sub, FlagCtl.AddSub, false).toMap ++
    // reg-reg mov/addx (ooo=0, single dispatch) and subx (m-class)
    regReg2(0x0c, Ucode.FetchEntry + 0x17, AluOp.Pass, FlagCtl.Nz, true, false).toMap ++
    regReg2(0x0e, Ucode.FetchEntry + 0x18, AluOp.Adc, FlagCtl.AddSub, true, false).toMap ++
    regReg2(0x1e, Ucode.FetchEntry + 0x19, AluOp.Sbc, FlagCtl.StickyZ, true).toMap ++
    // word reg-reg ops use rd16=word[2:0], rs16=word[6:4].
    regReg2Word(0x09, Ucode.FetchEntry + 0x72, AluOp.Add, FlagCtl.AddSub, true).toMap ++
    regReg2Word(0x0d, Ucode.FetchEntry + 0x75, AluOp.Pass, FlagCtl.Nz, true).toMap ++
    regReg2Word(0x19, Ucode.FetchEntry + 0x78, AluOp.Sub, FlagCtl.AddSub, true).toMap ++
    regReg2Word(0x1d, Ucode.FetchEntry + 0x7b, AluOp.Sub, FlagCtl.AddSub, false).toMap ++
    bcd().toMap ++
    mulxu(Ucode.Mulxu).toMap ++
    divxu(Ucode.Divxu, Ucode.DivxuSub).toMap ++
    // inc.b / dec.b (N,Z,V; C,H preserved)
    unary1(0x0a, Ucode.FetchEntry + 0x1a, AluOp.Add).toMap ++
    unary1(0x1a, Ucode.FetchEntry + 0x1c, AluOp.Sub).toMap ++
    addsSubs(0x0b, Ucode.FetchEntry + 0xa1, AluOp.Add).toMap ++
    addsSubs(0x1b, Ucode.FetchEntry + 0xa4, AluOp.Sub, mclass = true).toMap ++
    bitDispatchEntries ++
    Map(
      Ucode.BitRegBset -> bitDataExec(AluOp.Or, true, index = IntIdx.Temp),
      Ucode.BitRegBnot -> bitDataExec(AluOp.Xor, true, index = IntIdx.Temp),
      Ucode.BitRegBclr -> bitDataExec(AluOp.And, true,
        clear = true, index = IntIdx.Temp),
      Ucode.BitRegBtst -> bitDataExec(AluOp.And, false,
        flag = FlagCtl.Bit, index = IntIdx.Temp),
      Ucode.BitBstStart -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
        bSel = BSel.Imm8, intIdx = IntIdx.Aux, cond = Cond.IntBit,
        alu = AluOp.And, wsel = WSel.Int, we = true, vclr = true),
      Ucode.BitBstFinish -> retire(MW(aSel = ASel.Int, h8Idx = H8Idx.RdReg,
        bSel = BSel.Imm8, intIdx = IntIdx.Aux, cond = Cond.IntBit,
        alu = AluOp.Or, wsel = WSel.H8, we = true))
    )

  private val fixedEntries = Map(
    Ucode.DebugEntry -> debugEntryWord,
    Ucode.NmiEntry -> nmiEntryWord,
    Ucode.BitBstStart -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg,
      bSel = BSel.Imm8, intIdx = IntIdx.Aux, cond = Cond.IntBit,
      alu = AluOp.And, wsel = WSel.Int, we = true, vclr = true),
    Ucode.BitBstFinish -> retire(MW(aSel = ASel.Int, h8Idx = H8Idx.RdReg,
      bSel = BSel.Imm8, intIdx = IntIdx.Aux, cond = Cond.IntBit,
      alu = AluOp.Or, wsel = WSel.H8, we = true)),
    Ucode.BitPrefixR16 -> MW(cond = Cond.NibbleBad, seq = SeqSrc.Literal,
      lit = Ucode.Retire),
    (Ucode.BitPrefixR16 + 1) -> MW(aSel = ASel.H8, h8Idx = H8Idx.Ptr,
      alu = AluOp.PassA, size = 1, wsel = WSel.Int, intIdx = IntIdx.IReg,
      we = true, seq = SeqSrc.Literal, lit = Ucode.BitPrefixExt, aux = true)) ++
    bitDispatchEntries
  fixedEntries.foreach { case (address, word) =>
    require(strictProgram.get(address).contains(word),
      f"microcode entry 0x$address%03x was overwritten")
  }
  private val debugRange = (Ucode.DebugEntry until
    (Ucode.DebugEntry + Ucode.DebugSlots)).toSet
  require(strictProgram.keySet.intersect(debugRange) == Set(Ucode.DebugEntry),
    "reserved debug microcode range is occupied")
  private val missingTargets = strictProgram.collect {
    case (address, word) if word.seq == SeqSrc.Literal && !strictProgram.contains(word.lit) =>
      f"0x$address%03x -> 0x${word.lit}%03x"
  }
  require(missingTargets.isEmpty,
    s"microcode literal targets are missing: ${missingTargets.toSeq.sorted.mkString(", ")}")
  require(strictProgram.collect {
    case (address, word) if word.seq == SeqSrc.Return && !word.aux => address
  }.toSet == Set(Ucode.Retire), "retire-point encoding is not unique")
  require(strictProgram.collect {
    case (address, word) if word.seq == SeqSrc.Literal && word.aux => address
  }.toSet == Set(0x7e, 0x7f, 0xfe, 0xff, Ucode.BitPrefixR16 + 1),
    "bit-prefix encoding is not unique")
  require(strictProgram.collect {
    case (address, word) if word.bSel == BSel.Lit && (word.lit & 0x100) != 0 =>
      address -> (word.lit & 1)
  } == Map(Ucode.FetchEntry + 0x34 -> 1,
    Ucode.FetchEntry + 0xa2 -> 0, Ucode.FetchEntry + 0xa5 -> 0),
    "special-literal encoding is not unique")

  /** Without strict decode the guard words vanish. A removed word reads as the
    * all-zero no-op, so fall-through chains still work; jumps that entered a
    * routine at its guard are retargeted past it. The sleep wait word also
    * carries Cond.WordBad but branches to itself, so it survives and the
    * freed cond code tests the wake signal.
    */
  private val leanProgram: Map[Int, MW] =
    val guards = strictProgram.collect {
      case (addr, w)
          if (w.cond == Cond.WordBad || w.cond == Cond.NibbleBad) &&
            w.seq == SeqSrc.Literal && w.lit != addr =>
        require(!w.we && w.bus == BusCtl.None && !w.aux,
          f"guard word 0x$addr%03x does more than branch")
        addr
    }.toSet
    def past(target: Int): Int = if guards(target) then past(target + 1) else target
    strictProgram.collect {
      case (addr, w) if !guards(addr) =>
        addr -> (if w.seq == SeqSrc.Literal then w.copy(lit = past(w.lit)) else w)
    }

  def program(strictDecode: Boolean): Map[Int, MW] =
    if strictDecode then strictProgram else leanProgram

  /** Sparse image: only authored addresses; the ROM defaults the rest to zero. */
  def sparse(strictDecode: Boolean): Seq[(Int, BigInt)] =
    program(strictDecode).toSeq.sortBy(_._1).map { case (a, mw) => (a, mw.encode) }
