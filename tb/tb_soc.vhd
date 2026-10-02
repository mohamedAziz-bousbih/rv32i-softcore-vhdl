-- tb_soc: runs one program on the complete SoC and judges the outcome.
--
-- The run ends when the program writes TEST_STATUS, when the core halts, or
-- after MAX_CYCLES. The outcome ("pass", "fail", "timeout" or the halt cause
-- such as "halt_ecall") must equal EXPECT. Along the way the testbench
--   * decodes the serial UART line bit by bit (checking the real 8N1
--     framing), prints every line as "uart| ..." and, if UART_EXPECT_FILE is
--     given, matches it against the next line of that file ('#' in the file
--     stands for a run of digits, e.g. a cycle count);
--   * optionally writes a commit trace (one line per retired instruction)
--     that scripts/run_tests.py compares with the Python reference model;
--   * optionally checks the LED outputs at the end (EXPECT_LEDS >= 0);
--   * reports cycles and retired instructions for CPI figures;
--   * after a halt, prints x1..x31 as read through the register file's
--     debug port, so the runner can check that the halt was precise.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

use work.rv32i_pkg.all;
use work.soc_pkg.all;
use work.sim_pkg.all;

entity tb_soc is
  generic (
    ROM_FILE         : string   := "";
    EXPECT           : string   := "pass";
    UART_EXPECT_FILE : string   := "";
    TRACE_FILE       : string   := "";
    MAX_CYCLES       : positive := 2_000_000;
    CLKS_PER_BIT     : positive := 8;        -- fast UART keeps simulations short
    SWITCHES         : natural  := 16#2A5#;  -- value driven onto gpio_in
    EXPECT_LEDS      : integer  := -1        -- checked at the end if >= 0
  );
end entity tb_soc;

architecture sim of tb_soc is

  constant CLK_PERIOD    : time := 20 ns;  -- 50 MHz, as on the DE10-Lite
  constant GPIO_WIDTH    : positive := 10;
  constant ROM_ADDR_BITS : positive := 12;
  constant ROM_IMAGE     : word_array_t := read_hex_file(ROM_FILE, 2**ROM_ADDR_BITS);

  signal clk      : std_logic := '0';
  signal rst      : std_logic := '1';
  signal uart_tx  : std_logic;
  signal gpio_out : std_logic_vector(GPIO_WIDTH - 1 downto 0);
  signal gpio_in  : std_logic_vector(GPIO_WIDTH - 1 downto 0);
  signal dbg      : soc_debug_t;
  signal dbg_reg_addr : reg_idx_t := (others => '0');
  signal done     : boolean := false;

  -- UART checker state visible to the control process.
  signal uart_expect_left : boolean := false;  -- expected lines not yet seen
  signal uart_partial     : boolean := false;  -- characters after the last LF

begin

  assert CLKS_PER_BIT >= 2
    report "the UART sampler needs at least 2 clocks per bit" severity failure;

  clk     <= not clk after CLK_PERIOD / 2 when not done;
  gpio_in <= std_logic_vector(to_unsigned(SWITCHES, GPIO_WIDTH));

  dut : entity work.rv32i_soc
    generic map (
      ROM_INIT      => ROM_IMAGE,
      ROM_ADDR_BITS => ROM_ADDR_BITS,
      CLKS_PER_BIT  => CLKS_PER_BIT,
      GPIO_WIDTH    => GPIO_WIDTH
    )
    port map (
      clk      => clk,
      rst      => rst,
      uart_tx  => uart_tx,
      gpio_out => gpio_out,
      gpio_in  => gpio_in,
      dbg      => dbg,
      dbg_reg_addr => dbg_reg_addr
    );

  ---------------------------------------------------------------------------
  -- UART receiver and line checker
  ---------------------------------------------------------------------------
  uart_rx : process
    file exp_f        : text;
    variable status   : file_open_status;
    variable byte     : std_logic_vector(7 downto 0);
    variable c        : character;
    variable cur      : line := new string'("");
    variable exp_l    : line;
    variable out_l    : line;
    variable have_exp : boolean := false;
  begin
    if UART_EXPECT_FILE'length > 0 then
      file_open(status, exp_f, UART_EXPECT_FILE, read_mode);
      assert status = open_ok
        report "cannot open " & UART_EXPECT_FILE severity failure;
      have_exp := true;
      uart_expect_left <= not endfile(exp_f);
    end if;

    loop
      uart_receive(clk, uart_tx, CLKS_PER_BIT, byte);
      c := character'val(to_integer(unsigned(byte)));
      if c = LF then
        write(out_l, string'("uart| ") & cur.all);
        writeline(output, out_l);
        if have_exp then
          assert not endfile(exp_f)
            report "UART: unexpected extra line '" & cur.all & "'" severity failure;
          readline(exp_f, exp_l);
          assert line_matches(strip_cr(exp_l.all), cur.all)
            report "UART mismatch: expected '" & strip_cr(exp_l.all) &
                   "', got '" & cur.all & "'" severity failure;
          uart_expect_left <= not endfile(exp_f);
        end if;
        deallocate(cur);
        cur := new string'("");
        uart_partial <= false;
      elsif c /= CR then
        write(cur, c);
        uart_partial <= true;
      end if;
    end loop;
  end process;

  ---------------------------------------------------------------------------
  -- Commit trace, one line per retired instruction:
  --   pc instr rd rd_data store_be mem_addr store_data
  -- rd = 0 when nothing is written, mem_addr = 0 unless the instruction is
  -- a load or store, store data masked to the enabled lanes.
  ---------------------------------------------------------------------------
  tracer : process
    file trace_f  : text;
    variable l    : line;
    variable r    : retire_t;
    variable data : word_t;
    variable addr : word_t;
  begin
    if TRACE_FILE'length = 0 then
      wait;
    end if;
    file_open(trace_f, TRACE_FILE, write_mode);
    loop
      wait until rising_edge(clk) or done;
      exit when done;
      r := dbg.retire;
      if r.valid = '1' then
        write(l, to_hstring(r.pc) & ' ' & to_hstring(r.instr) & ' ');
        if r.rd_we = '1' then
          write(l, to_hstring(r.rd) & ' ' & to_hstring(r.rd_data));
        else
          write(l, string'("00 00000000"));
        end if;
        -- The core exports its ALU result for every instruction; it is an
        -- address only for loads and stores.
        if r.instr(6 downto 0) = OPC_LOAD or r.instr(6 downto 0) = OPC_STORE then
          addr := r.mem_addr;
        else
          addr := (others => '0');
        end if;
        for lane in 0 to 3 loop
          if r.st_be(lane) = '1' then
            data(8 * lane + 7 downto 8 * lane) := r.st_data(8 * lane + 7 downto 8 * lane);
          else
            data(8 * lane + 7 downto 8 * lane) := x"00";
          end if;
        end loop;
        write(l, ' ' & to_hstring(r.st_be) & ' ' & to_hstring(addr) & ' ' & to_hstring(data));
        writeline(trace_f, l);
      end if;
    end loop;
    file_close(trace_f);
    wait;
  end process;

  ---------------------------------------------------------------------------
  -- Reset, run, judge. Values are sampled on rising edges, i.e. the process
  -- sees what the design held during the cycle that just ended.
  ---------------------------------------------------------------------------
  control : process
    variable cycles  : natural := 0;
    variable instret : natural := 0;
    variable outcome : line;
    variable l       : line;
    variable failed  : boolean := false;
  begin
    assert ROM_FILE'length > 0
      report "tb_soc: set the ROM_FILE generic (-gROM_FILE=...)" severity failure;
    rst <= '1';
    for i in 1 to 4 loop
      wait until rising_edge(clk);
    end loop;
    rst <= '0';

    loop
      wait until rising_edge(clk);
      cycles := cycles + 1;
      if dbg.retire.valid = '1' then
        instret := instret + 1;
      end if;
      exit when dbg.status_we = '1' or dbg.halted = '1' or cycles >= MAX_CYCLES;
    end loop;

    if dbg.status_we = '1' then
      if dbg.status_data = x"00000001" then
        write(outcome, string'("pass"));
      else
        write(outcome, string'("fail"));
      end if;
    elsif dbg.halted = '1' then
      write(outcome, halt_cause_t'image(dbg.halt_cause));
    else
      write(outcome, string'("timeout"));
    end if;

    -- The halted pipeline is frozen, so the register file holds the final
    -- architectural state.
    if dbg.halted = '1' then
      write(l, string'("regs|"));
      for i in 1 to 31 loop
        dbg_reg_addr <= std_logic_vector(to_unsigned(i, 5));
        wait for 1 ns;
        write(l, ' ' & to_hstring(dbg.reg_data));
      end loop;
      writeline(output, l);
    end if;

    -- Let the tracer close its file.
    done <= true;
    wait for CLK_PERIOD;

    write(l, string'("tb_soc: result=") & outcome.all &
             " cycles=" & integer'image(cycles) &
             " instret=" & integer'image(instret) &
             " status=" & to_hstring(dbg.status_data) &
             " halt_pc=" & to_hstring(dbg.halt_pc) &
             " leds=" & to_hstring(gpio_out));
    writeline(output, l);

    if outcome.all /= EXPECT then
      report "outcome '" & outcome.all & "' but expected '" & EXPECT & "'" severity error;
      if outcome.all = "fail" then
        report "program reports failure in test case " &
               integer'image(to_integer(unsigned(dbg.status_data(31 downto 1))))
          severity error;
      end if;
      failed := true;
    end if;
    if EXPECT_LEDS >= 0 and to_integer(unsigned(gpio_out)) /= EXPECT_LEDS then
      report "LEDs are 0x" & to_hstring(gpio_out) & ", expected 0x" &
             to_hstring(to_unsigned(EXPECT_LEDS, GPIO_WIDTH)) severity error;
      failed := true;
    end if;
    if uart_expect_left then
      report "UART: expected output has lines that were never received" severity error;
      failed := true;
    end if;
    if uart_partial then
      report "UART: output ends without a newline" severity error;
      failed := true;
    end if;

    assert not failed report "tb_soc: FAILED" severity failure;
    report "tb_soc: OK";
    finish;
  end process;

end architecture sim;
