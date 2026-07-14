// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*

/** Debug-enabled top: the Core and a separate JTAG DTM, wired through the
  * DebugPort. The DTM lives outside the Core (architect requirement) and runs in
  * its own TCK clock domain; the DebugPort carries the CDC handshake. Top-level
  * pins are the core bus/irq/status plus the five JTAG pins.
  */
class CoreTopIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irq   = Flipped(Bool())
  val nmi   = Flipped(Bool())
  val irq_number = Flipped(UInt(parameter.irqNumberWidth))
  val vt_base = Flipped(UInt(8))
  val bus   = Aligned(new SramBus(parameter))
  val core_sleeping = Aligned(Bool())
  val is_halted = Option.when(parameter.dm || parameter.hardwareBreakpoint)(Aligned(Bool()))
  // JTAG pins.
  val tck  = Flipped(Clock())
  val trst = Flipped(Reset())
  val tms  = Flipped(Bool())
  val tdi  = Flipped(Bool())
  val tdo  = Aligned(Bool())

@generator
object CoreTop
    extends Generator[ChimeraParameter, ChimeraLayers, CoreTopIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreTop"

  def architecture(parameter: ChimeraParameter) =
    require(parameter.debug, "CoreTop is the debug-enabled top; build with debug=true")
    val io = summon[Interface[CoreTopIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val core = Core.instantiate(parameter)
    val dtm  = JtagDtm.instantiate(parameter)

    // Core clocking and IO passthrough.
    core.io.clock := io.clock
    core.io.reset := io.reset
    core.io.irq   := io.irq
    core.io.nmi   := io.nmi
    core.io.irq_number := io.irq_number
    core.io.vt_base := io.vt_base
    io.bus.addr  := core.io.bus.addr
    io.bus.wdata := core.io.bus.wdata
    io.bus.we    := core.io.bus.we
    io.bus.wmask := core.io.bus.wmask
    io.bus.req   := core.io.bus.req
    core.io.bus.rdata := io.bus.rdata
    core.io.bus.rdy   := io.bus.rdy
    io.core_sleeping := core.io.core_sleeping
    (io.is_halted, core.io.is_halted) match
      case (Some(top), Some(c)) => top := c
      case _                    => ()

    // JTAG DTM clocking.
    dtm.io.tck  := io.tck
    dtm.io.trst := io.trst
    dtm.io.tms  := io.tms
    dtm.io.tdi  := io.tdi
    io.tdo := dtm.io.tdo

    // DebugPort <-> DTM. The core parks/dispatches; the DTM drives host->core and
    // reads core->host. CDC handshake lives on both sides (see each module).
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
