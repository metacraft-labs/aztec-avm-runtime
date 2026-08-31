#!/usr/bin/env python3
"""Compose ONE sweep log out of several partial ones, so the summariser can total it.

    m37-sweep-splice.py <out.log> <milestones>=<log> [<milestones>=<log> ...]

    m37-sweep-splice.py /tmp/full.log \\
        m0-m11=~/.cache/aztec-m37-sweep-part1-m0-m11.log \\
        m12-m18=~/.cache/aztec-m37-sweep-part2-m12-m18.log \\
        m19-m36=~/.cache/aztec-m37-sweep-part4.log

WHY THIS EXISTS. M37's sweep ran in three parts, and each part's log contains milestones BEYOND
the range that part measured validly -- part 1 ran on into m12/m13 as the disk ran out, part 2 ran
on into m19..m24 after its own reclaim had deleted their inputs. Those trailing blocks are real
`########` markers with real (tiny) assertion counts, and concatenating the files whole would add
them to the total. The ranges have to be stated and enforced.

WHY IT REUSES THE SUMMARISER'S PARSER INSTEAD OF SCANNING FOR BLOCKS. The standing warning is
specific and was paid for: a splice that looks for block STARTS first matches every `rc=` line as a
second start, because `######## m0 rc=0 secs=12` also satisfies `^######## (m\\d+)\\s+\\S`. The
result was every milestone reported at 0. So END is tested before START here, exactly as
`m37-sweep-sum.py` does it, and the two files are imported from one another rather than kept in
step by hand.

WHAT IT REFUSES. Silence is the failure mode that matters, so this refuses rather than warns:

  * a requested milestone that appears in NO source log
  * a requested milestone that appears in MORE THAN ONE source log (the ranges overlap)
  * a block whose `start` has no `rc=` (a partial milestone, which is what a splice must never
    quietly include -- part 1's m14 is exactly this)

It writes a single `SWEEPDONE` at the end. That marker means "the requested set is present and
whole", which is the only thing the summariser needs it to mean.
"""

import os
import re
import sys

SUM = os.path.join(os.path.dirname(os.path.abspath(__file__)), "m37-sweep-sum.py")
sys.path.insert(0, os.path.dirname(SUM))
_mod = __import__("m37_sweep_sum") if False else None

# The summariser is not importable by name (it has dashes), so its two patterns are restated and
# then ASSERTED equal to the ones in its source, which is what keeps them in step.
START = re.compile(r"^######## (m\d+)\s+\S")
END = re.compile(r"^######## (m\d+) rc=(-?\d+) secs=(\d+)$")


def check_patterns_match_the_summariser() -> None:
    src = open(SUM, encoding="utf-8").read()
    for name, pat in (("START", START.pattern), ("END", END.pattern)):
        needle = f'{name} = re.compile(r"{pat}")'
        if needle not in src:
            raise SystemExit(
                f"REFUSING: this splicer's {name} pattern is not the one in m37-sweep-sum.py.\n"
                f"  wanted to find: {needle}\n"
                "Keeping two parsers in step by hand is how the block-start defect got in."
            )


def expand(spec: str) -> list:
    out = []
    for part in spec.split(","):
        if "-" in part:
            a, b = part.split("-", 1)
            for i in range(int(a[1:]), int(b[1:]) + 1):
                out.append(f"m{i}")
        else:
            out.append(part)
    return out


def blocks(path: str) -> dict:
    """Every COMPLETE milestone block in one log, as name -> list of lines."""
    found, cur, buf = {}, None, []
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        m = END.match(line)          # END FIRST. See the docstring.
        if m and cur == m.group(1):
            buf.append(line)
            found[cur] = buf
            cur, buf = None, []
            continue
        m2 = START.match(line)
        if m2 and not m:
            cur, buf = m2.group(1), [line]
            continue
        if cur is not None:
            buf.append(line)
    return found


def main() -> int:
    check_patterns_match_the_summariser()
    out_path, specs = sys.argv[1], sys.argv[2:]
    if not specs:
        raise SystemExit(__doc__)

    wanted, source_of, available = [], {}, {}
    for spec in specs:
        rng, _, log = spec.partition("=")
        log = os.path.expanduser(log)
        got = blocks(log)
        for name in expand(rng):
            if name in source_of:
                raise SystemExit(f"REFUSING: {name} was requested from two logs "
                                 f"({source_of[name]} and {log}). The ranges overlap.")
            source_of[name] = log
            wanted.append(name)
        available[log] = got

    missing = [n for n in wanted if n not in available[source_of[n]]]
    if missing:
        raise SystemExit(
            "REFUSING: these milestones have no COMPLETE block in the log they were asked of:\n  "
            + "\n  ".join(f"{n}  <- {source_of[n]}" for n in missing)
            + "\n(a block with a `start` and no `rc=` is partial and is never spliced in)")

    with open(out_path, "w", encoding="utf-8") as fh:
        fh.write("# COMPOSED by m37-sweep-splice.py — not a log any single run produced.\n")
        for spec in specs:
            fh.write(f"#   {spec}\n")
        for name in wanted:
            for line in available[source_of[name]][name]:
                fh.write(line + "\n")
        fh.write("SWEEPDONE\n")

    print(f"wrote {out_path}: {len(wanted)} milestones "
          f"({wanted[0]}..{wanted[-1]}) from {len(specs)} logs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
