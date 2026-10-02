#!/usr/bin/env python3
"""Synthesises the board top level with GHDL as a synthesisability check.

This is not a replacement for Quartus (no technology mapping, no timing),
but it proves that the RTL elaborates as hardware: the run fails if GHDL
rejects a construct, infers a latch, or does not recognise the ROM and the
four RAM byte lanes as memories. It does not check that their reads are
registered (what makes them fit M9K blocks); the one-cycle latency is
covered by the simulation instead. GHDL also lists the register file as a
small RAM; on the MAX 10 its asynchronous reads map to logic, see
rtl/core/rv32i_regfile.vhd.
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_tests import ROOT, RTL_SOURCES  # noqa: E402

TOP = "de10lite_top"
# Memories that must be inferred, matched by kind and geometry (width, depth)
# rather than by source file: GHDL 6 reports the program ROM once, in
# rom_dp.vhd, while GHDL 4 (the Ubuntu package used in CI) splits it into one
# ROM per read port and attributes them to the files that index the constant.
# Each entry is (kind, width, depth): (minimum count, maximum count).
EXPECTED = {
    ("ROM", 32, 4096): (1, 2),  # program ROM: one dual-port, or one per port
    ("RAM", 8, 4096): (4, 4),   # one RAM per byte lane
}
# Tolerant of the message prefix and name quoting, which vary between GHDL
# releases (CI uses the older Ubuntu package).
MEMORY_RE = re.compile(r"([\w.-]+\.vhd):\d+:\d+:\s*(?:note|info): found (ROM|RAM) "
                       r"\"?([^\",]+)\"?, width: (\d+) bits, depth: (\d+)")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ghdl", default=os.environ.get("GHDL", "ghdl"))
    args = parser.parse_args()
    if shutil.which(args.ghdl) is None:
        sys.exit(f"synth_check: '{args.ghdl}' not found")

    work = ROOT / "build" / "synth"
    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)

    def ghdl(*cmd: str) -> subprocess.CompletedProcess:
        return subprocess.run([args.ghdl, *cmd], cwd=work, capture_output=True,
                              encoding="utf-8", errors="replace")

    proc = ghdl("-a", "--std=08", *(str(ROOT / s) for s in RTL_SOURCES))
    if proc.returncode != 0:
        sys.exit(f"synth_check: analysis failed:\n{proc.stdout}{proc.stderr}")

    proc = ghdl("--synth", "--std=08", TOP)
    log = proc.stderr
    if proc.returncode != 0:
        sys.exit(f"synth_check: ghdl --synth {TOP} failed:\n{log}")
    netlist = work / f"{TOP}_synth.vhd"
    netlist.write_text(proc.stdout, newline="\n")

    memories = MEMORY_RE.findall(log)
    for file, kind, name, width, depth in memories:
        print(f"synth_check: {kind} {name} in {file}: {depth} x {width} bits")
    errors = []
    for (kind, width, depth), (lo, hi) in EXPECTED.items():
        found = sum(1 for m in memories
                    if (m[1], int(m[3]), int(m[4])) == (kind, width, depth))
        if not lo <= found <= hi:
            want = str(lo) if lo == hi else f"{lo}..{hi}"
            errors.append(f"{found} {depth} x {width} {kind}s inferred, expected {want}")
    errors += [f"latch: {line}" for line in log.splitlines() if "latch" in line.lower()]

    print(f"synth_check: {TOP}: netlist in {netlist.relative_to(ROOT).as_posix()}")
    for e in errors:
        print(f"synth_check: {e}")
    print(f"synth_check: {'FAILED' if errors else 'OK'}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
