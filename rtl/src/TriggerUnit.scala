// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Hardware-breakpoint / trigger unit. Present only with
  * parameter.hardwareBreakpoint. Holds `hwBreakpointCount` comparator units and
  * their MMIO registers; the Biu decodes the dbgBase window and drives the
  * register port here (index by addr[4:1]). Both the core and any DM reach the
  * registers through that one decode.
  *
  * Register map (16-bit words indexed by addr[4:1] within the 32-byte window):
  *   word 0     (byte 0x0)  STEP     reserved for single-step (P4), reads 0 here
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
  val retire      = Flipped(Bool())          // rearm point
  // MMIO register port from the Biu decode.
  val mmioSel   = Flipped(Bool())            // an in-window access this cycle
  val mmioWrite = Flipped(Bool())            // 1 = write, 0 = read
  val mmioIndex = Flipped(UInt(4))           // addr[4:1] word index
  val mmioWdata = Flipped(UInt(parameter.dataWidth))
  val mmioWmask = Flipped(UInt(parameter.wmaskWidth))
  val mmioRdata = Aligned(UInt(parameter.dataWidth))
  // Redirect outputs (registered).
  val hwbpFire = Aligned(Bool())
  val hwbpKind = Aligned(Bool())             // 0 = instruction, 1 = data

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

    // Latch-once arm/pend: set on the first fire, rearm at retire.
    when(anyFire & (!hwbpArmed)) {
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
