// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! gdb Remote Serial Protocol server for h8300-elf-gdb.
//!
//! gdb owns the H8 instruction decoder and does software single-step, so this
//! server implements framing, `qSupported`, the 27-byte register block, memory,
//! run control (`c`/`vCont;c`), and software breakpoints (`Z0`/`z0` inserting
//! `TRAPA #2`). It never decodes instructions itself.
//!
//! ## H8/300 register block (26 bytes, little-endian per field)
//! Verified against h8300-elf-gdb 17.1 `maint print raw-registers`: the `g`
//! block holds the 13 raw registers (Nr 0..12); `ccr` (Nr 13) is a *cooked*
//! pseudo-register served only through `p`/`P`, not in `g`/`G`.
//! ```text
//!  [0..2)   r0    [2..4)   r1    [4..6)   r2    [6..8)   r3
//!  [8..10)  r4    [10..12) r5    [12..14) r6    [14..16) r7 (sp)
//!  [16..18) Nr 8 unnamed state reg (returned 0)
//!  [18..20) pc (Nr 9)
//!  [20..22) cycles  [22..24) tick  [24..26) inst  (Nr 10..12, sim, returned 0)
//! ```
//! Register indices for `p`/`P`: 0..7 = r0..r7, 8 = state, 9 = pc,
//! 10..12 = sim counters, 13 = ccr (served from the DM, 1 byte).

use crate::backend::JtagBackend;
use crate::dm_h8::{DmH8, TRAPA2};
use anyhow::{bail, Context, Result};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};

/// The `g`/`G` block is the 13 raw registers = 26 bytes (ccr is cooked).
const REG_BLOCK_LEN: usize = 26;

/// A saved software breakpoint: original word so `z0` can restore it.
struct SwBreak {
    orig: u16,
}

pub struct RspServer<B: JtagBackend> {
    dm: DmH8<B>,
    breakpoints: HashMap<u16, SwBreak>,
}

impl<B: JtagBackend> RspServer<B> {
    pub fn new(dm: DmH8<B>) -> Self {
        RspServer {
            dm,
            breakpoints: HashMap::new(),
        }
    }

    /// Accept one gdb connection on `addr` and serve until it disconnects.
    pub fn serve_once(&mut self, addr: &str) -> Result<()> {
        let listener = TcpListener::bind(addr).with_context(|| format!("bind {addr}"))?;
        log::info!("jtag2gdb RSP listening on {addr}");
        let (stream, peer) = listener.accept()?;
        log::info!("gdb connected from {peer}");
        stream.set_nodelay(true).ok();
        let mut conn = Conn::new(stream);
        // On attach, halt the core so gdb sees a stopped target.
        self.dm.halt().ok();
        self.serve(&mut conn)
    }

    fn serve(&mut self, conn: &mut Conn) -> Result<()> {
        loop {
            let packet = match conn.read_packet()? {
                Some(p) => p,
                None => {
                    log::info!("gdb disconnected");
                    return Ok(());
                }
            };
            log::debug!("<- {}", String::from_utf8_lossy(&packet));
            let keep_going = self.dispatch(conn, &packet)?;
            if !keep_going {
                return Ok(());
            }
        }
    }

    /// Returns Ok(false) to close the connection (kill).
    fn dispatch(&mut self, conn: &mut Conn, packet: &[u8]) -> Result<bool> {
        if packet.is_empty() {
            conn.send(b"")?;
            return Ok(true);
        }
        match packet[0] {
            b'q' => self.handle_query(conn, packet)?,
            b'?' => conn.send(b"S05")?, // SIGTRAP: stopped
            b'g' => self.handle_read_regs(conn)?,
            b'G' => self.handle_write_regs(conn, &packet[1..])?,
            b'p' => self.handle_read_one_reg(conn, &packet[1..])?,
            b'P' => self.handle_write_one_reg(conn, &packet[1..])?,
            b'm' => self.handle_read_mem(conn, &packet[1..])?,
            b'M' => self.handle_write_mem(conn, &packet[1..])?,
            b'c' => self.handle_continue(conn, &packet[1..])?,
            b'C' => self.handle_continue(conn, b"")?, // continue with signal
            b'v' => self.handle_v(conn, packet)?,
            b'Z' => self.handle_insert_bp(conn, &packet[1..])?,
            b'z' => self.handle_remove_bp(conn, &packet[1..])?,
            b'H' => conn.send(b"OK")?, // thread select: single thread
            b'k' => return Ok(false),  // kill
            b'D' => {
                conn.send(b"OK")?; // detach
                self.dm.resume().ok();
                return Ok(false);
            }
            _ => conn.send(b"")?, // unsupported
        }
        Ok(true)
    }

    fn handle_query(&mut self, conn: &mut Conn, packet: &[u8]) -> Result<()> {
        let q = &packet[1..];
        if q.starts_with(b"Supported") {
            conn.send(b"PacketSize=1000;swbreak+;qXfer:features:read-")?;
        } else if q == b"Attached" {
            conn.send(b"1")?;
        } else if q == b"C" {
            conn.send(b"QC1")?; // current thread = 1
        } else if q.starts_with(b"fThreadInfo") {
            conn.send(b"m1")?;
        } else if q.starts_with(b"sThreadInfo") {
            conn.send(b"l")?;
        } else if q.starts_with(b"Symbol") {
            conn.send(b"OK")?;
        } else {
            conn.send(b"")?;
        }
        Ok(())
    }

    fn read_reg_block(&mut self) -> Result<[u8; REG_BLOCK_LEN]> {
        // H8/300 is big-endian: each 16-bit register is MSB-first in the block.
        let mut blk = [0u8; REG_BLOCK_LEN];
        for n in 0..8u8 {
            let v = self.dm.read_gpr(n)?;
            blk[(n as usize) * 2] = (v >> 8) as u8;
            blk[(n as usize) * 2 + 1] = (v & 0xFF) as u8;
        }
        // [16..18) unnamed state reg -> 0.
        let pc = self.dm.read_pc()?;
        blk[18] = (pc >> 8) as u8;
        blk[19] = (pc & 0xFF) as u8;
        // counters [20..26) -> 0. ccr is not in the g block (cooked; via `p`).
        Ok(blk)
    }

    fn handle_read_regs(&mut self, conn: &mut Conn) -> Result<()> {
        let blk = self.read_reg_block()?;
        conn.send(hex_bytes(&blk).as_bytes())
    }

    fn handle_write_regs(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        let bytes = unhex(body)?;
        if bytes.len() < REG_BLOCK_LEN {
            conn.send(b"E01")?;
            return Ok(());
        }
        // Big-endian: MSB-first per register.
        for n in 0..8u8 {
            let hi = bytes[(n as usize) * 2] as u16;
            let lo = bytes[(n as usize) * 2 + 1] as u16;
            self.dm.write_gpr(n, (hi << 8) | lo)?;
        }
        let pc = ((bytes[18] as u16) << 8) | bytes[19] as u16;
        self.dm.write_pc(pc)?;
        conn.send(b"OK")
    }

    fn handle_read_one_reg(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        let idx = parse_hex_u32(body)? as usize;
        if idx == 13 {
            // ccr: 1 byte (H8 CCR is 8-bit), read via program buffer.
            let ccr = self.dm.read_ccr()?;
            return conn.send(hex_bytes(&[ccr]).as_bytes());
        }
        let val: u16 = match idx {
            0..=7 => self.dm.read_gpr(idx as u8)?,
            9 => self.dm.read_pc()?,
            _ => 0, // Nr 8 state / Nr 10..12 counters
        };
        // Big-endian: MSB-first.
        let bytes = [(val >> 8) as u8, (val & 0xFF) as u8];
        conn.send(hex_bytes(&bytes).as_bytes())
    }

    fn handle_write_one_reg(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        let eq = body
            .iter()
            .position(|&c| c == b'=')
            .context("P packet missing '='")?;
        let idx = parse_hex_u32(&body[..eq])? as usize;
        let bytes = unhex(&body[eq + 1..])?;
        // Big-endian: MSB-first.
        let val = if bytes.len() >= 2 {
            ((bytes[0] as u16) << 8) | bytes[1] as u16
        } else if bytes.len() == 1 {
            bytes[0] as u16
        } else {
            0
        };
        match idx {
            0..=7 => self.dm.write_gpr(idx as u8, val)?,
            9 => self.dm.write_pc(val)?,
            _ => {}
        }
        conn.send(b"OK")
    }

    fn handle_read_mem(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        let (addr, len) = parse_addr_len(body)?;
        let bytes = self.dm.read_mem(addr, len as usize)?;
        conn.send(hex_bytes(&bytes).as_bytes())
    }

    fn handle_write_mem(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        let colon = body
            .iter()
            .position(|&c| c == b':')
            .context("M packet missing ':'")?;
        let (addr, _len) = parse_addr_len(&body[..colon])?;
        let bytes = unhex(&body[colon + 1..])?;
        self.dm.write_mem(addr, &bytes)?;
        conn.send(b"OK")
    }

    fn handle_continue(&mut self, conn: &mut Conn, _body: &[u8]) -> Result<()> {
        self.resume_until_stop(conn)
    }

    fn handle_v(&mut self, conn: &mut Conn, packet: &[u8]) -> Result<()> {
        if packet.starts_with(b"vCont?") {
            conn.send(b"vCont;c;C")?;
        } else if packet.starts_with(b"vCont;c") || packet.starts_with(b"vCont;C") {
            self.resume_until_stop(conn)?;
        } else if packet.starts_with(b"vMustReplyEmpty") {
            conn.send(b"")?;
        } else {
            conn.send(b"")?;
        }
        Ok(())
    }

    /// Resume and poll STATUS until the core re-halts (a TRAPA #2 breakpoint
    /// re-enters debug), then report a SIGTRAP stop with swbreak.
    fn resume_until_stop(&mut self, conn: &mut Conn) -> Result<()> {
        let pc_before = self.dm.read_pc().unwrap_or(0);
        log::debug!("resume from pc={pc_before:#06x}");
        self.dm.resume()?;
        // Wait for the core to re-halt at a breakpoint. wait_halted polls with a
        // bounded guard; the breakpoint re-enters debug within a few cycles.
        self.dm.dtm.wait_halted(true)?;
        let pc_after = self.dm.read_pc()?;
        log::debug!("re-halted at pc={pc_after:#06x}");
        // TRAPA #2 leaves PC just past the 2-byte trap word. If that lands one
        // instruction past a software breakpoint we planted, back the PC up to
        // the breakpoint address so gdb sees the stop AT the breakpoint (the
        // swbreak convention) and does not immediately continue again.
        let bp_pc = pc_after.wrapping_sub(2);
        if self.breakpoints.contains_key(&bp_pc) {
            self.dm.write_pc(bp_pc)?;
            log::debug!("rewound PC to breakpoint {bp_pc:#06x}");
        }
        conn.send(b"T05swbreak:;")
    }

    fn handle_insert_bp(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        // Format: <type>,<addr>,<kind>. type 0 = software breakpoint.
        let (ty, addr) = parse_bp(body)?;
        if ty != 0 {
            conn.send(b"")?; // only software breakpoints
            return Ok(());
        }
        if !self.breakpoints.contains_key(&addr) {
            let orig = self.dm.read_mem_word(addr)?;
            self.dm.write_mem_word(addr, TRAPA2)?;
            self.breakpoints.insert(addr, SwBreak { orig });
            log::debug!("insert swbp @{addr:#06x}, orig={orig:#06x}");
        }
        conn.send(b"OK")
    }

    fn handle_remove_bp(&mut self, conn: &mut Conn, body: &[u8]) -> Result<()> {
        let (ty, addr) = parse_bp(body)?;
        if ty != 0 {
            conn.send(b"")?;
            return Ok(());
        }
        if let Some(bp) = self.breakpoints.remove(&addr) {
            self.dm.write_mem_word(addr, bp.orig)?;
            log::debug!("remove swbp @{addr:#06x}, restored={:#06x}", bp.orig);
        }
        conn.send(b"OK")
    }
}

// ---- RSP wire framing ----

struct Conn {
    stream: TcpStream,
    inbuf: Vec<u8>,
    no_ack: bool,
}

impl Conn {
    fn new(stream: TcpStream) -> Self {
        Conn {
            stream,
            inbuf: Vec::new(),
            no_ack: false,
        }
    }

    /// Read one complete `$...#cc` packet, sending `+` ack. Returns None on EOF.
    fn read_packet(&mut self) -> Result<Option<Vec<u8>>> {
        loop {
            if let Some(pkt) = self.try_extract()? {
                return Ok(Some(pkt));
            }
            let mut buf = [0u8; 4096];
            let n = self.stream.read(&mut buf)?;
            if n == 0 {
                return Ok(None);
            }
            self.inbuf.extend_from_slice(&buf[..n]);
        }
    }

    fn try_extract(&mut self) -> Result<Option<Vec<u8>>> {
        // Drop leading acks / interrupts we do not need to parse specially.
        while let Some(&c) = self.inbuf.first() {
            match c {
                b'+' | b'-' => {
                    self.inbuf.remove(0);
                }
                0x03 => {
                    // Ctrl-C interrupt: treat as an empty stop request.
                    self.inbuf.remove(0);
                    return Ok(Some(vec![b'?']));
                }
                b'$' => break,
                _ => {
                    self.inbuf.remove(0);
                }
            }
        }
        let start = match self.inbuf.iter().position(|&c| c == b'$') {
            Some(p) => p,
            None => return Ok(None),
        };
        let hash = match self.inbuf[start..].iter().position(|&c| c == b'#') {
            Some(p) => start + p,
            None => return Ok(None),
        };
        if self.inbuf.len() < hash + 3 {
            return Ok(None); // checksum digits not yet in
        }
        let body = self.inbuf[start + 1..hash].to_vec();
        let sum_hex = &self.inbuf[hash + 1..hash + 3];
        let want = parse_hex_u32(sum_hex).unwrap_or(0) as u8;
        let got = checksum(&body);
        self.inbuf.drain(..hash + 3);
        if want == got {
            if !self.no_ack {
                self.stream.write_all(b"+")?;
                self.stream.flush()?;
            }
        } else {
            self.stream.write_all(b"-")?;
            self.stream.flush()?;
            return Ok(Some(Vec::new())); // let dispatch send empty; gdb retries
        }
        // The QStartNoAckMode handshake is not advertised; keep acks on.
        Ok(Some(body))
    }

    fn send(&mut self, body: &[u8]) -> Result<()> {
        let mut out = Vec::with_capacity(body.len() + 4);
        out.push(b'$');
        out.extend_from_slice(body);
        out.push(b'#');
        let sum = checksum(body);
        out.extend_from_slice(format!("{sum:02x}").as_bytes());
        log::debug!("-> {}", String::from_utf8_lossy(body));
        self.stream.write_all(&out)?;
        self.stream.flush()?;
        if !self.no_ack {
            // Read the gdb ack (+). Ignore a resend request for simplicity.
            let mut a = [0u8; 1];
            let _ = self.stream.read(&mut a);
        }
        Ok(())
    }
}

fn checksum(body: &[u8]) -> u8 {
    body.iter().fold(0u8, |a, &b| a.wrapping_add(b))
}

fn hex_bytes(bytes: &[u8]) -> String {
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

fn unhex(hex: &[u8]) -> Result<Vec<u8>> {
    if hex.len() % 2 != 0 {
        bail!("odd-length hex");
    }
    let mut out = Vec::with_capacity(hex.len() / 2);
    for pair in hex.chunks(2) {
        let hi = hex_digit(pair[0])?;
        let lo = hex_digit(pair[1])?;
        out.push((hi << 4) | lo);
    }
    Ok(out)
}

fn hex_digit(c: u8) -> Result<u8> {
    match c {
        b'0'..=b'9' => Ok(c - b'0'),
        b'a'..=b'f' => Ok(c - b'a' + 10),
        b'A'..=b'F' => Ok(c - b'A' + 10),
        _ => bail!("bad hex digit {c}"),
    }
}

fn parse_hex_u32(s: &[u8]) -> Result<u32> {
    let mut v: u32 = 0;
    for &c in s {
        v = (v << 4) | hex_digit(c)? as u32;
    }
    Ok(v)
}

/// Parse `addr,len` (both hex).
fn parse_addr_len(s: &[u8]) -> Result<(u16, u32)> {
    let comma = s
        .iter()
        .position(|&c| c == b',')
        .context("missing ',' in addr,len")?;
    let addr = parse_hex_u32(&s[..comma])? as u16;
    let len = parse_hex_u32(&s[comma + 1..])?;
    Ok((addr, len))
}

/// Parse `<type>,<addr>,<kind>` for Z/z; returns (type, addr).
fn parse_bp(s: &[u8]) -> Result<(u32, u16)> {
    let mut parts = s.split(|&c| c == b',');
    let ty = parse_hex_u32(parts.next().context("bp type")?)?;
    let addr = parse_hex_u32(parts.next().context("bp addr")?)? as u16;
    Ok((ty, addr))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn checksum_matches_rsp() {
        assert_eq!(checksum(b"OK"), (b'O' as u8).wrapping_add(b'K'));
    }

    #[test]
    fn hex_roundtrip() {
        let b = [0xBE, 0xEF, 0x00, 0x57, 0x20];
        assert_eq!(unhex(hex_bytes(&b).as_bytes()).unwrap(), b);
    }

    #[test]
    fn parse_addr_len_hex() {
        let (a, l) = parse_addr_len(b"300,2").unwrap();
        assert_eq!(a, 0x300);
        assert_eq!(l, 2);
    }

    #[test]
    fn parse_bp_fields() {
        let (ty, addr) = parse_bp(b"0,40,2").unwrap();
        assert_eq!(ty, 0);
        assert_eq!(addr, 0x40);
    }

    #[test]
    fn reg_block_len_is_26() {
        // 13 raw registers; ccr is cooked and excluded from the g block.
        assert_eq!(REG_BLOCK_LEN, 26);
    }
}
