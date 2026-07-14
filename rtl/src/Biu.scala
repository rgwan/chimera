// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Microcode-driven bus master. It does not distinguish fetch from data: the
  * caller supplies the address and `busCtl`; the BIU issues one SRAM
  * transaction and reports `rdy`. Big-endian byte lanes: even address = high
  * byte (wmask bit1), odd = low byte (wmask bit0).
  */
class BiuIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val addr   = Flipped(UInt(parameter.addrWidth))
  val wdata  = Flipped(UInt(parameter.dataWidth))
  val busCtl = Flipped(UInt(2))
  val word   = Flipped(Bool()) // 1 = 16-bit access, 0 = byte
  val bus    = Aligned(new SramBus(parameter))
  val rdata  = Aligned(UInt(parameter.dataWidth))
  val rdy    = Aligned(Bool())
  // MMIO debug-register port. Present only with a self-hostable debug feature
  // (hardwareBreakpoint or singleStep). An access whose address falls in the
  // 32-byte dbgBase window is served here, not on the external bus.
  val mmioSel   = Option.when(parameter.mmio)(Aligned(Bool()))
  val mmioWrite = Option.when(parameter.mmio)(Aligned(Bool()))
  val mmioIndex = Option.when(parameter.mmio)(Aligned(UInt(4)))
  val mmioWdata = Option.when(parameter.mmio)(Aligned(UInt(parameter.dataWidth)))
  val mmioWmask = Option.when(parameter.mmio)(Aligned(UInt(parameter.wmaskWidth)))
  val mmioRdata = Option.when(parameter.mmio)(Flipped(UInt(parameter.dataWidth)))
  // The MMIO decode registers `hit` to keep the window compare off the memory-
  // read critical cone, so it needs the core clock. Present only with mmio.
  val clock = Option.when(parameter.mmio)(Flipped(Clock()))
  val reset = Option.when(parameter.mmio)(Flipped(Reset()))

@generator
object Biu extends Generator[ChimeraParameter, ChimeraLayers, BiuIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Biu"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[BiuIO]]

    val isReq    = io.busCtl =/= BusCtl.None.U(2)
    val isWrite  = io.busCtl === BusCtl.Write.U(2)
    val wordAddr = (io.addr.asBits.bits(parameter.addrWidth - 1, 1) ## 0.B).asUInt
    val byteMask = io.addr.asBits.bit(0).?(1.U(parameter.wmaskWidth), 2.U(parameter.wmaskWidth))

    val busWmask = isWrite.?(io.word.?(3.U(parameter.wmaskWidth), byteMask),
      0.U(parameter.wmaskWidth))

    if parameter.mmio then
      given Ref[Clock] = io.clock.get
      given Ref[Reset] = io.reset.get
      // 32-byte MMIO window: constant prefix compare on addr[15:5]. To keep this
      // compare off the memory-read critical cone, the access is served on the
      // cycle AFTER the decode: `hit` suppresses the external request and clears
      // rdy this cycle; a registered `hitReg` then answers rdy and muxes rdata
      // from the trigger register file. MMIO is thus a fixed 1-cycle-wait access,
      // and the read-data mux select (`hitReg`) is a flop, not a live compare.
      val prefix = (parameter.dbgBase & 0xFFFF) >> 5
      val hit = io.addr.asBits.bits(parameter.addrWidth - 1, 5).asUInt ===
        prefix.U(parameter.addrWidth - 5)
      val index = io.addr.asBits.bits(4, 1).asUInt   // half-word slot in window
      val access = isReq & hit
      // hitReg pulses for exactly the serve cycle: set on a fresh access, cleared
      // once served so a stalled multi-cycle microword serves only once.
      val hitReg = RegInit(false.B)
      hitReg := access & (!hitReg)

      io.bus.addr  := wordAddr
      io.bus.wdata := io.wdata
      io.bus.req   := isReq & (!hit)
      io.bus.we    := isWrite
      io.bus.wmask := hit.?(0.U(parameter.wmaskWidth), busWmask)

      // Register writes commit on the serve cycle (hitReg), same as reads settle.
      io.mmioSel.get   := hitReg
      io.mmioWrite.get := isWrite
      io.mmioIndex.get := index
      io.mmioWdata.get := io.wdata
      io.mmioWmask.get := io.word.?(3.U(parameter.wmaskWidth), byteMask)

      io.rdata := hitReg.?(io.mmioRdata.get, io.bus.rdata)
      io.rdy   := hit.?(hitReg, io.bus.rdy)
    else
      io.bus.addr  := wordAddr
      io.bus.wdata := io.wdata
      io.bus.req   := isReq
      io.bus.we    := isWrite
      io.bus.wmask := busWmask

      io.rdata := io.bus.rdata
      io.rdy   := io.bus.rdy
