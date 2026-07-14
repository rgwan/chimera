// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*

/** AXI-Lite top: the Core plus the SRAM-to-AXI-Lite bridge, exposing a 32-bit
  * AXI-Lite master instead of the native SRAM bus. When debug is on the JTAG DTM
  * is carried too, mirroring CoreTop.
  */
class CoreTopAxiIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irq   = Flipped(Bool())
  val nmi   = Flipped(Bool())
  val irq_number = Flipped(UInt(parameter.irqNumberWidth))
  val vt_base = Flipped(UInt(8))
  val axil  = Aligned(new AxiLiteBundle(parameter))
  val core_sleeping = Aligned(Bool())
  val is_halted = Option.when(parameter.dm || parameter.hardwareBreakpoint)(Aligned(Bool()))
  // JTAG pins, present only with debug.
  val tck  = Option.when(parameter.debug)(Flipped(Clock()))
  val trst = Option.when(parameter.debug)(Flipped(Reset()))
  val tms  = Option.when(parameter.debug)(Flipped(Bool()))
  val tdi  = Option.when(parameter.debug)(Flipped(Bool()))
  val tdo  = Option.when(parameter.debug)(Aligned(Bool()))

@generator
object CoreTopAxi
    extends Generator[ChimeraParameter, ChimeraLayers, CoreTopAxiIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreTopAxi"

  def architecture(parameter: ChimeraParameter) =
    require(parameter.axilite, "CoreTopAxi is the AXI-Lite top; build with axilite=true")
    val io = summon[Interface[CoreTopAxiIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val core   = Core.instantiate(parameter)
    val bridge = SramToAxiLite.instantiate(parameter)

    core.io.clock := io.clock
    core.io.reset := io.reset
    core.io.irq   := io.irq
    core.io.nmi   := io.nmi
    core.io.irq_number := io.irq_number
    core.io.vt_base := io.vt_base
    io.core_sleeping := core.io.core_sleeping
    (io.is_halted, core.io.is_halted) match
      case (Some(top), Some(c)) => top := c
      case _                    => ()

    // Core native SRAM bus -> bridge slave side.
    bridge.io.clock := io.clock
    bridge.io.reset := io.reset
    bridge.io.bus.addr  := core.io.bus.addr
    bridge.io.bus.wdata := core.io.bus.wdata
    bridge.io.bus.we    := core.io.bus.we
    bridge.io.bus.wmask := core.io.bus.wmask
    bridge.io.bus.req   := core.io.bus.req
    core.io.bus.rdata := bridge.io.bus.rdata
    core.io.bus.rdy   := bridge.io.bus.rdy

    // Bridge AXI-Lite master -> top pins.
    io.axil.aw.valid     := bridge.io.axi.aw.valid
    io.axil.aw.bits.addr := bridge.io.axi.aw.bits.addr
    io.axil.aw.bits.prot := bridge.io.axi.aw.bits.prot
    bridge.io.axi.aw.ready := io.axil.aw.ready
    io.axil.w.valid      := bridge.io.axi.w.valid
    io.axil.w.bits.data  := bridge.io.axi.w.bits.data
    io.axil.w.bits.strb  := bridge.io.axi.w.bits.strb
    bridge.io.axi.w.ready  := io.axil.w.ready
    io.axil.b.ready      := bridge.io.axi.b.ready
    bridge.io.axi.b.valid    := io.axil.b.valid
    bridge.io.axi.b.bits.resp := io.axil.b.bits.resp
    io.axil.ar.valid     := bridge.io.axi.ar.valid
    io.axil.ar.bits.addr := bridge.io.axi.ar.bits.addr
    io.axil.ar.bits.prot := bridge.io.axi.ar.bits.prot
    bridge.io.axi.ar.ready := io.axil.ar.ready
    io.axil.r.ready      := bridge.io.axi.r.ready
    bridge.io.axi.r.valid    := io.axil.r.valid
    bridge.io.axi.r.bits.data := io.axil.r.bits.data
    bridge.io.axi.r.bits.resp := io.axil.r.bits.resp

    // Optional JTAG DTM, same wiring as CoreTop.
    if parameter.debug then
      val dtm = JtagDtm.instantiate(parameter)
      dtm.io.tck  := io.tck.get
      dtm.io.trst := io.trst.get
      dtm.io.tms  := io.tms.get
      dtm.io.tdi  := io.tdi.get
      io.tdo.get := dtm.io.tdo

      val dm = core.io.dbg.get
      dm.dmactive     := dtm.io.dmactive
      dm.req          := dtm.io.req
      dm.cmd          := dtm.io.cmd
      dm.addr         := dtm.io.addr
      dm.dataFromHost := dtm.io.dataFromHost
      dtm.io.ack          := dm.ack
      dtm.io.dataToHost   := dm.dataToHost
      dtm.io.halted       := dm.halted
      dtm.io.coreSleeping := core.io.core_sleeping
