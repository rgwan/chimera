// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class BcdAdjustIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val value    = Flipped(UInt(parameter.byteWidth))
  val ccrHnzvc = Flipped(UInt(5))
  val ccrByte  = Flipped(UInt(8))
  val isDaa    = Flipped(Bool())
  val result   = Aligned(UInt(parameter.byteWidth))
  val ccrOut   = Aligned(UInt(8))

@generator
object BcdAdjust extends Generator[ChimeraParameter, ChimeraLayers, BcdAdjustIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "BcdAdjust"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[BcdAdjustIO]]
    val value = io.value.asBits
    val upper = value.bits(7, 4).asUInt
    val lower = value.bits(3, 0).asUInt
    val ccr = io.ccrHnzvc.asBits
    val oldH = ccr.bit(4)
    val oldV = ccr.bit(1)
    val oldC = ccr.bit(0)
    val zero8 = 0.U(parameter.byteWidth)

    val daaC1H1 = ((upper <= 3.U(4)) & (lower <= 3.U(4))).?(
      0x66.U(parameter.byteWidth), zero8)
    val daaC1H0 = (upper <= 2.U(4)).?(
      (lower <= 9.U(4)).?(0x60.U(parameter.byteWidth), 0x66.U(parameter.byteWidth)),
      zero8)
    val daaC0H1 = (lower <= 3.U(4)).?(
      (upper <= 9.U(4)).?(0x06.U(parameter.byteWidth), 0x66.U(parameter.byteWidth)),
      zero8)
    val daaC0H0 = (lower <= 9.U(4)).?(
      (upper <= 9.U(4)).?(zero8, 0x60.U(parameter.byteWidth)),
      (upper <= 8.U(4)).?(0x06.U(parameter.byteWidth), 0x66.U(parameter.byteWidth)))
    val daaAdjust = oldC.?(oldH.?(daaC1H1, daaC1H0), oldH.?(daaC0H1, daaC0H0))

    val dasC1H1 = ((upper >= 6.U(4)) & (lower >= 6.U(4))).?(
      0x9a.U(parameter.byteWidth), zero8)
    val dasC1H0 = ((upper >= 7.U(4)) & (lower <= 9.U(4))).?(
      0xa0.U(parameter.byteWidth), zero8)
    val dasC0H1 = ((upper <= 8.U(4)) & (lower >= 6.U(4))).?(
      0xfa.U(parameter.byteWidth), zero8)
    val dasAdjust = oldC.?(oldH.?(dasC1H1, dasC1H0), oldH.?(dasC0H1, zero8))

    val adjust = io.isDaa.?(daaAdjust, dasAdjust)
    val sum = ((0.B(1) ## value).asUInt + (0.B(1) ## adjust.asBits).asUInt).asBits
    val result = sum.bits(7, 0).asUInt
    val n = result.asBits.bit(7)
    val z = result.asBits === 0.B(8)
    val c = io.isDaa.?(sum.bit(8) | oldC, oldC)

    io.result := result
    io.ccrOut := (io.ccrByte.asBits.bit(7).asBits ## 0.B(1) ## oldH.asBits ##
      0.B(1) ## n.asBits ## z.asBits ## oldV.asBits ## c.asBits).asUInt
