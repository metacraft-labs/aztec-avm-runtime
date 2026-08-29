#!/usr/bin/env python3
"""Re-derive DEV-WALLET.md's figures from the artefacts and compare.

    _m34_doc_figures.py <DEV-WALLET.md> <chunks.json> <wallet-transfer.json> <closure.tsv>

Prints `KEY<TAB>VALUE` lines for `e2e_wallet_public_transfer` §8:

    CHECKED  <n>          how many figures were compared — asserted non-trivial
    BAD      <details>    a figure the document states that the artefact does not
    MISSING  <details>    a subject line the document no longer has

THE COMPARER IS M33's, AND SO IS EVERY LESSON IN IT. `states()` and `fmt()` are copied from
`_m33_doc_figures.py` deliberately rather than imported, because the two files' figure LISTS are
what differ and a shared list would be a shared thing to rot; the two functions are eleven lines and
carry two of this campaign's most expensive findings:

  * ANCHORED TO THE ROW, NOT TO THE FILE (M24's review). A check that matched each figure as
    `| <number> |` anywhere in a document passed a table whose two rows had been SWAPPED, so the
    document stated the reverse of the data with 91 assertions and 0 failures.
  * AND ANCHORED TO THE FIELD, NOT TO THE ROW (M33's review). Bare substring containment let two of
    nineteen figures pass unfalsifiably, because `245.87` supplies an `8` for a file count of 8 and
    `0` is a substring of every number containing a zero digit. The remedy is a DELIMITED needle:
    the value must be bounded by characters that cannot be part of a number.

M34's figures are of three kinds and every one of them is a property of an artefact rather than of a
report: the closure figures come from `_m34_closure.py` out of the anchor's object store, the
transfer figures come from the ARM RUN (which is a browser's answer, not a page's intention), and the
packaging figures come from the build's own `chunks.json`.
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
    """Does `row` state `wanted` AS A FIGURE — delimited, not merely as a run of characters?"""
    for form in {wanted, wanted.replace(",", "")}:
        if re.search(r"(?<![\d.,])%s(?![\d.,])" % re.escape(form), row):
            return True
    return False


def main(doc_path, chunks_path, arms_path, closure_path):
    doc_lines = open(doc_path, encoding="utf-8").read().split("\n")
    chunks = json.load(open(chunks_path))
    arms = json.load(open(arms_path))["arms"]
    closure = {}
    for line in open(closure_path):
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 4:
            closure[parts[0]] = (int(parts[1]), int(parts[2]), int(parts[3]))

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

    # ---- §2: the closure table. Three groups, each on the line that names its own subject.
    for group, needle in (
        ("basewallet", "the class M34 was told to subclass"),
        ("walletschema", "which M34 DOES depend on"),
        ("entrypoints", "upstream's other entrypoint package"),
    ):
        if group not in closure:
            missing.append("closure[%s] was not derived" % group)
            continue
        files, lines, pkgs = closure[group]
        compare(needle, files, "closure-files[%s]" % group)
        compare(needle, lines, "closure-lines[%s]" % group)
        compare(needle, pkgs, "closure-pkgs[%s]" % group)

    # ---- §2: the pxe VALUE-edge count, on a line of its own.
    if "basewallet-pxe" in closure:
        edges, _, _ = closure["basewallet-pxe"]
        compare("named VALUE edges", edges, "basewallet-pxe-edges")
    else:
        missing.append("closure[basewallet-pxe] was not derived")

    # ---- §3: the served/refused split, out of the ARM RUN's own reading of the bundle.
    served = arms["refusals"]["report"]["served"]
    refused = arms["refusals"]["report"]["refused"]
    methods = arms["refusals"]["report"]["methods"]
    compare("methods in upstream's `WalletSchema` at the installed pin", len(methods),
            "method-count")
    compare("- **10 served**", len(served), "served-count")
    compare("- **6 refused**", len(refused), "refused-count")

    # ---- §4: the transfer table. Each figure a property of what the BROWSER did.
    report = arms["transfer"]["report"]
    compare("| executed AVM steps |", report["executedSteps"], "steps")
    compare("| AVM contexts |", report["contexts"], "contexts")
    compare("| `ProcessedTx.revertCode` |", report["revertCode"], "revert-code")
    compare("| wallet decisions recorded |", len(report["decisions"]), "decisions")
    compare("| requests containing `barretenberg` |",
            len(arms["transfer"]["barretenbergRequests"]), "barretenberg-requests")
    # The control's zero, which is the other half of "a named failure, not a silent no-op".
    compare("the AVM executed **0** steps", arms["declined"]["report"]["executedSteps"],
            "declined-steps")

    # ---- §6: the packaging table, from the build's own report.
    for entry, needle, label in (
        ("wallet", "| the wallet entry's eager set |", "wallet"),
        ("wallet-demo", "| the wallet demo page's eager set |", "wallet-demo"),
    ):
        row = next((r for r in chunks["eager"] if r["name"] == entry), None)
        if row is None:
            missing.append("chunks.json has no '%s' eager row" % entry)
            continue
        compare(needle, round(row["gzipBytes"] / 1024, 2), "eager-kb[%s]" % label)
        compare(needle, len(row["files"]), "eager-files[%s]" % label)

    print("CHECKED\t%d" % checked)
    print("BAD\t%s" % (" ;; ".join(bad) if bad else ""))
    print("MISSING\t%s" % (" ;; ".join(missing) if missing else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*sys.argv[1:5]))
