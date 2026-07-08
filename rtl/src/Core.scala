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
object Core extends Generator[ChimeraParameter, ChimeraLayers, CoreIO, CoreProbe]:
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

    val sizeWord = udec.io.size

    // single H8 read/write index: pick one OperandExtract field. Bit 3 is the
    // byte select (0 = RnH high, 1 = RnL low); bits [2:0] are the word register.
    val ri = parameter.regIndexBits - 1
    val h8field = Wire(UInt(4))
    h8field := opx.io.rdReg
    when(udec.io.h8Idx === H8Idx.RdImm.U(2))(h8field := opx.io.rdImm)
    when(udec.io.h8Idx === H8Idx.RsReg.U(2))(h8field := opx.io.rsReg)
    val h8Idx  = h8field.asBits.bits(ri, 0).asUInt
    val h8Sel3 = h8field.asBits.bit(3)

    // byte-aligned H8 read: selected byte into [7:0] for byte ops
    val h8Byte = h8Sel3.?(h8rf.io.rdata.asBits.bits(7, 0), h8rf.io.rdata.asBits.bits(15, 8))
    val h8Read = sizeWord.?(h8rf.io.rdata, (0.B(8) ## h8Byte).asUInt)

    val imm8ext  = (0.B(8) ## opx.io.imm8.asBits).asUInt
    val litConst = (0.B(8) ## udec.io.literal.asBits.bits(7, 0)).asUInt

    // register-file reads (single port each)
    h8rf.io.raddr  := h8Idx
    intrf.io.raddr := udec.io.intIdx

    // ALU A mux
    val aMux = Wire(UInt(parameter.dataWidth))
    aMux := h8Read
    when(udec.io.aSel === ASel.Int.U(2))(aMux := intrf.io.rdata)
    when(udec.io.aSel === ASel.Zero.U(2))(aMux := 0.U(parameter.dataWidth))

    // ALU B mux
    val bMux = Wire(UInt(parameter.dataWidth))
    bMux := h8Read
    when(udec.io.bSel === BSel.Imm8.U(2))(bMux := imm8ext)
    when(udec.io.bSel === BSel.Int.U(2))(bMux := intrf.io.rdata)
    when(udec.io.bSel === BSel.Lit.U(2))(bMux := litConst)

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

    // writeback: WSel picks the H8 or internal file (shared index/data). Byte ops
    // replicate the result byte and let wmask place it into the selected half.
    val toInternal = udec.io.wsel
    val yByte = alu.io.y.asBits.bits(7, 0)
    h8rf.io.waddr  := h8Idx
    h8rf.io.wdata  := sizeWord.?(alu.io.y, (yByte ## yByte).asUInt)
    h8rf.io.wmask  := sizeWord.?(3.U(parameter.wmaskWidth),
      h8Sel3.?(1.U(parameter.wmaskWidth), 2.U(parameter.wmaskWidth)))
    h8rf.io.we     := udec.io.regWe & (!toInternal)
    intrf.io.waddr := udec.io.intIdx
    intrf.io.wdata := alu.io.y
    intrf.io.we    := udec.io.regWe & toInternal

    // BIU: address from the internal read (PC for fetch, IREG for a data address)
    biu.io.addr   := intrf.io.rdata
    biu.io.wdata  := h8rf.io.rdata
    biu.io.busCtl := udec.io.busCtl
    biu.io.word   := sizeWord

    // memory is big-endian; the decoder-visible IR is byte-swapped (first byte in
    // [7:0]). Data loads use biu.rdata directly (natural BE value).
    val doFetch      = udec.io.busCtl === BusCtl.Fetch.U(2)
    val fetchSwapped = biu.io.rdata.asBits.bits(7, 0) ## biu.io.rdata.asBits.bits(15, 8)
    when(doFetch & biu.io.rdy)(ir := fetchSwapped.asUInt)

    // sequencer inputs
    useq.io.seqSrc   := udec.io.seqSrc
    useq.io.cond     := udec.io.cond
    useq.io.call     := udec.io.call
    useq.io.literal  := udec.io.literal
    useq.io.dispatch := coarse.io.dispatch
    useq.io.condZ    := ccr.io.zFlag
    useq.io.condC    := ccr.io.cFlag
    useq.io.busRdy   := biu.io.rdy
    useq.io.ccTaken  := false.B // branch-condition eval: filled later

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

    // retire-trace surface, lowered into the DV layer bind collateral (stripped
    // in production). doFetch marks one fetch per instruction.
    val probe = summon[Interface[CoreProbe]]
    layer("DV"):
      probe.traceH8    <== h8rf.io.dbg
      probe.tracePc    <== intrf.io.dbgPc
      probe.traceCcr   <== ccr.io.hnzvc
      probe.traceFetch <== doFetch
