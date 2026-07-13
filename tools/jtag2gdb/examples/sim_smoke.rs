// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! Drive the simulated CoreTop through the DM primitives, mirroring the
//! reference JTAG testbench: IDCODE, halt, mem write/read round-trip, set/read
//! PC, resume. Run against a live `tb_core_top_rbb` sim:
//!   cargo run --example sim_smoke -- 127.0.0.1:2542

use jtag2gdb::dm_h8::DmH8;
use jtag2gdb::dtm::Dtm;
use jtag2gdb::jtag_tap::Tap;
use jtag2gdb::sim_socket::SimSocket;

fn main() -> anyhow::Result<()> {
    let addr = std::env::args().nth(1).unwrap_or("127.0.0.1:2542".into());
    let backend = SimSocket::connect(&addr)?;
    let tap = Tap::new(backend);
    let mut dtm = Dtm::new(tap);
    dtm.reset()?;

    let idcode = dtm.read_idcode()?;
    println!("IDCODE = {idcode:#010x}");
    assert_eq!(idcode, 0x0011_4514, "IDCODE mismatch");

    let mut dm = DmH8::new(dtm);
    dm.halt()?;
    println!("halted");

    let s = dm.dtm.read_status()?;
    println!("STATUS: {s:?}");
    assert!(s.is_halted);
    assert_eq!(s.dbg_base, 0xFF00);
    assert_eq!(s.hwbp_count, 2);
    assert!(s.dmactive, "dmactive readable on STATUS[22]");

    dm.write_mem_word(0x0300, 0xBEEF)?;
    let w = dm.read_mem_word(0x0300)?;
    println!("mem[0x0300] = {w:#06x}");
    assert_eq!(w, 0xBEEF);

    dm.write_mem_word(0x0400, 0x1234)?;
    assert_eq!(dm.read_mem_word(0x0400)?, 0x1234);
    println!("mem round-trips OK");

    dm.write_pc(0x0040)?;
    let pc = dm.read_pc()?;
    println!("PC = {pc:#06x}");
    assert_eq!(pc, 0x0040);

    // GPR via program buffer: write r3, read it back.
    dm.write_gpr(3, 0xABCD)?;
    let r3 = dm.read_gpr(3)?;
    println!("r3 = {r3:#06x}");
    assert_eq!(r3, 0xABCD, "GPR program-buffer round-trip");

    dm.resume()?;
    println!("resumed");
    println!("ALL SIM SMOKE CHECKS PASSED");
    Ok(())
}
