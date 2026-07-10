// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Single ALU: add/sub/logic/compare and 1-bit shift/rotate through carry.
  * No barrel shifter, no multiply/divide. `word` selects the flag/carry
  * boundary (bit15 vs bit7). V and C are raw here; the FlagUnit selects them.
  */
class AluIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val a    = Flipped(UInt(parameter.dataWidth))
  val b    = Flipped(UInt(parameter.dataWidth))
  val cin  = Flipped(Bool())
  val op   = Flipped(UInt(4))
  val word = Flipped(Bool())
  val y    = Aligned(UInt(parameter.dataWidth))
  val cout = Aligned(Bool()) // carry / borrow / shifted-out bit
  val vout = Aligned(Bool()) // signed overflow
  val hout = Aligned(Bool()) // half-carry (bit3->4 byte, bit11->12 word)

@generator
object Alu extends Generator[ChimeraParameter, ChimeraLayers, AluIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Alu"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[AluIO]]
    val a  = io.a.asBits
    val b  = io.b.asBits

    def isOp(c: Int) = io.op === c.U(4)
    val isSub = isOp(AluOp.Sub) | isOp(AluOp.Cmp) | isOp(AluOp.Sbc)
    val isAdd = isOp(AluOp.Add) | isOp(AluOp.Adc)
    val isRol = isOp(AluOp.Rol)

    // Unified adder. Subtract inverts b; carry-in is chosen per op. Left shift is
    // Add(b=a), ROTXL is Adc(b=a), ROTL injects the old bit7 as carry-in so
    // a+a+bit7 = {a[6:0], a[7]}.
    val bEff = isSub.?((~b), b)
    val cinEff = Wire(Bool())
    cinEff := false.B
    when(isOp(AluOp.Adc))(cinEff := io.cin)
    when(isOp(AluOp.Sub) | isOp(AluOp.Cmp))(cinEff := true.B)
    when(isOp(AluOp.Sbc))(cinEff := !io.cin)
    when(isRol)(cinEff := a.bit(7))

    val ci   = cinEff.?(1.U(17), 0.U(17))
    val a17  = (0.B(1) ## a.bits(15, 0)).asUInt
    val be17 = (0.B(1) ## bEff.bits(15, 0)).asUInt
    val sum  = (a17 + be17 + ci).asBits            // 17-bit
    val addY = sum.bits(15, 0)

    val byteCarry = sum.bit(8) ^ a.bit(8) ^ bEff.bit(8)
    val rawC = io.word.?(sum.bit(16), byteCarry)
    val arithC = isSub.?((!rawC), rawC)            // borrow = ~carry on subtract
    // signed overflow via bEff (correct for both add and sub)
    val vB = (a.bit(7) === bEff.bit(7)) & (addY.bit(7) =/= a.bit(7))
    val vW = (a.bit(15) === bEff.bit(15)) & (addY.bit(15) =/= a.bit(15))
    val arithV = io.word.?(vW, vB)
    val byteHalf = sum.bit(4) ^ a.bit(4) ^ bEff.bit(4)
    val wordHalf = sum.bit(12) ^ a.bit(12) ^ bEff.bit(12)
    val rawH = io.word.?(wordHalf, byteHalf)
    io.hout := isSub.?((!rawH), rawH)              // half-borrow = ~carry on subtract

    // right shift / rotate keep a dedicated 1-bit path (byte datapath)
    val shlr = 0.B(1) ## a.bits(7, 1)              // logical right
    val shar = a.bit(7).asBits ## a.bits(7, 1)     // arithmetic right
    val ror  = a.bit(0).asBits ## a.bits(7, 1)
    val rorc = io.cin.asBits ## a.bits(7, 1)

    val logic = Wire(UInt(parameter.dataWidth))
    logic := (a & b).asUInt
    when(isOp(AluOp.Or))(logic := (a | b).asUInt)
    when(isOp(AluOp.Xor))(logic := (a ^ b).asUInt)
    when(isOp(AluOp.Not))(logic := (~a).asUInt)
    when(isOp(AluOp.Pass))(logic := io.b)
    when(isOp(AluOp.PassA))(logic := io.a)

    // result: adder ops (add/sub/adc/sbc/cmp and rol) default to addY
    val y = Wire(UInt(parameter.dataWidth))
    y := addY.asUInt
    when(isOp(AluOp.And) | isOp(AluOp.Or) | isOp(AluOp.Xor) | isOp(AluOp.Not) |
      isOp(AluOp.Pass) | isOp(AluOp.PassA))(y := logic)
    when(isOp(AluOp.Shar))(y := shar.asUInt)
    when(isOp(AluOp.Shr1))(y := shlr.asUInt)
    when(isOp(AluOp.Ror))(y := ror.asUInt)
    when(isOp(AluOp.Rorc))(y := rorc.asUInt)
    io.y := y

    // carry-out: add carry / sub borrow / rol carry (old bit7) / right shift-out
    val cout = Wire(Bool())
    cout := a.bit(0)                               // right shift/rotate default
    when(isAdd | isRol)(cout := rawC)
    when(isSub)(cout := arithC)
    io.cout := cout

    // overflow: only add/sub set it; shifts/rotates/logic force V=0
    io.vout := (isAdd | isSub).?(arithV, false.B)
