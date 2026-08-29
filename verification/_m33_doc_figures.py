#!/usr/bin/env python3
"""Re-derive WALLET-BOUNDARY.md's figures from the artefacts and compare.

    _m33_doc_figures.py <WALLET-BOUNDARY.md> <chunks.json> <meta.json> <wallet.json>
                        <closure.tsv> <deps.tsv>

Prints `KEY<TAB>VALUE` lines for `verify_provider_half_dd9_clean` §9:

    CHECKED  <n>          how many figures were compared — asserted non-trivial
    BAD      <details>    a figure the document states that the artefact does not
    MISSING  <details>    a subject line the document no longer has

WHY THIS EXISTS. `CAMPAIGN-BRIEF.md`: *"If a document states a measurement, something must take that
measurement again and compare."* Every other milestone write-up in this repository learned that the
expensive way: `BROWSER-PACKAGING.md` claimed on its first line that everything in it was re-derived
on every run, and no check opened it at all — eleven figures had already rotted.

ANCHORED TO THE ROW, NOT TO THE FILE. M24's review's finding: a check that matched each figure as
`| <number> |` anywhere in a document passed a table whose two rows had been swapped, so the
document stated the reverse of the data with 91 assertions and 0 failures. Here a figure is looked
for on the line that NAMES ITS SUBJECT, and a subject line the document does not have is a MISSING
rather than a silent pass.
"""

import json
import sys


def fmt(value):
    """`1234.5` -> `1,234.5`: the document writes thousands separators and drops trailing zeros."""
    if isinstance(value, int):
        return "{:,}".format(value)
    text = ("%.2f" % value).rstrip("0").rstrip(".")
    whole, _, frac = text.partition(".")
    return "{:,}".format(int(whole)) + ("." + frac if frac else "")


def main(doc_path, chunks_path, meta_path, arms_path, closure_path, deps_path):
    doc_lines = open(doc_path, encoding="utf-8").read().split("\n")
    chunks = json.load(open(chunks_path))
    meta = json.load(open(meta_path))
    arms = json.load(open(arms_path))["arms"]
    closure = {}
    for line in open(closure_path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 3:
            closure[parts[0]] = (int(parts[1]), int(parts[2]))
    deps = {}
    for line in open(deps_path):
        parts = line.rstrip("\n").split("\t")
        if parts and parts[0] == "CLOSURE" and len(parts) >= 3:
            deps[parts[1]] = int(parts[2])

    checked = 0
    bad = []
    missing = []

    def compare(needle, value, label):
        nonlocal checked
        row = next((l for l in doc_lines if needle in l), None)
        if row is None:
            missing.append("%s(no line naming %r)" % (label, needle))
            return
        checked += 1
        wanted = fmt(value)
        if wanted not in row and wanted.replace(",", "") not in row:
            bad.append("%s expected %s in: %s" % (label, wanted, row.strip()))

    # ---- §1: the closure table, one row per group, each naming its own subject.
    for group, needle in (
        ("provider", "provider half (`extension/provider`"),
        ("wallet", "wallet half (`base-wallet`"),
        ("protocol", "the protocol declaration alone"),
        ("schema", "`WalletSchema` |"),
    ):
        if group not in closure:
            missing.append("closure[%s] was not derived" % group)
            continue
        files, lines = closure[group]
        compare(needle, files, "closure-files[%s]" % group)
        compare(needle, lines, "closure-lines[%s]" % group)

    # ---- §2: the package-closure table, one row per package.
    for pkg, needle in (
        ("@aztec/wallet-sdk", "| `@aztec/wallet-sdk` |"),
        ("@aztec/wallets", "| `@aztec/wallets` |"),
        ("@aztec/pxe", "| `@aztec/pxe` |"),
        ("@aztec/aztec.js", "`@aztec/aztec.js` — what M33 adds"),
    ):
        if pkg not in deps:
            missing.append("deps[%s] was not derived" % pkg)
            continue
        compare(needle, deps[pkg], "deps[%s]" % pkg)

    # ---- §6: the packaging table, from the build's own report and the metafile.
    eager = next((r for r in chunks["eager"] if r["name"] == "wallet"), None)
    own = next((f for f in chunks["files"] if f["file"] == "wallet.js"), None)
    if eager is None or own is None:
        missing.append("chunks.json has no wallet entry")
    else:
        compare("`wallet.js`'s own module", own["gzipKB"], "wallet-own-kb")
        compare("its eager set", round(eager["gzipBytes"] / 1024, 2), "wallet-eager-kb")
        compare("its eager set", len(eager["files"]), "wallet-eager-files")

        def aztecjs_bytes(entry_name):
            row = next((r for r in chunks["eager"] if r["name"] == entry_name), None)
            want = set(row["files"])
            total = 0
            for key, out in meta["outputs"].items():
                if not any(key == f or key.endswith("/" + f) for f in want):
                    continue
                for inp, d in out["inputs"].items():
                    i = inp.rfind("node_modules/")
                    if i < 0:
                        continue
                    if inp[i + len("node_modules/"):].startswith("@aztec/aztec.js/"):
                        total += d["bytesInOutput"]
            return total

        compare("`@aztec/aztec.js` bytes in that eager set", aztecjs_bytes("wallet"),
                "wallet-aztecjs-bytes")
        compare("`@aztec/aztec.js` bytes in `browser.js`'s eager set", aztecjs_bytes("browser"),
                "browser-aztecjs-bytes")

    # ---- §3: the protocol's own counts, from the ARM RUN rather than from the build.
    compare("message types**, re-derived from", len(arms["protocol"]["messageTypes"]),
            "message-types")
    compare("wallet methods**, and none of them typed", len(arms["protocol"]["nullWalletMethods"]),
            "wallet-methods")

    print("CHECKED\t%d" % checked)
    print("BAD\t%s" % (" ;; ".join(bad) if bad else ""))
    print("MISSING\t%s" % (" ;; ".join(missing) if missing else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*sys.argv[1:7]))
