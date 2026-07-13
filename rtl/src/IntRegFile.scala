// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Microsequencer internal register file: PC, IREG, TEMP and AUX. 1R1W. */
class IntRegFileIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val raddr = Flipped(UInt(2))
  val rdata = Aligned(UInt(parameter.dataWidth))
  val waddr = Flipped(UInt(2))
  val wdata = Flipped(UInt(parameter.dataWidth))
  val we    = Flipped(Bool())
  val pcData = Aligned(UInt(parameter.dataWidth))
  val iregData = Aligned(UInt(parameter.dataWidth))
  val tempData = Aligned(UInt(parameter.dataWidth))
  val auxData = Aligned(UInt(parameter.dataWidth))
  val dbgPc = Aligned(UInt(parameter.dataWidth)) // verify tap
  // Debug-module injection into the AUX flop D-input. Present only with
  // parameter.debug; the field and its priority branch vanish otherwise.
  val dmWe   = Option.when(parameter.debug)(Flipped(Bool()))
  val dmData = Option.when(parameter.debug)(Flipped(UInt(parameter.dataWidth)))

@generator
object IntRegFile
    extends Generator[ChimeraParameter, ChimeraLayers, IntRegFileIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "IntRegFile"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[IntRegFileIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val pc   = RegInit(0.U(parameter.dataWidth))
    val ireg = RegInit(0.U(parameter.dataWidth))
    val temp = RegInit(0.U(parameter.dataWidth))
    val aux  = RegInit(0.U(parameter.dataWidth))

    when(io.we & (io.waddr === 0.U(2)))(pc := io.wdata)
    when(io.we & (io.waddr === 1.U(2)))(ireg := io.wdata)
    when(io.we & (io.waddr === 2.U(2)))(temp := io.wdata)
    (io.dmWe, io.dmData) match
      case (Some(dmWe), Some(dmData)) =>
        when(dmWe)(aux := dmData).otherwise {
          when(io.we & (io.waddr === 3.U(2)))(aux := io.wdata)
        }
      case _ =>
        when(io.we & (io.waddr === 3.U(2)))(aux := io.wdata)

    val rd = Wire(UInt(parameter.dataWidth))
    rd := pc
    when(io.raddr === 1.U(2))(rd := ireg)
    when(io.raddr === 2.U(2))(rd := temp)
    when(io.raddr === 3.U(2))(rd := aux)
    io.rdata := rd
    io.pcData := pc
    io.iregData := ireg
    io.tempData := temp
    io.auxData := aux
    io.dbgPc := pc
