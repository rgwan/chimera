// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Hardware-breakpoint / single-step MMIO block. Present whenever a self-hosted
  * debug feature owns the dbgBase window (parameter.mmio). Holds the single-step
  * control register, `hwBreakpointCount` comparator units, and their MMIO
  * registers; the Biu decodes the dbgBase window and drives the register port
  * here (index by addr[4:1]). Both the core and any DM reach the registers
  * through that one decode.
  *
  * Register map (16-bit words indexed by addr[4:1] within the 32-byte window):
  *   word 0     (byte 0x0)  STEP  single-step control + capability read:
  *                            [0]    EN       arm the step; a retire raises
  *                                            stepFire (parameter.singleStep)
  *                            [1]    ONESHOT  1 = self-clear EN after one step,
  *                                            0 = continuous (re-fires each retire)
  *                            [2]    PEND     W1C sticky "a step fired" (self-
  *                                            hosted handler polls / clears it)
  *                            [7:3]  reserved (read 0)
  *                            [11:8] HWBPCOUNT  read-only hwBreakpointCount, so a
  *                                            self-hosted program (no JTAG STATUS
  *                                            DR) discovers the breakpoint count
  *                                            with one MMIO load
  *                            [15:12] reserved (read 0)
  *                            Writes touch only the low-byte control bits.
  *   words 1-3  (byte 0x2)  reserved gap
  *   per unit i (byte 0x8 + i*4):
  *     word 4+2i  ADDR  16-bit compare address
  *     word 5+2i  CTL   [0]=EN [1]=TYPE(0=instr,1=data) [2]=RD [3]=WR
  *   word 4+2N  (after the last unit)  HWBP_STAT  W1C fired bits [N-1:0]
  *
  * Comparators:
  *   instruction bp: compares the fetch address (busAddr, qualified by
  *     doFetch & biu.rdy), fires BEFORE execution.
  *   data bp: compares the data-access address (biu.addr, qualified by
  *     bus.rdy and RD/WR select), fires AFTER the access.
  * Every comparator output is registered (ibFire/dbFire flops) so nothing lands
  * on the fetch / bus critical path. A latch-once arm/pend fires the unit once
  * per instruction and rearms at retire (so RMW / multi-byte accesses fire once).
  * `hwbpFire` (registered) and `hwbpKind` (0=instr, 1=data) drive the redirect.
  * `stepFire` (registered) fires one retire after a step is armed and routes like
  * a hardware-breakpoint fire (DebugEntry when a DM is present, else TRAP#2).
  */
class TriggerUnitIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  // Comparator inputs from the core datapath.
  val fetchAddr   = Flipped(UInt(parameter.addrWidth))
  val fetchValid  = Flipped(Bool())          // doFetch & biu.rdy
  val dataAddr    = Flipped(UInt(parameter.addrWidth))
  val dataRead    = Flipped(Bool())          // read access completing this cycle
  val dataWrite   = Flipped(Bool())          // write access completing this cycle
  val retire      = Flipped(Bool())          // rearm point / step boundary
  // Suppress step + bp fires while a self-hosted TRAP#2 debug handler runs.
  val suppress    = Flipped(Bool())
  // MMIO register port from the Biu decode.
  val mmioSel   = Flipped(Bool())            // an in-window access this cycle
  val mmioWrite = Flipped(Bool())            // 1 = write, 0 = read
  val mmioIndex = Flipped(UInt(4))           // addr[4:1] word index
  val mmioWdata = Flipped(UInt(parameter.dataWidth))
  val mmioWmask = Flipped(UInt(parameter.wmaskWidth))
  val mmioRdata = Aligned(UInt(parameter.dataWidth))
  // A write into any MMIO debug register (for the trap-2 restore policy).
  val mmioTouched = Aligned(Bool())
  // Redirect outputs (registered).
  val hwbpFire = Aligned(Bool())
  val hwbpKind = Aligned(Bool())             // 0 = instruction, 1 = data
  // Single-step redirect (registered). Present with parameter.singleStep.
  val stepFire = Option.when(parameter.singleStep)(Aligned(Bool()))

@generator
object TriggerUnit
    extends Generator[ChimeraParameter, ChimeraLayers, TriggerUnitIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "TriggerUnit"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[TriggerUnitIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val n  = parameter.hwBreakpointCount
    val dw = parameter.dataWidth
    val aw = parameter.addrWidth

    // Word index of each register within the 32-byte window (addr[4:1]).
    val stepIdx = 0
    def addrIdx(i: Int) = 4 + 2 * i
    def ctlIdx(i: Int)  = 5 + 2 * i
    val statIdx = 4 + 2 * n

    def selIdx(k: Int) = io.mmioSel & (io.mmioIndex === k.U(4))
    val wm = io.mmioWmask.asBits
    val wd = io.mmioWdata.asBits

    // Any write into the window is a debug-register touch (trap-2 restore policy).
    io.mmioTouched := io.mmioSel & io.mmioWrite

    // STEP register low-byte control bits (word 0), 0 when single-step is absent.
    val stepCtl = Wire(UInt(parameter.byteWidth))
    stepCtl := 0.U(parameter.byteWidth)

    // ---- single-step control register (word 0). ----
    // stepEnReg / stepOneShot arm the step; stepPend is the W1C sticky witness.
    // A fire happens one retire after arming, is gated by `suppress`, and (in
    // one-shot mode) self-clears EN so the handler re-arms per step.
    if parameter.singleStep then
      val stepFireR    = RegInit(false.B)
      val stepEnReg    = RegInit(false.B)
      val stepOneShot  = RegInit(false.B)
      val stepPend     = RegInit(false.B)
      val selStep = selIdx(stepIdx) & io.mmioWrite & wm.bit(0)
      // A step boundary is a retire while armed and not suppressed.
      val stepBoundary = stepEnReg & io.retire & (!io.suppress)
      stepFireR := stepBoundary
      // EN next: a host write wins; otherwise a one-shot fire self-clears it.
      val enSelfClear = stepBoundary & stepOneShot
      val enNext = selStep.?(wd.bit(0), enSelfClear.?(false.B, stepEnReg))
      stepEnReg := enNext
      when(selStep)(stepOneShot := wd.bit(1))
      // PEND: set on a fire, W1C by a host write of bit2.
      val clrPend = selStep & wd.bit(2)
      stepPend := (stepBoundary | stepPend) & (!clrPend)
      io.stepFire.get := stepFireR
      // Low-byte control read-back; the count field is added in the read mux.
      stepCtl := (0.B(parameter.byteWidth - 3) ##
        stepPend.asBits ## stepOneShot.asBits ## stepEnReg.asBits).asUInt

    // Per-unit registers. ADDR is 16-bit; CTL keeps four control bits.
    val addrRegs = (0 until n).map(_ => RegInit(0.U(aw)))
    val ctlRegs  = (0 until n).map(_ => RegInit(0.U(4)))
    val statBits = (0 until n).map(_ => RegInit(false.B))  // W1C fired bits

    // Registered comparator fire flops (one per unit, split instr/data).
    val ibFire = (0 until n).map(_ => RegInit(false.B))
    val dbFire = (0 until n).map(_ => RegInit(false.B))

    // Latch-once: hold the first fire until retire rearms.
    val hwbpArmed = RegInit(false.B)
    val hwbpPend  = RegInit(false.B)
    val hwbpKindR = RegInit(false.B)

    // ---- MMIO register writes (byte-masked; STAT is W1C). ----
    // Combinational next-value with a single register assign (no nested-when
    // register write), mirroring the H8 register file. CTL lives in the low byte.
    (0 until n).foreach { i =>
      val selA = selIdx(addrIdx(i)) & io.mmioWrite
      val cur  = addrRegs(i).asBits
      val whi  = (selA & wm.bit(1)).?(wd.bits(15, 8), cur.bits(15, 8))
      val wlo  = (selA & wm.bit(0)).?(wd.bits(7, 0), cur.bits(7, 0))
      addrRegs(i) := (whi ## wlo).asUInt

      val selC = selIdx(ctlIdx(i)) & io.mmioWrite & wm.bit(0)
      ctlRegs(i) := selC.?(wd.bits(3, 0).asUInt, ctlRegs(i))
    }

    // ---- Comparators (combinational match, registered fire). ----
    // Fire set flops sample the match qualified by the access this cycle; they
    // clear on the next cycle unless re-matched, and feed the latch-once logic.
    (0 until n).foreach { i =>
      val en   = ctlRegs(i).asBits.bit(0)
      val isData = ctlRegs(i).asBits.bit(1)
      val rd   = ctlRegs(i).asBits.bit(2)
      val wr   = ctlRegs(i).asBits.bit(3)
      val instrMatch = en & (!isData) & io.fetchValid & (io.fetchAddr === addrRegs(i))
      val accessSel  = (rd & io.dataRead) | (wr & io.dataWrite)
      val dataMatch  = en & isData & accessSel & (io.dataAddr === addrRegs(i))
      ibFire(i) := instrMatch
      dbFire(i) := dataMatch
    }

    // Aggregate fire (from the registered flops) for the latch-once machine.
    val anyIb = if n == 0 then (false.B: Referable[Bool])
      else (0 until n).map(ibFire(_): Referable[Bool]).reduce(_ | _)
    val anyDb = if n == 0 then (false.B: Referable[Bool])
      else (0 until n).map(dbFire(_): Referable[Bool]).reduce(_ | _)
    val anyFire = anyIb | anyDb

    // W1C fired-bit status: set on the registered fire, cleared by a W1C write.
    (0 until n).foreach { i =>
      val fired = ibFire(i) | dbFire(i)
      val clr = selIdx(statIdx) & io.mmioWrite & wd.bit(i)
      statBits(i) := (fired | statBits(i)) & (!clr)
    }

    // Latch-once arm/pend: set on the first fire, rearm at retire. A fire while
    // a self-hosted trap-2 handler runs is suppressed (does not pend a redirect),
    // so the handler's own execution never re-triggers its debug features.
    when(anyFire & (!hwbpArmed) & (!io.suppress)) {
      hwbpArmed := true.B
      hwbpPend  := true.B
      hwbpKindR := anyDb & (!anyIb)   // instruction bp wins a tie (fires first)
    }
    when(io.retire) {
      hwbpArmed := false.B
      hwbpPend  := false.B
    }

    io.hwbpFire := hwbpPend
    io.hwbpKind := hwbpKindR

    // ---- MMIO read mux (index by addr[4:1]). ----
    val rd = Wire(UInt(dw))
    rd := 0.U(dw)
    // STEP word: [15:12]=0, [11:8]=hwBreakpointCount (capability), [7:0]=control.
    val stepReadWord = (0.B(4) ## n.U(4).asBits ## stepCtl.asBits).asUInt
    when(io.mmioIndex === stepIdx.U(4))(rd := stepReadWord)
    (0 until n).foreach { i =>
      when(io.mmioIndex === addrIdx(i).U(4))(rd := addrRegs(i))
      when(io.mmioIndex === ctlIdx(i).U(4))(
        rd := (0.B(dw - 4) ## ctlRegs(i).asBits).asUInt)
    }
    if n > 0 then
      val statWord = (0 until n).reverse.map(statBits(_).asBits).reduce(_ ## _)
      when(io.mmioIndex === statIdx.U(4))(
        rd := (0.B(dw - n) ## statWord).asUInt)
    io.mmioRdata := rd
