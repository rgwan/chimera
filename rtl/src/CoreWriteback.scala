// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

class CoreWritebackIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val size = Flipped(Bool())
  val wsel = Flipped(Bool())
  val aSel = Flipped(UInt(2))
  val intIdx = Flipped(UInt(2))
  val h8IdxCtl = Flipped(UInt(2))
  val busCtl = Flipped(UInt(2))
  val h8Idx = Flipped(UInt(parameter.regIndexBits))
  val h8Sel3 = Flipped(Bool())
  val bitAluOp = Flipped(UInt(4))
  val bitRegWe = Flipped(Bool())
  val bitMemStore = Flipped(Bool())
  val aluY = Flipped(UInt(parameter.dataWidth))
  val busAddr = Flipped(UInt(parameter.dataWidth))
  val iregData = Flipped(UInt(parameter.dataWidth))
  val divPack = Flipped(Bool())
  val divPackData = Flipped(UInt(parameter.dataWidth))
  val divStep = Flipped(Bool())
  val divStepData = Flipped(UInt(parameter.dataWidth))
  val h8Waddr = Aligned(UInt(parameter.regIndexBits))
  val h8Wdata = Aligned(UInt(parameter.dataWidth))
  val h8Wmask = Aligned(UInt(parameter.wmaskWidth))
  val h8We = Aligned(Bool())
  val intWaddr = Aligned(UInt(2))
  val intWdata = Aligned(UInt(parameter.dataWidth))
  val intWe = Aligned(Bool())
  val biuAddr = Aligned(UInt(parameter.dataWidth))
  val biuWdata = Aligned(UInt(parameter.dataWidth))
  val biuBusCtl = Aligned(UInt(2))
  val biuWord = Aligned(Bool())

@generator
object CoreWriteback
    extends Generator[ChimeraParameter, ChimeraLayers, CoreWritebackIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "CoreWriteback"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreWritebackIO]]
    val yByte = io.aluY.asBits.bits(7, 0)
    io.h8Waddr := io.h8Idx
    io.h8Wdata := io.divPack.?(io.divPackData,
      io.size.?(io.aluY, (yByte ## yByte).asUInt))
    io.h8Wmask := io.size.?(3.U(parameter.wmaskWidth),
      io.h8Sel3.?(1.U(parameter.wmaskWidth), 2.U(parameter.wmaskWidth)))
    io.h8We := io.bitRegWe & (!io.wsel) & (!io.bitMemStore)

    val pcFromIReg = io.wsel & io.bitRegWe & (io.aSel === ASel.Int.U(2)) &
      (io.intIdx === IntIdx.IReg.U(2)) & (io.bitAluOp === AluOp.PassA.U(4)) &
      (io.h8IdxCtl === H8Idx.RsReg.U(2))
    val intWaddr = pcFromIReg.?(IntIdx.PC.U(2), io.intIdx)
    val pcData = (io.aluY.asBits.bits(parameter.dataWidth - 1, 1) ## 0.B(1)).asUInt
    io.intWaddr := intWaddr
    io.intWdata := io.divStep.?(io.divStepData,
      (intWaddr === IntIdx.PC.U(2)).?(pcData, io.aluY))
    io.intWe := io.bitRegWe & io.wsel

    val bitMemWdata = (yByte ## yByte).asUInt
    val normalWdata = io.size.?(io.aluY, (yByte ## yByte).asUInt)
    io.biuAddr := io.bitMemStore.?(io.iregData, io.busAddr)
    io.biuWdata := io.bitMemStore.?(bitMemWdata, normalWdata)
    io.biuBusCtl := io.bitMemStore.?(BusCtl.Write.U(2), io.busCtl)
    io.biuWord := io.bitMemStore.?(false.B, io.size)
