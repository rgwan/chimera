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

    val state = RegInit(0.U(6)) // I H N Z V C
    val stateBits = state.asBits

    def fc(code: Int) = io.flagCtl === code.U(3)

    val nz      = fc(FlagCtl.Nz)
    val addSub  = fc(FlagCtl.AddSub)
    val shift   = fc(FlagCtl.Shift)
    val stickyZ = fc(FlagCtl.StickyZ)
    val bit     = fc(FlagCtl.Bit)
    val nzv     = fc(FlagCtl.Nzv)

    val bitC = bit & io.resH
    val bitZ = bit & (!io.resH)
    val writeH = addSub | stickyZ
    val writeN = nz | addSub | shift | stickyZ | nzv
    val writeZ = writeN | bitZ
    val writeV = writeN
    val writeC = addSub | shift | stickyZ | bitC
    val flagWriteMask = (0.B(1) ## writeH.asBits ## writeN.asBits ## writeZ.asBits ##
      writeV.asBits ## writeC.asBits).asUInt

    val nextZ = stickyZ.?((io.resZ & stateBits.bit(2)), io.resZ)
    val nextV = nz.?(false.B, io.hwV)
    val flagNext = (0.B(1) ## io.resH.asBits ## io.resN.asBits ## nextZ.asBits ##
      nextV.asBits ## io.hwC.asBits).asUInt

    val lv = io.ldVal.asBits
    val loadNext = (lv.bit(7).asBits ## lv.bit(5).asBits ## lv.bits(3, 0)).asUInt
    val selectedMask = io.ldWe.?(0x3f.U(6), flagWriteMask)
    val selectedNext = io.ldWe.?(loadNext, flagNext)
    val setIMask = (io.setI.asBits ## 0.B(5)).asUInt
    val writeMask = (selectedMask.asBits | setIMask.asBits).asUInt
    val writeValue = (selectedNext.asBits | setIMask.asBits).asUInt
    val nextState = ((stateBits & (~writeMask.asBits)) |
      (writeValue.asBits & writeMask.asBits)).asUInt
    state := nextState

    io.hnzvc := stateBits.bits(4, 0).asUInt
    io.ccrByte := (stateBits.bit(5).asBits ## 0.B(1) ## stateBits.bit(4).asBits ##
      0.B(1) ## stateBits.bits(3, 0)).asUInt
    io.zFlag := stateBits.bit(2)
    io.cFlag := stateBits.bit(0)
    io.iFlag := stateBits.bit(5)
