# SPDX-FileCopyrightText: 2026 Huang Rui <vowstar@gmail.com>
# SPDX-License-Identifier: MIT
"""AXI-Lite bridge test: real CoreTopAxi executes over cocotbext-axi AxiLiteRam.

The DUT is the AXI-Lite MASTER (Core + SramToAxiLite bridge); cocotb models the
SLAVE with AxiLiteRam. A tiny H8/300 program is loaded into the RAM (with the
reset SP/PC vectors); the core boots from it and performs directed loads/stores.
Each case then reads the RAM back and checks placement.

Memory contract (from the native SRAM testbenches, the ground truth the core is
built against): H8/300 is big-endian. A 16-bit word 0xHHLL stored at H8 address
A lands as byte[A]=0xHH (high), byte[A+1]=0xLL (low). Reads return
{byte[A], byte[A+1]}.

The bridge places the 16-bit core word on the addr[1]-selected half of the
32-bit AXI word (low half for addr[1]=0, high half for addr[1]=1) with WSTRB
gating the two byte lanes, and byte-swaps within the half so the AXI byte image
is H8 big-endian: a word 0xHHLL written at H8 address A lands as RAM byte[A]=HH,
byte[A+1]=LL, exactly the native SRAM image. The RAM byte address therefore
equals the H8 byte address, so the helpers below are a plain big-endian model.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

from cocotbext.axi import AxiLiteBus, AxiLiteRam

RAM_SIZE = 2**16

# H8/300 reset vector table (word-addressed, big-endian in H8 memory image).
RESET_SP = 0x0300
RESET_PC = 0x0030

# --- H8/300 program -------------------------------------------------------
# Register-indirect stores exercising both AXI half-lanes and WSTRB widths.
#   mov.w #0x1234,R1
#   mov.w #0x0100,R2      ; even word target  (addr[1]=0, low half)
#   mov.w R1,@R2          ; word store -> WSTRB 0b0011 on low half
#   mov.w #0x5678,R3
#   mov.w #0x0102,R4      ; addr[1]=1 word target (high half)
#   mov.w R3,@R4          ; word store -> WSTRB 0b1100 on high half
#   mov.b #0xAB,R5L
#   mov.w #0x0200,R6      ; byte store to EVEN H8 addr 0x0200 (high byte)
#   mov.b R5L,@R6
#   mov.b #0xCD,R0L
#   mov.w #0x0203,R7      ; byte store to ODD H8 addr 0x0203 (low byte)
#   mov.b R0L,@R7
#   mov.w @R2,R0          ; read back the first word into R0
#   mov.w #0x0110,R2      ; store R0 to a witness address so the RAM shows it
#   mov.w R0,@R2
# loop: bra loop
PROGRAM = {
    0x0030: [0x79, 0x01, 0x12, 0x34],   # mov.w #0x1234,R1
    0x0034: [0x79, 0x02, 0x01, 0x00],   # mov.w #0x0100,R2
    0x0038: [0x69, 0xA1],               # mov.w R1,@R2
    0x003A: [0x79, 0x03, 0x56, 0x78],   # mov.w #0x5678,R3
    0x003E: [0x79, 0x04, 0x01, 0x02],   # mov.w #0x0102,R4
    0x0042: [0x69, 0xC3],               # mov.w R3,@R4
    0x0044: [0xFD, 0xAB],               # mov.b #0xAB,R5L
    0x0046: [0x79, 0x06, 0x02, 0x00],   # mov.w #0x0200,R6
    0x004A: [0x68, 0xED],               # mov.b R5L,@R6
    0x004C: [0xF8, 0xCD],               # mov.b #0xCD,R0L
    0x004E: [0x79, 0x07, 0x02, 0x03],   # mov.w #0x0203,R7
    0x0052: [0x68, 0xF8],               # mov.b R0L,@R7
    0x0054: [0x69, 0x20],               # mov.w @R2,R0
    0x0056: [0x79, 0x02, 0x01, 0x10],   # mov.w #0x0110,R2
    0x005A: [0x69, 0xA0],               # mov.w R0,@R2
    0x005C: [0x40, 0xFE],               # loop: bra loop  (-2)
}


def load_ram(ram):
    """Write the reset vectors and program into the AxiLiteRam byte image.

    The AXI byte image is H8 big-endian (the bridge byte-swaps), so the vectors
    and program go in at their H8 byte addresses directly.
    """
    axil_put_word(ram, 0x0002, RESET_SP)
    axil_put_word(ram, 0x0006, RESET_PC)
    for base, data in PROGRAM.items():
        for off in range(0, len(data), 2):
            hi, lo = data[off], data[off + 1]
            axil_put_word(ram, base + off, (hi << 8) | lo)


# --- Big-endian RAM model -------------------------------------------------
# The bridge makes the AXI byte image H8 big-endian, so the RAM byte address is
# the H8 byte address and these are a plain big-endian view.

def axil_put_word(ram, h8_addr, word):
    """Place a 16-bit H8 word big-endian at its H8 byte address."""
    ram.write(h8_addr, bytes([(word >> 8) & 0xFF, word & 0xFF]))


def axil_get_word(ram, h8_addr):
    """Read a 16-bit H8 word (big-endian) from its H8 byte address."""
    b = ram.read(h8_addr, 2)
    return (b[0] << 8) | b[1]


def axil_get_byte(ram, h8_addr):
    """Read one H8 byte at its H8 byte address (big-endian image)."""
    return ram.read(h8_addr, 1)[0]


@cocotb.test()
async def axil_boot_and_stores(dut):
    dut.reset.value = 1
    dut.irq.value = 0
    dut.nmi.value = 0
    dut.irq_number.value = 0
    dut.vt_base.value = 0

    cocotb.start_soon(Clock(dut.clock, 10, unit="ns").start())

    ram = AxiLiteRam(
        AxiLiteBus.from_prefix(dut, "m_axil"), dut.clock, dut.reset, size=RAM_SIZE
    )
    load_ram(ram)

    await ClockCycles(dut.clock, 4)
    dut.reset.value = 0
    # Let the core boot (fetch SP/PC) and run the whole store sequence to the
    # bra self-loop. Each store is a multi-cycle microcode op over AXI-Lite.
    await ClockCycles(dut.clock, 400)

    errors = []

    def expect(name, got, exp):
        if got != exp:
            errors.append(f"{name}: got 0x{got:04x} exp 0x{exp:04x}")
        dut._log.info("%s = 0x%04x (exp 0x%04x)", name, got, exp)

    # 1. Word store to even H8 addr 0x0100 (addr[1]=0, low half, WSTRB 0b0011).
    expect("word@0x0100 (low half)", axil_get_word(ram, 0x0100), 0x1234)

    # 2. Word store to H8 addr 0x0102 (addr[1]=1, high half, WSTRB 0b1100).
    expect("word@0x0102 (high half)", axil_get_word(ram, 0x0102), 0x5678)

    # 3. Byte store to EVEN H8 addr 0x0200 -> high byte of its word.
    expect("byte@0x0200 (even/high)", axil_get_byte(ram, 0x0200), 0xAB)

    # 4. Byte store to ODD H8 addr 0x0203 -> low byte of its word.
    expect("byte@0x0203 (odd/low)", axil_get_byte(ram, 0x0203), 0xCD)

    # 5. Read path: R0 = @0x0100, then stored to witness 0x0110.
    expect("read-back @0x0100 -> @0x0110", axil_get_word(ram, 0x0110), 0x1234)

    # --- Raw byte-order check --------------------------------------------
    # The AXI byte image must be H8 big-endian: word 0x1234 at 0x0100 gives
    # byte[0x0100]=0x12 (high), byte[0x0101]=0x34 (low), so an external big-
    # endian AXI observer reads the same bytes the core wrote.
    raw = ram.read(0x0100, 2)
    dut._log.info("RAW RAM bytes @0x0100: [%02x %02x] (expect [12 34])", raw[0], raw[1])
    if raw[0] != 0x12 or raw[1] != 0x34:
        errors.append(
            f"raw byte order @0x0100: got [{raw[0]:02x} {raw[1]:02x}] exp [12 34]")

    assert not errors, "AXI-Lite bridge checks failed:\n  " + "\n  ".join(errors)
    dut._log.info("AXI-LITE PASS: boot, word/byte stores, both lanes, read-back")
