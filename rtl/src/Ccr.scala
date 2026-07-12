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

    val state = RegInit(0x20.U(6)) // I H N Z V C; reset masks interrupts
    val stateBits = state.asBits

    def fc(code: Int) = io.flagCtl === code.U(3)

    val nz      = fc(FlagCtl.Nz)
    val addSub  = fc(FlagCtl.AddSub)
    val shift   = fc(FlagCtl.Shift)
    val stickyZ = fc(FlagCtl.StickyZ)
    val bit     = fc(FlagCtl.Bit)
    val nzv     = fc(FlagCtl.Nzv)

    // The result flags arrive late through the ALU; flagCtl/ldWe/setI and the
    // old state are ready at the cycle start. Fold everything early into one
    // base term and one result enable per bit, so the late signals cross a
    // single and-or level.
    val bitC = bit & io.resH
    val bitZ = bit & (!io.resH)
    val writeH = addSub | stickyZ
    val writeN = nz | addSub | shift | stickyZ | nzv
    val writeZ = writeN | bitZ
    val writeV = writeN
    val writeC = addSub | shift | stickyZ | bitC

    val lv = io.ldVal.asBits
    val notLd = !io.ldWe
    def flagBit(idx: Int, resEnRaw: Referable[Bool], late: Referable[Bool],
                loadBit: Referable[Bool], force: Referable[Bool]) =
      val resEn = notLd & resEnRaw
      val keep = (!resEn) & notLd
      (keep & stateBits.bit(idx)) | (io.ldWe & loadBit) | force |
        (resEn & late)

    val never = Wire(Bool())
    never := false.B
    val zLate = io.resZ & (stickyZ.?(stateBits.bit(2), true.B))
    val vLate = io.hwV & (!nz)
    val nextI = flagBit(5, never, never, lv.bit(7), io.setI)
    val nextH = flagBit(4, writeH, io.resH, lv.bit(5), never)
    val nextN = flagBit(3, writeN, io.resN, lv.bit(3), never)
    val nextZb = flagBit(2, writeZ, zLate, lv.bit(2), never)
    val nextV = flagBit(1, writeV, vLate, lv.bit(1), never)
    val nextC = flagBit(0, writeC, io.hwC, lv.bit(0), never)
    state := (nextI.asBits ## nextH.asBits ## nextN.asBits ##
      nextZb.asBits ## nextV.asBits ## nextC.asBits).asUInt

    io.hnzvc := stateBits.bits(4, 0).asUInt
    if parameter.ccrUbit then
      // UI (bit6) and U (bit4) exist as plain storage: only the direct load
      // path writes them; flag groups and interrupt entry leave them alone.
      val ubits = RegInit(0.U(2))
      when(io.ldWe)(ubits := (lv.bit(6).asBits ## lv.bit(4).asBits).asUInt)
      val ubitsBits = ubits.asBits
      io.ccrByte := (stateBits.bit(5).asBits ## ubitsBits.bit(1).asBits ##
        stateBits.bit(4).asBits ## ubitsBits.bit(0).asBits ##
        stateBits.bits(3, 0)).asUInt
    else
      io.ccrByte := (stateBits.bit(5).asBits ## 0.B(1) ## stateBits.bit(4).asBits ##
        0.B(1) ## stateBits.bits(3, 0)).asUInt
    io.zFlag := stateBits.bit(2)
    io.cFlag := stateBits.bit(0)
    io.iFlag := stateBits.bit(5)
