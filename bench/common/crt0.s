; SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
; SPDX-FileCopyrightText: 2026 Zhiyuan Wan <hikari@iloli.bid>
; SPDX-License-Identifier: MIT
; CPU loads SP and the entry PC from the vector table, then _start runs
; main, reports, and parks in sleep.
	.section .vectors,"a",@progbits
	.word	0
	.word	__stack_top
	.word	0
	.word	_start

	.section .init,"ax",@progbits
	.global	_start
_start:
	jsr	@_main
	mov.w	r0, @0xff88:16
.Lpark:
	sleep
	bra	.Lpark
