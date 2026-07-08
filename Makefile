# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke rtl-verilog check-decode gnu-oracle gdb-oracle isa-cases sail-coverage sail-model verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

rtl-verilog:
	bash rtl/build.sh

check-decode:
	TOP=CoarseDecoder bash rtl/build.sh
	COARSE_SV=rtl/generated/CoarseDecoder.sv python3 scripts/check_decode_dispatch.py

check-alu:
	TOP=Alu bash rtl/build.sh
	iverilog -o rtl/generated/tb_alu test/alu/tb_alu.v rtl/generated/Alu.sv
	vvp rtl/generated/tb_alu

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

gnu-oracle:
	python3 scripts/check_gnu_oracle.py

gdb-oracle:
	python3 scripts/check_gdb_oracle.py

isa-cases:
	python3 scripts/check_isa_cases.py

sail-coverage:
	python3 scripts/check_sail_coverage.py

sail-model:
	python3 scripts/check_sail_model.py

verify-smoke: smoke isa-cases sail-coverage gnu-oracle gdb-oracle sail-model

check:
	nix flake check

clean:
	rm -rf result
