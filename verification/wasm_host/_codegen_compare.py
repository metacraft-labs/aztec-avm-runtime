#!/usr/bin/env python3
"""Compare the machine code one function is compiled to in two object files.

The milestone's Goal and the campaign's Introduction table both say the patch
"produces identical codegen on 64-bit". That is a claim with a measurement behind
it, and the measurement disagrees: the VALUES are identical for every input the
function can receive, but the instructions are not, because widening first makes
the >= 2^32 case representable and the compiler has to materialise a high word the
truncating form cannot produce.

Rather than assert a whole-object byte comparison — which would also move for a
changed `__FILE__` string or a different build path — this disassembles both
objects and reports, per object:

    file <which> <path>
    text_bytes <which> <n>          the .text section size
    identical_objects <yes|no>      whole-file byte comparison, for the record
    insn <which> <n>                instructions inside the named function
    mnemonic <which> <name> <n>     per-mnemonic counts inside it

Usage: _codegen_compare.py <symbol-substring> <before.o> <after.o>
"""

import re
import subprocess
import sys


def disassemble(path: str) -> str:
    for tool in ("objdump", "llvm-objdump"):
        try:
            proc = subprocess.run([tool, "-d", "--demangle", path],
                                  capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if proc.returncode == 0:
            return proc.stdout
    sys.exit(f"could not disassemble {path}: no working objdump")


def function_body(dis: str, symbol: str) -> list[str]:
    """Lines of the first symbol whose header contains `symbol`."""
    body, inside = [], False
    for line in dis.splitlines():
        header = re.match(r"^[0-9a-f]+ <(.*)>:$", line.strip())
        if header:
            inside = symbol in header.group(1)
            continue
        if inside:
            if not line.strip():
                inside = False
                continue
            body.append(line)
    return body


def mnemonics(body: list[str]) -> dict[str, int]:
    counts: dict[str, int] = {}
    for line in body:
        # "  4e1: 48 c1 e6 20   shlq  $0x20, %rsi"
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        mnemonic = parts[2].strip().split()[0]
        counts[mnemonic] = counts.get(mnemonic, 0) + 1
    return counts


def text_bytes(path: str) -> int:
    for tool in ("size", "llvm-size"):
        try:
            proc = subprocess.run([tool, path], capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if proc.returncode == 0:
            rows = proc.stdout.strip().splitlines()
            if len(rows) >= 2:
                return int(rows[1].split()[0])
    sys.exit(f"could not read the .text size of {path}")


def main() -> int:
    if len(sys.argv) != 4:
        print("usage: _codegen_compare.py <symbol-substring> <before.o> <after.o>",
              file=sys.stderr)
        return 2
    symbol, before, after = sys.argv[1], sys.argv[2], sys.argv[3]

    with open(before, "rb") as fh:
        before_bytes = fh.read()
    with open(after, "rb") as fh:
        after_bytes = fh.read()
    print(f"identical_objects {'yes' if before_bytes == after_bytes else 'no'}")

    for which, path in (("before", before), ("after", after)):
        body = function_body(disassemble(path), symbol)
        if not body:
            sys.exit(f"no function matching '{symbol}' in {path}")
        print(f"file {which} {path}")
        print(f"text_bytes {which} {text_bytes(path)}")
        print(f"insn {which} {len(body)}")
        for name, count in sorted(mnemonics(body).items()):
            print(f"mnemonic {which} {name} {count}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
