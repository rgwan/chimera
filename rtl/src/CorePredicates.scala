// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CorePredicatesIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val firstOp      = Flipped(UInt(8))
  val ir           = Flipped(UInt(parameter.dataWidth))
  val bitMemActive = Flipped(Bool())
  val bitMemWrite  = Flipped(Bool())
  val wordBad      = Aligned(Bool())
  val nibbleBad    = Aligned(Bool())
  val bitMemExtBad = Aligned(Bool())

@generator
object CorePredicates
    extends Generator[ChimeraParameter, ChimeraLayers, CorePredicatesIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CorePredicates"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CorePredicatesIO]]
    val irBits = io.ir.asBits
    val opBits = io.firstOp.asBits
    val bitRegIndexOp = opBits.bits(7, 2) === 0x18.B(6)
    val bitImmOp = opBits.bits(7, 3) === 0x0e.B(5)
    val bitBstOp = io.firstOp === 0x67.U(8)
    val bitPrefixOp = opBits.bits(7, 2) === 0x1f.B(6)

    val wordRegPage = (io.firstOp === 0x09.U(8)) | (io.firstOp === 0x0d.U(8)) |
      (io.firstOp === 0x19.U(8)) | (io.firstOp === 0x1d.U(8))
    io.wordBad := wordRegPage.?(irBits.bit(15) | irBits.bit(11), irBits.bit(11))

    val secondHigh = irBits.bits(15, 12)
    val byteCcrPage = (io.firstOp === 0x02.U(8)) | (io.firstOp === 0x03.U(8))
    val addsSubsPage = (io.firstOp === 0x0b.U(8)) | (io.firstOp === 0x1b.U(8))
    val daaDasPage = (io.firstOp === 0x0f.U(8)) | (io.firstOp === 0x1f.U(8))
    val trapaPage = io.firstOp === 0x57.U(8)
    val trapaBad = (irBits.bits(15, 14) =/= 0.B(2)) |
      (irBits.bits(11, 8) =/= 0.B(4))
    val normalNibbleBad = byteCcrPage.?(
      secondHigh =/= 0.B(4),
      trapaPage.?(trapaBad,
        daaDasPage.?(secondHigh =/= 0.B(4),
          addsSubsPage.?(irBits.bits(14, 11) =/= 0.B(4),
            irBits.bits(14, 12) =/= 0.B(3)))))
    val bitPrefixR16 = (!io.bitMemActive) & bitPrefixOp & (!opBits.bit(1))
    val bitPrefixR16Bad = irBits.bit(15) | (irBits.bits(11, 8) =/= 0.B(4))
    val bitMemExtLowBad = irBits.bits(11, 8) =/= 0.B(4)
    val bitRegReadOp = bitRegIndexOp & (opBits.bits(1, 0) === 3.B(2))
    val bitRegWriteOp = bitRegIndexOp & (opBits.bits(1, 0) =/= 3.B(2))
    val bitImmBaseOp = bitImmOp & (!opBits.bit(2))
    val bitMemReadOp = bitRegReadOp |
      (bitImmBaseOp & (opBits.bits(1, 0) === 3.B(2)) & (!irBits.bit(15))) |
      (bitImmOp & opBits.bit(2))
    val bitMemWriteOp = bitRegWriteOp | bitBstOp |
      (bitImmBaseOp & (opBits.bits(1, 0) =/= 3.B(2)) & (!irBits.bit(15)))
    io.bitMemExtBad := bitMemExtLowBad | io.bitMemWrite.?((!bitMemWriteOp), (!bitMemReadOp))
    io.nibbleBad := io.bitMemActive.?(io.bitMemExtBad,
      bitPrefixR16.?(bitPrefixR16Bad, normalNibbleBad))
