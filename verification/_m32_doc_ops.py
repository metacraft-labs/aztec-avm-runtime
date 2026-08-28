#!/usr/bin/env python3
"""Compare the write-up's §2 operation LIST against the built bundle's declarations, both ways.

    _m32_doc_ops.py '<json array of operation names>' <WORKER-NODE.md> [missing|extra|region]

    missing   operations the bundle declares that §2's list does not name   (default)
    extra     names §2's list carries that the bundle does not declare
    region    how many lines the list region has, so "both residues are empty" is not
              "the region was empty"

WHY A RESIDUE AND NOT A COUNT. `CAMPAIGN-BRIEF.md`: "write scanners that PRINT the residue rather
than counting the matches". A document that states "19 operations" and lists eighteen of them passes
a size comparison and fails this one, naming the missing one.

WHY A REGION AND NOT THE FILE — AND THIS IS M32'S REVIEW'S CORRECTION, ON THE CHECK THAT ADVERTISED
THE PROPERTY. The first version asked whether `` `name` `` occurred ANYWHERE in the document, and
`CAMPAIGN-BRIEF.md` already records what that costs: M24's OQ-6 check matched each figure as
`| <number> |` anywhere in the file, and swapping two rows left the document stating the reverse of
the data with 91 assertions and 0 failures. Measured here the same way: delete `containerBufferState`
from §2's list and the residue is still **empty**, because §4 mentions the operation in prose. The
check's own comment says "EVERY OPERATION NAMED, not a count only: a document that lost an operation
from the list while keeping the number would pass a size comparison" — which is exactly what it did.

The region is the §2 bullet that states the count: from the line naming
`operations** on the schema channel` to the next blank line. A missing anchor is reported as a
residue of its own rather than as an empty answer, and `region` exists so the caller can assert the
region was found and is not one line long.

The needle is still the backtick-quoted name, so a name that merely occurs in prose does not satisfy
it — the campaign's "a citation is the opposite of a dependency", applied to a document.
"""

import json
import re
import sys

ANCHOR = "operations** on the schema channel"


def region_of(doc):
    """The §2 bullet naming the operation count, as a list of lines. Empty if the anchor is gone.

    ONE BULLET, not "up to the next blank line": §2's bullets are not blank-separated, so a
    blank-line terminator swallowed the three bullets after it — sixteen lines instead of five —
    and `extra` then reported `subscribe`, `takeContainer`, `block`, `tx` and `trace` as names the
    bundle does not declare, which they are not, they are the NEIGHBOURS' subjects. A region that
    is too wide is the same defect as a needle asked of the whole file, one notch smaller.
    """
    lines = doc.split("\n")
    for i, line in enumerate(lines):
        if ANCHOR in line:
            out = [line]
            for candidate in lines[i + 1:]:
                if candidate.strip() == "" or candidate.lstrip().startswith("- "):
                    break
                out.append(candidate)
            return out
    return []


def main(ops_json, doc_path, mode="missing"):
    ops = json.loads(ops_json)
    doc = open(doc_path, encoding="utf-8").read()
    lines = region_of(doc)
    if mode == "region":
        print(len(lines))
        return
    if not lines:
        print("NO-REGION(%s)" % ANCHOR)
        return
    text = "\n".join(lines)
    if mode == "extra":
        # Every backtick-quoted lower-camel identifier in the region that the bundle does not
        # declare. Anchored to the region, so `worker_protocol.ts` and `AvmWorkerNodeSchema` in the
        # same bullet are not identifiers of this shape and do not register.
        named = set(re.findall(r"`([a-z][A-Za-z0-9]*)`", text))
        print(" ".join(sorted(named - set(ops))))
        return
    print(" ".join(op for op in ops if ("`%s`" % op) not in text))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3] if len(sys.argv) > 3 else "missing")
