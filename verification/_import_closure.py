#!/usr/bin/env python3
"""The transitive relative-import closure of a TypeScript entry point, as a number.

    _import_closure.py <root> <entry-relative-to-root>

Prints `KEY<TAB>VALUE` lines, and a `FILE<TAB><path><TAB><lines>` line per file so the total can be
audited rather than believed.

WHY THIS EXISTS RATHER THAN A `grep -c import`. Three things have to be right for a closure number
to mean anything, and each of them has bitten this campaign:

  1. **The residue is PRINTED, not dropped.** A relative specifier the walker cannot resolve is
     reported as `UNRESOLVED_SPEC`, and the caller asserts the count is zero. A walker that
     silently skips what it cannot place turns a containment measurement into an undercount, which
     is the direction that reads as good news.

  2. **Comments are stripped WITHOUT eating string literals.** The import-graph walker M18 used
     scanned for `//` unconditionally, so a `//` inside a string began a comment and ate the rest
     of the line: `const u = 'http://host'; import 'koa';` reported no imports. Every assertion
     written against it was an ABSENCE, so the failure pointed the dangerous way. This scanner
     tracks quote state.

  3. **`export … from` is an import.** A barrel file that only re-exports would otherwise look
     like a leaf, and `fixtures/index.ts` is exactly that shape upstream.

Package specifiers (`@aztec/…`, `assert`, `lodash.merge`) are dependencies, not vendoring cost.
They are collected and printed separately so the reader can see what an adoption would need.
"""

import os
import re
import sys

# THE CLAUSE SPANS LINES AND THE FIRST DRAFT OF THIS REGEX DID NOT.
#
# `[^;\n]*?` between `import` and `from` looks harmless and silently loses every multi-line import
# — which upstream writes constantly, because prettier wraps a brace list past 120 columns. It cost
# **18 files and 2,338 lines** off the closure the first time this ran (47/8,083 against the true
# 65/10,421), and it lost them in the direction that reads as good news. The class is `[^;]` with
# `re.S` semantics instead: a clause may contain newlines, and a `;` ends it.
IMPORT_RE = re.compile(r"""(?:^|[\n;}])\s*(?:import|export)\b[^;]*?\bfrom\s+['"]([^'"]+)['"]""")
BARE_IMPORT_RE = re.compile(r"""(?:^|[\n;}])\s*import\s+['"]([^'"]+)['"]""")


def strip_comments(text: str) -> str:
    """Remove `//` and `/* */` comments without treating a `//` inside a string as one."""
    out = []
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "\"'`":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def resolve(root: str, importer: str, spec: str):
    base = os.path.normpath(os.path.join(os.path.dirname(importer), spec))
    candidates = [base]
    if base.endswith(".js"):
        candidates.append(base[:-3] + ".ts")
    candidates += [base + ".ts", os.path.join(base, "index.ts")]
    for c in candidates:
        if os.path.isfile(os.path.join(root, c)):
            return c
    return None


def imports_of(root: str, rel: str):
    text = strip_comments(open(os.path.join(root, rel), encoding="utf-8").read())
    specs = list(IMPORT_RE.findall(text)) + list(BARE_IMPORT_RE.findall(text))
    return specs


def closure(root: str, entries, stop_at=()):
    """Files reachable from `entries`, not descending into `stop_at`."""
    seen, packages, unresolved = set(), set(), []
    stack = list(entries)
    while stack:
        rel = stack.pop()
        if rel in seen:
            continue
        seen.add(rel)
        if rel in stop_at:
            continue
        for spec in imports_of(root, rel):
            if spec.startswith("."):
                r = resolve(root, rel, spec)
                if r is None:
                    unresolved.append((rel, spec))
                else:
                    stack.append(r)
            else:
                packages.add(spec)
    return seen, packages, unresolved


def lines_of(root: str, rel: str) -> int:
    with open(os.path.join(root, rel), encoding="utf-8") as f:
        return sum(1 for _ in f)


def main() -> int:
    root, entry = sys.argv[1], sys.argv[2]

    full, packages, unresolved = closure(root, [entry])
    total = sum(lines_of(root, f) for f in full)
    for f in sorted(full):
        print(f"FILE\t{f}\t{lines_of(root, f)}")
    print(f"FULL_FILES\t{len(full)}")
    print(f"FULL_LINES\t{total}")
    print(f"UNRESOLVED\t{len(unresolved)}")
    for importer, spec in unresolved:
        print(f"UNRESOLVED_SPEC\t{importer}\t{spec}")
    for p in sorted(packages):
        print(f"PACKAGE\t{p}")

    # THE REDUCED SET. Declared as a LIST rather than derived by pruning, because "what survives if
    # you delete the simulator half" is a judgement and a judgement stated as a list can be argued
    # with. Its own closedness is then MEASURED: nothing in it may import outside it except through
    # the three functions the adoption drops, which are named in REUSE-INVENTORY.md RI-64.
    fixtures = "yarn-project/simulator/src/public/fixtures"
    avmfix = "yarn-project/simulator/src/public/avm/fixtures"
    reduced = [
        f"{fixtures}/public_tx_simulation_tester.ts",
        f"{fixtures}/utils.ts",
        f"{fixtures}/simple_contract_data_source.ts",
        f"{avmfix}/utils.ts",
        f"{avmfix}/base_avm_simulation_tester.ts",
    ]
    minimal = reduced[:-1]
    for name, group in (("REDUCED", reduced), ("MINIMAL", minimal)):
        missing = [f for f in group if not os.path.isfile(os.path.join(root, f))]
        if missing:
            print(f"{name}_MISSING\t{','.join(missing)}")
            return 1
        print(f"{name}_FILES\t{len(group)}")
        print(f"{name}_LINES\t{sum(lines_of(root, f) for f in group)}")

    # The edges the reduced set would have to sever, PRINTED so the trim is a list and not a hope.
    escapes = []
    for f in minimal:
        for spec in imports_of(root, f):
            if not spec.startswith("."):
                continue
            r = resolve(root, f, spec)
            if r is not None and r not in reduced:
                escapes.append((f, spec, r))
    print(f"REDUCED_ESCAPES\t{len(escapes)}")
    for f, spec, r in escapes:
        print(f"REDUCED_ESCAPE\t{f}\t{spec}\t{r}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
