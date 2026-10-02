-- tb_uart_tx: cycle-exact check of the 8N1 transmitter.
--
-- After every clock edge the testbench compares the line and the busy flag
-- with an independent model of the frame: start bit, eight data bits LSB
-- first and a stop bit, each exactly CLKS_PER_BIT cycles long. Checked
-- scenarios: idle line, single frames with several bit patterns, a start
-- request while busy (ignored), a request in the first cycle with busy low
-- (accepted at once, so polling software can send at full rate) and a
-- reset in mid-frame.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.all;

entity tb_uart_tx is
end entity tb_uart_tx;

architecture sim of tb_uart_tx is

  constant CLKS_PER_BIT : positive := 5;  -- odd, to catch off-by-one counts
  constant CLK_PERIOD   : time := 10 ns;

  signal clk   : std_logic := '0';
  signal rst   : std_logic := '1';
  signal data  : std_logic_vector(7 downto 0) := (others => '0');
  signal start : std_logic := '0';
  signal busy  : std_logic;
  signal tx    : std_logic;
  signal done  : boolean := false;

begin

  clk <= not clk after CLK_PERIOD / 2 when not done;

  dut : entity work.uart_tx
    generic map (
      CLKS_PER_BIT => CLKS_PER_BIT
    )
    port map (
      clk   => clk,
      rst   => rst,
      data  => data,
      start => start,
      busy  => busy,
      tx    => tx
    );

  stimulus : process
    variable errors : natural := 0;

    procedure check(exp_tx, exp_busy : std_logic; what : string) is
    begin
      if tx /= exp_tx or busy /= exp_busy then
        errors := errors + 1;
        report what & ": tx=" & std_logic'image(tx) & " busy=" & std_logic'image(busy) &
               ", expected tx=" & std_logic'image(exp_tx) & " busy=" &
               std_logic'image(exp_busy) severity error;
      end if;
    end procedure;

    -- One clock cycle; outputs are compared just after the edge.
    procedure tick is
    begin
      wait until rising_edge(clk);
      wait for 1 ns;
    end procedure;

    -- Requests a frame for one cycle, then checks all 10 * CLKS_PER_BIT
    -- cycles of it. A second request (`spoil`) is made in the middle of the
    -- frame and must have no effect.
    procedure send_and_check(byte : std_logic_vector(7 downto 0); spoil : boolean) is
      variable frame : std_logic_vector(9 downto 0);
    begin
      frame := '1' & byte & '0';  -- stop, data (MSB..LSB), start
      data  <= byte;
      start <= '1';
      tick;
      start <= '0';
      for bit_idx in 0 to 9 loop
        for c in 1 to CLKS_PER_BIT loop
          check(frame(bit_idx), '1', "frame " & to_hstring(byte) & " bit " &
                integer'image(bit_idx) & " cycle " & integer'image(c));
          if spoil and bit_idx = 4 and c = 2 then
            data  <= not byte;
            start <= '1';
          else
            start <= '0';
          end if;
          if not (bit_idx = 9 and c = CLKS_PER_BIT) then
            tick;
          end if;
        end loop;
      end loop;
    end procedure;

  begin
    rst <= '1';
    tick;
    tick;
    rst <= '0';
    check('1', '0', "after reset");

    -- Idle: the line stays high without a request.
    for i in 1 to 3 * CLKS_PER_BIT loop
      tick;
      check('1', '0', "idle");
    end loop;

    send_and_check(x"A5", false);
    tick;
    check('1', '0', "idle after A5");

    send_and_check(x"00", false);
    tick;
    send_and_check(x"FF", true);   -- request while busy is ignored
    tick;
    check('1', '0', "idle after FF");
    tick;
    check('1', '0', "no frame from the ignored request");

    -- Back to back: the next request comes in the first cycle with busy
    -- low and is accepted on that edge.
    send_and_check(x"3C", false);
    tick;
    check('1', '0', "stop bit of 3C completed");
    send_and_check(x"C3", false);
    tick;

    -- Reset in mid-frame returns the line to idle at once.
    data  <= x"00";
    start <= '1';
    tick;
    start <= '0';
    tick;
    check('0', '1', "start bit before reset");
    rst <= '1';
    tick;
    check('1', '0', "reset in mid-frame");
    rst <= '0';
    for i in 1 to 2 * CLKS_PER_BIT loop
      tick;
      check('1', '0', "idle after reset");
    end loop;

    done <= true;
    assert errors = 0 report "tb_uart_tx: FAILED" severity failure;
    report "tb_uart_tx: OK";
    finish;
  end process;

end architecture sim;
