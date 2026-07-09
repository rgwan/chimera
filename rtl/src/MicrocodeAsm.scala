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
    call:   Boolean = false,
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
        (if call then BigInt(1) << MicroWord.CALL._2 else BigInt(0)) |
        (if vclr then BigInt(1) << MicroWord.VCLEAR._2 else BigInt(0))

  private def field(w: BigInt, r: (Int, Int)): Int =
    ((w >> r._2) & ((BigInt(1) << (r._1 - r._2 + 1)) - 1)).toInt

  // Round-trip self-check: distinct value in every field survives encode with no
  // overlap. Pinned to an independently computed value. Runs at elaboration.
  private val probe = MW(lit = 0x1ab, seq = 3, cond = 5, alu = 9, aSel = 2, bSel = 3,
    h8Idx = 2, intIdx = 1, wsel = 1, we = true, flag = 4, bus = 3, size = 1, call = true,
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
      field(pw, MicroWord.SIZE) == 1 && field(pw, MicroWord.CALL) == 1 &&
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
      (tail -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int,
                  intIdx = IntIdx.Temp, alu = op, flag = flag, wsel = WSel.H8,
                  we = writes, seq = SeqSrc.Literal, lit = Ucode.FetchEntry))

  /** Single-operand +/-1 (INC/DEC): needs a Lit const, so it cannot also branch
    * in the same word. Jump to an upper routine: op with seq=Next, then a pure
    * jump back to fetch. */
  private def unary1(disp: Int, routine: Int, op: Int): Seq[(Int, MW)] =
    Seq(disp -> MW(seq = SeqSrc.Literal, lit = routine),
        routine -> MW(aSel = ASel.H8, bSel = BSel.Lit, lit = 1, h8Idx = H8Idx.RdReg,
                      alu = op, flag = FlagCtl.Nzv, wsel = WSel.H8, we = true,
                      seq = SeqSrc.Next),
        (routine + 1) -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry))

  /** Routines by ROM address. Instruction routines sit at ROM[dispatch]; the
    * fetch mainloop and multi-step tails live in upper ROM (>= FetchEntry).
    * Unlisted addresses read as the all-zero word (SeqSrc.Next no-op).
    */
  val program: Map[Int, MW] = Map(
    // fetch mainloop
    Ucode.FetchEntry ->                       // issue fetch at PC
      MW(bus = BusCtl.Fetch, intIdx = IntIdx.PC),
    (Ucode.FetchEntry + 1) ->                 // PC += 2, then dispatch on the opcode
      MW(aSel = ASel.Int, bSel = BSel.Lit, lit = 2, alu = AluOp.Add,
         wsel = WSel.Int, intIdx = IntIdx.PC, we = true, seq = SeqSrc.Dispatch),

    // NOP (dispatch 0x00): return to fetch
    0x00 -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // ldc #imm8,ccr (dispatch 0x07): CCR := imm8 (I UI H U N Z V C)
    0x07 -> MW(flag = FlagCtl.LoadCcr, seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // not.b Rd (0x17): Rd = ~Rd, set N/Z clear V
    0x17 -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Not, flag = FlagCtl.Nz,
               wsel = WSel.H8, we = true, seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // neg.b Rd (m-class 0xD7): Rd = 0 - Rd
    0xd7 -> MW(aSel = ASel.Zero, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Sub,
               flag = FlagCtl.AddSub, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // shift/rotate by 1 (left = adder reuse: b=a). vclr forces V=0 except SHAL.
    0x10 -> MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Add,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // shll.b
    0xd0 -> MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Add,
               flag = FlagCtl.Shift, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // shal.b (V=sign change)
    0x11 -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Shr1,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // shlr.b
    0xd1 -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Shar,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // shar.b
    0x12 -> MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Adc,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // rotxl.b
    0xd2 -> MW(aSel = ASel.H8, bSel = BSel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Rol,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // rotl.b
    0x13 -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Rorc,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // rotxr.b
    0xd3 -> MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, alu = AluOp.Ror,
               flag = FlagCtl.Shift, vclr = true, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),   // rotr.b

    // Immediate-ALU page (dispatch 0x80|ooo). rd is instr[3:0]; imm8 the 2nd byte.
    // add.b #imm,Rd
    0x80 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Add,
               flag = FlagCtl.AddSub, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // addx.b #imm,Rd: Rd = Rd + imm + C (normal Z)
    0x81 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Adc,
               flag = FlagCtl.AddSub, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // subx.b #imm,Rd: Rd = Rd - imm - C (sticky Z)
    0x83 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Sbc,
               flag = FlagCtl.StickyZ, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // cmp.b #imm,Rd (flags only, no writeback)
    0x82 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Cmp,
               flag = FlagCtl.AddSub, seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // or.b #imm,Rd
    0x84 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Or,
               flag = FlagCtl.Nz, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // xor.b #imm,Rd
    0x85 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.Xor,
               flag = FlagCtl.Nz, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // and.b #imm,Rd
    0x86 -> MW(aSel = ASel.H8, bSel = BSel.Imm8, h8Idx = H8Idx.RdImm, alu = AluOp.And,
               flag = FlagCtl.Nz, wsel = WSel.H8, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    // mov.b #imm8,Rd (dispatch 0x87): Rd = imm8, set N/Z, clear V
    0x87 -> MW(bSel = BSel.Imm8, alu = AluOp.Pass, wsel = WSel.H8, h8Idx = H8Idx.RdImm,
               we = true, flag = FlagCtl.Nz, seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // add.b Rs,Rd (dispatch 0x08): stage Rs into TEMP, then Rd = Rd + TEMP
    0x08 -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x10),
    (Ucode.FetchEntry + 0x10) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int, intIdx = IntIdx.Temp,
         alu = AluOp.Add, flag = FlagCtl.AddSub, wsel = WSel.H8, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // sub.b Rs,Rd (dispatch 0x18, m-class alias 0xD8): rd = rd - rs. AH=1 ops
    // land at two coarse addresses depending on rs[3]; both route here.
    0x18 -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x11),
    0xd8 -> MW(bSel = BSel.H8, h8Idx = H8Idx.RsReg, alu = AluOp.Pass,
               wsel = WSel.Int, intIdx = IntIdx.Temp, we = true,
               seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x11),
    (Ucode.FetchEntry + 0x11) ->
      MW(aSel = ASel.H8, h8Idx = H8Idx.RdReg, bSel = BSel.Int, intIdx = IntIdx.Temp,
         alu = AluOp.Sub, flag = FlagCtl.AddSub, wsel = WSel.H8, we = true,
         seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // mov.w #imm16,Rd (dispatch 0x79, 4-byte): Rd = ext word at PC; then PC += 2
    // (total +4) and fetch. Ext word is natural big-endian data (no byteswap).
    0x79 -> MW(bus = BusCtl.Read, intIdx = IntIdx.PC, aSel = ASel.Mem,
               alu = AluOp.PassA, flag = FlagCtl.Nz, wsel = WSel.H8, h8Idx = H8Idx.RdReg,
               we = true, size = 1, seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x40),
    (Ucode.FetchEntry + 0x40) ->               // PC += 2 (seq=Next avoids the lit clash)
      MW(aSel = ASel.Int, intIdx = IntIdx.PC, bSel = BSel.Lit, lit = 2, alu = AluOp.Add,
         wsel = WSel.Int, we = true),
    (Ucode.FetchEntry + 0x41) -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry),

    // Bcc shared routine: taken -> PC += signext(disp8); not taken -> fetch.
    // cond nibble drives the CcInstr predicate (evaluated in Core).
    (Ucode.FetchEntry + 0x20) ->
      MW(seq = SeqSrc.Literal, cond = Cond.CcInstr, lit = Ucode.FetchEntry + 0x22),
    (Ucode.FetchEntry + 0x21) -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry),
    (Ucode.FetchEntry + 0x22) ->
      MW(aSel = ASel.Int, bSel = BSel.Imm8, intIdx = IntIdx.PC, alu = AluOp.Add,
         wsel = WSel.Int, we = true, seq = SeqSrc.Literal, lit = Ucode.FetchEntry)
  ) ++ (0x40 to 0x4f).map(a =>
    a -> MW(seq = SeqSrc.Literal, lit = Ucode.FetchEntry + 0x20)).toMap ++
    // reg-reg logical/compare (m-class): or/xor/and set N,Z clear V; cmp no write
    regReg2(0x14, Ucode.FetchEntry + 0x13, AluOp.Or,  FlagCtl.Nz,     true).toMap ++
    regReg2(0x15, Ucode.FetchEntry + 0x14, AluOp.Xor, FlagCtl.Nz,     true).toMap ++
    regReg2(0x16, Ucode.FetchEntry + 0x15, AluOp.And, FlagCtl.Nz,     true).toMap ++
    regReg2(0x1c, Ucode.FetchEntry + 0x16, AluOp.Cmp, FlagCtl.AddSub, false).toMap ++
    // reg-reg mov/addx (ooo=0, single dispatch) and subx (m-class)
    regReg2(0x0c, Ucode.FetchEntry + 0x17, AluOp.Pass, FlagCtl.Nz, true, false).toMap ++
    regReg2(0x0e, Ucode.FetchEntry + 0x18, AluOp.Adc, FlagCtl.AddSub, true, false).toMap ++
    regReg2(0x1e, Ucode.FetchEntry + 0x19, AluOp.Sbc, FlagCtl.StickyZ, true).toMap ++
    // inc.b / dec.b (N,Z,V; C,H preserved)
    unary1(0x0a, Ucode.FetchEntry + 0x1a, AluOp.Add).toMap ++
    unary1(0x1a, Ucode.FetchEntry + 0x1c, AluOp.Sub).toMap

  /** Sparse image: only authored addresses; the ROM defaults the rest to zero. */
  val sparse: Seq[(Int, BigInt)] =
    program.toSeq.sortBy(_._1).map { case (a, mw) => (a, mw.encode) }
