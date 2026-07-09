// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreBitControlIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val firstOp = Flipped(UInt(8))
  val ir = Flipped(UInt(parameter.dataWidth))
  val coarseDispatch = Flipped(UInt(parameter.dispatchBits))
  val seqSrc = Flipped(UInt(2))
  val cond = Flipped(UInt(3))
  val literal = Flipped(UInt(parameter.upcBits))
  val bitMemActive = Flipped(Bool())
  val bitMemExtBad = Flipped(Bool())
  val dispatch = Aligned(UInt(parameter.dispatchBits))
  val prefixHead = Aligned(Bool())
  val memReturn = Aligned(Bool())

@generator
object CoreBitControl
    extends Generator[ChimeraParameter, ChimeraLayers, CoreBitControlIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreBitControl"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreBitControlIO]]
    val firstOpBits = io.firstOp.asBits
    val firstOpHi6 = firstOpBits.bits(7, 2)
    val firstOpHi5 = firstOpBits.bits(7, 3)
    val bitRegIndexOp = firstOpHi6 === 0x18.B(6)
    val bitImmOp = firstOpHi5 === 0x0e.B(5)
    val bitBstOp = io.firstOp === 0x67.U(8)
    val bitPrefixOp = firstOpHi6 === 0x1f.B(6)
    val bitExtInv = io.ir.asBits.bit(15)

    io.prefixHead := bitPrefixOp &
      (io.seqSrc === SeqSrc.Literal.U(2)) &
      (io.literal === Ucode.BitPrefixExt.U(parameter.upcBits))

    val bitDispatch = Wire(UInt(parameter.dispatchBits))
    bitDispatch := io.coarseDispatch
    when(bitRegIndexOp)(bitDispatch := 0x60.U(parameter.dispatchBits))
    when(bitBstOp | (bitImmOp & (!firstOpBits.bit(2)) & (!bitExtInv)))(
      bitDispatch := 0x70.U(parameter.dispatchBits))
    when(bitImmOp & firstOpBits.bit(2))(bitDispatch := 0x74.U(parameter.dispatchBits))
    when(bitPrefixOp & (!firstOpBits.bit(1)) & (!bitExtInv))(
      bitDispatch := 0x7c.U(parameter.dispatchBits))
    when(bitPrefixOp & firstOpBits.bit(1))(bitDispatch := 0x7e.U(parameter.dispatchBits))
    io.dispatch := bitDispatch

    io.memReturn := io.bitMemActive & (io.seqSrc === SeqSrc.Literal.U(2)) &
      (io.literal === Ucode.FetchEntry.U(parameter.upcBits)) &
      ((io.cond =/= Cond.NibbleBad.U(3)) | io.bitMemExtBad)
