#!/usr/bin/env python3
"""Re-derive BROWSER-PACKAGING.md's figures from the build's own report and compare.

    _m27_doc_figures.py <chunks.json> <BROWSER-PACKAGING.md> <browser.json>

Prints `KEY<TAB>VALUE` lines for `verify_browser_chunk_budget` §6.

WHY THIS EXISTS. `CAMPAIGN-BRIEF.md`: "If a document states a measurement, something must take that
measurement again and compare." Every other milestone write-up in this repository is opened by
between two and seven checks; `BROWSER-PACKAGING.md` was opened by NONE — `lib_m27_browser.sh`
defined and exported `M27_DOC` and nothing read it — while its own first sentence claimed that
everything in it is re-derived on every run. Eleven of its figures had already rotted, among them
the §1 total (8,166 against a measured 8,149.89), `util`'s importer count (37 against 43) and the
entry-point attribution in §6 (253.94 KB against 277.65). This is M12's shape:
`verify_avm_wasm_size_budget` opens `REACTOR-ABI.md` and requires eight measured figures to appear
in it.

ANCHORED TO THE ROW, NOT TO THE FILE. `CAMPAIGN-BRIEF.md` records an OQ-6 check that matched each
figure as `| <number> |` anywhere in the document: swapping two rows' medians left the document
stating the reverse of the data and the check reported 91 assertions, 0 failures. So a figure is
looked for on the line that NAMES its subject, and a row whose subject line cannot be found is a
`ROW-MISSING`, not a silent pass.

THE RESIDUE IS PRINTED. A subject the document does not mention at all is reported rather than
skipped, so a table that loses a row fails instead of getting smaller.
"""

import json
import re
import sys


def kb(gzip_bytes):
    """The document's own convention: bytes / 1024, two decimals, as `build.mjs` prints it."""
    return round(gzip_bytes / 1024, 2)


def fmt(value):
    """`1234.5` -> `1,234.50`-ish: the document writes thousands separators and drops `.0`."""
    text = ("%.2f" % value).rstrip("0").rstrip(".")
    if "." in text:
        whole, frac = text.split(".")
    else:
        whole, frac = text, ""
    grouped = "{:,}".format(int(whole))
    return grouped + ("." + frac if frac else "")


def line_for(doc_lines, needle):
    """The document line naming this subject, or None. Fixed string, first match."""
    for line in doc_lines:
        if needle in line:
            return line
    return None


def main(chunks_path, doc_path, arms_path):
    chunks = json.load(open(chunks_path))
    doc_lines = open(doc_path, encoding="utf-8").read().split("\n")
    arms = json.load(open(arms_path))

    checked = 0
    bad = []
    missing = []

    def compare(subject, needle, value, label):
        """Require `value`, formatted as the document formats numbers, on the subject's own line."""
        nonlocal checked
        row = line_for(doc_lines, needle)
        if row is None:
            missing.append("%s(no line naming %r)" % (label, needle))
            return
        checked += 1
        wanted = fmt(value)
        # Both spellings: the document writes `3,018.02` in tables and `8,149.89` in prose, and a
        # figure under 1,000 has no separator at all.
        if wanted not in row and wanted.replace(",", "") not in row:
            bad.append("%s expected %s in: %s" % (label, wanted, row.strip()))

    # ---- §1, the eager table. One row per entry point, each naming its own entry file.
    eager_by_entry = {row["entry"]: row for row in chunks["eager"]}
    for entry, needle in (
        ("browser.js", "the DD-5 reference"),
        ("testing.js", "`aztec-avm-runtime/testing`"),
        ("demo.js", "the demo page"),
        ("node/node.js", "`aztec-avm-runtime/node` |"),
    ):
        row = eager_by_entry.get(entry)
        if row is None:
            missing.append("eager[%s] is not in chunks.json" % entry)
            continue
        compare(entry, needle, kb(row["gzipBytes"]), "eager-kb[%s]" % entry)
        # The file COUNT on the same row, as a bare integer between pipes.
        doc_row = line_for(doc_lines, needle)
        if doc_row is not None:
            cells = [c.strip() for c in doc_row.split("|")]
            if str(len(row["files"])) not in cells:
                bad.append("eager-files[%s] expected %d in: %s"
                           % (entry, len(row["files"]), doc_row.strip()))
            else:
                checked += 1

    # ---- §1, the lazy table, by chunk prefix. `chunks/` only: the `node/chunks/` siblings differ
    # in the second decimal and the document's globs exclude them.
    by_file = {row["file"]: row for row in chunks["files"]}
    for prefix, needle in (
        ("chunks/barretenberg-threads-", "`chunks/barretenberg-threads-*.js`"),
        ("chunks/barretenberg-", "`chunks/barretenberg-*.js`"),
        ("chunks/ContractClassRegistry-", "`chunks/ContractClassRegistry-*.js`"),
        ("chunks/FeeJuice-", "`chunks/FeeJuice-*.js`"),
        ("chunks/ContractInstanceRegistry-", "`chunks/ContractInstanceRegistry-*.js`"),
    ):
        hits = [f for f in by_file
                if f.startswith(prefix)
                and not (prefix == "chunks/barretenberg-" and "threads" in f)]
        if len(hits) != 1:
            missing.append("%s matched %d chunks, expected 1" % (prefix, len(hits)))
            continue
        compare(prefix, needle, kb(by_file[hits[0]]["gzipBytes"]), "lazy-kb[%s]" % prefix)

    # ---- §1, the total.
    compare("total", "gzipped across every chunk", kb(chunks["totalGzipBytes"]), "total-kb")

    # ---- §6, the request accounting, from the ARM RUN rather than from the build.
    requests = arms["arms"]["publicOnly"]["requests"]
    compare("requests", "the enumeration below totals",
            len(requests), "request-count")
    scripts = [r for r in requests if r["url"].startswith("/chunks/")
               and not r["url"].startswith("/chunks/FeeJuice-")]
    compare("chunks", "shared chunks", len(scripts), "eager-chunk-requests")
    compare("module", "the AVM and its world state", arms["module"]["bytes"], "module-bytes")

    print("CHECKED\t%d" % checked)
    print("BAD\t%s" % (" ;; ".join(bad) if bad else ""))
    print("MISSING\t%s" % (" ;; ".join(missing) if missing else ""))


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
