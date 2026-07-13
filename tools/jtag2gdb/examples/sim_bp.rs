// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! Reproduce the gdb software-breakpoint flow directly: load a tiny program,
//! insert TRAPA #2 at a target, set PC, resume, and confirm the core re-halts.

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
    println!("halted, pc={:#06x}", dm.read_pc()?);

    // Program at 0x30: mov.w #0x1111,r0 ; mov.w #0x2222,r1 ; nop @0x3a ...
    // 79 00 11 11 | 79 01 22 22 | 00 00 (nop @0x3a)
    dm.write_mem_word(0x30, 0x7900)?;
    dm.write_mem_word(0x32, 0x1111)?;
    dm.write_mem_word(0x34, 0x7901)?;
    dm.write_mem_word(0x36, 0x2222)?;
    dm.write_mem_word(0x38, 0x0000)?; // nop
    dm.write_mem_word(0x3a, 0x0000)?; // nop (breakpoint target)
    dm.write_mem_word(0x3c, 0x0000)?;
    dm.write_mem_word(0x3e, 0x40fe)?; // bra . (loop)

    // Mimic gdb: read all GPRs (program-buffer) before setting the breakpoint,
    // to reproduce any residual-state interaction.
    dm.write_pc(0x30)?;
    for n in 0..8u8 {
        let v = dm.read_gpr(n)?;
        println!("  r{n} = {v:#06x} (progbuf); pc now {:#06x}", dm.read_pc()?);
    }
    println!("after full GPR read, pc={:#06x}", dm.read_pc()?);

    // Insert software breakpoint (TRAPA #2) at 0x3a.
    let orig = dm.read_mem_word(0x3a)?;
    dm.write_mem_word(0x3a, TRAPA2)?;
    println!("bp @0x3a: orig={:#06x} now={:#06x}", orig, dm.read_mem_word(0x3a)?);

    dm.write_pc(0x30)?;
    println!("pc set to {:#06x}", dm.read_pc()?);

    println!("resuming...");
    dm.resume()?;
    println!("resumed; polling for re-halt");
    let s = dm.dtm.wait_halted(true)?;
    println!("RE-HALTED at pc={:#06x}, status={:?}", dm.read_pc()?, s);
    println!("SW-BREAKPOINT HIT OK");
    Ok(())
}
