// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Remote-bitbang JTAG server as an Icarus Verilog VPI module.
//
// $rbb_listen(port)  opens a TCP listener and blocks for one client.
// $rbb_step(tdo)     processes at most one queued client command per call and
//                    drives the shared TAP pins via $rbb_pins outputs. Called
//                    once per core clock from the testbench.
//
// Pins are exchanged through module-scope regs the testbench wires to the DUT:
//   the C side writes tck/tms/tdi/trst by name (relative to the caller scope).
// The single-char protocol matches OpenOCD remote_bitbang:
//   '0'..'7' -> set (tck,tms,tdi) = low 3 bits;  'R' -> reply TDO as '0'/'1';
//   't'/'r'  -> assert / release TRST;  'Q' -> quit;  'B'/'b' -> ignored.

#include <vpi_user.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int g_listen = -1;
static int g_client = -1;

// Pin state the C side maintains and pushes into the DUT each step.
static int p_tck = 0, p_tms = 1, p_tdi = 0, p_trst = 1;

// Handles to the testbench pin regs, resolved once from the calling scope.
static vpiHandle h_tck, h_tms, h_tdi, h_trst;

static void put_scalar(vpiHandle h, int v) {
  s_vpi_value val;
  val.format = vpiIntVal;
  val.value.integer = v ? 1 : 0;
  vpi_put_value(h, &val, NULL, vpiNoDelay);
}

static void push_pins(void) {
  put_scalar(h_tck, p_tck);
  put_scalar(h_tms, p_tms);
  put_scalar(h_tdi, p_tdi);
  put_scalar(h_trst, p_trst);
}

// Resolve tck/tms/tdi/trst relative to the scope that called the task.
static void resolve_pins(void) {
  vpiHandle task = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle scope = vpi_handle(vpiScope, task);
  (void)scope;
  h_tck = vpi_handle_by_name("tb_core_top_rbb.tck", NULL);
  h_tms = vpi_handle_by_name("tb_core_top_rbb.tms", NULL);
  h_tdi = vpi_handle_by_name("tb_core_top_rbb.tdi", NULL);
  h_trst = vpi_handle_by_name("tb_core_top_rbb.trst", NULL);
}

static PLI_INT32 rbb_listen_calltf(PLI_BYTE8 *ud) {
  (void)ud;
  vpiHandle task = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle argv = vpi_iterate(vpiArgument, task);
  vpiHandle a0 = vpi_scan(argv);
  s_vpi_value val;
  val.format = vpiIntVal;
  vpi_get_value(a0, &val);
  int port = val.value.integer;

  resolve_pins();

  g_listen = socket(AF_INET, SOCK_STREAM, 0);
  int one = 1;
  setsockopt(g_listen, SOL_SOCKET, SO_REUSEADDR, &one, sizeof(one));
  struct sockaddr_in sa;
  memset(&sa, 0, sizeof(sa));
  sa.sin_family = AF_INET;
  sa.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  sa.sin_port = htons((unsigned short)port);
  if (bind(g_listen, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
    vpi_printf("rbb: bind failed: %s\n", strerror(errno));
    return 0;
  }
  listen(g_listen, 1);
  vpi_printf("rbb: listening on 127.0.0.1:%d\n", port);
  g_client = accept(g_listen, NULL, NULL);
  if (g_client < 0) {
    vpi_printf("rbb: accept failed: %s\n", strerror(errno));
    return 0;
  }
  int nod = 1;
  setsockopt(g_client, IPPROTO_TCP, TCP_NODELAY, &nod, sizeof(nod));
  // Non-blocking so $rbb_step never stalls the simulation.
  int fl = fcntl(g_client, F_GETFL, 0);
  fcntl(g_client, F_SETFL, fl | O_NONBLOCK);
  vpi_printf("rbb: client connected\n");
  push_pins();
  return 0;
}

// Read exactly one command byte if available; return -1 if none pending.
static int read_cmd(void) {
  unsigned char c;
  ssize_t n = recv(g_client, &c, 1, 0);
  if (n == 1)
    return c;
  return -1;
}

static PLI_INT32 rbb_step_calltf(PLI_BYTE8 *ud) {
  (void)ud;
  if (g_client < 0)
    return 0;
  vpiHandle task = vpi_handle(vpiSysTfCall, NULL);
  vpiHandle argv = vpi_iterate(vpiArgument, task);
  vpiHandle a0 = vpi_scan(argv); // tdo input
  s_vpi_value tv;
  tv.format = vpiIntVal;
  vpi_get_value(a0, &tv);
  int tdo = tv.value.integer & 1;

  int c = read_cmd();
  if (c < 0)
    return 0; // nothing queued this clock

  if (c >= '0' && c <= '7') {
    int v = c - '0';
    p_tck = (v >> 2) & 1;
    p_tms = (v >> 1) & 1;
    p_tdi = v & 1;
    push_pins();
  } else if (c == 'R') {
    char r = tdo ? '1' : '0';
    // Blocking send is fine; one byte, client is waiting.
    while (send(g_client, &r, 1, 0) < 0 && errno == EAGAIN) {
    }
  } else if (c == 't') {
    p_trst = 1;
    push_pins();
  } else if (c == 'r') {
    p_trst = 0;
    push_pins();
  } else if (c == 'Q') {
    close(g_client);
    g_client = -1;
    vpi_printf("rbb: client quit\n");
  }
  // 'B','b',other -> ignore.
  return 0;
}

static void register_tasks(void) {
  s_vpi_systf_data listen_tf = {vpiSysTask, 0, "$rbb_listen", rbb_listen_calltf,
                                0, 0, 0};
  vpi_register_systf(&listen_tf);
  s_vpi_systf_data step_tf = {vpiSysTask, 0, "$rbb_step", rbb_step_calltf, 0, 0,
                              0};
  vpi_register_systf(&step_tf);
}

void (*vlog_startup_routines[])(void) = {register_tasks, 0};
