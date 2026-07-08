// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Microsequencer internal register file: PC, IREG, TEMP. 1R1W. */
class IntRegFileIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val raddr = Flipped(UInt(2))
  val rdata = Aligned(UInt(parameter.dataWidth))
  val waddr = Flipped(UInt(2))
  val wdata = Flipped(UInt(parameter.dataWidth))
  val we    = Flipped(Bool())
  val dbgPc = Aligned(UInt(parameter.dataWidth)) // verify tap

@generator
object IntRegFile
    extends Generator[ChimeraParameter, ChimeraLayers, IntRegFileIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "IntRegFile"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[IntRegFileIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val pc   = RegInit((parameter.resetVector & ~1).U(parameter.dataWidth))
    val ireg = RegInit(0.U(parameter.dataWidth))
    val temp = RegInit(0.U(parameter.dataWidth))

    when(io.we & (io.waddr === 0.U(2)))(pc := io.wdata)
    when(io.we & (io.waddr === 1.U(2)))(ireg := io.wdata)
    when(io.we & (io.waddr === 2.U(2)))(temp := io.wdata)

    val rd = Wire(UInt(parameter.dataWidth))
    rd := pc
    when(io.raddr === 1.U(2))(rd := ireg)
    when(io.raddr === 2.U(2))(rd := temp)
    io.rdata := rd
    io.dbgPc := pc
