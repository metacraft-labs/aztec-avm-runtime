#!/usr/bin/env python3
"""The Nim packages a trace-format-nim revision's `.nimble` requires, as that revision pins them.

    _ct_print_nim_deps.py <flake.lock>  ->  one "<owner> <repo> <rev> <narHash>" line per package

`codetracer_trace_format.nimble` requires `stew` and `results` (and `stew` needs `unittest2`); the
writer repository's own `flake.lock` declares the revisions as `flake = false` inputs. This reads
them from the lock of the revision being built, so a revision is built against the dependency
sources ITS authors pinned and this repository never types a second copy of a sha. A file rather
than a heredoc for the reason `_ct_print_anchors.py` gives.

A missing input exits non-zero and prints nothing: the caller refuses by name rather than building
with a dependency set it guessed.
"""

import json
import sys

INPUTS = ("nim-stew", "nim-results", "nim-unittest2")


def main(path):
    nodes = json.load(open(path, encoding="utf-8"))["nodes"]
    lines = []
    for name in INPUTS:
        locked = (nodes.get(name) or {}).get("locked") or {}
        fields = [locked.get(k, "") for k in ("owner", "repo", "rev", "narHash")]
        if locked.get("type") != "github" or not all(fields):
            print(f"{path}: input {name} is not a complete github lock entry", file=sys.stderr)
            return 1
        lines.append(" ".join(fields))
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
