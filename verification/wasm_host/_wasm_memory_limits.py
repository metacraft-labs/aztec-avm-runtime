#!/usr/bin/env python3
"""Print the declared limits of a wasm module's IMPORTED memory: "<module> <name> <min> <max>".

barretenberg links every wasm artefact `--import-memory`, so a runtime that cannot
supply an imported memory from the command line (wasmtime, all versions that still
load these modules) needs the import satisfied statically. Doing that requires the
declared minimum: a memory smaller than it makes instantiation fail with a message
that reads like a toolchain problem, and a memory larger than it is a different
module from the one that shipped.

The limits are read out of the binary rather than guessed, and rather than asked of
`WebAssembly.Module.imports()`, which does not report them.

Exit 2 on an unreadable or non-wasm file, 3 when the module imports no memory --
which for these binaries means the artefact is not the one the caller thinks it is.
"""

import sys


def read(path):
    with open(path, "rb") as fh:
        b = fh.read()
    if b[:4] != b"\x00asm":
        raise ValueError("not a wasm module (bad magic)")
    o = 8
    n = len(b)

    def leb():
        nonlocal o
        result = 0
        shift = 0
        while True:
            byte = b[o]
            o += 1
            result |= (byte & 0x7F) << shift
            shift += 7
            if not byte & 0x80:
                return result

    def name():
        nonlocal o
        k = leb()
        s = b[o : o + k].decode("utf-8", "replace")
        o += k
        return s

    while o < n:
        sec = b[o]
        o += 1
        size = leb()
        end = o + size
        if sec == 2:
            count = leb()
            for _ in range(count):
                mod = name()
                fld = name()
                kind = b[o]
                o += 1
                if kind == 0x00:
                    leb()
                elif kind == 0x01:
                    o += 1
                    flags = b[o]
                    o += 1
                    leb()
                    if flags & 0x01:
                        leb()
                elif kind == 0x02:
                    flags = b[o]
                    o += 1
                    mn = leb()
                    mx = leb() if flags & 0x01 else 65536
                    return mod, fld, mn, mx
                elif kind == 0x03:
                    o += 2
                else:
                    raise ValueError("unknown import kind %d" % kind)
        o = end
    return None


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: _wasm_memory_limits.py <module.wasm>\n")
        return 2
    try:
        got = read(argv[1])
    except (OSError, ValueError, IndexError) as exc:
        sys.stderr.write("_wasm_memory_limits.py: %s: %s\n" % (argv[1], exc))
        return 2
    if got is None:
        sys.stderr.write("_wasm_memory_limits.py: %s imports no memory\n" % argv[1])
        return 3
    print("%s %s %d %d" % got)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
