// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! H8/300 debug-module operations layered on the raw DTM command set.
//!
//! The DTM offers only mem read/write, set/read PC, and halt/resume. Everything
//! the RSP server needs is expressed in those terms.
//!
//! GPR access uses the program-buffer technique: the DM has no per-register
//! command, so a short H8 snippet that moves the target register through a RAM
//! work area is injected, PC is pointed at it, and the core is resumed. The
//! snippet ends in `TRAPA #2` (0x57 0x20) so the core re-enters debug mode
//! immediately after the move, and the original work-area bytes / PC are
//! restored afterward.

use crate::backend::JtagBackend;
use crate::dtm::Dtm;
use anyhow::Result;

/// RAM work area for the injected GPR snippet. Two 16-bit words: a 6-byte code
/// slot and a 2-byte data slot. Chosen low in RAM, above the reset vectors and
/// clear of the default stack; the caller may override.
pub const DEFAULT_CODE_AREA: u16 = 0x0100;
pub const DEFAULT_DATA_AREA: u16 = 0x0110;

/// The software-breakpoint opcode: `TRAPA #2`, big-endian bytes 0x57 0x20.
pub const TRAPA2: u16 = 0x5720;

pub struct DmH8<B: JtagBackend> {
    pub dtm: Dtm<B>,
    code_area: u16,
    data_area: u16,
}

impl<B: JtagBackend> DmH8<B> {
    pub fn new(dtm: Dtm<B>) -> Self {
        DmH8 {
            dtm,
            code_area: DEFAULT_CODE_AREA,
            data_area: DEFAULT_DATA_AREA,
        }
    }

    pub fn set_work_area(&mut self, code: u16, data: u16) {
        self.code_area = code;
        self.data_area = data;
    }

    pub fn reset(&mut self) -> Result<()> {
        self.dtm.reset()
    }

    pub fn read_idcode(&mut self) -> Result<u32> {
        self.dtm.read_idcode()
    }

    pub fn is_halted(&mut self) -> Result<bool> {
        Ok(self.dtm.read_status()?.is_halted)
    }

    pub fn halt(&mut self) -> Result<()> {
        self.dtm.halt()
    }

    pub fn resume(&mut self) -> Result<()> {
        self.dtm.resume()
    }

    pub fn read_pc(&mut self) -> Result<u16> {
        self.dtm.read_pc()
    }

    pub fn write_pc(&mut self, pc: u16) -> Result<()> {
        self.dtm.set_pc(pc)
    }

    pub fn read_mem_word(&mut self, addr: u16) -> Result<u16> {
        self.dtm.mem_read(addr)
    }

    pub fn write_mem_word(&mut self, addr: u16, data: u16) -> Result<()> {
        self.dtm.mem_write(addr, data)
    }

    /// Read a byte range. H8 memory is word-addressed BE; a read of an aligned
    /// word yields {hi, lo}. Odd start / length is handled by masking words.
    pub fn read_mem(&mut self, addr: u16, len: usize) -> Result<Vec<u8>> {
        let mut out = Vec::with_capacity(len);
        let mut a = addr;
        let mut remaining = len;
        // Handle an unaligned leading byte.
        if a & 1 == 1 && remaining > 0 {
            let w = self.dtm.mem_read(a & !1)?;
            out.push((w & 0xFF) as u8);
            a = a.wrapping_add(1);
            remaining -= 1;
        }
        while remaining >= 2 {
            let w = self.dtm.mem_read(a)?;
            out.push((w >> 8) as u8);
            out.push((w & 0xFF) as u8);
            a = a.wrapping_add(2);
            remaining -= 2;
        }
        if remaining == 1 {
            let w = self.dtm.mem_read(a)?;
            out.push((w >> 8) as u8);
        }
        Ok(out)
    }

    /// Write a byte range, read-modify-writing the two edge words when the range
    /// is not word-aligned.
    pub fn write_mem(&mut self, addr: u16, bytes: &[u8]) -> Result<()> {
        if bytes.is_empty() {
            return Ok(());
        }
        let mut a = addr;
        let mut idx = 0usize;
        // Leading unaligned byte.
        if a & 1 == 1 {
            let base = a & !1;
            let cur = self.dtm.mem_read(base)?;
            let w = (cur & 0xFF00) | bytes[idx] as u16;
            self.dtm.mem_write(base, w)?;
            a = a.wrapping_add(1);
            idx += 1;
        }
        while idx + 2 <= bytes.len() {
            let w = ((bytes[idx] as u16) << 8) | bytes[idx + 1] as u16;
            self.dtm.mem_write(a, w)?;
            a = a.wrapping_add(2);
            idx += 2;
        }
        // Trailing unaligned byte.
        if idx < bytes.len() {
            let cur = self.dtm.mem_read(a)?;
            let w = ((bytes[idx] as u16) << 8) | (cur & 0x00FF);
            self.dtm.mem_write(a, w)?;
        }
        Ok(())
    }

    /// Read GPR rN (0..7) via program buffer.
    ///
    /// Injects `MOV.W rN,@data_area:16` = 0x6B8N followed by `TRAPA #2`, saves
    /// and restores the clobbered code/data/PC. Returns the 16-bit register.
    pub fn read_gpr(&mut self, n: u8) -> Result<u16> {
        assert!(n < 8);
        let saved = self.save_work_and_pc()?;
        // 6B 8N | aa_hi aa_lo | 57 20
        let instr0 = 0x6B80u16 | (n as u16);
        self.dtm.mem_write(self.code_area, instr0)?;
        self.dtm.mem_write(self.code_area + 2, self.data_area)?;
        self.dtm.mem_write(self.code_area + 4, TRAPA2)?;
        self.dtm.set_pc(self.code_area)?;
        self.dtm.resume()?;
        self.dtm.wait_halted(true)?;
        let val = self.dtm.mem_read(self.data_area)?;
        self.restore_work_and_pc(&saved)?;
        Ok(val)
    }

    /// Write GPR rN (0..7) via program buffer.
    ///
    /// Places `value` at the data area, injects `MOV.W @data_area:16,rN` =
    /// 0x6B0N followed by `TRAPA #2`, then restores.
    pub fn write_gpr(&mut self, n: u8, value: u16) -> Result<()> {
        assert!(n < 8);
        let saved = self.save_work_and_pc()?;
        let instr0 = 0x6B00u16 | (n as u16);
        self.dtm.mem_write(self.data_area, value)?;
        self.dtm.mem_write(self.code_area, instr0)?;
        self.dtm.mem_write(self.code_area + 2, self.data_area)?;
        self.dtm.mem_write(self.code_area + 4, TRAPA2)?;
        self.dtm.set_pc(self.code_area)?;
        self.dtm.resume()?;
        self.dtm.wait_halted(true)?;
        self.restore_work_and_pc(&saved)?;
        Ok(())
    }

    /// Read the 8-bit CCR (non-destructive).
    ///
    /// The DM captures CCR at the debugger's fresh park entry and restores it on
    /// every resume, so a direct `ReadCcr` command returns the target's true CCR
    /// with no program-buffer perturbation and no scratch-register save/restore.
    /// The whole architectural state (GPRs, PC, work area, CCR) is left pristine.
    pub fn read_ccr(&mut self) -> Result<u8> {
        self.dtm.read_ccr()
    }

    fn save_work_and_pc(&mut self) -> Result<SavedWork> {
        Ok(SavedWork {
            pc: self.dtm.read_pc()?,
            code0: self.dtm.mem_read(self.code_area)?,
            code1: self.dtm.mem_read(self.code_area + 2)?,
            code2: self.dtm.mem_read(self.code_area + 4)?,
            data: self.dtm.mem_read(self.data_area)?,
        })
    }

    fn restore_work_and_pc(&mut self, s: &SavedWork) -> Result<()> {
        self.dtm.mem_write(self.code_area, s.code0)?;
        self.dtm.mem_write(self.code_area + 2, s.code1)?;
        self.dtm.mem_write(self.code_area + 4, s.code2)?;
        self.dtm.mem_write(self.data_area, s.data)?;
        self.dtm.set_pc(s.pc)?;
        Ok(())
    }
}

struct SavedWork {
    pc: u16,
    code0: u16,
    code1: u16,
    code2: u16,
    data: u16,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dtm::{ir, pack_control, Cmd, CTRL_BITS};
    use crate::jtag_tap::Tap;

    /// Behavioural DM/DTM model at the JTAG pin level. It walks the same TAP FSM
    /// the driver drives, holds an IR and a shared 36-bit shift DR, and models
    /// the H8 debug target: memory, PC, eight 16-bit GPRs, CCR, and the P4
    /// non-destructive CCR semantics (capture CCR on a fresh halt from running
    /// code, restore it on every resume, and do NOT re-capture on a TRAPA#2
    /// re-park). Program-buffer GPR reads run an injected MOV that perturbs the
    /// live CCR N/Z/V, exactly as on hardware, so the test proves the restore.
    struct ModelBackend {
        state: TapState,
        ir: u8,
        ir_shift: u8,
        dr: u64,
        dr_capture: u64,
        // Target model.
        mem: std::collections::HashMap<u16, u16>,
        pc: u16,
        gpr: [u16; 8],
        ccr: u8,
        saved_ccr: u8,
        halted: bool,
        in_running_code: bool, // true once a resume returns to non-injected code
    }

    #[derive(Clone, Copy, PartialEq, Eq, Debug)]
    enum TapState {
        Tlr,
        Rti,
        SelDr,
        SelIr,
        CapIr,
        ShIr,
        Ex1Ir,
        UpdIr,
        CapDr,
        ShDr,
        Ex1Dr,
        UpdDr,
    }

    const TRAPA2_OP: u16 = 0x5720;

    impl ModelBackend {
        fn new() -> Self {
            ModelBackend {
                state: TapState::Rti,
                ir: ir::IDCODE,
                ir_shift: 0,
                dr: 0,
                dr_capture: 0,
                mem: std::collections::HashMap::new(),
                pc: 0,
                gpr: [0; 8],
                ccr: 0x20,
                saved_ccr: 0x20,
                halted: false,
                in_running_code: true,
            }
        }

        // Value the selected DR presents on Capture-DR.
        fn capture_dr(&self) -> u64 {
            match self.ir {
                x if x == ir::IDCODE => 0x0011_4514,
                x if x == ir::STATUS => {
                    let mut s = 0u64;
                    if self.halted {
                        s |= 1;
                    }
                    s |= (0xFF00u64) << 2; // dbg_base (arbitrary for the test)
                    s |= 1u64 << 22; // dmactive
                    s
                }
                x if x == ir::CONTROL => self.dr_capture,
                _ => 0,
            }
        }

        // A fresh halt from running user code captures CCR; a re-park from an
        // injected TRAPA#2 snippet does not.
        fn halt_from_running(&mut self) {
            if !self.halted {
                if self.in_running_code {
                    self.saved_ccr = self.ccr;
                }
                self.halted = true;
            }
        }

        // Execute one injected snippet word-stream starting at PC until TRAPA #2,
        // modelling the flag perturbation of a MOV. Used by the resume of a
        // program-buffer read.
        fn run_injected(&mut self) {
            // Restore CCR on resume (the DebugResume microword).
            self.ccr = self.saved_ccr;
            for _ in 0..8 {
                let op = *self.mem.get(&self.pc).unwrap_or(&0);
                if op == TRAPA2_OP {
                    // Re-park via TRAPA#2: does NOT re-capture saved CCR.
                    self.halted = true;
                    self.pc = self.pc.wrapping_add(2);
                    return;
                }
                if (op & 0xFF00) == 0x6B00 && (op & 0x0080) == 0x0080 {
                    // MOV.W rN,@aa:16 : store rN to the address in the next word.
                    let n = (op & 0x7) as usize;
                    let aa = *self.mem.get(&self.pc.wrapping_add(2)).unwrap_or(&0);
                    self.mem.insert(aa, self.gpr[n]);
                    // MOV updates N/Z, clears V: perturb the live CCR.
                    self.ccr = (self.ccr & 0xF1) | 0x04; // e.g. set Z-ish witness
                    self.pc = self.pc.wrapping_add(4);
                } else if (op & 0xFF00) == 0x6B00 {
                    // MOV.W @aa:16,rN : load.
                    let n = (op & 0x7) as usize;
                    let aa = *self.mem.get(&self.pc.wrapping_add(2)).unwrap_or(&0);
                    self.gpr[n] = *self.mem.get(&aa).unwrap_or(&0);
                    self.ccr = (self.ccr & 0xF1) | 0x04;
                    self.pc = self.pc.wrapping_add(4);
                } else {
                    self.pc = self.pc.wrapping_add(2);
                }
            }
        }

        fn exec_control(&mut self) {
            let cmd = (self.dr & 0x7) as u8;
            let addr = ((self.dr >> 3) & 0xFFFF) as u16;
            let data = ((self.dr >> 19) & 0xFFFF) as u16;
            let mut out_data = data;
            match cmd {
                c if c == Cmd::MemWrite as u8 => {
                    self.mem.insert(addr, data);
                }
                c if c == Cmd::MemRead as u8 => {
                    out_data = *self.mem.get(&addr).unwrap_or(&0);
                }
                c if c == Cmd::SetPc as u8 => {
                    self.pc = addr;
                    // Pointing PC at an injected snippet: the next resume runs it.
                    self.in_running_code = false;
                }
                c if c == Cmd::ReadPc as u8 => {
                    out_data = self.pc;
                }
                c if c == Cmd::ReadCcr as u8 => {
                    out_data = self.saved_ccr as u16;
                }
                c if c == Cmd::Halt as u8 => {
                    self.halt_from_running();
                }
                c if c == Cmd::Resume as u8 => {
                    if self.in_running_code {
                        // Final resume-to-program: restore CCR, leave halted.
                        self.ccr = self.saved_ccr;
                        self.halted = false;
                    } else {
                        // Program-buffer snippet run; it re-parks via TRAPA#2.
                        self.halted = false;
                        self.run_injected();
                        self.in_running_code = true;
                    }
                }
                _ => {}
            }
            // CONTROL read-back: go/in_progress=0 (done), data field updated.
            self.dr_capture = pack_control(false, Cmd::Nop, addr, out_data);
        }
    }

    impl crate::backend::JtagBackend for ModelBackend {
        fn reset(&mut self) -> Result<()> {
            self.state = TapState::Tlr;
            self.ir = ir::IDCODE;
            Ok(())
        }

        fn tick(&mut self, tms: bool, tdi: bool) -> Result<bool> {
            // Sample TDO (LSB of the shift register) BEFORE clocking, matching the
            // backend contract.
            let tdo = match self.state {
                TapState::ShIr => self.ir_shift & 1 == 1,
                TapState::ShDr => self.dr & 1 == 1,
                _ => false,
            };
            // Shift on the clock while in a Shift state (before the state moves).
            match self.state {
                TapState::ShIr => {
                    self.ir_shift = (self.ir_shift >> 1) | ((tdi as u8) << 3);
                }
                TapState::ShDr => {
                    self.dr = (self.dr >> 1) | ((tdi as u64) << (CTRL_BITS - 1));
                }
                _ => {}
            }
            // Advance the FSM.
            self.state = next_state(self.state, tms);
            match self.state {
                TapState::CapIr => self.ir_shift = self.ir,
                TapState::CapDr => {
                    self.dr = self.capture_dr();
                }
                TapState::UpdIr => self.ir = self.ir_shift & 0xF,
                TapState::UpdDr => {
                    if self.ir == ir::CONTROL {
                        // A launch (go=1) executes; a poll (go=0) just re-reads.
                        if (self.dr >> 35) & 1 == 1 {
                            self.exec_control();
                        }
                    }
                }
                _ => {}
            }
            Ok(tdo)
        }
    }

    fn next_state(s: TapState, tms: bool) -> TapState {
        use TapState::*;
        match (s, tms) {
            (Tlr, false) => Rti,
            (Tlr, true) => Tlr,
            (Rti, false) => Rti,
            (Rti, true) => SelDr,
            (SelDr, false) => CapDr,
            (SelDr, true) => SelIr,
            (SelIr, false) => CapIr,
            (SelIr, true) => Tlr, // Select-IR + TMS=1 -> Test-Logic-Reset
            (CapIr, false) => ShIr,
            (CapIr, true) => Ex1Ir,
            (ShIr, false) => ShIr,
            (ShIr, true) => Ex1Ir,
            (Ex1Ir, _) => UpdIr,
            (UpdIr, false) => Rti,
            (UpdIr, true) => SelDr,
            (CapDr, false) => ShDr,
            (CapDr, true) => Ex1Dr,
            (ShDr, false) => ShDr,
            (ShDr, true) => Ex1Dr,
            (Ex1Dr, _) => UpdDr,
            (UpdDr, false) => Rti,
            (UpdDr, true) => SelDr,
        }
    }

    fn attach() -> DmH8<ModelBackend> {
        let backend = ModelBackend::new();
        let tap = Tap::new(backend);
        let dtm = Dtm::new(tap);
        DmH8::new(dtm)
    }

    #[test]
    fn read_ccr_is_non_destructive() {
        let mut dm = attach();
        dm.reset().unwrap();
        // Seed a known CCR and distinct GPRs into the model.
        {
            let m = dm.dtm.tap_mut().backend_mut();
            m.ccr = 0x2C;
            m.saved_ccr = 0x20; // stale; a fresh halt must overwrite it
            for i in 0..8 {
                m.gpr[i] = 0x1000 + i as u16;
            }
        }
        dm.halt().unwrap();

        // ReadCcr returns the CCR captured at the fresh halt (0x2C), not stale.
        let ccr = dm.read_ccr().unwrap();
        assert_eq!(ccr, 0x2C, "ReadCcr must return the CCR captured at halt");

        // Read every GPR via the program-buffer path (perturbs the live CCR).
        for n in 0..8u8 {
            let v = dm.read_gpr(n).unwrap();
            assert_eq!(v, 0x1000 + n as u16, "GPR read must be faithful");
        }

        // ReadCcr is idempotent and still the captured value.
        assert_eq!(dm.read_ccr().unwrap(), 0x2C, "ReadCcr not stable");

        // Final resume restores the architectural CCR to the captured value.
        dm.resume().unwrap();
        let m = dm.dtm.tap_mut().backend_mut();
        assert_eq!(m.ccr, 0x2C, "architectural CCR must be pristine after resume");
        for i in 0..8 {
            assert_eq!(m.gpr[i], 0x1000 + i as u16, "GPRs must be pristine");
        }
    }
}
