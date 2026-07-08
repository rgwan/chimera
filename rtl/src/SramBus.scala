// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*

/** Native SRAM-style master bus, from the core's perspective.
  *
  * `we == 0` is a read; on a write `wmask` selects bytes. One outstanding
  * request, big-endian, 16-bit data. `wdata` = di (master -> memory),
  * `rdata` = do (memory -> master).
  */
class SramBus(parameter: ChimeraParameter) extends Bundle:
  val addr  = Aligned(UInt(parameter.addrWidth))
  val wdata = Aligned(UInt(parameter.dataWidth))
  val rdata = Flipped(UInt(parameter.dataWidth))
  val we    = Aligned(Bool())
  val wmask = Aligned(UInt(parameter.wmaskWidth))
  val req   = Aligned(Bool())
  val rdy   = Flipped(Bool())
