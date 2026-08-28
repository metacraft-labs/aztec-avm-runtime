#!/usr/bin/env python3
"""Per-record comparison of two `ExecutionStep` transcripts.

    _m29_record_compare.py <left.records> <right.records> [excluded-field ...]

Each file is one record per line, in the shape `avm_differential steps` prints:

    ctx=<n> pc=<n> op=<n> l2=<n> da=<n> addr=0x<64 hex>

Prints `KEY<TAB>VALUE` lines. The comparison is over WHOLE LINES unless fields are named for
exclusion, in which case those fields are stripped from BOTH sides first and the number of them is
reported — so an exclusion is a number a check can assert is zero rather than a habit nobody counts.
M26's review is why: an exclusion list is where a bug hides.

M12 compares the same two things in Node with an inline snippet. This is that snippet, extracted so
M29 does not become a third copy of it, with three things added that the inline one did not have:

  * a LENGTH disagreement is its own key. Two lists of different lengths compared with `zip` agree
    over the prefix and report zero, which is how a dropped record becomes invisible.
  * the exclusion machinery, with its own count.
  * the first differing pair is printed, so a red assertion carries a diagnosis.
"""

import re
import sys

FIELDS = ("ctx", "pc", "op", "l2", "da", "addr")
PATTERN = re.compile(r"^ctx=(\S+) pc=(\S+) op=(\S+) l2=(\S+) da=(\S+) addr=(\S+)$")


def load(path):
    rows = []
    residue = []
    with open(path, encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.rstrip("\n")
            if not line:
                continue
            m = PATTERN.match(line)
            if m is None:
                residue.append(f"{lineno}:{line[:60]}")
                continue
            rows.append(dict(zip(FIELDS, m.groups())))
    return rows, residue


def render(row, excluded):
    return " ".join(f"{k}={row[k]}" for k in FIELDS if k not in excluded)


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: _m29_record_compare.py <left> <right> [excluded-field ...]", file=sys.stderr)
        return 2
    excluded = set(sys.argv[3:])
    unknown = excluded - set(FIELDS)
    if unknown:
        print(f"unknownExcludedField\t{','.join(sorted(unknown))}")
        return 3

    left, left_residue = load(sys.argv[1])
    right, right_residue = load(sys.argv[2])

    print(f"excluded\t{len(excluded)}")
    for field in sorted(excluded):
        print(f"excludedField\t{field}")
    print(f"leftRecords\t{len(left)}")
    print(f"rightRecords\t{len(right)}")
    print(f"leftResidue\t{len(left_residue)}")
    print(f"rightResidue\t{len(right_residue)}")
    for item in (left_residue + right_residue)[:5]:
        print(f"residueSample\t{item}")
    print(f"lengthDiffers\t{0 if len(left) == len(right) else 1}")

    mismatches = 0
    first = None
    for i in range(max(len(left), len(right))):
        a = render(left[i], excluded) if i < len(left) else "(absent)"
        b = render(right[i], excluded) if i < len(right) else "(absent)"
        if a != b:
            mismatches += 1
            if first is None:
                first = f"{i} left[{a}] right[{b}]"
    print(f"compared\t{min(len(left), len(right))}")
    print(f"mismatches\t{mismatches}")
    if first is not None:
        print(f"firstMismatch\t{first}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
