#!/usr/bin/env python3
"""M33's protocol comparer, and the two readings it compares.

    _m33_protocol.py derive          <types.ts>            -> the WalletMessageType members, JSON
    _m33_protocol.py compare         <a.json> <b.json>     -> KEY<TAB>VALUE lines
    _m33_protocol.py strip-header    <file>                -> the file without its provenance header
    _m33_protocol.py disclosure-line <disclosure.ts>       -> the DISCLOSURE_LINE literal

WHY A COMPARER RATHER THAN A `diff`. The question "is our protocol upstream's" has three distinct
answers that a diff conflates and that a COUNT cannot see at all:

  * a member upstream declares and the bundle does not  -> MISSING
  * a member the bundle declares and upstream does not  -> EXTRA
  * a member whose NAME agrees and whose VALUE drifted  -> VALUE_DIFF

The third is the dangerous one, because it is the one that keeps the count and the name list intact.
`CAMPAIGN-BRIEF.md` has this shape twice — `_m32_doc_ops.py`, written to catch "same number, missing
entry", asking of the whole file instead of the row; and an OQ-6 check that matched each figure
anywhere in a document, so two swapped rows passed. So each answer is separate and each is asserted.

THE RESIDUE IS PRINTED, never counted: every disagreement is named.
"""

import json
import re
import sys

# `export enum WalletMessageType { NAME = 'value', ... }`, one member per line, with `/** ... */`
# and `//` comments between them. The class is `[^'"]` on the value side rather than `\w`, because a
# value is a hyphenated string (`aztec-wallet-key-exchange-request`) and `CAMPAIGN-BRIEF.md`'s
# needle family is full of classes that were one character too narrow — `[A-Za-z_]+` never matching
# `avm2`, `[A-Za-z0-9_/]+` never matching a path with a dot in it.
ENUM_RE = re.compile(r"export\s+enum\s+WalletMessageType\s*\{(.*?)\n\}", re.S)
MEMBER_RE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'([^']*)'\s*,?\s*$", re.M)

HEADER_BEGIN = "// BEGIN VENDORED-PROVENANCE"
HEADER_END = "// END VENDORED-PROVENANCE"


def derive(path):
    text = open(path, encoding="utf-8").read()
    body = ENUM_RE.search(text)
    if not body:
        sys.stderr.write("_m33_protocol.py: no `export enum WalletMessageType { ... }` in %s\n" % path)
        return 1
    region = body.group(1)
    members = {}
    for name, value in MEMBER_RE.findall(region):
        members[name] = value
    # THE RESIDUE. A line inside the enum body that is neither a member, a comment, nor blank is
    # printed as a failure rather than skipped: a scanner that silently drops what it cannot place
    # turns this derivation into an undercount, in the direction that reads as agreement.
    residue = []
    for line in region.split("\n"):
        s = line.strip()
        if not s or s.startswith("/*") or s.startswith("*") or s.startswith("//") or s.startswith("*/"):
            continue
        if MEMBER_RE.match(line):
            continue
        residue.append(s)
    if residue:
        sys.stderr.write("_m33_protocol.py: unclassified lines inside the enum body: %r\n" % residue)
        return 1
    json.dump(members, sys.stdout, sort_keys=True)
    sys.stdout.write("\n")
    return 0


def compare(a_path, b_path):
    a = json.load(open(a_path))
    b = json.load(open(b_path))
    missing = sorted(k for k in a if k not in b)
    extra = sorted(k for k in b if k not in a)
    diff = sorted(k for k in a if k in b and a[k] != b[k])
    print("SIZE\t%d" % len(a))
    print("BSIZE\t%d" % len(b))
    print("MISSING\t%s" % ",".join(missing))
    print("EXTRA\t%s" % ",".join(extra))
    print("VALUE_DIFF\t%s" % ",".join(diff))
    for k in diff:
        print("VALUE_DIFF_DETAIL\t%s\t%s\t%s" % (k, a[k], b[k]))
    return 0


def strip_header(path):
    text = open(path, encoding="utf-8").read()
    if HEADER_BEGIN not in text:
        sys.stdout.write(text)
        return 0
    before, rest = text.split(HEADER_BEGIN, 1)
    if HEADER_END not in rest:
        sys.stderr.write("_m33_protocol.py: unbalanced provenance header in %s\n" % path)
        return 1
    _, after = rest.split(HEADER_END, 1)
    sys.stdout.write(before + after.lstrip("\n"))
    return 0


def disclosure_line(path):
    """The `DISCLOSURE_LINE` literal, concatenated, as the module evaluates it."""
    text = open(path, encoding="utf-8").read()
    m = re.search(r"export const DISCLOSURE_LINE\s*=\s*(.*?);\n", text, re.S)
    if not m:
        sys.stdout.write("UNREADABLE\n")
        return 0
    expr = m.group(1)
    # The literal is a template piece plus two single-quoted pieces. Both spellings are collected;
    # `${PINNED_PROTOCOL_VERSION}` is substituted from the same file.
    version = re.search(r"export const PINNED_PROTOCOL_VERSION\s*=\s*'([^']*)'", text)
    parts = re.findall(r"`([^`]*)`|'([^']*)'", expr)
    out = "".join(a or b for a, b in parts)
    if version:
        out = out.replace("${PINNED_PROTOCOL_VERSION}", version.group(1))
    sys.stdout.write(out + "\n")
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    cmd = argv[1]
    if cmd == "derive":
        return derive(argv[2])
    if cmd == "compare":
        return compare(argv[2], argv[3])
    if cmd == "strip-header":
        return strip_header(argv[2])
    if cmd == "disclosure-line":
        return disclosure_line(argv[2])
    sys.stderr.write("_m33_protocol.py: unknown subcommand %r\n" % cmd)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
