// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! jtag2gdb entry point.
//!
//! Usage:
//!   jtag2gdb --sim <sim-host:port> --gdb <listen:port>
//!   jtag2gdb --ft232 --gdb <listen:port>         (requires the `ft232` feature)
//!
//! The default sim host is 127.0.0.1:2542 and the default gdb listen is
//! 127.0.0.1:3333.

use anyhow::{bail, Result};
use jtag2gdb::backend::JtagBackend;
use jtag2gdb::dm_h8::DmH8;
use jtag2gdb::dtm::Dtm;
use jtag2gdb::jtag_tap::Tap;
use jtag2gdb::rsp_server::RspServer;
use jtag2gdb::sim_socket::SimSocket;

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let mut sim_addr = "127.0.0.1:2542".to_string();
    let mut gdb_addr = "127.0.0.1:3333".to_string();
    let mut use_ft232 = false;

    let mut args = std::env::args().skip(1);
    while let Some(a) = args.next() {
        match a.as_str() {
            "--sim" => sim_addr = args.next().unwrap_or(sim_addr),
            "--gdb" => gdb_addr = args.next().unwrap_or(gdb_addr),
            "--ft232" => use_ft232 = true,
            "-h" | "--help" => {
                eprintln!("usage: jtag2gdb [--sim host:port] [--gdb listen:port] [--ft232]");
                return Ok(());
            }
            other => bail!("unknown argument {other}"),
        }
    }

    if use_ft232 {
        run_ft232(&gdb_addr)
    } else {
        let backend = SimSocket::connect(&sim_addr)?;
        run(backend, &gdb_addr)
    }
}

fn run<B: JtagBackend>(backend: B, gdb_addr: &str) -> Result<()> {
    let tap = Tap::new(backend);
    let mut dtm = Dtm::new(tap);
    dtm.reset()?;
    let idcode = dtm.read_idcode()?;
    log::info!("IDCODE = {idcode:#010x}");
    let dm = DmH8::new(dtm);
    let mut server = RspServer::new(dm);
    server.serve_once(gdb_addr)
}

#[cfg(feature = "ft232")]
fn run_ft232(gdb_addr: &str) -> Result<()> {
    let backend = jtag2gdb::ft232_mpsse::Ft232Mpsse::open()?;
    run(backend, gdb_addr)
}

#[cfg(not(feature = "ft232"))]
fn run_ft232(_gdb_addr: &str) -> Result<()> {
    bail!("built without the `ft232` feature; rebuild with --features ft232")
}
