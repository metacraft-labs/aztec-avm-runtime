#!/usr/bin/env python3
"""Re-derive PRIVATE-EXECUTION.md's figures from the artefacts and compare.

    _m35_doc_figures.py <PRIVATE-EXECUTION.md> <chunks.json> <private-execution.json> <registry.tsv>

Prints `KEY<TAB>VALUE` lines for `verify_oracle_coverage_is_measured` §8:

    CHECKED  <n>          how many figures were compared — asserted non-trivial
    BAD      <details>    a figure the document states that the artefact does not
    MISSING  <details>    a subject line the document no longer has

`fmt()` and `states()` are M33's and M34's, copied rather than imported for the reason M34 records:
the two files' figure LISTS are what differ, and a shared list would be a shared thing to rot. They
are eleven lines and carry two of this campaign's most expensive findings:

  * ANCHORED TO THE ROW, NOT TO THE FILE (M24's review). A check matching each figure as
    `| <number> |` anywhere in a document passed a table whose two rows had been SWAPPED, so the
    document stated the reverse of its data with 91 assertions and 0 failures.
  * AND ANCHORED TO THE FIELD, NOT TO THE ROW (M33's review). Bare substring containment let two of
    nineteen figures pass unfalsifiably, because `245.87` supplies an `8` for a file count of 8 and
    `0` is a substring of every number containing a zero digit. The needle is DELIMITED.

M35's figures come from four artefacts and not one report: the registry counts from
`_m35_oracles.py` over the ANCHOR'S OBJECT STORE, the surface counts from the BROWSER arm, the two
frames' figures from the same arm, and the packaging figures from the build's own `chunks.json`.
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


def main(doc_path, chunks_path, arms_path, registry_path, vendored_tsv_path):
    doc_lines = open(doc_path, encoding="utf-8").read().split("\n")
    chunks = json.load(open(chunks_path))
    arms = json.load(open(arms_path))["arms"]
    vendored_files = open(vendored_tsv_path, encoding="utf-8").read()
    reg = {"scope": {}}
    for line in open(registry_path):
        parts = line.rstrip("\n").split("\t")
        if parts[0] == "COUNT":
            reg["count"] = int(parts[1])
        elif parts[0] == "LEGACY_COUNT":
            reg["legacy"] = int(parts[1])
        elif parts[0] == "SCOPE":
            reg["scope"][parts[1]] = int(parts[2])

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

    surface = arms["surface"]["report"]
    private = arms["private"]["report"]

    # ---- §1: the registry, from the ANCHOR'S OWN SOURCE.
    compare("entries in `ORACLE_REGISTRY` at the `cpp` anchor", reg["count"], "registry-count")
    compare("of which `misc`", reg["scope"].get("misc", -1), "registry-misc")
    compare("of which `utl`", reg["scope"].get("utl", -1), "registry-utl")
    compare("of which `prv`", reg["scope"].get("prv", -1), "registry-prv")
    compare("legacy oracle aliases beside them", reg["legacy"], "registry-legacy")

    # ---- §1: the oracle versions, from the BROWSER arm.
    #
    # A VERSION IS NOT A DECIMAL, and `fmt` is right to strip a trailing zero from a measurement and
    # wrong to strip one from `30.0`. Caught on this comparer's own first run: it wanted `30` on a row
    # correctly stating `30.0`. Compared as `major.minor` text, delimited the same way.
    def compare_version(needle, major, minor, label):
        nonlocal checked
        row = next((l for l in doc_lines if needle in l), None)
        if row is None:
            missing.append("%s(no line naming %r)" % (label, needle))
            return
        checked += 1
        wanted = "%d.%d" % (major, minor)
        if not re.search(r"(?<![\d.])%s(?![\d.])" % re.escape(wanted), row):
            bad.append("%s expected %s in: %s" % (label, wanted, row.strip()))

    env = surface["registry"]["environmentVersion"]
    compare_version("the environment's oracle version, from the vendored",
                    env["major"], env["minor"], "env-version")
    cv = private["executes"]["contractOracleVersion"]
    compare_version("the version the executed bytecode declared",
                    cv["major"], cv["minor"], "contract-version")

    # ---- §3: the partition, from the BROWSER arm.
    compare("oracles in the registry", surface["registry"]["total"], "surface-total")
    compare("| implemented |", len(surface["registry"]["implemented"]), "surface-implemented")
    compare("| refusing |", len(surface["registry"]["refusing"]), "surface-refusing")
    compare("refusals carrying a declared reason", len(surface["registry"]["reasons"]), "surface-reasons")
    compare("implemented oracles EXERCISED in the browser", len(surface["exercised"]), "surface-exercised")

    # ---- §4: the two frames, from the BROWSER arm.
    compare("`OracleVersionCheck.private_function` bytecode",
            private["executes"]["bytecodeBytes"], "executes-bytes")
    compare("its context-input fields", private["executes"]["contextInputFields"], "executes-context")
    compare("its solved witness", private["executes"]["solvedWitnessSize"], "executes-witness")
    compare("oracle calls it made, all served", private["executes"]["oraclesServed"], "executes-served")
    compare("`Token.transfer` bytecode", private["refuses"]["bytecodeBytes"], "refuses-bytes")
    compare("oracles it served before stopping", private["refuses"]["oraclesServed"], "refuses-served")
    compare("oracles it refused", private["refuses"]["oraclesRefused"], "refuses-refused")

    # ---- §5: the ephemeral-array measurement, from the BROWSER arm.
    compare("oracles whose RETURN type carries an `EphemeralArray`",
            len(surface["registry"]["ephemeralReturnOracles"]), "ephemeral-count")

    # ---- §6: the packaging, from the BUILD's own report and the arm run's asset table.
    def eager(entry):
        row = next((r for r in chunks["eager"] if r["entry"] == entry), None)
        return row
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
    assets = json.load(open(arms_path))["assets"]
    compare("`acvm_js_bg.wasm` |", assets["acvm"]["bytes"], "acvm-bytes")
    compare("`noirc_abi_wasm_bg.wasm` |", assets["noircAbi"]["bytes"], "noircabi-bytes")

    # ---- §2: the vendoring table, EVERY FIGURE OF IT, from the artefacts.
    #
    # THIS ROW WAS WRONG WHEN IT WAS ONLY HALF-DERIVED, AND THAT IS WHY IT IS FULLY DERIVED NOW.
    # A first version compared the FILE count and left the LINE count alone, and the line count was
    # 4,870 — which is 923 + 3,947, the 36-file relative closure, on a row that says 37 files are
    # vendored. The true figure is 4,961. Nobody would have found it: the file count was right and
    # the line count was a number in a table. `CAMPAIGN-BRIEF.md`'s "a figure nobody re-derives rots"
    # family, in the document written to record this milestone's own vendoring.
    #
    # `vendored_files` is now a TSV of `label<TAB>needle<TAB>files<TAB>lines`, so each of the four
    # rows is compared on the line that names its own subject and BOTH of its figures are compared.
    for row in vendored_files.strip().split("\n"):
        if not row.strip():
            continue
        parts = row.split("\t")
        if len(parts) != 4:
            missing.append("vendored(malformed row %r)" % row)
            continue
        label, needle, files, lines = parts
        compare(needle, int(files), "vendored-files[%s]" % label)
        compare(needle, int(lines), "vendored-lines[%s]" % label)

    print("CHECKED\t%d" % checked)
    print("BAD\t%s" % (" ;; ".join(bad) if bad else ""))
    print("MISSING\t%s" % (" ;; ".join(missing) if missing else ""))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(*sys.argv[1:]))
