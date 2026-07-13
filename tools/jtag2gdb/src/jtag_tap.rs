// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! IEEE 1149.1 TAP driver: navigate the 16-state controller and run IR / DR
//! scans over any `JtagBackend`.
//!
//! The Chimera DTM is a single TAP (no chain), so there is no BYPASS padding.
//! Scans always start and end in Run-Test/Idle.

use crate::backend::JtagBackend;
use anyhow::Result;

/// TAP controller, parameterised over the pin backend.
pub struct Tap<B: JtagBackend> {
    backend: B,
}

impl<B: JtagBackend> Tap<B> {
    pub fn new(backend: B) -> Self {
        Tap { backend }
    }

    pub fn backend_mut(&mut self) -> &mut B {
        &mut self.backend
    }

    /// TRST pulse then five TMS=1 to force Test-Logic-Reset, then one TMS=0 to
    /// land in Run-Test/Idle.
    pub fn reset(&mut self) -> Result<()> {
        self.backend.reset()?;
        for _ in 0..5 {
            self.backend.tick(true, false)?;
        }
        self.backend.tick(false, false)?; // -> Run-Test/Idle
        self.backend.flush()?;
        Ok(())
    }

    /// Shift a 4-bit instruction (from Run-Test/Idle, back to Run-Test/Idle).
    pub fn shift_ir(&mut self, value: u8) -> Result<()> {
        self.backend.tick(true, false)?; // RTI -> Select-DR
        self.backend.tick(true, false)?; // -> Select-IR
        self.backend.tick(false, false)?; // -> Capture-IR
        self.backend.tick(false, false)?; // Capture-IR -> Shift-IR
        for i in 0..4 {
            let bit = (value >> i) & 1 == 1;
            let last = i == 3;
            self.backend.tick(last, bit)?; // last bit exits to Exit1-IR
        }
        self.backend.tick(true, false)?; // Exit1-IR -> Update-IR
        self.backend.tick(false, false)?; // -> Run-Test/Idle
        self.backend.flush()?;
        Ok(())
    }

    /// Shift `n` (<=64) bits into the selected DR, capturing the read-back.
    ///
    /// Data is LSB-first, matching the DTM's shift order. The captured value is
    /// what the register presented as it was shifted out.
    pub fn shift_dr(&mut self, n: usize, wdata: u64) -> Result<u64> {
        debug_assert!(n <= 64);
        self.backend.tick(true, false)?; // RTI -> Select-DR
        self.backend.tick(false, false)?; // -> Capture-DR
        self.backend.tick(false, false)?; // Capture-DR -> Shift-DR (loaded)
        let mut rdata: u64 = 0;
        for i in 0..n {
            let bit = (wdata >> i) & 1 == 1;
            let last = i == n - 1;
            let sampled = self.backend.tick(last, bit)?; // sample then shift
            if sampled {
                rdata |= 1u64 << i;
            }
        }
        self.backend.tick(true, false)?; // Exit1-DR -> Update-DR
        self.backend.tick(false, false)?; // -> Run-Test/Idle
        self.backend.flush()?;
        Ok(rdata)
    }
}
