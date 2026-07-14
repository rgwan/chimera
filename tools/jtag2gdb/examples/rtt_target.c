// SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
// SPDX-License-Identifier: MIT
//
// Minimal target-side RTT control block for the Chimera H8/300 core.
//
// This is NOT built by the host crate; it is a reference a Chimera firmware
// compiles with h8300-elf-gcc. The host tool (jtag2gdb rtt) scans RAM for the
// magic, parses this block, drains the up buffer, and fills the down buffer via
// DM memRead/memWrite. No RTL support is needed: the DM's auto-halt memory
// access services the host's accesses transparently while this program runs.
//
// The layout is the SEGGER RTT layout narrowed to 16-bit pointers/counters
// (base H8/300 is a 64 KiB address space). All multi-byte fields are the H8's
// native big-endian, which is what the host parser expects.

#include <stdint.h>

#define RTT_UP_BUFFERS   1
#define RTT_DOWN_BUFFERS 1
#define RTT_UP_SIZE      64
#define RTT_DOWN_SIZE    16

typedef struct {
    const char *sName;   // channel name, NUL-terminated
    uint8_t    *pBuffer; // ring storage
    uint16_t    SizeOfBuffer;
    uint16_t    WrOff;   // producer index
    uint16_t    RdOff;   // consumer index
    uint16_t    Flags;   // 0 = skip when full (no blocking)
} rtt_ring_t;

typedef struct {
    char       acId[16]; // magic
    uint16_t   MaxNumUpBuffers;
    uint16_t   MaxNumDownBuffers;
    rtt_ring_t up[RTT_UP_BUFFERS];
    rtt_ring_t down[RTT_DOWN_BUFFERS];
} rtt_cb_t;

static uint8_t up0_storage[RTT_UP_SIZE];
static uint8_t down0_storage[RTT_DOWN_SIZE];

// Placed in RAM; the linker keeps it word-aligned so the host's 2-step scan
// finds it. Zero the magic first and write it LAST so a scanning host never
// latches a half-initialised block.
volatile rtt_cb_t _rtt_cb;

void rtt_init(void)
{
    _rtt_cb.MaxNumUpBuffers   = RTT_UP_BUFFERS;
    _rtt_cb.MaxNumDownBuffers = RTT_DOWN_BUFFERS;

    _rtt_cb.up[0].sName        = "Terminal";
    _rtt_cb.up[0].pBuffer      = up0_storage;
    _rtt_cb.up[0].SizeOfBuffer = RTT_UP_SIZE;
    _rtt_cb.up[0].WrOff        = 0;
    _rtt_cb.up[0].RdOff        = 0;
    _rtt_cb.up[0].Flags        = 0;

    _rtt_cb.down[0].sName        = "Terminal";
    _rtt_cb.down[0].pBuffer      = down0_storage;
    _rtt_cb.down[0].SizeOfBuffer = RTT_DOWN_SIZE;
    _rtt_cb.down[0].WrOff        = 0;
    _rtt_cb.down[0].RdOff        = 0;
    _rtt_cb.down[0].Flags        = 0;

    // Magic written last.
    static const char magic[16] = "SEGGER RTT\0\0\0\0\0";
    for (int i = 0; i < 16; i++)
        _rtt_cb.acId[i] = magic[i];
}

// Enqueue one byte onto up channel 0. The host consumes it (advances RdOff).
// Drops the byte if the ring is full (Flags==0, non-blocking).
void rtt_putc(uint8_t c)
{
    uint16_t wr = _rtt_cb.up[0].WrOff;
    uint16_t next = (uint16_t)((wr + 1) % RTT_UP_SIZE);
    if (next == _rtt_cb.up[0].RdOff)
        return; // full: skip
    up0_storage[wr] = c;
    _rtt_cb.up[0].WrOff = next;
}

// Dequeue one byte from down channel 0 if the host queued any. Returns -1 when
// empty.
int rtt_getc(void)
{
    uint16_t rd = _rtt_cb.down[0].RdOff;
    if (rd == _rtt_cb.down[0].WrOff)
        return -1; // empty
    uint8_t c = down0_storage[rd];
    _rtt_cb.down[0].RdOff = (uint16_t)((rd + 1) % RTT_DOWN_SIZE);
    return c;
}
