# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke isa-cases sail-model verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

isa-cases:
	python3 scripts/check_isa_cases.py

sail-model:
	python3 scripts/check_sail_model.py

verify-smoke: smoke isa-cases sail-model

check:
	nix flake check

clean:
	rm -rf result
