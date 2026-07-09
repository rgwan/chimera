// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** µPC, next-µPC mux (seq+1 / literal / dispatch / return) and a one-level
  * call/return stack. The ROM address is the next µPC because the ROM data is
  * registered; the internal `cur` register tracks the word being executed.
  */
class MicrosequencerIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock    = Flipped(Clock())
  val reset    = Flipped(Reset())
  val seqSrc   = Flipped(UInt(2))
  val cond     = Flipped(UInt(3))
  val call     = Flipped(Bool())
  val literal  = Flipped(UInt(parameter.upcBits))
  val dispatch = Flipped(UInt(parameter.dispatchBits))
  val condZ    = Flipped(Bool())
  val condC    = Flipped(Bool())
  val busRdy   = Flipped(Bool())
  val ccTaken  = Flipped(Bool())
  val irqPend  = Flipped(Bool())
  val wordRegBad = Flipped(Bool())
  val upc      = Aligned(UInt(parameter.upcBits))
  val irqAck   = Aligned(Bool())     // interrupt call taken this cycle

@generator
object Microsequencer
    extends Generator[ChimeraParameter, ChimeraLayers, MicrosequencerIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Microsequencer"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicrosequencerIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val cur = RegInit(Ucode.FetchEntry.U(parameter.upcBits))
    val ret = RegInit(0.U(parameter.upcBits))

    val seqNext = (cur + 1.U(parameter.upcBits)).asBits.bits(parameter.upcBits - 1, 0).asUInt
    val dispatchTarget = (0.B(1) ## io.dispatch.asBits).asUInt

    val pred = Wire(Bool())
    pred := true.B
    when(io.cond === Cond.Z.U(3))(pred := io.condZ)
    when(io.cond === Cond.C.U(3))(pred := io.condC)
    when(io.cond === Cond.BusRdy.U(3))(pred := io.busRdy)
    when(io.cond === Cond.CcInstr.U(3))(pred := io.ccTaken)
    when(io.cond === Cond.Irq.U(3))(pred := io.irqPend)
    when(io.cond === Cond.WordRegBad.U(3))(pred := io.wordRegBad)

    val nxt = Wire(UInt(parameter.upcBits))
    nxt := seqNext
    when(io.seqSrc === SeqSrc.Literal.U(2))(nxt := pred.?(io.literal, seqNext))
    when(io.seqSrc === SeqSrc.Dispatch.U(2))(nxt := dispatchTarget)
    when(io.seqSrc === SeqSrc.Return.U(2))(nxt := ret)
    cur := nxt

    val doCall = (io.seqSrc === SeqSrc.Literal.U(2)) & io.call & pred
    when(doCall)(ret := seqNext)

    io.upc := nxt
    // Interrupt entry is a conditional JUMP (not a call): the fixed return point
    // lets irq_proc use the call/return stack for register push/pop. Ack fires
    // when that jump is taken.
    io.irqAck := (io.seqSrc === SeqSrc.Literal.U(2)) & (io.cond === Cond.Irq.U(3)) & pred
