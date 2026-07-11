/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */
/* One 64KB RAM; the top 128 bytes are the bench MMIO page. */
OUTPUT_ARCH(h8300)
ENTRY(_start)

MEMORY { ram (rwx) : ORIGIN = 0x0000, LENGTH = 0xff80 }

SECTIONS {
  .text : { KEEP(*(.init)) *(.text*) } > ram
  .rodata : { *(.rodata*) } > ram
  .data : { *(.data*) } > ram
  .bss : { *(.bss*) *(COMMON) } > ram
  /* H8 C symbols carry a leading underscore, hence the triple form. */
  ___heap_start = ALIGN(2);
  __stack_top = 0xff80;
}
