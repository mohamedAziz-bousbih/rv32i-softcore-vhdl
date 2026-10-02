#!/usr/bin/env python3
"""Runs the complete simulation test suite with GHDL.

  1. tb_core_vectors  decoder, ALU, branch comparator and load/store lanes
                      against golden vectors from the reference model
  2. tb_uart_tx       cycle-exact check of the UART transmitter
  3. tb_soc           every program in sw/images on the complete SoC. Each run
                      is judged by its own self-check (TEST_STATUS, halt cause,
                      LEDs, expected UART text) and compared with the
                      reference model (scripts/rv32i_iss.py): outcome, cycle
                      count, retired instructions, halt PC, LEDs, UART output,
                      the commit trace instruction by instruction and, after a
                      halt, the register file.
  4. tb_de10lite      the board top level at the real baud rate

Exit status 0 only if everything passed. The ROM images are committed, so
zig is not needed here (scripts/build_sw.py rebuilds them).
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import time
import traceback
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import gen_vectors  # noqa: E402
import rv32i_iss as iss  # noqa: E402

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / "build"
WORK = BUILD / "ghdl"

# Analysis order: packages before their users.
RTL_SOURCES = [
    "rtl/core/rv32i_pkg.vhd",
    "rtl/core/rv32i_alu.vhd",
    "rtl/core/rv32i_regfile.vhd",
    "rtl/core/rv32i_core.vhd",
    "rtl/soc/soc_pkg.vhd",
    "rtl/soc/uart_tx.vhd",
    "rtl/soc/rom_dp.vhd",
    "rtl/soc/ram_be.vhd",
    "rtl/soc/soc_mmio.vhd",
    "rtl/soc/rv32i_soc.vhd",
    "board/de10lite/rom_image_pkg.vhd",
    "board/de10lite/de10lite_top.vhd",
]
TB_SOURCES = [
    "tb/sim_pkg.vhd",
    "tb/tb_core_vectors.vhd",
    "tb/tb_uart_tx.vhd",
    "tb/tb_soc.vhd",
    "tb/tb_de10lite.vhd",
]
TOPS = ["tb_core_vectors", "tb_uart_tx", "tb_soc", "tb_de10lite"]

RESULT_RE = re.compile(
    r"tb_soc: result=(?P<outcome>\S+) cycles=(?P<cycles>\d+) "
    r"instret=(?P<instret>\d+) status=(?P<status>[0-9A-F]+) "
    r"halt_pc=(?P<halt_pc>[0-9A-F]+) leds=(?P<leds>[0-9A-F]+)")


def line_matches(pattern: str, text: str) -> bool:
    """'#' matches one or more digits; same rule as sim_pkg.line_matches."""
    regex = "".join(r"\d+" if c == "#" else re.escape(c) for c in pattern)
    return re.fullmatch(regex, text) is not None


@dataclass
class Program:
    name: str
    image: Path
    expect: str = "pass"
    leds: int | None = None
    uart_lines: list[str] | None = None   # expected patterns, None = no check
    regs: dict[int, int] = field(default_factory=dict)  # after a halt


@dataclass
class Outcome:
    name: str
    ok: bool
    messages: list[str] = field(default_factory=list)
    cycles: int = 0
    instret: int = 0
    result: str = ""
    seconds: float = 0.0


def annotations(texts: list[str]) -> dict[str, list[str]]:
    found: dict[str, list[str]] = {}
    for text in texts:
        for key, value in re.findall(r"@(expect|leds|uart|reg)[ \t]+([^\n]*)", text):
            found.setdefault(key, []).append(re.sub(r"\s*(\*/)?\s*$", "", value))
    return found


def discover_programs() -> list[Program]:
    programs = []
    for image in sorted((ROOT / "sw" / "images").glob("*.hex")):
        name = image.stem
        test_src = ROOT / "sw" / "tests" / f"{name}.S"
        app_dir = ROOT / "sw" / "apps" / name
        if test_src.exists():
            sources = [test_src]
        elif app_dir.is_dir():
            sources = sorted(app_dir.glob("*.[cS]"))
        else:
            sys.exit(f"run_tests: no source for image {image.name}")
        notes = annotations([s.read_text() for s in sources])
        prog = Program(name, image)
        if "expect" in notes:
            prog.expect = notes["expect"][0]
        if "leds" in notes:
            prog.leds = int(notes["leds"][0], 0)
        if "uart" in notes:
            prog.uart_lines = notes["uart"]
        for note in notes.get("reg", []):
            reg, value = note.split()
            prog.regs[int(reg.lstrip("x"))] = int(value, 0)
        expected_file = app_dir / "expected_uart.txt"
        if expected_file.exists():
            prog.uart_lines = expected_file.read_text().splitlines()
        programs.append(prog)
    return programs


class Ghdl:
    def __init__(self, exe: str):
        self.exe = exe

    def run(self, args: list[str], timeout: float | None = None) -> subprocess.CompletedProcess:
        # A broken design can print arbitrary bytes on its UART, so decoding
        # must not fail; a hung simulation counts as a failure.
        try:
            return subprocess.run([self.exe, *args], cwd=WORK, capture_output=True,
                                  encoding="utf-8", errors="replace", timeout=timeout)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, -1, "", f"timed out after {timeout} s")

    def analyse_and_elaborate(self) -> None:
        if WORK.exists():
            shutil.rmtree(WORK)
        WORK.mkdir(parents=True)
        sources = [str(ROOT / s) for s in RTL_SOURCES + TB_SOURCES]
        steps = [["-a", "--std=08", *sources]]
        steps += [["-e", "--std=08", top] for top in TOPS]
        for args in steps:
            proc = self.run(args)
            if proc.returncode != 0:
                sys.exit(f"run_tests: ghdl {' '.join(args[:2])} failed:\n"
                         f"{proc.stdout}{proc.stderr}")

    def simulate(self, top: str, generics: dict[str, str | int],
                 timeout: float = 600) -> subprocess.CompletedProcess:
        args = ["-r", "--std=08", top]
        args += [f"-g{k}={v}" for k, v in generics.items()]
        # numeric_std warns about 'U' operands before the first clock edge.
        args.append("--ieee-asserts=disable-at-0")
        return self.run(args, timeout)


def check_unit_tb(ghdl: Ghdl, top: str, generics: dict[str, str | int]) -> Outcome:
    start = time.monotonic()
    proc = ghdl.simulate(top, generics)
    out = proc.stdout + proc.stderr
    ok = proc.returncode == 0 and f"{top}: OK" in out
    summary = [line for line in out.splitlines() if "vectors," in line]
    outcome = Outcome(top, ok, seconds=time.monotonic() - start,
                      result="ok" if ok else "FAILED")
    outcome.messages = summary if ok else out.strip().splitlines()[-25:]
    return outcome


def compare_traces(rtl: list[str], model: list[str]) -> list[str]:
    for i, (a, b) in enumerate(zip(rtl, model)):
        if a != b:
            word = int(b.split()[1], 16)
            pc = int(b.split()[0], 16)
            return [f"commit trace differs at instruction {i}:",
                    f"  rtl:   {a}",
                    f"  model: {b}   ({iss.disassemble(word, pc)})"]
    if len(rtl) != len(model):
        return [f"commit trace length: rtl {len(rtl)}, model {len(model)}"]
    return []


def run_program(ghdl: Ghdl, prog: Program, trace: bool) -> Outcome:
    start = time.monotonic()
    out = Outcome(prog.name, True)
    try:
        check_program(ghdl, prog, trace, out)
    except Exception:  # report, do not abort the other runs
        out.messages += traceback.format_exc().splitlines()
    out.ok = not out.messages
    out.seconds = time.monotonic() - start
    return out


def check_program(ghdl: Ghdl, prog: Program, trace: bool, out: Outcome) -> None:
    errors = out.messages

    model = iss.Soc(iss.read_hex(prog.image)).run(trace=trace)
    model_uart = model.uart.decode("ascii", errors="replace").splitlines()

    # The model must agree with the program's own expectations too, so a
    # wrong model cannot make a wrong core look right.
    if model.outcome != prog.expect:
        errors.append(f"model outcome {model.outcome}, expected {prog.expect}")
    if prog.uart_lines is not None:
        if len(model_uart) != len(prog.uart_lines) or not all(
                line_matches(p, s) for p, s in zip(prog.uart_lines, model_uart)):
            errors.append("model UART output does not match the expected text")

    generics: dict[str, str | int] = {
        "ROM_FILE": prog.image.resolve().as_posix(),
        "EXPECT": prog.expect,
        # Twice the model's run time is plenty; a broken core that loops
        # forever then ends as "timeout" instead of hanging the suite.
        "MAX_CYCLES": 2 * model.cycles + 1000,
    }
    if prog.leds is not None:
        generics["EXPECT_LEDS"] = prog.leds
    if prog.uart_lines is not None:
        expect_file = BUILD / "expect" / f"{prog.name}.txt"
        expect_file.parent.mkdir(parents=True, exist_ok=True)
        expect_file.write_text("".join(f"{s}\n" for s in prog.uart_lines), newline="\n")
        generics["UART_EXPECT_FILE"] = expect_file.resolve().as_posix()
    trace_file = BUILD / "trace" / f"{prog.name}.txt"
    if trace:
        trace_file.parent.mkdir(parents=True, exist_ok=True)
        generics["TRACE_FILE"] = trace_file.resolve().as_posix()

    proc = ghdl.simulate("tb_soc", generics)
    text = proc.stdout + proc.stderr
    match = RESULT_RE.search(text)
    if proc.returncode != 0 or match is None:
        errors.append(f"tb_soc failed (exit {proc.returncode}):")
        errors += ["  " + line for line in text.strip().splitlines()[-15:]]
    if match:
        rtl = match.groupdict()
        out.result = rtl["outcome"]
        out.cycles = int(rtl["cycles"])
        out.instret = int(rtl["instret"])
        for key, model_value in [("outcome", model.outcome),
                                 ("cycles", model.cycles),
                                 ("instret", model.instret),
                                 ("halt_pc", model.halt_pc),
                                 ("leds", model.leds)]:
            value = rtl[key]
            if key in ("halt_pc", "leds"):
                value = int(value, 16)
            elif key != "outcome":
                value = int(value)
            if value != model_value:
                errors.append(f"{key}: rtl {value}, model {model_value}")
        rtl_uart = [line[len("uart| "):] for line in text.splitlines()
                    if line.startswith("uart| ")]
        if rtl_uart != model_uart:
            errors.append("UART output differs from the model")
        if trace and trace_file.exists():
            errors += compare_traces(trace_file.read_text().splitlines(), model.trace)
        if model.outcome.startswith("halt"):
            errors += check_halt_registers(text, prog, model.regs)


def check_halt_registers(text: str, prog: Program, model_regs: list[int]) -> list[str]:
    """Register file after a halt: the older instructions must have written
    their results, the faulting one and everything younger must not have."""
    dump = next((line for line in text.splitlines() if line.startswith("regs|")), None)
    if dump is None:
        return ["no register dump after the halt"]
    rtl = [0] + [int(v, 16) for v in dump.split()[1:]]
    errors = [f"x{n}: rtl {rtl[n]:08X}, test expects {value:08X}"
              for n, value in sorted(prog.regs.items()) if rtl[n] != value]
    errors += [f"x{n} after the halt: rtl {rtl[n]:08X}, model {model_regs[n]:08X}"
               for n in range(1, 32) if rtl[n] != model_regs[n]]
    return errors


def write_report(path: Path, outcomes: list[Outcome]) -> None:
    rows = ["| Program | Result | Cycles | Instructions | CPI |",
            "|---|---|---:|---:|---:|"]
    for o in outcomes:
        cpi = f"{o.cycles / o.instret:.3f}" if o.instret else "-"
        rows.append(f"| {o.name} | {o.result} | {o.cycles} | {o.instret} | {cpi} |")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(rows) + "\n", newline="\n")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"),
                        help="GHDL executable (default: $GHDL or ghdl)")
    parser.add_argument("-k", "--filter", default="",
                        help="only run programs whose name contains this text")
    parser.add_argument("--no-trace", action="store_true",
                        help="skip the commit-trace comparison (faster)")
    parser.add_argument("-j", "--jobs", type=int, default=os.cpu_count() or 1)
    parser.add_argument("--report", type=Path,
                        help="write a Markdown table of cycle counts to this file")
    args = parser.parse_args()
    # Failure reports can quote UART output of a broken design.
    sys.stdout.reconfigure(errors="replace")

    if shutil.which(args.ghdl) is None:
        sys.exit(f"run_tests: '{args.ghdl}' not found")
    ghdl = Ghdl(args.ghdl)
    t0 = time.monotonic()
    ghdl.analyse_and_elaborate()

    vectors = BUILD / "vectors.txt"
    vectors.write_text("\n".join(gen_vectors.generate()) + "\n", newline="\n")

    programs = [p for p in discover_programs() if args.filter in p.name]
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        units = [
            pool.submit(check_unit_tb, ghdl, "tb_core_vectors",
                        {"VECTOR_FILE": vectors.resolve().as_posix()}),
            pool.submit(check_unit_tb, ghdl, "tb_uart_tx", {}),
            pool.submit(check_unit_tb, ghdl, "tb_de10lite", {}),
        ]
        runs = [pool.submit(run_program, ghdl, p, not args.no_trace) for p in programs]
        unit_results = [f.result() for f in units]
        prog_results = [f.result() for f in runs]

    failed = 0
    for o in unit_results:
        print(f"{'PASS' if o.ok else 'FAIL'}  {o.name:<24} {o.seconds:6.1f} s")
        for msg in o.messages:
            print(f"      {msg}")
        failed += not o.ok
    print()
    print(f"      {'program':<24} {'result':<22} {'cycles':>8} {'instr':>8} {'CPI':>6}")
    for o in prog_results:
        cpi = f"{o.cycles / o.instret:.3f}" if o.instret else "-"
        print(f"{'PASS' if o.ok else 'FAIL'}  {o.name:<24} {o.result:<22} "
              f"{o.cycles:>8} {o.instret:>8} {cpi:>6}  ({o.seconds:.1f} s)")
        for msg in o.messages:
            print(f"      {msg}")
        failed += not o.ok

    if args.report:
        write_report(args.report, prog_results)
    total = len(unit_results) + len(prog_results)
    print(f"\n{total - failed}/{total} passed in {time.monotonic() - t0:.0f} s")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
