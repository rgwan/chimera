// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//! jtag2gdb: bridge h8300-elf-gdb to the Chimera core over its custom JTAG DTM.
//!
//! Layers, bottom to top:
//!   backend      pin-level JTAG (sim_socket for simulation, ft232_mpsse for HW)
//!   jtag_tap     16-state TAP FSM + IR/DR scans
//!   dtm          STATUS/IDCODE/CONTROL/BYPASS + go/in_progress poll (no busy)
//!   dm_h8        halt/resume/PC/mem + GPR via program buffer
//!   rsp_server   gdb RSP framing + handlers + 27-byte register block
//!   rtt          host-only RTT terminal over DM auto-halt mem access

pub mod backend;
pub mod dm_h8;
pub mod dtm;
pub mod jtag_tap;
pub mod rsp_server;
pub mod rtt;
pub mod sim_socket;

#[cfg(feature = "ft232")]
pub mod ft232_mpsse;
