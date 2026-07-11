/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */
/* Freestanding stand-in; the bench build redirects printf/scanf. */
#ifndef BENCH_STDIO_H
#define BENCH_STDIO_H
int bench_printf(const char *fmt, ...);
int bench_scanf(const char *fmt, int *out);
#endif
