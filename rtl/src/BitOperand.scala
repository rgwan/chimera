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
  val firstOp      = Flipped(UInt(8))
  val ir           = Flipped(UInt(parameter.dataWidth))
  val intRead      = Flipped(UInt(parameter.dataWidth))
  val h8Byte       = Flipped(UInt(parameter.byteWidth))
  val bit3         = Flipped(UInt(3))
  val bitMemActive = Flipped(Bool())
  val bitMemByte   = Flipped(UInt(parameter.byteWidth))
  val aSel         = Flipped(UInt(2))
  val bSel         = Flipped(UInt(2))
  val vclr         = Flipped(Bool())
  val operandSel   = Aligned(Bool())
  val operandByte  = Aligned(UInt(parameter.byteWidth))
  val dataByte     = Aligned(UInt(parameter.byteWidth))
  val invert       = Aligned(Bool())

@generator
object BitOperand extends Generator[ChimeraParameter, ChimeraLayers, BitOperandIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "BitOperand"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[BitOperandIO]]
    val opBits = io.firstOp.asBits
    val regIndex = opBits.bits(7, 2) === 0x18.B(6) // 0x60..0x63
    val immBit = opBits.bits(7, 3) === 0x0e.B(5)   // 0x70..0x77
    val bst = io.firstOp === 0x67.U(8)
    val invertible = bst | (opBits.bits(7, 2) === 0x1d.B(6)) // 0x74..0x77
    val bitIndex = regIndex.?(io.intRead.asBits.bits(2, 0).asUInt, io.bit3)
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

    val invert = io.ir.asBits.bit(15) & invertible
    val value = invert.?((!set), set)
    val insn = regIndex | bst | immBit
    val operandSel = insn & (io.bSel === BSel.Imm8.U(2))
    val scalar = operandSel & (io.aSel === ASel.Int.U(2))
    val operand = Wire(UInt(parameter.byteWidth))
    operand := mask
    when(operandSel & io.vclr)(operand := (~mask.asBits).asUInt)
    when(scalar)(operand := (0.B(7) ## value.asBits).asUInt)

    io.operandSel := operandSel
    io.operandByte := operand
    io.dataByte := data
    io.invert := invert
