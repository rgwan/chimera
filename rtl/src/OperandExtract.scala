// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Hardwired field muxes over the instruction register (not ROM). Exposes the
  * operand fields at instr[3:0]/[7:4]/[11:8], the imm8, and the bit index.
  */
class OperandExtractIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val word = Flipped(UInt(parameter.dataWidth))
  val f0   = Aligned(UInt(4)) // instr[3:0]
  val f1   = Aligned(UInt(4)) // instr[7:4]
  val f2   = Aligned(UInt(4)) // instr[11:8]
  val imm8 = Aligned(UInt(8)) // instr[7:0]
  val bit3 = Aligned(UInt(3)) // instr[6:4]

@generator
object OperandExtract
    extends Generator[ChimeraParameter, ChimeraLayers, OperandExtractIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "OperandExtract"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[OperandExtractIO]]
    val w  = io.word.asBits
    io.f0   := w.bits(3, 0).asUInt
    io.f1   := w.bits(7, 4).asUInt
    io.f2   := w.bits(11, 8).asUInt
    io.imm8 := w.bits(7, 0).asUInt
    io.bit3 := w.bits(6, 4).asUInt
