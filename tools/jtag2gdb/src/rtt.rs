// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! Real-Time Transfer (RTT) terminal over the DM's memory access.
//!
//! RTT gives a J-Link-RTT-style bidirectional byte channel using ONLY host-side
//! memory access: the target program lays out a control block plus ring buffers
//! in RAM, and the host (this module) polls the up buffer and fills the down
//! buffer with plain `memRead`/`memWrite`. Zero extra RTL: the DM's auto-halt
//! memory access (feature #22) lets these accesses run while the core executes,
//! so the host issues one `memRead`/`memWrite` and the DM transparently halts,
//! services it, and resumes. This module never issues its own halt/resume.
//!
//! Caveat vs a real J-Link: each access briefly stalls the core (auto-halt is
//! not a true background bus steal), so it is throughput-limited and best suited
//! to RTT's periodic polling rather than bulk transfer.
//!
//! ## Control-block layout (Chimera 16-bit variant)
//!
//! The layout mirrors SEGGER RTT field-for-field but narrows the 32-bit target
//! pointers and counters to 16 bits, because the base H8/300 address space is
//! 64 KiB. A SEGGER RTT target library ported to a 16-bit pointer width lays out
//! exactly these bytes; a stock 32-bit SEGGER block is NOT wire-compatible and
//! would need a widened parser (deliberately out of scope for the 64 KiB core).
//!
//! All multi-byte fields are big-endian (H8/300 memory order), matching the
//! `DmH8::read_mem`/`write_mem` byte convention.
//!
//! ```text
//! Control block header:
//!   +0x00  char   acId[16]         magic, "SEGGER RTT\0\0\0\0\0\0"
//!   +0x10  u16    MaxNumUpBuffers
//!   +0x12  u16    MaxNumDownBuffers
//!   +0x14  up-buffer descriptors   (MaxNumUpBuffers   x 12 bytes)
//!   ...    down-buffer descriptors (MaxNumDownBuffers x 12 bytes)
//!
//! Ring-buffer descriptor (12 bytes):
//!   +0x00  u16    sName    pointer to a NUL-terminated channel name
//!   +0x02  u16    pBuffer  pointer to the ring storage
//!   +0x04  u16    SizeOfBuffer
//!   +0x06  u16    WrOff    write offset (producer index)
//!   +0x08  u16    RdOff    read offset  (consumer index)
//!   +0x0A  u16    Flags    channel mode (0 = no block/skip)
//! ```
//!
//! Ring semantics (same as SEGGER): the buffer holds `SizeOfBuffer` bytes but at
//! most `SizeOfBuffer - 1` are ever live, so `WrOff == RdOff` means empty and the
//! producer never writes the byte that would make them collide. For an UP buffer
//! the target is producer (advances WrOff) and the host is consumer (advances
//! RdOff); for a DOWN buffer the roles reverse.

use crate::backend::JtagBackend;
use crate::dm_h8::DmH8;
use anyhow::{bail, Result};

/// The 16-byte magic that marks a control block. Written by the target LAST so a
/// scanning host never latches a half-initialised block.
pub const RTT_MAGIC: &[u8; 16] = b"SEGGER RTT\0\0\0\0\0\0";

const HDR_MAGIC_LEN: usize = 16;
const HDR_LEN: usize = HDR_MAGIC_LEN + 4; // magic + MaxNumUp(2) + MaxNumDown(2)
const DESC_LEN: usize = 12;

/// A parsed ring-buffer descriptor plus the control-block address of its live
/// `WrOff`/`RdOff` words, so the host can update them in place.
#[derive(Clone, Copy, Debug)]
pub struct RingBuffer {
    pub name_ptr: u16,
    pub buffer_ptr: u16,
    pub size: u16,
    pub wr_off: u16,
    pub rd_off: u16,
    pub flags: u16,
    /// Address of this descriptor's WrOff word in the control block.
    wr_off_addr: u16,
    /// Address of this descriptor's RdOff word in the control block.
    rd_off_addr: u16,
}

/// A located and parsed RTT control block.
#[derive(Clone, Debug)]
pub struct ControlBlock {
    pub addr: u16,
    pub up: Vec<RingBuffer>,
    pub down: Vec<RingBuffer>,
}

/// Scan `[start, end)` for the RTT magic and parse the block it heads.
///
/// The scan steps by 2 (H8/300 code/data is 16-bit aligned; a target that word-
/// aligns its control block, which the linker does, is found). Returns the first
/// block whose magic matches and whose descriptor table fits in the range.
pub fn find_control_block<B: JtagBackend>(
    dm: &mut DmH8<B>,
    start: u16,
    end: u16,
) -> Result<ControlBlock> {
    let mut addr = start & !1;
    while addr as u32 + HDR_MAGIC_LEN as u32 <= end as u32 {
        let magic = dm.read_mem(addr, HDR_MAGIC_LEN)?;
        if magic == RTT_MAGIC {
            return parse_control_block(dm, addr);
        }
        // Guard against wrap at the top of the address space.
        match addr.checked_add(2) {
            Some(next) => addr = next,
            None => break,
        }
    }
    bail!("RTT control block not found in {start:#06x}..{end:#06x}")
}

/// Parse the header and descriptor tables of a block already known to sit at
/// `addr` (magic verified by the caller or re-verified here).
pub fn parse_control_block<B: JtagBackend>(
    dm: &mut DmH8<B>,
    addr: u16,
) -> Result<ControlBlock> {
    let hdr = dm.read_mem(addr, HDR_LEN)?;
    if hdr[..HDR_MAGIC_LEN] != RTT_MAGIC[..] {
        bail!("no RTT magic at {addr:#06x}");
    }
    let max_up = be16(&hdr[16..18]);
    let max_down = be16(&hdr[18..20]);

    let up_base = addr.wrapping_add(HDR_LEN as u16);
    let up = read_descriptors(dm, up_base, max_up)?;
    let down_base = up_base.wrapping_add(max_up.wrapping_mul(DESC_LEN as u16));
    let down = read_descriptors(dm, down_base, max_down)?;

    Ok(ControlBlock { addr, up, down })
}

fn read_descriptors<B: JtagBackend>(
    dm: &mut DmH8<B>,
    base: u16,
    count: u16,
) -> Result<Vec<RingBuffer>> {
    let mut out = Vec::with_capacity(count as usize);
    for i in 0..count {
        let d = base.wrapping_add(i.wrapping_mul(DESC_LEN as u16));
        let raw = dm.read_mem(d, DESC_LEN)?;
        out.push(RingBuffer {
            name_ptr: be16(&raw[0..2]),
            buffer_ptr: be16(&raw[2..4]),
            size: be16(&raw[4..6]),
            wr_off: be16(&raw[6..8]),
            rd_off: be16(&raw[8..10]),
            flags: be16(&raw[10..12]),
            wr_off_addr: d.wrapping_add(6),
            rd_off_addr: d.wrapping_add(8),
        });
    }
    Ok(out)
}

/// Drain all currently queued bytes from one UP buffer (target -> host).
///
/// Re-reads WrOff live (the target keeps advancing it), copies `RdOff..WrOff`
/// with wrap, then commits the new RdOff with a single `memWrite`. Returns the
/// drained bytes (possibly empty).
pub fn read_up<B: JtagBackend>(dm: &mut DmH8<B>, ring: &RingBuffer) -> Result<Vec<u8>> {
    if ring.size == 0 {
        return Ok(Vec::new());
    }
    let wr = dm.read_mem_word(ring.wr_off_addr)?;
    let mut rd = dm.read_mem_word(ring.rd_off_addr)?;
    if wr >= ring.size || rd >= ring.size {
        bail!("RTT up-buffer offsets out of range (wr={wr}, rd={rd}, size={})", ring.size);
    }
    let mut out = Vec::new();
    while rd != wr {
        // Copy the contiguous span up to the buffer end or up to wr.
        let span_end = if wr > rd { wr } else { ring.size };
        let chunk = dm.read_mem(ring.buffer_ptr.wrapping_add(rd), (span_end - rd) as usize)?;
        out.extend_from_slice(&chunk);
        rd = span_end % ring.size;
    }
    dm.write_mem_word(ring.rd_off_addr, rd)?;
    Ok(out)
}

/// Free byte count in a DOWN buffer given its live WrOff/RdOff.
fn down_free(size: u16, wr: u16, rd: u16) -> u16 {
    // One slot is always kept empty to distinguish full from empty.
    if rd > wr {
        rd - wr - 1
    } else {
        size - wr + rd - 1
    }
}

/// Push as many bytes as fit into one DOWN buffer (host -> target).
///
/// Re-reads RdOff live (the target keeps consuming), writes into `WrOff..` with
/// wrap while space remains, then commits the new WrOff with a single
/// `memWrite`. Returns the number of bytes actually written (short writes when
/// the buffer is nearly full; the caller retries the remainder later).
pub fn write_down<B: JtagBackend>(
    dm: &mut DmH8<B>,
    ring: &RingBuffer,
    data: &[u8],
) -> Result<usize> {
    if ring.size == 0 || data.is_empty() {
        return Ok(0);
    }
    let rd = dm.read_mem_word(ring.rd_off_addr)?;
    let mut wr = dm.read_mem_word(ring.wr_off_addr)?;
    if wr >= ring.size || rd >= ring.size {
        bail!("RTT down-buffer offsets out of range (wr={wr}, rd={rd}, size={})", ring.size);
    }
    let free = down_free(ring.size, wr, rd) as usize;
    let n = data.len().min(free);
    let mut idx = 0;
    while idx < n {
        let span_end = if wr < rd { rd - 1 } else { ring.size };
        let span = ((span_end - wr) as usize).min(n - idx);
        if span == 0 {
            break;
        }
        dm.write_mem(ring.buffer_ptr.wrapping_add(wr), &data[idx..idx + span])?;
        idx += span;
        wr = (wr + span as u16) % ring.size;
    }
    dm.write_mem_word(ring.wr_off_addr, wr)?;
    Ok(idx)
}

fn be16(b: &[u8]) -> u16 {
    ((b[0] as u16) << 8) | b[1] as u16
}

/// Run a blocking bidirectional terminal on the given up/down channel indices.
///
/// Prints up-channel bytes to stdout and forwards stdin lines to the down
/// channel, polling on an interval. Reloads the descriptors each poll so live
/// offsets are always fresh. Returns on stdin EOF.
#[cfg(feature = "terminal")]
pub fn run_terminal<B: JtagBackend>(
    dm: &mut DmH8<B>,
    cb: &ControlBlock,
    up_ch: usize,
    down_ch: usize,
    poll: std::time::Duration,
) -> Result<()> {
    use std::io::{Read, Write};

    if up_ch >= cb.up.len() {
        bail!("up channel {up_ch} out of range (have {})", cb.up.len());
    }
    let has_down = down_ch < cb.down.len();
    let up_desc = cb.up[up_ch];
    let stdin = std::io::stdin();
    let mut pending: Vec<u8> = Vec::new();

    loop {
        let bytes = read_up(dm, &up_desc)?;
        if !bytes.is_empty() {
            let out = std::io::stdout();
            let mut lock = out.lock();
            lock.write_all(&bytes)?;
            lock.flush()?;
        }

        // Non-blocking-ish stdin: a full RTT terminal wants raw mode; here we
        // read available input opportunistically. Left simple on purpose.
        let mut buf = [0u8; 256];
        if let Ok(n) = stdin.lock().read(&mut buf) {
            if n == 0 {
                return Ok(());
            }
            pending.extend_from_slice(&buf[..n]);
        }
        if has_down && !pending.is_empty() {
            let wrote = write_down(dm, &cb.down[down_ch], &pending)?;
            pending.drain(..wrote);
        }
        std::thread::sleep(poll);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::dtm::{ir, pack_control, Cmd, CTRL_BITS};
    use crate::jtag_tap::Tap;

    /// A minimal pin-level DM model exposing a flat RAM through the CONTROL DR
    /// memRead/memWrite commands. It is halt-agnostic (the auto-halt FSM that
    /// makes running-target access work lives in RTL #22 and is transparent to
    /// the host), so it services every memRead/memWrite unconditionally.
    struct RamModel {
        state: TapState,
        ir: u8,
        ir_shift: u8,
        dr: u64,
        dr_capture: u64,
        mem: std::collections::HashMap<u16, u16>,
    }

    #[derive(Clone, Copy, PartialEq, Eq)]
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

    impl RamModel {
        fn new() -> Self {
            RamModel {
                state: TapState::Rti,
                ir: ir::IDCODE,
                ir_shift: 0,
                dr: 0,
                dr_capture: 0,
                mem: std::collections::HashMap::new(),
            }
        }

        fn capture_dr(&self) -> u64 {
            match self.ir {
                x if x == ir::IDCODE => 0x0011_4514,
                x if x == ir::STATUS => 1 | (1u64 << 22), // halted + dmactive
                x if x == ir::CONTROL => self.dr_capture,
                _ => 0,
            }
        }

        fn exec_control(&mut self) {
            let cmd = (self.dr & 0x7) as u8;
            let addr = ((self.dr >> 3) & 0xFFFF) as u16;
            let data = ((self.dr >> 19) & 0xFFFF) as u16;
            let mut out = data;
            match cmd {
                c if c == Cmd::MemWrite as u8 => {
                    self.mem.insert(addr, data);
                }
                c if c == Cmd::MemRead as u8 => {
                    out = *self.mem.get(&addr).unwrap_or(&0);
                }
                _ => {}
            }
            self.dr_capture = pack_control(false, Cmd::Nop, addr, out);
        }

        /// Seed a 16-bit word big-endian at a byte address (aligned).
        fn poke_word(&mut self, addr: u16, w: u16) {
            self.mem.insert(addr, w);
        }

        /// Seed a byte at any address by read-modify-write of its word.
        fn poke_byte(&mut self, addr: u16, b: u8) {
            let base = addr & !1;
            let cur = *self.mem.get(&base).unwrap_or(&0);
            let w = if addr & 1 == 0 {
                (cur & 0x00FF) | ((b as u16) << 8)
            } else {
                (cur & 0xFF00) | b as u16
            };
            self.mem.insert(base, w);
        }

        fn peek_byte(&self, addr: u16) -> u8 {
            let base = addr & !1;
            let cur = *self.mem.get(&base).unwrap_or(&0);
            if addr & 1 == 0 {
                (cur >> 8) as u8
            } else {
                (cur & 0xFF) as u8
            }
        }
    }

    impl crate::backend::JtagBackend for RamModel {
        fn reset(&mut self) -> Result<()> {
            self.state = TapState::Tlr;
            self.ir = ir::IDCODE;
            Ok(())
        }

        fn tick(&mut self, tms: bool, tdi: bool) -> Result<bool> {
            let tdo = match self.state {
                TapState::ShIr => self.ir_shift & 1 == 1,
                TapState::ShDr => self.dr & 1 == 1,
                _ => false,
            };
            match self.state {
                TapState::ShIr => {
                    self.ir_shift = (self.ir_shift >> 1) | ((tdi as u8) << 3);
                }
                TapState::ShDr => {
                    self.dr = (self.dr >> 1) | ((tdi as u64) << (CTRL_BITS - 1));
                }
                _ => {}
            }
            self.state = next_state(self.state, tms);
            match self.state {
                TapState::CapIr => self.ir_shift = self.ir,
                TapState::CapDr => self.dr = self.capture_dr(),
                TapState::UpdIr => self.ir = self.ir_shift & 0xF,
                TapState::UpdDr => {
                    if self.ir == ir::CONTROL && (self.dr >> 35) & 1 == 1 {
                        self.exec_control();
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
            (SelIr, true) => Tlr,
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

    /// Build a control block with one up and one down channel at `cb_addr`, up
    /// storage at `up_buf`, down storage at `down_buf`, each `size` bytes.
    fn seed_block(m: &mut RamModel, cb_addr: u16, up_buf: u16, down_buf: u16, size: u16) {
        // Header magic.
        for (i, &b) in RTT_MAGIC.iter().enumerate() {
            m.poke_byte(cb_addr + i as u16, b);
        }
        m.poke_word(cb_addr + 0x10, 1); // MaxNumUpBuffers
        m.poke_word(cb_addr + 0x12, 1); // MaxNumDownBuffers
        let up_desc = cb_addr + HDR_LEN as u16;
        let down_desc = up_desc + DESC_LEN as u16;
        // Up descriptor: name=0, buffer, size, WrOff=0, RdOff=0, flags=0.
        m.poke_word(up_desc, 0);
        m.poke_word(up_desc + 2, up_buf);
        m.poke_word(up_desc + 4, size);
        m.poke_word(up_desc + 6, 0);
        m.poke_word(up_desc + 8, 0);
        m.poke_word(up_desc + 10, 0);
        // Down descriptor.
        m.poke_word(down_desc, 0);
        m.poke_word(down_desc + 2, down_buf);
        m.poke_word(down_desc + 4, size);
        m.poke_word(down_desc + 6, 0);
        m.poke_word(down_desc + 8, 0);
        m.poke_word(down_desc + 10, 0);
    }

    fn attach(m: RamModel) -> DmH8<RamModel> {
        let tap = Tap::new(m);
        let dtm = crate::dtm::Dtm::new(tap);
        DmH8::new(dtm)
    }

    #[test]
    fn finds_and_parses_block() {
        let mut m = RamModel::new();
        // Put junk before the block to prove the scan skips it.
        m.poke_word(0x1000, 0xDEAD);
        seed_block(&mut m, 0x1010, 0x1080, 0x10C0, 32);
        let mut dm = attach(m);
        let cb = find_control_block(&mut dm, 0x1000, 0x1200).unwrap();
        assert_eq!(cb.addr, 0x1010);
        assert_eq!(cb.up.len(), 1);
        assert_eq!(cb.down.len(), 1);
        assert_eq!(cb.up[0].buffer_ptr, 0x1080);
        assert_eq!(cb.up[0].size, 32);
        assert_eq!(cb.down[0].buffer_ptr, 0x10C0);
    }

    #[test]
    fn not_found_errors() {
        let m = RamModel::new();
        let mut dm = attach(m);
        assert!(find_control_block(&mut dm, 0x1000, 0x1100).is_err());
    }

    #[test]
    fn read_up_simple() {
        let mut m = RamModel::new();
        seed_block(&mut m, 0x1010, 0x1080, 0x10C0, 32);
        // Target produced "Hi!" into the up buffer and set WrOff=3.
        for (i, &b) in b"Hi!".iter().enumerate() {
            m.poke_byte(0x1080 + i as u16, b);
        }
        let up_desc = 0x1010 + HDR_LEN as u16;
        m.poke_word(up_desc + 6, 3); // WrOff = 3
        let mut dm = attach(m);
        let cb = find_control_block(&mut dm, 0x1000, 0x1200).unwrap();
        let got = read_up(&mut dm, &cb.up[0]).unwrap();
        assert_eq!(got, b"Hi!");
        // RdOff committed to 3, so a second drain yields nothing.
        let again = read_up(&mut dm, &cb.up[0]).unwrap();
        assert!(again.is_empty());
        // RdOff word in the control block advanced.
        let rd = dm.read_mem_word(up_desc + 8).unwrap();
        assert_eq!(rd, 3);
    }

    #[test]
    fn read_up_wraps() {
        let size = 8u16;
        let mut m = RamModel::new();
        seed_block(&mut m, 0x1010, 0x1080, 0x10C0, size);
        // Ring content "ABCDE" spanning the wrap: RdOff=6, WrOff=3.
        // Bytes at offsets 6,7 = 'A','B'; offsets 0,1,2 = 'C','D','E'.
        m.poke_byte(0x1086, b'A');
        m.poke_byte(0x1087, b'B');
        m.poke_byte(0x1080, b'C');
        m.poke_byte(0x1081, b'D');
        m.poke_byte(0x1082, b'E');
        let up_desc = 0x1010 + HDR_LEN as u16;
        m.poke_word(up_desc + 6, 3); // WrOff
        m.poke_word(up_desc + 8, 6); // RdOff
        let mut dm = attach(m);
        let cb = find_control_block(&mut dm, 0x1000, 0x1200).unwrap();
        let got = read_up(&mut dm, &cb.up[0]).unwrap();
        assert_eq!(got, b"ABCDE");
        assert_eq!(dm.read_mem_word(up_desc + 8).unwrap(), 3); // RdOff -> WrOff
    }

    #[test]
    fn write_down_simple() {
        let mut m = RamModel::new();
        seed_block(&mut m, 0x1010, 0x1080, 0x10C0, 32);
        let mut dm = attach(m);
        let cb = find_control_block(&mut dm, 0x1000, 0x1200).unwrap();
        let n = write_down(&mut dm, &cb.down[0], b"ping").unwrap();
        assert_eq!(n, 4);
        let down_desc = 0x1010 + HDR_LEN as u16 + DESC_LEN as u16;
        assert_eq!(dm.read_mem_word(down_desc + 6).unwrap(), 4); // WrOff -> 4
        // Bytes landed in the down storage.
        let m2 = dm.dtm.tap_mut().backend_mut();
        assert_eq!(m2.peek_byte(0x10C0), b'p');
        assert_eq!(m2.peek_byte(0x10C1), b'i');
        assert_eq!(m2.peek_byte(0x10C2), b'n');
        assert_eq!(m2.peek_byte(0x10C3), b'g');
    }

    #[test]
    fn write_down_wraps() {
        let size = 8u16;
        let mut m = RamModel::new();
        seed_block(&mut m, 0x1010, 0x1080, 0x10C0, size);
        // Pre-position WrOff near the end and RdOff giving room: WrOff=6, RdOff=3.
        // Free = size - wr + rd - 1 = 8 - 6 + 3 - 1 = 4 bytes.
        let down_desc = 0x1010 + HDR_LEN as u16 + DESC_LEN as u16;
        m.poke_word(down_desc + 6, 6); // WrOff
        m.poke_word(down_desc + 8, 3); // RdOff
        let mut dm = attach(m);
        let cb = find_control_block(&mut dm, 0x1000, 0x1200).unwrap();
        // Try 6 bytes; only 4 fit, wrapping across the end.
        let n = write_down(&mut dm, &cb.down[0], b"WXYZ12").unwrap();
        assert_eq!(n, 4);
        // WrOff = (6 + 4) % 8 = 2.
        assert_eq!(dm.read_mem_word(down_desc + 6).unwrap(), 2);
        let m2 = dm.dtm.tap_mut().backend_mut();
        assert_eq!(m2.peek_byte(0x10C6), b'W');
        assert_eq!(m2.peek_byte(0x10C7), b'X');
        assert_eq!(m2.peek_byte(0x10C0), b'Y');
        assert_eq!(m2.peek_byte(0x10C1), b'Z');
    }

    #[test]
    fn write_down_full_writes_zero() {
        let size = 4u16;
        let mut m = RamModel::new();
        seed_block(&mut m, 0x1010, 0x1080, 0x10C0, size);
        // Full ring: WrOff=2, RdOff=3 -> free = 4 - 2 + 3 - 1 = 4? recheck.
        // Make it genuinely full: WrOff just behind RdOff. WrOff=2, RdOff=2 empty;
        // full is free==0: pick WrOff=1, RdOff=2 -> rd>wr -> free = 2-1-1 = 0.
        let down_desc = 0x1010 + HDR_LEN as u16 + DESC_LEN as u16;
        m.poke_word(down_desc + 6, 1); // WrOff
        m.poke_word(down_desc + 8, 2); // RdOff
        let mut dm = attach(m);
        let cb = find_control_block(&mut dm, 0x1000, 0x1200).unwrap();
        let n = write_down(&mut dm, &cb.down[0], b"x").unwrap();
        assert_eq!(n, 0);
        assert_eq!(dm.read_mem_word(down_desc + 6).unwrap(), 1); // unchanged
    }

    #[test]
    fn down_free_math() {
        assert_eq!(down_free(8, 0, 0), 7); // empty: size-1 usable
        assert_eq!(down_free(8, 6, 3), 4);
        assert_eq!(down_free(8, 3, 6), 2); // rd>wr
        assert_eq!(down_free(4, 1, 2), 0); // full
    }
}
