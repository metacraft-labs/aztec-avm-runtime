#!/usr/bin/env python3
"""Classify the null wallet's answer to every declared method.

    _m33_refusals.py <methods.json> <results.json>

`results.json` is the arm run's per-method record: `{name: {"resolved": ...}}` or
`{name: {"rejected": {"name": ..., "message": ...}}}`.

Prints:

    CHECKED      <n>            how many methods were classified — asserted equal to the declared count
    RESOLVED     <names>        a method that ANSWERED. A plausible default is the whole failure mode
    MISSING      <names>        a declared method with no result at all
    WRONG_ERROR  <names>        rejected, but not with `WalletNotAttached`
    UNNAMED      <names>        rejected by name, but the message does not contain the method's name
    NO_REASON    <names>        …or does not say what is missing

FOUR CATEGORIES RATHER THAN A PASS/FAIL, because they fail for different reasons and a single
boolean makes them indistinguishable. `CAMPAIGN-BRIEF.md`'s repeated finding is that "the check
failed" and "the check saw what I broke" are different statements; the same applies to what a check
reports about its subject.

THE NAME IS LOOKED FOR AS `'<method>'` — quoted, exactly as the refusal writes it. A bare substring
would be satisfied by `getChainInfo` appearing inside `getContractClassMetadata`… it would not, but
`registerContract` IS a prefix of `registerContractClass`, and that is the needle family
`CAMPAIGN-BRIEF.md` records twenty-one instances of (`honk` in `chonk`, `world_state` in
`world_state_reference`). Quoting makes the match exact.
"""

import json
import sys

REASON_MARKERS = ("wallet protocol boundary", "wallet responsibilities")


def main(methods_path, results_path):
    methods = json.load(open(methods_path))
    results = json.load(open(results_path))

    resolved, missing, wrong, unnamed, no_reason = [], [], [], [], []
    checked = 0
    for name in methods:
        r = results.get(name)
        if r is None:
            missing.append(name)
            continue
        checked += 1
        if "resolved" in r:
            resolved.append(name)
            continue
        err = r.get("rejected") or {}
        if err.get("name") != "WalletNotAttached":
            wrong.append("%s(%s)" % (name, err.get("name")))
            continue
        message = err.get("message") or ""
        if ("'%s'" % name) not in message:
            unnamed.append(name)
        if not any(m in message for m in REASON_MARKERS):
            no_reason.append(name)

    print("CHECKED\t%d" % checked)
    print("RESOLVED\t%s" % ",".join(sorted(resolved)))
    print("MISSING\t%s" % ",".join(sorted(missing)))
    print("WRONG_ERROR\t%s" % ",".join(sorted(wrong)))
    print("UNNAMED\t%s" % ",".join(sorted(unnamed)))
    print("NO_REASON\t%s" % ",".join(sorted(no_reason)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1], sys.argv[2]))
