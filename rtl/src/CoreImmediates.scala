// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreImmediatesIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val ir = Flipped(UInt(parameter.dataWidth))
  val imm8 = Flipped(UInt(8))
  val literal = Flipped(UInt(parameter.upcBits))
  val aSel = Flipped(UInt(2))
  val bSel = Flipped(UInt(2))
  val aluOp = Flipped(UInt(4))
  val h8Idx = Flipped(UInt(2))
  val intIdx = Flipped(UInt(2))
  val wsel = Flipped(Bool())
  val regWe = Flipped(Bool())
  val size = Flipped(Bool())
  val irqVectorAddr = Flipped(UInt(parameter.dataWidth))
  val imm8ext = Aligned(UInt(parameter.dataWidth))
  val litConst = Aligned(UInt(parameter.dataWidth))

@generator
object CoreImmediates
    extends Generator[ChimeraParameter, ChimeraLayers, CoreImmediatesIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreImmediates"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreImmediatesIO]]
    val abs8PageAddr = (io.aSel === ASel.Zero.U(2)) & (io.bSel === BSel.Imm8.U(2)) &
      (io.aluOp === AluOp.Pass.U(4)) & io.wsel & io.regWe &
      (io.intIdx === IntIdx.IReg.U(2))
    val vec8Addr = (io.aSel === ASel.Zero.U(2)) & (io.bSel === BSel.Imm8.U(2)) &
      (io.aluOp === AluOp.Pass.U(4)) & io.wsel & io.regWe &
      (io.intIdx === IntIdx.PC.U(2))
    val imm8sign = io.imm8.asBits.bit(7).?(0xff.B(8), 0.B(8))
    val imm8top  = (0xff.B(8) ## io.imm8.asBits).asUInt
    val imm8zero = (0.B(8) ## io.imm8.asBits).asUInt
    io.imm8ext := abs8PageAddr.?(imm8top,
      vec8Addr.?(imm8zero, (imm8sign ## io.imm8.asBits).asUInt))

    val addsSubsLit = (io.bSel === BSel.Lit.U(2)) &
      (io.literal === 0.U(parameter.upcBits)) & io.size &
      io.regWe & (!io.wsel) &
      (io.h8Idx === H8Idx.RdReg.U(2)) &
      ((io.aluOp === AluOp.Add.U(4)) | (io.aluOp === AluOp.Sub.U(4)))
    val addsSubsConst = io.ir.asBits.bit(15).?(2.U(parameter.dataWidth),
      1.U(parameter.dataWidth))
    val irqVectorLit = (io.aSel === ASel.Zero.U(2)) &
      (io.bSel === BSel.Lit.U(2)) &
      (io.aluOp === AluOp.Pass.U(4)) & io.wsel & io.regWe &
      (io.intIdx === IntIdx.PC.U(2)) &
      (io.literal === 8.U(parameter.upcBits))
    io.litConst := addsSubsLit.?(addsSubsConst,
      irqVectorLit.?(io.irqVectorAddr,
        (0.B(8) ## io.literal.asBits.bits(7, 0)).asUInt))
