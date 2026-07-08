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

@generator
object Biu extends Generator[ChimeraParameter, ChimeraLayers, BiuIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Biu"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[BiuIO]]

    val isReq    = io.busCtl =/= BusCtl.None.U(2)
    val isWrite  = io.busCtl === BusCtl.Write.U(2)
    val wordLike = io.word | (io.busCtl === BusCtl.Fetch.U(2))
    val wordAddr = (io.addr.asBits.bits(parameter.addrWidth - 1, 1) ## 0.B).asUInt
    val busAddr  = wordLike.?(wordAddr, io.addr)
    val byteMask = busAddr.asBits.bit(0).?(1.U(parameter.wmaskWidth), 2.U(parameter.wmaskWidth))

    io.bus.addr  := busAddr
    io.bus.wdata := io.wdata
    io.bus.req   := isReq
    io.bus.we    := isWrite
    io.bus.wmask := isWrite.?(io.word.?(3.U(parameter.wmaskWidth), byteMask),
      0.U(parameter.wmaskWidth))

    io.rdata := io.bus.rdata
    io.rdy   := io.bus.rdy
