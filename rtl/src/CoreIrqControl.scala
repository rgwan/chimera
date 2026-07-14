// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Pending latches, service-state bits, and the vector address, laid out per
  * the platform table: NMI 0x0E, TRAPA 0x10+2t, IRQ 0x18+2i, all offset by
  * vtBase<<8. A running IRQ blocks new IRQs until its RTE; NMI may preempt
  * and its RTE pops back into the interrupted IRQ flow.
  */
class CoreIrqControlIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irq = Flipped(Bool())
  val nmi = Flipped(Bool())
  val irqNumber = Flipped(UInt(parameter.irqNumberWidth))
  val vtBase = Flipped(UInt(8))
  val irqAck = Flipped(Bool())
  val trapAck = Flipped(Bool())
  val trapIndex = Flipped(UInt(2))
  val rteAck = Flipped(Bool())
  val iFlag = Flipped(Bool())
  val nmiPend = Aligned(Bool())
  val irqPend = Aligned(Bool())
  val irqVectorAddr = Aligned(UInt(parameter.dataWidth))
  // High while an NMI or IRQ is in service. The trap-2 suppression FSM uses it
  // to distinguish a nested NMI/IRQ RTE from the trap-2 handler's own RTE.
  // Present only with a self-hosted debug feature so an all-off build is
  // byte-identical.
  val serviceActive = Option.when(
    parameter.hardwareBreakpoint || parameter.singleStep)(Aligned(Bool()))

@generator
object CoreIrqControl
    extends Generator[ChimeraParameter, ChimeraLayers, CoreIrqControlIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreIrqControl"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreIrqControlIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val irqVectorAddr = RegInit(0.U(parameter.dataWidth))
    val irqLatch = RegInit(false.B)
    val nmiLatch = RegInit(false.B)
    val irqActive = RegInit(false.B)
    val nmiActive = RegInit(false.B)

    val nmiAck = io.irqAck & (!io.trapAck) & nmiLatch
    val irqAcc = io.irqAck & (!io.trapAck) & (!nmiLatch)

    val low = Wire(UInt(8))
    val w = parameter.irqNumberWidth
    val irqOff = (0.B(7 - w) ## io.irqNumber.asBits ## 0.B(1)).asUInt
    val irqLow = (0x18.U(8) + irqOff).asBits.bits(7, 0).asUInt
    low := irqLow
    when(io.trapAck)(
      low := (0.B(3) ## 1.B(1) ## 0.B(1) ## io.trapIndex.asBits ## 0.B(1)).asUInt)
    when((!io.trapAck) & nmiLatch)(low := 0x0e.U(8))
    when(io.irqAck)(irqVectorAddr := (io.vtBase.asBits ## low.asBits).asUInt)

    when(irqAcc) {
      irqLatch := false.B
      irqActive := true.B
    }
    when(io.irq)(irqLatch := true.B)
    when(nmiAck) {
      nmiLatch := false.B
      nmiActive := true.B
    }
    when(io.nmi)(nmiLatch := true.B)
    // RTE pops the innermost service level: NMI first, then IRQ.
    when(io.rteAck)(
      when(nmiActive)(nmiActive := false.B).otherwise(irqActive := false.B))

    io.nmiPend := nmiLatch & (!nmiActive)
    io.irqPend := irqLatch & (!io.iFlag) & (!irqActive) & (!nmiActive)
    io.irqVectorAddr := irqVectorAddr
    io.serviceActive.foreach(_ := nmiActive | irqActive)
