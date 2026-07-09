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
    val bcd    = BcdAdjust.instantiate(parameter)
    val bcond  = BranchCond.instantiate(parameter)
    val readsel = CoreReadSelect.instantiate(parameter)
    val imm    = CoreImmediates.instantiate(parameter)
    val preds  = CorePredicates.instantiate(parameter)
    val div    = DivAssist.instantiate(parameter)
    val bitctl = CoreBitControl.instantiate(parameter)
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
      readsel.io.clock := io.clock; readsel.io.reset := io.reset
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

    def connectReadSelect() =
      readsel.io.irqAck := useq.io.irqAck
      readsel.io.size := sizeWord
      readsel.io.h8IdxCtl := udec.io.h8Idx
      readsel.io.intIdx := udec.io.intIdx
      readsel.io.vclr := udec.io.vclr
      readsel.io.rdReg := opx.io.rdReg
      readsel.io.rdImm := opx.io.rdImm
      readsel.io.rsReg := opx.io.rsReg
      readsel.io.bit3 := opx.io.bit3
      readsel.io.h8Rdata := h8rf.io.rdata
      readsel.io.intRdata := intrf.io.rdata
      readsel.io.ccrByte := ccr.io.ccrByte

    connectReadSelect()
    val h8Idx = readsel.io.h8Idx
    val h8Sel3 = readsel.io.h8Sel3
    val h8Byte = readsel.io.h8Byte
    val h8Read = readsel.io.h8Read
    val intRead = readsel.io.intRead

    def connectImmediateAndReads() =
      imm.io.ir := ir
      imm.io.imm8 := opx.io.imm8
      imm.io.literal := udec.io.literal
      imm.io.aSel := udec.io.aSel
      imm.io.bSel := udec.io.bSel
      imm.io.aluOp := udec.io.aluOp
      imm.io.h8Idx := udec.io.h8Idx
      imm.io.intIdx := udec.io.intIdx
      imm.io.wsel := udec.io.wsel
      imm.io.regWe := udec.io.regWe
      imm.io.size := sizeWord
      imm.io.irqVectorAddr := irqctl.io.irqVectorAddr
      h8rf.io.raddr  := h8Idx
      intrf.io.raddr := udec.io.intIdx

    connectImmediateAndReads()

    val bitMemActive = RegInit(false.B)
    val bitMemWrite = RegInit(false.B)
    val bitMemByte = RegInit(0.U(parameter.byteWidth))

    def connectBitInputs() =
      bitop.io.firstOp := firstOp.asUInt
      bitop.io.ir := ir
      bitop.io.intRead := intRead
      bitop.io.h8Byte := h8Byte
      bitop.io.bit3 := opx.io.bit3
      bitop.io.bitMemActive := bitMemActive
      bitop.io.bitMemByte := bitMemByte
      bitop.io.cFlag := ccr.io.cFlag
      bitop.io.aSel := udec.io.aSel
      bitop.io.bSel := udec.io.bSel
      bitop.io.vclr := udec.io.vclr

    connectBitInputs()
    val bitMemStore = bitMemActive & bitMemWrite & bitop.io.operandSel &
      bitop.io.ctlRegWe & (!udec.io.wsel) & (!sizeWord)

    def connectPredicates() =
      preds.io.firstOp := firstOp.asUInt
      preds.io.ir := ir
      preds.io.seqSrc := udec.io.seqSrc
      preds.io.cond := udec.io.cond
      preds.io.intIdx := udec.io.intIdx
      preds.io.intRead := intRead
      preds.io.iregData := intrf.io.iregData
      preds.io.tempData := intrf.io.tempData
      preds.io.cFlag := ccr.io.cFlag
      preds.io.bitMemActive := bitMemActive
      preds.io.bitMemWrite := bitMemWrite
      bitctl.io.firstOp := firstOp.asUInt
      bitctl.io.ir := ir
      bitctl.io.coarseDispatch := coarse.io.dispatch
      bitctl.io.seqSrc := udec.io.seqSrc
      bitctl.io.cond := udec.io.cond
      bitctl.io.literal := udec.io.literal
      bitctl.io.bitMemActive := bitMemActive
      bitctl.io.bitMemExtBad := preds.io.bitMemExtBad

    connectPredicates()

    val daaFinal = (firstOp === 0x0f.B(8)) & (udec.io.flagCtl === FlagCtl.LoadCcr.U(3)) &
      udec.io.regWe & (!udec.io.wsel)
    val dasFinal = (firstOp === 0x1f.B(8)) & (udec.io.flagCtl === FlagCtl.LoadCcr.U(3)) &
      udec.io.regWe & (!udec.io.wsel)
    val bcdFinal = daaFinal | dasFinal
    def connectBcd() =
      bcd.io.value := h8Byte
      bcd.io.ccrByte := ccr.io.ccrByte
      bcd.io.isDaa := daaFinal

    connectBcd()

    val stackBus = (udec.io.h8Idx === H8Idx.Ptr.U(2)) & udec.io.vclr &
      ((udec.io.busCtl === BusCtl.Read.U(2)) | (udec.io.busCtl === BusCtl.Write.U(2)))
    val h8BusAddr = (udec.io.busCtl === BusCtl.Write.U(2)) & (!udec.io.vclr) &
      (udec.io.h8Idx === H8Idx.Ptr.U(2)) & (udec.io.aSel === ASel.Int.U(2))
    val extIRegBus = (udec.io.busCtl === BusCtl.Read.U(2)) &
      (udec.io.aSel === ASel.Mem.U(2)) & udec.io.wsel & udec.io.regWe &
      (udec.io.intIdx === IntIdx.IReg.U(2))
    val busAddr = extIRegBus.?(intrf.io.pcData,
      (stackBus | h8BusAddr).?(h8rf.io.rdata, intrf.io.rdata))
    val memByte = busAddr.asBits.bit(0).?(
      biu.io.rdata.asBits.bits(7, 0), biu.io.rdata.asBits.bits(15, 8))
    val memRead = sizeWord.?(biu.io.rdata, (0.B(8) ## memByte).asUInt)

    def connectAluPath() =
      aluctl.io.seqSrc := udec.io.seqSrc
      aluctl.io.literal := udec.io.literal
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
      aluctl.io.bitCtlASelInt := bitop.io.ctlASelInt
      aluctl.io.bitCtlAlu := bitop.io.ctlAlu
      aluctl.io.bitCtlFlag := bitop.io.ctlFlag
      aluctl.io.bitCtlRegWe := bitop.io.ctlRegWe
      aluctl.io.bitCtlVclr := bitop.io.ctlVclr
      aluctl.io.bitDataByte := bitop.io.dataByte
      aluctl.io.bitOperandByte := bitop.io.operandByte
      aluctl.io.h8Read := h8Read
      aluctl.io.intRead := intRead
      aluctl.io.memRead := memRead
      aluctl.io.imm8ext := imm.io.imm8ext
      aluctl.io.litConst := imm.io.litConst
      aluctl.io.tempData := intrf.io.tempData
      aluctl.io.bcdFinal := bcdFinal
      aluctl.io.bcdAdjust := bcd.io.adjust
      aluctl.io.divSub := div.io.sub
      div.io.firstOp := firstOp.asUInt
      div.io.flagCtl := udec.io.flagCtl
      div.io.intIdx := udec.io.intIdx
      div.io.regWe := udec.io.regWe
      div.io.wsel := udec.io.wsel
      div.io.aSel := udec.io.aSel
      div.io.bSel := udec.io.bSel
      div.io.aluOp := udec.io.aluOp
      div.io.size := sizeWord
      div.io.vclr := udec.io.vclr
      div.io.bitAluOp := aluctl.io.bitAluOp
      div.io.bitRegWe := aluctl.io.bitRegWe
      div.io.oldCcr := ccr.io.ccrByte
      div.io.iregData := intrf.io.iregData
      div.io.tempData := intrf.io.tempData
      div.io.h8Data := h8rf.io.rdata
      alu.io.a    := aluctl.io.aMux
      alu.io.b    := aluctl.io.bMux
      alu.io.cin  := ccr.io.cFlag
      alu.io.op   := aluctl.io.bitAluOp
      alu.io.word := sizeWord

    connectAluPath()

    def connectCcrPath() =
      ccrctl.io.size := sizeWord
      ccrctl.io.aSel := udec.io.aSel
      ccrctl.io.bitASelInt := aluctl.io.bitASelInt
      ccrctl.io.bitFlagCtl := aluctl.io.bitFlagCtl
      ccrctl.io.bitVclr := aluctl.io.bitVclr
      ccrctl.io.aluY := alu.io.y
      ccrctl.io.aluH := alu.io.hout
      ccrctl.io.aluV := alu.io.vout
      ccrctl.io.aluC := alu.io.cout
      ccrctl.io.h8Read := h8Read
      ccrctl.io.imm8 := opx.io.imm8
      ccrctl.io.memData := biu.io.rdata
      ccrctl.io.oldCcr := ccr.io.ccrByte
      ccrctl.io.daaFinal := daaFinal
      ccrctl.io.bcdFinal := bcdFinal
      ccrctl.io.divFlagLoad := div.io.flagLoad
      ccrctl.io.divCcrByte := div.io.ccrByte
      ccr.io.flagCtl := ccrctl.io.flagCtl
      ccr.io.resN := ccrctl.io.resN
      ccr.io.resZ := ccrctl.io.resZ
      ccr.io.resH := ccrctl.io.resH
      ccr.io.hwV := ccrctl.io.hwV
      ccr.io.hwC := ccrctl.io.hwC
      ccr.io.ldWe := ccrctl.io.ldWe
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
      wb.io.iregData := intrf.io.iregData
      wb.io.divPack := div.io.pack
      wb.io.divPackData := div.io.packData
      wb.io.divStep := div.io.step
      wb.io.divStepData := div.io.stepData
      h8rf.io.waddr := wb.io.h8Waddr
      h8rf.io.wdata := wb.io.h8Wdata
      h8rf.io.wmask := wb.io.h8Wmask
      h8rf.io.we := wb.io.h8We
      intrf.io.waddr := wb.io.intWaddr
      intrf.io.wdata := wb.io.intWdata
      intrf.io.we := wb.io.intWe
      biu.io.addr := wb.io.biuAddr
      biu.io.wdata := wb.io.biuWdata
      biu.io.busCtl := wb.io.biuBusCtl
      biu.io.word := wb.io.biuWord

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
      useq.io.call     := udec.io.call
      useq.io.literal  := udec.io.literal
      useq.io.dispatch := bitctl.io.dispatch
      useq.io.condZ    := ccr.io.zFlag
      useq.io.condC    := preds.io.condC
      useq.io.busRdy   := biu.io.rdy
      useq.io.wordBad := preds.io.wordBad
      useq.io.nibbleBad := preds.io.nibbleBad
      when(bitctl.io.memReturn) {
        bitMemActive := false.B
        bitMemWrite := false.B
      }
      when(bitctl.io.prefixHead) {
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
      irqctl.io.iFlag := ccr.io.iFlag
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

    // retire-trace surface, lowered into the DV layer bind collateral (stripped
    // in production). doFetch marks one fetch per instruction.
    val probe = summon[Interface[CoreProbe]]
    layer("DV"):
      probe.traceH8    <== h8rf.io.dbg
      probe.tracePc    <== intrf.io.dbgPc
      probe.traceCcr   <== ccr.io.hnzvc
      probe.traceFetch <== doFetch
