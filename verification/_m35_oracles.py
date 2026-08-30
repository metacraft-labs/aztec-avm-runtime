#!/usr/bin/env python3
"""The oracle registry, as a re-derivation rather than as a remembered number.

    _m35_oracles.py <path to an oracle_registry.ts> [<path to a legacy_oracle_registry.ts>]

Prints `KEY<TAB>VALUE` lines:

    COUNT        <n>                    entries in ORACLE_REGISTRY
    SCOPE        <scope>\\t<n>           one line per scope, derived from the names
    ORACLE       <name>\\t<scope>\\t<method>\\t<params>\\t<returns>
    LEGACY_COUNT <n>                    entries in LEGACY_ORACLE_REGISTRY, if a path was given
    LEGACY       <name>\\t<modernOracle>
    RESIDUE      <n>                    depth-0 tokens that are NOT a key (asserted to be the
                                        entry VALUES and nothing else)
    RESIDUE_TOKEN <token>               each of them, PRINTED rather than counted away
    UNBALANCED   <0|1>                  the scanner never found the object's closing brace

WHY A STRUCTURAL PARSE AND NOT A GREP.

`CAMPAIGN-BRIEF.md`: *"when the derivation IS the number, run the derivation twice, differently,
before believing it"* — and here the derivation IS the number twice over, because the milestone's
own deliverable is "the registry count re-derived, never remembered" and because the coverage check
partitions that count into an implemented set and a refusing set.

A `grep -c` over `^  <name>: makeEntry(` gives the right answer at this anchor and is one upstream
reformat away from giving a wrong one, in either direction: a `// prettier-ignore` that puts two
entries on one line undercounts, and a nested object literal that happens to indent a member by two
spaces overcounts. `grep -c '^  [A-Za-z0-9_]*:'` over the whole file gives **70** at this anchor,
and the two extra are members of an interface below the object — the second form on this file's own
defect list, wearing a count instead of a comparison.

So this walks the object: it finds `export const ORACLE_REGISTRY = {`, scans to the matching close
brace with a reader that knows about `'`, `"`, `` ` ``, `//` and `/* */`, and takes the identifiers
at depth 1 that are followed by a `:`. **Everything else it sees at depth 1 is PRINTED as residue**
— which is M22's rule for scanners: print what you cannot place rather than counting what you can.
At this anchor the residue is exactly one `makeEntry` token per entry, which is the value half of
each pair, and the caller asserts that.

THE SCOPE SPLIT IS DERIVED FROM THE NAMES, not typed. `buildACIRCallback` parses every key with
`/^aztec_(\\w+?)_(.+)$/` and refuses a name that does not match, so the same split is a property of
the wire rather than of this file's opinion — and a key that does not follow the convention is
reported as scope `?`, which the caller asserts is absent.
"""

import re
import sys
from collections import Counter

NAME_RE = re.compile(r"^aztec_(\w+?)_(.+)$")


def scan_object(src: str, decl: str):
    """The balanced region of `decl`'s object literal, string- and comment-aware."""
    m = re.search(re.escape(decl), src)
    if not m:
        return None, True
    i = src.index("{", m.end() - 1)
    start, depth, in_s, in_c = i, 0, None, None
    while i < len(src):
        c = src[i]
        if in_c:
            if in_c == "//" and c == "\n":
                in_c = None
            elif in_c == "/*" and src[i : i + 2] == "*/":
                in_c = None
                i += 1
        elif in_s:
            if c == "\\":
                i += 1
            elif c == in_s:
                in_s = None
        else:
            if src[i : i + 2] == "//":
                in_c = "//"
                i += 1
            elif src[i : i + 2] == "/*":
                in_c = "/*"
                i += 1
            elif c in "\"'`":
                in_s = c
            elif c in "{([":
                depth += 1
            elif c in ")]}":
                depth -= 1
                if depth == 0:
                    return src[start + 1 : i], False
        i += 1
    return None, True


def top_level(region: str):
    """(keys, residue) at depth 0 of a already-unwrapped object literal body."""
    keys, residue, tok = [], [], ""
    i, depth, in_s, in_c = 0, 0, None, None
    while i < len(region):
        c = region[i]
        if in_c:
            if in_c == "//" and c == "\n":
                in_c = None
            elif in_c == "/*" and region[i : i + 2] == "*/":
                in_c = None
                i += 1
        elif in_s:
            if c == "\\":
                i += 1
            elif c == in_s:
                in_s = None
        else:
            if region[i : i + 2] == "//":
                in_c = "//"
                i += 1
            elif region[i : i + 2] == "/*":
                in_c = "/*"
                i += 1
            elif c in "\"'`":
                in_s = c
            elif c in "{([":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif depth == 0:
                if re.match(r"[A-Za-z0-9_$]", c):
                    tok += c
                elif c == ":":
                    if tok:
                        keys.append(tok)
                    tok = ""
                else:
                    if tok:
                        residue.append(tok)
                    tok = ""
                    if not c.isspace() and c != ",":
                        residue.append("CHAR:" + repr(c))
        i += 1
    if tok:
        residue.append(tok)
    return keys, residue


def outermost_ephemeral(region: str, keys):
    """Entries whose `returnType:` TEXT names `EPHEMERAL_ARRAY`, i.e. where the combinator is the
    OUTERMOST return type.

    This is deliberately a WEAKER derivation than reading the built mapping's `label`, and the two
    are compared rather than assumed equal: a nested case — an `EphemeralArray` inside an `Option`,
    which `aztec_utl_getFactCollection` is — is invisible here and visible there. Printing both lets
    the caller assert the SUBSET relation and NAME the residue, instead of asserting an equality that
    is false or a floor that both would pass while dead.
    """
    out = []
    for i, k in enumerate(keys):
        m = re.search(re.escape(k) + r":\s*makeEntry\(", region)
        if not m:
            continue
        nxt = None
        for j in keys[i + 1:]:
            n = re.search(re.escape(j) + r":\s*makeEntry\(", region)
            if n:
                nxt = n.start()
                break
        body = region[m.start(): nxt if nxt is not None else len(region)]
        rt = re.search(r"returnType:\s*([^\n]*)", body)
        if rt and "EPHEMERAL_ARRAY" in rt.group(1):
            out.append(k)
    return out


def entry_shapes(region: str, keys):
    """`params`/`returnType` presence per entry, read from each entry's own literal."""
    shapes = {}
    for k in keys:
        m = re.search(re.escape(k) + r":\s*makeEntry\(", region)
        if not m:
            shapes[k] = ("?", "?")
            continue
        body, bad = scan_object(region[m.start() :], k + ": makeEntry(")
        if bad or body is None:
            shapes[k] = ("?", "?")
            continue
        sub_keys, _ = top_level(body)
        shapes[k] = ("yes" if "params" in sub_keys else "no",
                     "yes" if "returnType" in sub_keys else "no")
    return shapes


def main(argv):
    src = open(argv[1], encoding="utf-8").read()
    region, bad = scan_object(src, "export const ORACLE_REGISTRY = {")
    print("UNBALANCED\t%d" % (1 if bad or region is None else 0))
    if region is None:
        return 1
    keys, residue = top_level(region)
    shapes = entry_shapes(region, keys)
    scopes = Counter()
    print("COUNT\t%d" % len(keys))
    for k in keys:
        m = NAME_RE.match(k)
        scope, method = (m.group(1), m.group(2)) if m else ("?", k)
        scopes[scope] += 1
        p, r = shapes[k]
        print("ORACLE\t%s\t%s\t%s\t%s\t%s" % (k, scope, method, p, r))
    for scope in sorted(scopes):
        print("SCOPE\t%s\t%d" % (scope, scopes[scope]))
    print("RESIDUE\t%d" % len(residue))
    for t in residue:
        print("RESIDUE_TOKEN\t%s" % t)
    outer = outermost_ephemeral(region, keys)
    print("OUTERMOST_EPHEMERAL\t%d" % len(outer))
    for k in outer:
        print("OUTERMOST_EPHEMERAL_ORACLE\t%s" % k)

    if len(argv) > 2:
        lsrc = open(argv[2], encoding="utf-8").read()
        lregion, lbad = scan_object(lsrc, "export const LEGACY_ORACLE_REGISTRY: Record<string, LegacyOracleEntry> = {")
        if lregion is None:
            print("LEGACY_UNBALANCED\t1")
            return 1
        lkeys, lresidue = top_level(lregion)
        print("LEGACY_COUNT\t%d" % len(lkeys))
        for k in lkeys:
            m = re.search(re.escape(k) + r":\s*legacyOracle\(\{\s*modernOracle:\s*'([^']+)'", lregion)
            print("LEGACY\t%s\t%s" % (k, m.group(1) if m else "?"))
        print("LEGACY_RESIDUE\t%d" % len(lresidue))
        for t in lresidue:
            print("LEGACY_RESIDUE_TOKEN\t%s" % t)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
