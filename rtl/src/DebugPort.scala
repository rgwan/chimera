// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*

/** Debug-module request/ack port, from the core's perspective.
  *
  * The debug module (a separate block reached over a DTM) drives one request at
  * a time: raise `req` with `cmd`, `addr` and `dataFromHost`; the core parks in
  * the debug wait word, runs the primitive, and raises `ack` when it retires.
  * `dataToHost` returns the read result. `dmactive` marks a debugger present;
  * `halted` reports the core is parked in the debug wait word.
  */
object DmCmd:
  val MemRead  = 0
  val MemWrite = 1
  val SetPc    = 2
  val Halt     = 3
  val Resume   = 4

class DebugPort(parameter: ChimeraParameter) extends Bundle:
  val dmactive     = Flipped(Bool())                       // host -> core
  val req          = Flipped(Bool())                       // host -> core
  val cmd          = Flipped(UInt(3))                       // host -> core (DmCmd)
  val addr         = Flipped(UInt(parameter.addrWidth))     // host -> core
  val dataFromHost = Flipped(UInt(parameter.dataWidth))     // host -> core
  val ack          = Aligned(Bool())                        // core -> host
  val dataToHost   = Aligned(UInt(parameter.dataWidth))     // core -> host
  val halted       = Aligned(Bool())                        // core -> host
