# Chimera Microarchitecture

Hybrid-microcode, multi-cycle H8/300 core. Hardware coarse pre-decode produces
a microcode-ROM dispatch address; microcode does fine decode and execution.
FPGA-first, minimal area. Two configurations: `lean` (default) omits the
illegal-encoding guards, `strict` keeps them. H8/300H is disabled by default;
the area budget is measured with it off.

![Core](diagrams/chimera-core.drawio.svg)

## Coarse pre-decode

External memory and Sail use the ISA word: first opcode byte in `[15:8]`,
second byte in `[7:0]`. Coarse pre-decode consumes the BIU byte-swapped IR:
first byte in `word[7:0]` (`d ooo pppp`, `d=word[7]`) and second byte in
`word[15:8]` (`m xxx xxxx`, `m=word[15]`). Three-way map:

| Bucket | Condition | Address |
|---|---|---|
| A | `d=1` | `{0x80 \| ooo}` (0x80..0x87, immediate ALU) |
| B | `d=0`, `ooo ∈ {1,6,7}` (plus `0` when H8/300H) | `{2'b11, word[5:0]}` (0xC0..0xFF) |
| C | otherwise | `{1'b0, word[7:0]}` (0x00..0x7F) |

`word[7]` in bucket B is an address bit, not a gate. 192 dispatch targets
(compressible to 160–184). Coarse LUT < 10 LUT4/5. Second-level dispatch
(`word[7:4]`/`word[7]` sub-slots, `ext[15:8]` for bit-prefixes) is done in
microcode via the next-µPC jump table.

## Microsequencer

- `µPC` (9-bit) indexes the microcode ROM (512 × 36, 2 × M9K).
- next-µPC sources: `seq+1`, `literal` (absolute micro-branch gated by `cond`),
  coarse `dispatch` (second-level jump-table), `return` (two-word retire).
- `seq_aux` qualifies the source: `next`+aux loads the 4-bit loop counter from
  `literal[3:0]`, `dispatch`+aux arms a trap, `return`+aux requests retire.
- At retire a fixed-priority selector picks the next entry:
  debug > NMI > trap > IRQ > fetch.

## Microword (36 bit = 4 × 9)

| Bits | Field | Encoding |
|---|---|---|
| 35:27 | literal | absolute next-µPC target / immediate constant |
| 26:25 | seq_src | seq+1 / literal / dispatch / return |
| 24:22 | cond | none, Z, alu-ge, int-bit, cc-from-instr, loop-nz, word-guard, nibble-guard |
| 21:18 | alu_op | add sub adc sbc and or xor pass shar shr1 rol ror rorc pass-a |
| 17:16 | a_sel | H8 / internal / zero / special (BIU read or CCR) |
| 15:14 | b_sel | H8 / imm8 / internal / literal |
| 13:12 | h8_idx | which extracted field indexes the H8 file |
| 11:10 | int_idx | internal file index (PC / IREG / TEMP / AUX) |
| 9 | wsel | writeback target (H8 / internal) |
| 8 | reg_we | register write enable |
| 7:5 | flag_ctl | flag update group |
| 4:3 | bus_ctl | none / fetch / read / write |
| 2 | size | byte / word |
| 1 | seq_aux | loop init / trap arm / retire (by seq_src) |
| 0 | vclear | force V=0; with the pointer index also selects SP |

In the `lean` configuration the two guard predicates are removed and the
word-guard code holds the sleep wait loop (branch while no wake event).

## Operands

RISC-like `rd / rs1 / rs2`. Fields extracted from `instr[4:0]`, `instr[7:4]`,
`instr[11:8]` by hardwired muxes (not ROM). `rs1` selects microsequencer-internal
registers only. `rd`/`rs2` select H8 or internal registers, distinguished by one
bit. The instruction word is a readable internal register.

## Register files

Two separate 1R1W files: the H8 file (`R0–R7`, 8 × 16, byte-addressable as
`RnH`/`RnL`) and the microsequencer internal file (`PC`, `IREG`, `TEMP`, `AUX`).
They are split because a 2R1W file equals 2 × 1R1W in FPGA area and microcode
never dual-reads the H8 file; one operand is read from each file in parallel.
Two H8-source ops read the H8 file over two cycles (+1 step). `AUX` holds the
saved CCR across the divide loop and gives microcode a fourth scratch slot.

## Fetch and memory access

Fully microcode-driven. The bus master does not distinguish instruction from
data: it presents a microcode-selected address, `PC` (in the internal file)
for fetch or a computed address in an internal register for data. Microcode
increments `PC` (`+2`/`+4`) or loads it through the ALU; there is no hardware
next-PC path.

## Execution

- ALU: add, sub, logic, and 1-bit shift/rotate through C. No barrel shifter.
  Left shift = `r + r`; the right shifts and rotates share one path that only
  muxes the injected MSB. Compare = sub without writeback; not = xor `0xff`.
- No hardware multiply/divide. MULXU (8 iterations) and DIVXU (16 iterations,
  restoring) are microcode loops driven by the 4-bit loop counter.
- Flags: V and C in hardware; N, Z, H in microcode. CCR order `H N Z V C`.

## Interrupts, traps, sleep

`irq` and `nmi` latch separately; `irq` pending is gated by `CCR.I`. The retire
selector routes the next entry by fixed priority (debug > NMI > trap > IRQ >
fetch), so exceptions are taken only at retire boundaries and per-instruction
retire equivalence with Sail is unaffected. The shared exception microcode
pushes PC and CCR, sets `I`, and loads the latched vector. TRAPA (`0x57`)
arms a synchronous trap serviced at its own retire; trap #2 routes to the
reserved debug entry ahead of NMI. SLEEP parks in a one-word microcode wait
loop with no bus traffic until any wake source (NMI, unmasked IRQ, debug)
ends it; the stacked PC is the next instruction address.

## Memory-bit prefix family

`0x7C`/`0x7D` = `@Rn` read/RMW; `0x7E`/`0x7F` = `@aa:8` read/RMW. The prefix
loads the memory operand into `IREG` and fetches the second word, whose high byte
`ext[15:8]` is a register-form bit op (`0x60–0x77`) redirected to `IREG`.
Sequence: `load → call bitop_reg(IREG) → if RMW store IREG`. Architecturally one
4-byte instruction: single retire, `PC += 4` once, uninterruptible between the two
words, atomic memory and flags.

## Not implemented

MOVFPE, MOVTPE, EEPMOV. In the default base config they decode as illegal
(matching the `h8_reject_*` cases). Their opcode slots are reserved.

## Bus

Native SRAM-style master: `addr[15:0]`, `di[15:0]`, `do[15:0]`, `we`,
`wmask[1:0]`, `req`, `rdy`. `we == 0` is a read; on a write `wmask` selects bytes.
One outstanding request. Big-endian, 16-bit data. The core never speaks AXI;
a bus wrapper is a planned SoC-side addition.

## Module decomposition (zaozi)

| Module | Role |
|---|---|
| `Biu` | µcode-driven bus master, fetch + data |
| `SramBus` | `addr/di/do/we/wmask/req/rdy` bundle |
| `CoarseDecoder` | 3-way pre-decode → 8-bit dispatch |
| `Microsequencer` | µPC, next-µPC mux, loop counter, retire selector |
| `MicrocodeRom` | 512 × 36, image selected by configuration |
| `MicroDecode` | µword field decode |
| `OperandExtract` | hardwired field muxes |
| `H8RegFile` | R0–R7, 1R1W |
| `IntRegFile` | PC / IREG / TEMP / AUX, 1R1W |
| `Alu` | add/sub/logic, 1-bit shift |
| `BitOperand` | bit-op mask and bit extraction |
| `BranchCond` | 16-condition Bcc evaluator |
| `Ccr` | CCR register |
| `CoreAluControl` | operand muxes |
| `CoreCcrControl` | flag update routing |
| `CoreIrqControl` | pending latches, vector address |
| `CorePredicates` | illegal-encoding guards (`strict` only) |
| `CoreWriteback` | write path, byte lanes |
| `Core` | top |

## Verification obligations

At instruction-retire granularity:

1. Decoder ≡ ISA table: the pre-decode mapping equals `isa/*.yaml` `mask`/`match`,
   exhaustive over 256 first bytes and relevant second-byte bits.
2. Microcode execution ≡ Sail: retire trace by canonical `instruction_id`, `pc`,
   register writes, and `ccr_hnzvc`, against the `isa/*.yaml` cases and
   flag-boundary set.

## Configuration

`ChimeraParameter` selects the build; `rtl/build.sh` reads the matching
environment variables. One line per configuration:

```bash
make rtl-verilog                       # lean (default)
STRICT_DECODE=true make rtl-verilog    # strict
ROM_HEX=true make rtl-verilog          # readmemh microcode ROM
```

| | `lean` (default) | `strict` (`STRICT_DECODE=true`) |
|---|---|---|
| Illegal encodings | undefined behavior | guarded, retire as no-op |
| LUT4 / LUT5 (yosys generic, µROM as BRAM) | 751 / 612 | 802 / 620 |
| Microcode words | 371 / 512 | 393 / 512 |
| Logic depth (LUT5 levels) | 19 | 19 |

`strict` adds the `CorePredicates` guards and their guard microwords; `lean`
reuses the freed cond code for the sleep wake test and drops one cycle from
every guarded routine. Guard checks are identical to the Sail model's reject
cases, so `strict` is the configuration for decoder-equivalence work; `lean`
is the area target. H8/300H stays disabled by default.

`ROM_HEX=true` composes with either configuration: elaboration writes the
microcode image to `urom.memh` and the build swaps in
`rtl/verilog/MicrocodeRomHex.sv`, a drop-in `MicrocodeRom` that loads the
image with `readmemh` so FPGA tools infer block RAM. The default when-chain
ROM stays self-contained for simulation.

## Deferred

- Platform vector table (reset SP/PC in the table, NMI/TRAPA/IRQ slots):
  layout agreed, adoption pending; changes every boot image.
- Debug module and unified TRAPA #2 / hardware-breakpoint behavior: waiting
  on the debug specification. The debug entry, retire priority, and reserved
  microcode region are already in place.
