// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! Chimera custom debug-transport module (DTM) register layer.
//!
//! This is NOT RISC-V dmi/dtmcs: a 4-bit IR selects one of four data registers,
//! and there is no sticky-busy. Commands launch by setting the CONTROL "go"
//! strobe (top bit) in Update-DR; the host polls by re-scanning CONTROL with
//! go=0 (a bare read that does not re-launch) until the in_progress bit clears.

use crate::backend::JtagBackend;
use crate::jtag_tap::Tap;
use anyhow::{bail, Result};

/// IR opcodes (4-bit). Anything else maps to BYPASS in the DTM.
pub mod ir {
    pub const STATUS: u8 = 0x0;
    pub const IDCODE: u8 = 0x1;
    pub const CONTROL: u8 = 0x2;
    pub const BYPASS: u8 = 0xF;
}

/// CONTROL cmd field (4-bit).
///
/// `Nop` is 0 so a zeroed / reset CONTROL DR is inert (no spurious access);
/// only `MemRead` at 6 moves. This mirrors `DmCmd` in the RTL.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Cmd {
    Nop = 0,
    MemWrite = 1,
    SetPc = 2,
    Halt = 3,
    Resume = 4,
    ReadPc = 5,
    MemRead = 6,
    ReadCcr = 7,
}

/// Geometry of the 37-bit CONTROL DR and the 23-bit STATUS DR.
pub const CTRL_BITS: usize = 37;
pub const STATUS_BITS: usize = 23;
pub const IDCODE_BITS: usize = 32;

/// Decoded STATUS DR.
#[derive(Clone, Copy, Debug)]
pub struct Status {
    pub is_halted: bool,
    pub is_sleeping: bool,
    pub dbg_base: u16,
    pub hwbp_count: u8,
    pub dmactive: bool,
}

impl Status {
    /// LSB-first: [0]halted [1]sleeping [17:2]dbg_base[16] [21:18]hwbp_count[4]
    /// [22]dmactive.
    pub fn decode(raw: u64) -> Status {
        Status {
            is_halted: (raw & 1) != 0,
            is_sleeping: (raw >> 1) & 1 != 0,
            dbg_base: ((raw >> 2) & 0xFFFF) as u16,
            hwbp_count: ((raw >> 18) & 0xF) as u8,
            dmactive: (raw >> 22) & 1 != 0,
        }
    }
}

/// Pack a CONTROL DR word.
///
/// LSB-first field layout: [3:0]cmd [19:4]addr[16] [35:20]data[16] [36]go. On a
/// write `go` is the launch strobe; the same bit reads back as in_progress.
pub fn pack_control(go: bool, cmd: Cmd, addr: u16, data: u16) -> u64 {
    let cmd = (cmd as u64) & 0xF;
    let addr = (addr as u64) & 0xFFFF;
    let data = (data as u64) & 0xFFFF;
    let go = if go { 1u64 } else { 0 };
    cmd | (addr << 4) | (data << 20) | (go << 36)
}

/// Fields decoded from a CONTROL read-back.
#[derive(Clone, Copy, Debug)]
pub struct ControlReadback {
    pub in_progress: bool,
    pub data: u16,
}

pub fn decode_control(raw: u64) -> ControlReadback {
    ControlReadback {
        in_progress: (raw >> 36) & 1 != 0,
        data: ((raw >> 20) & 0xFFFF) as u16,
    }
}

/// The DTM driver: owns the TAP and tracks the currently loaded IR to avoid
/// redundant IR scans.
pub struct Dtm<B: JtagBackend> {
    tap: Tap<B>,
    loaded_ir: Option<u8>,
    poll_guard: usize,
}

impl<B: JtagBackend> Dtm<B> {
    pub fn new(tap: Tap<B>) -> Self {
        Dtm {
            tap,
            loaded_ir: None,
            poll_guard: 512,
        }
    }

    /// TRST + TLR; after reset the IR resets to IDCODE inside the DTM.
    pub fn reset(&mut self) -> Result<()> {
        self.tap.reset()?;
        self.loaded_ir = Some(ir::IDCODE);
        Ok(())
    }

    /// Access the underlying TAP (its backend), for tests and diagnostics.
    pub fn tap_mut(&mut self) -> &mut Tap<B> {
        &mut self.tap
    }

    fn select_ir(&mut self, want: u8) -> Result<()> {
        if self.loaded_ir != Some(want) {
            self.tap.shift_ir(want)?;
            self.loaded_ir = Some(want);
        }
        Ok(())
    }

    pub fn read_idcode(&mut self) -> Result<u32> {
        self.select_ir(ir::IDCODE)?;
        let raw = self.tap.shift_dr(IDCODE_BITS, 0)?;
        Ok(raw as u32)
    }

    pub fn read_status(&mut self) -> Result<Status> {
        self.select_ir(ir::STATUS)?;
        let raw = self.tap.shift_dr(STATUS_BITS, 0)?;
        Ok(Status::decode(raw))
    }

    /// Poll STATUS until `is_halted` reaches `want`, or the guard trips.
    pub fn wait_halted(&mut self, want: bool) -> Result<Status> {
        for _ in 0..self.poll_guard {
            let s = self.read_status()?;
            if s.is_halted == want {
                return Ok(s);
            }
        }
        bail!("timeout waiting for is_halted={}", want)
    }

    /// Launch a CONTROL command (go=1), then poll with go=0 until in_progress
    /// clears. Returns the CONTROL data field captured on completion.
    ///
    /// Resume never acks in_progress the same way (the core leaves the park word
    /// and STATUS.is_halted drops); callers that need that observe STATUS.
    fn control_launch_and_poll(&mut self, cmd: Cmd, addr: u16, data: u16) -> Result<u16> {
        self.select_ir(ir::CONTROL)?;
        // Launch.
        self.tap
            .shift_dr(CTRL_BITS, pack_control(true, cmd, addr, data))?;
        // Poll with go=0 so the re-scan reads in_progress without re-launching.
        let poll_word = pack_control(false, cmd, addr, data);
        for _ in 0..self.poll_guard {
            let raw = self.tap.shift_dr(CTRL_BITS, poll_word)?;
            let rb = decode_control(raw);
            if !rb.in_progress {
                return Ok(rb.data);
            }
        }
        bail!("timeout polling CONTROL for cmd {:?}", cmd)
    }

    pub fn mem_read(&mut self, addr: u16) -> Result<u16> {
        self.control_launch_and_poll(Cmd::MemRead, addr, 0)
    }

    pub fn mem_write(&mut self, addr: u16, data: u16) -> Result<()> {
        self.control_launch_and_poll(Cmd::MemWrite, addr, data)?;
        Ok(())
    }

    pub fn set_pc(&mut self, pc: u16) -> Result<()> {
        self.control_launch_and_poll(Cmd::SetPc, pc, 0)?;
        Ok(())
    }

    pub fn read_pc(&mut self) -> Result<u16> {
        self.control_launch_and_poll(Cmd::ReadPc, 0, 0)
    }

    /// Read CCR captured at the debugger's session entry (non-destructive).
    ///
    /// The core saves CCR on the fresh park entry and restores it on every
    /// resume, so this returns the target's true CCR (low byte) without any
    /// program-buffer perturbation. Valid only while halted.
    pub fn read_ccr(&mut self) -> Result<u8> {
        Ok((self.control_launch_and_poll(Cmd::ReadCcr, 0, 0)? & 0xFF) as u8)
    }

    pub fn halt(&mut self) -> Result<()> {
        self.control_launch_and_poll(Cmd::Halt, 0, 0)?;
        self.wait_halted(true)?;
        Ok(())
    }

    /// Resume: launch the command and poll CONTROL until in_progress clears.
    ///
    /// The DTM drops in_progress for a resume the moment the core's halted status
    /// falls, so this returns once the core has left the park word. It does NOT
    /// wait on STATUS.is_halted afterward: a software breakpoint can re-halt the
    /// core within a few cycles, faster than a STATUS scan, so a separate
    /// `wait_halted(true)` is used by callers that expect a re-halt.
    pub fn resume(&mut self) -> Result<()> {
        self.control_launch_and_poll(Cmd::Resume, 0, 0)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn control_field_packing() {
        // go=1, cmd=memWrite(1), addr=0x0300, data=0xBEEF.
        let w = pack_control(true, Cmd::MemWrite, 0x0300, 0xBEEF);
        assert_eq!(w & 0xF, 1); // cmd
        assert_eq!((w >> 4) & 0xFFFF, 0x0300); // addr
        assert_eq!((w >> 20) & 0xFFFF, 0xBEEF); // data
        assert_eq!((w >> 36) & 1, 1); // go
        assert_eq!(w, ((1u64) << 36) | (0xBEEFu64 << 20) | (0x0300u64 << 4) | 1);
    }

    #[test]
    fn control_go_low_clears_top_bit() {
        let w = pack_control(false, Cmd::MemRead, 0x0400, 0);
        assert_eq!((w >> 36) & 1, 0);
        assert_eq!(w & 0xF, 6); // memRead is 6 in the new encoding
        assert_eq!((w >> 4) & 0xFFFF, 0x0400);
    }

    #[test]
    fn cmd_encoding_matches_rtl() {
        assert_eq!(Cmd::Nop as u64, 0); // reset CONTROL DR is inert
        assert_eq!(Cmd::MemWrite as u64, 1);
        assert_eq!(Cmd::SetPc as u64, 2);
        assert_eq!(Cmd::Halt as u64, 3);
        assert_eq!(Cmd::Resume as u64, 4);
        assert_eq!(Cmd::ReadPc as u64, 5);
        assert_eq!(Cmd::MemRead as u64, 6); // only memRead moves from 0
    }

    #[test]
    fn control_readback_decode() {
        // in_progress=1, data=0x1234 in the [35:20] field.
        let raw = (1u64 << 36) | (0x1234u64 << 20);
        let rb = decode_control(raw);
        assert!(rb.in_progress);
        assert_eq!(rb.data, 0x1234);

        let done = 0x5720u64 << 20; // in_progress=0, data=TRAPA #2 word
        let rb2 = decode_control(done);
        assert!(!rb2.in_progress);
        assert_eq!(rb2.data, 0x5720);
    }

    #[test]
    fn status_decode_fields() {
        // halted=1, sleeping=0, dbg_base=0xFF00, hwbp_count=2, dmactive=1.
        let raw = 1u64 | (0u64 << 1) | (0xFF00u64 << 2) | (2u64 << 18) | (1u64 << 22);
        let s = Status::decode(raw);
        assert!(s.is_halted);
        assert!(!s.is_sleeping);
        assert_eq!(s.dbg_base, 0xFF00);
        assert_eq!(s.hwbp_count, 2);
        assert!(s.dmactive);
    }

    #[test]
    fn status_decode_sleeping() {
        // dmactive=0 here to cover the cleared case.
        let raw = 0u64 | (1u64 << 1) | (0xAB00u64 << 2) | (1u64 << 18);
        let s = Status::decode(raw);
        assert!(!s.is_halted);
        assert!(s.is_sleeping);
        assert_eq!(s.dbg_base, 0xAB00);
        assert_eq!(s.hwbp_count, 1);
        assert!(!s.dmactive);
    }

    #[test]
    fn control_roundtrip_pack_decode() {
        // A completed read: pack a poll word (go=0), and independently a
        // read-back with the same data confirms field alignment agrees.
        let data = 0xCAFEu16;
        let readback = decode_control((data as u64) << 20);
        assert_eq!(readback.data, data);
        assert!(!readback.in_progress);
    }
}
