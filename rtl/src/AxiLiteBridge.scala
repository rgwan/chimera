// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*

/** Ready/valid channel. `ready` is driven by the sink, `valid`/`bits` by the
  * source. */
class Decoupled[T <: Data](gen: T) extends Bundle:
  val ready = Flipped(Bool())
  val valid = Aligned(Bool())
  val bits  = Aligned(gen)

class AxiAw(parameter: ChimeraParameter) extends Bundle:
  val addr = Aligned(UInt(parameter.axiAddrW))
  val prot = Aligned(UInt(3))

class AxiW(parameter: ChimeraParameter) extends Bundle:
  val data = Aligned(UInt(parameter.axiDataWidth))
  val strb = Aligned(UInt(parameter.axiStrbW))

class AxiB extends Bundle:
  val resp = Aligned(UInt(2))

class AxiAr(parameter: ChimeraParameter) extends Bundle:
  val addr = Aligned(UInt(parameter.axiAddrW))
  val prot = Aligned(UInt(3))

class AxiR(parameter: ChimeraParameter) extends Bundle:
  val data = Aligned(UInt(parameter.axiDataWidth))
  val resp = Aligned(UInt(2))

/** AXI-Lite master (from this bridge's perspective). Address/data channels are
  * aligned (outgoing); response channels are flipped (incoming). */
class AxiLiteBundle(parameter: ChimeraParameter) extends Bundle:
  val aw = Aligned(new Decoupled(new AxiAw(parameter)))
  val w  = Aligned(new Decoupled(new AxiW(parameter)))
  val b  = Flipped(new Decoupled(new AxiB))
  val ar = Aligned(new Decoupled(new AxiAr(parameter)))
  val r  = Flipped(new Decoupled(new AxiR(parameter)))

/** Bridge IO: the native SRAM master bus appears here as a slave (Flipped), and
  * the bridge presents an AXI-Lite master. */
class SramToAxiLiteIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val bus   = Flipped(new SramBus(parameter))
  val axi   = Aligned(new AxiLiteBundle(parameter))

/** 16-bit SRAM master bus <-> 32-bit AXI-Lite master.
  *
  * The 16-bit core word is placed on one half of the 32-bit AXI word, selected
  * by addr[1]: addr[1]=0 uses the low half (data[15:0], strb[1:0]); addr[1]=1
  * uses the high half (data[31:16], strb[3:2]). The 16-bit core address is
  * zero-extended into the 32-bit AXI address. The 16-bit word is byte-swapped
  * onto the half so the AXI byte image is big-endian like H8 memory (high byte
  * at the lower byte address); WSTRB tracks the swap. Reads extract the half and
  * swap back.
  *
  * Handshake: one outstanding transaction, matching the SRAM contract (core
  * holds req until rdy). A read (req & !we) drives AR then accepts R; a write
  * (req & we) drives AW and W independently, joins on both-accepted, then waits
  * for B. `rdy` pulses on the R / B beat. `prot` is hardwired to 2 (data,
  * non-secure, unprivileged); the SRAM bus carries no fetch/data hint.
  */
@generator
object SramToAxiLite
    extends Generator[ChimeraParameter, ChimeraLayers, SramToAxiLiteIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "SramToAxiLite"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[SramToAxiLiteIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val aw = io.axi.aw
    val w  = io.axi.w
    val b  = io.axi.b
    val ar = io.axi.ar
    val r  = io.axi.r

    val isReq   = io.bus.req
    val isWrite = io.bus.we
    val isRead  = isReq & (!isWrite)

    // 16-bit core address zero-extended into the 32-bit AXI address; the word
    // is naturally aligned (addr[1] selects the half, addr[0] stays with the
    // byte lanes carried by wmask/strb).
    val axiAddr =
      (0.B(parameter.axiAddrW - parameter.addrWidth) ## io.bus.addr.asBits).asUInt
    val highHalf = io.bus.addr.asBits.bit(1)

    // Place the 16-bit datum on the selected 32-bit half, byte-swapped so the
    // high byte (wdata[15:8], the even H8 address) lands on the LOWER AXI byte
    // lane of the half: the AXI byte image is then big-endian, matching H8
    // memory order, so an external AXI peripheral sees the same bytes the core
    // does. Reads swap back.
    val wdata16 = io.bus.wdata.asBits
    val wdata16sw = wdata16.bits(7, 0) ## wdata16.bits(15, 8)
    val wdata32 = highHalf.?((wdata16sw ## 0.B(16)).asUInt,
      (0.B(16) ## wdata16sw).asUInt)
    // wmask bit1=high byte, bit0=low byte; swap to track the byte-swapped lanes.
    val wmaskSw = io.bus.wmask.asBits.bits(0, 0) ## io.bus.wmask.asBits.bits(1, 1)
    val strb32 = highHalf.?((wmaskSw ## 0.B(2)).asUInt,
      (0.B(2) ## wmaskSw).asUInt)

    val prot = 2.U(3)

    // --- Read path ---------------------------------------------------------
    // One outstanding read: AR fires once, then R completes it.
    val readOutstanding = RegInit(false.B)
    val arValid = isRead & (!readOutstanding)
    val arFire  = arValid & ar.ready
    val rFire   = r.valid & (readOutstanding | arFire)
    when(arFire & (!rFire))(readOutstanding := true.B)
    when(rFire)(readOutstanding := false.B)

    ar.valid     := arValid
    ar.bits.addr := axiAddr
    ar.bits.prot := prot
    r.ready      := isRead

    // Extract the selected half, then byte-swap back to the core's big-endian
    // 16-bit word (inverse of the write-side swap).
    val rHalfRaw = highHalf.?(r.bits.data.asBits.bits(31, 16),
      r.bits.data.asBits.bits(15, 0))
    val rHalf = (rHalfRaw.bits(7, 0) ## rHalfRaw.bits(15, 8)).asUInt

    // --- Write path --------------------------------------------------------
    // AW and W accepted independently; join, then wait for B.
    val awDone = RegInit(false.B)
    val wDone  = RegInit(false.B)
    val awValid = isWrite & (!awDone)
    val wValid  = isWrite & (!wDone)
    val awFire  = awValid & aw.ready
    val wFire   = wValid & w.ready
    val bothDone = (awDone | awFire) & (wDone | wFire)
    val bFire    = isWrite & bothDone & b.valid
    // Latch each accepted channel until the response retires the transaction.
    when(awFire & (!bFire))(awDone := true.B)
    when(wFire & (!bFire))(wDone := true.B)
    when(bFire)(awDone := false.B)
    when(bFire)(wDone := false.B)

    aw.valid     := awValid
    aw.bits.addr := axiAddr
    aw.bits.prot := prot
    w.valid      := wValid
    w.bits.data  := wdata32
    w.bits.strb  := strb32
    b.ready      := isWrite & bothDone

    // --- Wait-state to the core -------------------------------------------
    io.bus.rdata := rHalf
    io.bus.rdy   := rFire | bFire
