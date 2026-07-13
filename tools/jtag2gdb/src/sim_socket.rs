// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! JTAG-over-TCP backend using the generic remote-bitbang single-char protocol.
//!
//! The simulated CoreTop is wrapped by an iverilog testbench that opens a TCP
//! server and interprets one ASCII command per byte:
//!   'r'/'s'/'t'/'u'  TRST/SRST off/on (bit0=TRST? we use the standard mapping)
//!   '0'..'7'         set (TCK,TMS,TDI) to the low 3 bits and clock TCK per the
//!                    value's TCK bit
//!   'R'              read TDO, reply one ASCII '0'/'1'
//!   'B'/'b'          LED blink on/off (ignored)
//!   'Q'              quit
//!
//! This is the OpenOCD remote_bitbang wire format. The 8 digit commands encode
//! (tck<<2)|(tms<<1)|tdi, so a full TCK cycle is two writes: one with tck=0 to
//! set up TMS/TDI, one with tck=1 to clock. The DUT samples TDO before the
//! rising edge, so we issue 'R' while tck is low, then raise tck.

use crate::backend::JtagBackend;
use anyhow::{bail, Context, Result};
use std::io::{Read, Write};
use std::net::TcpStream;

pub struct SimSocket {
    stream: TcpStream,
}

impl SimSocket {
    pub fn connect(addr: &str) -> Result<Self> {
        let stream = TcpStream::connect(addr).with_context(|| format!("connect sim {addr}"))?;
        stream.set_nodelay(true).ok();
        Ok(SimSocket { stream })
    }

    fn write_cmd(&mut self, c: u8) -> Result<()> {
        self.stream.write_all(&[c])?;
        Ok(())
    }

    /// Encode (tck,tms,tdi) into the '0'..'7' command byte.
    fn pin_cmd(tck: bool, tms: bool, tdi: bool) -> u8 {
        let v = ((tck as u8) << 2) | ((tms as u8) << 1) | (tdi as u8);
        b'0' + v
    }

    fn read_tdo(&mut self) -> Result<bool> {
        self.stream.write_all(b"R")?;
        self.stream.flush()?;
        let mut b = [0u8; 1];
        self.stream.read_exact(&mut b).context("read TDO")?;
        match b[0] {
            b'0' => Ok(false),
            b'1' => Ok(true),
            other => bail!("bad TDO reply {other:#x}"),
        }
    }
}

impl JtagBackend for SimSocket {
    fn reset(&mut self) -> Result<()> {
        // Assert TRST (and SRST) with a few TCK pulses, then release. The DUT
        // wrapper clears its DTM flops while TRST is asserted.
        // remote_bitbang reset command: 'r'=trst0 srst0, 's'=trst0 srst1,
        // 't'=trst1 srst0, 'u'=trst1 srst1.  Here trst active-low semantics are
        // handled by the wrapper; 't' asserts our TRST.
        self.write_cmd(b't')?; // assert TRST
        for _ in 0..6 {
            self.write_cmd(Self::pin_cmd(false, true, false))?;
            self.write_cmd(Self::pin_cmd(true, true, false))?;
        }
        self.write_cmd(b'r')?; // release TRST
        self.stream.flush()?;
        Ok(())
    }

    fn tick(&mut self, tms: bool, tdi: bool) -> Result<bool> {
        // Set up pins with TCK low, sample TDO (valid before the rising edge),
        // then raise TCK to clock the DUT, then drop TCK.
        self.write_cmd(Self::pin_cmd(false, tms, tdi))?;
        let tdo = self.read_tdo()?;
        self.write_cmd(Self::pin_cmd(true, tms, tdi))?; // rising edge
        self.write_cmd(Self::pin_cmd(false, tms, tdi))?; // falling edge
        Ok(tdo)
    }

    fn flush(&mut self) -> Result<()> {
        self.stream.flush()?;
        Ok(())
    }
}
