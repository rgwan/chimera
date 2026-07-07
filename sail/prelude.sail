/* SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com> */
/* SPDX-License-Identifier: MIT */

default Order dec

$include <prelude.sail>
$include <mapping.sail>
$include <vector_dec.sail>
$include <generic_equality.sail>
$include <hex_bits.sail>

mapping bool_bit : bool <-> bits(1) = {
  true  <-> 0b1,
  false <-> 0b0,
}

function bool_to_bit(value : bool) -> bit = bool_bit(value)

val sub_vec = pure {c: "sub_bits", cpp: "sub_bits", _: "sub_vec"} :
  forall 'n. (bits('n), bits('n)) -> bits('n)

overload operator - = {sub_vec}
