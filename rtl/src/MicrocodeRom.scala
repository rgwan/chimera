// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Microcode image (512 x 36). Filled in under the execution-equivalence work;
  * an empty image reads as the all-zero microword (SeqSrc.Next / no-op).
  */
object MicrocodeImage:
  val words: Seq[BigInt] = Seq.empty

/** Combinational 512 x 36 ROM. Backed by a mux over the image; when the image
  * grows, revisit as a PLA/truth-table for area.
  */
class MicrocodeRomIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val addr = Flipped(UInt(parameter.upcBits))
  val data = Aligned(UInt(parameter.uromWidth))

@generator
object MicrocodeRom
    extends Generator[ChimeraParameter, ChimeraLayers, MicrocodeRomIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "MicrocodeRom"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicrocodeRomIO]]
    val d  = Wire(UInt(parameter.uromWidth))
    d := 0.U(parameter.uromWidth)
    MicrocodeImage.words.zipWithIndex.foreach { case (w, i) =>
      when(io.addr === i.U(parameter.upcBits))(d := w.U(parameter.uromWidth))
    }
    io.data := d
