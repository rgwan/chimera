# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke rtl-verilog check-decode-table check-decode check-biu gnu-oracle gdb-oracle gcc-footprint isa-cases sail-coverage sail-model verify-smoke check clean

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

check-word-reg:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_word_reg test/core/tb_core_word_reg.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_word_reg

check-stack:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_stack test/core/tb_core_stack.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_stack

check-jsr:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_jsr test/core/tb_core_jsr.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_jsr

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
