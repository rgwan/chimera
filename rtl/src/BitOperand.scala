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
  val cFlag        = Flipped(Bool())
  val aSel         = Flipped(UInt(2))
  val bSel         = Flipped(UInt(2))
  val vclr         = Flipped(Bool())
  val operandSel   = Aligned(Bool())
  val operandByte  = Aligned(UInt(parameter.byteWidth))
  val dataByte     = Aligned(UInt(parameter.byteWidth))
  val invert       = Aligned(Bool())
  val ctlAlu       = Aligned(UInt(4))
  val ctlFlag      = Aligned(UInt(3))
  val ctlRegWe     = Aligned(Bool())
  val ctlASelInt   = Aligned(Bool())
  val ctlVclr      = Aligned(Bool())

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
    val opLow = opBits.bits(1, 0)
    val ccrOp = immBit & opBits.bit(2)
    val readWriteOp = regIndex | (immBit & (!opBits.bit(2)))
    val testOp = readWriteOp & (opLow === 3.B(2))
    val writeOp = bst | (readWriteOp & (opLow =/= 3.B(2)))
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
    val bstSet = io.cFlag ^ invert
    val clearMask = io.vclr | (readWriteOp & (opLow === 2.B(2))) | (bst & (!bstSet))
    val value = invert.?((!set), set)
    val insn = regIndex | bst | immBit
    val operandSel = insn & (io.bSel === BSel.Imm8.U(2))
    val scalar = operandSel & ccrOp
    val operand = Wire(UInt(parameter.byteWidth))
    operand := mask
    when(operandSel & clearMask)(operand := (~mask.asBits).asUInt)
    when(scalar)(operand := (0.B(7) ## value.asBits).asUInt)

    val ctlAlu = Wire(UInt(4))
    ctlAlu := AluOp.Or.U(4)
    when(opLow === 1.B(2))(ctlAlu := AluOp.Xor.U(4))
    when(opLow === 2.B(2))(ctlAlu := AluOp.And.U(4))
    when(opLow === 3.B(2))(ctlAlu := ccrOp.?(AluOp.Pass.U(4),
      bst.?(bstSet.?(AluOp.Or.U(4), AluOp.And.U(4)), AluOp.And.U(4))))

    io.operandSel := operandSel
    io.operandByte := operand
    io.dataByte := data
    io.invert := invert
    io.ctlAlu := ctlAlu
    io.ctlFlag := (ccrOp | testOp).?(FlagCtl.Bit.U(3), FlagCtl.None.U(3))
    io.ctlRegWe := writeOp
    io.ctlASelInt := ccrOp
    io.ctlVclr := clearMask
