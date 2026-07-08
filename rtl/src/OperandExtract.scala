// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Hardwired field muxes over the little-endian IR (first byte in [7:0]).
  * Positions are the ISA-word offsets mapped through the BIU byteswap.
  */
class OperandExtractIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val word  = Flipped(UInt(parameter.dataWidth))
  val rdImm = Aligned(UInt(4)) // instr[3:0]   imm-ALU / mov-imm rd
  val rdReg = Aligned(UInt(4)) // instr[11:8]  reg-reg / rd-only rd
  val rsReg = Aligned(UInt(4)) // instr[15:12] reg-reg rs
  val imm8  = Aligned(UInt(8)) // instr[15:8]  imm8 / disp8 / abs8
  val bit3  = Aligned(UInt(3)) // instr[14:12] bit index

@generator
object OperandExtract
    extends Generator[ChimeraParameter, ChimeraLayers, OperandExtractIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "OperandExtract"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[OperandExtractIO]]
    val w  = io.word.asBits
    io.rdImm := w.bits(3, 0).asUInt
    io.rdReg := w.bits(11, 8).asUInt
    io.rsReg := w.bits(15, 12).asUInt
    io.imm8  := w.bits(15, 8).asUInt
    io.bit3  := w.bits(14, 12).asUInt
