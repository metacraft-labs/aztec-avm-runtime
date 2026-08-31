#!/usr/bin/env python3
"""Is this a complete token/block arm run? Prints `ok`, or one line saying what is wrong.

Read by `lib_token_blocks.sh`'s `tb_require_arms_shape`, which refuses the run on anything else.

WHY THIS EXISTS. A file that is merely non-empty satisfies the library's staleness test, and every
accessor beneath it then throws one at a time — which reads as a check with thirty-five unrelated
failures rather than as a run that did not happen. Measured by this pass's own mutation arm M10,
where a truncated `{ "arms": {` produced exactly that. The distinction matters because the two have
different remedies: one is a defect in the subject, the other is a re-run.

The arm list is enumerated rather than counted, so an arm that silently stopped being produced is
named. It is the same rule the campaign applies to its check lists: a presence is only as wide as
the subjects the loop enumerates.
"""

import json
import sys

EXPECTED_ARMS = [
    "tokenFlows",
    "tokenFlowsNoMint",
    "deployment",
    "deploymentControl",
    "nested",
    "debugLogsOn",
    "debugLogsOff",
    "phasesAllSucceed",
    "phasesAppReverts",
    "phasesSetupReverts",
    "phasesTeardownReverts",
    "customBytecode",
]


def main() -> None:
    if len(sys.argv) != 2:
        print("usage: _token_blocks_shape.py <token-blocks.json>")
        return
    try:
        doc = json.load(open(sys.argv[1], encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001 — any parse failure is the same verdict here
        print(f"unparseable JSON ({exc.__class__.__name__}: {exc})")
        return
    arms = doc.get("arms")
    if not isinstance(arms, dict):
        print("no 'arms' object at the top level")
        return
    missing = [a for a in EXPECTED_ARMS if a not in arms]
    if missing:
        print("missing arm(s): " + ", ".join(missing))
        return
    empty = [a for a in EXPECTED_ARMS if not isinstance(arms[a], dict) or not arms[a].get("blocks")]
    if empty:
        print("arm(s) with no blocks: " + ", ".join(empty))
        return
    if not isinstance(doc.get("module"), dict) or not doc["module"].get("sha256"):
        print("the run does not name the module it measured")
        return
    print("ok")


if __name__ == "__main__":
    main()
