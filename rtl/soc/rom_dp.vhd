-- rom_dp: read-only memory with two independent synchronous read ports.
--
-- Port A feeds instruction fetch, port B serves loads from the ROM region
-- (constants, string literals and the .data initialisers that crt0 copies
-- to RAM). Both ports register the address, which matches an M9K block of
-- the MAX 10 configured as a dual-port ROM.
--
-- The contents arrive as a generic rather than being read from a file, so
-- the RTL contains no file I/O: the testbench loads a hex image, the board
-- top level passes the constant from a generated VHDL package.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;

entity rom_dp is
  generic (
    ADDR_BITS : positive;     -- word address width; size = 4 * 2**ADDR_BITS bytes
    INIT      : word_array_t  -- program image, word 0 first; may be shorter than the ROM
  );
  port (
    clk    : in  std_logic;
    addr_a : in  std_logic_vector(ADDR_BITS - 1 downto 0);
    q_a    : out word_t;
    addr_b : in  std_logic_vector(ADDR_BITS - 1 downto 0);
    q_b    : out word_t
  );
end entity rom_dp;

architecture rtl of rom_dp is

  -- Pads the image with zeros to the full ROM depth (zero is an illegal
  -- instruction, so running off the end of a program halts the core).
  function fill(image : word_array_t; depth : positive) return word_array_t is
    variable mem : word_array_t(0 to depth - 1) := (others => (others => '0'));
  begin
    assert image'length <= depth
      report "ROM image of " & integer'image(image'length) &
             " words does not fit into " & integer'image(depth) & " words"
      severity failure;
    for i in 0 to image'length - 1 loop
      mem(i) := image(image'low + i);
    end loop;
    return mem;
  end function;

  constant ROM : word_array_t(0 to 2**ADDR_BITS - 1) := fill(INIT, 2**ADDR_BITS);

begin

  process (clk)
  begin
    if rising_edge(clk) then
      q_a <= ROM(to_integer(unsigned(addr_a)));
      q_b <= ROM(to_integer(unsigned(addr_b)));
    end if;
  end process;

end architecture rtl;
