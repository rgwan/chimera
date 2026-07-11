/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */
/* CoreMark port for the Chimera bench flow: 16-bit int, no float, no OS. */
#ifndef CORE_PORTME_H
#define CORE_PORTME_H

#define HAS_FLOAT       0
#define HAS_TIME_H      0
#define USE_CLOCK       0
#define HAS_STDIO       0
#define HAS_PRINTF      0

#define MAIN_HAS_NOARGC 1
#define SEED_METHOD     SEED_VOLATILE
#define MEM_METHOD      MEM_STATIC
#define MEM_LOCATION    "STATIC"
#define PERFORMANCE_RUN 1

#define MULTITHREAD 1
#define USE_PTHREAD 0
#define USE_FORK    0
#define USE_SOCKET  0

#ifndef ITERATIONS
#define ITERATIONS 1
#endif

#define COMPILER_VERSION "GCC" __VERSION__
#define COMPILER_FLAGS   "-Os"

typedef signed short   ee_s16;
typedef unsigned short ee_u16;
typedef signed long    ee_s32;
typedef unsigned long  ee_u32;
typedef unsigned char  ee_u8;
typedef unsigned int   ee_ptr_int;
typedef unsigned int   ee_size_t;
#define NULL ((void *)0)

#define align_mem(x) (void *)(4 + (((ee_ptr_int)(x)-1) & ~3))

#define CORETIMETYPE ee_u32
typedef ee_u32 CORE_TICKS;

extern ee_u32 default_num_contexts;

typedef struct CORE_PORTABLE_S
{
    ee_u8 portable_id;
} core_portable;

void portable_init(core_portable *p, int *argc, char *argv[]);
void portable_fini(core_portable *p);

int bench_printf(const char *fmt, ...);
#define ee_printf bench_printf

#endif /* CORE_PORTME_H */
