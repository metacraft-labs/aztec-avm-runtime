#!/usr/bin/env python3
"""Compare every ABBREVIATED value a document quotes against the value the artefacts measure.

    _m40_doc_prefixes.py <document> <row-needle>|<index>|<measured> ...

`_m38_doc_figures.py` does this for BOLD NUMBERS. This does it for the other half of a write-up's
measurements: the `` `0x124ef545…` `` and `` `d53fc677…` `` tokens a document quotes because the
whole value is sixty-six characters and unreadable. Each argument names ONE such token: a
distinctive substring of the ROW that carries it, which backticked token on that row it is
(0-based), and the value the artefacts measured. The comparer prints

    BAD <needle> | <index> | measured <m> | quoted <q>
    MISSING <needle> | <index> | measured <m> | <why>
    OK <count>

and exits 0 always: the CALLER asserts, because a comparer that exited non-zero would make the
caller's assertion about the comparer's exit rather than about the document.

WHY THIS EXISTS AT ALL. M38's second sweep abort found that thirteen of a write-up's twenty-six
figures were "stated and compared by NOTHING, under a header claiming all of them were re-derived
on every run". The bold-figure comparer closed the numbers; the abbreviated hex values were still
prose. An abbreviation is a measurement with its tail cut off, not a decoration, and a digit that
rots in one is exactly as wrong as a digit that rots in a count.

A PREFIX RATHER THAN AN EQUALITY, and the ellipsis is required. `0x124ef545…` is a claim about the
first ten characters of a value; asserting equality against the whole would fail for a correct
document, and asserting containment would pass for a document quoting the empty string. So the
token must END in `…` (or `...`), which is refused as MISSING when it does not — a document that
quoted a whole value would otherwise be silently compared as a prefix of itself.

A row that matches more than one line is a MISSING with its own reason rather than a match on the
first: a needle that has stopped being distinctive is a needle that will eventually match the wrong
row, and reporting it is cheaper than discovering it.
"""

import re
import sys

TOKEN = re.compile(r"`([^`]+)`")
ELLIPSIS = ("…", "...")


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(f"usage: {sys.argv[0]} <document> <needle>|<index>|<measured> ...\n")
        return 2

    lines = open(sys.argv[1], encoding="utf8").read().split("\n")
    checked = 0

    for spec in sys.argv[2:]:
        parts = spec.split("|")
        if len(parts) != 3:
            print(f"MISSING {spec} | | | the specification is not <needle>|<index>|<measured>")
            continue
        needle, index_text, measured = parts[0], parts[1], parts[2]
        try:
            index = int(index_text)
        except ValueError:
            print(f"MISSING {needle} | {index_text} | measured {measured} | the index is not a number")
            continue

        hits = [line for line in lines if needle in line]
        if not hits:
            print(f"MISSING {needle} | {index} | measured {measured} | no row carries that needle")
            continue
        if len(hits) > 1:
            print(
                f"MISSING {needle} | {index} | measured {measured} | "
                f"{len(hits)} rows carry that needle, so it names no row"
            )
            continue

        tokens = TOKEN.findall(hits[0])
        if index >= len(tokens):
            print(
                f"MISSING {needle} | {index} | measured {measured} | "
                f"the row carries {len(tokens)} backticked token(s)"
            )
            continue

        quoted = tokens[index]
        if not quoted.endswith(ELLIPSIS):
            print(
                f"MISSING {needle} | {index} | measured {measured} | "
                f"the quoted token `{quoted}` does not end in an ellipsis, so it is not an abbreviation"
            )
            continue

        stem = quoted
        for e in ELLIPSIS:
            if stem.endswith(e):
                stem = stem[: -len(e)]
                break
        if not stem:
            print(f"MISSING {needle} | {index} | measured {measured} | the quoted token is only an ellipsis")
            continue

        checked += 1
        if not measured.startswith(stem):
            print(f"BAD {needle} | {index} | measured {measured} | quoted {quoted}")

    print(f"OK {checked}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
