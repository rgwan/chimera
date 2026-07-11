// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}

/** Core parameters. H8/300H is disabled by default; the LUT budget is measured
  * with it off. strictDecode adds the illegal-encoding guards (WordBad and
  * NibbleBad predicates plus their guard microwords); without it the guards
  * are elided and their cond code tests the sleep wake signal instead.
  */
case class ChimeraParameter(
  h8300h:         Boolean = false,
  strictDecode:   Boolean = false,
  romHex:         Boolean = false,
  irqNumberWidth: Int = 3,
  resetVector:    Int = 0
) extends Parameter:
  require(resetVector >= 0, "resetVector must be non-negative")
  require(irqNumberWidth >= 1 && irqNumberWidth <= 8,
    "irqNumberWidth must be 1..8")

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
