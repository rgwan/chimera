# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke sail-model verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

sail-model:
	python3 scripts/check_sail_model.py

verify-smoke: smoke sail-model

check:
	nix flake check

clean:
	rm -rf result
