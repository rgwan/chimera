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
  * microcode. Two-stage microword pipeline: F (ROM data -> decode -> operand
  * read/select -> next-fetch address) and X (ALU -> CCR fold -> writeback ->
  * bus). A pipeline register carries the F-stage operands and control fields
  * into X; a conservative interlock bubbles X and holds F on a RAW hazard.
  */
class CoreIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val clock = Flipped(Clock())
  val reset = Flipped(Reset())
  val irq   = Flipped(Bool())
  val nmi   = Flipped(Bool())
  val irq_number = Flipped(UInt(parameter.irqNumberWidth))
  val vt_base = Flipped(UInt(8))
  val bus   = Aligned(new SramBus(parameter))
  val core_sleeping = Aligned(Bool()) // high while parked in SLEEP

@generator
object Core extends Generator[ChimeraParameter, ChimeraLayers, CoreIO, CoreProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Core"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val coarse = CoarseDecoder.instantiate(parameter)
    if parameter.romHex then
      val image = MicrocodeImage.sparse(parameter.strictDecode).toMap
      os.write.over(os.pwd / "urom.memh",
        (0 until parameter.uromDepth).map(a =>
          f"${image.getOrElse(a, BigInt(0))}%09x").mkString("\n") + "\n")
    val urom = MicrocodeRom.instantiate(parameter)
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

    // Forward the just-fetched word from the X-stage fetch to the F-stage
    // decoders in the same cycle, so the dispatch microword right behind the
    // fetch reads the fresh opcode without a stall (see connectXState).
    val irForward = Wire(UInt(parameter.dataWidth))
    val irView = Wire(UInt(parameter.dataWidth))
    irView := irForward

    def connectClockedDecode() =
      h8rf.io.clock  := io.clock; h8rf.io.reset  := io.reset
      intrf.io.clock := io.clock; intrf.io.reset := io.reset
      ccr.io.clock   := io.clock; ccr.io.reset   := io.reset
      irqctl.io.clock := io.clock; irqctl.io.reset := io.reset
      useq.io.clock  := io.clock; useq.io.reset  := io.reset
      urom.io.clock  := io.clock; urom.io.reset  := io.reset
      urom.io.addr := useq.io.upc
      udec.io.word := urom.io.data
      coarse.io.word := irView
      opx.io.word    := irView

    connectClockedDecode()

    val firstOp = irView.asBits.bits(7, 0)
    val sizeWord = udec.io.size

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
    val sel0 = udec.io.literal.asBits.bit(0)
    val sel1 = udec.io.literal.asBits.bit(1)
    val vecHi = irqctl.io.irqVectorAddr.asBits.bits(15, 8).asUInt
    val vecLo = irqctl.io.irqVectorAddr.asBits.bits(7, 0).asUInt
    val addsSubsLo = irView.asBits.bit(15).?(2.U(8), 1.U(8))
    val specialHi = sel1.?(io.vt_base, sel0.?(vecHi, 0.U(8)))
    val specialLo = sel1.?(sel0.?(0x06.U(8), 0x02.U(8)),
      sel0.?(vecLo, addsSubsLo))
    val specialValue = (specialHi.asBits ## specialLo.asBits).asUInt
    val litConst = udec.io.literal.asBits.bit(8).?(specialValue,
      (0.B(8) ## udec.io.literal.asBits.bits(7, 0)).asUInt)

    def connectReads() =
      h8rf.io.raddr  := h8Idx
      intrf.io.raddr := udec.io.intIdx

    connectReads()

    // Bit-memory state (BSET/BCLR/BST on an @Rn operand). Updated in X.
    val bitMemActive = RegInit(false.B)
    val bitMemWrite = RegInit(false.B)
    val bitMemByte = RegInit(0.U(parameter.byteWidth))

    def connectBitInputs() =
      bitop.io.ir := irView
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
      p.io.ir := irView
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

    // ---- F-stage operand mux and bit passthroughs (steer the ALU inputs). ----
    def connectAluControl() =
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
      // Bus-read / CCR operand for the F-stage mux. The bus-read datum is
      // resolved in X (from live biu.rdata); pass CCR here so the non-bus
      // Special path (stc ccr) latches correctly.
      aluctl.io.specialRead := ccrRead
      aluctl.io.imm8ext := imm8ext
      aluctl.io.litConst := litConst
      aluctl.io.tempData := intrf.io.tempData

    connectAluControl()

    val fBusRead = udec.io.busCtl === BusCtl.Read.U(2)

    // ======================= pipeline register (F -> X) =======================
    val advance = useq.io.advance
    val xValid  = useq.io.xValid

    val xAluOp     = RegInit(0.U(4))
    val xASel      = RegInit(0.U(2))
    val xBSel      = RegInit(0.U(2))
    val xIntIdx    = RegInit(0.U(2))
    val xH8IdxCtl  = RegInit(0.U(2))
    val xBusCtl    = RegInit(0.U(2))
    val xFlagCtl   = RegInit(0.U(3))
    val xSize      = RegInit(false.B)
    val xWsel      = RegInit(false.B)
    val xRegWe     = RegInit(false.B)
    val xVclr      = RegInit(false.B)
    val xAMux      = RegInit(0.U(parameter.dataWidth))
    val xBMux      = RegInit(0.U(parameter.dataWidth))
    val xBusAddr   = RegInit(0.U(parameter.dataWidth))
    val xH8Idx     = RegInit(0.U(parameter.regIndexBits))
    val xH8Sel3    = RegInit(false.B)
    val xH8Read    = RegInit(0.U(parameter.dataWidth))
    val xImm8      = RegInit(0.U(8))
    val xBitCcrOp  = RegInit(false.B)
    val xBitAluOp  = RegInit(0.U(4))
    val xBitFlagCtl = RegInit(0.U(3))
    val xBitRegWe  = RegInit(false.B)
    val xBitVclr   = RegInit(false.B)
    val xBitMemStore = RegInit(false.B)
    val xBusRead   = RegInit(false.B)
    val xBitMemActive = RegInit(false.B)
    val xSeqSrc    = RegInit(0.U(2))
    val xSeqAux    = RegInit(false.B)
    val xCond      = RegInit(0.U(3))
    val xLiteral   = RegInit(0.U(parameter.upcBits))
    val xBitPrefixHead = RegInit(false.B)
    val xBitMemReturn  = RegInit(false.B)
    val xBitMemWrite   = RegInit(false.B)
    val xFirstOp   = RegInit(0.U(8))

    when(advance) {
      xAluOp     := udec.io.aluOp
      xASel      := udec.io.aSel
      xBSel      := udec.io.bSel
      xIntIdx    := udec.io.intIdx
      xH8IdxCtl  := udec.io.h8Idx
      xBusCtl    := udec.io.busCtl
      xFlagCtl   := udec.io.flagCtl
      xSize      := sizeWord
      xWsel      := udec.io.wsel
      xRegWe     := udec.io.regWe
      xVclr      := udec.io.vclr
      xAMux      := aluctl.io.aMux
      xBMux      := aluctl.io.bMux
      xBusAddr   := busAddr
      xH8Idx     := h8Idx
      xH8Sel3    := h8Sel3
      xH8Read    := h8Read
      xImm8      := opx.io.imm8
      xBitCcrOp  := aluctl.io.bitCcrOp
      xBitAluOp  := aluctl.io.bitAluOp
      xBitFlagCtl := aluctl.io.bitFlagCtl
      xBitRegWe  := aluctl.io.bitRegWe
      xBitVclr   := aluctl.io.bitVclr
      xBitMemStore := bitMemStore
      xBusRead   := fBusRead
      xBitMemActive := bitMemActive
      xSeqSrc    := udec.io.seqSrc
      xSeqAux    := udec.io.seqAux
      xCond      := udec.io.cond
      xLiteral   := udec.io.literal
      xBitPrefixHead := bitPrefixHead
      xBitMemReturn  := bitMemReturn
      xBitMemWrite   := bitMemWrite
      xFirstOp   := firstOp.asUInt
    }

    // ======================= X stage ==========================================
    // Bus transactions live in X: the address was latched in F, write data is
    // the X-stage ALU result, and read data feeds back into the X-stage ALU A.
    val xMemByte = xBusAddr.asBits.bit(0).?(
      biu.io.rdata.asBits.bits(7, 0), biu.io.rdata.asBits.bits(15, 8))
    val xMemRead = xSize.?(biu.io.rdata, (0.B(8) ## xMemByte).asUInt)
    val xSpecialSel = xASel === ASel.Special.U(2)
    // For a bus-read microword the Special A source is the live memory datum,
    // not the F-latched value.
    val xAluA = (xSpecialSel & xBusRead).?(xMemRead, xAMux)

    def connectAluPath() =
      alu.io.a    := xAluA
      alu.io.b    := xBMux
      alu.io.cin  := ccr.io.cFlag
      alu.io.op   := xBitAluOp
      alu.io.word := xSize

    connectAluPath()

    val stepEn = Wire(Bool())
    val xWrite = xValid & stepEn

    def connectCcrPath() =
      ccrctl.io.size := xSize
      ccrctl.io.aSel := xASel
      ccrctl.io.bitCcrOp := xBitCcrOp
      ccrctl.io.bitFlagCtl := xBitFlagCtl
      ccrctl.io.bitVclr := xBitVclr
      ccrctl.io.aluY := alu.io.y
      ccrctl.io.aluH := alu.io.hout
      ccrctl.io.aluV := alu.io.vout
      ccrctl.io.aluC := alu.io.cout
      ccrctl.io.h8Read := xH8Read
      ccrctl.io.imm8 := xImm8
      ccrctl.io.memData := biu.io.rdata
      ccrctl.io.specialMem := xSpecialSel & xBusRead
      ccr.io.flagCtl := xWrite.?(ccrctl.io.flagCtl, FlagCtl.None.U(3))
      ccr.io.resN := ccrctl.io.resN
      ccr.io.resZ := ccrctl.io.resZ
      ccr.io.resH := ccrctl.io.resH
      ccr.io.hwV := ccrctl.io.hwV
      ccr.io.hwC := ccrctl.io.hwC
      ccr.io.ldWe := xWrite & ccrctl.io.ldWe
      ccr.io.ldVal := ccrctl.io.ldVal

    connectCcrPath()

    def connectWriteback() =
      wb.io.size := xSize
      wb.io.wsel := xWsel
      wb.io.aSel := xASel
      wb.io.intIdx := xIntIdx
      wb.io.h8IdxCtl := xH8IdxCtl
      wb.io.busCtl := xBusCtl
      wb.io.h8Idx := xH8Idx
      wb.io.h8Sel3 := xH8Sel3
      wb.io.bitAluOp := xBitAluOp
      wb.io.bitRegWe := xBitRegWe
      wb.io.bitMemStore := xBitMemStore
      wb.io.aluY := alu.io.y
      wb.io.busAddr := xBusAddr
      h8rf.io.waddr := wb.io.h8Waddr
      h8rf.io.wdata := wb.io.h8Wdata
      h8rf.io.wmask := wb.io.h8Wmask
      h8rf.io.we := xWrite & wb.io.h8We
      intrf.io.waddr := wb.io.intWaddr
      intrf.io.wdata := wb.io.intWdata
      intrf.io.we := xWrite & wb.io.intWe
      biu.io.addr := wb.io.biuAddr
      biu.io.wdata := wb.io.biuWdata
      // No bus transaction in a bubble cycle.
      biu.io.busCtl := xValid.?(wb.io.biuBusCtl, BusCtl.None.U(2))
      biu.io.word := wb.io.biuWord
      stepEn := (biu.io.busCtl === BusCtl.None.U(2)) | io.bus.rdy

    connectWriteback()

    // ir writeback and bit-memory state, in X, gated by xValid & rdy.
    val xDoFetch = xBusCtl === BusCtl.Fetch.U(2)
    val xBitMemExtLoad = xBitMemActive & (xBusCtl === BusCtl.Read.U(2)) &
      (xIntIdx === IntIdx.PC.U(2))
    val fetchSwapped = biu.io.rdata.asBits.bits(7, 0) ## biu.io.rdata.asBits.bits(15, 8)
    val irWriteX = xValid & (xDoFetch | xBitMemExtLoad) & biu.io.rdy
    irForward := irWriteX.?(fetchSwapped.asUInt, ir)
    def connectXState() =
      when(xWrite & (xDoFetch | xBitMemExtLoad) & biu.io.rdy)(ir := fetchSwapped.asUInt)
      when(xWrite & xBitMemActive & (xBusCtl === BusCtl.Read.U(2)) &
        (xIntIdx === IntIdx.IReg.U(2)) & biu.io.rdy)(bitMemByte := xMemByte.asUInt)
      when(xWrite & xBitMemReturn) {
        bitMemActive := false.B
        bitMemWrite := false.B
      }
      when(xWrite & xBitPrefixHead) {
        bitMemActive := true.B
        bitMemWrite := xFirstOp.asBits.bit(0)
      }

    connectXState()

    // ======================= hazard interlock =================================
    // A microword in F that reads register / flag / state the executing (X)
    // microword writes must wait one cycle. Conservative over-approximation.
    val xH8We = xValid & wb.io.h8We
    val xIntWe = xValid & wb.io.intWe
    val xCcrWrite = xValid & (((xFlagCtl =/= FlagCtl.None.U(3)) | ccrctl.io.ldWe))
    // loopCount is touched by a loop-init (Next+aux) or a LoopNZ tail branch.
    val xLoopTouch = xValid & (((xSeqSrc === SeqSrc.Next.U(2)) & xSeqAux) |
      ((xSeqSrc === SeqSrc.Literal.U(2)) & (xCond === Cond.LoopNZ.U(3))))
    // aluPred is written only by a Next+AluGe word, so only that in X can
    // hazard an F-stage AluGe branch (not any executing word).
    val xSetsAluPred = xValid & (xSeqSrc === SeqSrc.Next.U(2)) &
      (xCond === Cond.AluGe.U(3))
    val xBitStateChange = xValid & (xBitPrefixHead | xBitMemReturn |
      (xBitMemActive & (xBusCtl === BusCtl.Read.U(2)) & (xIntIdx === IntIdx.IReg.U(2))))
    // Only a genuine pending-state mutation makes the F-stage retire redirect
    // wait: a trap arm (sets trapPend), or an interrupt/RTE ack (changes the
    // in-service latches). A plain two-word retire that just redirects to
    // fetch changes nothing, so it must not stall — that false hazard was
    // ~half of all bubbles (once per instruction).
    val xPendChange = (xValid & (xSeqSrc === SeqSrc.Dispatch.U(2)) & xSeqAux) |
      useq.io.irqAck | useq.io.rteAck

    val fReadsH8 = (udec.io.aSel === ASel.H8.U(2)) | (udec.io.bSel === BSel.H8.U(2)) |
      (udec.io.h8Idx === H8Idx.Ptr.U(2)) | stackBus | h8BusAddr
    // The F word reads intrf through the operand port (udec.intIdx) and,
    // for a bus op, through the dedicated pc/ireg address ports.
    val busActive = udec.io.busCtl =/= BusCtl.None.U(2)
    val fReadsIntPort = (udec.io.aSel === ASel.Int.U(2)) |
      (udec.io.bSel === BSel.Int.U(2)) | (udec.io.cond === Cond.IntBit.U(3))
    val fBusIregAddr = busActive & (!(stackBus | h8BusAddr)) & (!pcBus)
    val fReadsCcr = (udec.io.aSel === ASel.Special.U(2)) & (!fBusRead)
    val fCondFlags = (udec.io.cond === Cond.Z.U(3)) |
      (udec.io.cond === Cond.CcInstr.U(3))
    val fCondAluGe = udec.io.cond === Cond.AluGe.U(3)
    val fCondLoop = udec.io.cond === Cond.LoopNZ.U(3)
    // A retire redirect consumes the pending state.
    val fRetirePoint = (udec.io.seqSrc === SeqSrc.Return.U(2)) & (!udec.io.seqAux)

    val xIntW = wb.io.intWaddr
    val hazH8 = xH8We & fReadsH8 & (xH8Idx === h8Idx)
    val hazInt = xIntWe & (
      (fReadsIntPort & (xIntW === udec.io.intIdx)) |
      (pcBus & (xIntW === IntIdx.PC.U(2))) |
      (fBusIregAddr & (xIntW === IntIdx.IReg.U(2))))
    val hazCcr = xCcrWrite & (fCondFlags | fReadsCcr)
    val hazAluGe = xSetsAluPred & fCondAluGe
    val hazLoop = xLoopTouch & fCondLoop
    val hazBit = xBitStateChange
    val hazPend = xPendChange & fRetirePoint

    val hazard = xValid & (hazH8 | hazInt | hazCcr | hazAluGe | hazLoop |
      hazBit | hazPend)

    // ======================= sequencer wiring =================================
    def connectFetchAndSequencer() =
      useq.io.seqSrc   := udec.io.seqSrc
      useq.io.cond     := udec.io.cond
      useq.io.seqAux   := udec.io.seqAux
      useq.io.literal  := udec.io.literal
      useq.io.dispatch := coarse.io.dispatch
      useq.io.condZ    := ccr.io.zFlag
      useq.io.aluGe    := !alu.io.cout
      useq.io.intBit   := sizeWord.?(intRead.asBits.bit(6),
        udec.io.vclr.?(intRead.asBits.bit(5), intRead.asBits.bit(0)))
      useq.io.trapNum  := irView.asBits.bits(13, 12).asUInt
      useq.io.stepEn   := stepEn
      useq.io.hazard   := hazard
      useq.io.wordBad := preds.fold(false.B)(_.io.wordBad)
      useq.io.nibbleBad := preds.fold(false.B)(_.io.nibbleBad)
      useq.io.wakePend := wakePend
      useq.io.xSeqSrc  := xSeqSrc
      useq.io.xCond    := xCond
      useq.io.xSeqAux  := xSeqAux
      useq.io.xLiteral := xLiteral
      bcond.io.cc := opx.io.rdImm
      bcond.io.hnzvc := ccr.io.hnzvc
      useq.io.ccTaken := bcond.io.taken

    connectFetchAndSequencer()

    def connectIrqAndBus() =
      irqctl.io.irq := io.irq
      irqctl.io.nmi := io.nmi
      irqctl.io.irqNumber := io.irq_number
      irqctl.io.vtBase := io.vt_base
      irqctl.io.irqAck := useq.io.irqAck
      irqctl.io.trapAck := useq.io.trapAck
      irqctl.io.trapIndex := useq.io.trapIndex
      irqctl.io.rteAck := useq.io.rteAck
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
      io.core_sleeping := useq.io.sleeping

    connectIrqAndBus()

    // Retire trace is lowered into DV bind collateral and stripped in production.
    val probe = summon[Interface[CoreProbe]]
    layer("DV"):
      probe.traceH8    <== h8rf.io.dbg
      probe.tracePc    <== intrf.io.dbgPc
      probe.traceCcr   <== ccr.io.hnzvc
      probe.traceFetch <== useq.io.retire
