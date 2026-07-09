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
    urom.io.clock  := io.clock; urom.io.reset  := io.reset

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
    // Ptr indexes Rn (word[6:4]); with vclr set it selects the fixed SP = R7
    // (stack pushes/pops address SP, which no field encodes). SP microwords don't
    // update V, so reusing vclr here is free.
    when(udec.io.h8Idx === H8Idx.Ptr.U(2))(
      h8field := udec.io.vclr.?(7.U(4), (0.B(1) ## opx.io.bit3.asBits).asUInt))
    val h8Idx  = h8field.asBits.bits(ri, 0).asUInt
    val h8Sel3 = h8field.asBits.bit(3)

    // byte-aligned H8 read: selected byte into [7:0] for byte ops
    val h8Byte = h8Sel3.?(h8rf.io.rdata.asBits.bits(7, 0), h8rf.io.rdata.asBits.bits(15, 8))
    val h8Read = sizeWord.?(h8rf.io.rdata, (0.B(8) ## h8Byte).asUInt)

    // imm8 sign-extended: correct for branch disp8 (16-bit PC add) and harmless
    // for byte ALU ops (which use only [7:0]).
    val abs8PageAddr = (udec.io.aSel === ASel.Zero.U(2)) & (udec.io.bSel === BSel.Imm8.U(2)) &
      (udec.io.aluOp === AluOp.Pass.U(4)) & udec.io.wsel & udec.io.regWe &
      (udec.io.intIdx === IntIdx.IReg.U(2))
    val vec8Addr = (udec.io.aSel === ASel.Zero.U(2)) & (udec.io.bSel === BSel.Imm8.U(2)) &
      (udec.io.aluOp === AluOp.Pass.U(4)) & udec.io.wsel & udec.io.regWe &
      (udec.io.intIdx === IntIdx.PC.U(2))
    val imm8sign = opx.io.imm8.asBits.bit(7).?(0xff.B(8), 0.B(8))
    val imm8top  = (0xff.B(8) ## opx.io.imm8.asBits).asUInt
    val imm8zero = (0.B(8) ## opx.io.imm8.asBits).asUInt
    val imm8ext  = abs8PageAddr.?(imm8top,
      vec8Addr.?(imm8zero, (imm8sign ## opx.io.imm8.asBits).asUInt))
    val addsSubsLit = (udec.io.bSel === BSel.Lit.U(2)) &
      (udec.io.literal === 0.U(parameter.upcBits)) & sizeWord &
      udec.io.regWe & (!udec.io.wsel) &
      (udec.io.h8Idx === H8Idx.RdReg.U(2)) &
      ((udec.io.aluOp === AluOp.Add.U(4)) | (udec.io.aluOp === AluOp.Sub.U(4)))
    val addsSubsConst = ir.asBits.bit(15).?(2.U(parameter.dataWidth),
      1.U(parameter.dataWidth))
    val litConst = addsSubsLit.?(addsSubsConst,
      (0.B(8) ## udec.io.literal.asBits.bits(7, 0)).asUInt)

    // register-file reads (single port each)
    h8rf.io.raddr  := h8Idx
    intrf.io.raddr := udec.io.intIdx

    val savedCcr = RegInit(0.U(parameter.byteWidth))
    when(useq.io.irqAck)(savedCcr := ccr.io.ccrByte)
    val ccrWord = sizeWord.?((savedCcr.asBits ## 0.B(8)).asUInt,
      (0.B(8) ## ccr.io.ccrByte.asBits).asUInt)
    val intRead = (udec.io.intIdx === IntIdx.CcrSrc.U(2)).?(ccrWord, intrf.io.rdata)

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

    // ALU A mux
    val aMux = Wire(UInt(parameter.dataWidth))
    aMux := h8Read
    when(udec.io.aSel === ASel.Int.U(2))(aMux := intRead)
    when(udec.io.aSel === ASel.Zero.U(2))(aMux := 0.U(parameter.dataWidth))
    when(udec.io.aSel === ASel.Mem.U(2))(aMux := memRead)

    // ALU B mux
    val bMux = Wire(UInt(parameter.dataWidth))
    bMux := h8Read
    when(udec.io.bSel === BSel.Imm8.U(2))(bMux := imm8ext)
    when(udec.io.bSel === BSel.Int.U(2))(bMux := intRead)
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
    ccr.io.hwV     := udec.io.vclr.?(false.B, alu.io.vout) // SHLL/SHLR/SHAR/ROT* force V=0
    ccr.io.hwC     := alu.io.cout
    ccr.io.ldWe    := udec.io.flagCtl === FlagCtl.LoadCcr.U(3)
    val ccrRegByte = h8Read.asBits.bits(7, 0).asUInt
    val ccrLogicByte = alu.io.y.asBits.bits(7, 0).asUInt
    val ccrImmByte = (udec.io.aSel === ASel.Int.U(2)).?(ccrLogicByte,
      (udec.io.aSel === ASel.H8.U(2)).?(ccrRegByte, opx.io.imm8))
    // RTE pops CCR from the high byte of mem[SP].
    ccr.io.ldVal   := (udec.io.aSel === ASel.Mem.U(2)).?(
      biu.io.rdata.asBits.bits(15, 8).asUInt, ccrImmByte)

    // writeback: WSel picks the H8 or internal file (shared index/data). Byte ops
    // replicate the result byte and let wmask place it into the selected half.
    val toInternal = udec.io.wsel
    val yByte = alu.io.y.asBits.bits(7, 0)
    h8rf.io.waddr  := h8Idx
    h8rf.io.wdata  := sizeWord.?(alu.io.y, (yByte ## yByte).asUInt)
    h8rf.io.wmask  := sizeWord.?(3.U(parameter.wmaskWidth),
      h8Sel3.?(1.U(parameter.wmaskWidth), 2.U(parameter.wmaskWidth)))
    h8rf.io.we     := udec.io.regWe & (!toInternal)
    // H8Idx.RsReg tags the internal move that reads IREG and writes PC.
    val pcFromIReg = toInternal & udec.io.regWe & (udec.io.aSel === ASel.Int.U(2)) &
      (udec.io.intIdx === IntIdx.IReg.U(2)) & (udec.io.aluOp === AluOp.PassA.U(4)) &
      (udec.io.h8Idx === H8Idx.RsReg.U(2))
    val intWaddr = pcFromIReg.?(IntIdx.PC.U(2), udec.io.intIdx)
    // PC is architecturally even: clear bit0 on a PC write so an odd branch/jump
    // displacement aligns the target down (matches the model, no trap).
    val toPc = intWaddr === IntIdx.PC.U(2)
    intrf.io.waddr := intWaddr
    intrf.io.wdata := toPc.?((alu.io.y.asBits.bits(parameter.dataWidth - 1, 1) ## 0.B(1)).asUInt,
      alu.io.y)
    intrf.io.we    := udec.io.regWe & toInternal

    // SP stack bus ops address R7 while write data can come from the internal file.
    biu.io.addr   := busAddr
    biu.io.wdata  := sizeWord.?(alu.io.y, (h8Byte ## h8Byte).asUInt)
    biu.io.busCtl := udec.io.busCtl
    biu.io.word   := sizeWord

    // memory is big-endian; the decoder-visible IR is byte-swapped (first byte in
    // [7:0]). Byte data reads select the lane from the requested address.
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
    val firstOp = ir.asBits.bits(7, 0)
    val wordRegPage = (firstOp === 0x09.B(8)) | (firstOp === 0x0d.B(8)) |
      (firstOp === 0x19.B(8)) | (firstOp === 0x1d.B(8))
    useq.io.wordBad := wordRegPage.?(ir.asBits.bit(15) | ir.asBits.bit(11),
      ir.asBits.bit(11))
    val secondHigh = ir.asBits.bits(15, 12)
    val byteCcrPage = (firstOp === 0x02.B(8)) | (firstOp === 0x03.B(8))
    val addsSubsPage = (firstOp === 0x0b.B(8)) | (firstOp === 0x1b.B(8))
    useq.io.nibbleBad := byteCcrPage.?(
      secondHigh =/= 0.B(4),
      addsSubsPage.?(ir.asBits.bits(14, 11) =/= 0.B(4),
        ir.asBits.bits(14, 12) =/= 0.B(3)))

    // Bcc condition evaluator: cond nibble = instr[3:0], flags from CCR.
    val fN = ccr.io.hnzvc.asBits.bit(3)
    val fZ = ccr.io.hnzvc.asBits.bit(2)
    val fV = ccr.io.hnzvc.asBits.bit(1)
    val fC = ccr.io.hnzvc.asBits.bit(0)
    val cc = opx.io.rdImm
    val taken = Wire(Bool())
    taken := true.B                                       // 0 BRA
    when(cc === 0x1.U(4))(taken := false.B)               // BRN
    when(cc === 0x2.U(4))(taken := !(fC | fZ))            // BHI
    when(cc === 0x3.U(4))(taken := fC | fZ)               // BLS
    when(cc === 0x4.U(4))(taken := !fC)                   // BCC
    when(cc === 0x5.U(4))(taken := fC)                    // BCS
    when(cc === 0x6.U(4))(taken := !fZ)                   // BNE
    when(cc === 0x7.U(4))(taken := fZ)                    // BEQ
    when(cc === 0x8.U(4))(taken := !fV)                   // BVC
    when(cc === 0x9.U(4))(taken := fV)                    // BVS
    when(cc === 0xa.U(4))(taken := !fN)                   // BPL
    when(cc === 0xb.U(4))(taken := fN)                    // BMI
    when(cc === 0xc.U(4))(taken := !(fN ^ fV))            // BGE
    when(cc === 0xd.U(4))(taken := fN ^ fV)               // BLT
    when(cc === 0xe.U(4))(taken := !(fZ | (fN ^ fV)))     // BGT
    when(cc === 0xf.U(4))(taken := fZ | (fN ^ fV))        // BLE
    useq.io.ccTaken := taken

    // Interrupt latches, polled by the fetch mainloop (no async hardware entry).
    // IRQ is maskable by CCR.I; NMI is not. Entry acks the latch and sets I.
    val irqLatch = RegInit(false.B)
    val nmiLatch = RegInit(false.B)
    when(useq.io.irqAck)(irqLatch := false.B) // ack clears; set below is dominant
    when(io.irq)(irqLatch := true.B)
    when(useq.io.irqAck)(nmiLatch := false.B)
    when(io.nmi)(nmiLatch := true.B)
    useq.io.irqPend := (irqLatch & (!ccr.io.iFlag)) | nmiLatch
    ccr.io.setI     := useq.io.irqAck

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
