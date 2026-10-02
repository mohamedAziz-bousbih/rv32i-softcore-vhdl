#!/usr/bin/env python3
"""Checks that the test suite notices bugs: injects one fault at a time into
a temporary copy of the RTL and runs scripts/run_tests.py on it.

A mutation counts as detected if at least one testbench fails. The report
also says whether a failure came from a self-check (a program's own result,
a unit testbench, the expected UART text or LEDs) or only from the
comparison with the reference model. The repository itself is never
modified. Each mutation names the exact code it replaces, so a refactoring
that removes that code makes this script fail instead of silently testing
nothing.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COPY = ["rtl", "tb", "board", "scripts", "sw/images", "sw/tests", "sw/apps", "sw/common"]

# (name, file, original code, mutated code)
MUTATIONS = [
    ("ALU: SRA shifts in zeros", "rtl/core/rv32i_alu.vhd",
     "y <= std_logic_vector(shift_right(signed(a), shamt));",
     "y <= std_logic_vector(shift_right(unsigned(a), shamt));"),
    ("ALU: SLT compares unsigned", "rtl/core/rv32i_alu.vhd",
     "if signed(a) < signed(b) then",
     "if unsigned(a) < unsigned(b) then"),
    ("ALU: shift amount taken from 6 bits", "rtl/core/rv32i_alu.vhd",
     "variable shamt : natural range 0 to 31;\n  begin\n    shamt := to_integer(unsigned(b(4 downto 0)));",
     "variable shamt : natural range 0 to 63;\n  begin\n    shamt := to_integer(unsigned(b(5 downto 0)));"),
    ("ALU: SUB adds", "rtl/core/rv32i_alu.vhd",
     "y <= std_logic_vector(unsigned(a) - unsigned(b));",
     "y <= std_logic_vector(unsigned(a) + unsigned(b));"),
    ("decode: SRAI decoded as SRLI", "rtl/core/rv32i_pkg.vhd",
     "d.alu_op := instr(30) & f3;\n          else",
     "d.alu_op := '0' & f3;\n          else"),
    ("decode: writes to x0 not suppressed", "rtl/core/rv32i_pkg.vhd",
     "if d.rd = \"00000\" then\n      d.rd_we := '0';\n    end if;",
     "null;"),
    ("decode: B-immediate bit 11 from instr(31)", "rtl/core/rv32i_pkg.vhd",
     "return sext(instr(31) & instr(7) & instr(30 downto 25)",
     "return sext(instr(31) & instr(31) & instr(30 downto 25)"),
    ("decode: FENCE illegal", "rtl/core/rv32i_pkg.vhd",
     "if f3 /= \"000\" then\n          d.cause := HALT_ILLEGAL;",
     "if f3 /= \"111\" then\n          d.cause := HALT_ILLEGAL;"),
    ("decode: RV32M MUL accepted as ADD", "rtl/core/rv32i_pkg.vhd",
     "if not (f7 = \"0000000\" or (f7 = \"0100000\"",
     "if not (f7 = \"0000000\" or f7 = \"0000001\" or (f7 = \"0100000\""),
    ("branch: BGE is strict", "rtl/core/rv32i_pkg.vhd",
     "when \"10\"   => cond := signed(a) < signed(b);",
     "when \"10\"   => cond := signed(a) <= signed(b);"),
    ("load: LH zero-extends", "rtl/core/rv32i_pkg.vhd",
     "when F3_H   => return sext(shifted(15 downto 0));",
     "when F3_H   => return std_logic_vector(resize(unsigned(shifted(15 downto 0)), 32));"),
    ("store: SH upper half uses the wrong lanes", "rtl/core/rv32i_pkg.vhd",
     "return \"1100\";", "return \"0110\";"),
    ("pipeline: no WB->EX forwarding on rs2", "rtl/core/rv32i_core.vhd",
     "op2 <= wb_result when wb_valid = '1' and wb_rd_we = '1' and wb_rd = ex_dec.rs2 else ex_rs2_val;",
     "op2 <= ex_rs2_val;"),
    ("pipeline: forwarding ignores wb_valid", "rtl/core/rv32i_core.vhd",
     "op1 <= wb_result when wb_valid = '1' and wb_rd_we = '1'",
     "op1 <= wb_result when wb_rd_we = '1'"),
    ("regfile: no write-through", "rtl/core/rv32i_regfile.vhd",
     "elsif w_en = '1' and wa = ra then\n      return wd;\n    end if;",
     "end if;"),
    ("pipeline: instruction behind a taken branch not squashed", "rtl/core/rv32i_core.vhd",
     "ex_valid   <= not redirect and not ex_fault;",
     "ex_valid   <= not ex_fault;"),
    ("JALR: bit 0 of the target not cleared", "rtl/core/rv32i_core.vhd",
     "ex_target <= alu_y(31 downto 1) & '0' when",
     "ex_target <= alu_y when"),
    ("JAL: link register gets pc instead of pc + 4", "rtl/core/rv32i_core.vhd",
     "wb_exec_result <= ex_pc4;", "wb_exec_result <= ex_pc;"),
    ("exceptions: misaligned loads not detected", "rtl/core/rv32i_core.vhd",
     "elsif ex_dec.is_load = '1' and is_misaligned(",
     "elsif false and is_misaligned("),
    ("exceptions: halt is imprecise (older instruction dropped)", "rtl/core/rv32i_core.vhd",
     "rf_we <= wb_valid and wb_rd_we;",
     "rf_we <= wb_valid and wb_rd_we and not ex_fault;"),
    ("UART: bit period one cycle too long", "rtl/soc/uart_tx.vhd",
     "elsif baud_cnt = CLKS_PER_BIT - 1 then",
     "elsif baud_cnt = CLKS_PER_BIT then"),
    ("UART: write while busy restarts the frame", "rtl/soc/uart_tx.vhd",
     "      elsif bits_left = 0 then\n        if start = '1' then",
     "      elsif bits_left = 0 or start = '1' then\n        if start = '1' then"),
    ("MMIO: MTIME not writable", "rtl/soc/soc_mmio.vhd",
     "mtime <= unsigned(wdata);", "null;"),
    ("MMIO: CRC unit uses the wrong polynomial", "rtl/soc/soc_pkg.vhd",
     "x\"EDB88320\";", "x\"EDB88321\";"),
    ("SoC: RAM stores ignore the byte enables", "rtl/soc/rv32i_soc.vhd",
     "ram_we   <= dmem_we when region = REGION_RAM else \"0000\";",
     "ram_we   <= \"1111\" when region = REGION_RAM and dmem_we /= \"0000\" else \"0000\";"),
]

# run_tests.py messages for failures found without the reference model: the
# testbench run itself failed, or a register differs from the test's @reg.
SELF_CHECK_HINTS = ("tb_soc failed", "test expects")


def apply(tree: Path, file: str, old: str, new: str) -> None:
    path = tree / file
    text = path.read_text()
    if text.count(old) != 1:
        sys.exit(f"mutation_check: the code to mutate in {file} was not found "
                 f"exactly once:\n{old}")
    path.write_text(text.replace(old, new), newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ghdl", default="ghdl")
    parser.add_argument("-k", "--filter", default="",
                        help="only mutations whose name contains this text")
    args = parser.parse_args()

    undetected = 0
    selected = [m for m in MUTATIONS if args.filter.lower() in m[0].lower()]
    with tempfile.TemporaryDirectory() as tmp:
        tree = Path(tmp)
        for part in COPY:
            shutil.copytree(ROOT / part, tree / part)
        for name, file, old, new in selected:
            pristine = (ROOT / file).read_text()
            apply(tree, file, old, new)
            proc = subprocess.run(
                [sys.executable, str(tree / "scripts" / "run_tests.py"),
                 "--ghdl", args.ghdl],
                capture_output=True, encoding="utf-8", errors="replace",
                env={**os.environ, "PYTHONIOENCODING": "utf-8"})
            (tree / file).write_text(pristine, newline="\n")

            failing, self_checked = [], False
            current = None
            for line in proc.stdout.splitlines():
                m = re.match(r"FAIL\s+(\S+)", line)
                if m:
                    current = m.group(1)
                    failing.append(current)
                    if current.startswith("tb_") and current != "tb_soc":
                        self_checked = True
                elif current and any(h in line for h in SELF_CHECK_HINTS):
                    self_checked = True
            if proc.returncode != 0 and not failing:
                # run_tests.py stopped before running anything, e.g. because
                # the mutated code does not analyse; show why.
                failing = ["(suite aborted)"]
                for line in (proc.stdout + proc.stderr).strip().splitlines()[-8:]:
                    print(f"    {line}")
            detected = proc.returncode != 0
            undetected += not detected
            how = "self-check" if self_checked else "model comparison only"
            shown = ", ".join(failing[:6]) + (" ..." if len(failing) > 6 else "")
            print(f"{'detected  ' if detected else 'MISSED    '} {name}"
                  + (f"  [{how}: {shown}]" if detected else ""))
            sys.stdout.flush()

    print(f"\n{len(selected) - undetected}/{len(selected)} mutations detected")
    return 1 if undetected else 0


if __name__ == "__main__":
    sys.exit(main())
