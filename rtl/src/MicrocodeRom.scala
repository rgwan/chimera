// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class MicrocodeRomIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val addr = Flipped(UInt(parameter.upcBits))
  val data = Aligned(UInt(parameter.uromWidth))

@generator
object MicrocodeRom
    extends Generator[ChimeraParameter, ChimeraLayers, MicrocodeRomIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "MicrocodeRom"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[MicrocodeRomIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val d = Wire(UInt(parameter.uromWidth))
    d := 0.U(parameter.uromWidth)
    MicrocodeImage.sparse(parameter.strictDecode).foreach { case (addr, w) =>
      when(io.addr === addr.U(parameter.upcBits))(d := w.U(parameter.uromWidth))
    }
    val resetWord =
      MicrocodeImage.program(parameter.strictDecode)(Ucode.ResetEntry).encode
    val q = RegInit(resetWord.U(parameter.uromWidth))
    q := d
    io.data := q
