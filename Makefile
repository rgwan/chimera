# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: build smoke verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

verify-smoke: smoke

check:
	nix flake check

clean:
	rm -rf result
