# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: bench-dhry bench-coremark check-sleep-strict build smoke rtl-verilog check-decode-table check-decode check-biu check-core-wait check-sleep check-rom-hex check-bit-reg check-bit-mem check-daa-das check-adds-subs check-mulxu check-divxu check-stack-byte check-irq-vector check-trapa gnu-oracle gdb-oracle gcc-footprint isa-cases sail-coverage sail-model verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

rtl-verilog:
	bash rtl/build.sh

check-decode-table:
	python3 scripts/check_decode_dispatch.py --table-only

check-decode:
	TOP=CoarseDecoder bash rtl/build.sh
	COARSE_SV=rtl/generated/CoarseDecoder.sv python3 scripts/check_decode_dispatch.py

check-alu:
	TOP=Alu bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/tb_alu test/alu/tb_alu.v rtl/generated/Alu.sv
	vvp rtl/generated/tb_alu

check-biu:
	TOP=Biu bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/tb_biu test/biu/tb_biu.v rtl/generated/Biu.sv
	vvp rtl/generated/tb_biu

check-core:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_core test/core/tb_core.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_core

check-core-wait:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_core_wait test/core/tb_core_wait.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_core_wait

check-sleep:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_sleep test/core/tb_core_sleep.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_sleep

check-sleep-strict:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_sleep_strict test/core/tb_core_sleep.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_sleep_strict

check-rom-hex:
	ROM_HEX=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_rom_hex test/core/tb_core_sleep.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	cd rtl/generated && vvp sim_rom_hex

check-trapa:
	RESET_VECTOR=256 STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_trapa test/core/tb_core_trapa.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_trapa

check-add:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_add test/core/tb_core_add.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_add

check-byte:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_byte test/core/tb_core_byte.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_byte

check-flags:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_flags test/core/tb_core_flags.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_flags

check-ccr:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_ccr test/core/tb_core_ccr.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_ccr

check-imm:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_imm test/core/tb_core_imm.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_imm

check-branch:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_branch test/core/tb_core_branch.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_branch

check-branch-odd:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_branch_odd test/core/tb_core_branch_odd.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_branch_odd

check-bcc:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_bcc test/core/tb_core_bcc.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_bcc

check-loop:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_loop test/core/tb_core_loop.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_loop

check-sub:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_sub test/core/tb_core_sub.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_sub

check-irq:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_irq test/core/tb_core_irq.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_irq

check-irq-entry:
	RESET_VECTOR=256 CHIMERA_RTL_OUT=$$PWD/rtl/generated_irq_entry bash rtl/build.sh
	iverilog -g2012 -o rtl/generated_irq_entry/sim_irq_entry test/core/tb_core_irq_entry.v \
	  $$(ls rtl/generated_irq_entry/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated_irq_entry/sim_irq_entry

check-irq-vector:
	RESET_VECTOR=256 CHIMERA_RTL_OUT=$$PWD/rtl/generated_irq_vector bash rtl/build.sh
	iverilog -g2012 -o rtl/generated_irq_vector/sim_irq_vector test/core/tb_core_irq_vector.v \
	  $$(ls rtl/generated_irq_vector/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated_irq_vector/sim_irq_vector

check-movw:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_movw test/core/tb_core_movw.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_movw

check-mem:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_mem test/core/tb_core_mem.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_mem

check-mem-byte:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_mem_byte test/core/tb_core_mem_byte.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_mem_byte

check-mem-disp:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_mem_disp test/core/tb_core_mem_disp.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_mem_disp

check-mem-abs:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_mem_abs test/core/tb_core_mem_abs.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_mem_abs

check-word-reg:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_word_reg test/core/tb_core_word_reg.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_word_reg

check-adds-subs:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_adds_subs test/core/tb_core_adds_subs.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_adds_subs

check-bit-reg:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_bit_reg test/core/tb_core_bit_reg.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_bit_reg

check-bit-mem:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_bit_mem test/core/tb_core_bit_mem.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_bit_mem

check-daa-das:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_daa_das test/core/tb_core_daa_das.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_daa_das

check-mulxu:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_mulxu test/core/tb_core_mulxu.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_mulxu

check-divxu:
	STRICT_DECODE=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_divxu test/core/tb_core_divxu.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_divxu

check-stack:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_stack test/core/tb_core_stack.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_stack

check-stack-byte:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_stack_byte test/core/tb_core_stack_byte.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_stack_byte

check-jsr:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_jsr test/core/tb_core_jsr.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_jsr

check-jmp-abs:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_jmp_abs test/core/tb_core_jmp_abs.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_jmp_abs

check-rte:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_rte test/core/tb_core_rte.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_rte

check-exec-sail:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_isa test/isa/tb_isa_case.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	SIM_BIN=rtl/generated/sim_isa python3 scripts/check_exec_sail.py

gnu-oracle:
	python3 scripts/check_gnu_oracle.py

gdb-oracle:
	python3 scripts/check_gdb_oracle.py

gcc-footprint:
	python3 scripts/check_gcc_footprint.py

isa-cases:
	python3 scripts/check_isa_cases.py

sail-coverage:
	python3 scripts/check_sail_coverage.py

sail-model:
	python3 scripts/check_sail_model.py

verify-smoke: smoke isa-cases sail-coverage check-decode-table gnu-oracle gdb-oracle gcc-footprint sail-model

check:
	nix flake check

clean:
	rm -rf result

BENCH_RUNS ?= 200
BENCH_CC ?= h8300-elf-gcc
bench-dhry:
	bash rtl/build.sh
	@test -n "$$BENCH_CC" || { echo "BENCH_CC not set (enter nix develop)"; exit 1; }
	$(BENCH_CC) -Os -ffreestanding -fno-builtin -fomit-frame-pointer \
	  -nostartfiles -nostdlib -Ibench/common -Ibench/common/include \
	  -DBENCH_RUNS=$(BENCH_RUNS) -DTIME=1 -DHZ=1 \
	  -Dprintf=bench_printf -Dscanf=bench_scanf \
	  -Dmalloc=bench_malloc -Dtime=bench_time \
	  -Wl,-T,bench/common/link.ld -o rtl/generated/dhry.elf \
	  bench/common/crt0.s bench/common/runtime.c \
	  bench/dhrystone/upstream/dhry_1.c bench/dhrystone/upstream/dhry_2.c \
	  -lgcc
	$(BENCH_OBJCOPY) -O verilog rtl/generated/dhry.elf rtl/generated/dhry.hex
	python3 scripts/check_bench_dhry.py --audit rtl/generated/dhry.elf
	iverilog -g2012 -o rtl/generated/sim_bench test/bench/tb_core_bench.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_bench +hex=rtl/generated/dhry.hex \
	  +max_cycles=50000000 | tee rtl/generated/dhry.log
	python3 scripts/check_bench_dhry.py --score rtl/generated/dhry.log --runs $(BENCH_RUNS)

COREMARK_ITER ?= 1
bench-coremark:
	bash rtl/build.sh
	@test -n "$$COREMARK_SRC" || { echo "COREMARK_SRC not set (enter nix develop)"; exit 1; }
	$(BENCH_CC) -Os -ffreestanding -fno-builtin -fomit-frame-pointer \
	  -nostartfiles -nostdlib -Ibench/common -Ibench/common/include \
	  -Ibench/coremark/port -I$$COREMARK_SRC \
	  -DITERATIONS=$(COREMARK_ITER) \
	  -Wl,-T,bench/common/link.ld -o rtl/generated/coremark.elf \
	  bench/common/crt0.s bench/common/runtime.c \
	  bench/coremark/port/core_portme.c \
	  $$COREMARK_SRC/core_main.c $$COREMARK_SRC/core_list_join.c \
	  $$COREMARK_SRC/core_matrix.c $$COREMARK_SRC/core_state.c \
	  $$COREMARK_SRC/core_util.c \
	  -lgcc
	$(BENCH_OBJCOPY) -O verilog rtl/generated/coremark.elf rtl/generated/coremark.hex
	python3 scripts/check_bench_dhry.py --audit rtl/generated/coremark.elf
	iverilog -g2012 -o rtl/generated/sim_bench test/bench/tb_core_bench.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_bench +hex=rtl/generated/coremark.hex \
	  +max_cycles=60000000 | tee rtl/generated/coremark.log
	python3 scripts/check_bench_coremark.py --score rtl/generated/coremark.log \
	  --iterations $(COREMARK_ITER)
