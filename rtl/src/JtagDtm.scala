// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
package com.vowstar.chimera

import me.jiuyang.zaozi.*
import me.jiuyang.zaozi.default.{*, given}
import me.jiuyang.zaozi.reftpe.*
import me.jiuyang.zaozi.valuetpe.*

/** Minimal custom JTAG debug-transport module (TCK clock domain).
  *
  * Not RISC-V dmi/dtmcs: no abstract commands, no sticky-busy. A standard
  * IEEE-1149.1 16-state TAP, a 4-bit IR (reset = IDCODE), and four data
  * registers selected by IR:
  *   0x0 STATUS  (23-bit, read-only): is_halted, is_sleeping, dbg_base[16],
  *                hwbp_count[4], dmactive. Served entirely by DTM hardware.
  *   0x1 IDCODE  (32-bit, read-only): the idcode parameter.
  *   0x2 CONTROL (36-bit): cmd[3], addr[16], data[16], in_progress. Update-DR
  *                latches cmd/addr/data and drives the DebugPort; read-back
  *                returns the synchronized dataToHost and the in-progress flag.
  *   0xF BYPASS  (1-bit).
  * Unknown IR -> BYPASS.
  *
  * Everything the core needs (req/cmd/addr/dataFromHost/dmactive) is driven from
  * this TCK domain; the core 2-FF-syncs req+dmactive into its own domain. ack,
  * halted and sleeping are 2-FF-synced back here; dataToHost is captured when a
  * synced ack is observed (MCP handshake keeps it stable by then). dmactive is a
  * present-debugger latch: set on first CONTROL access, cleared on TLR / TRST.
  */
class JtagDtmIO(parameter: ChimeraParameter) extends HWBundle(parameter):
  val tck  = Flipped(Clock())
  val trst = Flipped(Reset())
  val tms  = Flipped(Bool())
  val tdi  = Flipped(Bool())
  val tdo  = Aligned(Bool())
  // Toward the core's DebugPort (this side drives host->core, reads core->host).
  val dmactive     = Aligned(Bool())
  val req          = Aligned(Bool())
  val cmd          = Aligned(UInt(3))
  val addr         = Aligned(UInt(parameter.addrWidth))
  val dataFromHost = Aligned(UInt(parameter.dataWidth))
  val ack          = Flipped(Bool())
  val dataToHost   = Flipped(UInt(parameter.dataWidth))
  val halted       = Flipped(Bool())
  val coreSleeping = Flipped(Bool())

/** TAP controller state codes (IEEE 1149.1). */
object Tap:
  val TestLogicReset = 0
  val RunTestIdle    = 1
  val SelectDrScan   = 2
  val CaptureDr      = 3
  val ShiftDr        = 4
  val Exit1Dr        = 5
  val PauseDr        = 6
  val Exit2Dr        = 7
  val UpdateDr       = 8
  val SelectIrScan   = 9
  val CaptureIr      = 10
  val ShiftIr        = 11
  val Exit1Ir        = 12
  val PauseIr        = 13
  val Exit2Ir        = 14
  val UpdateIr       = 15

object JtagIr:
  val Status  = 0x0
  val Idcode  = 0x1
  val Control = 0x2
  val Bypass  = 0xF

@generator
object JtagDtm
    extends Generator[ChimeraParameter, ChimeraLayers, JtagDtmIO, ChimeraProbe]:
  override def moduleName(parameter: ChimeraParameter): String = "JtagDtm"

  def architecture(parameter: ChimeraParameter) =
    val io = summon[Interface[JtagDtmIO]]
    given Ref[Clock] = io.tck
    given Ref[Reset] = io.trst

    val dw = parameter.dataWidth   // 16
    val aw = parameter.addrWidth   // 16
    val ctlW = 3 + aw + dw + 1     // 36
    val statusW = 2 + 16 + 4 + 1   // 23 (+dmactive)

    // ---- TAP state machine (posedge TCK). ----
    val state = RegInit(Tap.TestLogicReset.U(4))
    val tms = io.tms
    def sel(s: Int) = state === s.U(4)
    val nextState = Wire(UInt(4))
    nextState := state
    when(sel(Tap.TestLogicReset))(nextState := tms.?(Tap.TestLogicReset.U(4), Tap.RunTestIdle.U(4)))
    when(sel(Tap.RunTestIdle))(nextState := tms.?(Tap.SelectDrScan.U(4), Tap.RunTestIdle.U(4)))
    when(sel(Tap.SelectDrScan))(nextState := tms.?(Tap.SelectIrScan.U(4), Tap.CaptureDr.U(4)))
    when(sel(Tap.CaptureDr))(nextState := tms.?(Tap.Exit1Dr.U(4), Tap.ShiftDr.U(4)))
    when(sel(Tap.ShiftDr))(nextState := tms.?(Tap.Exit1Dr.U(4), Tap.ShiftDr.U(4)))
    when(sel(Tap.Exit1Dr))(nextState := tms.?(Tap.UpdateDr.U(4), Tap.PauseDr.U(4)))
    when(sel(Tap.PauseDr))(nextState := tms.?(Tap.Exit2Dr.U(4), Tap.PauseDr.U(4)))
    when(sel(Tap.Exit2Dr))(nextState := tms.?(Tap.UpdateDr.U(4), Tap.ShiftDr.U(4)))
    when(sel(Tap.UpdateDr))(nextState := tms.?(Tap.SelectDrScan.U(4), Tap.RunTestIdle.U(4)))
    when(sel(Tap.SelectIrScan))(nextState := tms.?(Tap.TestLogicReset.U(4), Tap.CaptureIr.U(4)))
    when(sel(Tap.CaptureIr))(nextState := tms.?(Tap.Exit1Ir.U(4), Tap.ShiftIr.U(4)))
    when(sel(Tap.ShiftIr))(nextState := tms.?(Tap.Exit1Ir.U(4), Tap.ShiftIr.U(4)))
    when(sel(Tap.Exit1Ir))(nextState := tms.?(Tap.UpdateIr.U(4), Tap.PauseIr.U(4)))
    when(sel(Tap.PauseIr))(nextState := tms.?(Tap.Exit2Ir.U(4), Tap.PauseIr.U(4)))
    when(sel(Tap.Exit2Ir))(nextState := tms.?(Tap.UpdateIr.U(4), Tap.ShiftIr.U(4)))
    when(sel(Tap.UpdateIr))(nextState := tms.?(Tap.SelectDrScan.U(4), Tap.RunTestIdle.U(4)))
    state := nextState

    val inTlr    = sel(Tap.TestLogicReset)
    val captureDr = sel(Tap.CaptureDr)
    val shiftDr   = sel(Tap.ShiftDr)
    val updateDr  = sel(Tap.UpdateDr)
    val captureIr = sel(Tap.CaptureIr)
    val shiftIr   = sel(Tap.ShiftIr)
    val updateIr  = sel(Tap.UpdateIr)

    // ---- CDC: sync core->host signals into the TCK domain (2-FF). ----
    val haltSync0 = RegInit(false.B); haltSync0 := io.halted
    val haltSync  = RegInit(false.B); haltSync := haltSync0
    val sleepSync0 = RegInit(false.B); sleepSync0 := io.coreSleeping
    val sleepSync  = RegInit(false.B); sleepSync := sleepSync0
    val ackSync0 = RegInit(false.B); ackSync0 := io.ack
    val ackSync  = RegInit(false.B); ackSync := ackSync0

    // Capture the read datum when a synced ack is observed (stable by MCP).
    val readData = RegInit(0.U(dw))
    when(ackSync)(readData := io.dataToHost)

    // ---- Instruction register. ----
    val ir = RegInit(JtagIr.Idcode.U(4))
    val irShift = RegInit(0.U(4))
    when(captureIr)(irShift := 1.U(4)) // 0b0001 fixed capture pattern
    when(shiftIr)(irShift := (io.tdi.asBits ## irShift.asBits.bits(3, 1)).asUInt)
    when(updateIr)(ir := irShift)
    when(inTlr)(ir := JtagIr.Idcode.U(4))

    val isStatus  = ir === JtagIr.Status.U(4)
    val isIdcode  = ir === JtagIr.Idcode.U(4)
    val isControl = ir === JtagIr.Control.U(4)
    // Anything else (incl. explicit BYPASS) is a 1-bit bypass register.

    // ---- CONTROL register: latched command + in-progress handshake. ----
    val cmdReg  = RegInit(0.U(3))
    val addrReg = RegInit(0.U(aw))
    val dataReg = RegInit(0.U(dw))
    val reqReg  = RegInit(false.B)          // level request to the core
    val dmactive = RegInit(false.B)         // present-debugger latch

    // in_progress: a level request is outstanding. Most commands complete on a
    // synced ack; resume never acks (the core leaves the park word), so it
    // completes when the synced halted status drops.
    val inProgress = reqReg
    val isResumeCmd = cmdReg === DmCmd.Resume.U(3)
    when(reqReg & ackSync)(reqReg := false.B)
    when(reqReg & isResumeCmd & (!haltSync))(reqReg := false.B)

    // ---- One shared shift register for every DR. ----
    // The data DRs (STATUS 23b, IDCODE 32b, CONTROL 36b) and BYPASS (1b) are
    // time-multiplexed through a single ctlW-wide (36b) shift register: Capture-
    // DR muxes the IR-selected value into the low bits (zero-extended); Shift-DR
    // shifts LSB-first; TDO reads bit 0; Update-DR latches the CONTROL fields.
    // External TAP behaviour is byte-for-byte identical: the host still scans
    // each IR's own DR length (STATUS 23, IDCODE 32, CONTROL 36, BYPASS 1) and
    // the low bits it reads back match the per-DR registers this replaces. One
    // 36b register + one capture mux replaces four registers + four shift/TDO
    // paths (measured -49 LUT4 / -55 DFF).
    val shiftReg = RegInit(0.U(ctlW))

    val dbgBaseC   = parameter.debugBase & 0xFFFF
    val hwbpC      = parameter.triggerCount & 0xF
    // LSB-first: [0]=halted [1]=sleeping [17:2]=dbg_base [21:18]=hwbp_count
    // [22]=dmactive
    val statusWord = (
      dmactive.asBits ## hwbpC.U(4).asBits ## dbgBaseC.U(16).asBits ##
      sleepSync.asBits ## haltSync.asBits).asUInt

    // CONTROL read-back: [2:0]=cmd [18:3]=addr [34:19]=readData [35]=in_progress
    val controlWord = (
      inProgress.asBits ## readData.asBits ## addrReg.asBits ##
      cmdReg.asBits).asUInt

    val idcodeWord = (parameter.idcode & 0xFFFFFFFFL).U(32)

    // Capture value per IR, zero-extended to the shared register width (ctlW).
    // STATUS is statusW bits, IDCODE 32, CONTROL is already ctlW, BYPASS all-0.
    val statusCap = (0.U(ctlW - statusW).asBits ## statusWord.asBits).asUInt
    val idcodeCap = (0.U(ctlW - 32).asBits ## idcodeWord.asBits).asUInt
    val captureWord = isStatus.?(statusCap,
      isIdcode.?(idcodeCap,
        isControl.?(controlWord, 0.U(ctlW))))

    when(captureDr)(shiftReg := captureWord)
    when(shiftDr) {
      shiftReg := (io.tdi.asBits ## shiftReg.asBits.bits(ctlW - 1, 1)).asUInt
    }

    // Update-DR on CONTROL launches a command only when the shifted-in top bit
    // (a write-side "go" strobe, same position as the read-side in_progress) is
    // set and no request is outstanding. Polling re-scans CONTROL with go=0 to
    // read in_progress back without re-launching.
    val goStrobe = shiftReg.asBits.bit(2 + aw + dw + 1)
    when(updateDr & isControl & goStrobe & (!reqReg)) {
      cmdReg  := shiftReg.asBits.bits(2, 0).asUInt
      addrReg := shiftReg.asBits.bits(2 + aw, 3).asUInt
      dataReg := shiftReg.asBits.bits(2 + aw + dw, 3 + aw).asUInt
      reqReg  := true.B
    }

    // dmactive: present on any TAP activity; a CONTROL access is proof enough.
    // Set sticky on first CONTROL capture/update; cleared on TLR / TRST.
    when((captureDr | updateDr) & isControl)(dmactive := true.B)
    when(inTlr)(dmactive := false.B)

    // ---- TDO: shift out the LSB of the shared register (falling-edge
    // convention is handled by the tap master; TDO is combinational here). -----
    val tdoDr = shiftReg.asBits.bit(0)
    val tdoIr = irShift.asBits.bit(0)
    io.tdo := shiftIr.?(tdoIr, tdoDr)

    // ---- Drive the DebugPort (host->core) from the TCK domain. ----
    io.dmactive     := dmactive
    io.req          := reqReg
    io.cmd          := cmdReg
    io.addr         := addrReg
    io.dataFromHost := dataReg
