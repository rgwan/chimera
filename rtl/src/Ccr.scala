// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Condition-code register (H N Z V C + I). V and C are supplied by hardware
  * (`hwV`/`hwC`); N, Z, H come from the datapath result; `flagCtl` selects the
  * update group. A direct load path serves LDC/ANDC/ORC/XORC/STC.
  */
class CcrIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock   = Flipped(Clock())
  val reset   = Flipped(Reset())
  val flagCtl = Flipped(UInt(3))
  val resN    = Flipped(Bool())
  val resZ    = Flipped(Bool())
  val resH    = Flipped(Bool())
  val hwV     = Flipped(Bool())
  val hwC     = Flipped(Bool())
  val ldWe    = Flipped(Bool())      // direct CCR write (LDC/logic-on-CCR)
  val ldVal   = Flipped(UInt(8))     // I UI H U N Z V C
  val setI    = Flipped(Bool())      // interrupt entry masks further IRQ
  val hnzvc   = Aligned(UInt(5))     // H N Z V C, model order
  val ccrByte = Aligned(UInt(8))     // I UI H U N Z V C
  val zFlag   = Aligned(Bool())
  val cFlag   = Aligned(Bool())
  val iFlag   = Aligned(Bool())

@generator
object Ccr extends Generator[ChimeraParameter, ChimeraLayers, CcrIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Ccr"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CcrIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val c = RegInit(false.B)
    val v = RegInit(false.B)
    val z = RegInit(false.B)
    val n = RegInit(false.B)
    val h = RegInit(false.B)
    val i = RegInit(false.B)

    def fc(code: Int) = io.flagCtl === code.U(3)

    when(fc(FlagCtl.Nz) | fc(FlagCtl.AddSub) | fc(FlagCtl.Shift) | fc(FlagCtl.StickyZ) |
      fc(FlagCtl.Nzv)) {
      n := io.resN
    }
    when(fc(FlagCtl.Nz))(z := io.resZ)
    when(fc(FlagCtl.AddSub) | fc(FlagCtl.Shift) | fc(FlagCtl.Nzv))(z := io.resZ)
    when(fc(FlagCtl.StickyZ))(z := io.resZ.?(z, false.B)) // SUBX sticky Z
    when(fc(FlagCtl.Nz))(v := false.B)
    when(fc(FlagCtl.AddSub) | fc(FlagCtl.Shift) | fc(FlagCtl.StickyZ) | fc(FlagCtl.Nzv))(v := io.hwV)
    when(fc(FlagCtl.AddSub) | fc(FlagCtl.Shift) | fc(FlagCtl.StickyZ))(c := io.hwC)
    when(fc(FlagCtl.AddSub) | fc(FlagCtl.StickyZ))(h := io.resH)
    when(fc(FlagCtl.Bit) & (!io.resH))(z := io.resZ)
    when(fc(FlagCtl.Bit) & io.resH)(c := io.hwC)

    when(io.ldWe) {
      val lv = io.ldVal.asBits
      i := lv.bit(7); h := lv.bit(5); n := lv.bit(3)
      z := lv.bit(2); v := lv.bit(1); c := lv.bit(0)
    }
    when(io.setI)(i := true.B)

    io.hnzvc := (h.asBits ## n.asBits ## z.asBits ## v.asBits ## c.asBits).asUInt
    io.ccrByte := (i.asBits ## 0.B(1) ## h.asBits ## 0.B(1) ## n.asBits ##
      z.asBits ## v.asBits ## c.asBits).asUInt
    io.zFlag := z
    io.cFlag := c
    io.iFlag := i
