// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreReadSelectIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irqAck = Flipped(Bool())
  val size = Flipped(Bool())
  val h8IdxCtl = Flipped(UInt(2))
  val intIdx = Flipped(UInt(2))
  val vclr = Flipped(Bool())
  val rdReg = Flipped(UInt(4))
  val rdImm = Flipped(UInt(4))
  val rsReg = Flipped(UInt(4))
  val bit3 = Flipped(UInt(3))
  val h8Rdata = Flipped(UInt(parameter.dataWidth))
  val intRdata = Flipped(UInt(parameter.dataWidth))
  val ccrByte = Flipped(UInt(8))
  val h8Idx = Aligned(UInt(parameter.regIndexBits))
  val h8Sel3 = Aligned(Bool())
  val h8Byte = Aligned(UInt(parameter.byteWidth))
  val h8Read = Aligned(UInt(parameter.dataWidth))
  val intRead = Aligned(UInt(parameter.dataWidth))

@generator
object CoreReadSelect
    extends Generator[ChimeraParameter, ChimeraLayers, CoreReadSelectIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreReadSelect"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreReadSelectIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val h8field = Wire(UInt(4))
    h8field := io.rdReg
    when(io.h8IdxCtl === H8Idx.RdImm.U(2))(h8field := io.rdImm)
    when(io.h8IdxCtl === H8Idx.RsReg.U(2))(h8field := io.rsReg)
    when(io.h8IdxCtl === H8Idx.Ptr.U(2))(
      h8field := io.vclr.?(7.U(4), (0.B(1) ## io.bit3.asBits).asUInt))
    io.h8Idx := h8field.asBits.bits(parameter.regIndexBits - 1, 0).asUInt
    io.h8Sel3 := h8field.asBits.bit(3)

    val h8Byte = io.h8Sel3.?(
      io.h8Rdata.asBits.bits(7, 0), io.h8Rdata.asBits.bits(15, 8))
    io.h8Byte := h8Byte.asUInt
    io.h8Read := io.size.?(io.h8Rdata, (0.B(8) ## h8Byte).asUInt)

    val savedCcr = RegInit(0.U(parameter.byteWidth))
    when(io.irqAck)(savedCcr := io.ccrByte)
    val ccrWord = io.size.?((savedCcr.asBits ## 0.B(8)).asUInt,
      (0.B(8) ## io.ccrByte.asBits).asUInt)
    io.intRead := (io.intIdx === IntIdx.CcrSrc.U(2)).?(ccrWord, io.intRdata)
