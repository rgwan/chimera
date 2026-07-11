/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */
/* Freestanding shims for the benchmark programs: console printf over the
 * MMIO byte port, a bump allocator, string helpers, and a time() stand-in
 * that latches the testbench cycle counter on first and second call.
 */
#include <stdarg.h>
#include "bench.h"

#ifndef BENCH_RUNS
#define BENCH_RUNS 100
#endif

void *bench_malloc(unsigned size)
{
  extern char __heap_start;
  static char *brk;
  char *p;
  if (!brk)
    brk = &__heap_start;
  p = brk;
  brk += (size + 1u) & ~1u;
  return p;
}

char *strcpy(char *d, const char *s)
{
  char *r = d;
  while ((*d++ = *s++) != 0)
    ;
  return r;
}

int strcmp(const char *a, const char *b)
{
  while (*a && *a == *b) {
    ++a;
    ++b;
  }
  return (unsigned char)*a - (unsigned char)*b;
}

void *memcpy(void *d, const void *s, __SIZE_TYPE__ n)
{
  char *dp = d;
  const char *sp = s;
  while (n--)
    *dp++ = *sp++;
  return d;
}

static void putstr(const char *s)
{
  while (*s)
    BENCH_PUTC = (unsigned char)*s++;
}

static void putnum(long v, unsigned base)
{
  char buf[12];
  int i = 0;
  unsigned long u = v;
  if (base == 10 && v < 0) {
    BENCH_PUTC = '-';
    u = -v;
  }
  do {
    unsigned d = u % base;
    buf[i++] = d < 10 ? '0' + d : 'a' + d - 10;
    u /= base;
  } while (u);
  while (i)
    BENCH_PUTC = buf[--i];
}

int bench_printf(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  for (; *fmt; ++fmt) {
    if (*fmt != '%') {
      BENCH_PUTC = (unsigned char)*fmt;
      continue;
    }
    ++fmt;
    switch (*fmt) {
    case 'd': putnum(va_arg(ap, int), 10); break;
    case 'l': putnum(va_arg(ap, long), 10); ++fmt; break;  /* %ld */
    case 'x': putnum(va_arg(ap, int), 16); break;
    case 'c': BENCH_PUTC = (unsigned char)va_arg(ap, int); break;
    case 's': putstr(va_arg(ap, const char *)); break;
    case '%': BENCH_PUTC = '%'; break;
    default: break;
    }
  }
  va_end(ap);
  return 0;
}

int bench_scanf(const char *fmt, int *out)
{
  (void)fmt;
  *out = BENCH_RUNS;
  return 1;
}

long bench_time(long *t)
{
  static unsigned calls;
  (void)t;
  if (calls++ == 0) {
    BENCH_TSTART = 1;
    return 0;
  }
  BENCH_TSTOP = 1;
  return 1;
}
