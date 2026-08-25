#!/usr/bin/env python3
"""Measure the THREE-WAY differential arm: comparisons, pairs, and the divergence set.

Two numbers and one set, and the distinction between them is the whole point.

  * TRANSACTIONS COMPARED — how many transactions ran through all three implementations from one
    proved-identical pre-state. This is the unit `fixtures/differential-arm-counts.json` quotes and
    the one CI reports as its headline.
  * PAIRS COMPARED — two per transaction (`wasm ↔ native-cpp`, `wasm ↔ typescript`). Reported
    separately, never folded in: quoting a pair count as a comparison count would double the
    corpus's apparent coverage without a single new transaction, which is the same arithmetic that
    turned 74 comparisons into a reported 756.
  * THE DIVERGENCE SET — every (pair, field) on which the arms disagreed, with how many
    transactions each fired on.

The divergence set is written to `fixtures/differential-wasm-divergences.json`, which the arm
ENFORCES on every normal run. This tool is the only thing that writes it, and it refuses to write
an entry it cannot attribute:

    an observed (pair, field) with no `drift` id and no `note` in the existing file is written back
    as UNCLASSIFIED and the tool exits non-zero.

That is deliberate. "It diverges and we do not know why" must not be recordable as though it were
an answer, and an auto-classifying tool would make the ledger grow silently — which is exactly how
a ledger becomes an exemption.

Usage:
    tools/measure_three_way.py [--out FILE] [--counts FILE]

Requires AVM_WASM_PATH. Exit status is non-zero if jest fails, if zero transactions were compared
(a measurement of nothing is not a measurement of zero), or if any divergence is unclassified.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
from collections import Counter
from datetime import datetime, timezone
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DIFFSIM = REPO / "diffsim"
LEDGER = REPO / "fixtures" / "differential-wasm-divergences.json"
JEST = "./node_modules/.bin/jest"
SUITE = "src/differential"


def load_ledger(path: Path) -> dict:
    if not path.exists():
        return {"measuredAt": "", "modulePin": "", "oraclePin": "", "entries": []}
    return json.loads(path.read_text())


def pins() -> tuple[str, str]:
    """The two pins the measurement is only valid under, read from pins.json rather than typed."""
    data = json.loads((REPO / "pins.json").read_text())
    module = f"anchor cpp {data['anchors']['cpp']['short']} ({data['anchors']['cpp']['date']}) + this repo's patch stack"
    oracle = (
        f"npm.deletion_era {data['npm']['deletion_era']['version']}"
        f" = anchor ts {data['anchors']['ts']['short']} ({data['anchors']['ts']['date']})"
    )
    return module, oracle


def run_jest(extra_env: dict) -> dict:
    env = dict(os.environ)
    env["NODE_NO_WARNINGS"] = "1"
    env["RUN_THREE_WAY"] = "1"
    env.update(extra_env)
    with tempfile.NamedTemporaryFile("r", suffix=".json", delete=False) as report:
        report_path = Path(report.name)
    cmd = [
        "node",
        "--experimental-vm-modules",
        JEST,
        "--json",
        f"--outputFile={report_path}",
        SUITE,
    ]
    proc = subprocess.run(cmd, cwd=DIFFSIM, env=env, capture_output=True, text=True)
    if not report_path.exists():
        sys.stderr.write(proc.stdout[-4000:] + "\n" + proc.stderr[-4000:] + "\n")
        raise SystemExit("measure_three_way: jest produced no report")
    data = json.loads(report_path.read_text())
    report_path.unlink()
    return data


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(LEDGER))
    ap.add_argument("--counts", default=str(REPO / "fixtures" / "three-way-arm-counts.json"))
    args = ap.parse_args()

    if not os.environ.get("AVM_WASM_PATH"):
        sys.stderr.write(
            "measure_three_way: AVM_WASM_PATH is not set. Build avm.wasm (M6) and point it at\n"
            "  build-wasm-avm/bin/avm.wasm. Measuring without the wasm arm would measure a\n"
            "  two-way differential and label it three-way.\n"
        )
        return 2

    survey_dir = Path(tempfile.mkdtemp(prefix="m19-survey-", dir=str(Path.home() / ".cache")))
    try:
        report = run_jest({"M19_SURVEY_DIR": str(survey_dir)})
        records = []
        for f in sorted(survey_dir.glob("*.jsonl")):
            for line in f.read_text().splitlines():
                if line.strip():
                    records.append(json.loads(line))
    finally:
        shutil.rmtree(survey_dir, ignore_errors=True)

    # One record per (transaction, divergence); a transaction that agreed everywhere writes one
    # record with an empty field. So transactions are counted by (file, test) plus ordinal — which
    # we do not have — so instead: agreements are one record each, and divergences group per
    # transaction only if we count the max per (pair, field). The arm reports its own totals, so
    # the transaction count comes from there rather than from arithmetic over these records.
    agreements = sum(1 for r in records if not r["field"])
    per_field = Counter((r["pair"], r["field"]) for r in records if r["field"])
    signatures: dict[tuple[str, str], set[str]] = {}
    for r in records:
        if r["field"]:
            signatures.setdefault((r["pair"], r["field"]), set()).add(r.get("signature", ""))
    transactions = agreements + (max(per_field.values()) if per_field else 0)

    module_pin, oracle_pin = pins()
    previous = {(e["pair"], e["field"]): e for e in load_ledger(Path(args.out))["entries"]}

    entries = []
    unclassified = []
    for (pair, field), count in sorted(per_field.items()):
        old = previous.get((pair, field))
        entry = {
            "pair": pair,
            "field": field,
            "drift": old["drift"] if old else "UNCLASSIFIED",
            "note": old["note"] if old else "",
            "transactions": count,
            # The EXACT values accounted for, not just the field. Without these an entry for
            # `gasUsed.totalGas` excuses any gas disagreement whatever, which the fault-injection
            # controls proved by going green on an injected +1.
            "signatures": sorted(signatures.get((pair, field), set())),
        }
        if entry["drift"] == "UNCLASSIFIED" or not entry["note"]:
            unclassified.append(f"{pair} {field}")
        entries.append(entry)

    stale = [f"{p} {f}" for (p, f) in previous if (p, f) not in per_field]

    ledger = {
        "note": (
            "MEASURED by tools/measure_three_way.py, never hand-written. One entry per (pair, field) "
            "on which the three-way arm observed a disagreement, with the DRIFT.md entry that "
            "explains it. The arm fails on any divergence NOT in this file, and the checker fails on "
            "any entry in this file that no longer fires — a ledger that has stopped describing the "
            "tree is how an exemption becomes a hole."
        ),
        "generator": "tools/measure_three_way.py",
        "measuredAt": datetime.now(timezone.utc).strftime("%Y-%m-%d"),
        "modulePin": module_pin,
        "oraclePin": oracle_pin,
        "transactionsCompared": transactions,
        "transactionsAgreeingOnEveryField": agreements,
        "entries": entries,
    }
    Path(args.out).write_text(json.dumps(ledger, indent=2) + "\n")

    # SECOND RUN, ENFORCING. The survey run tolerates divergences so the whole set can be measured
    # in one pass, which means the wasm arm keeps a state the native arm does not have and the
    # pre-state numbers it produces describe a tolerated run rather than the shipped one. The
    # counts must describe the ENFORCING run — the one CI does — so they are measured there.
    counts_dir = Path(tempfile.mkdtemp(prefix="m19-counts-", dir=str(Path.home() / ".cache")))
    try:
        enforcing = run_jest({"DIFFSIM_COUNTERS_DIR": str(counts_dir)})
        comparisons = []
        for f in sorted(counts_dir.glob("*.jsonl")):
            for line in f.read_text().splitlines():
                if line.strip():
                    comparisons.append(json.loads(line))
    finally:
        shutil.rmtree(counts_dir, ignore_errors=True)

    # EACH TRANSACTION WRITES TWO RECORDS AND THAT IS CORRECT, but it is exactly the arithmetic
    # that has to be got right. `ThreeWayPublicTxSimulator.simulate` calls into
    # `CppVsTsPublicTxSimulator.simulate`, which records its OWN two-way comparison — so one
    # transaction produces one record for `typescript-interpreter:native-cpp-avm` and one for the
    # two wasm pairs. Counting records as transactions gives 58 where the truth is 29, which is the
    # same family of error as counting tests as comparisons.
    #
    # So a TRANSACTION is a record that carries a wasm pair, and PAIRS is the sum over all records —
    # three implementation-pair comparisons per transaction, all three of which really ran.
    wasm_records = [c for c in comparisons if any(p.startswith("wasm-avm:") for p in c.get("pairs", []))]
    enforced_txs = len(wasm_records)
    enforced_pairs = sum(len(c.get("pairs", [])) for c in comparisons)
    identical_pre_states = sum(1 for c in wasm_records if c.get("preStateIdentical"))

    counts = {
        "note": (
            "The three-way arm's own totals. `transactionsCompared` is the unit the corpus manifest "
            "quotes; `pairsCompared` is two per transaction and is reported separately so neither "
            "number can be quoted as the other."
        ),
        "generator": "tools/measure_three_way.py",
        "command": f"cd diffsim && AVM_WASM_PATH=… npx jest {SUITE}",
        "transactionsCompared": enforced_txs,
        "pairsCompared": enforced_pairs,
        "pairsPerTransaction": 3,
        "twoWayRecordsFromTheParentHarness": len(comparisons) - enforced_txs,
        "preStatesProvedIdentical": identical_pre_states,
        "transactionsAgreeingOnEveryField": agreements,
        "divergentPairFields": len(entries),
        "testCounts": {
            "totalPassed": enforcing.get("numPassedTests", 0),
            "totalFailed": enforcing.get("numFailedTests", 0),
        },
    }
    Path(args.counts).write_text(json.dumps(counts, indent=2) + "\n")

    print(f"measure_three_way: enforcing run {enforced_txs} transactions / {enforced_pairs} pairs / "
          f"{identical_pre_states} from byte-identical pre-states; survey run {transactions} transactions, "
          f"{agreements} agreeing on every field, {len(entries)} divergent (pair, field)")
    print(f"  wrote {args.out}")
    print(f"  wrote {args.counts}")

    if transactions == 0:
        sys.stderr.write("measure_three_way: zero transactions compared — that is not a measurement of zero\n")
        return 3
    if report.get("numFailedTests", 0):
        sys.stderr.write(f"measure_three_way: {report['numFailedTests']} jest tests failed during the survey\n")
        return 4
    if enforcing.get("numFailedTests", 0) or enforced_txs == 0:
        sys.stderr.write(
            f"measure_three_way: the ENFORCING run failed ({enforcing.get('numFailedTests', 0)} tests, "
            f"{enforced_txs} transactions). The counts describe the enforcing run, not the survey.\n"
        )
        return 7
    if stale:
        sys.stderr.write("measure_three_way: ledger entries that no longer fire: " + ", ".join(stale) + "\n")
        return 5
    if unclassified:
        sys.stderr.write(
            "measure_three_way: divergences with no DRIFT.md attribution: "
            + ", ".join(unclassified)
            + "\n  Open a drift entry and fill in `drift` and `note`. A divergence that is written "
            "down without being investigated is an exemption wearing a ledger's clothes.\n"
        )
        return 6
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
