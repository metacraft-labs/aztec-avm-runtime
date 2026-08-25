#!/usr/bin/env python3
"""Decide whether M6's and M10's build evidence still describes the rebased tree.

BACKGROUND, because this file exists to replace a claim that stopped being true.

`verify_carry_set_applies_to_upstream_head` used to answer the deliverable's second
half — "and the result builds both the native and the wasm presets" — by requiring
the set of paths upstream had changed since the base and the set of paths the carry
set modifies to be DISJOINT. Disjointness is a SUFFICIENT condition for the build
evidence to transfer, and while it held the check needed nothing else.

It stopped holding. Upstream's `next` moved seven commits past the base and one of
them, `chore: remove labs-owned deploy workflows and scenario/kind/bench machinery`,
deletes 198 lines from the top-level `bootstrap.sh` — a file patch 2 also modifies.
(The count is the one `git diff -U0` reports for the single hunk, `@@ -876,198 @@`; an
earlier draft of this docstring said 204 and the shell check said 198.)
The intersection is no longer empty and the sufficient condition is unavailable.

What replaces it is NOT a looser version of the same test. It is a different, and
strictly narrower, argument with three conjuncts, each of which is computed here
rather than asserted in prose:

  1. NOTHING UPSTREAM CHANGED IS IN THE TREE THE EVIDENCE COMPILES. M6 and M10 both
     configure in `barretenberg/cpp`, and if upstream has changed no path under it
     then no translation unit, no CMake input and no test source that either build
     reads can differ between BASE + stack and TIP + stack. This is the conjunct
     that carries the weight, and it is the one that cannot be waived: an
     acknowledgement for a path under the build root is REFUSED here, so the class
     of overlap that would actually void the evidence has no way through.

  2. EVERY OVERLAPPING PATH IS ACKNOWLEDGED, AND THE ACKNOWLEDGEMENT IS PINNED TO
     THE EXACT CHANGE. `carry/overlap.json` names each one with the reason it does
     not reach either build, the patch that owns it, and the blob ids of upstream's
     versions of that path BEFORE and AFTER. Upstream touching the file again moves
     the `after` blob and the acknowledgement expires — which is the difference
     between a decision and a rubber stamp. An overlap with no entry is a failure.

  3. THE TWO SETS OF CHANGED LINES DO NOT MEET. Upstream's pre-image ranges and the
     carry set's pre-image ranges, both `-U0` and both relative to the base, must be
     disjoint per path. This is not about the build at all — it is what says the
     overlap is not even a rebase hazard, and it is measured from the two diffs.

If any conjunct fails the verdict is `void`, which means exactly what the old check
said it would: the transferred build evidence is no longer valid and M6 and M10 have
to be re-run against the rebased tree.

The decision is a pure function of a single JSON input so that the check can drive it
with SYNTHETIC inputs. An intersection test that can only return "empty" proves
nothing, and a decision procedure that has only ever been run on the real data has
the same problem one level up.

  usage: _carry_overlap.py --input <json>     (prints the verdict as JSON)
"""

from __future__ import annotations

import argparse
import json
import sys

# Rejection reasons. Tokens rather than sentences: the check asserts on the token, so
# a reworded message cannot turn a red into a green.
R_UNACKNOWLEDGED = "unacknowledged-overlap"
R_STALE = "acknowledgement-does-not-match-upstreams-current-change"
R_IN_BUILD_TREE = "overlap-inside-the-tree-the-evidence-compiles"
R_REGION = "upstream-and-carry-change-the-same-lines"
R_WRONG_OWNER = "acknowledgement-names-the-wrong-patch"
R_NOT_AN_OVERLAP = "acknowledged-path-is-not-in-the-overlap"


def _overlaps(a: list[list[int]], b: list[list[int]]) -> list[tuple[list[int], list[int]]]:
    """Every pair of ranges that meet. Inclusive on both ends."""
    hits = []
    for r in a:
        for s in b:
            if r[0] <= s[1] and s[0] <= r[1]:
                hits.append((r, s))
    return hits


def decide(inp: dict) -> dict:
    build_root = inp["build_root"]
    overlap = sorted(set(inp["overlap"]))
    ack = inp["ack"]
    up_blobs = inp["upstream_blobs"]
    up_ranges = inp["upstream_ranges"]
    carry_ranges = inp["carry_ranges"]
    owners = inp["patch_owners"]

    rejected: dict[str, list[str]] = {}

    def reject(path: str, reason: str) -> None:
        rejected.setdefault(path, [])
        if reason not in rejected[path]:
            rejected[path].append(reason)

    # An acknowledgement for a path that is not in the overlap is itself a failure:
    # it is either stale bookkeeping or an attempt to pre-authorise something.
    for path in sorted(ack):
        if path not in overlap:
            reject(path, R_NOT_AN_OVERLAP)

    for path in overlap:
        # (1) The conjunct that cannot be waived. Checked FIRST and independently of
        # the acknowledgement, so an entry in the file can never excuse it.
        if path == build_root or path.startswith(build_root.rstrip("/") + "/"):
            reject(path, R_IN_BUILD_TREE)

        entry = ack.get(path)
        if entry is None:
            reject(path, R_UNACKNOWLEDGED)
            continue

        # (2) Pinned to the exact change upstream made, by blob id at both ends.
        seen = up_blobs.get(path, {})
        if (entry.get("upstream_before") != seen.get("before")
                or entry.get("upstream_after") != seen.get("after")):
            reject(path, R_STALE)

        if entry.get("patch") != owners.get(path):
            reject(path, R_WRONG_OWNER)

        # (3) The regions.
        hits = _overlaps(up_ranges.get(path, []), carry_ranges.get(path, []))
        if hits:
            reject(path, R_REGION)

    # The build-root conjunct also applies to everything upstream changed, not only
    # to the intersection: a change under the build root voids the evidence whether
    # or not the carry set happens to touch the same file.
    in_build_tree = sorted(p for p in inp["upstream_paths"]
                           if p == build_root or p.startswith(build_root.rstrip("/") + "/"))

    return {
        "build_root": build_root,
        "overlap": overlap,
        "accepted": [p for p in overlap if p not in rejected],
        "rejected": rejected,
        "upstream_paths_in_build_tree": in_build_tree,
        "verdict": "void" if (rejected or in_build_tree) else "transfers",
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", required=True)
    args = ap.parse_args()
    out = decide(json.loads(open(args.input).read()))
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0 if out["verdict"] == "transfers" else 2


if __name__ == "__main__":
    sys.exit(main())
