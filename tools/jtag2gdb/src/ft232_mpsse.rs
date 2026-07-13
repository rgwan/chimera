// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! FT232H/FT2232 MPSSE JTAG backend for real silicon.
//!
//! Adapted from generic FTDI MPSSE JTAG practice: TCK on AD0, TDI on AD1, TDO on
//! AD2, TMS on AD3, output-enable on AD7. TDO is driven on the falling TCK edge
//! and sampled on the rising edge (the DTM's convention), so MPSSE clocks TMS/
//! TDI on the falling edge and reads TDO on the rising edge.
//!
//! This backend needs the FT232 adapter and is gated behind the `ft232` feature.
//! It is not exercised in the simulation flow; it exists so the real-hardware
//! path is codeable and reviewable. The bit-level protocol is identical to the
//! sim backend, so the TAP / DTM / DM / RSP layers above are shared unchanged.

#![cfg(feature = "ft232")]

use crate::backend::JtagBackend;
use anyhow::{Context, Result};
use libftd2xx::{BitMode, Ft232h, Ftdi, FtdiCommon};
use std::convert::TryInto;

/// MPSSE opcodes for 1-bit TMS/TDI shifting with TDO read.
mod mpsse {
    /// Clock TMS out on falling edge, read TDO on rising edge (LSB-first).
    pub const TMS_OUT_READ: u8 = 0x6B;
    /// Clock TDI out on falling edge, read TDO on rising edge (LSB-first).
    pub const TDI_OUT_READ: u8 = 0x6B; // same engine, TMS line carries data bit
    pub const SET_BITS_LOW: u8 = 0x80;
    pub const SET_BITS_HIGH: u8 = 0x82;
    pub const DISABLE_LOOPBACK: u8 = 0x85;
    pub const SET_CLOCK_DIV: u8 = 0x86;
    pub const DISABLE_DIV5: u8 = 0x8A;
    pub const DISABLE_ADAPTIVE: u8 = 0x97;
}

pub struct Ft232Mpsse {
    dev: Ft232h,
    // Current level of TMS/TDI when idle; TDO reads come back interleaved.
    last_tms: bool,
    last_tdi: bool,
}

impl Ft232Mpsse {
    /// Open the first FT232H, put it in MPSSE mode, set the pin directions and a
    /// conservative ~1 MHz TCK.
    pub fn open() -> Result<Self> {
        // Open the first FTDI device and narrow it to an FT232H.
        let ftdi = Ftdi::new().context("open first FTDI device")?;
        let mut dev: Ft232h = ftdi
            .try_into()
            .map_err(|e| anyhow::anyhow!("device is not an FT232H: {e:?}"))?;
        dev.set_bit_mode(0x00, BitMode::Reset)?;
        dev.set_bit_mode(0x00, BitMode::Mpsse)?;
        // AD0=TCK out, AD1=TDI out, AD3=TMS out, AD7=OE out; AD2=TDO in.
        let dir_low = 0b1000_1011u8; // AD0,AD1,AD3,AD7 outputs
        let init = [
            mpsse::DISABLE_DIV5,
            mpsse::DISABLE_ADAPTIVE,
            mpsse::DISABLE_LOOPBACK,
            mpsse::SET_CLOCK_DIV,
            0x1D, // div low: 60MHz/(2*(1+0x1D)) ~= 1 MHz
            0x00, // div high
            mpsse::SET_BITS_LOW,
            0x00,    // initial values: TCK/TDI/TMS low
            dir_low, // directions
            mpsse::SET_BITS_HIGH,
            0x00,
            0x80, // AD7 output (OE)
        ];
        dev.write_all(&init)?;
        Ok(Ft232Mpsse {
            dev,
            last_tms: false,
            last_tdi: false,
        })
    }
}

impl JtagBackend for Ft232Mpsse {
    fn reset(&mut self) -> Result<()> {
        // No dedicated TRST wire in this adapter mapping; drive 5+ TMS=1 clocks
        // to reach Test-Logic-Reset, which the DTM treats as its reset.
        for _ in 0..6 {
            self.tick(true, false)?;
        }
        self.flush()
    }

    fn tick(&mut self, tms: bool, tdi: bool) -> Result<bool> {
        // Shift a single bit: MPSSE 0x6B clocks one bit of the "TMS" field out
        // on the falling edge while presenting TDI on the last-state bit, and
        // reads TDO on the rising edge. Encode our tms/tdi in one bit-op.
        self.last_tms = tms;
        self.last_tdi = tdi;
        // Byte 0: command, byte 1: length-1 (0 => 1 bit), byte 2: data. Bit 7 of
        // data is the held TDI level; bit 0 is the TMS/TDI bit clocked out.
        let data = ((tdi as u8) << 7) | (tms as u8);
        self.dev
            .write_all(&[mpsse::TMS_OUT_READ, 0x00, data])
            .context("MPSSE shift")?;
        let mut buf = [0u8; 1];
        self.dev.read_all(&mut buf).context("MPSSE read TDO")?;
        // TDO is the MSB of the returned byte for a 1-bit read.
        Ok(buf[0] & 0x80 != 0)
    }

    fn flush(&mut self) -> Result<()> {
        // libftd2xx writes are unbuffered here; nothing to flush.
        let _ = (self.last_tms, self.last_tdi);
        Ok(())
    }
}
