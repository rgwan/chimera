// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class DivAssistIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val firstOp = Flipped(UInt(8))
  val flagCtl = Flipped(UInt(3))
  val intIdx = Flipped(UInt(2))
  val regWe = Flipped(Bool())
  val wsel = Flipped(Bool())
  val aSel = Flipped(UInt(2))
  val bSel = Flipped(UInt(2))
  val aluOp = Flipped(UInt(4))
  val size = Flipped(Bool())
  val vclr = Flipped(Bool())
  val bitAluOp = Flipped(UInt(4))
  val bitRegWe = Flipped(Bool())
  val oldCcr = Flipped(UInt(8))
  val iregData = Flipped(UInt(parameter.dataWidth))
  val tempData = Flipped(UInt(parameter.dataWidth))
  val h8Data = Flipped(UInt(parameter.dataWidth))
  val flagLoad = Aligned(Bool())
  val step = Aligned(Bool())
  val sub = Aligned(Bool())
  val pack = Aligned(Bool())
  val ccrByte = Aligned(UInt(8))
  val stepData = Aligned(UInt(parameter.dataWidth))
  val packData = Aligned(UInt(parameter.dataWidth))

@generator
object DivAssist extends Generator[ChimeraParameter, ChimeraLayers, DivAssistIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "DivAssist"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[DivAssistIO]]
    val divxuOp = io.firstOp === 0x51.U(8)
    io.flagLoad := divxuOp & (io.flagCtl === FlagCtl.LoadCcr.U(3)) &
      (io.intIdx === IntIdx.Temp.U(2))
    io.step := divxuOp & io.regWe & io.wsel &
      (io.intIdx === IntIdx.IReg.U(2)) &
      (io.aSel === ASel.Int.U(2)) & (io.bSel === BSel.H8.U(2)) &
      (io.aluOp === AluOp.Add.U(4)) & io.size & io.vclr
    io.sub := divxuOp & io.regWe & io.wsel &
      (io.intIdx === IntIdx.IReg.U(2)) &
      (io.aSel === ASel.Int.U(2)) & (io.bSel === BSel.Int.U(2)) &
      (io.aluOp === AluOp.Sub.U(4)) & io.size
    io.pack := divxuOp & io.bitRegWe & (!io.wsel) & io.size &
      (io.aSel === ASel.Int.U(2)) & (io.intIdx === IntIdx.IReg.U(2)) &
      (io.bSel === BSel.H8.U(2)) & (io.bitAluOp === AluOp.Or.U(4))

    val old = io.oldCcr.asBits
    val divisor = io.tempData.asBits.bits(7, 0)
    io.ccrByte := (old.bit(7).asBits ## 0.B(1) ## old.bit(5).asBits ## 0.B(1) ##
      divisor.bit(7).asBits ## (divisor === 0.B(8)).asBits ##
      old.bit(1).asBits ## old.bit(0).asBits).asUInt
    io.stepData := (io.iregData.asBits.bits(parameter.dataWidth - 2, 0) ##
      io.h8Data.asBits.bit(parameter.dataWidth - 1).asBits).asUInt
    io.packData := (io.iregData.asBits.bits(7, 0) ##
      io.h8Data.asBits.bits(7, 0)).asUInt
