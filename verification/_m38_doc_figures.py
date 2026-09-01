#!/usr/bin/env python3
"""Compare every figure a document states against what the artefacts measure — by ROW.

    _m38_doc_figures.py <document> <row-needle>|<index>|<expected> ...

Each argument names ONE figure: a distinctive substring of the row that carries it, which bold
figure on that row it is (0-based), and the value the artefacts measured. The comparer prints

    BAD <needle> | <index> | expected <e> | got <g>
    MISSING <needle> | <index> | expected <e> | <why>
    OK <count>

and exits 0 always: the CALLER asserts, because a comparer that exited non-zero would make the
caller's assertion about the comparer's exit rather than about the document.

WHY BY ROW, AND WHY NOT WITH A REGULAR EXPRESSION. M24's OQ-6 review found a check that re-derived
every figure a table quoted and matched each one `anywhere in the file`: the median and the minimum
were swapped between two rows, the document said the reverse of the measurement, and the check
reported 91 assertions and 0 failures. Anchoring to the row is the remedy — and M38 then found that
the obvious way to write it in bash, `str_has_re "$DOC" 'subject.*\\*\\*N\\*\\*'`, is not anchored
either, because bash's `=~` has no `REG_NEWLINE` and its `.` matches a newline. This walks lines.

A row that matches more than one line is a MISSING with its own reason rather than a match on the
first: a needle that has stopped being distinctive is a needle that will eventually match the wrong
row, and reporting it is cheaper than discovering it.
"""

import re
import sys

BOLD = re.compile(r"\*\*([0-9][0-9,]*)\*\*")


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <document> <needle>|<index>|<expected> ...\n")
        return 2

    lines = open(sys.argv[1], encoding="utf8").read().split("\n")
    checked = 0

    for spec in sys.argv[2:]:
        parts = spec.split("|")
        if len(parts) != 3:
            print(f"MISSING {spec} | | | the specification is not <needle>|<index>|<expected>")
            continue
        needle, index_text, expected = parts[0], parts[1], parts[2]
        try:
            index = int(index_text)
        except ValueError:
            print(f"MISSING {needle} | {index_text} | expected {expected} | the index is not a number")
            continue

        hits = [line for line in lines if needle in line]
        if not hits:
            print(f"MISSING {needle} | {index} | expected {expected} | no row carries that needle")
            continue
        if len(hits) > 1:
            print(
                f"MISSING {needle} | {index} | expected {expected} | "
                f"{len(hits)} rows carry that needle, so it names no row"
            )
            continue

        figures = BOLD.findall(hits[0])
        if index >= len(figures):
            print(
                f"MISSING {needle} | {index} | expected {expected} | "
                f"the row carries {len(figures)} bold figure(s)"
            )
            continue

        got = figures[index].replace(",", "")
        want = expected.replace(",", "")
        checked += 1
        if got != want:
            print(f"BAD {needle} | {index} | expected {expected} | got {figures[index]}")

    print(f"OK {checked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
