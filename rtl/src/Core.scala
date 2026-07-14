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
  *
  * parameter.pipeline off (default) is the single-cycle datapath: the decoded
  * microword drives the ALU/CCR/writeback/bus directly in one cycle. On, it is
  * a two-stage microword pipeline: F (ROM data -> decode -> operand read/select
  * -> next-fetch address) and X (ALU -> CCR fold -> writeback -> bus); a
  * pipeline register carries the F-stage operands into X and a conservative
  * interlock bubbles X and holds F on a RAW hazard.
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
  // High while parked in the DebugEntry wait word. Present when the core can
  // park: a DM halt, a hardware-breakpoint, or a single-step redirect into
  // DebugEntry.
  val is_halted = Option.when(
    parameter.dm || parameter.hardwareBreakpoint || parameter.singleStep)(Aligned(Bool()))
  // Optional debug-module port; present only with parameter.debug.
  val dbg   = Option.when(parameter.debug)(Aligned(new DebugPort(parameter)))

@generator
object Core extends Generator[ChimeraParameter, ChimeraLayers, CoreIO, CoreProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "Core"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[CoreIO]]
    given Ref[Clock] = io.clock
    given Ref[Reset] = io.reset

    val coarse = CoarseDecoder.instantiate(parameter)
    if parameter.romHex then
      val image = MicrocodeImage.sparse(parameter.strictDecode, parameter.debug).toMap
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
    // The trigger / MMIO block owns the dbgBase window: present whenever a
    // self-hosted feature (hardware breakpoint or single-step) needs it.
    val trig   = Option.when(parameter.mmio)(
      TriggerUnit.instantiate(parameter))

    // instruction register (holds the fetched word microcode reads)
    val ir = RegInit(0.U(parameter.dataWidth))

    // F-stage view of the opcode. In the single-cycle config it is `ir`. In the
    // pipeline it is the X-stage fetch forwarded in the same cycle, so the
    // dispatch microword right behind a fetch reads the fresh opcode.
    val irForward = Wire(UInt(parameter.dataWidth))
    val irView = Wire(UInt(parameter.dataWidth))
    if parameter.pipeline then irView := irForward else irView := ir

    def connectClockedDecode() =
      h8rf.io.clock  := io.clock; h8rf.io.reset  := io.reset
      intrf.io.clock := io.clock; intrf.io.reset := io.reset
      ccr.io.clock   := io.clock; ccr.io.reset   := io.reset
      irqctl.io.clock := io.clock; irqctl.io.reset := io.reset
      biu.io.clock.foreach(_ := io.clock); biu.io.reset.foreach(_ := io.reset)
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
    // Special-literal value, selected by literal[1:0]: 0 adds/subs const,
    // 1 IRQ vector, 2 reset SP addr, 3 reset PC addr. Split into independent
    // high/low byte muxes: the reset vectors share the vt_base high byte, so
    // one 4-input mux each packs tighter on a LUT4 fabric than a 16-bit mux.
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

    // Bit-memory state (BSET/BCLR/BST on an @Rn operand). Updated in X (pipeline)
    // or in the same cycle (single-cycle).
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
    // Single-cycle memory read: resolved live in the same cycle as the microword.
    val memByte = busAddr.asBits.bit(0).?(
      biu.io.rdata.asBits.bits(7, 0), biu.io.rdata.asBits.bits(15, 8))
    val memRead = sizeWord.?(biu.io.rdata, (0.B(8) ## memByte).asUInt)

    val fBusRead = udec.io.busCtl === BusCtl.Read.U(2)

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
      // Bus-read / CCR operand for the operand mux. In the pipeline the bus-read
      // datum is resolved in X (from live biu.rdata), so pass CCR here; in the
      // single-cycle config the read datum is live so mux it in directly.
      if parameter.pipeline then
        aluctl.io.specialRead := ccrRead
      else
        aluctl.io.specialRead := fBusRead.?(memRead, ccrRead)
      aluctl.io.imm8ext := imm8ext
      aluctl.io.litConst := litConst
      aluctl.io.tempData := intrf.io.tempData

    connectAluControl()

    // ---- shared X-stage / sequencer plumbing wires ----
    val fetchSwapped = biu.io.rdata.asBits.bits(7, 0) ## biu.io.rdata.asBits.bits(15, 8)
    val stepEn = Wire(Bool())
    // Bus-ready for step gating. With the MMIO window the BIU inserts a wait on
    // an in-range access, so step must honour biu.io.rdy; otherwise it is the
    // transparent external rdy (byte-identical when the window is absent).
    val busReady = if parameter.mmio then biu.io.rdy else io.bus.rdy

    if parameter.pipeline then {

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
      stepEn := (biu.io.busCtl === BusCtl.None.U(2)) | busReady

    connectWriteback()

    // ir writeback and bit-memory state, in X, gated by xValid & rdy.
    val xDoFetch = xBusCtl === BusCtl.Fetch.U(2)
    val xBitMemExtLoad = xBitMemActive & (xBusCtl === BusCtl.Read.U(2)) &
      (xIntIdx === IntIdx.PC.U(2))
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
    // The retire redirect no longer needs a hardware interlock: a trap arm and
    // an RTE pop each carry a microcode delay-slot word (TrapaDelay / RteRetire)
    // that registers the pending / in-service change before the retire point
    // reaches F, so the redirect target is always resolved from settled state.

    val hazard = xValid & (hazH8 | hazInt | hazCcr | hazAluGe | hazLoop | hazBit)

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

    } else {

    // ======================= single-cycle datapath ============================
    // Pipeline outputs unused; tie the F/X inputs the sequencer ignores.
    useq.io.hazard   := false.B
    useq.io.xSeqSrc  := 0.U(2)
    useq.io.xCond    := 0.U(3)
    useq.io.xSeqAux  := false.B
    useq.io.xLiteral := 0.U(parameter.upcBits)
    irForward := ir

    def connectAluPath() =
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
      stepEn := (wb.io.biuBusCtl === BusCtl.None.U(2)) | busReady

    connectWriteback()

    val doFetch      = udec.io.busCtl === BusCtl.Fetch.U(2)
    val bitMemExtLoad = bitMemActive & (udec.io.busCtl === BusCtl.Read.U(2)) &
      (udec.io.intIdx === IntIdx.PC.U(2))
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

    }

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

    // ======================= trigger / MMIO debug block =======================
    // Behind parameter.mmio (hardware breakpoint or single-step). The block owns
    // the MMIO registers (reached through the BIU decode), the registered
    // comparators, and the single-step control register; every net here vanishes
    // when no self-hosted feature is enabled. `hwbpFire` and `stepFire` are
    // registered latches that the routing block below steers to DebugEntry (DM
    // present) or the trap-2 handler (self-hosted). `trap2Suppress` freezes both
    // while a self-hosted trap-2 debug handler runs (see the FSM below).
    val trap2Suppress = Wire(Bool())
    trap2Suppress := false.B
    trig.foreach { t =>
      t.io.clock := io.clock
      t.io.reset := io.reset
      // Instruction bp: the fetch address, qualified by a completing fetch.
      // Data bp: the BIU access address, qualified by a completing read/write.
      val busFetch = biu.io.busCtl === BusCtl.Fetch.U(2)
      val busRead  = biu.io.busCtl === BusCtl.Read.U(2)
      val busWrite = biu.io.busCtl === BusCtl.Write.U(2)
      t.io.fetchAddr  := biu.io.addr
      t.io.fetchValid := busFetch & biu.io.rdy
      t.io.dataAddr   := biu.io.addr
      t.io.dataRead   := busRead & biu.io.rdy
      t.io.dataWrite  := busWrite & biu.io.rdy
      t.io.retire     := useq.io.retire
      t.io.suppress   := trap2Suppress
      // MMIO register port from the BIU decode.
      t.io.mmioSel   := biu.io.mmioSel.get
      t.io.mmioWrite := biu.io.mmioWrite.get
      t.io.mmioIndex := biu.io.mmioIndex.get
      t.io.mmioWdata := biu.io.mmioWdata.get
      t.io.mmioWmask := biu.io.mmioWmask.get
      biu.io.mmioRdata.get := t.io.mmioRdata
    }

    // ======================= debug-module controller ==========================
    // Behind parameter.debug only. Synchronizes the DM request, holds the core
    // in the DebugEntry park word, dispatches the primitive microwords, injects
    // the host word into AUX / drives PC and the bus address, and taps AUX back
    // to the host. Every net here vanishes when debug is off.
    //
    // `dmHalt` carries the DM halt latch and `dmActiveReg` the synced dmactive
    // to the unified routing driver below.
    var dmHalt: Option[Referable[Bool]] = None
    var dmActiveReg: Option[Referable[Bool]] = None
    if parameter.debug then
      val dm = io.dbg.get

      val activeSync0 = RegInit(false.B); activeSync0 := dm.dmactive
      val activeSync  = RegInit(false.B); activeSync := activeSync0
      dmActiveReg = Some(activeSync)
      val reqSync0 = RegInit(false.B); reqSync0 := dm.req
      val reqSync  = RegInit(false.B); reqSync := reqSync0

      val exec = useq.io.xpc
      val parked = useq.io.halted.get

      val cmd = dm.cmd
      val isHalt   = cmd === DmCmd.Halt.U(4)
      val isResume = cmd === DmCmd.Resume.U(4)
      val isReadPc = cmd === DmCmd.ReadPc.U(4)
      val isReadCcr = cmd === DmCmd.ReadCcr.U(4)
      // Hardware-dispatched primitives: the sequencer jumps into the matching
      // DebugSlots routine. readPC / readCCR are answered by the controller
      // directly (Core-side muxes) and never dispatch; halt/resume hold/release.
      val isPrim   = (cmd === DmCmd.MemRead.U(4)) |
        (cmd === DmCmd.MemWrite.U(4)) | (cmd === DmCmd.SetPc.U(4))

      // One request is served per req assertion; `served` also gates ack. Halt is
      // taken while running; primitives, resume and readPC only while parked.
      val served = RegInit(false.B)
      val request = activeSync & reqSync & (!served)
      val accept = request &
        (isHalt | ((isPrim | isResume | isReadPc | isReadCcr) & parked))
      when(accept)(served := true.B)
      when(!reqSync)(served := false.B)

      // Halt latch forces the retire redirect into DebugEntry; resume releases it.
      // readPC keeps the core parked, so it does not touch the latch. A concurrent
      // hardware-breakpoint park resolves through the same latch (see below).
      val haltLatch = RegInit(false.B)
      when(accept & (isHalt | isPrim))(haltLatch := true.B)
      when(accept & isResume)(haltLatch := false.B)
      // A hardware-breakpoint or single-step fire while the debugger is present
      // also parks: fold it into the halt latch so a concurrent haltreq + fire
      // resolve to one DebugEntry park, cleared by the same resume.
      trig.foreach { t =>
        when(t.io.hwbpFire)(haltLatch := true.B)
        t.io.stepFire.foreach(sf => when(sf)(haltLatch := true.B))
      }

      // Auto-halt-memop-resume: a small orchestration FSM so the host issues ONE
      // memRead / memWrite regardless of run state. A primitive arriving while the
      // core runs (not parked) auto-halts it (asserts the halt latch; the core
      // parks at the next retire), lets the existing accept path run the primitive,
      // then auto-resumes back to the program when the primitive returns to the
      // park word. `wasRunning` remembers to resume only when the core was running,
      // so a host-initiated halt-then-memop stays halted (original semantics).
      // Reuses the halt / memop / resume machinery: no BIU arbitration, no bus
      // steal, no datapath mux — orchestration only.
      val autoResume = Wire(Bool())
      autoResume := false.B
      if parameter.dmAutoHalt then
        val wasRunning = RegInit(false.B)
        // A fresh primitive request while running: no accept yet (accept needs
        // parked), so raise the halt latch and remember to resume afterwards.
        val autoHaltReq = request & isPrim & (!parked) & (!haltLatch)
        when(autoHaltReq) {
          haltLatch  := true.B
          wasRunning := true.B
        }
        // The primitive has been dispatched and has returned to the park word:
        // `served` set and parked again. If it was an auto-halt, resume once and
        // release the latch. Clearing wasRunning makes this a single pulse.
        val primDone = served & parked & wasRunning
        when(primDone) {
          haltLatch  := false.B
          wasRunning := false.B
        }
        autoResume := primDone
      end if
      dmHalt = Some(haltLatch)

      useq.io.dbgReq.get    := accept & isPrim
      useq.io.dbgCmd.get    := cmd
      useq.io.dbgResume.get := (accept & isResume) | autoResume

      // AUX injection for the mem-write data-staging word.
      val atMemWriteStage = exec === Ucode.DebugMemWrite.U(parameter.upcBits)
      intrf.io.dmWe.get   := atMemWriteStage
      intrf.io.dmData.get := dm.dataFromHost

      // The mem primitives address dm.addr directly (decoupled from the operand
      // selectors); set-PC drives the PC flop with dm.addr.
      val atMemRead  = exec === Ucode.DebugMemRead.U(parameter.upcBits)
      val atMemWrite = exec === (Ucode.DebugMemWrite + 1).U(parameter.upcBits)
      val atSetPc    = exec === Ucode.DebugSetPc.U(parameter.upcBits)
      when(atMemRead | atMemWrite)(biu.io.addr := dm.addr)
      when(atSetPc) {
        intrf.io.waddr := IntIdx.PC.U(2)
        intrf.io.wdata := dm.addr
        intrf.io.we := stepEn
      }

      // Non-destructive CCR: capture the user CCR at the fresh session entry
      // (the retire that parks from running code), hold it across the whole
      // debugger session, and restore it on every resume microword. A program-
      // buffer snippet ends in TRAPA#2 and re-parks via the trapDebug path, and a
      // mem primitive returns to the park word by a literal branch; neither is a
      // fresh entry, so neither re-captures. Every resume restores the saved
      // value, so the injected STC reads the true CCR and the final resume-to-
      // program sees pristine flags.
      val savedDbgCcr = RegInit(0x20.U(parameter.byteWidth))
      when(useq.io.dbgFreshEntry.get)(savedDbgCcr := ccr.io.ccrByte)
      // On the DebugResume microword, drive the CCR direct-load path with the
      // captured value (LDC semantics), overriding ccrctl for that one word.
      val atResume = exec === Ucode.DebugResume.U(parameter.upcBits)
      when(atResume) {
        ccr.io.ldWe  := stepEn
        ccr.io.ldVal := savedDbgCcr
      }

      // readPC / readCCR are answered without microcode: while parked, tap the
      // live PC or the captured CCR to the host and ack immediately (the core
      // stays parked). Key the mux on the latched cmd and parked, not on
      // `served`, so the datum holds steady across the whole parked window while
      // the DTM captures it. memRead returns the AUX word its routine staged.
      dm.ack        := served & parked
      val ccrToHost = (0.B(8) ## savedDbgCcr.asBits).asUInt
      dm.dataToHost := (isReadPc & parked).?(intrf.io.pcData,
        (isReadCcr & parked).?(ccrToHost, intrf.io.auxData))
      dm.halted     := parked
    end if

    // ======================= trap-2 suppression FSM ===========================
    // A dedicated `trap2Active` bit tracks a self-hosted trap-2 debug handler.
    // Set on the trap-2 trapAck (a step / hardware-breakpoint / TRAPA#2 that took
    // the trap-2 vector); cleared on the first non-nested RTE — an RTE while no
    // NMI/IRQ is in service, so a nested interrupt's RTE never clears it. While
    // set (and no debugger is present) step and breakpoint fires are suppressed
    // so the handler is not re-interrupted by its own debug features. When a
    // debugger is present, dmActive gates the suppression off (step/bp fire in
    // any mode). The RTE restore is implicit: because fires are suppressed for
    // the whole handler, the pre-trap debug-enable state is preserved unless the
    // handler itself wrote a debug MMIO register (`dbgRegTouched`), in which case
    // the handler's new programming stands.
    val dmPresent = dmActiveReg.getOrElse(false.B)
    if parameter.hardwareBreakpoint || parameter.singleStep then
      val trap2Active   = RegInit(false.B)
      val dbgRegTouched = RegInit(false.B)
      val trap2Ack = useq.io.trapAck & (useq.io.trapIndex === 2.U(2))
      val serviceActive = irqctl.io.serviceActive.get
      val trap2Rte = useq.io.rteAck & (!serviceActive)
      // Set dominates a same-cycle clear (a fresh trap-2 nested past an RTE).
      when(trap2Rte & (!trap2Ack)) {
        trap2Active   := false.B
        dbgRegTouched := false.B
      }
      when(trap2Ack)(trap2Active := true.B)
      // Any MMIO debug-register write during the handler is a reprogram; sticky
      // until the handler returns.
      trig.foreach(t => when(trap2Active & t.io.mmioTouched)(dbgRegTouched := true.B))
      // Suppress fires only for a self-hosted handler (no debugger present).
      trap2Suppress := trap2Active & (!dmPresent)

      // FSM invariant: the clear (trap2Rte) is guarded by !serviceActive so an
      // RTE taken while an NMI/IRQ is in service never lifts the suppression, and
      // by !trap2Ack so a fresh trap-2 in the same cycle wins; trap2Active is a
      // single bit, so it can neither double-restore nor clear under nesting.
      // check-trap2-suppress exercises this (a handler-internal bp that must not
      // re-fire, and a nested NMI whose RTE must not lift the suppression).

    // ======================= debug redirect routing ===========================
    // Unified driver for the sequencer's debug/trap-2 inputs. A DM (when present)
    // supplies dmActive and the halt latch; a hardware breakpoint or a single-step
    // fire splits by debugger presence: with a DM it parks in DebugEntry via
    // debugPend (folded into the halt latch above), without one it traps to the
    // trap-2 handler via hwbpTrap. A SLEEP-as-software-breakpoint parks only with
    // a debugger present (SLEEP needs an external wake); without one it stays the
    // normal low-power wait. is_halted mirrors the sequencer park state.
    // Self-hosted fire (step or breakpoint) that routes to the trap-2 handler.
    val selfHostedFire = trig.map { t =>
      val hw = t.io.hwbpFire
      t.io.stepFire.fold(hw: Referable[Bool])(hw | _)
    }.getOrElse(false.B: Referable[Bool])
    // A SLEEP with a debugger present parks in DebugEntry (software breakpoint).
    val sleepPark = if parameter.dm then useq.io.sleeping & dmPresent else false.B
    // debugPend: the DM halt latch (already includes a concurrent HWBP park) plus
    // a SLEEP-as-swbp park when a debugger is present.
    useq.io.debugPend := dmHalt.getOrElse(false.B) | sleepPark
    useq.io.dmActive.foreach(_ := dmPresent)
    useq.io.hwbpTrap.foreach { p =>
      // Self-hosted step / breakpoint: only when no debugger is present. With a
      // DM the fire parks via the halt latch instead.
      p := selfHostedFire & (!dmPresent)
    }
    io.is_halted.foreach(_ := useq.io.halted.get)

    // Retire trace is lowered into DV bind collateral and stripped in production.
    val probe = summon[Interface[CoreProbe]]
    layer("DV"):
      probe.traceH8    <== h8rf.io.dbg
      probe.tracePc    <== intrf.io.dbgPc
      probe.traceCcr   <== ccr.io.hnzvc
      probe.traceFetch <== useq.io.retire
