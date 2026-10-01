#!/usr/bin/env python3
"""Mutation arms for the transcript split of upstream's MemoryMerkleDB equivalence test.

  _perturb.py <in.tsv> <out.tsv> answer <Suite.Test> <method> <n>
      Flip the lowest bit of the LAST byte of the n-th (0-based) <method> record's recorded
      answer, in <Suite.Test> only. For a sibling path that is the low byte of its last field
      element (msgpack bin32, big-endian), so the value moves by one and stays a field element.
  _perturb.py <in.tsv> <out.tsv> root <Suite.Test> get_tree_info <n>
      Flip the lowest bit of the tree ROOT inside the n-th get_tree_info answer: the 32-byte value
      that follows the msgpack key "root" (fixstr a4 'root', bin8 c4 20). Exactly one such key per
      answer, or the arm refuses.
  _perturb.py <in.tsv> <out.tsv> args <Suite.Test> <method> <n>
      The same, on the recorded ARGUMENTS: the replaying side's input no longer matches.
  _perturb.py <in.tsv> <out.tsv> drop-last <Suite.Test>
      Remove that test's last record.

Prints the record it changed (test, seq, method) on stdout. Exits non-zero if nothing matched, so
a mutation arm can never pass by perturbing nothing.
"""
import sys

FIELD = {"args": 3, "answer": 4, "root": 4}
ROOT_KEY = "a4726f6f74" + "c420"


def flip_last(h):
    return h[:-2] + "%02x" % (int(h[-2:], 16) ^ 1)


def flip_root(h):
    if h.count(ROOT_KEY) != 1:
        sys.exit(f"expected exactly one root field in the answer, found {h.count(ROOT_KEY)}")
    end = h.index(ROOT_KEY) + len(ROOT_KEY) + 64
    return flip_last(h[:end]) + h[end:]


def main():
    a = sys.argv[1:]
    if len(a) < 4:
        sys.exit(__doc__)
    src, dst, mode, test = a[:4]
    rows = [l.rstrip("\n").split("\t") for l in open(src) if l.strip()]
    for r in rows:
        if len(r) != 5:
            sys.exit(f"malformed transcript row with {len(r)} fields")
    hit = None
    if mode in FIELD:
        if len(a) != 6:
            sys.exit(__doc__)
        method, n = a[4], int(a[5])
        seen = 0
        for r in rows:
            if r[0] == test and r[2] == method:
                if seen == n:
                    h = r[FIELD[mode]]
                    r[FIELD[mode]] = flip_root(h) if mode == "root" else flip_last(h)
                    hit = r
                    break
                seen += 1
    elif mode == "drop-last":
        idx = [i for i, r in enumerate(rows) if r[0] == test]
        if idx:
            hit = rows.pop(idx[-1])
    else:
        sys.exit(__doc__)
    if hit is None:
        sys.exit(f"no record matched {a[2:]}")
    with open(dst, "w") as f:
        for r in rows:
            f.write("\t".join(r) + "\n")
    print(f"{hit[0]} seq={hit[1]} method={hit[2]}")


if __name__ == "__main__":
    main()
