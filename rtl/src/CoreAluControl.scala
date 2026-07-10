// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreAluControlIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val aSel = Flipped(UInt(2))
  val bSel = Flipped(UInt(2))
  val aluOp = Flipped(UInt(4))
  val flagCtl = Flipped(UInt(3))
  val regWe = Flipped(Bool())
  val wsel = Flipped(Bool())
  val size = Flipped(Bool())
  val vclr = Flipped(Bool())
  val bitMemActive = Flipped(Bool())
  val bitOperandSel = Flipped(Bool())
  val bitDataByte = Flipped(UInt(parameter.byteWidth))
  val bitOperandByte = Flipped(UInt(parameter.byteWidth))
  val h8Read = Flipped(UInt(parameter.dataWidth))
  val intRead = Flipped(UInt(parameter.dataWidth))
  val specialRead = Flipped(UInt(parameter.dataWidth))
  val imm8ext = Flipped(UInt(parameter.dataWidth))
  val litConst = Flipped(UInt(parameter.dataWidth))
  val tempData = Flipped(UInt(parameter.dataWidth))
  val aMux = Aligned(UInt(parameter.dataWidth))
  val bMux = Aligned(UInt(parameter.dataWidth))
  val bitCcrOp = Aligned(Bool())
  val bitAluOp = Aligned(UInt(4))
  val bitFlagCtl = Aligned(UInt(3))
  val bitRegWe = Aligned(Bool())
  val bitVclr = Aligned(Bool())

@generator
object CoreAluControl
    extends Generator[ChimeraParameter, ChimeraLayers, CoreAluControlIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreAluControl"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreAluControlIO]]
    io.bitCcrOp := io.bitOperandSel & (io.aSel === ASel.Special.U(2)) &
      (io.flagCtl === FlagCtl.Bit.U(3))
    io.bitAluOp := io.aluOp
    io.bitFlagCtl := io.flagCtl
    io.bitRegWe := io.regWe
    io.bitVclr := io.vclr

    val a = Wire(UInt(parameter.dataWidth))
    a := io.h8Read
    when(io.aSel === ASel.Int.U(2))(a := io.intRead)
    when(io.aSel === ASel.Zero.U(2))(a := 0.U(parameter.dataWidth))
    when(io.aSel === ASel.Special.U(2))(a := io.specialRead)
    when(io.bitMemActive & io.bitOperandSel & (io.aSel === ASel.H8.U(2)))(
      a := (0.B(8) ## io.bitDataByte.asBits).asUInt)
    io.aMux := a

    val b = Wire(UInt(parameter.dataWidth))
    b := io.h8Read
    when(io.bSel === BSel.Imm8.U(2)) {
      b := io.imm8ext
      when(io.bitOperandSel)(b := (0.B(8) ## io.bitOperandByte.asBits).asUInt)
    }
    when(io.bSel === BSel.Int.U(2))(b := io.vclr.?(io.tempData, io.intRead))
    when(io.bSel === BSel.Lit.U(2))(b := io.litConst)
    io.bMux := b
