#!/usr/bin/env python3
"""M33's enumeration, as a re-derivation rather than as a remembered number.

    _m33_closure.py <materialised-anchor-root> <group>

`<group>` is `provider` or `wallet`: the two halves of `@aztec/wallet-sdk`, split by its own
`exports` map. Prints `KEY<TAB>VALUE` lines:

    FILES        <n>            value-reachable .ts files
    LINES        <n>            their total line count
    WS_PKGS      <n>\\t<names>   workspace packages reached by a VALUE edge
    EXT_PKGS     <n>\\t<names>   non-workspace specifiers reached by a VALUE edge
    REACHES      <pkg>          one line per DD-9 package reached
    PXE_EDGE     <importer>\\t<specifier>             a VALUE edge to @aztec/pxe
    PXE_CLAUSE   <importer>\\t<specifier>\\t<kind>     EVERY @aztec/pxe clause, value or type
    UNCLASSIFIED <n>            import clauses the classifier could not place (asserted 0)
    UNPLACEABLE  <n>            workspace specifiers that resolved to no file (asserted 0)
    UNRESOLVED   <n>            relative specifiers that resolved to no file (printed, see below)

WHY THIS IS THE THIRD DERIVATION OF ONE NUMBER, AND WHY THE THIRD IS THE ONE THAT COUNTS.

`CAMPAIGN-BRIEF.md`: *"when the derivation IS the number, run the derivation twice, differently,
before believing it"* — the rule M25's review wrote after an import walker whose character class
excluded the newline returned 47 files against a true 65, in the direction that reads as good news.
M33 ran three:

  1. the relative closure per declared subpath, with `_import_closure.py`;
  2. the same, following workspace package edges through each `package.json`'s `exports`;
  3. **this one**, which additionally drops `import type` clauses — because esbuild erases them
     before a byte is emitted, so a closure that counts them measures the type-checker's graph and
     calls it the bundle's. That overcounts, in the direction that reads as BAD news for reuse,
     which is the direction nobody re-checks.

The third moved the answer materially: 565 files / 68,906 lines becomes 408 / 47,330, and the reason
is one clause — `wallet-sdk/src/types.ts`'s only import is `import type { ChainInfo }`, so the
protocol declaration itself has ZERO value dependencies.

THE RESIDUE IS PRINTED IN THREE CATEGORIES and two of them are asserted zero. The third,
`UNRESOLVED`, is not zero and must not be: `constants.gen.js`, `protocol_contract_data.js` and two
`contract-*-registry.js` are GENERATED files that do not exist in a source checkout. They are
counted and named rather than assumed away.
"""

import importlib.util
import json
import os
import re
import sys
from collections import deque

_HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "_import_closure", os.path.join(_HERE, "_import_closure.py")
)
ic = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ic)

FORBIDDEN = ("@aztec/pxe", "@aztec/native", "@aztec/world-state", "@aztec/simulator")

SDK = "yarn-project/wallet-sdk/src"
GROUPS = {
    # The provider/dApp half, as `@aztec/wallet-sdk`'s own `exports` map names it.
    "provider": [
        f"{SDK}/extension/provider/index.ts",
        f"{SDK}/iframe/provider/index.ts",
        f"{SDK}/types.ts",
        f"{SDK}/manager/index.ts",
        f"{SDK}/crypto.ts",
    ],
    # The wallet half.
    "wallet": [
        f"{SDK}/base-wallet/index.ts",
        f"{SDK}/extension/handlers/index.ts",
        f"{SDK}/iframe/handlers/index.ts",
    ],
    # The protocol declaration alone, which is what M33 vendors.
    "protocol": [f"{SDK}/types.ts", f"{SDK}/crypto.ts"],
    # Upstream's complete wallet protocol, which M33 depends on.
    "schema": ["yarn-project/aztec.js/src/wallet/wallet.ts"],
}

# THE SPELLINGS THIS WALKER ENUMERATES, WRITTEN DOWN, because an absence claim is only as wide as
# them. `CLAUSE_RE` and `BARE_RE` below match STATIC `import … from`, `export … from` and bare
# `import '…'`. They do NOT match `import()` or `require()`. Measured by M33's review over all 408
# provider-closure files: zero dynamic imports of either kind, so the closure is complete at this
# anchor — but complete by MEASUREMENT, not by construction, and an `import('@aztec/pxe')` added
# upstream would leave every pxe assertion green over a graph that reaches it. So the count is
# reported and asserted, and the scanner is calibrated against a fixture it must FIND before it is
# believed about the tree.
DYN_RE = re.compile(r"""(?<![.\w$])import\s*\(""")
DYN_SPEC_RE = re.compile(r"""(?<![.\w$])import\s*\(\s*['"]([^'"]+)['"]""")
REQUIRE_RE = re.compile(r"""(?<![.\w$])require\s*\(\s*['"]([^'"]+)['"]""")

# The calibration fixture. If the scanner stops matching, this stops matching too, and the check
# asserts on it before it believes the zero.
DYN_FIXTURE = "const a = await import('@aztec/pxe/server');\nconst b = import(spec);\nconst c = require('fs');\n"

CLAUSE_RE = re.compile(r"""(?:^|[\n;}])(\s*(?:import|export)\b[^;]*?\bfrom\s+['"]([^'"]+)['"])""")
BARE_RE = re.compile(r"""(?:^|[\n;}])\s*import\s+['"]([^'"]+)['"]""")


def classify(clause):
    head = clause.strip()
    body = head[: head.rindex("from")]
    kw = body.split(None, 1)
    if len(kw) < 2:
        return "UNCLASSIFIED"
    rest = kw[1].strip()
    if rest.startswith("type ") or rest.startswith("type{") or rest.startswith("type\n"):
        return "TYPE"
    if "{" not in rest:
        return "VALUE"                      # default or namespace import: always a value binding
    pre = rest[: rest.index("{")].strip()
    if pre.rstrip(",").strip():
        return "VALUE"                      # `import X, { … }`
    inner = rest[rest.index("{") + 1:]
    if "}" not in inner:
        return "UNCLASSIFIED"
    specs = [s.strip() for s in inner[: inner.rindex("}")].split(",") if s.strip()]
    if not specs:
        return "TYPE"
    for s in specs:
        if not (s.startswith("type ") or s.startswith("type\n")):
            return "VALUE"
    return "TYPE"


class Resolver:
    def __init__(self, root):
        self.root = root
        self.yp = os.path.join(root, "yarn-project")
        self.pkg_dir, self.exports = {}, {}
        for d in sorted(os.listdir(self.yp)):
            pj = os.path.join(self.yp, d, "package.json")
            if not os.path.isfile(pj):
                continue
            try:
                doc = json.load(open(pj))
            except Exception:
                continue
            name = doc.get("name")
            if not name:
                continue
            self.pkg_dir[name] = os.path.join(self.yp, d)
            exp = doc.get("exports")
            m = {}
            if isinstance(exp, str):
                m["."] = self._flat(exp)
            elif isinstance(exp, dict):
                for k, v in exp.items():
                    m[k] = self._flat(v)
            self.exports[name] = m

    def _flat(self, val):
        if isinstance(val, str):
            return [val]
        out = []
        if isinstance(val, dict):
            for k, v in val.items():
                if k != "types":
                    out += self._flat(v)
        return out

    def _dest_to_src(self, pkgdir, target):
        t = target[2:] if target.startswith("./") else target
        if t.startswith("dest/"):
            t = "src/" + t[len("dest/"):]
        cands = []
        if t.endswith(".js"):
            cands += [t[:-3] + ".ts", t[:-3] + ".tsx"]
        cands += [t, t + ".ts", os.path.join(t, "index.ts")]
        for c in cands:
            p = os.path.join(pkgdir, c)
            if os.path.isfile(p):
                return os.path.relpath(p, self.root)
        return None

    def resolve(self, spec):
        parts = spec.split("/")
        if spec.startswith("@"):
            pkg = "/".join(parts[:2])
            sub = "./" + "/".join(parts[2:]) if len(parts) > 2 else "."
        else:
            pkg, sub = parts[0], ("./" + "/".join(parts[1:]) if len(parts) > 1 else ".")
        if pkg not in self.pkg_dir:
            return None, pkg
        targets = self.exports.get(pkg, {}).get(sub)
        if targets is None:
            for k, v in self.exports.get(pkg, {}).items():
                if "*" in k:
                    pre, _, post = k.partition("*")
                    if sub.startswith(pre) and sub.endswith(post):
                        mid = sub[len(pre): len(sub) - len(post) or None]
                        targets = [t.replace("*", mid) for t in v]
                        break
        if targets is None:
            return None, pkg
        for t in targets:
            r = self._dest_to_src(self.pkg_dir[pkg], t)
            if r:
                return r, pkg
        return None, pkg


def main(root, group):
    if group not in GROUPS:
        sys.stderr.write("_m33_closure.py: unknown group %r\n" % group)
        return 2
    res = Resolver(root)
    entries = GROUPS[group]
    for e in entries:
        if not os.path.isfile(os.path.join(root, e)):
            print("ENTRY_MISSING\t%s" % e)
            return 1

    seen, ext, unplaceable, unresolved, hits, unclassified, pxe_edges = (
        set(), set(), [], [], set(), [], [])
    # EVERY pxe import CLAUSE, value and type alike, so the two counts the write-up states are both
    # derived. `PXE_EDGE` is the value subset and is what the separation rests on; `PXE_CLAUSE` is
    # the whole set, and the difference between them IS the type-erasure argument. M33's review
    # found the two conflated in two places that ship.
    pxe_clauses = []
    dyn_count, require_count, dyn_specs = 0, 0, []
    q = deque(entries)
    while q:
        rel = q.popleft()
        if rel in seen:
            continue
        seen.add(rel)
        text = ic.strip_comments(open(os.path.join(root, rel), encoding="utf-8").read())
        dyn_count += len(DYN_RE.findall(text))
        require_count += len(REQUIRE_RE.findall(text))
        for spec in DYN_SPEC_RE.findall(text):
            dyn_specs.append((rel, spec))
        specs = []
        for clause, spec in CLAUSE_RE.findall(text):
            k = classify(clause)
            if spec.split("/")[0:2] == ["@aztec", "pxe"]:
                pxe_clauses.append((rel, spec, k))
            if k == "VALUE":
                specs.append(spec)
            elif k == "UNCLASSIFIED":
                unclassified.append((rel, clause.strip()[:120]))
        specs += BARE_RE.findall(text)
        for s in specs:
            if s.startswith("."):
                r = ic.resolve(root, rel, s)
                if r is None:
                    unresolved.append((rel, s))
                else:
                    q.append(r)
            else:
                r, pkg = res.resolve(s)
                if pkg in res.pkg_dir:
                    hits.add(pkg)
                    if pkg == "@aztec/pxe":
                        pxe_edges.append((rel, s))
                    if r is None:
                        unplaceable.append((rel, s))
                    else:
                        q.append(r)
                else:
                    ext.add(s)

    print("FILES\t%d" % len(seen))
    print("LINES\t%d" % sum(ic.lines_of(root, f) for f in seen))
    print("WS_PKGS\t%d\t%s" % (len(hits), ",".join(sorted(hits))))
    print("EXT_PKGS\t%d\t%s" % (len(ext), ",".join(sorted(ext))))
    for p in FORBIDDEN:
        if p in hits:
            print("REACHES\t%s" % p)
    for imp, spec in sorted(pxe_edges):
        print("PXE_EDGE\t%s\t%s" % (imp, spec))
    for imp, spec, kind in sorted(pxe_clauses):
        print("PXE_CLAUSE\t%s\t%s\t%s" % (imp, spec, kind))
    print("UNCLASSIFIED\t%d" % len(unclassified))
    for rel, clause in unclassified[:20]:
        print("UNCLASSIFIED_CLAUSE\t%s\t%s" % (rel, clause))
    print("UNPLACEABLE\t%d" % len(unplaceable))
    for imp, spec in unplaceable[:20]:
        print("UNPLACEABLE_SPEC\t%s\t%s" % (imp, spec))
    # THE SPELLINGS THIS WALKER CANNOT FOLLOW, counted rather than left unsaid.
    print("DYNAMIC\t%d" % dyn_count)
    for rel, spec in sorted(set(dyn_specs)):
        print("DYNAMIC_SPEC\t%s\t%s" % (rel, spec))
    print("REQUIRE\t%d" % require_count)
    print("DYN_FIXTURE_SITES\t%d" % len(DYN_RE.findall(DYN_FIXTURE)))
    print("DYN_FIXTURE_SPECS\t%d" % len(DYN_SPEC_RE.findall(DYN_FIXTURE)))
    print("REQUIRE_FIXTURE_SITES\t%d" % len(REQUIRE_RE.findall(DYN_FIXTURE)))
    print("UNRESOLVED\t%d" % len(unresolved))
    for imp, spec in sorted(set(unresolved)):
        print("UNRESOLVED_SPEC\t%s\t%s" % (imp, spec))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
