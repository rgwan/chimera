// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*

/** Core parameters. H8/300H is disabled by default; the LUT budget is measured
  * with it off.
  */
case class ChimeraParameter(
  h8300h:      Boolean = false,
  resetVector: Int = 0
) extends Parameter:
  require(resetVector >= 0, "resetVector must be non-negative")

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

/** No verification layers in the production core. */
class ChimeraLayers(parameter: ChimeraParameter) extends LayerInterface(parameter):
  def layers = Seq.empty

/** No DV probe ports. */
class ChimeraProbe(parameter: ChimeraParameter)
    extends DVBundle[ChimeraParameter, ChimeraLayers](parameter)
