-- rv32i_alu: purely combinational integer ALU for the RV32I base ISA.
--
-- op = {instr[30], funct3}. funct3 selects the function; bit 3 only matters
-- for 000 (ADD/SUB) and 101 (SRL/SRA), so every one of the 16 op codes has a
-- defined result and no "others" fallback is needed.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;

entity rv32i_alu is
  port (
    op : in  alu_op_t;
    a  : in  word_t;
    b  : in  word_t;
    y  : out word_t
  );
end entity rv32i_alu;

architecture rtl of rv32i_alu is
begin

  process (all)
    -- Only the low five bits of the shift amount are used (RV32I spec).
    variable shamt : natural range 0 to 31;
  begin
    shamt := to_integer(unsigned(b(4 downto 0)));
    case op(2 downto 0) is
      when "000" =>
        if op(3) = '1' then
          y <= std_logic_vector(unsigned(a) - unsigned(b));
        else
          y <= std_logic_vector(unsigned(a) + unsigned(b));
        end if;
      when "001" =>
        y <= std_logic_vector(shift_left(unsigned(a), shamt));
      when "010" =>
        y <= (others => '0');
        if signed(a) < signed(b) then
          y(0) <= '1';
        end if;
      when "011" =>
        y <= (others => '0');
        if unsigned(a) < unsigned(b) then
          y(0) <= '1';
        end if;
      when "100" =>
        y <= a xor b;
      when "101" =>
        if op(3) = '1' then
          y <= std_logic_vector(shift_right(signed(a), shamt));
        else
          y <= std_logic_vector(shift_right(unsigned(a), shamt));
        end if;
      when "110" =>
        y <= a or b;
      when others =>
        y <= a and b;
    end case;
  end process;

end architecture rtl;
