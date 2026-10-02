-- tb_core_vectors: golden-vector check of the core's combinational parts.
--
-- Reads the file written by scripts/gen_vectors.py and compares, line by
-- line, the instruction decoder, the ALU entity, the branch comparator and
-- the load/store lane functions of rv32i_pkg with the values of the Python
-- reference model. Every mismatch is reported; the run fails if there was
-- any, or if a vector kind is missing from the file.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use std.env.all;

use work.rv32i_pkg.all;

entity tb_core_vectors is
  generic (
    VECTOR_FILE : string := ""
  );
end entity tb_core_vectors;

architecture sim of tb_core_vectors is

  signal alu_op : alu_op_t := ALU_ADD;
  signal alu_a  : word_t   := (others => '0');
  signal alu_b  : word_t   := (others => '0');
  signal alu_y  : word_t;

  function cause_code(c : halt_cause_t) return natural is
  begin
    case c is
      when HALT_NONE   => return 0;
      when HALT_ECALL  => return 1;
      when HALT_EBREAK => return 2;
      when HALT_ILLEGAL => return 3;
      -- decode() never reports address faults; they come from EX.
      when others      => return 15;
    end case;
  end function;

begin

  dut : entity work.rv32i_alu
    port map (
      op => alu_op,
      a  => alu_a,
      b  => alu_b,
      y  => alu_y
    );

  run : process
    file f            : text;
    variable status   : file_open_status;
    variable l        : line;
    variable kind     : character;
    variable sep      : character;
    variable lineno   : natural := 0;
    variable errors   : natural := 0;
    variable n_dec    : natural := 0;
    variable n_alu    : natural := 0;
    variable n_br     : natural := 0;
    variable n_ld     : natural := 0;
    variable n_st     : natural := 0;
    -- fields (hread needs a multiple of four bits)
    variable w, a, b, y, imm, mask, data, lanes : word_t;
    variable nib1, nib2, nib3, nib4 : std_logic_vector(3 downto 0);
    variable d        : decoded_t;

    procedure fail(msg : string) is
    begin
      errors := errors + 1;
      if errors <= 20 then
        report "vector line " & integer'image(lineno) & ": " & msg severity error;
      end if;
    end procedure;

  begin
    assert VECTOR_FILE'length > 0
      report "tb_core_vectors: set the VECTOR_FILE generic" severity failure;
    file_open(status, f, VECTOR_FILE, read_mode);
    assert status = open_ok
      report "cannot open " & VECTOR_FILE severity failure;

    while not endfile(f) loop
      readline(f, l);
      lineno := lineno + 1;
      next when l'length = 0;
      read(l, kind);
      read(l, sep);

      case kind is
        when 'D' =>
          -- word cause rd_we imm mask
          hread(l, w); read(l, sep);
          hread(l, nib1); read(l, sep);
          hread(l, nib2); read(l, sep);
          hread(l, imm); read(l, sep);
          hread(l, mask);
          d := decode(w);
          if cause_code(d.cause) /= to_integer(unsigned(nib1)) then
            fail("decode(" & to_hstring(w) & "): cause " &
                 halt_cause_t'image(d.cause) & ", expected code " & to_hstring(nib1));
          elsif nib2 /= x"F" and d.rd_we /= nib2(0) then
            fail("decode(" & to_hstring(w) & "): rd_we " & std_logic'image(d.rd_we));
          elsif (d.imm and mask) /= (imm and mask) then
            fail("decode(" & to_hstring(w) & "): imm " & to_hstring(d.imm) &
                 ", expected " & to_hstring(imm));
          end if;
          n_dec := n_dec + 1;

        when 'A' =>
          -- op a b y
          hread(l, nib1); read(l, sep);
          hread(l, a); read(l, sep);
          hread(l, b); read(l, sep);
          hread(l, y);
          alu_op <= nib1;
          alu_a  <= a;
          alu_b  <= b;
          wait for 1 ns;
          if alu_y /= y then
            fail("alu op " & to_hstring(nib1) & " " & to_hstring(a) & ", " &
                 to_hstring(b) & " = " & to_hstring(alu_y) & ", expected " & to_hstring(y));
          end if;
          n_alu := n_alu + 1;

        when 'B' =>
          -- funct3 a b taken
          hread(l, nib1); read(l, sep);
          hread(l, a); read(l, sep);
          hread(l, b); read(l, sep);
          hread(l, nib2);
          if branch_taken(nib1(2 downto 0), a, b) /= nib2(0) then
            fail("branch f3=" & to_hstring(nib1) & " " & to_hstring(a) & ", " & to_hstring(b));
          end if;
          n_br := n_br + 1;

        when 'L' =>
          -- funct3 offset word result misaligned
          hread(l, nib1); read(l, sep);
          hread(l, nib2); read(l, sep);
          hread(l, w); read(l, sep);
          hread(l, y); read(l, sep);
          hread(l, nib3);
          if is_misaligned(nib1(2 downto 0), nib2(1 downto 0)) /= (nib3(0) = '1') then
            fail("load misalignment f3=" & to_hstring(nib1) & " offset " & to_hstring(nib2));
          elsif nib3(0) = '0' and load_extend(w, nib1(2 downto 0), nib2(1 downto 0)) /= y then
            fail("load_extend f3=" & to_hstring(nib1) & " offset " & to_hstring(nib2) &
                 " word " & to_hstring(w));
          end if;
          n_ld := n_ld + 1;

        when 'S' =>
          -- funct3 offset data byte_enables lanes misaligned
          hread(l, nib1); read(l, sep);
          hread(l, nib2); read(l, sep);
          hread(l, data); read(l, sep);
          hread(l, nib3); read(l, sep);
          hread(l, lanes); read(l, sep);
          hread(l, nib4);
          if is_misaligned(nib1(2 downto 0), nib2(1 downto 0)) /= (nib4(0) = '1') then
            fail("store misalignment f3=" & to_hstring(nib1) & " offset " & to_hstring(nib2));
          elsif nib4(0) = '0' and
                (store_byte_enable(nib1(2 downto 0), nib2(1 downto 0)) /= nib3 or
                 store_lanes(nib1(2 downto 0), data) /= lanes) then
            fail("store f3=" & to_hstring(nib1) & " offset " & to_hstring(nib2) &
                 " data " & to_hstring(data));
          end if;
          n_st := n_st + 1;

        when others =>
          fail("unknown vector kind '" & kind & "'");
      end case;
    end loop;
    file_close(f);

    report "tb_core_vectors: decode " & integer'image(n_dec) &
           ", alu " & integer'image(n_alu) & ", branch " & integer'image(n_br) &
           ", load " & integer'image(n_ld) & ", store " & integer'image(n_st) &
           " vectors, " & integer'image(errors) & " mismatches";
    assert n_dec > 0 and n_alu > 0 and n_br > 0 and n_ld > 0 and n_st > 0
      report "tb_core_vectors: a vector kind is missing" severity failure;
    assert errors = 0 report "tb_core_vectors: FAILED" severity failure;
    report "tb_core_vectors: OK";
    finish;
  end process;

end architecture sim;
