# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke gnu-oracle gdb-oracle isa-cases sail-coverage sail-model verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

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
