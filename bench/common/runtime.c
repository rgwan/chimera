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

static void putnum(unsigned long u, unsigned base, int width, int zero)
{
  char buf[12];
  int i = 0;
  do {
    unsigned d = u % base;
    buf[i++] = d < 10 ? '0' + d : 'a' + d - 10;
    u /= base;
  } while (u);
  while (i < width && i < (int)sizeof(buf))
    buf[i++] = zero ? '0' : ' ';
  while (i)
    BENCH_PUTC = buf[--i];
}

int bench_printf(const char *fmt, ...)
{
  va_list ap;
  va_start(ap, fmt);
  for (; *fmt; ++fmt) {
    int zero = 0, width = 0, lng = 0;
    long v;
    if (*fmt != '%') {
      BENCH_PUTC = (unsigned char)*fmt;
      continue;
    }
    ++fmt;
    if (*fmt == '0') {
      zero = 1;
      ++fmt;
    }
    while (*fmt >= '0' && *fmt <= '9')
      width = width * 10 + (*fmt++ - '0');
    if (*fmt == 'l') {
      lng = 1;
      ++fmt;
    }
    switch (*fmt) {
    case 'd':
      v = lng ? va_arg(ap, long) : va_arg(ap, int);
      if (v < 0) {
        BENCH_PUTC = '-';
        v = -v;
      }
      putnum(v, 10, width, zero);
      break;
    case 'u':
      putnum(lng ? va_arg(ap, unsigned long) : va_arg(ap, unsigned),
             10, width, zero);
      break;
    case 'x':
      putnum(lng ? va_arg(ap, unsigned long) : va_arg(ap, unsigned),
             16, width, zero);
      break;
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
