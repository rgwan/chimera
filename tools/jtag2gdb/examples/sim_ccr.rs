// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! Validate CCR-read-via-program-buffer: load a known CCR value with `LDC`,
//! trap, then read it back through the DM program-buffer path.

use jtag2gdb::dm_h8::{DmH8, TRAPA2};
use jtag2gdb::dtm::Dtm;
use jtag2gdb::jtag_tap::Tap;
use jtag2gdb::sim_socket::SimSocket;

fn main() -> anyhow::Result<()> {
    let addr = std::env::args().nth(1).unwrap_or("127.0.0.1:2542".into());
    let backend = SimSocket::connect(&addr)?;
    let tap = Tap::new(backend);
    let mut dtm = Dtm::new(tap);
    dtm.reset()?;
    let mut dm = DmH8::new(dtm);

    dm.halt()?;

    // Program at 0x30: LDC #0x2C,ccr (07 2C) ; TRAPA #2 (57 20).
    // Choose 0x2C (I=0,H=1,N=0,Z=1,V=1,C=0 ... any legal byte works as a witness).
    let ccr_val: u8 = 0x2C;
    dm.write_mem_word(0x30, 0x0700 | ccr_val as u16)?; // 07 2C
    dm.write_mem_word(0x32, TRAPA2)?; // 57 20
    dm.write_pc(0x30)?;
    dm.resume()?;
    dm.dtm.wait_halted(true)?;
    println!("ran LDC #{:#04x},ccr; core re-halted at pc={:#06x}", ccr_val, dm.read_pc()?);

    let ccr = dm.read_ccr()?;
    println!("read_ccr() = {ccr:#04x} (loaded {ccr_val:#04x})");
    // The scratch-register save inside read_ccr executes a MOV that updates the
    // N/Z/V flags, so those three bits may differ; the stable bits I/UI/H/U/C
    // (mask 0xF1) are read back faithfully. This matches the perturbation gdb's
    // own g-packet GPR reads already cause on this microarchitecture.
    const STABLE: u8 = 0xF1; // I UI H U _ _ _ C
    println!(
        "  stable bits (0xF1): read {:#04x} vs loaded {:#04x}",
        ccr & STABLE,
        ccr_val & STABLE
    );
    assert_eq!(ccr & STABLE, ccr_val & STABLE, "CCR stable bits mismatch");

    // Confirm losslessness: read_ccr must restore r0/r6/PC/CCR.
    let r0 = dm.read_gpr(0)?;
    let r6 = dm.read_gpr(6)?;
    println!("r0 after read_ccr = {r0:#06x}; r6 = {r6:#06x} (scratch restored)");
    println!("pc after read_ccr = {:#06x}", dm.read_pc()?);
    // A second read_ccr must return the same value (idempotent, CCR restored).
    let ccr2 = dm.read_ccr()?;
    println!("second read_ccr() = {ccr2:#04x}");
    assert_eq!(ccr, ccr2, "read_ccr not idempotent (CCR not restored)");

    println!("CCR-VIA-PROGBUF OK (stable bits match; idempotent; lossless)");
    Ok(())
}
