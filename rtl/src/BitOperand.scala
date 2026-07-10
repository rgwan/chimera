// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class BitOperandIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val ir           = Flipped(UInt(parameter.dataWidth))
  val intRead      = Flipped(UInt(parameter.dataWidth))
  val h8Byte       = Flipped(UInt(parameter.byteWidth))
  val bit3         = Flipped(UInt(3))
  val bitMemActive = Flipped(Bool())
  val bitMemByte   = Flipped(UInt(parameter.byteWidth))
  val cFlag        = Flipped(Bool())
  val aSel         = Flipped(UInt(2))
  val bSel         = Flipped(UInt(2))
  val intIdx       = Flipped(UInt(2))
  val cond         = Flipped(UInt(3))
  val vclr         = Flipped(Bool())
  val operandSel   = Aligned(Bool())
  val operandByte  = Aligned(UInt(parameter.byteWidth))
  val dataByte     = Aligned(UInt(parameter.byteWidth))

@generator
object BitOperand extends Generator[ChimeraParameter, ChimeraLayers, BitOperandIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "BitOperand"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[BitOperandIO]]
    val bitIndex = (io.intIdx === IntIdx.Temp.U(2)).?(
      io.intRead.asBits.bits(2, 0).asUInt, io.bit3)
    val mask = Wire(UInt(parameter.byteWidth))
    mask := 1.U(parameter.byteWidth)
    when(bitIndex === 1.U(3))(mask := 2.U(parameter.byteWidth))
    when(bitIndex === 2.U(3))(mask := 4.U(parameter.byteWidth))
    when(bitIndex === 3.U(3))(mask := 8.U(parameter.byteWidth))
    when(bitIndex === 4.U(3))(mask := 16.U(parameter.byteWidth))
    when(bitIndex === 5.U(3))(mask := 32.U(parameter.byteWidth))
    when(bitIndex === 6.U(3))(mask := 64.U(parameter.byteWidth))
    when(bitIndex === 7.U(3))(mask := 128.U(parameter.byteWidth))

    val data = io.bitMemActive.?(io.bitMemByte, io.h8Byte)
    val bits = data.asBits
    val set = Wire(Bool())
    set := bits.bit(0)
    when(bitIndex === 1.U(3))(set := bits.bit(1))
    when(bitIndex === 2.U(3))(set := bits.bit(2))
    when(bitIndex === 3.U(3))(set := bits.bit(3))
    when(bitIndex === 4.U(3))(set := bits.bit(4))
    when(bitIndex === 5.U(3))(set := bits.bit(5))
    when(bitIndex === 6.U(3))(set := bits.bit(6))
    when(bitIndex === 7.U(3))(set := bits.bit(7))

    val invert = io.ir.asBits.bit(15)
    val operandSel = (io.bSel === BSel.Imm8.U(2)) &
      (io.cond === Cond.IntBit.U(3))
    val scalar = io.aSel === ASel.Special.U(2)
    val fill = io.aSel === ASel.Int.U(2)
    val fillSet = io.cFlag ^ invert
    val operand = Wire(UInt(parameter.byteWidth))
    operand := io.vclr.?((~mask.asBits).asUInt, mask)
    when(fill)(operand := fillSet.?(mask, 0.U(parameter.byteWidth)))
    when(scalar)(operand := (0.B(7) ## (set ^ invert).asBits).asUInt)

    io.operandSel := operandSel
    io.operandByte := operand
    io.dataByte := data
