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

    // Adder with carry-in; subtraction feeds ~b and cin=1 from the caller.
    val ci   = io.cin.?(1.U(17), 0.U(17))
    val a17  = (0.B(1) ## a.bits(15, 0)).asUInt
    val b17  = (0.B(1) ## b.bits(15, 0)).asUInt
    val sum  = (a17 + b17 + ci).asBits         // 17-bit
    val addY = sum.bits(15, 0)

    // half-carry: carry out of bit3 (byte) or bit11 (word)
    val loNib = ((0.B(1) ## a.bits(3, 0)).asUInt + (0.B(1) ## b.bits(3, 0)).asUInt +
      io.cin.?(1.U(5), 0.U(5))).asBits
    val hiNib = ((0.B(1) ## a.bits(11, 0)).asUInt + (0.B(1) ## b.bits(11, 0)).asUInt +
      io.cin.?(1.U(13), 0.U(13))).asBits
    io.hout := io.word.?(hiNib.bit(12), loNib.bit(4))

    // carry and signed overflow at the active msb
    val cB = sum.bit(8)
    val cW = sum.bit(16)
    io.cout := io.word.?(cW, cB)
    val vB = (a.bit(7) === b.bit(7)) & (addY.bit(7) =/= a.bit(7))
    val vW = (a.bit(15) === b.bit(15)) & (addY.bit(15) =/= a.bit(15))
    val addV = io.word.?(vW, vB)

    // 1-bit shifts / rotates (byte datapath; H8 shifts are byte)
    val v7   = a.bit(7)
    val v0   = a.bit(0)
    val shl  = a.bits(6, 0) ## 0.B(1)              // logical/arith left
    val shlr = 0.B(1) ## a.bits(7, 1)              // logical right
    val shar = a.bit(7).asBits ## a.bits(7, 1)     // arithmetic right
    val rol  = a.bits(6, 0) ## a.bit(7).asBits
    val ror  = a.bit(0).asBits ## a.bits(7, 1)
    val rolc = a.bits(6, 0) ## io.cin.asBits
    val rorc = io.cin.asBits ## a.bits(7, 1)

    val logic = Wire(UInt(parameter.dataWidth))
    logic := (a & b).asUInt
    when(io.op === AluOp.Or.U(4))(logic := (a | b).asUInt)
    when(io.op === AluOp.Xor.U(4))(logic := (a ^ b).asUInt)
    when(io.op === AluOp.Not.U(4))(logic := (~a).asUInt)
    when(io.op === AluOp.Pass.U(4))(logic := io.b)

    // result mux
    val y = Wire(UInt(parameter.dataWidth))
    y := addY.asUInt
    when(io.op === AluOp.And.U(4))(y := logic)
    when(io.op === AluOp.Or.U(4))(y := logic)
    when(io.op === AluOp.Xor.U(4))(y := logic)
    when(io.op === AluOp.Not.U(4))(y := logic)
    when(io.op === AluOp.Pass.U(4))(y := logic)
    when(io.op === AluOp.Shl1.U(4))(y := shl.asUInt)
    when(io.op === AluOp.Shr1.U(4))(y := shlr.asUInt)
    when(io.op === AluOp.Rol.U(4))(y := rol.asUInt)
    when(io.op === AluOp.Ror.U(4))(y := ror.asUInt)
    when(io.op === AluOp.Rolc.U(4))(y := rolc.asUInt)
    when(io.op === AluOp.Rorc.U(4))(y := rorc.asUInt)
    io.y := y

    // overflow: add/sub give signed overflow; SHAL (Shl1) gives v7^v6; else 0
    val shalV = a.bit(7) =/= a.bit(6)
    val vSel  = Wire(Bool())
    vSel := addV
    when(io.op === AluOp.Shl1.U(4))(vSel := shalV)
    when(io.op === AluOp.And.U(4))(vSel := false.B)
    when(io.op === AluOp.Or.U(4))(vSel := false.B)
    when(io.op === AluOp.Xor.U(4))(vSel := false.B)
    when(io.op === AluOp.Not.U(4))(vSel := false.B)
    io.vout := vSel
