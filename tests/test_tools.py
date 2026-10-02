"""Tests of the build and test scripts, and consistency of committed files."""

import struct
from pathlib import Path

import pytest

import build_sw
import gen_vectors
import run_tests

ROOT = Path(__file__).resolve().parent.parent


def test_bin_to_words_is_little_endian_and_padded():
    assert build_sw.bin_to_words(b"\x13\x00\x00\x00\xAA") == [0x13, 0xAA]
    assert build_sw.words_to_hex([0x13, 0xDEADBEEF]) == "00000013\nDEADBEEF\n"


def test_vhdl_package_lists_every_word():
    words = list(range(1, 14))
    text = build_sw.words_to_vhdl_package(words, "sw/apps/x")
    assert "word_array_t(0 to 12)" in text
    assert text.count('x"') == 13
    assert 'x"0000000D"\n  );' in text


def make_elf(sections):
    """Minimal ELF32 with the given (flags, type, payload) sections."""
    data = bytearray(0x34)
    data[:6] = b"\x7fELF\x01\x01"
    offsets = []
    for _, _, payload in sections:
        offsets.append(len(data))
        data += payload
    shoff = len(data)
    data += bytes(40)  # null section header
    for (flags, sh_type, payload), offset in zip(sections, offsets):
        data += struct.pack("<10I", 0, sh_type, flags, 0, offset, len(payload), 0, 0, 4, 0)
    struct.pack_into("<I", data, 0x20, shoff)
    struct.pack_into("<HHH", data, 0x2E, 40, len(sections) + 1, 0)
    return bytes(data)


def test_executable_words_reads_only_code_sections():
    code = struct.pack("<2I", 0x00000013, 0x02208733)
    rodata = struct.pack("<I", 0xFFFFFFFF)
    elf = make_elf([(0x6, 1, code), (0x2, 1, rodata)])
    assert build_sw.executable_words(elf) == [0x00000013, 0x02208733]


@pytest.mark.parametrize("pattern, text, ok", [
    ("x = #", "x = 42", True),
    ("x = #", "x = ", False),
    ("x = #", "x = 4a", False),
    ("CPI #.#", "CPI 1.10", True),
    ("(# cycles)", "(12 cycles)", True),
    ("a.b", "axb", False),          # only '#' is special
    ("abc", "abcd", False),
])
def test_line_matches(pattern, text, ok):
    assert run_tests.line_matches(pattern, text) is ok


def test_annotations():
    text = "/*\n * @expect halt_ecall\n * @leds 0x155 */\n/* @uart OK\n * @reg x7 0x156\n */\n"
    assert run_tests.annotations([text]) == {
        "expect": ["halt_ecall"], "leds": ["0x155"], "uart": ["OK"], "reg": ["x7 0x156"]}


def test_vectors_are_reproducible_and_complete():
    lines = gen_vectors.generate()
    assert lines == gen_vectors.generate()
    kinds = {line[0] for line in lines}
    assert kinds == {"D", "A", "B", "L", "S"}
    assert "D 00000073 1 F 00000000 00000000" in lines   # ECALL
    assert "D 00000000 3 F 00000000 00000000" in lines   # illegal


def test_every_program_has_a_committed_image():
    sources = {p.stem for p in (ROOT / "sw" / "tests").glob("*.S")}
    sources |= {p.name for p in (ROOT / "sw" / "apps").iterdir() if p.is_dir()}
    images = {p.stem for p in (ROOT / "sw" / "images").glob("*.hex")}
    assert sources == images


def test_board_package_matches_hello_image():
    words = [int(w, 16) for w in (ROOT / "sw" / "images" / "hello.hex").read_text().split()]
    package = (ROOT / "board" / "de10lite" / "rom_image_pkg.vhd").read_text()
    assert package == build_sw.words_to_vhdl_package(words, "sw/apps/hello")


def test_every_program_declares_a_known_outcome():
    causes = {"pass", "halt_ecall", "halt_ebreak", "halt_illegal",
              "halt_misaligned_fetch", "halt_misaligned_load", "halt_misaligned_store"}
    for prog in run_tests.discover_programs():
        assert prog.expect in causes, prog.name
