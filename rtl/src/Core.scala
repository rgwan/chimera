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
    val bitop  = BitOperand.instantiate(parameter)
    val bcond  = BranchCond.instantiate(parameter)
    val preds  = Option.when(parameter.strictDecode)(
      CorePredicates.instantiate(parameter))
    val aluctl = CoreAluControl.instantiate(parameter)
    val ccrctl = CoreCcrControl.instantiate(parameter)
    val wb     = CoreWriteback.instantiate(parameter)
    val irqctl = CoreIrqControl.instantiate(parameter)
    val biu    = Biu.instantiate(parameter)

    // instruction register (holds the fetched word microcode reads)
    val ir = RegInit(0.U(parameter.dataWidth))

    def connectClockedDecode() =
      h8rf.io.clock  := io.clock; h8rf.io.reset  := io.reset
      intrf.io.clock := io.clock; intrf.io.reset := io.reset
      ccr.io.clock   := io.clock; ccr.io.reset   := io.reset
      irqctl.io.clock := io.clock; irqctl.io.reset := io.reset
      useq.io.clock  := io.clock; useq.io.reset  := io.reset
      urom.io.clock  := io.clock; urom.io.reset  := io.reset
      urom.io.addr := useq.io.upc
      udec.io.word := urom.io.data
      coarse.io.word := ir
      opx.io.word    := ir

    connectClockedDecode()

    val firstOp = ir.asBits.bits(7, 0)
    val sizeWord = udec.io.size
    val stepEn = Wire(Bool())

    val h8field = Wire(UInt(4))
    h8field := opx.io.rdReg
    when(udec.io.h8Idx === H8Idx.RdImm.U(2))(h8field := opx.io.rdImm)
    when(udec.io.h8Idx === H8Idx.RsReg.U(2))(h8field := opx.io.rsReg)
    when(udec.io.h8Idx === H8Idx.Ptr.U(2))(
      h8field := udec.io.vclr.?(7.U(4), (0.B(1) ## opx.io.bit3.asBits).asUInt))
    val h8Idx = h8field.asBits.bits(parameter.regIndexBits - 1, 0).asUInt
    val h8Sel3 = h8field.asBits.bit(3)
    val h8Byte = h8Sel3.?(
      h8rf.io.rdata.asBits.bits(7, 0), h8rf.io.rdata.asBits.bits(15, 8)).asUInt
    val h8Read = sizeWord.?(h8rf.io.rdata, (0.B(8) ## h8Byte.asBits).asUInt)
    val intRead = intrf.io.rdata
    val savedCcr = RegInit(0.U(parameter.byteWidth))
    when(useq.io.irqAck)(savedCcr := ccr.io.ccrByte)
    val ccrRead = sizeWord.?((savedCcr.asBits ## 0.B(8)).asUInt,
      (0.B(8) ## ccr.io.ccrByte.asBits).asUInt)

    val abs8PageAddr = (udec.io.aSel === ASel.Zero.U(2)) &
      (udec.io.bSel === BSel.Imm8.U(2)) & (udec.io.aluOp === AluOp.Pass.U(4)) &
      udec.io.wsel & udec.io.regWe & (udec.io.intIdx === IntIdx.IReg.U(2))
    val vec8Addr = (udec.io.aSel === ASel.Zero.U(2)) &
      (udec.io.bSel === BSel.Imm8.U(2)) & (udec.io.aluOp === AluOp.Pass.U(4)) &
      udec.io.wsel & udec.io.regWe & (udec.io.intIdx === IntIdx.PC.U(2))
    val imm8sign = opx.io.imm8.asBits.bit(7).?(0xff.B(8), 0.B(8))
    val imm8top = (0xff.B(8) ## opx.io.imm8.asBits).asUInt
    val imm8zero = (0.B(8) ## opx.io.imm8.asBits).asUInt
    val imm8ext = abs8PageAddr.?(imm8top,
      vec8Addr.?(imm8zero, (imm8sign ## opx.io.imm8.asBits).asUInt))
    val addsSubsConst = ir.asBits.bit(15).?(2.U(parameter.dataWidth),
      1.U(parameter.dataWidth))
    val specialValue = udec.io.literal.asBits.bit(0).?(
      irqctl.io.irqVectorAddr, addsSubsConst)
    val litConst = udec.io.literal.asBits.bit(8).?(specialValue,
      (0.B(8) ## udec.io.literal.asBits.bits(7, 0)).asUInt)

    def connectReads() =
      h8rf.io.raddr  := h8Idx
      intrf.io.raddr := udec.io.intIdx

    connectReads()

    val bitMemActive = RegInit(false.B)
    val bitMemWrite = RegInit(false.B)
    val bitMemByte = RegInit(0.U(parameter.byteWidth))

    def connectBitInputs() =
      bitop.io.ir := ir
      bitop.io.intRead := intRead
      bitop.io.h8Byte := h8Byte
      bitop.io.bit3 := opx.io.bit3
      bitop.io.bitMemActive := bitMemActive
      bitop.io.bitMemByte := bitMemByte
      bitop.io.cFlag := ccr.io.cFlag
      bitop.io.aSel := udec.io.aSel
      bitop.io.bSel := udec.io.bSel
      bitop.io.intIdx := udec.io.intIdx
      bitop.io.cond := udec.io.cond
      bitop.io.vclr := udec.io.vclr

    connectBitInputs()
    val bitMemStore = bitMemActive & bitMemWrite & bitop.io.operandSel &
      udec.io.regWe & (!udec.io.wsel)
    val bitPrefixHead = (udec.io.seqSrc === SeqSrc.Literal.U(2)) & udec.io.seqAux
    val bitMemReturn = bitMemActive & (udec.io.seqSrc === SeqSrc.Return.U(2))

    val wakePend = irqctl.io.nmiPend | irqctl.io.irqPend

    def connectPredicates() = preds.foreach { p =>
      p.io.firstOp := firstOp.asUInt
      p.io.ir := ir
      p.io.bitMemActive := bitMemActive
      p.io.bitMemWrite := bitMemWrite
      p.io.wakePend := wakePend
    }

    connectPredicates()

    val stackBus = (udec.io.h8Idx === H8Idx.Ptr.U(2)) & udec.io.vclr &
      ((udec.io.busCtl === BusCtl.Read.U(2)) | (udec.io.busCtl === BusCtl.Write.U(2)))
    val h8BusAddr = (udec.io.busCtl === BusCtl.Write.U(2)) & (!udec.io.vclr) &
      (udec.io.h8Idx === H8Idx.Ptr.U(2)) & (udec.io.aSel === ASel.Int.U(2))
    val extIRegBus = (udec.io.busCtl === BusCtl.Read.U(2)) &
      (udec.io.aSel === ASel.Special.U(2)) & udec.io.wsel & udec.io.regWe &
      (udec.io.intIdx === IntIdx.IReg.U(2))
    val pcBus = (udec.io.busCtl === BusCtl.Fetch.U(2)) |
      ((udec.io.busCtl === BusCtl.Read.U(2)) & (udec.io.intIdx === IntIdx.PC.U(2))) |
      extIRegBus
    val busAddr = (stackBus | h8BusAddr).?(h8rf.io.rdata,
      pcBus.?(intrf.io.pcData, intrf.io.iregData))
    val memByte = busAddr.asBits.bit(0).?(
      biu.io.rdata.asBits.bits(7, 0), biu.io.rdata.asBits.bits(15, 8))
    val memRead = sizeWord.?(biu.io.rdata, (0.B(8) ## memByte).asUInt)

    def connectAluPath() =
      aluctl.io.aSel := udec.io.aSel
      aluctl.io.bSel := udec.io.bSel
      aluctl.io.aluOp := udec.io.aluOp
      aluctl.io.flagCtl := udec.io.flagCtl
      aluctl.io.regWe := udec.io.regWe
      aluctl.io.wsel := udec.io.wsel
      aluctl.io.size := sizeWord
      aluctl.io.vclr := udec.io.vclr
      aluctl.io.bitMemActive := bitMemActive
      aluctl.io.bitOperandSel := bitop.io.operandSel
      aluctl.io.bitDataByte := bitop.io.dataByte
      aluctl.io.bitOperandByte := bitop.io.operandByte
      aluctl.io.h8Read := h8Read
      aluctl.io.intRead := intRead
      aluctl.io.specialRead := (udec.io.busCtl === BusCtl.Read.U(2)).?(
        memRead, ccrRead)
      aluctl.io.imm8ext := imm8ext
      aluctl.io.litConst := litConst
      aluctl.io.tempData := intrf.io.tempData
      alu.io.a    := aluctl.io.aMux
      alu.io.b    := aluctl.io.bMux
      alu.io.cin  := ccr.io.cFlag
      alu.io.op   := aluctl.io.bitAluOp
      alu.io.word := sizeWord

    connectAluPath()

    def connectCcrPath() =
      ccrctl.io.size := sizeWord
      ccrctl.io.aSel := udec.io.aSel
      ccrctl.io.bitCcrOp := aluctl.io.bitCcrOp
      ccrctl.io.bitFlagCtl := aluctl.io.bitFlagCtl
      ccrctl.io.bitVclr := aluctl.io.bitVclr
      ccrctl.io.aluY := alu.io.y
      ccrctl.io.aluH := alu.io.hout
      ccrctl.io.aluV := alu.io.vout
      ccrctl.io.aluC := alu.io.cout
      ccrctl.io.h8Read := h8Read
      ccrctl.io.imm8 := opx.io.imm8
      ccrctl.io.memData := biu.io.rdata
      ccrctl.io.specialMem := (udec.io.aSel === ASel.Special.U(2)) &
        (udec.io.busCtl === BusCtl.Read.U(2))
      ccr.io.flagCtl := stepEn.?(ccrctl.io.flagCtl, FlagCtl.None.U(3))
      ccr.io.resN := ccrctl.io.resN
      ccr.io.resZ := ccrctl.io.resZ
      ccr.io.resH := ccrctl.io.resH
      ccr.io.hwV := ccrctl.io.hwV
      ccr.io.hwC := ccrctl.io.hwC
      ccr.io.ldWe := stepEn & ccrctl.io.ldWe
      ccr.io.ldVal := ccrctl.io.ldVal

    connectCcrPath()

    def connectWriteback() =
      wb.io.size := sizeWord
      wb.io.wsel := udec.io.wsel
      wb.io.aSel := udec.io.aSel
      wb.io.intIdx := udec.io.intIdx
      wb.io.h8IdxCtl := udec.io.h8Idx
      wb.io.busCtl := udec.io.busCtl
      wb.io.h8Idx := h8Idx
      wb.io.h8Sel3 := h8Sel3
      wb.io.bitAluOp := aluctl.io.bitAluOp
      wb.io.bitRegWe := aluctl.io.bitRegWe
      wb.io.bitMemStore := bitMemStore
      wb.io.aluY := alu.io.y
      wb.io.busAddr := busAddr
      h8rf.io.waddr := wb.io.h8Waddr
      h8rf.io.wdata := wb.io.h8Wdata
      h8rf.io.wmask := wb.io.h8Wmask
      h8rf.io.we := stepEn & wb.io.h8We
      intrf.io.waddr := wb.io.intWaddr
      intrf.io.wdata := wb.io.intWdata
      intrf.io.we := stepEn & wb.io.intWe
      biu.io.addr := wb.io.biuAddr
      biu.io.wdata := wb.io.biuWdata
      biu.io.busCtl := wb.io.biuBusCtl
      biu.io.word := wb.io.biuWord
      stepEn := (wb.io.biuBusCtl === BusCtl.None.U(2)) | io.bus.rdy

    connectWriteback()

    val doFetch      = udec.io.busCtl === BusCtl.Fetch.U(2)
    val bitMemExtLoad = bitMemActive & (udec.io.busCtl === BusCtl.Read.U(2)) &
      (udec.io.intIdx === IntIdx.PC.U(2))
    val fetchSwapped = biu.io.rdata.asBits.bits(7, 0) ## biu.io.rdata.asBits.bits(15, 8)
    def connectFetchAndSequencer() =
      when((doFetch | bitMemExtLoad) & biu.io.rdy)(ir := fetchSwapped.asUInt)
      when(bitMemActive & (udec.io.busCtl === BusCtl.Read.U(2)) &
        (udec.io.intIdx === IntIdx.IReg.U(2)) & biu.io.rdy)(bitMemByte := memByte.asUInt)
      useq.io.seqSrc   := udec.io.seqSrc
      useq.io.cond     := udec.io.cond
      useq.io.seqAux   := udec.io.seqAux
      useq.io.literal  := udec.io.literal
      useq.io.dispatch := coarse.io.dispatch
      useq.io.condZ    := ccr.io.zFlag
      useq.io.aluGe    := !alu.io.cout
      useq.io.intBit   := sizeWord.?(intRead.asBits.bit(6),
        udec.io.vclr.?(intRead.asBits.bit(5), intRead.asBits.bit(0)))
      useq.io.trapNum  := ir.asBits.bits(13, 12).asUInt
      useq.io.stepEn   := stepEn
      useq.io.wordBad := preds.fold(false.B)(_.io.wordBad)
      useq.io.nibbleBad := preds.fold(false.B)(_.io.nibbleBad)
      useq.io.wakePend := wakePend
      when(stepEn & bitMemReturn) {
        bitMemActive := false.B
        bitMemWrite := false.B
      }
      when(stepEn & bitPrefixHead) {
        bitMemActive := true.B
        bitMemWrite := firstOp.bit(0)
      }
      bcond.io.cc := opx.io.rdImm
      bcond.io.hnzvc := ccr.io.hnzvc
      useq.io.ccTaken := bcond.io.taken

    connectFetchAndSequencer()

    def connectIrqAndBus() =
      irqctl.io.irq := io.irq
      irqctl.io.nmi := io.nmi
      irqctl.io.irqAck := useq.io.irqAck
      irqctl.io.trapAck := useq.io.trapAck
      irqctl.io.trapIndex := useq.io.trapIndex
      irqctl.io.iFlag := ccr.io.iFlag
      useq.io.debugPend := false.B
      useq.io.nmiPend := irqctl.io.nmiPend
      useq.io.irqPend := irqctl.io.irqPend
      ccr.io.setI     := useq.io.irqAck
      io.bus.addr  := biu.io.bus.addr
      io.bus.wdata := biu.io.bus.wdata
      io.bus.we    := biu.io.bus.we
      io.bus.wmask := biu.io.bus.wmask
      io.bus.req   := biu.io.bus.req
      biu.io.bus.rdata := io.bus.rdata
      biu.io.bus.rdy   := io.bus.rdy

    connectIrqAndBus()

    // Retire trace is lowered into DV bind collateral and stripped in production.
    val probe = summon[Interface[CoreProbe]]
    layer("DV"):
      probe.traceH8    <== h8rf.io.dbg
      probe.tracePc    <== intrf.io.dbgPc
      probe.traceCcr   <== ccr.io.hnzvc
      probe.traceFetch <== useq.io.retire
