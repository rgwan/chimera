// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Split the 36-bit microword into its control fields (see MicroWord). */
class MicroDecodeIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val word    = Flipped(UInt(parameter.uromWidth))
  val literal = Aligned(UInt(parameter.upcBits))
  val seqSrc  = Aligned(UInt(2))
  val cond    = Aligned(UInt(3))
  val aluOp   = Aligned(UInt(4))
  val aSel    = Aligned(UInt(2))
  val bSel    = Aligned(UInt(2))
  val h8Idx   = Aligned(UInt(2))
  val intIdx  = Aligned(UInt(2))
  val wsel    = Aligned(Bool())
  val regWe   = Aligned(Bool())
  val flagCtl = Aligned(UInt(3))
  val busCtl  = Aligned(UInt(2))
  val size    = Aligned(Bool())
  val call    = Aligned(Bool())

@generator
object MicroDecode
    extends Generator[ChimeraParameter, ChimeraLayers, MicroDecodeIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "MicroDecode"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicroDecodeIO]]
    val w  = io.word.asBits
    def f(r: (Int, Int)) = w.bits(r._1, r._2)

    io.literal := f(MicroWord.LITERAL).asUInt
    io.seqSrc  := f(MicroWord.SEQ_SRC).asUInt
    io.cond    := f(MicroWord.COND).asUInt
    io.aluOp   := f(MicroWord.ALU_OP).asUInt
    io.aSel    := f(MicroWord.A_SEL).asUInt
    io.bSel    := f(MicroWord.B_SEL).asUInt
    io.h8Idx   := f(MicroWord.H8_IDX).asUInt
    io.intIdx  := f(MicroWord.INT_IDX).asUInt
    io.wsel    := w.bit(MicroWord.WSEL._1)
    io.regWe   := w.bit(MicroWord.REG_WE._1)
    io.flagCtl := f(MicroWord.FLAG_CTL).asUInt
    io.busCtl  := f(MicroWord.BUS_CTL).asUInt
    io.size    := w.bit(MicroWord.SIZE._1)
    io.call    := w.bit(MicroWord.CALL._1)
