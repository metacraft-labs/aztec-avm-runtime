#!/usr/bin/env python3
"""Measure the differential suite's COMPARISON counts, not its test counts.

The distinction is the whole point. A jest test in `diffsim/` may drive several differential
transactions, one, or none at all — `bench.test.ts` has 30 tests labelled `(TS Simulator)` and
opts out of the comparison entirely — and the labels are inverted from intuition, because
`useCppSimulator ? MeasuredCppPublicTxSimulator : MeasuredCppVsTsPublicTxSimulator` means the
suites labelled `(TS Simulator)` are the differential ones. Quoting the test count as a comparison
count has already overstated this corpus's coverage twice (DRIFT.md D2, D7).

So this tool runs the suite with `DIFFSIM_COUNTERS_DIR` set, which makes
`differential_counters.ts` emit one record per *completed comparison*, and aggregates:

  * comparisons per test file — how many transactions actually went through
    `CppVsTsPublicTxSimulator.simulate()` and passed every assertion;
  * of those, how many had their structured revert reason actually asserted rather than excused by
    the no-C++-metadata exemption (DRIFT.md D3/D7);
  * and, separately, the jest test counts bucketed by `describe` label, so the manifest can state
    both and the difference between them is visible rather than implied.

Usage:
    tools/measure_differential.py [--out FILE] [--skip-opcode-spam]

Exit status is non-zero if either jest run fails or if zero comparisons were recorded — a
measurement of nothing must not be mistaken for a measurement of zero.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DIFFSIM = REPO / "diffsim"
JEST = "./node_modules/.bin/jest"

# The label `describe.each` puts on each arm. `(TS Simulator)` selects the DIFFERENTIAL simulator
# (`useCppSimulator: false` -> MeasuredCppVsTsPublicTxSimulator); `(Cpp Simulator)` runs C++ alone
# with no comparison at all. The names mean the opposite of what they look like.
#
# Two spellings are in the tree — `(TS Simulator)` and `(via TS Simulator)` (avm_gadgets.test.ts
# and bench.test.ts use the second). Matching only the first undercounts the arm by 57 tests, which
# is exactly the kind of enumeration error this whole file exists to stop, so both are matched.
TS_LABEL = re.compile(r"\((?:via )?TS Simulator\)")
CPP_LABEL = re.compile(r"\((?:via )?Cpp Simulator\)")


def run_jest(counter_dir: Path, extra_env: dict, jest_args: list[str]) -> dict:
    """Run jest with --json, returning the parsed report. Raises on a hard failure to run."""
    env = dict(os.environ)
    env["NODE_NO_WARNINGS"] = "1"
    env["DIFFSIM_COUNTERS_DIR"] = str(counter_dir)
    env.update(extra_env)
    with tempfile.NamedTemporaryFile("r", suffix=".json", delete=False) as report:
        report_path = Path(report.name)
    cmd = [
        "node",
        "--experimental-vm-modules",
        JEST,
        "--passWithNoTests",
        "--json",
        f"--outputFile={report_path}",
        *jest_args,
    ]
    proc = subprocess.run(cmd, cwd=DIFFSIM, env=env, capture_output=True, text=True)
    if not report_path.exists():
        sys.stderr.write(proc.stdout[-4000:] + "\n" + proc.stderr[-4000:] + "\n")
        raise SystemExit(f"measure_differential: jest produced no report ({' '.join(cmd)})")
    data = json.loads(report_path.read_text())
    report_path.unlink()
    data["_stderrTail"] = proc.stderr[-2000:]
    return data


def bucket_tests(report: dict) -> dict:
    """Bucket passing tests by describe label, so the label inversion is visible in the numbers."""
    buckets = {"tsSimulatorLabelled": 0, "cppSimulatorLabelled": 0, "unlabelled": 0, "addedHere": 0}
    passed = failed = skipped = 0
    for suite in report.get("testResults", []):
        # Tests WE added live under diffsim/src/corpus/. They are counted separately so the
        # upstream figures (77 / 78 / 602) stay comparable with what upstream's own suite reports,
        # and so our own tests can never be folded into a number quoted as upstream coverage.
        ours = "/src/corpus/" in suite.get("name", "")
        for a in suite.get("assertionResults", []):
            status = a.get("status")
            if status == "passed":
                passed += 1
            elif status == "failed":
                failed += 1
                continue
            else:
                skipped += 1
                continue
            ancestors = " ".join(a.get("ancestorTitles", []))
            if ours:
                buckets["addedHere"] += 1
            elif TS_LABEL.search(ancestors):
                buckets["tsSimulatorLabelled"] += 1
            elif CPP_LABEL.search(ancestors):
                buckets["cppSimulatorLabelled"] += 1
            else:
                buckets["unlabelled"] += 1
    buckets["totalPassed"] = passed
    buckets["totalFailed"] = failed
    buckets["totalSkippedOrOther"] = skipped
    return buckets


def aggregate(counter_dir: Path) -> dict:
    """Fold the per-process JSONL records into per-file comparison counts."""
    per_file: dict[str, dict] = defaultdict(lambda: {"comparisons": 0, "revertReasonCompared": 0})
    total = 0
    reasons = 0
    for jsonl in sorted(counter_dir.glob("*.jsonl")):
        for line in jsonl.read_text().splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            path = rec.get("file") or "<unknown>"
            try:
                path = str(Path(path).resolve().relative_to((DIFFSIM / "src").resolve()))
            except ValueError:
                pass
            per_file[path]["comparisons"] += 1
            total += 1
            if rec.get("revertReasonCompared"):
                per_file[path]["revertReasonCompared"] += 1
                reasons += 1
    return {
        "comparisons": total,
        "revertReasonComparisons": reasons,
        "revertReasonExemptions": total - reasons,
        "byFile": {k: per_file[k] for k in sorted(per_file)},
    }


def measure(skip_opcode_spam: bool) -> dict:
    out: dict = {
        "note": (
            "MEASURED, not read. `comparisons` counts transactions that went through "
            "CppVsTsPublicTxSimulator.simulate() and passed every assertion; a jest test may drive "
            "several, one, or none. `revertReasonComparisons` counts the subset whose structured "
            "revert reason was actually asserted rather than excused by the no-C++-metadata "
            "exemption (DRIFT.md D3/D7). Regenerate with tools/measure_differential.py."
        ),
        "generator": "tools/measure_differential.py",
    }

    # --- Arm 1: the default suite. Everything except the env-gated opcode-spam matrix.
    with tempfile.TemporaryDirectory() as tmp:
        cdir = Path(tmp)
        report = run_jest(cdir, {}, [])
        out["defaultSuite"] = {
            "command": "cd diffsim && npm test",
            "testCounts": bucket_tests(report),
            **aggregate(cdir),
        }

    # --- Arm 2: the opcode-spam matrix, which upstream ships env-gated and CppVsTs-disabled.
    if not skip_opcode_spam:
        with tempfile.TemporaryDirectory() as tmp:
            cdir = Path(tmp)
            report = run_jest(
                cdir,
                {"RUN_AVM_OPCODE_SPAM": "1"},
                ["src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts"],
            )
            out["opcodeSpamArm"] = {
                "command": (
                    "cd diffsim && RUN_AVM_OPCODE_SPAM=1 node --experimental-vm-modules "
                    "./node_modules/.bin/jest src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts"
                ),
                "testCounts": bucket_tests(report),
                **aggregate(cdir),
            }

    d = out["defaultSuite"]
    s = out.get("opcodeSpamArm")
    out["totals"] = {
        "comparisons": d["comparisons"] + (s["comparisons"] if s else 0),
        "revertReasonComparisons": d["revertReasonComparisons"] + (s["revertReasonComparisons"] if s else 0),
        "revertReasonExemptions": d["revertReasonExemptions"] + (s["revertReasonExemptions"] if s else 0),
    }
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", type=Path, default=None, help="write JSON here instead of stdout")
    ap.add_argument(
        "--skip-opcode-spam",
        action="store_true",
        help="measure only the default suite (the opcode-spam arm costs ~3 minutes)",
    )
    args = ap.parse_args()

    if not (DIFFSIM / JEST).exists():
        sys.stderr.write(f"measure_differential: {DIFFSIM / JEST} is missing; run npm install in diffsim/\n")
        return 1
    if shutil.which("node") is None:
        sys.stderr.write("measure_differential: node is not on PATH\n")
        return 1

    result = measure(args.skip_opcode_spam)
    if result["totals"]["comparisons"] == 0:
        sys.stderr.write(
            "measure_differential: ZERO comparisons recorded. That is a broken measurement, not a "
            "measurement of zero — the counter sink or the suite selection is wrong.\n"
        )
        return 1

    text = json.dumps(result, indent=2) + "\n"
    if args.out:
        args.out.write_text(text)
        sys.stderr.write(f"measure_differential: wrote {args.out}\n")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
