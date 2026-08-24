#!/usr/bin/env python3
"""Measure what a switch to the deleted TypeScript merkle trees would cost.

M16's second deliverable asks for the switch to be PRICED — "recorded now so a future reader need
not redo the analysis". A price copied out of the milestone text is not a measurement, so every
number this prints is read out of the installed
`@aztec/merkle-tree@5.0.0-nightly.20260316` tree under `probe-mt/node_modules/`, which is the last
published nightly that ships the package at all (pins.json, `npm_exceptions`).

Output is `key=value` lines on stdout, one per measurement, plus `PROBLEM <text>` lines for
anything that makes the tree unmeasurable. The caller asserts on the values; this script asserts
nothing, so that a check cannot pass because the measuring tool agreed with itself.

Usage:  _fallback_price.py <path-to-@aztec/merkle-tree>
"""

import json
import os
import re
import sys

# The five components M16's deliverable names, mapped to the files that implement them. A name
# that stops resolving is a PROBLEM rather than a zero: the package was restructured, and a price
# quoted off a missing file would be silently wrong.
NAMED_COMPONENTS = {
    "tree_base": "src/tree_base.ts",
    "standard_tree": "src/standard_tree/standard_tree.ts",
    "standard_indexed_tree": "src/standard_indexed_tree/standard_indexed_tree.ts",
    "sparse_tree": "src/sparse_tree/sparse_tree.ts",
}
SNAPSHOT_DIR = "src/snapshots"

# Files published in the tarball that exist to support somebody else's tests. They are part of the
# 2,756 lines on disk and are not part of what a revival would have to maintain, so they are
# counted and then subtracted rather than quietly dropped.
TEST_SUPPORT = [
    "src/snapshots/snapshot_builder_test_suite.ts",
    "src/standard_indexed_tree/test/standard_indexed_tree_with_append.ts",
]


def loc(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return sum(1 for _ in fh)


def main():
    if len(sys.argv) != 2:
        print("PROBLEM usage: _fallback_price.py <path-to-@aztec/merkle-tree>")
        return 1
    root = sys.argv[1]
    out = []
    problems = []

    def emit(k, v):
        out.append("%s=%s" % (k, v))

    pkg_json = os.path.join(root, "package.json")
    if not os.path.isfile(pkg_json):
        print("PROBLEM the package is not installed at %s (run `npm install` in probe-mt/)" % root)
        return 1
    pkg = json.load(open(pkg_json, encoding="utf-8"))
    emit("pkg.name", pkg.get("name", ""))
    emit("pkg.version", pkg.get("version", ""))

    # --- dependencies -------------------------------------------------------
    deps = pkg.get("dependencies", {}) or {}
    aztec_deps = sorted(d for d in deps if d.startswith("@aztec/"))
    other_deps = sorted(d for d in deps if not d.startswith("@aztec/"))
    emit("deps.aztec", ",".join(aztec_deps))
    emit("deps.other", ",".join(other_deps))
    emit("deps.count", len(deps))

    # --- lines of code ------------------------------------------------------
    src = os.path.join(root, "src")
    if not os.path.isdir(src):
        problems.append("the package ships no src/ tree, so its sources cannot be measured")
    ts_files = []
    for dirpath, _dirnames, filenames in os.walk(src):
        for fn in sorted(filenames):
            if fn.endswith(".ts"):
                ts_files.append(os.path.relpath(os.path.join(dirpath, fn), root))
    ts_files.sort()
    emit("src.files", len(ts_files))
    # The tarball carries no *.test.ts — assert that rather than assume it, because "non-test LOC"
    # means something different if it does.
    emit("src.test_files", sum(1 for f in ts_files if f.endswith(".test.ts")))

    total = 0
    for f in ts_files:
        total += loc(os.path.join(root, f))
    emit("loc.all", total)

    support = 0
    for f in TEST_SUPPORT:
        p = os.path.join(root, f)
        if not os.path.isfile(p):
            problems.append("the test-support file %s is gone; the shippable total is derived from it" % f)
            continue
        support += loc(p)
    emit("loc.test_support", support)
    emit("loc.shippable", total - support)

    named_total = 0
    for name, rel in NAMED_COMPONENTS.items():
        p = os.path.join(root, rel)
        if not os.path.isfile(p):
            problems.append("M16 names the component '%s' and %s does not exist" % (name, rel))
            continue
        n = loc(p)
        emit("loc.%s" % name, n)
        named_total += n

    snap_dir = os.path.join(root, SNAPSHOT_DIR)
    snap = 0
    snap_files = 0
    if not os.path.isdir(snap_dir):
        problems.append("M16 names a snapshot layer and %s does not exist" % SNAPSHOT_DIR)
    else:
        for fn in sorted(os.listdir(snap_dir)):
            if not fn.endswith(".ts"):
                continue
            rel = "%s/%s" % (SNAPSHOT_DIR, fn)
            if rel in TEST_SUPPORT:
                continue
            snap += loc(os.path.join(snap_dir, fn))
            snap_files += 1
    emit("loc.snapshots", snap)
    emit("snapshots.files", snap_files)
    named_total += snap
    emit("loc.five_named", named_total)

    # --- what the compiled package actually imports --------------------------
    # `import type` is erased, so the .d.ts import set and the .js import set are different
    # questions and answering only one of them misprices the browser closure. Both are reported.
    dest = os.path.join(root, "dest")
    js_imports, dts_imports = set(), set()
    if not os.path.isdir(dest):
        problems.append("the package ships no dest/ tree, so its runtime imports cannot be measured")
    else:
        pat = re.compile(r"""from ['"](@aztec/[A-Za-z0-9/._-]+)['"]""")
        for dirpath, _d, filenames in os.walk(dest):
            for fn in filenames:
                p = os.path.join(dirpath, fn)
                if fn.endswith(".js"):
                    target = js_imports
                elif fn.endswith(".d.ts"):
                    target = dts_imports
                else:
                    continue
                with open(p, encoding="utf-8", errors="replace") as fh:
                    for m in pat.finditer(fh.read()):
                        # the scope-level package, not the subpath export
                        target.add("/".join(m.group(1).split("/")[:2]))
    emit("imports.runtime", ",".join(sorted(js_imports)))
    emit("imports.types_only", ",".join(sorted(dts_imports - js_imports)))
    emit("imports.dts_all", ",".join(sorted(dts_imports)))

    # --- word-boundary greps over the sources --------------------------------
    # Every needle is matched on a word boundary. `\brevert\b` and not `revert`, because
    # `revertible` is a different word and a price built on it would be wrong in the direction
    # that flatters the fallback.
    blob = ""
    for f in ts_files:
        with open(os.path.join(root, f), encoding="utf-8", errors="replace") as fh:
            blob += fh.read()

    def words(pattern):
        return len(re.findall(pattern, blob, re.IGNORECASE))

    emit("words.checkpoint", words(r"\bcheckpoint\b"))
    emit("words.revert", words(r"\brevert\b"))
    emit("words.snapshot", words(r"\bsnapshot\b"))
    emit("words.genesis", words(r"\bgenesis\b"))
    emit("words.archive", words(r"\barchive\b"))
    emit("words.domain_separator", words(r"\bDOM_SEP\w*\b|\bDomainSeparator\b"))
    emit("words.sha256", words(r"\bsha256\b"))

    # --- the store surface a revival has to re-adapt -------------------------
    handles = re.findall(r"\.(openMap|openSingleton)\(", blob)
    emit("store.handles", len(handles))

    # The synchronous accessor call sites: `this.<member>.get(` and friends, where <member> is a
    # handle the package opened. Derived from the handle assignments rather than from a hand-typed
    # member list, so a renamed member changes the count instead of escaping it.
    members = set()
    for m in re.finditer(r"this\.(#?[A-Za-z_][A-Za-z0-9_]*)\s*=\s*\w+\.(?:openMap|openSingleton)\(", blob):
        members.add(m.group(1))
    emit("store.members", ",".join(sorted(members)))
    sync_sites = 0
    for mem in members:
        sync_sites += len(re.findall(
            r"this\.%s\.(get|set|has|entries|values|keys|size)\(" % re.escape(mem), blob))
    emit("store.sync_call_sites", sync_sites)

    # --- the hasher, read out of the source ---------------------------------
    hasher = os.path.join(root, "src/poseidon.ts")
    if not os.path.isfile(hasher):
        problems.append("src/poseidon.ts does not exist, so the hashing form cannot be read")
    else:
        text = open(hasher, encoding="utf-8", errors="replace").read()
        # Two-argument poseidon2 with no separator is the defect; a three-argument form with a
        # separator would be the fix. Both are looked for, so "the separator is absent" is a
        # measurement rather than the failure of one grep.
        emit("hasher.undomained_form", 1 if re.search(
            r"poseidon2Hash\(\s*\[\s*\n?\s*Fr\.fromBuffer\(Buffer\.from\(lhs\)\)", text) else 0)
        emit("hasher.separator_mentions", len(re.findall(
            r"\bDOM_SEP\w*\b|\bDomainSeparator\b|\bseparator\b", text, re.IGNORECASE)))

    for p in problems:
        print("PROBLEM %s" % p)
    for line in out:
        print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
