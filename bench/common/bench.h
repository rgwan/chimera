/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */
/* Bench MMIO page, snooped by test/bench/tb_core_bench.v. */
#ifndef BENCH_H
#define BENCH_H

#define BENCH_PUTC   (*(volatile unsigned char *)0xff80)
#define BENCH_TSTART (*(volatile unsigned int *)0xff84)
#define BENCH_TSTOP  (*(volatile unsigned int *)0xff86)
#define BENCH_EXIT   (*(volatile unsigned int *)0xff88)

#endif
