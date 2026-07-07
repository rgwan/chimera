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

function mask16(addr : word) -> word = addr

function align_word_addr(addr : word) -> word =
  addr[15 .. 1] @ 0b0

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

function h8_exec_mov16_imm(st : H8State, rd : h8_r16, value : word) -> H8State = {
  let st1 = write_r16(st, rd, value);
  {st1 with ccr = h8_nz_flags(H8_WORD, value, st.ccr), pc = st.pc + 0x0004}
}

function h8_exec_add8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let lhs : byte = read_r8(st, rd);
  let result : byte = lhs + value;
  let st1 = write_r8(st, rd, result);
  {st1 with ccr = h8_add_flags(H8_BYTE, 0x00 @ lhs, 0x00 @ value, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
}

function h8_exec_cmp8(st : H8State, rd : H8R8, value : byte) -> H8State = {
  let lhs : byte = read_r8(st, rd);
  let result : byte = lhs - value;
  {st with ccr = h8_sub_flags(H8_BYTE, 0x00 @ lhs, 0x00 @ value, 0x00 @ result, st.ccr), pc = st.pc + 0x0002}
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

function h8_reset() -> H8State =
  struct {pc = 0x0000, r = [0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000, 0x0000],
          ccr = struct {i = 0b1, u6 = 0b0, h = 0b0, u4 = 0b0, n = 0b0, z = 0b0, v = 0b0, c = 0b0}}

function h8_selftest() -> bool = {
  let r0h : H8R8 = struct {reg = 0, high = true};
  let r0l : H8R8 = struct {reg = 0, high = false};
  let st0 = h8_reset();
  let st1 = h8_exec_mov8_imm(st0, r0h, 0x12);
  let st2 = h8_exec_mov8_imm(st1, r0l, 0x34);
  let st3 = h8_exec_add8(st2, r0l, 0xCC);
  let st4 = h8_exec_cmp8(st3, r0l, 0x00);
  let st5 = h8_exec_branch(st4, H8_BEQ, 0xFE);
  read_r16(st2, 0) == 0x1234
    & read_r8(st3, r0l) == 0x00
    & st3.ccr.z == 0b1
    & st3.ccr.c == 0b1
    & st4.ccr.z == 0b1
    & st5.pc == st4.pc
}
