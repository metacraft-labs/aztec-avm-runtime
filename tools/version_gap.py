#!/usr/bin/env python3
"""The oracle version-gap report — DD-12, printed every run.

WHY THIS EXISTS AND WHY IT IS A NUMBER.

The differential's C++ oracle is the in-process NAPI AVM in `@aztec/bb.js` at pin
`npm.deletion_era`. Upstream cut over to an out-of-process `bb-avm-sim` IPC service on 2026-07-17
(`96082e32ec`) and has kept moving. As the pin ages the arm stays green while meaning
progressively less: it proves agreement with a SNAPSHOT, not correctness against current
consensus, and it never says which side should move. DRIFT.md D6 accepts that, with two
mitigations rather than a fix, and this tool is the first of them.

A green test that has quietly stopped meaning anything is the worst kind of decay, so the gap is
reported as a number on every run and the check fails when it crosses a recorded threshold. The
numbers are MEASURED from the fork's own history, not typed:

  * days between the oracle's anchor and upstream's current tip;
  * commits between them;
  * changed files under `barretenberg/cpp/src/barretenberg/vm2/` — the AVM itself;
  * whether the out-of-process cutover is inside the gap (it is, and that is the qualitative half:
    past that commit the oracle is not merely older, it is a DIFFERENT ARCHITECTURE);
  * and the gap between the MODULE's anchor and the ORACLE's anchor, which is the one that
    explains D15.

Usage:
    tools/version_gap.py [--json FILE] [--fail-over-days N]

Exit status 0 within the threshold, 3 over it, 2 if the fork cannot answer.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import date
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
FORK = REPO.parent / "aztec-packages"
# The commit at which upstream's simulator stopped talking to an in-process NAPI AVM. Recorded in
# DRIFT.md D6; asserted to exist rather than assumed, so a rewritten history is a failure here
# instead of a silently absent qualitative finding.
CUTOVER = "96082e32ec5216cb0dc32fda6f3f9098b8184e30"
AVM_PATH = "barretenberg/cpp/src/barretenberg/vm2"
# The recorded threshold. Crossing it does not mean the oracle is wrong; it means the claim "this
# proves the swap is safe" has decayed far enough that somebody must look. Moving it requires
# saying so in PINS.md.
DEFAULT_FAIL_OVER_DAYS = 180


def git(*args: str) -> str:
    out = subprocess.run(["git", "-C", str(FORK), *args], capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"version_gap: git {' '.join(args)} failed: {out.stderr.strip()}")
    return out.stdout.strip()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", default="")
    ap.add_argument("--fail-over-days", type=int, default=DEFAULT_FAIL_OVER_DAYS)
    args = ap.parse_args()

    if not (FORK / ".git").exists():
        sys.stderr.write(f"version_gap: the aztec-packages fork is not at {FORK}\n")
        return 2

    pins = json.loads((REPO / "pins.json").read_text())
    ts = pins["anchors"]["ts"]
    cpp = pins["anchors"]["cpp"]
    oracle_version = pins["npm"]["deletion_era"]["version"]

    for name, commit in (("ts", ts["commit"]), ("cpp", cpp["commit"]), ("cutover", CUTOVER)):
        try:
            git("cat-file", "-e", f"{commit}^{{commit}}")
        except SystemExit:
            sys.stderr.write(
                f"version_gap: the fork does not have the {name} commit {commit[:10]}.\n"
                f"  Remedy: git -C {FORK} fetch upstream next\n"
            )
            return 2

    tip = git("rev-parse", "upstream/next")
    tip_date = git("log", "-1", "--format=%cs", tip)

    def gap(a: str, b: str) -> dict:
        a_date = date.fromisoformat(git("log", "-1", "--format=%cs", a))
        b_date = date.fromisoformat(git("log", "-1", "--format=%cs", b))
        commits = int(git("rev-list", "--count", f"{a}..{b}"))
        avm_files = git("diff", "--name-only", a, b, "--", AVM_PATH)
        return {
            "from": a[:10],
            "fromDate": a_date.isoformat(),
            "to": b[:10],
            "toDate": b_date.isoformat(),
            "days": (b_date - a_date).days,
            "commits": commits,
            "avmFilesChanged": len([x for x in avm_files.splitlines() if x]),
        }

    oracle_to_tip = gap(ts["commit"], tip)
    oracle_to_module = gap(ts["commit"], cpp["commit"])
    module_to_tip = gap(cpp["commit"], tip)

    cutover_in_gap = git("merge-base", "--is-ancestor", CUTOVER, tip) == "" and (
        subprocess.run(
            ["git", "-C", str(FORK), "merge-base", "--is-ancestor", CUTOVER, tip]
        ).returncode
        == 0
    )
    cutover_after_oracle = (
        subprocess.run(
            ["git", "-C", str(FORK), "merge-base", "--is-ancestor", ts["commit"], CUTOVER]
        ).returncode
        == 0
    )

    report = {
        "generator": "tools/version_gap.py",
        "oraclePackage": oracle_version,
        "oracleAnchor": ts["commit"][:10],
        "moduleAnchor": cpp["commit"][:10],
        "upstreamTip": tip[:10],
        "upstreamTipDate": tip_date,
        "oracleToUpstreamTip": oracle_to_tip,
        "oracleToModule": oracle_to_module,
        "moduleToUpstreamTip": module_to_tip,
        "outOfProcessCutover": {
            "commit": CUTOVER[:10],
            "date": git("log", "-1", "--format=%cs", CUTOVER),
            "insideTheGap": bool(cutover_in_gap and cutover_after_oracle),
            "what": "feat: cut simulator over to generated bb-avm-sim IPC service",
        },
        "failOverDays": args.fail_over_days,
        "overThreshold": oracle_to_tip["days"] > args.fail_over_days,
    }

    print("=== ORACLE VERSION GAP (DD-12) ===")
    print(f"  oracle    {oracle_version}  =  {report['oracleAnchor']} ({oracle_to_tip['fromDate']})")
    print(f"  module    avm.wasm           =  {report['moduleAnchor']} ({oracle_to_module['toDate']})")
    print(f"  upstream  next               =  {report['upstreamTip']} ({tip_date})")
    print(
        f"  oracle -> upstream tip : {oracle_to_tip['days']} days, {oracle_to_tip['commits']} commits, "
        f"{oracle_to_tip['avmFilesChanged']} AVM files changed"
    )
    print(
        f"  oracle -> module       : {oracle_to_module['days']} days, {oracle_to_module['commits']} commits, "
        f"{oracle_to_module['avmFilesChanged']} AVM files changed   <- this one explains DRIFT.md D15"
    )
    print(
        f"  module -> upstream tip : {module_to_tip['days']} days, {module_to_tip['commits']} commits, "
        f"{module_to_tip['avmFilesChanged']} AVM files changed"
    )
    print(
        f"  out-of-process cutover {CUTOVER[:10]} is "
        f"{'INSIDE' if report['outOfProcessCutover']['insideTheGap'] else 'OUTSIDE'} the gap"
        " — past it the oracle is not merely older, it is a different architecture"
    )
    print(f"  threshold: {args.fail_over_days} days  ->  {'OVER' if report['overThreshold'] else 'within'}")

    if args.json:
        Path(args.json).write_text(json.dumps(report, indent=2) + "\n")

    return 3 if report["overThreshold"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
