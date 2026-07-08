# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke rtl-verilog check-decode gnu-oracle gdb-oracle isa-cases sail-coverage sail-model verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

rtl-verilog:
	rtl/build.sh

check-decode:
	TOP=CoarseDecoder rtl/build.sh
	COARSE_SV=rtl/generated/CoarseDecoder.sv python3 scripts/check_decode_dispatch.py

check-alu:
	TOP=Alu rtl/build.sh
	iverilog -o rtl/generated/tb_alu test/alu/tb_alu.v rtl/generated/Alu.sv
	vvp rtl/generated/tb_alu

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
