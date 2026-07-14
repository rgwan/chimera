// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! jtag2gdb entry point.
//!
//! Usage:
//!   jtag2gdb [gdb] --sim <sim-host:port> --gdb <listen:port>
//!   jtag2gdb [gdb] --ft232 --gdb <listen:port>    (requires the `ft232` feature)
//!   jtag2gdb rtt --sim <sim-host:port> [--scan lo:hi] [--up N] [--down N]
//!
//! The default sim host is 127.0.0.1:2542 and the default gdb listen is
//! 127.0.0.1:3333. The `rtt` subcommand finds the target's RTT control block by
//! scanning RAM for the magic and runs a bidirectional terminal.

use anyhow::{bail, Result};
use jtag2gdb::backend::JtagBackend;
use jtag2gdb::dm_h8::DmH8;
use jtag2gdb::dtm::Dtm;
use jtag2gdb::jtag_tap::Tap;
use jtag2gdb::rsp_server::RspServer;
use jtag2gdb::sim_socket::SimSocket;

/// Shared connection options for either subcommand.
struct Opts {
    sim_addr: String,
    gdb_addr: String,
    use_ft232: bool,
    scan_lo: u16,
    scan_hi: u16,
    up_ch: usize,
    down_ch: usize,
}

impl Default for Opts {
    fn default() -> Self {
        Opts {
            sim_addr: "127.0.0.1:2542".to_string(),
            gdb_addr: "127.0.0.1:3333".to_string(),
            use_ft232: false,
            scan_lo: 0x0000,
            scan_hi: 0xFFFE,
            up_ch: 0,
            down_ch: 0,
        }
    }
}

fn main() -> Result<()> {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();

    let mut args = std::env::args().skip(1).peekable();
    // Optional leading subcommand: "gdb" (default) or "rtt".
    let mut mode = "gdb".to_string();
    if let Some(first) = args.peek() {
        if first == "gdb" || first == "rtt" {
            mode = args.next().unwrap();
        }
    }

    let mut o = Opts::default();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--sim" => o.sim_addr = args.next().unwrap_or(o.sim_addr),
            "--gdb" => o.gdb_addr = args.next().unwrap_or(o.gdb_addr),
            "--ft232" => o.use_ft232 = true,
            "--scan" => {
                let s = args.next().unwrap_or_default();
                let (lo, hi) = s.split_once(':').unwrap_or(("", ""));
                o.scan_lo = parse_u16(lo)?;
                o.scan_hi = parse_u16(hi)?;
            }
            "--up" => o.up_ch = args.next().unwrap_or_default().parse().unwrap_or(0),
            "--down" => o.down_ch = args.next().unwrap_or_default().parse().unwrap_or(0),
            "-h" | "--help" => {
                eprintln!(
                    "usage: jtag2gdb [gdb|rtt] [--sim host:port] [--gdb listen:port] [--ft232]\n\
                     \x20             [--scan lo:hi] [--up N] [--down N]"
                );
                return Ok(());
            }
            other => bail!("unknown argument {other}"),
        }
    }

    match mode.as_str() {
        "rtt" => open_and_run(&o, |dm| run_rtt(dm, &o)),
        _ => open_and_run(&o, |dm| {
            let mut server = RspServer::new(dm);
            server.serve_once(&o.gdb_addr)
        }),
    }
}

fn parse_u16(s: &str) -> Result<u16> {
    let s = s.trim_start_matches("0x");
    u16::from_str_radix(s, 16).map_err(|e| anyhow::anyhow!("bad hex address {s:?}: {e}"))
}

/// Open the selected backend, reset the DTM, log IDCODE, then hand a `DmH8` to
/// the caller.
fn open_and_run<F>(o: &Opts, f: F) -> Result<()>
where
    F: FnOnce(DmH8<Box<dyn JtagBackend>>) -> Result<()>,
{
    let backend: Box<dyn JtagBackend> = if o.use_ft232 {
        open_ft232()?
    } else {
        Box::new(SimSocket::connect(&o.sim_addr)?)
    };
    let tap = Tap::new(backend);
    let mut dtm = Dtm::new(tap);
    dtm.reset()?;
    let idcode = dtm.read_idcode()?;
    log::info!("IDCODE = {idcode:#010x}");
    f(DmH8::new(dtm))
}

fn run_rtt(mut dm: DmH8<Box<dyn JtagBackend>>, o: &Opts) -> Result<()> {
    log::info!("scanning {:#06x}..{:#06x} for RTT block", o.scan_lo, o.scan_hi);
    let cb = jtag2gdb::rtt::find_control_block(&mut dm, o.scan_lo, o.scan_hi)?;
    log::info!(
        "RTT control block at {:#06x}: {} up, {} down channels",
        cb.addr,
        cb.up.len(),
        cb.down.len()
    );
    run_terminal(&mut dm, &cb, o)
}

#[cfg(feature = "terminal")]
fn run_terminal(dm: &mut DmH8<Box<dyn JtagBackend>>, cb: &jtag2gdb::rtt::ControlBlock, o: &Opts) -> Result<()> {
    jtag2gdb::rtt::run_terminal(
        dm,
        cb,
        o.up_ch,
        o.down_ch,
        std::time::Duration::from_millis(10),
    )
}

#[cfg(not(feature = "terminal"))]
fn run_terminal(_dm: &mut DmH8<Box<dyn JtagBackend>>, _cb: &jtag2gdb::rtt::ControlBlock, _o: &Opts) -> Result<()> {
    bail!("built without the `terminal` feature; rebuild with --features terminal")
}

#[cfg(feature = "ft232")]
fn open_ft232() -> Result<Box<dyn JtagBackend>> {
    Ok(Box::new(jtag2gdb::ft232_mpsse::Ft232Mpsse::open()?))
}

#[cfg(not(feature = "ft232"))]
fn open_ft232() -> Result<Box<dyn JtagBackend>> {
    bail!("built without the `ft232` feature; rebuild with --features ft232")
}
