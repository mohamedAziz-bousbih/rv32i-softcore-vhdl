-- ram_be: single-port RAM, 32-bit words, per-byte write enables,
-- synchronous read (read-before-write).
--
-- Stored as four independent byte lanes. Every synthesis tool infers a
-- block RAM from this shape, whereas byte-enable inference from a single
-- 32-bit array depends on vendor-specific coding templates.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;

entity ram_be is
  generic (
    ADDR_BITS : positive  -- word address width; size = 4 * 2**ADDR_BITS bytes
  );
  port (
    clk   : in  std_logic;
    addr  : in  std_logic_vector(ADDR_BITS - 1 downto 0);
    we    : in  byte_en_t;
    wdata : in  word_t;
    q     : out word_t
  );
end entity ram_be;

architecture rtl of ram_be is
begin

  lanes : for lane in 0 to 3 generate
    type lane_t is array (0 to 2**ADDR_BITS - 1) of std_logic_vector(7 downto 0);
    signal mem : lane_t := (others => (others => '0'));
  begin
    process (clk)
    begin
      if rising_edge(clk) then
        if we(lane) = '1' then
          mem(to_integer(unsigned(addr))) <= wdata(8 * lane + 7 downto 8 * lane);
        end if;
        q(8 * lane + 7 downto 8 * lane) <= mem(to_integer(unsigned(addr)));
      end if;
    end process;
  end generate;

end architecture rtl;
