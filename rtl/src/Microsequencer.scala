// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** µPC and next-µPC mux. The ROM address is the next µPC because the ROM data
  * is registered; the internal `cur` register tracks the word being executed.
  */
class MicrosequencerIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock    = Flipped(Clock())
  val reset    = Flipped(Reset())
  val seqSrc   = Flipped(UInt(2))
  val cond     = Flipped(UInt(3))
  val seqAux   = Flipped(Bool())
  val literal  = Flipped(UInt(parameter.upcBits))
  val dispatch = Flipped(UInt(parameter.dispatchBits))
  val condZ    = Flipped(Bool())
  val aluGe    = Flipped(Bool())
  val intBit   = Flipped(Bool())
  val stepEn   = Flipped(Bool())
  val ccTaken  = Flipped(Bool())
  val debugPend = Flipped(Bool())
  val nmiPend  = Flipped(Bool())
  val irqPend  = Flipped(Bool())
  val trapNum  = Flipped(UInt(2))
  val wordBad  = Flipped(Bool())
  val nibbleBad = Flipped(Bool())
  val wakePend = Flipped(Bool())
  val upc      = Aligned(UInt(parameter.upcBits))
  val retire   = Aligned(Bool())
  val irqAck   = Aligned(Bool())
  val trapAck  = Aligned(Bool())
  val trapIndex = Aligned(UInt(2))

@generator
object Microsequencer
    extends Generator[ChimeraParameter, ChimeraLayers, MicrosequencerIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Microsequencer"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicrosequencerIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val cur = RegInit(Ucode.FetchEntry.U(parameter.upcBits))
    val loopCount = RegInit(0.U(4))
    val aluPred = RegInit(false.B)
    val trapPend = RegInit(false.B)
    val trapIndex = RegInit(0.U(2))

    val seqNext = (cur + 1.U(parameter.upcBits)).asBits.bits(parameter.upcBits - 1, 0).asUInt
    val dispatchTarget = (0.B(1) ## io.dispatch.asBits).asUInt
    val trapArm = (io.seqSrc === SeqSrc.Dispatch.U(2)) & io.seqAux
    val retireRequest = (io.seqSrc === SeqSrc.Return.U(2)) & io.seqAux
    val retirePoint = (io.seqSrc === SeqSrc.Return.U(2)) & (!io.seqAux)
    val trapDebug = trapPend & (trapIndex === 2.U(2))
    val debugTake = io.debugPend | trapDebug
    val nmiTake = (!debugTake) & io.nmiPend
    val trapTake = (!debugTake) & (!io.nmiPend) & trapPend
    val irqTake = (!debugTake) & (!io.nmiPend) & (!trapPend) & io.irqPend
    val retireTarget = debugTake.?(Ucode.DebugEntry.U(parameter.upcBits),
      nmiTake.?(Ucode.NmiEntry.U(parameter.upcBits),
        (trapTake | irqTake).?(Ucode.IrqEntry.U(parameter.upcBits),
          Ucode.FetchEntry.U(parameter.upcBits))))

    val pred = Wire(Bool())
    pred := true.B
    when(io.cond === Cond.Z.U(3))(pred := io.condZ)
    when(io.cond === Cond.AluGe.U(3))(pred := aluPred)
    when(io.cond === Cond.IntBit.U(3))(pred := io.intBit)
    when(io.cond === Cond.CcInstr.U(3))(pred := io.ccTaken)
    when(io.cond === Cond.LoopNZ.U(3))(pred := loopCount =/= 0.U(4))
    if parameter.strictDecode then
      when(io.cond === Cond.WordBad.U(3))(pred := io.wordBad)
      when(io.cond === Cond.NibbleBad.U(3))(pred := io.nibbleBad)
    else
      // guards elided: the WordBad code holds the sleep wait loop instead
      when(io.cond === Cond.WordBad.U(3))(pred := !io.wakePend)

    val nxt = Wire(UInt(parameter.upcBits))
    nxt := seqNext
    when(io.seqSrc === SeqSrc.Literal.U(2))(nxt := pred.?(io.literal, seqNext))
    when(io.seqSrc === SeqSrc.Dispatch.U(2))(nxt := dispatchTarget)
    when(trapArm)(nxt := Ucode.Retire.U(parameter.upcBits))
    when(retireRequest)(nxt := Ucode.Retire.U(parameter.upcBits))
    when(retirePoint)(nxt := retireTarget)
    when(io.stepEn)(cur := nxt)

    when(io.stepEn & (io.seqSrc === SeqSrc.Next.U(2)) &
      (io.cond === Cond.AluGe.U(3)))(aluPred := io.aluGe)
    val loopInit = (io.seqSrc === SeqSrc.Next.U(2)) & io.seqAux
    val loopTail = (io.seqSrc === SeqSrc.Literal.U(2)) &
      (io.cond === Cond.LoopNZ.U(3))
    when(io.stepEn & loopInit)(
      loopCount := io.literal.asBits.bits(3, 0).asUInt)
    when(io.stepEn & loopTail & pred)(
      loopCount := (loopCount - 1.U(4)).asBits.bits(3, 0).asUInt)
    when(io.stepEn & trapArm) {
      trapPend := true.B
      trapIndex := io.trapNum
    }
    when(io.stepEn & retirePoint & (trapDebug | trapTake))(
      trapPend := false.B)

    io.upc := io.stepEn.?(nxt, cur)
    io.retire := io.stepEn & retirePoint
    io.irqAck := io.retire & (nmiTake | trapTake | irqTake)
    io.trapAck := io.retire & trapTake
    io.trapIndex := trapIndex
