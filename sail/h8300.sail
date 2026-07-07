/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */

type byte = bits(8)
type word = bits(16)
type h8_r8_pair = range(0, 7)
type h8_r16 = range(0, 15)
type H8Memory = vector(65536, byte)

enum H8Width = {H8_BYTE, H8_WORD}
enum H8AluOp = {H8_ADD, H8_SUB, H8_CMP, H8_AND, H8_OR, H8_XOR, H8_NOT}
enum H8BranchCond = {
  H8_BRA, H8_BRN, H8_BHI, H8_BLS,
  H8_BCC, H8_BCS, H8_BNE, H8_BEQ,
  H8_BVC, H8_BVS, H8_BPL, H8_BMI,
  H8_BGE, H8_BLT, H8_BGT, H8_BLE
}

struct H8CCR = {
  i : bit,
  u6 : bit,
  h : bit,
  u4 : bit,
  n : bit,
  z : bit,
  v : bit,
  c : bit
}

struct H8R8 = {
  reg : h8_r8_pair,
  high : bool
}

struct H8State = {
  pc : word,
  r : vector(16, word),
  ccr : H8CCR
}

union H8Inst = {
  H8_NOP : unit,
  H8_BRANCH : (H8BranchCond, byte),
  H8_MOV8_IMM : (H8R8, byte),
  H8_MOV16_IMM : (h8_r16, word),
  H8_ADD8_IMM : (H8R8, byte),
  H8_CMP8_IMM : (H8R8, byte),
  H8_OR8_IMM : (H8R8, byte),
  H8_XOR8_IMM : (H8R8, byte),
  H8_AND8_IMM : (H8R8, byte),
  H8_ADD8_R8_R8 : (H8R8, H8R8),
  H8_MOV8_R8_R8 : (H8R8, H8R8),
  H8_OR8_R8_R8 : (H8R8, H8R8),
  H8_XOR8_R8_R8 : (H8R8, H8R8),
  H8_AND8_R8_R8 : (H8R8, H8R8),
  H8_SUB8_R8_R8 : (H8R8, H8R8),
  H8_CMP8_R8_R8 : (H8R8, H8R8)
}

struct H8ExecResult = {
  st : H8State,
  trap : bool
}

struct H8Machine = {
  st : H8State,
  mem : H8Memory,
  trap : bool
}

function mask16(addr : word) -> word = addr

function align_word_addr(addr : word) -> word =
  addr[15 .. 1] @ 0b0

function h8_empty_mem() -> H8Memory =
  vector_init(0x00)

function h8_mem_read8(mem : H8Memory, addr : word) -> byte =
  mem[unsigned(addr)]

function h8_mem_write8(mem : H8Memory, addr : word, value : byte) -> H8Memory =
  vector_update(mem, unsigned(addr), value)

val h8_load_bytes : forall 'n, 0 < 'n <= 65536. (H8Memory, word, vector('n, byte)) -> H8Memory
function h8_load_bytes(mem, base, bytes) = {
  var out = mem;
  foreach (i from 0 to ('n - 1)) {
    out = h8_mem_write8(out, base + i, bytes[('n - 1) - i])
  };
  out
}

function h8_fetch16(mem : H8Memory, addr : word) -> word =
  h8_mem_read8(mem, addr) @ h8_mem_read8(mem, addr + 0x0001)

function h8_r8_from_code(code : bits(4)) -> H8R8 =
  struct {reg = unsigned(code[2 .. 0]), high = code[3] == 0b0}

function h8_r16_from_code(code : bits(3)) -> h8_r16 =
  unsigned(code)

function h8_r16_from_nibble(code : bits(4)) -> h8_r16 =
  unsigned(code)

function read_r8(st : H8State, idx : H8R8) -> byte =
  if idx.high then st.r[idx.reg][15 .. 8] else st.r[idx.reg][7 .. 0]

function write_r8(st : H8State, idx : H8R8, value : byte) -> H8State = {
  let old : word = st.r[idx.reg];
  let next : word =
    if idx.high then value @ old[7 .. 0] else old[15 .. 8] @ value;
  {st with r = vector_update(st.r, idx.reg, next)}
}

function read_r16(st : H8State, idx : h8_r16) -> word =
  st.r[idx]

function write_r16(st : H8State, idx : h8_r16, value : word) -> H8State =
  {st with r = vector_update(st.r, idx, value)}

function h8_exec_nop(st : H8State) -> H8State =
  {st with pc = st.pc + 0x0002}

function h8_nz_flags(width : H8Width, result : word, ccr : H8CCR) -> H8CCR = {
  match width {
    H8_BYTE => {
      let b : byte = result[7 .. 0];
      {ccr with n = b[7], z = bool_to_bit(b == 0x00), v = 0b0}
    },
    H8_WORD => {
      {ccr with n = result[15], z = bool_to_bit(result == 0x0000), v = 0b0}
    }
  }
}

function h8_logic_flags(width : H8Width, result : word, ccr : H8CCR) -> H8CCR =
  h8_nz_flags(width, result, ccr)

function h8_add_flags(width : H8Width, lhs : word, rhs : word, result : word, ccr : H8CCR) -> H8CCR = {
  match width {
    H8_BYTE => {
      let a : byte = lhs[7 .. 0];
      let b : byte = rhs[7 .. 0];
      let r : byte = result[7 .. 0];
      let h : bit = bool_to_bit(unsigned(a[3 .. 0]) + unsigned(b[3 .. 0]) > 15);
      let c : bit = bool_to_bit(unsigned(a) + unsigned(b) > 255);
      let v : bit = bool_to_bit((a[7] == b[7]) & (r[7] != a[7]));
      {ccr with h = h, n = r[7], z = bool_to_bit(r == 0x00), v = v, c = c}
    },
    H8_WORD => {
      let h : bit = bool_to_bit(unsigned(lhs[11 .. 0]) + unsigned(rhs[11 .. 0]) > 4095);
      let c : bit = bool_to_bit(unsigned(lhs) + unsigned(rhs) > 65535);
      let v : bit = bool_to_bit((lhs[15] == rhs[15]) & (result[15] != lhs[15]));
      {ccr with h = h, n = result[15], z = bool_to_bit(result == 0x0000), v = v, c = c}
    }
  }
}

function h8_sub_flags(width : H8Width, lhs : word, rhs : word, result : word, ccr : H8CCR) -> H8CCR = {
  match width {
    H8_BYTE => {
      let a : byte = lhs[7 .. 0];
      let b : byte = rhs[7 .. 0];
      let r : byte = result[7 .. 0];
      let h : bit = bool_to_bit(unsigned(a[3 .. 0]) < unsigned(b[3 .. 0]));
      let c : bit = bool_to_bit(unsigned(a) < unsigned(b));
      let v : bit = bool_to_bit((a[7] != b[7]) & (r[7] != a[7]));
      {ccr with h = h, n = r[7], z = bool_to_bit(r == 0x00), v = v, c = c}
    },
    H8_WORD => {
      let h : bit = bool_to_bit(unsigned(lhs[11 .. 0]) < unsigned(rhs[11 .. 0]));
      let c : bit = bool_to_bit(unsigned(lhs) < unsigned(rhs));
      let v : bit = bool_to_bit((lhs[15] != rhs[15]) & (result[15] != lhs[15]));
      {ccr with h = h, n = result[15], z = bool_to_bit(result == 0x0000), v = v, c = c}
    }
  }
}

function h8_exec_mov8_imm(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let st1 = write_r8(st, rd, value);
  {st1 with ccr = h8_nz_flags(H8_BYTE, 0x00 @ value, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_mov8(st : H8State, rd : H8R8, rs : H8R8) -> H8State = {
  let value : byte = read_r8(st, rs);
  let st1 = write_r8(st, rd, value);
  {st1 with ccr = h8_nz_flags(H8_BYTE, 0x00 @ value, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_mov16_imm(st : H8State, rd : h8_r16, value : word) -> H8State = {
  let st1 = write_r16(st, rd, value);
  {st1 with ccr = h8_nz_flags(H8_WORD, value, st.ccr), pc = st.pc + 0x0004}
}

function h8_exec_mov16(st : H8State, rd : h8_r16, rs : h8_r16) -> H8State = {
  let value : word = read_r16(st, rs);
  let st1 = write_r16(st, rd, value);
  {st1 with ccr = h8_nz_flags(H8_WORD, value, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_add8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let lhs : byte = read_r8(st, rd);
  let result : byte = lhs + value;
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_add_flags(H8_BYTE, 0x00 @ lhs, 0x00 @ value, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_add16(st : H8State, rd : h8_r16, value : word) -> H8State = {
  let lhs : word = read_r16(st, rd);
  let result : word = lhs + value;
  let st1 = write_r16(st, rd, result);
  {st1 with ccr = h8_add_flags(H8_WORD, lhs, value, result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_sub8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let lhs : byte = read_r8(st, rd);
  let result : byte = lhs - value;
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_sub_flags(H8_BYTE, 0x00 @ lhs, 0x00 @ value, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_sub16(st : H8State, rd : h8_r16, value : word) -> H8State = {
  let lhs : word = read_r16(st, rd);
  let result : word = lhs - value;
  let st1 = write_r16(st, rd, result);
  {st1 with ccr = h8_sub_flags(H8_WORD, lhs, value, result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_cmp8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let lhs : byte = read_r8(st, rd);
  let result : byte = lhs - value;
  {st with ccr = h8_sub_flags(H8_BYTE, 0x00 @ lhs, 0x00 @ value, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_cmp16(st : H8State, rd : h8_r16, value : word) -> H8State = {
  let lhs : word = read_r16(st, rd);
  let result : word = lhs - value;
  {st with ccr = h8_sub_flags(H8_WORD, lhs, value, result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_and8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let result : byte = read_r8(st, rd) & value;
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_logic_flags(H8_BYTE, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_or8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let result : byte = read_r8(st, rd) | value;
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_logic_flags(H8_BYTE, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_xor8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let result : byte = xor_vec(read_r8(st, rd), value);
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_logic_flags(H8_BYTE, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_not8(st : H8State, rd : H8R8) -> H8State = {
  let result : byte = not_vec(read_r8(st, rd));
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_logic_flags(H8_BYTE, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_branch_taken(cond : H8BranchCond, ccr : H8CCR) -> bool = {
  match cond {
    H8_BRA => true,
    H8_BRN => false,
    H8_BHI => ccr.c == 0b0 & ccr.z == 0b0,
    H8_BLS => ccr.c == 0b1 | ccr.z == 0b1,
    H8_BCC => ccr.c == 0b0,
    H8_BCS => ccr.c == 0b1,
    H8_BNE => ccr.z == 0b0,
    H8_BEQ => ccr.z == 0b1,
    H8_BVC => ccr.v == 0b0,
    H8_BVS => ccr.v == 0b1,
    H8_BPL => ccr.n == 0b0,
    H8_BMI => ccr.n == 0b1,
    H8_BGE => ccr.n == ccr.v,
    H8_BLT => ccr.n != ccr.v,
    H8_BGT => ccr.z == 0b0 & ccr.n == ccr.v,
    H8_BLE => ccr.z == 0b1 | ccr.n != ccr.v
  }
}

function sign_extend8_to16(value : byte) -> word =
  if value[7] == 0b1 then 0xFF @ value else 0x00 @ value

function h8_exec_branch(st : H8State, cond : H8BranchCond, disp : byte) -> H8State = {
  let next_pc : word = st.pc + 0x0002;
  if h8_branch_taken(cond, st.ccr) then
    {st with pc = next_pc + sign_extend8_to16(disp)}
  else
    {st with pc = next_pc}
}

function h8_branch_cond_from_code(code : bits(4)) -> H8BranchCond =
  match code {
    0x0 => H8_BRA,
    0x1 => H8_BRN,
    0x2 => H8_BHI,
    0x3 => H8_BLS,
    0x4 => H8_BCC,
    0x5 => H8_BCS,
    0x6 => H8_BNE,
    0x7 => H8_BEQ,
    0x8 => H8_BVC,
    0x9 => H8_BVS,
    0xA => H8_BPL,
    0xB => H8_BMI,
    0xC => H8_BGE,
    0xD => H8_BLT,
    0xE => H8_BGT,
    0xF => H8_BLE
  }

function h8_decode(first : word, ext : word) -> option(H8Inst) = {
  let op0 : byte = first[15 .. 8];
  let op1 : byte = first[7 .. 0];
  let rr8_rs = h8_r8_from_code(op1[7 .. 4]);
  let rr8_rd = h8_r8_from_code(op1[3 .. 0]);
  match op0[7 .. 4] {
    0x0 => if op0 == 0x00 & op1 == 0x00 then
             Some(H8_NOP())
           else if op0 == 0x08 then
             Some(H8_ADD8_R8_R8(rr8_rd, rr8_rs))
           else if op0 == 0x0C then
             Some(H8_MOV8_R8_R8(rr8_rd, rr8_rs))
           else
             None(),
    0x1 => if op0 == 0x14 then
             Some(H8_OR8_R8_R8(rr8_rd, rr8_rs))
           else if op0 == 0x15 then
             Some(H8_XOR8_R8_R8(rr8_rd, rr8_rs))
           else if op0 == 0x16 then
             Some(H8_AND8_R8_R8(rr8_rd, rr8_rs))
           else if op0 == 0x18 then
             Some(H8_SUB8_R8_R8(rr8_rd, rr8_rs))
           else if op0 == 0x1C then
             Some(H8_CMP8_R8_R8(rr8_rd, rr8_rs))
           else
             None(),
    0x4 => if op1[0] == 0b0 then
             Some(H8_BRANCH(h8_branch_cond_from_code(op0[3 .. 0]), op1))
           else
             None(),
    0x7 => if op0 == 0x79 & op1[7 .. 3] == 0b00000 then
             Some(H8_MOV16_IMM(h8_r16_from_code(op1[2 .. 0]), ext))
           else
             None(),
    0x8 => Some(H8_ADD8_IMM(h8_r8_from_code(op0[3 .. 0]), op1)),
    0xA => Some(H8_CMP8_IMM(h8_r8_from_code(op0[3 .. 0]), op1)),
    0xC => Some(H8_OR8_IMM(h8_r8_from_code(op0[3 .. 0]), op1)),
    0xD => Some(H8_XOR8_IMM(h8_r8_from_code(op0[3 .. 0]), op1)),
    0xE => Some(H8_AND8_IMM(h8_r8_from_code(op0[3 .. 0]), op1)),
    0xF => Some(H8_MOV8_IMM(h8_r8_from_code(op0[3 .. 0]), op1)),
    _ => None()
  }
}

function h8_execute(st : H8State, inst : H8Inst) -> H8ExecResult =
  match inst {
    H8_NOP() => struct {st = h8_exec_nop(st), trap = false},
    H8_BRANCH(cond, disp) => struct {st = h8_exec_branch(st, cond, disp), trap = false},
    H8_MOV8_IMM(rd, imm) => struct {st = h8_exec_mov8_imm(st, rd, imm), trap = false},
    H8_MOV16_IMM(rd, imm) => struct {st = h8_exec_mov16_imm(st, rd, imm), trap = false},
    H8_ADD8_IMM(rd, imm) => struct {st = h8_exec_add8(st, rd, imm), trap = false},
    H8_CMP8_IMM(rd, imm) => struct {st = h8_exec_cmp8(st, rd, imm), trap = false},
    H8_OR8_IMM(rd, imm) => struct {st = h8_exec_or8(st, rd, imm), trap = false},
    H8_XOR8_IMM(rd, imm) => struct {st = h8_exec_xor8(st, rd, imm), trap = false},
    H8_AND8_IMM(rd, imm) => struct {st = h8_exec_and8(st, rd, imm), trap = false},
    H8_ADD8_R8_R8(rd, rs) => struct {st = h8_exec_add8(st, rd, read_r8(st, rs)), trap = false},
    H8_MOV8_R8_R8(rd, rs) => struct {st = h8_exec_mov8(st, rd, rs), trap = false},
    H8_OR8_R8_R8(rd, rs) => struct {st = h8_exec_or8(st, rd, read_r8(st, rs)), trap = false},
    H8_XOR8_R8_R8(rd, rs) => struct {st = h8_exec_xor8(st, rd, read_r8(st, rs)), trap = false},
    H8_AND8_R8_R8(rd, rs) => struct {st = h8_exec_and8(st, rd, read_r8(st, rs)), trap = false},
    H8_SUB8_R8_R8(rd, rs) => struct {st = h8_exec_sub8(st, rd, read_r8(st, rs)), trap = false},
    H8_CMP8_R8_R8(rd, rs) => struct {st = h8_exec_cmp8(st, rd, read_r8(st, rs)), trap = false}
  }

function h8_decode_execute(st : H8State, first : word, ext : word) -> H8ExecResult =
  match h8_decode(first, ext) {
    Some(inst) => h8_execute(st, inst),
    None() => struct {st = st, trap = true}
  }

function h8_step(m : H8Machine) -> H8Machine =
  if m.trap then
    m
  else {
    let first : word = h8_fetch16(m.mem, m.st.pc);
    let ext : word = h8_fetch16(m.mem, m.st.pc + 0x0002);
    let result = h8_decode_execute(m.st, first, ext);
    {m with st = result.st, trap = result.trap}
  }

type h8_step_count = {'n, 0 < 'n. int('n)}

function h8_run(m : H8Machine, step_limit : h8_step_count) -> H8Machine = {
  var out = m;
  foreach (i from 0 to (step_limit - 1)) {
    out = h8_step(out)
  };
  out
}

function h8_reset() -> H8State =
  struct {pc = 0x0000, r = [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000,
                            0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000],
          ccr = struct {i = 0b1, u6 = 0b0, h = 0b0, u4 = 0b0, n = 0b0, z = 0b0, v = 0b0, c = 0b0}}

function h8_reset_machine() -> H8Machine =
  struct {st = h8_reset(), mem = h8_empty_mem(), trap = false}

val h8_load_program : forall 'n, 0 < 'n <= 65536. (H8Machine, word, vector('n, byte)) -> H8Machine
function h8_load_program(m, base, bytes) =
  {m with mem = h8_load_bytes(m.mem, base, bytes)}

function h8_test_ccr(n : bit, z : bit, v : bit, c : bit) -> H8CCR =
  struct {i = 0b1, u6 = 0b0, h = 0b0, u4 = 0b0, n = n, z = z, v = v, c = c}

function h8_test_hnzvc(h : bit, n : bit, z : bit, v : bit, c : bit) -> H8CCR =
  struct {i = 0b1, u6 = 0b0, h = h, u4 = 0b0, n = n, z = z, v = v, c = c}

function h8_ccr_hnzvc(ccr : H8CCR) -> bits(5) =
  ccr.h @ ccr.n @ ccr.z @ ccr.v @ ccr.c

function h8_reg_arith_selftest() -> bool = {
  let r0h : H8R8 = struct {reg = 0, high = true};
  let r0l : H8R8 = struct {reg = 0, high = false};
  let r1l : H8R8 = struct {reg = 1, high = false};
  let st0 = h8_reset();
  let st_nop = h8_exec_nop(st0);
  let st1 = h8_exec_mov8_imm(st_nop, r0h, 0x12);
  let st2 = h8_exec_mov8_imm(st1, r0l, 0x34);
  let st3 = h8_exec_mov8(st2, r1l, r0l);
  let st4 = h8_exec_add8(st3, r0l, 0xCC);
  let st5 = h8_exec_cmp8(st4, r0l, 0x00);
  let st6 = h8_exec_mov16_imm(st5, 2, 0x7FFF);
  let st7 = h8_exec_add16(st6, 2, 0x0001);
  let st8 = h8_exec_sub16(st7, 2, 0x0001);
  let st9 = h8_exec_cmp16(st8, 2, 0x7FFF);
  let st10 = h8_exec_mov16(st9, 3, 2);
  let st11 = h8_exec_sub8(st10, r1l, 0x35);
  let st12 = h8_exec_and8(st11, r1l, 0x0F);
  let st13 = h8_exec_or8(st12, r1l, 0x80);
  let st14 = h8_exec_xor8(st13, r1l, 0xFF);
  let st15 = h8_exec_not8(st14, r1l);
  let st16 = h8_exec_branch(st15, H8_BNE, 0xFE);
  let ok_alias = read_r16(st2, 0) == 0x1234 & read_r8(st3, r1l) == 0x34;
  let ok_add8 = read_r8(st4, r0l) == 0x00 & st4.ccr.z == 0b1 & st4.ccr.c == 0b1;
  let ok_cmp8 = st5.ccr.z == 0b1;
  let ok_add16 = read_r16(st7, 2) == 0x8000 & st7.ccr.n == 0b1 & st7.ccr.v == 0b1 & st7.ccr.c == 0b0;
  let ok_sub16 = read_r16(st8, 2) == 0x7FFF & st8.ccr.h == 0b1 & st8.ccr.v == 0b1;
  let ok_cmp16 = read_r16(st9, 2) == 0x7FFF & st9.ccr.z == 0b1;
  let ok_mov16 = read_r16(st10, 3) == 0x7FFF;
  let ok_sub8 = read_r8(st11, r1l) == 0xFF & st11.ccr.n == 0b1 & st11.ccr.c == 0b1;
  let ok_logic = read_r8(st15, r1l) == 0x8F & st15.ccr.n == 0b1 & st15.ccr.v == 0b0;
  ok_alias & ok_add8 & ok_cmp8 & ok_add16 & ok_sub16 & ok_cmp16 & ok_mov16 & ok_sub8 & ok_logic & st16.pc == st15.pc
}

function h8_r16_state_selftest() -> bool = {
  let r0h : H8R8 = struct {reg = 0, high = true};
  let r0l : H8R8 = struct {reg = 0, high = false};
  let st0 = h8_reset();
  let st1 = write_r16(st0, 8, 0x1234);
  let st2 = write_r16(st1, 0, 0xABCD);
  let st3 = write_r8(st2, r0h, 0x56);
  let st4 = write_r8(st3, r0l, 0x78);
  read_r16(st1, 8) == 0x1234
    & read_r16(st2, 0) == 0xABCD
    & read_r16(st2, 8) == 0x1234
    & read_r16(st4, 0) == 0x5678
    & read_r16(st4, 8) == 0x1234
}

function h8_flag_selftest() -> bool = {
  let r0l : H8R8 = struct {reg = 0, high = false};
  let st0 = h8_reset();
  let add8_base = h8_exec_mov8_imm(st0, r0l, 0x7F);
  let add8 = h8_exec_add8(add8_base, r0l, 0x01);
  let add16_low_base = h8_exec_mov16_imm(st0, 1, 0x000F);
  let add16_low = h8_exec_add16(add16_low_base, 1, 0x0001);
  let add16_h_base = h8_exec_mov16_imm(st0, 1, 0x0FFF);
  let add16_h = h8_exec_add16(add16_h_base, 1, 0x0001);
  let sub8_base = h8_exec_mov8_imm(st0, r0l, 0x80);
  let sub8 = h8_exec_sub8(sub8_base, r0l, 0x01);
  let sub16_low_base = h8_exec_mov16_imm(st0, 1, 0x0010);
  let sub16_low = h8_exec_sub16(sub16_low_base, 1, 0x0001);
  let sub16_h_base = h8_exec_mov16_imm(st0, 1, 0x1000);
  let sub16_h = h8_exec_sub16(sub16_h_base, 1, 0x0001);
  let cmp8_borrow_base = h8_exec_mov8_imm(st0, r0l, 0x00);
  let cmp8_borrow = h8_exec_cmp8(cmp8_borrow_base, r0l, 0x01);
  let cmp8_overflow_base = h8_exec_mov8_imm(st0, r0l, 0x80);
  let cmp8_overflow = h8_exec_cmp8(cmp8_overflow_base, r0l, 0x01);
  let cmp16_borrow_base = h8_exec_mov16_imm(st0, 1, 0x0000);
  let cmp16_borrow = h8_exec_cmp16(cmp16_borrow_base, 1, 0x0001);
  let ok_add8 = read_r8(add8, r0l) == 0x80 & h8_ccr_hnzvc(add8.ccr) == 0b11010;
  let ok_add16_low = read_r16(add16_low, 1) == 0x0010 & h8_ccr_hnzvc(add16_low.ccr) == 0b00000;
  let ok_add16_h = read_r16(add16_h, 1) == 0x1000 & h8_ccr_hnzvc(add16_h.ccr) == 0b10000;
  let ok_sub8 = read_r8(sub8, r0l) == 0x7F & h8_ccr_hnzvc(sub8.ccr) == 0b10010;
  let ok_sub16_low = read_r16(sub16_low, 1) == 0x000F & h8_ccr_hnzvc(sub16_low.ccr) == 0b00000;
  let ok_sub16_h = read_r16(sub16_h, 1) == 0x0FFF & h8_ccr_hnzvc(sub16_h.ccr) == 0b10000;
  let ok_cmp8_borrow = read_r8(cmp8_borrow, r0l) == 0x00 & h8_ccr_hnzvc(cmp8_borrow.ccr) == 0b11001;
  let ok_cmp8_overflow = read_r8(cmp8_overflow, r0l) == 0x80 & h8_ccr_hnzvc(cmp8_overflow.ccr) == 0b10010;
  let ok_cmp16_borrow = read_r16(cmp16_borrow, 1) == 0x0000 & h8_ccr_hnzvc(cmp16_borrow.ccr) == 0b11001;
  ok_add8
    & ok_add16_low
    & ok_add16_h
    & ok_sub8
    & ok_sub16_low
    & ok_sub16_h
    & ok_cmp8_borrow
    & ok_cmp8_overflow
    & ok_cmp16_borrow
}

function h8_branch_selftest() -> bool = {
  let c0 = h8_test_ccr(0b0, 0b0, 0b0, 0b0);
  let c1 = h8_test_ccr(0b1, 0b1, 0b1, 0b1);
  h8_branch_taken(H8_BRA, c0)
    & not_bool(h8_branch_taken(H8_BRN, c1))
    & h8_branch_taken(H8_BHI, c0)
    & h8_branch_taken(H8_BLS, c1)
    & h8_branch_taken(H8_BCC, c0)
    & h8_branch_taken(H8_BCS, c1)
    & h8_branch_taken(H8_BNE, c0)
    & h8_branch_taken(H8_BEQ, c1)
    & h8_branch_taken(H8_BVC, c0)
    & h8_branch_taken(H8_BVS, c1)
    & h8_branch_taken(H8_BPL, c0)
    & h8_branch_taken(H8_BMI, c1)
    & h8_branch_taken(H8_BGE, c0)
    & h8_branch_taken(H8_BLT, h8_test_ccr(0b1, 0b0, 0b0, 0b0))
    & h8_branch_taken(H8_BGT, c0)
    & h8_branch_taken(H8_BLE, c1)
}

function h8_decode_selftest() -> bool = {
  let r0h : H8R8 = struct {reg = 0, high = true};
  let r0l : H8R8 = struct {reg = 0, high = false};
  let st0 = h8_reset();
  let s0 = h8_decode_execute(st0, 0x0000, 0x0000);
  let s1 = h8_decode_execute(s0.st, 0xF012, 0x0000);
  let s2 = h8_decode_execute(s1.st, 0xF834, 0x0000);
  let s3 = h8_decode_execute(s2.st, 0x80EE, 0x0000);
  let s4 = h8_decode_execute(s3.st, 0xA000, 0x0000);
  let s5 = h8_decode_execute(s4.st, 0x7902, 0xABCD);
  let s6 = h8_decode_execute({s5.st with ccr = h8_test_ccr(0b0, 0b0, 0b0, 0b0)}, 0x46FE, 0x0000);
  let s7 = h8_decode_execute(s6.st, 0x4601, 0x0000);
  let s8 = h8_decode_execute(s6.st, 0x0100, 0x0000);
  let bad_branch_decode : option(H8Inst) = h8_decode(0x4601, 0x0000);
  let bad_opcode_decode : option(H8Inst) = h8_decode(0x0100, 0x0000);
  let bad_branch = is_none(bad_branch_decode);
  let bad_opcode = is_none(bad_opcode_decode);
  s0.st.pc == 0x0002
    & read_r8(s1.st, r0h) == 0x12
    & read_r8(s2.st, r0l) == 0x34
    & read_r8(s3.st, r0h) == 0x00
    & s3.st.ccr.z == 0b1
    & s4.st.ccr.z == 0b1
    & read_r16(s5.st, 2) == 0xABCD
    & s5.st.pc == 0x000E
    & s6.st.pc == s5.st.pc
    & bad_branch
    & bad_opcode
    & s7.trap
    & s8.trap
}

function h8_logic_imm_decode_selftest() -> bool = {
  let r1l : H8R8 = struct {reg = 1, high = false};
  let ccr0 = h8_test_hnzvc(0b1, 0b0, 0b0, 0b1, 0b1);
  let or_base = write_r8({h8_reset() with ccr = ccr0}, r1l, 0x01);
  let xor_base = write_r8({h8_reset() with ccr = ccr0}, r1l, 0xFF);
  let and_base = write_r8({h8_reset() with ccr = ccr0}, r1l, 0xF0);
  let or_res = h8_decode_execute(or_base, 0xC980, 0x0000);
  let xor_res = h8_decode_execute(xor_base, 0xD9FF, 0x0000);
  let and_res = h8_decode_execute(and_base, 0xE90F, 0x0000);
  read_r8(or_res.st, r1l) == 0x81
    & h8_ccr_hnzvc(or_res.st.ccr) == 0b11001
    & read_r8(xor_res.st, r1l) == 0x00
    & h8_ccr_hnzvc(xor_res.st.ccr) == 0b10101
    & read_r8(and_res.st, r1l) == 0x00
    & h8_ccr_hnzvc(and_res.st.ccr) == 0b10101
    & not_bool(or_res.trap)
    & not_bool(xor_res.trap)
    & not_bool(and_res.trap)
}

function h8_r8_r8_decode_selftest() -> bool = {
  let r0l : H8R8 = struct {reg = 0, high = false};
  let r1h : H8R8 = struct {reg = 1, high = true};
  let ccr0 = h8_test_hnzvc(0b1, 0b0, 0b0, 0b1, 0b1);
  let add_base = write_r8(write_r8(h8_reset(), r0l, 0x7F), r1h, 0x01);
  let mov_base = write_r8(write_r8({h8_reset() with ccr = ccr0}, r0l, 0x00), r1h, 0x80);
  let or_base = write_r8(write_r8({h8_reset() with ccr = ccr0}, r0l, 0x01), r1h, 0x80);
  let xor_base = write_r8(write_r8({h8_reset() with ccr = ccr0}, r0l, 0x80), r1h, 0x80);
  let and_base = write_r8(write_r8({h8_reset() with ccr = ccr0}, r0l, 0xF0), r1h, 0x0F);
  let sub_base = write_r8(write_r8(h8_reset(), r0l, 0x00), r1h, 0x01);
  let add_res = h8_decode_execute(add_base, 0x0818, 0x0000);
  let mov_res = h8_decode_execute(mov_base, 0x0C18, 0x0000);
  let or_res = h8_decode_execute(or_base, 0x1418, 0x0000);
  let xor_res = h8_decode_execute(xor_base, 0x1518, 0x0000);
  let and_res = h8_decode_execute(and_base, 0x1618, 0x0000);
  let sub_res = h8_decode_execute(sub_base, 0x1818, 0x0000);
  let cmp_res = h8_decode_execute(sub_base, 0x1C18, 0x0000);
  read_r8(add_res.st, r0l) == 0x80
    & h8_ccr_hnzvc(add_res.st.ccr) == 0b11010
    & read_r8(mov_res.st, r0l) == 0x80
    & h8_ccr_hnzvc(mov_res.st.ccr) == 0b11001
    & read_r8(or_res.st, r0l) == 0x81
    & h8_ccr_hnzvc(or_res.st.ccr) == 0b11001
    & read_r8(xor_res.st, r0l) == 0x00
    & h8_ccr_hnzvc(xor_res.st.ccr) == 0b10101
    & read_r8(and_res.st, r0l) == 0x00
    & h8_ccr_hnzvc(and_res.st.ccr) == 0b10101
    & read_r8(sub_res.st, r0l) == 0xFF
    & h8_ccr_hnzvc(sub_res.st.ccr) == 0b11001
    & read_r8(cmp_res.st, r0l) == 0x00
    & h8_ccr_hnzvc(cmp_res.st.ccr) == 0b11001
    & not_bool(add_res.trap)
    & not_bool(mov_res.trap)
    & not_bool(or_res.trap)
    & not_bool(xor_res.trap)
    & not_bool(and_res.trap)
    & not_bool(sub_res.trap)
    & not_bool(cmp_res.trap)
}

function h8_memory_selftest() -> bool = {
  let r0h : H8R8 = struct {reg = 0, high = true};
  let mem0 = h8_empty_mem();
  let mem_fetch = h8_load_bytes(mem0, 0x0000, [0xF0, 0x12]);
  let mem_wrap0 = h8_mem_write8(mem0, 0xFFFF, 0x12);
  let mem_wrap1 = h8_mem_write8(mem_wrap0, 0x0000, 0x34);
  let mov16_mach = h8_load_program(h8_reset_machine(), 0x0000, [0x79, 0x02, 0xAB, 0xCD]);
  let mov16_done = h8_step(mov16_mach);
  let seq_prog = h8_load_program(h8_reset_machine(), 0x0000,
    [0xF0, 0x12, 0xF8, 0x34, 0x80, 0xEE, 0xA0, 0x00, 0x79, 0x02, 0xAB, 0xCD]);
  let seq_done = h8_run(seq_prog, 5);
  let branch_base = {h8_reset_machine() with st = {h8_reset() with pc = 0x000E, ccr = h8_test_ccr(0b0, 0b0, 0b0, 0b0)}};
  let branch_prog = h8_load_program(branch_base, 0x000E, [0x46, 0xFE]);
  let branch_done = h8_run(branch_prog, 3);
  let bad_prog = h8_load_program(h8_reset_machine(), 0x0000, [0x01, 0x00]);
  let bad_done = h8_step(bad_prog);
  h8_fetch16(mem_fetch, 0x0000) == 0xF012
    & h8_fetch16(mem_wrap1, 0xFFFF) == 0x1234
    & read_r16(mov16_done.st, 2) == 0xABCD
    & mov16_done.st.pc == 0x0004
    & not_bool(mov16_done.trap)
    & read_r16(seq_done.st, 0) == 0x0034
    & read_r16(seq_done.st, 2) == 0xABCD
    & seq_done.st.pc == 0x000C
    & not_bool(seq_done.trap)
    & branch_done.st.pc == 0x000E
    & not_bool(branch_done.trap)
    & bad_done.trap
    & bad_done.st.pc == 0x0000
}

function h8_selftest() -> bool =
  h8_reg_arith_selftest()
    & h8_r16_state_selftest()
    & h8_flag_selftest()
    & h8_branch_selftest()
    & h8_decode_selftest()
    & h8_logic_imm_decode_selftest()
    & h8_r8_r8_decode_selftest()
    & h8_memory_selftest()
