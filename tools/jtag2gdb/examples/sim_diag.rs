// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! Low-level DTM diagnostic: raw IDCODE / STATUS / CONTROL scans, matching the
//! reference testbench sequence bit-for-bit. Used to localise sim-path issues.

use jtag2gdb::dtm::{pack_control, Cmd, Status, CTRL_BITS, IDCODE_BITS, STATUS_BITS};
use jtag2gdb::dtm::ir;
use jtag2gdb::jtag_tap::Tap;
use jtag2gdb::sim_socket::SimSocket;

fn main() -> anyhow::Result<()> {
    let addr = std::env::args().nth(1).unwrap_or("127.0.0.1:2542".into());
    let backend = SimSocket::connect(&addr)?;
    let mut tap = Tap::new(backend);
    tap.reset()?;

    tap.shift_ir(ir::IDCODE)?;
    let id = tap.shift_dr(IDCODE_BITS, 0)?;
    println!("IDCODE raw = {id:#010x}");

    // Launch HALT.
    tap.shift_ir(ir::CONTROL)?;
    let launch = pack_control(true, Cmd::Halt, 0, 0);
    let r = tap.shift_dr(CTRL_BITS, launch)?;
    println!("after halt launch, CONTROL readback raw = {r:#012x} in_progress={}",
        (r >> 35) & 1);
    // Poll CONTROL (go=0).
    let poll = pack_control(false, Cmd::Halt, 0, 0);
    for i in 0..40 {
        let rr = tap.shift_dr(CTRL_BITS, poll)?;
        let ip = (rr >> 35) & 1;
        if i < 6 || ip == 0 {
            println!("  poll[{i}] CONTROL raw={rr:#012x} in_progress={ip}");
        }
        if ip == 0 { break; }
    }

    // Poll STATUS.
    tap.shift_ir(ir::STATUS)?;
    for i in 0..60 {
        let s = tap.shift_dr(STATUS_BITS, 0)?;
        let st = Status::decode(s);
        if i < 8 || st.is_halted {
            println!("  STATUS[{i}] raw={s:#08x} halted={} sleeping={} dbg_base={:#06x} hwbp={}",
                st.is_halted, st.is_sleeping, st.dbg_base, st.hwbp_count);
        }
        if st.is_halted { break; }
    }
    Ok(())
}
