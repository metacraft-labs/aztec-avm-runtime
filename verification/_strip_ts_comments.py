#!/usr/bin/env python3
"""Print the `.ts` sources under a directory with their comments removed.

    _strip_ts_comments.py <dir>

A CITATION IS THE OPPOSITE OF A DEPENDENCY, and a raw grep cannot tell them apart. This campaign
has met that twice: `verify_transcript_truncation_detection_uniform` counted a comment mentioning
`require_complete_transcript` as a call, and `verify_ts_simulator_configuration_named_not_inverted`
went red on the sentence explaining why a default is not read from `process.env`. It met it a third
time in M24: `test_dropped_column_awareness_asserted` asserts that ct-host relies on no
`private constructor`, and the count came out 1 — from the comment at the top of `config.ts`
explaining why one is NOT used.

So an assertion of the form "this construct does not appear in the code" is taken over code.

WHAT THIS DOES NOT DO, stated because a scanner that overclaims is worse than none: it removes
whole-line `//` comments and `/* … */` blocks, and it does NOT understand a `//` inside a string
literal, a regex literal or a template literal. The import-graph walker's own defect was exactly
that — `const u = 'http://host'` began a comment and ate the line — and it pointed the DANGEROUS
way there because every assertion over it was an absence. Here it points the SAFE way: this file's
callers assert an absence over the OUTPUT, so a line wrongly dropped can only make an absence
easier to satisfy… which is the dangerous direction after all. Hence the caller is required to
assert that the stripper left a substantial number of lines AND that it left a named line the
subject depends on, and only whole-line `//` comments are dropped — a `//` that begins a line
inside a template literal would be needed to fool it.
"""

import os
import re
import sys


def strip(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return "\n".join(l for l in src.split("\n") if not l.lstrip().startswith("//"))


def main(root: str) -> int:
    out = []
    for dirpath, _, files in os.walk(root):
        for name in sorted(files):
            if name.endswith(".ts"):
                with open(os.path.join(dirpath, name), encoding="utf-8") as fh:
                    out.append(strip(fh.read()))
    if not out:
        sys.stderr.write("_strip_ts_comments: no .ts sources under %s\n" % root)
        return 1
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.stderr.write(__doc__)
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
