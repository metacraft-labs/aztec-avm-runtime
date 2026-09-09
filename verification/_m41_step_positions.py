#!/usr/bin/env python3
"""The step positions a container carries, and whether they are the ones a driver asked for.

    _m41_step_positions.py <ct-print-full.json> [expected.json]

With one argument, prints `STEP <index> <path> <line> <column>` rows and `STEPS <n>`.
With two, also compares against the driver's own expectation and prints `MATCH ok` or one
`MISMATCH <index> <expected> <actual>` row per disagreement, exiting non-zero.

WHY THE COMPARISON IS PER-STEP AND NOT A COUNT. A count is satisfied by a container with the right
number of wrong steps -- and that is not hypothetical here: the first Path B build produced exactly
the right number of steps with EVERY COLUMN ONE TOO HIGH, because the Nim ABI takes a column DELTA
from a step that already sits at column 1. Nothing refused it. A column one to the right is a real
position in a real line, so a reader has no way to object; only a comparison against what was asked
for can see it. `column: null` in the expectation means the step carries no column at all, which is
a different state from column 1 and is compared as such.

A decode with no steps is a non-zero exit rather than an empty report: "the container has no steps"
and "this file is not a decode" must not read the same.
"""

import json
import sys


def positions(doc):
    out = []
    for e in doc.get("events") or []:
        if e.get("kind") != "step":
            continue
        out.append(
            {
                "index": e.get("step_index"),
                "path": e.get("path"),
                "line": e.get("line"),
                "column": e.get("column"),
            }
        )
    return out


def main(argv):
    doc = json.load(open(argv[1], encoding="utf-8"))
    steps = positions(doc)
    for s in steps:
        col = "-" if s["column"] is None else s["column"]
        print(f"STEP\t{s['index']}\t{s['path']}\t{s['line']}\t{col}")
    print(f"STEPS\t{len(steps)}")
    if not steps:
        print(f"_m41_step_positions: {argv[1]} decodes to no steps at all", file=sys.stderr)
        return 1

    if len(argv) < 3:
        return 0

    expected = json.load(open(argv[2], encoding="utf-8"))
    rc = 0
    if len(expected) != len(steps):
        print(f"MISMATCH\tcount\t{len(expected)}\t{len(steps)}")
        rc = 1
    for i, want in enumerate(expected):
        if i >= len(steps):
            print(f"MISMATCH\t{i}\t{json.dumps(want)}\t<absent>")
            rc = 1
            continue
        got = steps[i]
        if (
            want["path"] != got["path"]
            or want["line"] != got["line"]
            or want["column"] != got["column"]
        ):
            print(
                f"MISMATCH\t{i}\t"
                f"{want['path']}:{want['line']}:{want['column']}\t"
                f"{got['path']}:{got['line']}:{got['column']}"
            )
            rc = 1
    print("MATCH\tok" if rc == 0 else "MATCH\tfailed")
    return rc


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        print("usage: _m41_step_positions.py <ct-print-full.json> [expected.json]", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv))
