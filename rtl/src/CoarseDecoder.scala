// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Decoder-visible word (BIU-byteswapped from big-endian memory): first opcode
  * byte in [7:0] (`d ooo pppp`, d=bit7), second byte in [15:8] (`m xxx xxxx`).
  */
class CoarseDecoderIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val word     = Flipped(UInt(parameter.dataWidth))
  val dispatch = Aligned(UInt(parameter.dispatchBits))

/** Three-way coarse pre-decode to an 8-bit dispatch address (< 10 LUT). */
@generator
object CoarseDecoder
    extends Generator[ChimeraParameter, ChimeraLayers, CoarseDecoderIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoarseDecoder"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoarseDecoderIO]]
    val w  = io.word.asBits

    val d     = w.bit(7)                    // first-byte MSB
    val mf    = w.bit(15)                   // second-byte MSB (m)
    val sym   = w.bit(6) === w.bit(5)       // ooo in {0,1,6,7}
    val oooNZ = w.bits(6, 4) =/= 0.B(3)     // ooo != 0

    // ooo=0 joins the m-class only with H8/300H enabled.
    val m = if parameter.h8300h then (sym & mf) else (sym & mf & oooNZ)

    val cAddr = w.bits(7, 0)                // bucket C: first byte (d=0 => bit7=0)
    val bAddr = 3.B(2) ## w.bits(5, 0)      // bucket B: 0xc0-0xff
    val aAddr = 16.B(5) ## w.bits(6, 4)     // bucket A: 0x80-0x87

    io.dispatch := d.?(aAddr, m.?(bAddr, cAddr)).asUInt
