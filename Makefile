# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT

.PHONY: bench-dhry bench-coremark check-sleep-strict check-ccr-ubit build smoke rtl-verilog check-decode-table check-decode check-biu check-core-wait check-sleep check-debug check-jtag check-autohalt check-hwbp-selfhosted check-hwbp-dm check-step-selfhosted check-step-dm check-trap2-suppress check-nondestruct check-jtag2gdb check-gdb-e2e verify-debug check-formal-debug check-formal-core check-formal-decode verify-formal check-rom-hex check-bit-reg check-bit-mem check-daa-das check-adds-subs check-mulxu check-divxu check-stack-byte check-irq-vector check-trapa gnu-oracle gdb-oracle gcc-footprint isa-cases sail-coverage sail-model check-axilite check-cocotb-jtag check-cocotb-axi verify-cocotb verify-smoke check clean

build: smoke

smoke:
	build-chimera --smoke

rtl-verilog:
	bash rtl/build.sh

# AXI-Lite optional bridge: (1) the default (axilite off) build stays byte-
# identical to a clean build, proving the flag perturbs no leaf module; (2) the
# CoreTopAxi top elaborates and the canonical-name SV wrapper co-elaborates.
check-axilite:
	rm -rf rtl/generated_axil_base
	CHIMERA_RTL_OUT=$(CURDIR)/rtl/generated_axil_base bash rtl/build.sh
	bash rtl/build.sh
	@for f in rtl/generated/*.sv; do \
	  cmp -s "$$f" "rtl/generated_axil_base/$$(basename $$f)" \
	    || { echo "AXILITE NOT BYTE-IDENTICAL: $$(basename $$f)"; exit 1; }; \
	done
	@echo "[check-axilite] default build byte-identical"
	AXIL=true TOP=CoreTopAxi bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_axil -s coretop_axil \
	  test/cocotb/wrappers/coretop_axil.sv \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	@echo "[check-axilite] CoreTopAxi + wrapper elaborate"

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

check-debug:
	python3 test/cocotb/debug/run_dm.py debug

# The standalone JTAG DTM path is verified in cocotb (check-cocotb-jtag), which
# drives the same TAP pins in-process; this alias keeps the old target name and
# the debug aggregate pointing at it.
check-jtag: check-cocotb-jtag

check-hwbp-selfhosted:
	HW_BREAKPOINT=true HW_BREAKPOINT_COUNT=2 DBG_BASE=65280 bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_hwbp_self test/core/tb_core_hwbp_selfhosted.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_hwbp_self

check-hwbp-dm:
	python3 test/cocotb/debug/run_dm.py hwbp

check-step-selfhosted:
	SINGLE_STEP=true DBG_BASE=65280 bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_step_self test/core/tb_core_step_selfhosted.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_step_self

check-step-dm:
	python3 test/cocotb/debug/run_dm.py step

check-trap2-suppress:
	SINGLE_STEP=true HW_BREAKPOINT=true HW_BREAKPOINT_COUNT=2 DBG_BASE=65280 bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_trap2_suppress test/core/tb_core_trap2_suppress.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_trap2_suppress

check-nondestruct:
	TOP=Core DM=true SINGLE_STEP=true DBG_BASE=65280 bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_nondestruct test/core/tb_core_nondestruct.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_nondestruct

check-autohalt:
	DM=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_autohalt test/core/tb_core_autohalt.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_autohalt

check-jtag2gdb:
	cd tools/jtag2gdb && cargo test

# End-to-end gdb-transport bring-up: build the DM+HWBP RTL, the remote-bitbang
# VPI, and the rbb sim, then attach the pure-Rust jtag2gdb example over TCP.
# GDB_E2E_EXAMPLE selects the example (sim_bp = software-breakpoint hit).
# gdb-in-the-loop (real h8300-elf-gdb via the RSP server) is a manual bring-up
# step, not this gate; see scripts/run_gdb_e2e.sh.
GDB_E2E_EXAMPLE ?= sim_bp
GDB_E2E_PORT ?= 2542
check-gdb-e2e:
	python3 test/cocotb/rbb/run_rbb.py build
	bash scripts/run_gdb_e2e.sh $(GDB_E2E_EXAMPLE) $(GDB_E2E_PORT)

# Debug-subsystem aggregate over every debug gate (RTL + tool + e2e).
DEBUG_CHECKS ?= check-jtag check-debug check-autohalt check-hwbp-selfhosted \
  check-hwbp-dm check-step-selfhosted check-step-dm check-trap2-suppress \
  check-nondestruct check-jtag2gdb check-gdb-e2e
verify-debug: $(DEBUG_CHECKS)

# CIRCT-native bounded model checking (circt-bmc). check-formal-debug proves the
# JtagDtm go-strobe launch gate holds AND that its deliberately-broken variant is
# caught, so the harness is demonstrably non-vacuous. FORMAL_BMC_BOUND sets the
# unroll depth.
FORMAL_BMC_BOUND ?= 20
check-formal-debug:
	FORMAL_BROKEN=false bash formal/lower.sh JtagDtm
	bash formal/run_bmc.sh JtagDtm $(FORMAL_BMC_BOUND)
	FORMAL_BROKEN=true bash formal/lower.sh JtagDtm
	@echo "[formal] broken variant must be violated:"
	@if bash formal/run_bmc.sh JtagDtm $(FORMAL_BMC_BOUND); then \
	  echo "[formal] ERROR: broken property was not caught"; exit 1; \
	else \
	  echo "[formal] broken property correctly reported as violable"; \
	fi

verify-formal: check-formal-debug check-formal-core check-formal-decode

# check-formal-core proves the debug-FSM transition invariants on module Core
# (auto-halt/resume soundness, trap-2 single-entry, dmactive gating) AND that
# their deliberately-broken variant is caught. HW_BREAKPOINT=true enables the
# MMIO trigger unit so the trap-2 suppression FSM exists; DM=true brings the
# auto-halt FSM. The invariants are single-cycle, so a small bound suffices.
#
# circt-bmc verifies one self-contained module: lower.sh leaves Core's children
# as hw.module.extern, which the tool cannot see through (black-box ports merge
# into a false comb cycle). FLATTEN_CORE lowers every child mlirbc to hw dialect,
# splices all real hw.module bodies into one file (Microsequencer's registered
# upc cuts the datapath loop, so no true cycle remains), folds the four DV-probe
# hw.wire taps that circt-bmc rejects, and lowers array ops to comb. The result
# is a single sound module circt-bmc flattens; children stay real logic so no
# signal is over-approximated.
FORMAL_CORE_BOUND ?= 3
define FLATTEN_CORE
	out=formal/gen; rm -f $$out/*_hwmod.mlir; \
	for f in $$out/*.mlirbc; do b=$$(basename $$f .mlirbc); \
	  case $$b in Core|CoreTop) continue;; esac; \
	  firtool $$f --ir-hw -o $$out/$${b}_hwmod.mlir; done; \
	awkx='/^  hw\.module\.extern / { next } /^  hw\.module @/ { inmod=1; depth=0 } inmod { n=gsub(/{/,"{"); depth+=n; m=gsub(/}/,"}"); depth-=m; print; if (depth<=0) inmod=0; next }'; \
	{ echo "module {"; for f in $$out/*_hwmod.mlir; do awk "$$awkx" $$f; done; \
	  awk "$$awkx" $$out/Core_hw.mlir; echo "}"; } > $$out/Core_flat_raw.mlir; \
	perl -e 'my %m; my @l; while(<STDIN>){ if(/^\s*(\%\S+)\s*=\s*hw\.wire\s+(\%\S+)/){$$m{$$1}=$$2; next;} push @l,$$_; } for my $$k (keys %m){ my $$v=$$m{$$k}; $$v=$$m{$$v} while exists $$m{$$v}; $$m{$$k}=$$v; } for my $$x (@l){ for my $$k (keys %m){ my $$q=quotemeta($$k); $$x =~ s/$$q(?![A-Za-z0-9_.])/$$m{$$k}/g; } print $$x; }' \
	  < $$out/Core_flat_raw.mlir > $$out/Core_flat_nowire.mlir; \
	circt-opt --hw-aggregate-to-comb $$out/Core_flat_nowire.mlir -o $$out/Core_flat_bmc.mlir
endef
check-formal-core:
	DM=true HW_BREAKPOINT=true FORMAL_BROKEN=false bash formal/lower.sh Core
	@$(FLATTEN_CORE)
	bash formal/run_bmc.sh Core $(FORMAL_CORE_BOUND) formal/gen/Core_flat_bmc.mlir
	DM=true HW_BREAKPOINT=true FORMAL_BROKEN=true bash formal/lower.sh Core
	@$(FLATTEN_CORE)
	@echo "[formal] broken variant must be violated:"
	@if bash formal/run_bmc.sh Core $(FORMAL_CORE_BOUND) formal/gen/Core_flat_bmc.mlir; then \
	  echo "[formal] ERROR: broken property was not caught"; exit 1; \
	else \
	  echo "[formal] broken property correctly reported as violable"; \
	fi

# CoarseDecoder is pure combinational over the 16-bit opcode word, so a bound of
# 1 makes circt-bmc quantify over the whole 64K space. check-formal-decode proves
# the dispatch output always tags one of three pairwise-disjoint buckets (decode
# is total and unambiguous) AND that its broken variant is caught.
check-formal-decode:
	TOP=CoarseDecoder DM=false DTM=false FORMAL_BROKEN=false \
	  bash formal/lower.sh CoarseDecoder
	bash formal/run_bmc.sh CoarseDecoder 1
	TOP=CoarseDecoder DM=false DTM=false FORMAL_BROKEN=true \
	  bash formal/lower.sh CoarseDecoder
	@echo "[formal] broken variant must be violated:"
	@if bash formal/run_bmc.sh CoarseDecoder 1; then \
	  echo "[formal] ERROR: broken property was not caught"; exit 1; \
	else \
	  echo "[formal] broken property correctly reported as violable"; \
	fi

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
	STRICT_DECODE=true bash rtl/build.sh
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

check-ccr-ubit:
	CCR_UBIT=true bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_ccr_ubit test/core/tb_core_ccr_ubit.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_ccr_ubit

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
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_irq_entry test/core/tb_core_irq_entry.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_irq_entry

check-irq-vector:
	bash rtl/build.sh
	iverilog -g2012 -o rtl/generated/sim_irq_vector test/core/tb_core_irq_vector.v \
	  $$(ls rtl/generated/*.sv | grep -vE 'layers-|ref_')
	vvp rtl/generated/sim_irq_vector

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

# cocotb + Verilator JTAG harness (cocotb 2.0 runner API). Builds CoreTop with
# DM=true, then drives the DTM over JTAG with the vendored cocotbext.jtag TAP
# driver: IDCODE smoke plus the full sequence (halt, status, memWrite/memRead,
# setPC/readPC, resume) against a Python RAM slave on the core bus. Run inside
# `nix develop .#cocotb` (PYTHONPATH has test/cocotbext).
check-cocotb-jtag:
	PYTHONPATH=$(CURDIR)/test:$$PYTHONPATH \
	  python3 test/cocotb/jtag/run_idcode.py

# cocotb + Verilator AXI-Lite harness. Builds CoreTopAxi (AXIL=true), boots the
# real core over the vendored cocotbext-axi AxiLiteRam slave, and checks the
# write/read/WSTRB/lane placement and byte order of the SramToAxiLite bridge.
# Run inside `nix develop .#cocotb` (PYTHONPATH has test/cocotbext).
check-cocotb-axi:
	PYTHONPATH=$(CURDIR)/test:$$PYTHONPATH \
	  python3 test/cocotb/axi/run_axil.py

# Cocotb + Verilator gates (run inside `nix develop .#cocotb`).
verify-cocotb: check-cocotb-jtag check-cocotb-axi

clean:
	rm -rf result

BENCH_RUNS ?= 200
BENCH_CC ?= h8300-elf-gcc
bench-dhry:
	bash rtl/build.sh
	@test -n "$$BENCH_CC" || { echo "BENCH_CC not set (enter nix develop)"; exit 1; }
	$(BENCH_CC) -Ofast -ffreestanding -fno-builtin -fomit-frame-pointer \
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
	$(BENCH_CC) -Ofast -ffreestanding -fno-builtin -fomit-frame-pointer \
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
