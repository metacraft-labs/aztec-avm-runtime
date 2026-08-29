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

AND ANCHORED TO THE FIELD, NOT TO THE ROW — WHICH IS THE SAME DEFECT ONE NOTCH FINER, AND IT WAS
LIVE. The first draft asked `wanted in row`: bare substring containment anywhere in the matched line.
Measured by M33's review over all nineteen figures, by perturbing the document one figure at a time
and reading `BAD`: **two of the nineteen could not fail.** The wallet entry's eager FILE COUNT is
`8`, and the row is

    | its eager set | **245.87 KB** gzipped across **8** files |

so `245.87` supplies an `8` and a document saying **7** files passed with `CHECKED 19, BAD <empty>`.
And `@aztec/aztec.js` bytes in `browser.js`'s eager set is `0`, which is a substring of every number
containing a zero digit — a document saying **900** where the artefact measures 0 passed too. The
zero is the more dangerous of the two, because it is the assertion holding up DD-11's whole reason
for a separate entry point: *a page that attaches no wallet must not download a wallet protocol.*

The remedy is not a longer needle, it is a DELIMITED one: the value must appear bounded by
characters that cannot be part of a number, so a digit borrowed from a neighbouring figure does not
satisfy it. Both perturbations above are red now, and all fifteen perturbations the review ran are
caught.
"""

import json
import re
import sys


def fmt(value):
    """`1234.5` -> `1,234.5`: the document writes thousands separators and drops trailing zeros."""
    if isinstance(value, int):
        return "{:,}".format(value)
    text = ("%.2f" % value).rstrip("0").rstrip(".")
    whole, _, frac = text.partition(".")
    return "{:,}".format(int(whole)) + ("." + frac if frac else "")


def states(row, wanted):
    """Does `row` state `wanted` AS A FIGURE — delimited, not merely as a run of characters?

    `(?<![\\d.,])` / `(?![\\d.,])` are the whole fix: a digit that belongs to a neighbouring number
    is preceded or followed by a digit, a decimal point or a thousands separator, and is therefore
    refused. Both spellings of a thousands-separated value are accepted, because the document writes
    `47,330` and a reader may write `47330`.
    """
    for form in {wanted, wanted.replace(",", "")}:
        if re.search(r"(?<![\d.,])%s(?![\d.,])" % re.escape(form), row):
            return True
    return False


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
        if not states(row, wanted):
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

    # ---- §1: the two pxe counts, ON LINES OF THEIR OWN.
    #
    # M33's review found this figure stated as "four" in `browser/src/entry_wallet.ts` and in
    # RI-88's `why:` while the check asserted three and the write-up said three. Four is
    # derivation 2's answer — distinct `(file, specifier)` pairs, counting the `import type`
    # clauses esbuild erases — so the two counts are DIFFERENT MEASUREMENTS and conflating them is
    # what let one of them rot. Both are derived and both are compared, and the document carries
    # them on separate lines: on one line a swap would satisfy both needles, which is M24's review's
    # row-swap finding at field level.
    if "pxe-edges" in closure:
        edges, clauses = closure["pxe-edges"]
        compare("`@aztec/pxe` import clauses exist in the wallet half", clauses, "pxe-clauses")
        compare("of them are pxe value edges", edges, "pxe-value-edges")
    else:
        missing.append("closure[pxe-edges] was not derived")

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
