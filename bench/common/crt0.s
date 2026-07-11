; SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
; SPDX-License-Identifier: MIT
; Reset lands at address 0: set SP, run main, report, park in sleep.
	.section .init,"ax",@progbits
	.global	_start
_start:
	mov.w	#__stack_top, r7
	jsr	@_main
	mov.w	r0, @0xff88:16
.Lpark:
	sleep
	bra	.Lpark
