#!/usr/bin/env python3
"""M33's DD-9 scanner, over a BUILT esbuild metafile, and the packaging fact behind it.

    _m33_dd9.py entry   <meta.json> <chunks.json> <entry-name>
    _m33_dd9.py deps    <yarn-project-dir> <package-name>...

`entry` prints, for one entry point:

    EAGER-FILES     <n>                     the entry's static-import closure, from chunks.json
    EAGER-BYTES     <n>                     raw bytes-in-output over that closure
    ALL-FILES       <n>                     every output reachable, dynamic imports included
    PKG-EAGER       <package>\\t<bytes>       one row per package, EAGER closure
    PKG-ALL         <package>\\t<bytes>       one row per package, WHOLE closure
    FORBIDDEN-EAGER <package>               a DD-9 package with non-zero bytes in the eager set
    FORBIDDEN-ALL   <package>               …anywhere in the reachable closure
    BUILTIN         <specifier>\\t<file>      a Node builtin surviving as an import in the bytes
    UNPLACED        <input>                  an input this scanner could not attribute (asserted 0)

WHY THE METAFILE AND NOT A GREP OF THE BYTES. `CAMPAIGN-BRIEF.md` records, twice, an absence
measured over a tree that excludes its subject by construction — "no published @aztec package ships
a ForkCheckpoint", asked of a node_modules from which the package was deliberately absent; and "the
import graph does not reach @aztec/native", asked of a tree where importing it is MODULE_NOT_FOUND.
A grep of minified bytes is the same defect one level down: `@aztec/native`'s NAME does not appear
in a bundle that inlined it, so its absence would be measured by a needle that could not match.
The metafile names every INPUT PATH esbuild read, so a package that contributed one byte is visible
as `node_modules/@aztec/native/...` whether or not its name survives minification.

AND THE SCANNER IS GIVEN A TREE WHERE THE SUBJECT IS RESOLVABLE. `verify_provider_half_dd9_clean`
builds a control bundle against a stub `@aztec/native` and `@aztec/world-state` and requires this
scanner to REPORT them. Without that, "FORBIDDEN-ALL is empty" is a statement about an instrument
nobody has seen produce a non-empty answer.

`deps` prints the transitive `dependencies` closure of one or more packages, read out of the
workspace's own `package.json` files, so the packaging fact M33 rests on — that `@aztec/wallet-sdk`
cannot be installed without `@aztec/pxe`, and `@aztec/pxe` without `@aztec/native` and
`@aztec/world-state` — is re-derived offline and deterministically rather than remembered.
"""

import json
import os
import re
import sys

FORBIDDEN = ("@aztec/native", "@aztec/world-state", "@aztec/pxe", "@aztec/simulator")

BUILTINS = (
    "fs", "path", "url", "readline", "process", "tty", "child_process", "net",
    "worker_threads", "os", "crypto", "stream", "zlib", "http", "https", "module",
)


def pkg_of(input_path):
    i = input_path.rfind("node_modules/")
    if i < 0:
        return "LOCAL"
    rest = input_path[i + len("node_modules/"):]
    parts = rest.split("/")
    return "/".join(parts[:2]) if rest.startswith("@") else parts[0]


def rel_outputs(meta, dist_files):
    """Map each metafile output key to the chunks.json-relative path it is."""
    out = {}
    for key in meta["outputs"]:
        match = None
        for f in dist_files:
            if key == f or key.endswith("/" + f):
                if match is None or len(f) > len(match):
                    match = f
        if match is not None:
            out[key] = match
    return out


def reachable(meta, roots):
    """Every output reachable from `roots` through imports, dynamic ones included."""
    seen = set()
    stack = list(roots)
    while stack:
        cur = stack.pop()
        if cur in seen or cur not in meta["outputs"]:
            continue
        seen.add(cur)
        for imp in meta["outputs"][cur].get("imports", []):
            p = imp.get("path")
            if p:
                stack.append(p)
    return seen


def entry_cmd(meta_path, chunks_path, entry_name):
    meta = json.load(open(meta_path))
    chunks = json.load(open(chunks_path))
    eager_row = next((r for r in chunks["eager"] if r["name"] == entry_name), None)
    if eager_row is None:
        print("ENTRY-MISSING\t%s" % entry_name)
        return 1
    dist_files = [f["file"] for f in chunks["files"]]
    key_to_rel = rel_outputs(meta, dist_files)
    rel_to_key = {}
    for k, v in key_to_rel.items():
        rel_to_key.setdefault(v, k)

    eager_rel = set(eager_row["files"])
    eager_keys = {rel_to_key[r] for r in eager_rel if r in rel_to_key}
    missing_rel = sorted(r for r in eager_rel if r not in rel_to_key)
    for r in missing_rel:
        print("UNPLACED\t%s" % r)

    entry_key = rel_to_key.get(eager_row["entry"])
    all_keys = reachable(meta, [entry_key] if entry_key else [])

    def tally(keys):
        acc = {}
        for k in keys:
            for inp, d in meta["outputs"][k]["inputs"].items():
                acc[pkg_of(inp)] = acc.get(pkg_of(inp), 0) + d["bytesInOutput"]
        return acc

    eager_pkgs = tally(eager_keys)
    all_pkgs = tally(all_keys)

    print("EAGER-FILES\t%d" % len(eager_keys))
    print("EAGER-BYTES\t%d" % sum(eager_pkgs.values()))
    print("ALL-FILES\t%d" % len(all_keys))
    print("ALL-BYTES\t%d" % sum(all_pkgs.values()))
    for name, acc in (("PKG-EAGER", eager_pkgs), ("PKG-ALL", all_pkgs)):
        for p in sorted(acc):
            print("%s\t%s\t%d" % (name, p, acc[p]))
    for p in FORBIDDEN:
        if eager_pkgs.get(p):
            print("FORBIDDEN-EAGER\t%s\t%d" % (p, eager_pkgs[p]))
        if all_pkgs.get(p):
            print("FORBIDDEN-ALL\t%s\t%d" % (p, all_pkgs[p]))

    # A Node builtin surviving as an IMPORT in the emitted bytes. esbuild leaves an unresolved
    # builtin as a bare `from "fs"`, which is what a browser cannot load.
    dist_dir = os.path.dirname(os.path.abspath(chunks_path))
    import_re = re.compile(r"""(?:^|[\n;}])\s*(?:import|export)[^;]*?\bfrom\s*["']([^"']+)["']""")
    require_re = re.compile(r"""\brequire\(\s*["']([^"']+)["']\s*\)""")
    for rel in sorted(eager_rel):
        p = os.path.join(dist_dir, rel)
        if not os.path.isfile(p):
            continue
        text = open(p, encoding="utf-8", errors="replace").read()
        for spec in set(import_re.findall(text)) | set(require_re.findall(text)):
            bare = spec[5:] if spec.startswith("node:") else spec
            if bare in BUILTINS or spec.startswith("node:"):
                print("BUILTIN\t%s\t%s" % (spec, rel))
    return 0


def deps_cmd(yarn_dir, names):
    by_name = {}
    for d in sorted(os.listdir(yarn_dir)):
        pj = os.path.join(yarn_dir, d, "package.json")
        if not os.path.isfile(pj):
            continue
        try:
            doc = json.load(open(pj))
        except Exception:
            continue
        if doc.get("name"):
            by_name[doc["name"]] = doc
    print("WORKSPACE\t%d" % len(by_name))
    for root in names:
        if root not in by_name:
            print("ROOT-MISSING\t%s" % root)
            continue
        seen, stack = set(), [root]
        while stack:
            cur = stack.pop()
            if cur in seen:
                continue
            seen.add(cur)
            doc = by_name.get(cur)
            if doc is None:
                continue
            for dep in (doc.get("dependencies") or {}):
                if dep.startswith("@aztec/"):
                    stack.append(dep)
        print("CLOSURE\t%s\t%d\t%s" % (root, len(seen), ",".join(sorted(seen))))
        hits = sorted(p for p in seen if p in FORBIDDEN and p != root)
        print("REACHES-FORBIDDEN\t%s\t%s" % (root, ",".join(hits)))
        direct = sorted((by_name[root].get("dependencies") or {}))
        print("DIRECT\t%s\t%s" % (root, ",".join(direct)))
    return 0


def raw_cmd(meta_path):
    """Package attribution over EVERY output in a metafile, through the same tally the entry
    reading uses. This is the mode the control build is read with, so `verify_provider_half_dd9_clean`
    runs its positive control through the same instrument rather than beside it — M32's review's
    lesson, where a control was a second expression over a second buffer and constrained only
    itself."""
    meta = json.load(open(meta_path))
    acc = {}
    for out in meta["outputs"].values():
        for inp, d in out["inputs"].items():
            acc[pkg_of(inp)] = acc.get(pkg_of(inp), 0) + d["bytesInOutput"]
    print("RAW-OUTPUTS\t%d" % len(meta["outputs"]))
    print("RAW-BYTES\t%d" % sum(acc.values()))
    for p in sorted(acc):
        print("RAW-PKG\t%s\t%d" % (p, acc[p]))
    for p in FORBIDDEN:
        if acc.get(p):
            print("RAW-FORBIDDEN\t%s\t%d" % (p, acc[p]))
    return 0


def main(argv):
    if len(argv) < 2:
        sys.stderr.write(__doc__)
        return 2
    if argv[1] == "entry":
        return entry_cmd(argv[2], argv[3], argv[4])
    if argv[1] == "raw":
        return raw_cmd(argv[2])
    if argv[1] == "deps":
        return deps_cmd(argv[2], argv[3:])
    sys.stderr.write("_m33_dd9.py: unknown subcommand %r\n" % argv[1])
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
