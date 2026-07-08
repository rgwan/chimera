// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** H8 general registers R0..R7 (8 x 16, byte-addressable RnH/RnL). 1R1W.
  * `wmask` bit1 = high byte, bit0 = low byte; word write = 0b11.
  */
class H8RegFileIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val raddr = Flipped(UInt(parameter.regIndexBits))
  val rdata = Aligned(UInt(parameter.dataWidth))
  val waddr = Flipped(UInt(parameter.regIndexBits))
  val wdata = Flipped(UInt(parameter.dataWidth))
  val wmask = Flipped(UInt(parameter.wmaskWidth))
  val we    = Flipped(Bool())

@generator
object H8RegFile
    extends Generator[ChimeraParameter, ChimeraLayers, H8RegFileIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "H8RegFile"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[H8RegFileIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val regs = (0 until parameter.regCount).map(_ => RegInit(0.U(parameter.dataWidth)))
    val wd   = io.wdata.asBits
    val wm   = io.wmask.asBits

    regs.zipWithIndex.foreach { case (r, i) =>
      val sel  = io.we & (io.waddr === i.U(parameter.regIndexBits))
      val curr = r.asBits
      val whi  = (sel & wm.bit(1)).?(wd.bits(15, 8), curr.bits(15, 8))
      val wlo  = (sel & wm.bit(0)).?(wd.bits(7, 0), curr.bits(7, 0))
      r := (whi ## wlo).asUInt
    }

    val rd = Wire(UInt(parameter.dataWidth))
    rd := regs(0)
    regs.zipWithIndex.drop(1).foreach { case (r, i) =>
      when(io.raddr === i.U(parameter.regIndexBits))(rd := r)
    }
    io.rdata := rd
