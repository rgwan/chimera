// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreIrqControlIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irq = Flipped(Bool())
  val nmi = Flipped(Bool())
  val irqAck = Flipped(Bool())
  val iFlag = Flipped(Bool())
  val irqPend = Aligned(Bool())
  val irqVectorAddr = Aligned(UInt(parameter.dataWidth))

@generator
object CoreIrqControl
    extends Generator[ChimeraParameter, ChimeraLayers, CoreIrqControlIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreIrqControl"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreIrqControlIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val irqVectorAddr = RegInit(8.U(parameter.dataWidth))
    val irqLatch = RegInit(false.B)
    val nmiLatch = RegInit(false.B)
    val nmiAck = io.irqAck & nmiLatch
    val irqAck = io.irqAck & (!nmiLatch)
    when(io.irqAck)(
      irqVectorAddr := nmiLatch.?(6.U(parameter.dataWidth), 8.U(parameter.dataWidth)))
    when(irqAck)(irqLatch := false.B)
    when(io.irq)(irqLatch := true.B)
    when(nmiAck)(nmiLatch := false.B)
    when(io.nmi)(nmiLatch := true.B)
    io.irqPend := (irqLatch & (!io.iFlag)) | nmiLatch
    io.irqVectorAddr := irqVectorAddr
