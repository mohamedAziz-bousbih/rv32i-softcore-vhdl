-- sim_pkg: simulation-only helpers shared by the testbenches.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

use work.rv32i_pkg.all;

package sim_pkg is

  -- Loads a memory image: one 32-bit hex word per line, word 0 first.
  -- Words beyond the end of the file are zero. An empty path yields an
  -- all-zero image, so that a design can be elaborated before the image
  -- is chosen (GHDL's -e step); the caller checks that a file was given.
  impure function read_hex_file(path : string; depth : positive) return word_array_t;

  -- Receives one 8N1 frame from `rx`. Samples are taken on rising clock
  -- edges in the middle of each bit, as a real receiver clocked from the
  -- same oscillator would; start and stop bits are checked.
  procedure uart_receive(signal clk     : in  std_logic;
                         signal rx      : in  std_logic;
                         constant cpb   : in  positive;  -- clocks per bit
                         variable byte  : out std_logic_vector(7 downto 0));

  -- Compares a received line with an expected-output pattern. A '#' in the
  -- pattern matches a run of one or more decimal digits (greedy, so '#'
  -- must not be followed by a digit); every other character matches itself.
  -- scripts/run_tests.py applies the same rule to the reference model.
  function line_matches(pattern, s : string) return boolean;

  -- Drops a trailing CR so expected-output files with CRLF endings work.
  function strip_cr(s : string) return string;

end package sim_pkg;

package body sim_pkg is

  impure function read_hex_file(path : string; depth : positive) return word_array_t is
    file f          : text;
    variable status : file_open_status;
    variable l      : line;
    variable w      : word_t;
    variable ok     : boolean;
    variable mem    : word_array_t(0 to depth - 1) := (others => (others => '0'));
    variable n      : natural := 0;
  begin
    if path'length = 0 then
      return mem;
    end if;
    file_open(status, f, path, read_mode);
    assert status = open_ok
      report "cannot open memory image '" & path & "'" severity failure;
    while not endfile(f) loop
      readline(f, l);
      if l'length > 0 then
        assert n < depth
          report "memory image '" & path & "' does not fit into " &
                 integer'image(depth) & " words" severity failure;
        hread(l, w, ok);
        assert ok
          report "malformed line " & integer'image(n + 1) & " in '" & path & "'"
          severity failure;
        mem(n) := w;
        n      := n + 1;
      end if;
    end loop;
    file_close(f);
    return mem;
  end function;

  procedure uart_receive(signal clk     : in  std_logic;
                         signal rx      : in  std_logic;
                         constant cpb   : in  positive;
                         variable byte  : out std_logic_vector(7 downto 0)) is
  begin
    wait until falling_edge(rx);
    for i in 1 to cpb / 2 loop
      wait until rising_edge(clk);
    end loop;
    assert rx = '0' report "UART: start bit too short" severity failure;
    for b in 0 to 7 loop
      for i in 1 to cpb loop
        wait until rising_edge(clk);
      end loop;
      byte(b) := rx;
    end loop;
    for i in 1 to cpb loop
      wait until rising_edge(clk);
    end loop;
    assert rx = '1' report "UART: framing error (stop bit is 0)" severity failure;
  end procedure;

  function is_digit(c : character) return boolean is
  begin
    return c >= '0' and c <= '9';
  end function;

  function line_matches(pattern, s : string) return boolean is
    variable j : integer := s'low;
  begin
    for i in pattern'range loop
      if pattern(i) = '#' then
        if j > s'high or not is_digit(s(j)) then
          return false;
        end if;
        while j <= s'high and is_digit(s(j)) loop
          j := j + 1;
        end loop;
      else
        if j > s'high or s(j) /= pattern(i) then
          return false;
        end if;
        j := j + 1;
      end if;
    end loop;
    return j > s'high;
  end function;

  function strip_cr(s : string) return string is
  begin
    if s'length > 0 and s(s'high) = CR then
      return s(s'low to s'high - 1);
    end if;
    return s;
  end function;

end package body sim_pkg;
