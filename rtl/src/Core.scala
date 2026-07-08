// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*
import org.llvm.mlir.scalalib.capi.ir.{Block, Context}
import java.lang.foreign.Arena

/** Chimera H8/300 core top. Native SRAM-style master bus; irq/nmi polled by
  * microcode. Wires the microsequencer, coarse decoder, register files, ALU,
  * CCR and BIU. Datapath operand/writeback muxing is steered by the microword.
  */
class CoreIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irq   = Flipped(Bool())
  val nmi   = Flipped(Bool())
  val bus   = Aligned(new SramBus(parameter))

@generator
object Core extends Generator[ChimeraParameter, ChimeraLayers, CoreIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Core"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val coarse = CoarseDecoder.instantiate(parameter)
    val urom   = MicrocodeRom.instantiate(parameter)
    val udec   = MicroDecode.instantiate(parameter)
    val useq   = Microsequencer.instantiate(parameter)
    val opx    = OperandExtract.instantiate(parameter)
    val h8rf   = H8RegFile.instantiate(parameter)
    val intrf  = IntRegFile.instantiate(parameter)
    val alu    = Alu.instantiate(parameter)
    val ccr    = Ccr.instantiate(parameter)
    val biu    = Biu.instantiate(parameter)

    // instruction register (holds the fetched word microcode reads)
    val ir = RegInit(0.U(parameter.dataWidth))

    // clocks / resets to the sequential submodules
    h8rf.io.clock  := io.clock; h8rf.io.reset  := io.reset
    intrf.io.clock := io.clock; intrf.io.reset := io.reset
    ccr.io.clock   := io.clock; ccr.io.reset   := io.reset
    useq.io.clock  := io.clock; useq.io.reset  := io.reset

    // microcode fetch/decode loop
    urom.io.addr := useq.io.upc
    udec.io.word := urom.io.data

    // decode paths
    coarse.io.word := ir
    opx.io.word    := ir

    val sizeWord = udec.io.misc.asBits.bit(Misc.SizeWord)

    // operand fields -> register indices
    val rdIdx = opx.io.rdReg.asBits.bits(parameter.regIndexBits - 1, 0).asUInt
    val rsIdx = opx.io.rsReg.asBits.bits(parameter.regIndexBits - 1, 0).asUInt
    val imm16 = (0.B(8) ## opx.io.imm8.asBits).asUInt

    // register-file reads
    h8rf.io.raddr := rsIdx
    intrf.io.raddr := udec.io.aSel.asBits.bits(1, 0).asUInt

    // ALU operand A mux (aSel)
    val aMux = Wire(UInt(parameter.dataWidth))
    aMux := h8rf.io.rdata
    when(udec.io.aSel === 1.U(3))(aMux := intrf.io.rdata)
    when(udec.io.aSel === 2.U(3))(aMux := imm16)
    when(udec.io.aSel === 3.U(3))(aMux := 0.U(parameter.dataWidth))

    // ALU operand B mux (bSel)
    val bMux = Wire(UInt(parameter.dataWidth))
    bMux := h8rf.io.rdata
    when(udec.io.bSel === 1.U(3))(bMux := imm16)
    when(udec.io.bSel === 2.U(3))(bMux := intrf.io.rdata)
    when(udec.io.bSel === 3.U(3))(bMux := 0.U(parameter.dataWidth))

    alu.io.a    := aMux
    alu.io.b    := bMux
    alu.io.cin  := ccr.io.cFlag
    alu.io.op   := udec.io.aluOp
    alu.io.word := sizeWord

    // flags
    ccr.io.flagCtl := udec.io.flagCtl
    ccr.io.resN    := sizeWord.?(alu.io.y.asBits.bit(15), alu.io.y.asBits.bit(7))
    ccr.io.resZ    := sizeWord.?(alu.io.y.asBits.bits(15, 0) === 0.B(16),
      alu.io.y.asBits.bits(7, 0) === 0.B(8))
    ccr.io.resH    := alu.io.hout
    ccr.io.hwV     := alu.io.vout
    ccr.io.hwC     := alu.io.cout
    ccr.io.ldWe    := false.B
    ccr.io.ldVal   := 0.U(8)

    // writeback routing (rdGrp bit0: 0 = H8 file, 1 = internal file)
    val toInternal = udec.io.rdGrp.asBits.bit(0)
    h8rf.io.waddr := rdIdx
    h8rf.io.wdata := alu.io.y
    h8rf.io.wmask := sizeWord.?(3.U(parameter.wmaskWidth), 2.U(parameter.wmaskWidth))
    h8rf.io.we    := udec.io.regWe & (!toInternal)
    intrf.io.waddr := udec.io.rdGrp.asBits.bits(1, 0).asUInt
    intrf.io.wdata := alu.io.y
    intrf.io.we    := udec.io.regWe & toInternal

    // BIU: address = PC/internal read; microcode selects via bus_ctl
    biu.io.addr   := intrf.io.rdata
    biu.io.wdata  := h8rf.io.rdata
    biu.io.busCtl := udec.io.busCtl
    biu.io.word   := sizeWord

    // fetch capture into IR
    // memory is big-endian; the decoder-visible IR is byteswapped (first byte in
    // [7:0]). Data loads use biu.rdata directly (natural BE value).
    val doFetch  = udec.io.busCtl === BusCtl.Fetch.U(3)
    val fetchLe  = biu.io.rdata.asBits.bits(7, 0) ## biu.io.rdata.asBits.bits(15, 8)
    when(doFetch & biu.io.rdy)(ir := fetchLe.asUInt)

    // sequencer inputs
    useq.io.seqSrc   := udec.io.seqSrc
    useq.io.cond     := udec.io.cond
    useq.io.misc     := udec.io.misc
    useq.io.literal  := udec.io.literal
    useq.io.dispatch := coarse.io.dispatch
    useq.io.condZ    := ccr.io.zFlag
    useq.io.condC    := ccr.io.cFlag
    useq.io.busRdy   := biu.io.rdy
    useq.io.ccTaken  := false.B // branch-condition eval: filled with microcode/flags

    // irq latch (polled by microcode)
    val irqLatch = RegInit(false.B)
    when(io.irq | io.nmi)(irqLatch := true.B)
    useq.io.irqPend := irqLatch

    // external SRAM bus <-> BIU
    io.bus.addr  := biu.io.bus.addr
    io.bus.wdata := biu.io.bus.wdata
    io.bus.we    := biu.io.bus.we
    io.bus.wmask := biu.io.bus.wmask
    io.bus.req   := biu.io.bus.req
    biu.io.bus.rdata := io.bus.rdata
    biu.io.bus.rdy   := io.bus.rdy
