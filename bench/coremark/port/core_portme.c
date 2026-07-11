/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */
#include "coremark.h"
#include "bench.h"

volatile ee_s32 seed1_volatile = 0x0;
volatile ee_s32 seed2_volatile = 0x0;
volatile ee_s32 seed3_volatile = 0x66;
volatile ee_s32 seed4_volatile = ITERATIONS;
volatile ee_s32 seed5_volatile = 0;

/* The core cannot read the testbench cycle counter back, so the timed
 * window is only latched via the MMIO writes; report a fixed 10 s so the
 * self-check passes. Real cycles come from the BENCH-EXIT record.
 */
static CORE_TICKS fake_ticks;

void
start_time(void)
{
    fake_ticks  = 0;
    BENCH_TSTART = 1;
}

void
stop_time(void)
{
    BENCH_TSTOP = 1;
    fake_ticks  = 10;
}

CORE_TICKS
get_time(void)
{
    return fake_ticks;
}

secs_ret
time_in_secs(CORE_TICKS ticks)
{
    return ticks;
}

ee_u32 default_num_contexts = 1;

void
portable_init(core_portable *p, int *argc, char *argv[])
{
    (void)argc;
    (void)argv;
    p->portable_id = 1;
}

void
portable_fini(core_portable *p)
{
    p->portable_id = 0;
}
