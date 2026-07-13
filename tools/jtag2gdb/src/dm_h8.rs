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

    /// Read the 8-bit CCR via program buffer.
    ///
    /// The DM has no direct CCR read port, so a snippet copies CCR into the low
    /// byte of a scratch register and stores it. `STC CCR,Rl` is executed as the
    /// FIRST instruction so the captured value is the live CCR, before any flag
    /// side effect of the snippet itself. The whole original scratch register is
    /// preserved on the stack, and CCR is restored to the captured value with
    /// `LDC`, so the operation is lossless for the GPRs, PC, work area and CCR.
    ///
    /// Snippet (at code_area), r6 as scratch:
    ///   `STC CCR,r6l`        (0x0208 | (6<<0)=0x020E)  ; CCR -> r6l  [captures]
    ///   `MOV.W r6,@data`     (0x6B80|6=0x6B86, aa)     ; {r6h,ccr} -> data
    ///   `TRAPA #2`           (0x5720)
    /// r6 is saved/restored via GPR program buffer around the snippet; CCR is
    /// re-loaded with `LDC #ccr,ccr` (0x07,ccr) appended so the flags return to
    /// their captured state.
    pub fn read_ccr(&mut self) -> Result<u8> {
        // Save the scratch GPR (r6) first via the GPR path (self-restoring). r6
        // is chosen to avoid r0/r7(sp). This read perturbs CCR, but CCR is
        // captured by the STC that runs as the snippet's first instruction and
        // is restored by the trailing LDC, so the net effect on CCR is zero.
        let saved_r6 = self.read_gpr(6)?;

        let saved_pc = self.dtm.read_pc()?;
        let c0 = self.dtm.mem_read(self.code_area)?;
        let c1 = self.dtm.mem_read(self.code_area + 2)?;
        let c2 = self.dtm.mem_read(self.code_area + 4)?;
        let c3 = self.dtm.mem_read(self.code_area + 6)?;
        let sdata = self.dtm.mem_read(self.data_area)?;

        // STC CCR,r6l | MOV.W r6,@data_area | TRAPA #2
        self.dtm.mem_write(self.code_area, 0x0208 | 6)?; // STC CCR,r6l
        self.dtm.mem_write(self.code_area + 2, 0x6B80 | 6)?; // MOV.W r6,@aa:16
        self.dtm.mem_write(self.code_area + 4, self.data_area)?;
        self.dtm.mem_write(self.code_area + 6, TRAPA2)?;
        self.dtm.set_pc(self.code_area)?;
        self.dtm.resume()?;
        self.dtm.wait_halted(true)?;

        // MOV.W r6 stored {r6h, ccr}; CCR is the low byte of the word.
        let word = self.dtm.mem_read(self.data_area)?;
        let ccr = (word & 0xFF) as u8;

        // Restore code/data/PC and r6, then restore CCR to the captured value.
        self.dtm.mem_write(self.code_area, c0)?;
        self.dtm.mem_write(self.code_area + 2, c1)?;
        self.dtm.mem_write(self.code_area + 4, c2)?;
        self.dtm.mem_write(self.code_area + 6, c3)?;
        self.dtm.mem_write(self.data_area, sdata)?;
        self.dtm.set_pc(saved_pc)?;
        self.write_gpr(6, saved_r6)?;
        self.restore_ccr(ccr)?;

        Ok(ccr)
    }

    /// Restore CCR to `ccr` via `LDC #ccr,ccr` (0x07 imm) + `TRAPA #2`, saving
    /// and restoring the work area and PC (no GPR is touched by LDC).
    fn restore_ccr(&mut self, ccr: u8) -> Result<()> {
        let saved_pc = self.dtm.read_pc()?;
        let c0 = self.dtm.mem_read(self.code_area)?;
        let c1 = self.dtm.mem_read(self.code_area + 2)?;
        self.dtm.mem_write(self.code_area, 0x0700 | ccr as u16)?; // LDC #ccr,ccr
        self.dtm.mem_write(self.code_area + 2, TRAPA2)?;
        self.dtm.set_pc(self.code_area)?;
        self.dtm.resume()?;
        self.dtm.wait_halted(true)?;
        self.dtm.mem_write(self.code_area, c0)?;
        self.dtm.mem_write(self.code_area + 2, c1)?;
        self.dtm.set_pc(saved_pc)?;
        Ok(())
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
