#!/usr/bin/env python3
"""Every changed line in a ForkCheckpoint copy's diff that is not part of the desugaring.

M18 copies upstream's `ForkCheckpoint` (46 lines) instead of importing it, and claims the copy
differs from upstream in exactly one way: two parameter properties desugared into two field
declarations and two assignments, because Node's type stripper refuses parameter properties
(ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX) and this campaign runs its `.ts` sources.

"Exactly" is the whole claim, so the comparison is against the exact lines rather than against
fragments of them. THE VERSION THIS REPLACES MATCHED FRAGMENTS WITH `re.search`, so any changed
line CONTAINING `this.depth = depth` was excused — including `this.depth = depth + 1;`. That
mutation leaves the +6 / -4 line counts intact, so the exact-line comparison here is the only
thing standing between a corrupted copy and a green check. Found by mutating the copy during
M18's review.

  usage: _fork_checkpoint_residual.py <unified-diff>
         prints the residual count on stdout, one line per residual on stderr
"""

from __future__ import annotations

import sys
from collections import Counter

# The desugaring, line for line, exactly as a compiler emits it for two parameter properties.
REMOVED = Counter([
    "  private constructor(",
    "    private readonly fork: MerkleTreeCheckpointOperations,",
    "    public readonly depth: number,",
    "  ) {}",
])
ADDED = Counter([
    "  private readonly fork: MerkleTreeCheckpointOperations;",
    "  public readonly depth: number;",
    "",
    "  private constructor(fork: MerkleTreeCheckpointOperations, depth: number) {",
    "    this.fork = fork;",
    "    this.depth = depth;",
    "  }",
])


def residual(diff_text: str) -> list[str]:
    seen_removed: Counter[str] = Counter()
    seen_added: Counter[str] = Counter()
    for line in diff_text.splitlines():
        # A blank added line is `+` alone; it is a real changed line and `grep -E '^[+-][^+-]'`
        # drops it, which is how an earlier draft reported a residual it could not name.
        if line[:3] in ("---", "+++") or not line or line[0] not in "+-":
            continue
        (seen_removed if line[0] == "-" else seen_added)[line[1:]] += 1

    out: list[str] = []
    for label, seen, want in (("-", seen_removed, REMOVED), ("+", seen_added, ADDED)):
        for body, n in (seen - want).items():
            out.extend(["%s%s" % (label, body)] * n)
        for body, n in (want - seen).items():
            out.extend(["MISSING %s%s" % (label, body)] * n)
    return out


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = residual(open(sys.argv[1]).read())
    print(len(out))
    for o in out:
        print("      residual: %s" % o, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
