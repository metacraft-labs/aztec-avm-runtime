#!/usr/bin/env python3
"""The ABI's function names, read out of one of the two places that declare them.

    _m41_abi_names.py --typescript ct-host/src/abi.ts   -> one name per line, sorted
    _m41_abi_names.py --rust       ct-writer/src/lib.rs -> one name per line, sorted

TWO DECLARATIONS, TWO READERS, AND NEITHER IS THE OTHER'S COPY. The point of reading both is that
they can DISAGREE, so each is parsed from its own source of truth:

  * TypeScript: the FOUR exported arrays -- `REQUIRED_EXPORTS`, `SOURCE_MAPPING_EXPORTS`,
    `JOIN_EXPORTS`, `SOURCE_STEP_EXPORTS`. They are separate on purpose (each milestone counts its
    own, so one milestone's addition cannot move another's assertion), and `ALL_REQUIRED_EXPORTS`
    is their concatenation. This reads the four and NOT the union, so a union that stopped
    including one of them would be caught rather than believed.

  * Rust: every `#[unsafe(no_mangle)]` attribute and the function it decorates. NOT
    `grep 'pub extern "C" fn'` -- twelve of the thirty-eight are `pub unsafe extern "C" fn` and
    that needle cannot see them, which is where the figure 26 came from.

A duplicate name in either source is an ERROR rather than a silently deduplicated entry: two lists
that both mention `ct_step` sum to one more than they contain, and the count is one of the things
being asserted.
"""

import re
import sys

TS_LISTS = (
    "REQUIRED_EXPORTS",
    "SOURCE_MAPPING_EXPORTS",
    "JOIN_EXPORTS",
    "SOURCE_STEP_EXPORTS",
)


def typescript(path):
    text = open(path, encoding="utf-8").read()
    names = []
    for list_name in TS_LISTS:
        m = re.search(
            r"export const %s\s*:\s*readonly string\[\]\s*=\s*(\[.*?\]);" % list_name,
            text,
            re.S,
        )
        if not m:
            print(f"_m41_abi_names: {path} has no {list_name}", file=sys.stderr)
            return None
        names.extend(re.findall(r"'([A-Za-z_][A-Za-z_0-9]*)'", m.group(1)))
    return names


def rust(path):
    text = open(path, encoding="utf-8").read()
    return re.findall(
        r"#\[unsafe\(no_mangle\)\]\s*\n\s*pub(?:\s+unsafe)?\s+extern\s+\"C\"\s+fn\s+"
        r"([A-Za-z_][A-Za-z_0-9]*)",
        text,
    )


def main(argv):
    if len(argv) != 3 or argv[1] not in ("--typescript", "--rust"):
        print("usage: _m41_abi_names.py --typescript|--rust <file>", file=sys.stderr)
        return 2
    names = (typescript if argv[1] == "--typescript" else rust)(argv[2])
    if names is None:
        return 1
    if not names:
        print(f"_m41_abi_names: {argv[2]} yielded no names at all", file=sys.stderr)
        return 1
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        print(f"_m41_abi_names: {argv[2]} names these twice: {dupes}", file=sys.stderr)
        return 1
    print("\n".join(sorted(names)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
