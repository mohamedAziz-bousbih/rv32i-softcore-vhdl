-- rv32i_regfile: 31 x 32-bit general-purpose registers (x0 reads as zero),
-- two asynchronous read ports, one synchronous write port, and a debug read
-- port that lets a testbench inspect the architectural state after a halt
-- (left unconnected on the board, where synthesis removes it).
--
-- The read ports are write-through: when the write-back stage writes a
-- register in the same cycle that decode reads it, the new value is
-- returned. That covers the "producer two instructions ahead" hazard, so
-- the pipeline only needs one forwarding path (WB -> EX).
--
-- Asynchronous reads map to logic elements rather than M9K blocks on MAX 10
-- (M9K reads are synchronous). About 1 k flip-flops is cheap on a 10M50 and
-- keeps decode and register read in a single stage.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

use work.rv32i_pkg.all;

entity rv32i_regfile is
  port (
    clk    : in  std_logic;
    raddr1 : in  reg_idx_t;
    raddr2 : in  reg_idx_t;
    rdata1 : out word_t;
    rdata2 : out word_t;
    we     : in  std_logic;
    waddr  : in  reg_idx_t;
    wdata  : in  word_t;
    -- debug: plain read of the stored value, no write-through
    dbg_addr : in  reg_idx_t;
    dbg_data : out word_t
  );
end entity rv32i_regfile;

architecture rtl of rv32i_regfile is

  type regs_t is array (0 to 31) of word_t;
  -- Zero-initialised so that simulation and the reference model start from
  -- the same architectural state; software must not rely on it.
  signal regs : regs_t := (others => (others => '0'));

  -- Every input is a parameter (not read from the enclosing scope) so that
  -- the concurrent calls below are sensitive to all of them.
  function read_port(r : regs_t; ra : reg_idx_t; w_en : std_logic;
                     wa : reg_idx_t; wd : word_t) return word_t is
  begin
    if ra = "00000" then
      return (others => '0');
    elsif w_en = '1' and wa = ra then
      return wd;
    end if;
    return r(to_integer(unsigned(ra)));
  end function;

begin

  process (clk)
  begin
    if rising_edge(clk) then
      if we = '1' and waddr /= "00000" then
        regs(to_integer(unsigned(waddr))) <= wdata;
      end if;
    end if;
  end process;

  rdata1 <= read_port(regs, raddr1, we, waddr, wdata);
  rdata2 <= read_port(regs, raddr2, we, waddr, wdata);

  -- regs(0) is never written, so x0 reads as zero here as well.
  dbg_data <= regs(to_integer(unsigned(dbg_addr)));

end architecture rtl;
