#!/usr/bin/env python3
"""Classify every line of a vendored file against its upstream original.

    _vendor_lines.py <upstream-file> <vendored-file> [<declared-added-file>]

WHY THIS EXISTS, AND IT IS M22'S LESSON RATHER THAN A NEW ONE. `check-drift` asserts only the
DIRECTION of a vendored file's difference — a file declared `none` must be byte-identical, a file
declared with an edit class must differ — and never pins what the difference IS. M22's review then
measured the consequence: `this.dateProvider = dateProvider;` -> `this.dateProvider = log;` is a
real corruption of an upstream constructor, and the vendoring check reported **59 assertions, 0
failures** on it, because the classifier accepted added lines BY SHAPE and a one-for-one swap keeps
every shape and every count.

So the property this file computes is the one a shape cannot fake:

    every line of the vendored file is EITHER byte-identical to some line of the upstream file,
    OR one of the lines the check declares as added.

A line corrupted in place is neither, and comes out as `UNDECLARED`. The check asserts that set is
empty, which is a pin on the CONTENT rather than on the count.

**AND MEMBERSHIP IS NOT ENOUGH — TWO HOLES WERE MEASURED, NOT ARGUED.** M26's review put a scratch
copy through the first version of this file and both of these passed **every** assertion the check
makes, with `VENDORED_LINES` computed and printed but never compared:

  * **Duplication.** One retained line repeated twenty times reported
    `VENDORED_LINES 125  RETAINED 124  ADDED 1  DROPPED 1` against a baseline of
    `106 / 105 / 1 / 1`, no `UNDECLARED`. A `set` answers "is this line upstream's" and has no
    opinion about how many times it may appear.
  * **Reordering.** Swapping two adjacent retained lines produced counts **byte-identical** to the
    baseline. Moving a statement from one method to another is a real corruption that membership
    cannot see at all.

So this file now computes the ORDER too: with the declared-added lines removed, what is left must
be an in-order subsequence of the upstream original. A greedy walk decides it (greedy subsequence
matching is exact), and the first line that cannot be placed is PRINTED rather than counted, which
is the shape this campaign asks a scanner for. `VENDORED_LINES` is asserted by the caller now, so
duplication has a number to fail against as well.

Output, `KEY<TAB>VALUE`:

    UPSTREAM_LINES  <n>
    VENDORED_LINES  <n>
    RETAINED        <n>   vendored lines that appear verbatim upstream
    ADDED           <n>   vendored lines that do not
    DROPPED         <n>   upstream lines that appear in no vendored line
    ORDERED         <0|1> the retained lines are an in-order subsequence of the upstream original
    OUTOFORDER      <text>       the first retained line the in-order walk could not place
    ADDED_LINE      <text>       one per added line, in file order
    UNDECLARED      <text>       one per added line the caller did not declare
    DROPPED_LINE    <text>       one per dropped line, in file order

Blank lines and the provenance header are excluded from every count: the header is a tool's output
and a blank line carries no content, so counting either would make the numbers depend on formatting
rather than on code. `check-drift` strips the header the same way.
"""

import sys

BEGIN = "BEGIN VENDORED-PROVENANCE"
END = "END VENDORED-PROVENANCE"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read().splitlines()


def strip_header(lines):
    out, skipping = [], False
    for ln in lines:
        if BEGIN in ln:
            skipping = True
            continue
        if END in ln:
            skipping = False
            continue
        if not skipping:
            out.append(ln)
    return out


def content(lines):
    return [ln for ln in lines if ln.strip() != ""]


def main(upstream_path, vendored_path, declared_path=None):
    up = content(strip_header(read(upstream_path)))
    ven = content(strip_header(read(vendored_path)))
    declared = set()
    if declared_path:
        declared = {ln for ln in read(declared_path) if ln.strip() != ""}

    up_set = set(up)
    ven_set = set(ven)

    added = [ln for ln in ven if ln not in up_set]
    dropped = [ln for ln in up if ln not in ven_set]
    undeclared = [ln for ln in added if ln not in declared]

    # THE ORDER, and it is what closes the two holes the docstring measures. Everything the
    # vendored file kept must still be walkable through the upstream original from top to bottom:
    # a greedy scan is exact for subsequence matching, so a line that cannot be placed is a real
    # move or a real duplicate rather than an artefact of the search.
    retained_seq = [ln for ln in ven if ln in up_set]
    i, out_of_order = 0, None
    for ln in retained_seq:
        while i < len(up) and up[i] != ln:
            i += 1
        if i == len(up):
            out_of_order = ln
            break
        i += 1

    print("UPSTREAM_LINES\t%d" % len(up))
    print("VENDORED_LINES\t%d" % len(ven))
    print("RETAINED\t%d" % (len(ven) - len(added)))
    print("ADDED\t%d" % len(added))
    print("DROPPED\t%d" % len(dropped))
    print("ORDERED\t%d" % (0 if out_of_order is not None else 1))
    if out_of_order is not None:
        print("OUTOFORDER\t%s" % out_of_order)
    for ln in added:
        print("ADDED_LINE\t%s" % ln)
    for ln in undeclared:
        print("UNDECLARED\t%s" % ln)
    for ln in dropped:
        print("DROPPED_LINE\t%s" % ln)
    return 0


if __name__ == "__main__":
    if len(sys.argv) not in (3, 4):
        print("usage: _vendor_lines.py <upstream> <vendored> [<declared-added>]", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(*sys.argv[1:]))
