// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** µPC and next-µPC mux. The ROM data is registered, so the ROM address is the
  * next µPC. In the single-cycle datapath (parameter.pipeline off) `cur` tracks
  * the executing word and the F/X pointers and X-stage inputs are unused. In the
  * two-stage pipeline (parameter.pipeline on) `fpc` drives the ROM address (F
  * stage) leading `xpc` by one cycle, and the X-stage inputs (`x*`, gated by
  * `xValid`) drive the side effects — retire/ack pulses, aluPred, loopCount and
  * trapPend.
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
  // Debug-module hold/dispatch. Present only with parameter.debug. While parked
  // in the DebugEntry wait word `dbgReq` steers to the primitive at
  // DebugEntry + DmCmd offset; `dbgResume` retires back to the fetch loop.
  val dbgReq    = Option.when(parameter.debug)(Flipped(Bool()))
  val dbgCmd    = Option.when(parameter.debug)(Flipped(UInt(3)))
  val dbgResume = Option.when(parameter.debug)(Flipped(Bool()))
  // Debugger-present gate: TRAPA#2 routes to DebugEntry only when a DM is active;
  // without it TRAPA#2 stays a normal trap-2 handler dispatch. Present with dm.
  val dmActive  = Option.when(parameter.dm)(Flipped(Bool()))
  // Self-hosted debug trap request: a hardware breakpoint or a single-step fire
  // (no DM present) arms a trap-index-2 pending so it takes the same trap-2 /
  // DebugEntry routing. Present with hardwareBreakpoint or singleStep.
  val hwbpTrap  = Option.when(parameter.hardwareBreakpoint || parameter.singleStep)(
    Flipped(Bool()))
  // Halted (parked in DebugEntry). Present whenever the core can park: a DM halt,
  // a hardware-breakpoint, or a single-step redirect into DebugEntry.
  val halted    = Option.when(
    parameter.dm || parameter.hardwareBreakpoint || parameter.singleStep)(Aligned(Bool()))
  // A fresh DebugEntry park entered from running code via debugPend (a DM halt,
  // hardware breakpoint, single step, or SLEEP-as-swbp) — not a TRAPA#2 re-park
  // and not a debug-primitive return to the park word. Present with dm; the CCR
  // capture keys on this so an injected program-buffer snippet or a mem primitive
  // never overwrites the session's saved CCR.
  val dbgFreshEntry = Option.when(parameter.dm)(Aligned(Bool()))

@generator
object Microsequencer
    extends Generator[ChimeraParameter, ChimeraLayers, MicrosequencerIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Microsequencer"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicrosequencerIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    if parameter.pipeline then {

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
    // TRAPA#2 routes to DebugEntry only when a debugger is present. With a DM the
    // gate is dmActive; a self-hosted build (hardwareBreakpoint, no DM) sends
    // TRAPA#2 to the trap-2 handler instead. An all-off build keeps the original
    // unconditional routing so it stays byte-identical.
    val trapDebug =
      if parameter.dm then trapPend & (trapIndex === 2.U(2)) & io.dmActive.get
      else if parameter.hardwareBreakpoint || parameter.singleStep then trapPend & (trapIndex === 2.U(2)) & false.B
      else trapPend & (trapIndex === 2.U(2))
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
    // A hardware breakpoint arms a trap-index-2 pending so it takes the same
    // trap-2 / DebugEntry redirect as a TRAPA#2. Priority over a same-cycle arm.
    io.hwbpTrap.foreach { hwbp =>
      when(hwbp) {
        trapPend := true.B
        trapIndex := 2.U(2)
      }
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

    // Debug hold is a single-cycle-datapath feature for now; tie the ports off.
    io.halted.foreach(_ := false.B)
    io.dbgFreshEntry.foreach(_ := false.B)

    } else {

    // ---- single-cycle datapath: one `cur` pointer, effects gated by stepEn. ----
    val cur = RegInit(Ucode.ResetEntry.U(parameter.upcBits))
    val loopCount = RegInit(0.U(4))
    val aluPred = RegInit(false.B)
    val trapPend = RegInit(false.B)
    val trapIndex = RegInit(0.U(2))

    // Unused pipeline outputs and X-stage inputs in the non-pipelined config.
    io.fpc := cur
    io.xpc := cur
    io.xValid := true.B
    io.advance := io.stepEn

    val seqNext = (cur + 1.U(parameter.upcBits)).asBits.bits(parameter.upcBits - 1, 0).asUInt
    val dispatchTarget = (0.B(1) ## io.dispatch.asBits).asUInt
    val trapArm = (io.seqSrc === SeqSrc.Dispatch.U(2)) & io.seqAux
    val retireRequest = (io.seqSrc === SeqSrc.Return.U(2)) & io.seqAux
    val retirePoint = (io.seqSrc === SeqSrc.Return.U(2)) & (!io.seqAux)
    // See the pipeline branch: TRAPA#2 -> DebugEntry only with a debugger present;
    // all-off keeps the original routing so it stays byte-identical.
    val trapDebug =
      if parameter.dm then trapPend & (trapIndex === 2.U(2)) & io.dmActive.get
      else if parameter.hardwareBreakpoint || parameter.singleStep then trapPend & (trapIndex === 2.U(2)) & false.B
      else trapPend & (trapIndex === 2.U(2))
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
    when(trapArm)(nxt := Ucode.Retire.U(parameter.upcBits))
    when(retireRequest)(nxt := Ucode.Retire.U(parameter.upcBits))
    when(retirePoint)(nxt := retireTarget)

    // Halted = parked in the DebugEntry wait word. Present whenever the core can
    // park: a DM halt, or a hardware-breakpoint redirect into DebugEntry.
    val parked = cur === Ucode.DebugEntry.U(parameter.upcBits)
    io.halted.foreach(_ := parked)
    // DM hold + dispatch. The park word (DebugEntry) self-loops until a DM
    // command arrives, then jumps to the matching primitive; resume retires to
    // the fetch loop. Everything vanishes when parameter.debug is off.
    if parameter.debug then
      val cmd = io.dbgCmd.get
      val target = Wire(UInt(parameter.upcBits))
      target := Ucode.DebugEntry.U(parameter.upcBits)
      when(cmd === DmCmd.MemRead.U(3))(target := Ucode.DebugMemRead.U(parameter.upcBits))
      when(cmd === DmCmd.MemWrite.U(3))(target := Ucode.DebugMemWrite.U(parameter.upcBits))
      when(cmd === DmCmd.SetPc.U(3))(target := Ucode.DebugSetPc.U(parameter.upcBits))
      when(parked & io.dbgReq.get)(nxt := target)
      // Resume routes through DebugResume (CCR restore) rather than straight to
      // fetch, so a park never leaks the flag perturbation of a program-buffer
      // reg read back into the resumed program.
      when(parked & io.dbgResume.get)(nxt := Ucode.DebugResume.U(parameter.upcBits))

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
    // A hardware breakpoint arms a trap-index-2 pending so it takes the same
    // trap-2 / DebugEntry redirect as a TRAPA#2. Priority over a same-cycle arm.
    io.hwbpTrap.foreach { hwbp =>
      when(hwbp) {
        trapPend := true.B
        trapIndex := 2.U(2)
      }
    }
    when(io.stepEn & retirePoint & (trapDebug | trapTake))(
      trapPend := false.B)

    io.upc := io.stepEn.?(nxt, cur)
    io.retire := io.stepEn & retirePoint
    io.irqAck := io.retire & (nmiTake | trapTake | irqTake)
    io.trapAck := io.retire & trapTake
    io.trapIndex := trapIndex
    // Shared microcode makes RteEnd a literal-jump into RteRetire, so the ack is
    // keyed on the executing pointer rather than a Return microword.
    io.rteAck := io.stepEn & (cur === Ucode.RteEnd.U(parameter.upcBits))
    // A fresh session entry: the retire that redirects to DebugEntry via
    // debugPend (halt / bp / step / sleep-park), excluding a TRAPA#2 re-park
    // (trapDebug) and any debug-primitive return to the park word.
    io.dbgFreshEntry.foreach(_ := io.retire & io.debugPend & (!trapDebug))

    val sleepReg = RegInit(false.B)
    sleepReg := cur === (Ucode.Sleep + 1).U(parameter.upcBits)
    io.sleeping := sleepReg

    }
