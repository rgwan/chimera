// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}

/** Core parameters. H8/300H is disabled by default; the LUT budget is measured
  * with it off. strictDecode adds the illegal-encoding guards (WordBad and
  * NibbleBad predicates plus their guard microwords); without it the guards
  * are elided and their cond code tests the sleep wake signal instead.
  * pipeline selects the two-stage F/X microword pipeline; off (default) is the
  * single-cycle datapath, which is smaller and clocks the same.
  *
  * Debug features are independent and separately configurable. `dm` adds the
  * microcode-driven debug-module port (external debugger); it implies `dtm`.
  * `hardwareBreakpoint` adds the MMIO trigger unit (self-hosted or DM-driven);
  * `singleStep` reserves the MMIO STEP register (P4). `debug` is the derived
  * umbrella flag: any dm-dependent collateral keys on it. Every debug feature
  * off (default) leaves every leaf module byte-identical.
  */
case class ChimeraParameter(
  h8300h:             Boolean = false,
  strictDecode:       Boolean = false,
  romHex:             Boolean = false,
  ccrUbit:            Boolean = false,
  pipeline:           Boolean = false,
  dm:                 Boolean = false,
  dtm:                Boolean = false,
  hardwareBreakpoint: Boolean = false,
  hwBreakpointCount:  Int = 0,
  singleStep:         Boolean = false,
  idcode:             Long = 0x00114514L,
  dbgBase:            Int = 0xFF00,
  irqNumberWidth:     Int = 3
) extends Parameter:
  require(irqNumberWidth >= 1 && irqNumberWidth <= 8,
    "irqNumberWidth must be 1..8")
  // dm requires a DTM to reach it.
  require(!dm || dtm, "dm implies dtm")
  require(hwBreakpointCount >= 0 && hwBreakpointCount <= 8,
    "hwBreakpointCount must be 0..8")
  require(hwBreakpointCount == 0 || hardwareBreakpoint,
    "hwBreakpointCount>0 requires hardwareBreakpoint")
  require(!hardwareBreakpoint || (dbgBase >= 0 && dbgBase <= 0xFFFF),
    "hardwareBreakpoint requires a 16-bit dbgBase")
  require(!singleStep || (dbgBase >= 0 && dbgBase <= 0xFFFF),
    "singleStep requires a 16-bit dbgBase")

  /** Umbrella: DM-dependent collateral (park microcode, DebugPort, AUX inject,
    * JTAG DTM). Kept as `debug` so every P0-P2 call site compiles unchanged. */
  val debug: Boolean = dm
  /** MMIO decode window is present when any self-hostable feature is enabled. */
  val mmio: Boolean = hardwareBreakpoint || singleStep

  val dataWidth:    Int = 16
  val addrWidth:    Int = 16
  val byteWidth:    Int = 8
  val wmaskWidth:   Int = 2   // dataWidth / byteWidth
  val regCount:     Int = 8   // H8 R0..R7
  val regIndexBits: Int = 3
  val uromDepth:    Int = 512
  val upcBits:      Int = 9
  val uromWidth:    Int = 36
  val dispatchBits: Int = 8

given upickle.default.ReadWriter[ChimeraParameter] = upickle.default.macroRW

/** Verification layer; lowered into bind collateral and stripped in production. */
class ChimeraLayers(parameter: ChimeraParameter) extends LayerInterface(parameter):
  def layers = Seq(Layer("DV"))

/** Empty probe for leaf modules (no trace surface). */
class ChimeraProbe(parameter: ChimeraParameter)
    extends DVBundle[ChimeraParameter, ChimeraLayers](parameter)

/** Retire-trace surface (architectural state) on the Core, read via the DV layer. */
class CoreProbe(parameter: ChimeraParameter)
    extends DVBundle[ChimeraParameter, ChimeraLayers](parameter):
  private def dv = layers("DV")
  val traceH8    = ProbeRead(UInt(parameter.regCount * parameter.dataWidth), dv)
  val tracePc    = ProbeRead(UInt(parameter.dataWidth), dv)
  val traceCcr   = ProbeRead(UInt(5), dv)
  val traceFetch = ProbeRead(Bool(), dv)
