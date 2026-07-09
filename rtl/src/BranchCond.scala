// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class BranchCondIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val cc    = Flipped(UInt(4))
  val hnzvc = Flipped(UInt(5))
  val taken = Aligned(Bool())

@generator
object BranchCond extends Generator[ChimeraParameter, ChimeraLayers, BranchCondIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "BranchCond"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[BranchCondIO]]
    val flags = io.hnzvc.asBits
    val n = flags.bit(3)
    val z = flags.bit(2)
    val v = flags.bit(1)
    val c = flags.bit(0)
    val nv = n ^ v

    val taken = Wire(Bool())
    taken := true.B
    when(io.cc === 0x1.U(4))(taken := false.B)
    when(io.cc === 0x2.U(4))(taken := !(c | z))
    when(io.cc === 0x3.U(4))(taken := c | z)
    when(io.cc === 0x4.U(4))(taken := !c)
    when(io.cc === 0x5.U(4))(taken := c)
    when(io.cc === 0x6.U(4))(taken := !z)
    when(io.cc === 0x7.U(4))(taken := z)
    when(io.cc === 0x8.U(4))(taken := !v)
    when(io.cc === 0x9.U(4))(taken := v)
    when(io.cc === 0xa.U(4))(taken := !n)
    when(io.cc === 0xb.U(4))(taken := n)
    when(io.cc === 0xc.U(4))(taken := !nv)
    when(io.cc === 0xd.U(4))(taken := nv)
    when(io.cc === 0xe.U(4))(taken := !(z | nv))
    when(io.cc === 0xf.U(4))(taken := z | nv)
    io.taken := taken
