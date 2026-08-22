#!/usr/bin/env python3
"""Compare two builds' compile databases command for command.

Used by verify_avm_wasm_default_off. It exists because "the compile commands are
identical" turned out to be false for this patch in a way that a whole-file diff
reports as 539 differing rows and says nothing more: `cmake/arch.cmake` changes

    add_compile_options(-fno-exceptions -fno-slp-vectorize)

into an if/else that adds `-fno-slp-vectorize` first and `-fno-exceptions` in the
else arm, so the two tokens SWAP POSITION on every command line in a default wasm
build. The flag multiset does not change, no flag is added or removed, and the
artefact is byte-identical -- but the command strings are not, and a check that
asserted they were would be asserting something untrue.

So this reports the difference structurally instead:

    rows_a / rows_b        entries per side
    keys_equal             yes if both sides compile the same set of files
    identical_rows         rows whose argument lists are equal
    differing_rows         rows whose argument lists are not
    multiset_equal_rows    of those, how many differ ONLY in token order
    added_or_removed       total tokens present on one side and not the other
    signature <n> <text>   one line per distinct difference shape, with its count

A "signature" is the ordered list of `a|b` pairs at the positions where the two
argument lists disagree. One signature covering every differing row is a single
systematic change; several signatures mean the change is not uniform and needs
looking at.

Usage: _db_compare.py <db-a> <root-a> <bdir-a> <db-b> <root-b> <bdir-b>
"""
import collections
import json
import shlex
import sys


def load(path, root, bdir):
    root = root.rstrip("/")

    def norm(x):
        return x.replace(root, "<TREE>").replace("/" + bdir + "/", "/<BUILD>/")

    # Keyed by (source, output), not by source: nine files in this build are
    # compiled twice, into two different objects, and keying by source alone
    # would silently drop one of each pair -- which would make the comparison
    # report on fewer rows than the build has and never say so.
    out = {}
    for e in json.load(open(path)):
        args = e.get("arguments") or shlex.split(e.get("command", ""))
        args = [norm(x) for x in args]
        obj = args[args.index("-o") + 1] if "-o" in args else ""
        out[(norm(e["file"]), obj)] = args
    return out


def main():
    if len(sys.argv) != 7:
        print(__doc__, file=sys.stderr)
        return 2
    a = load(sys.argv[1], sys.argv[2], sys.argv[3])
    b = load(sys.argv[4], sys.argv[5], sys.argv[6])

    print("rows_a=%d" % len(a))
    print("rows_b=%d" % len(b))
    print("keys_equal=%s" % ("yes" if set(a) == set(b) else "no"))

    identical = differing = multiset_equal = 0
    added_removed = 0
    sigs = collections.Counter()
    for k in sorted(set(a) & set(b)):
        xa, xb = a[k], b[k]
        if xa == xb:
            identical += 1
            continue
        differing += 1
        ca, cb = collections.Counter(xa), collections.Counter(xb)
        if ca == cb:
            multiset_equal += 1
        else:
            added_removed += sum(((ca - cb) + (cb - ca)).values())
        pairs = []
        for i in range(max(len(xa), len(xb))):
            ta = xa[i] if i < len(xa) else "<none>"
            tb = xb[i] if i < len(xb) else "<none>"
            if ta != tb:
                pairs.append("%s|%s" % (ta, tb))
        sigs["  ".join(pairs)] += 1

    print("identical_rows=%d" % identical)
    print("differing_rows=%d" % differing)
    print("multiset_equal_rows=%d" % multiset_equal)
    print("added_or_removed=%d" % added_removed)
    for sig, n in sigs.most_common():
        print("signature %d %s" % (n, sig))
    return 0


if __name__ == "__main__":
    sys.exit(main())
