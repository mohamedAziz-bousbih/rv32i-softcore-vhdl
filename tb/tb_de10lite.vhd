-- tb_de10lite: smoke test of the board top level as it would be synthesised.
--
-- Uses the generated rom_image_pkg (sw/apps/hello) and the real baud-rate
-- divisor (50 MHz / 115200 baud = 434 clocks per bit). While KEY0 is held
-- down the SoC must stay in reset with the UART line idle and the LEDs off;
-- after the release the first UART line must read "Hello from RV32I".
-- The rest of the program is covered by tb_soc with a fast UART.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

use work.sim_pkg.all;

entity tb_de10lite is
end entity tb_de10lite;

architecture sim of tb_de10lite is

  constant CLK_PERIOD   : time := 20 ns;
  constant CLKS_PER_BIT : positive := 434;
  constant GREETING     : string := "Hello from RV32I";
  -- The greeting takes 17 frames of 10 bits; allow twice that.
  constant TIMEOUT      : time := 2 * 17 * 10 * CLKS_PER_BIT * CLK_PERIOD;

  signal clk  : std_logic := '0';
  signal key  : std_logic_vector(0 downto 0) := "0";  -- pressed
  signal sw   : std_logic_vector(9 downto 0) := "1011001110";
  signal ledr : std_logic_vector(9 downto 0);
  signal tx   : std_logic;
  signal done : boolean := false;

begin

  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.de10lite_top
    port map (
      MAX10_CLK1_50 => clk,
      KEY           => key,
      SW            => sw,
      LEDR          => ledr,
      UART_TX       => tx
    );

  -- A broken design may never send anything; end the run anyway.
  watchdog : process
  begin
    wait for TIMEOUT;
    assert done report "tb_de10lite: no complete greeting within " & time'image(TIMEOUT)
      severity failure;
    wait;
  end process;

  check : process
    variable byte     : std_logic_vector(7 downto 0);
    variable received : string(1 to 64);
    variable n        : natural := 0;
    variable c        : character;
  begin
    -- Reset held by the button.
    for i in 1 to 200 loop
      wait until rising_edge(clk);
      assert tx = '1' report "UART active while KEY0 is pressed" severity failure;
    end loop;
    assert ledr = "0000000000" report "LEDs on while KEY0 is pressed" severity failure;
    key <= "1";

    -- First line after the release.
    loop
      uart_receive(clk, tx, CLKS_PER_BIT, byte);
      c := character'val(to_integer(unsigned(byte)));
      exit when c = LF;
      assert n < received'length report "UART line too long" severity failure;
      n := n + 1;
      received(n) := c;
    end loop;

    report "tb_de10lite: uart| " & received(1 to n);
    assert received(1 to n) = GREETING
      report "tb_de10lite: expected '" & GREETING & "'" severity failure;
    done <= true;
    report "tb_de10lite: OK";
    finish;
  end process;

end architecture sim;
