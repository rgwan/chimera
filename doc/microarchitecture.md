# Chimera Microarchitecture

Hybrid-microcode, multi-cycle H8/300 core. Hardware coarse pre-decode produces
a microcode-ROM dispatch address; microcode does fine decode and execution.
FPGA-first, minimal area. H8/300H is disabled by default; the area budget is
measured with it off.

![Datapath](diagrams/datapath.drawio.svg)

## Coarse pre-decode

Operates on the 16-bit fetch word with the first opcode byte in `word[7:0]`
(`d ooo pppp`, `d=word[7]`) and the second byte in `word[15:8]`
(`m xxx xxxx`, `m=word[15]`). Three-way map to an 8-bit dispatch address:

| Bucket | Condition | Address |
|---|---|---|
| A | `d=1` | `{0x80 \| ooo}` — 0x80–0x87, immediate ALU |
| B | `d=0`, `ooo ∈ {1,6,7}` (plus `0` when H8/300H) | `{2'b11, word[5:0]}` — 0xC0–0xFF |
| C | otherwise | `{1'b0, word[7:0]}` — 0x00–0x7F |

`word[7]` in bucket B is an address bit, not a gate. 192 dispatch targets
(compressible to 160–184). Coarse LUT < 10 LUT4/5. Second-level dispatch
(`word[7:4]`/`word[7]` sub-slots, `ext[15:8]` for bit-prefixes) is done in
microcode via the next-µPC jump table.

## Microsequencer

- `µPC` (9-bit) indexes the microcode ROM (512 × 36, 2 × M9K).
- next-µPC sources: `seq+1`, `literal` (absolute micro-branch to the microword
  literal field, gated by `cond`), coarse `dispatch` / `jump-table` (second-level,
  folds `word[7:4]`/`ext[15:8]` in one step), `return`.
- One-level call/return stack. Enables the memory-bit prefix family as a called
  subroutine.

## Microword (36 bit = 4 × 9)

| Bits | Field | Encoding |
|---|---|---|
| 35:27 | literal | absolute next-µPC target / immediate constant |
| 26:25 | seq_src | seq+1 / literal / dispatch·jump-table / return |
| 24:22 | cond | micro-branch predicate (none, Z, C, bus-rdy, cc-from-instr, irq) |
| 21:18 | alu_op | add sub adc sbc and or xor not pass cmp shl1 shr1 rol ror rolc rorc |
| 17:15 | a_sel | ALU A source |
| 14:12 | b_sel | ALU B source |
| 11:10 | rd_grp | destination group (H8 / internal, rd / rs2) |
| 9 | reg_we | register write enable |
| 8:6 | flag_ctl | flag update group |
| 5:3 | bus_ctl | none / fetch / read / write / rmw |
| 2:0 | misc | PC step (+2 / +4 / load), operand size (B/W), call/ret |

## Operands

RISC-like `rd / rs1 / rs2`. Fields extracted from `instr[4:0]`, `instr[7:4]`,
`instr[11:8]` by hardwired muxes (not ROM). `rs1` selects microsequencer-internal
registers only. `rd`/`rs2` select H8 or internal registers, distinguished by one
bit. The instruction word is a readable internal register.

## Register files

Two separate 1R1W files: the H8 file (`R0–R7`, 8 × 16, byte-addressable as
`RnH`/`RnL`) and the microsequencer internal file (`PC`, `IREG`, `TEMP`). They are
split because a 2R1W file equals 2 × 1R1W in FPGA area and microcode never
dual-reads the H8 file; one operand is read from each file in parallel. Two
H8-source ops read the H8 file over two cycles (+1 step).

## Fetch and memory access

Fully microcode-driven. The bus master presents a microcode-selected address —
`PC` (in the internal file) for fetch, or a computed address in an internal
register for data — and does not distinguish instruction from data. Microcode
increments `PC` (`+2`/`+4`) or loads it through the ALU; there is no hardware
next-PC path.

## Execution

- ALU: add, sub, logic, compare, and 1-bit shift/rotate through C. No barrel
  shifter. Left shift = `r + r`; right shift and rotate-through-carry use the
  shift path.
- No hardware multiply/divide. MULXU (8 iterations) and DIVXU (16 iterations,
  restoring) are microcode loops.
- Flags: V and C in hardware; N, Z, H in microcode. CCR order `H N Z V C`.

## Interrupts

`irq`/`nmi` are latched into a status bit exposed as one µbranch predicate
(alongside Z/C). The microcode main loop issues a conditional micro-call at
instruction-retire boundaries (`if(irq) call irq_proc`); when taken (and, for
`irq`, allowed by `CCR.I`), `irq_proc` performs the H8 exception sequence — push
PC, push CCR, set `I`, load the vector. The only interrupt hardware is the latch;
priority and context save are microcode, and `irq` reaches µPC only through that
conditional call, never as an async hardware steer. Per-instruction retire
equivalence is therefore unaffected.

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
One outstanding request. Big-endian, 16-bit data. An optional AXI4-Lite wrapper
(32-bit width-convert, one outstanding SRAM request) is available for ASIC use;
the core never speaks AXI.

## Module decomposition (zaozi)

| Module | Role |
|---|---|
| `Biu` | µcode-driven bus master, fetch + data |
| `SramBus` | `addr/di/do/we/wmask/req/rdy` bundle |
| `AxiLiteWrapper` | optional 32-bit AXI4-Lite front |
| `CoarseDecoder` | 3-way pre-decode → 8-bit dispatch |
| `Microsequencer` | µPC, next-µPC mux, call/return stack |
| `MicrocodeRom` | 512 × 36 |
| `MicroDecode` | µword field decode |
| `OperandExtract` | hardwired field muxes |
| `H8RegFile` | R0–R7, 1R1W |
| `IntRegFile` | PC / IREG / TEMP, 1R1W |
| `Alu` | add/sub/logic, 1-bit shift |
| `FlagUnit` | V/C hardware |
| `Ccr` | CCR register |
| `Core` | top |

## Verification obligations

At instruction-retire granularity:

1. Decoder ≡ ISA table — the pre-decode mapping equals `isa/*.yaml` `mask`/`match`,
   exhaustive over 256 first bytes and relevant second-byte bits.
2. Microcode execution ≡ Sail — retire trace by canonical `instruction_id`, `pc`,
   register writes, and `ccr_hnzvc`, against the `isa/*.yaml` cases and
   flag-boundary set.

## Configuration

H8/300H disabled by default (`H8_300H_ENABLE = 0`); the area target is measured in
this configuration.
