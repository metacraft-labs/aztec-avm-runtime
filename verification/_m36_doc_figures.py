#!/usr/bin/env python3
"""Re-derive LOCAL-HISTORY.md's figures from the artefacts and compare.

    _m36_doc_figures.py <LOCAL-HISTORY.md> <chunks.json> <note-discovery.json>

Prints `KEY<TAB>VALUE` lines for `e2e_note_discovery_across_blocks` §9:

    CHECKED  <n>          how many figures were compared — asserted non-trivial
    BAD      <details>    a figure the document states that the artefact does not
    MISSING  <details>    a subject line the document no longer has

`fmt()` and `states()` are M33's, M34's and M35's, copied rather than imported for the reason M34
records: the two files' figure LISTS are what differ, and a shared list would be a shared thing to
rot. They carry two of this campaign's most expensive findings:

  * ANCHORED TO THE ROW, NOT TO THE FILE (M24's review). A check matching each figure as
    `| <number> |` anywhere in a document passed a table whose two rows had been SWAPPED, so the
    document stated the reverse of its own data with 91 assertions and 0 failures.
  * AND ANCHORED TO THE FIELD, NOT TO THE ROW (M33's review). Bare substring containment let two of
    nineteen figures pass unfalsifiably, because `245.87` supplies an `8` and `0` is a substring of
    every number containing a zero digit. The needle is DELIMITED.

Every figure here comes from an artefact and none from a second document: the creation figures and
the note/tagging counts from the BROWSER arm's report, the packaging figures from the build's own
`chunks.json`, and the vendored-file count from the tracked tree.
"""

import json
import os
import re
import subprocess
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


def main(doc_path, chunks_path, arms_path):
    doc_lines = open(doc_path, encoding="utf-8").read().split("\n")
    chunks = json.load(open(chunks_path))
    arms = json.load(open(arms_path))["arms"]
    report = arms.get("discovery", {}).get("report", {})

    checked = 0
    bad = []
    missing = []

    def compare(needle, value, label):
        """Find the ONE line naming this subject and require it to state this figure."""
        nonlocal checked
        rows = [r for r in doc_lines if needle in r]
        if not rows:
            missing.append("%s (no line contains %r)" % (label, needle))
            return
        wanted = fmt(value)
        if not any(states(r, wanted) for r in rows):
            bad.append("%s: the artefact says %s, the document's row says %r" % (label, wanted, rows[0].strip()))
        checked += 1

    creation = report.get("creation", {})
    notes = report.get("notes", {})
    tagging = report.get("tagging", {})
    surface = report.get("surface", {})
    ephemeral = report.get("ephemeral", {})

    # ---- §3: the creation measurement, from the BROWSER arm.
    compare("`NoteGetter.insert_note` bytecode", creation.get("bytecodeBytes"), "insert-note-bytes")
    compare("its solved witness", creation.get("solvedWitnessSize"), "insert-note-witness")
    compare("oracle calls it made, all served", len(creation.get("oracleLedger", [])), "insert-note-oracles")
    compare("note hashes its public inputs claimed", len(creation.get("noteHashes", [])), "insert-note-hashes")
    compare("private logs its public inputs claimed", len(creation.get("privateLogLengths", [])), "insert-note-logs")
    compare("the served set with a discovery source attached", surface.get("servedWithDiscovery"), "served-with")
    compare("the served set without one", surface.get("servedWithout"), "served-without")
    compare("notes stored after block 1", notes.get("stored"), "notes-stored")
    compare("`getNotes(ACTIVE)` after creation", notes.get("activeAfterCreation"), "active-after-creation")
    compare("`getNotes(ACTIVE)` after the spend in block 3", notes.get("activeAfterSpend"), "active-after-spend")
    compare("`getNotes(ACTIVE_OR_NULLIFIED)` after the spend", notes.get("eitherAfterSpend"), "either-after-spend")

    # ---- §4: the tagging figures.
    compare("accounts the tagging half holds", tagging.get("accountCount"), "accounts")
    # THREE ROWS AND NOT ONE, and the reason is the comparer's own delimiting rule. A row reading
    # `**1, 2, 3**` states none of the three AS A FIGURE — `1` is followed by a comma, which is in
    # the excluded class precisely so that `1` cannot be matched out of `1,234`. Written as three
    # subjects the rows are individually falsifiable, which is also what makes a SWAP visible.
    idx = tagging.get("indexes") or []
    for needle, value in zip(
        ["the first of three consecutive `getNextTaggingIndex` calls returns", "| the second |", "| the third |"],
        idx,
    ):
        compare(needle, value, "tag-index[%s]" % needle[:24])
    compare("distinct siloed tags those three indexes produce", tagging.get("distinctTags"), "distinct-tags")
    compare("logs a replayed (secret, index) lookup returns, twice", tagging.get("replayFirst"), "replay-first")
    compare("logs a replayed (secret, index) lookup returns, twice", tagging.get("replaySecond"), "replay-second")

    # ---- §5: the deterministic ephemeral slots.
    compare("slots the deterministic allocator issued", ephemeral.get("allocatedSlots"), "eph-slots")

    # ---- §6: the packaging, from the BUILD's own report.
    def eager(entry):
        return next((r for r in chunks["eager"] if r["entry"] == entry), None)

    for label, entry, needle in (
        ("wallet", "wallet.js", "the wallet entry's eager set"),
        ("wallet-demo", "wallet-demo.js", "the wallet demo page's eager set"),
    ):
        row = eager(entry)
        if row is None:
            missing.append("eager(%s: no such entry in chunks.json)" % label)
            continue
        compare(needle, round(row["gzipBytes"] / 1024, 2), "eager-kb[%s]" % label)
        compare(needle, len(row["files"]), "eager-files[%s]" % label)

    # ---- §6: the vendored file count, from the TRACKED TREE rather than from a number in a table.
    repo = os.path.dirname(os.path.abspath(doc_path))
    listed = subprocess.run(
        ["git", "-C", repo, "ls-files", "browser/src/vendor/pxe_notes"],
        capture_output=True, text=True, check=False,
    ).stdout.split()
    compare("files vendored into `browser/src/vendor/pxe_notes`", len(listed), "vendored-files")

    print("CHECKED\t%d" % checked)
    print("BAD\t%s" % (" ;; ".join(bad) if bad else ""))
    print("MISSING\t%s" % (" ;; ".join(missing) if missing else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*sys.argv[1:]))
