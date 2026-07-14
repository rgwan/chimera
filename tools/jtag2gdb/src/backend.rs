// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! JTAG pin-level transport abstraction.
//!
//! A backend drives the four TAP pins (TCK/TMS/TDI/TDO) plus TRST. The higher
//! layers (`jtag_tap`, `dtm`) speak only in terms of clock pulses and bit
//! shifts, so the same TAP state machine drives either a simulated DUT
//! (`sim_socket`) or real silicon (`ft232_mpsse`).

use anyhow::Result;

/// One TAP clock: presents TMS/TDI, samples TDO, then pulses TCK.
///
/// Semantics match the reference sim testbench: TDO is the LSB the selected
/// register presents *before* the rising TCK edge, so a backend samples TDO
/// with the current TMS/TDI applied and *then* clocks. The returned bool is the
/// sampled TDO.
pub trait JtagBackend {
    /// Assert TRST, pulse TCK a few times so the TCK-domain flops clear, then
    /// release TRST. Matches the DTM's synchronous reset.
    fn reset(&mut self) -> Result<()>;

    /// Present `tms`/`tdi`, sample TDO, clock one TCK edge. Returns sampled TDO.
    fn tick(&mut self, tms: bool, tdi: bool) -> Result<bool>;

    /// Optional flush hook for buffered/batched backends (MPSSE). Default no-op.
    fn flush(&mut self) -> Result<()> {
        Ok(())
    }
}

/// Forward through a boxed backend so callers can pick sim vs FT232 at runtime
/// (`Box<dyn JtagBackend>`) without making every layer generic over the choice.
impl JtagBackend for Box<dyn JtagBackend> {
    fn reset(&mut self) -> Result<()> {
        (**self).reset()
    }

    fn tick(&mut self, tms: bool, tdi: bool) -> Result<bool> {
        (**self).tick(tms, tdi)
    }

    fn flush(&mut self) -> Result<()> {
        (**self).flush()
    }
}
