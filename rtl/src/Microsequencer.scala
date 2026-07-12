// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Two-stage pipeline pointer. `fpc` drives the ROM address (fetch/decode
  * stage F); `xpc` tracks the microword executing in the X stage (ROM data is
  * registered, so F leads X by one cycle). The F-stage inputs steer the next
  * fetch address; the X-stage inputs (`x*`, gated by `xValid`) drive the
  * side effects — retire/ack pulses, aluPred, loopCount and trapPend.
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
  val hazard   = Flipped(Bool())
  val ccTaken  = Flipped(Bool())
  val debugPend = Flipped(Bool())
  val nmiPend  = Flipped(Bool())
  val irqPend  = Flipped(Bool())
  val trapNum  = Flipped(UInt(2))
  val wordBad  = Flipped(Bool())
  val nibbleBad = Flipped(Bool())
  val wakePend = Flipped(Bool())
  // X-stage decoded fields (the executing microword) for side effects.
  val xSeqSrc  = Flipped(UInt(2))
  val xCond    = Flipped(UInt(3))
  val xSeqAux  = Flipped(Bool())
  val xLiteral = Flipped(UInt(parameter.upcBits))
  val upc      = Aligned(UInt(parameter.upcBits))
  val fpc      = Aligned(UInt(parameter.upcBits))
  val xpc      = Aligned(UInt(parameter.upcBits))
  val xValid   = Aligned(Bool())
  val advance  = Aligned(Bool())
  val retire   = Aligned(Bool())
  val irqAck   = Aligned(Bool())
  val trapAck  = Aligned(Bool())
  val trapIndex = Aligned(UInt(2))
  val rteAck   = Aligned(Bool())
  val sleeping = Aligned(Bool())

@generator
object Microsequencer
    extends Generator[ChimeraParameter, ChimeraLayers, MicrosequencerIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Microsequencer"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicrosequencerIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val fpc = RegInit(Ucode.ResetEntry.U(parameter.upcBits))
    // Executing-word pointer (X stage). Named `cur` to keep its historic
    // whitebox-probe name; the F stage leads it by one cycle.
    val cur = RegInit(Ucode.ResetEntry.U(parameter.upcBits))
    val xValidReg = RegInit(false.B)
    val loopCount = RegInit(0.U(4))
    val aluPred = RegInit(false.B)
    val trapPend = RegInit(false.B)
    val trapIndex = RegInit(0.U(2))

    // Advance the pipeline only when the bus is ready and no hazard is pending.
    // stepEn=0 freezes both stages; hazard=1 bubbles X and holds F for one cycle.
    val advance = io.stepEn & (!io.hazard)
    io.advance := advance
    io.xValid := xValidReg

    // ---- F stage: next-fetch address from the decoded F-stage microword. ----
    val seqNext = (fpc + 1.U(parameter.upcBits)).asBits.bits(parameter.upcBits - 1, 0).asUInt
    val dispatchTarget = (0.B(1) ## io.dispatch.asBits).asUInt
    val retireRequest = (io.seqSrc === SeqSrc.Return.U(2)) & io.seqAux
    val retirePoint = (io.seqSrc === SeqSrc.Return.U(2)) & (!io.seqAux)
    val trapArm = (io.seqSrc === SeqSrc.Dispatch.U(2)) & io.seqAux
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
      when(io.cond === Cond.WordBad.U(3))(pred := !io.wakePend)

    val nxt = Wire(UInt(parameter.upcBits))
    nxt := seqNext
    when(io.seqSrc === SeqSrc.Literal.U(2))(nxt := pred.?(io.literal, seqNext))
    when(io.seqSrc === SeqSrc.Dispatch.U(2))(nxt := dispatchTarget)
    // A trap arm and an RTE pop mutate pending / in-service state one microword
    // before the retire redirect resolves it. Route each through a settle word
    // (TrapaDelay / RteRetire) so the mutation is registered before the retire
    // point reaches F — a microcode delay slot in place of a hardware interlock.
    when(trapArm)(nxt := Ucode.TrapaDelay.U(parameter.upcBits))
    when(retireRequest)(nxt := Ucode.Retire.U(parameter.upcBits))
    when(retirePoint)(nxt := retireTarget)

    // Latch the retire-target decision resolved in F so the X-stage ack pulses
    // match the redirect exactly, even when pending state moves between stages.
    val xTakeNmi   = RegInit(false.B)
    val xTakeTrap  = RegInit(false.B)
    val xTakeIrq   = RegInit(false.B)
    val xTakeDebug = RegInit(false.B)

    when(advance) {
      fpc := nxt
      cur := fpc
      xValidReg := true.B
      xTakeNmi   := retirePoint & nmiTake
      xTakeTrap  := retirePoint & trapTake
      xTakeIrq   := retirePoint & irqTake
      xTakeDebug := retirePoint & debugTake
    }
    when(io.stepEn & io.hazard)(xValidReg := false.B)

    io.upc := advance.?(nxt, fpc)
    io.fpc := fpc
    io.xpc := cur

    // ---- X stage: side effects from the executing microword (gated). ----
    // The executing word commits exactly once, when the bus is ready. A hazard
    // stall bubbles the *next* X slot but must not block this word's effects,
    // so xFire ignores `hazard`; bus-wait (stepEn=0) holds it.
    val xFire = io.stepEn & xValidReg
    val xRetirePoint = (io.xSeqSrc === SeqSrc.Return.U(2)) & (!io.xSeqAux)
    val xTrapArm = (io.xSeqSrc === SeqSrc.Dispatch.U(2)) & io.xSeqAux

    when(xFire & (io.xSeqSrc === SeqSrc.Next.U(2)) &
      (io.xCond === Cond.AluGe.U(3)))(aluPred := io.aluGe)
    val xLoopInit = (io.xSeqSrc === SeqSrc.Next.U(2)) & io.xSeqAux
    val xLoopTail = (io.xSeqSrc === SeqSrc.Literal.U(2)) &
      (io.xCond === Cond.LoopNZ.U(3))
    val xLoopTaken = loopCount =/= 0.U(4)
    when(xFire & xLoopInit)(
      loopCount := io.xLiteral.asBits.bits(3, 0).asUInt)
    when(xFire & xLoopTail & xLoopTaken)(
      loopCount := (loopCount - 1.U(4)).asBits.bits(3, 0).asUInt)
    when(xFire & xTrapArm) {
      trapPend := true.B
      trapIndex := io.trapNum
    }
    when(xFire & xRetirePoint & (xTakeDebug | xTakeTrap))(
      trapPend := false.B)

    io.retire := xFire & xRetirePoint
    io.irqAck := io.retire & (xTakeNmi | xTakeTrap | xTakeIrq)
    io.trapAck := io.retire & xTakeTrap
    io.trapIndex := trapIndex
    io.rteAck := xFire & (cur === Ucode.RteEnd.U(parameter.upcBits))

    // Parked in the SLEEP wait word (no bus traffic until a wake event).
    // Registered so it is glitch-free for external clock gating. Sampled from
    // the executing (X) pointer.
    val sleepReg = RegInit(false.B)
    sleepReg := xValidReg & (cur === (Ucode.Sleep + 1).U(parameter.upcBits))
    io.sleeping := sleepReg
