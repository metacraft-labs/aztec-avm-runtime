#!/usr/bin/env python3
"""Take barretenberg's OWN compile command for one translation unit and re-point it.

Every M5 compile — the native codegen comparison, the wasm32 diagnostic, and the
probes that use barretenberg's `uint256_t` — runs on the command line CMake
generated for `vm2/simulation/lib/contract_crypto.cpp`, not on a hand-written one.
That matters twice over: the probes then use the same headers, macros and standard
level as the real translation unit by construction, and the compiler is the one the
configure pinned (an absolute store path), not whatever is first on PATH.

Only these edits are made, and each for a stated reason:

  --source S        compile S instead of the recorded file (same flags, one variable)
  --output O        write O instead of the recorded object path
  --wasm SDK        swap the compiler for SDK/bin/clang++ and add
                    --target=wasm32-wasip1; drop -march=<x86> (clang rejects it for
                    wasm32) and -pthread (the wasi sysroot's stubs make it noise)
  --syntax-only     add -fsyntax-only and drop -c (nothing is emitted)
  --drop-werror     remove -Werror, to ask "does it warn?" rather than "does it fail?"
  --drop-flag F     remove F exactly
  --add F           append F

-fcolor-diagnostics is always dropped so the output can be matched literally.

Prints the resulting argv, shell-quoted, on one line.

Usage: _tu_command.py <tree> [options...]
"""

import json
import shlex
import sys

TU_SUFFIX = "vm2/simulation/lib/contract_crypto.cpp"


def main() -> int:
    args = sys.argv[1:]
    if not args:
        print(__doc__, file=sys.stderr)
        return 2
    tree = args.pop(0)

    source = output = wasm = None
    syntax_only = drop_werror = False
    drop, add = [], []
    while args:
        opt = args.pop(0)
        if opt == "--source":
            source = args.pop(0)
        elif opt == "--output":
            output = args.pop(0)
        elif opt == "--wasm":
            wasm = args.pop(0)
        elif opt == "--syntax-only":
            syntax_only = True
        elif opt == "--drop-werror":
            drop_werror = True
        elif opt == "--drop-flag":
            drop.append(args.pop(0))
        elif opt == "--add":
            add.append(args.pop(0))
        else:
            print(f"unknown option {opt}", file=sys.stderr)
            return 2

    path = f"{tree}/barretenberg/cpp/build/compile_commands.json"
    try:
        with open(path) as fh:
            entries = json.load(fh)
    except OSError as exc:
        print(f"cannot read {path}: {exc}", file=sys.stderr)
        return 2

    hits = [e for e in entries if e["file"].endswith(TU_SUFFIX)]
    if len(hits) != 1:
        print(f"expected exactly one {TU_SUFFIX} entry in {path}, got {len(hits)}",
              file=sys.stderr)
        return 2
    entry = hits[0]

    argv, want_output = [], False
    for a in shlex.split(entry["command"]):
        if want_output:
            want_output = False
            if not syntax_only:
                argv.append(output if output else a)
            continue
        if a == "-o":
            want_output = True
            if not syntax_only:
                argv.append(a)
            continue
        if a == "-c" and syntax_only:
            continue
        if a == "-fcolor-diagnostics":
            continue
        if a == "-Werror" and drop_werror:
            continue
        if a in drop:
            continue
        if wasm and (a.startswith("-march=") or a == "-pthread"):
            continue
        if a == entry["file"]:
            argv.append(source if source else a)
            continue
        argv.append(a)

    if wasm:
        argv[0] = f"{wasm}/bin/clang++"
        argv = argv[:1] + ["--target=wasm32-wasip1"] + argv[1:]
    if syntax_only:
        argv = argv[:1] + ["-fsyntax-only"] + argv[1:]
    argv += add

    print(" ".join(shlex.quote(a) for a in argv))
    return 0


if __name__ == "__main__":
    sys.exit(main())
