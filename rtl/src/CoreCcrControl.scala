// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreCcrControlIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val size = Flipped(Bool())
  val aSel = Flipped(UInt(2))
  val bitASelInt = Flipped(Bool())
  val bitFlagCtl = Flipped(UInt(3))
  val bitVclr = Flipped(Bool())
  val aluY = Flipped(UInt(parameter.dataWidth))
  val aluH = Flipped(Bool())
  val aluV = Flipped(Bool())
  val aluC = Flipped(Bool())
  val h8Read = Flipped(UInt(parameter.dataWidth))
  val imm8 = Flipped(UInt(8))
  val memData = Flipped(UInt(parameter.dataWidth))
  val oldCcr = Flipped(UInt(8))
  val daaFinal = Flipped(Bool())
  val bcdFinal = Flipped(Bool())
  val divFlagLoad = Flipped(Bool())
  val divCcrByte = Flipped(UInt(8))
  val flagCtl = Aligned(UInt(3))
  val resN = Aligned(Bool())
  val resZ = Aligned(Bool())
  val resH = Aligned(Bool())
  val hwV = Aligned(Bool())
  val hwC = Aligned(Bool())
  val ldWe = Aligned(Bool())
  val ldVal = Aligned(UInt(8))

@generator
object CoreCcrControl
    extends Generator[ChimeraParameter, ChimeraLayers, CoreCcrControlIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreCcrControl"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreCcrControlIO]]
    io.flagCtl := io.bitFlagCtl
    io.resN := io.size.?(io.aluY.asBits.bit(15), io.aluY.asBits.bit(7))
    val bitFlag = io.bitFlagCtl === FlagCtl.Bit.U(3)
    io.resZ := bitFlag.?(io.aluY.asBits.bits(7, 0) === 0.B(8),
      io.size.?(io.aluY.asBits.bits(15, 0) === 0.B(16),
      io.aluY.asBits.bits(7, 0) === 0.B(8)))
    io.resH := bitFlag.?(io.bitASelInt, io.aluH)
    io.hwV := io.bitVclr.?(false.B, io.aluV)
    io.hwC := bitFlag.?(io.aluY.asBits.bit(0), io.aluC)
    io.ldWe := io.bitFlagCtl === FlagCtl.LoadCcr.U(3)

    val ccrRegByte = io.h8Read.asBits.bits(7, 0).asUInt
    val ccrLogicByte = io.aluY.asBits.bits(7, 0).asUInt
    val ccrImmByte = (io.aSel === ASel.Int.U(2)).?(ccrLogicByte,
      (io.aSel === ASel.H8.U(2)).?(ccrRegByte, io.imm8))
    val old = io.oldCcr.asBits
    val bcdC = io.daaFinal.?((old.bit(0) | io.aluC), old.bit(0))
    val bcdCcrByte = (old.bit(7).asBits ## 0.B(1) ## old.bit(5).asBits ##
      0.B(1) ## io.aluY.asBits.bit(7).asBits ##
      (io.aluY.asBits.bits(7, 0) === 0.B(8)).asBits ##
      old.bit(1).asBits ## bcdC.asBits).asUInt
    io.ldVal := (io.aSel === ASel.Mem.U(2)).?(
      io.memData.asBits.bits(15, 8).asUInt,
      io.divFlagLoad.?(io.divCcrByte, io.bcdFinal.?(bcdCcrByte, ccrImmByte)))
