#!/usr/bin/env python3
"""Re-target barretenberg's OWN native compile commands at wasm32 and record the
diagnostics.

The claim this exists to measure is PR.md's: `contract_crypto.cpp:61` is the only
place in `vm2` that shifts before widening. A grep is not evidence of that — the
compiler is. So every non-test translation unit CMake compiles for `vm2` is taken
out of `compile_commands.json` verbatim, retargeted `--target=wasm32-wasip1
-fsyntax-only`, and the diagnostics are counted.

Only three things are removed from each command line, and each for a reason:

  -o / -c            we are not producing an object.
  -march=<x86 name>  meaningless for wasm32; clang rejects it outright.
  -pthread           the wasi sysroot's pthread stubs make it noise here.
  -fcolor-diagnostics  so the output can be matched literally.

`-Werror` is KEPT unless --no-werror is passed, because whether the diagnostic is
fatal is exactly the question for a wasm build; the caller asks for both.

Output is line-oriented and machine-readable, one fact per line:

    scanned <n>
    failed <n>
    failed_file <path-relative-to-src>
    shift_overflow_files <n>
    shift_overflow <path-relative-to-src>:<line>:<col>
    other_warning_files <n>
    other_warning_file <path-relative-to-src> <first -W name>

Usage: _wasm32_syntax_scan.py <tree> <wasi-sdk-path> [--no-werror] [--only <substr>]
"""

import json
import shlex
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

SHIFT = "-Wshift-count-overflow"


def main() -> int:
    args = sys.argv[1:]
    if len(args) < 2:
        print("usage: _wasm32_syntax_scan.py <tree> <wasi-sdk> [--no-werror] [--only S]",
              file=sys.stderr)
        return 2
    tree, sdk = args[0], args[1]
    werror = "--no-werror" not in args
    only = None
    if "--only" in args:
        only = args[args.index("--only") + 1]

    ccpath = f"{tree}/barretenberg/cpp/build/compile_commands.json"
    try:
        with open(ccpath) as fh:
            cc = json.load(fh)
    except OSError as exc:
        print(f"cannot read {ccpath}: {exc}", file=sys.stderr)
        return 2

    tus = [e for e in cc
           if "/barretenberg/vm2/" in e["file"] and not e["file"].endswith(".test.cpp")]
    if only:
        tus = [e for e in tus if only in e["file"]]
    if not tus:
        print("no translation units selected", file=sys.stderr)
        return 2

    def rel(p: str) -> str:
        return p.split("/src/", 1)[-1]

    def run(entry):
        argv, skip = [], False
        for a in shlex.split(entry["command"]):
            if skip:
                skip = False
                continue
            if a == "-o":
                skip = True
                continue
            if a == "-c" or a.startswith("-march=") or a in ("-pthread", "-fcolor-diagnostics"):
                continue
            if a == "-Werror" and not werror:
                continue
            argv.append(a)
        argv[0] = f"{sdk}/bin/clang++"
        argv = argv[:1] + ["--target=wasm32-wasip1", "-fsyntax-only"] + argv[1:]
        proc = subprocess.run(argv, capture_output=True, text=True, cwd=entry["directory"])
        return entry["file"], proc.returncode, proc.stderr

    failed, shift_hits, other = [], [], []
    with ThreadPoolExecutor(max_workers=32) as pool:
        for path, rc, err in pool.map(run, tus):
            has_shift = SHIFT in err
            if has_shift:
                for line in err.splitlines():
                    if SHIFT in line:
                        # "<abs>:61:77: warning: shift count ..." -> "<rel>:61:77"
                        shift_hits.append(":".join(rel(line).split(":")[:3]))
            if rc != 0:
                failed.append(rel(path))
            names = [w for line in err.splitlines() if "[-W" in line
                     for w in [line.rsplit("[-W", 1)[-1].rstrip("]")]]
            names = [n for n in names if n != SHIFT[2:]]
            if names:
                other.append((rel(path), names[0]))

    print(f"scanned {len(tus)}")
    print(f"failed {len(failed)}")
    for f in sorted(failed):
        print(f"failed_file {f}")
    print(f"shift_overflow_files {len(set(h.split(':')[0] for h in shift_hits))}")
    for h in sorted(shift_hits):
        print(f"shift_overflow {h}")
    print(f"other_warning_files {len(set(o[0] for o in other))}")
    for f, n in sorted(set(other)):
        print(f"other_warning_file {f} {n}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
