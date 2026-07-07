/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */

type byte = bits(8)
type word = bits(16)
type h8_r16 = range(0, 7)

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
  reg : h8_r16,
  high : bool
}

struct H8State = {
  pc : word,
  r : vector(8, word),
  ccr : H8CCR
}

union H8Inst = {
  H8_NOP : unit,
  H8_BRANCH : (H8BranchCond, byte),
  H8_MOV8_IMM : (H8R8, byte),
  H8_MOV16_IMM : (h8_r16, word),
  H8_ADD8_IMM : (H8R8, byte),
  H8_CMP8_IMM : (H8R8, byte)
}

struct H8ExecResult = {
  st : H8State,
  trap : bool
}

function mask16(addr : word) -> word = addr

function align_word_addr(addr : word) -> word =
  addr[15 .. 1] @ 0b0

function h8_r8_from_code(code : bits(4)) -> H8R8 =
  struct {reg = unsigned(code[2 .. 0]), high = code[3] == 0b0}

function h8_r16_from_code(code : bits(3)) -> h8_r16 =
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
  match op0[7 .. 4] {
    0x0 => if op0 == 0x00 & op1 == 0x00 then Some(H8_NOP()) else None(),
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
    H8_CMP8_IMM(rd, imm) => struct {st = h8_exec_cmp8(st, rd, imm), trap = false}
  }

function h8_decode_execute(st : H8State, first : word, ext : word) -> H8ExecResult =
  match h8_decode(first, ext) {
    Some(inst) => h8_execute(st, inst),
    None() => struct {st = st, trap = true}
  }

function h8_reset() -> H8State =
  struct {pc = 0x0000, r = [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000],
          ccr = struct {i = 0b1, u6 = 0b0, h = 0b0, u4 = 0b0, n = 0b0, z = 0b0, v = 0b0, c = 0b0}}

function h8_test_ccr(n : bit, z : bit, v : bit, c : bit) -> H8CCR =
  struct {i = 0b1, u6 = 0b0, h = 0b0, u4 = 0b0, n = n, z = z, v = v, c = c}

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

function h8_selftest() -> bool =
  h8_reg_arith_selftest() & h8_branch_selftest() & h8_decode_selftest()
