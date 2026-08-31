#!/usr/bin/env python3
"""Per-step values out of a `.ct` container, as the PINNED READER renders it.

    _m25_container_steps.py <ct-print --full output.json> [<drained-records.txt>]

Prints `KEY<TAB>VALUE` lines. With a second argument it also compares the container's steps against
the DRAINED records the producing arm reported, one record at a time.

WHY THIS EXISTS, AND WHY IT READS THE CONTAINER RATHER THAN THE ARM'S REPORT.

`CAMPAIGN-BRIEF.md` records M29's finding as *"a number read from the producer's own report instead
of from what the producer produced"*: `test_browser_steps_are_executed_not_mapped` read an opcode
histogram out of the DRAINED records and out of the recording's own `distinctOpcodes` field, and the
recorder computed the second from the first — both upstream of the writer. Putting a fabrication
back at the WRITE site left every behavioural assertion green.

M25's `e2e_trace_token_transfer_steppable` asks for per-step `l2Gas` and `daGas` **in the token
container**, so this parser reads them back through `ct-print --full` — the pinned reader, over the
bytes the browser downloaded — and the comparison against the drained records is then a differential
between two sides of the writer rather than two readings of one side.

THE VARIABLE IDS ARE ASSIGNED BY ORDER OF FIRST APPEARANCE, STARTING AT ZERO. The reader emits a
`VariableName` event the first time a name is used and `Value` events carrying a `variable_id`
thereafter. Getting that off by one silently attributes every value to the wrong name — the first
draft of this file did, and it read `contractAddress` where `opcode` belongs, which produced
plausible-looking integers. The mapping is PRINTED so a check can assert it rather than trust it.
"""

import json
import sys


def load_steps(doc):
    names = {}
    nid = 0
    for e in doc.get("events", []):
        if e.get("type") == "VariableName":
            names[nid] = e["name"]
            nid += 1

    steps = []
    cur = None
    for e in doc.get("events", []):
        t = e.get("type")
        if t == "Step":
            cur = {"line": e.get("line"), "path_id": e.get("path_id")}
            steps.append(cur)
        elif t == "Value" and cur is not None:
            name = names.get(e.get("variable_id"))
            if name is None:
                continue
            v = e.get("value", {})
            cur[name] = v.get("i", v.get("text"))
    return names, steps


def parse_record(line):
    out = {}
    for kv in line.split(" "):
        if "=" in kv:
            k, v = kv.split("=", 1)
            out[k] = v
    return out


def main():
    if len(sys.argv) < 2:
        print("usage: _m25_container_steps.py <ct-print-output.json> [<drained.txt>]")
        return 2
    try:
        with open(sys.argv[1], encoding="utf-8") as fh:
            doc = json.load(fh)
    except Exception as exc:  # noqa: BLE001 — any parse failure is one verdict here
        print("PARSE\tUNREADABLE: %s: %s" % (exc.__class__.__name__, exc))
        print("STEPS\t0")
        return 0

    names, steps = load_steps(doc)
    print("PARSE\tok")
    print("VARNAMES\t%s" % ",".join(sorted(names.values())))
    print("VARIDS\t%s" % ",".join("%d=%s" % (k, names[k]) for k in sorted(names)))
    print("STEPS\t%d" % len(steps))

    wanted = ("opcode", "contextId", "l2Gas", "daGas", "contractAddress")
    incomplete = [i for i, s in enumerate(steps) if any(w not in s for w in wanted)]
    print("INCOMPLETE\t%d" % len(incomplete))
    print("INCOMPLETE_FIRST\t%s" % (incomplete[0] if incomplete else "none"))
    if not steps:
        return 0

    l2 = [s.get("l2Gas") for s in steps]
    da = [s.get("daGas") for s in steps]
    if any(not isinstance(v, int) for v in l2 + da):
        print("GASKIND\tNON-INTEGER")
        return 0
    print("GASKIND\tint")

    print("L2_FIRST\t%d" % l2[0])
    print("L2_LAST\t%d" % l2[-1])
    print("L2_DISTINCT\t%d" % len(set(l2)))
    dl2 = [b - a for a, b in zip(l2, l2[1:])]
    print("L2_DELTA_MIN\t%d" % min(dl2))
    print("L2_DELTA_MAX\t%d" % max(dl2))
    print("L2_DELTA_NONPOSITIVE\t%d" % sum(1 for x in dl2 if x <= 0))
    print("L2_DELTA_DISTINCT\t%d" % len(set(dl2)))

    print("DA_FIRST\t%d" % da[0])
    print("DA_LAST\t%d" % da[-1])
    print("DA_DISTINCT\t%d" % len(set(da)))
    dda = [b - a for a, b in zip(da, da[1:])]
    print("DA_DELTA_MIN\t%d" % min(dda))
    print("DA_DELTA_MAX\t%d" % max(dda))
    print("DA_DELTA_NEGATIVE\t%d" % sum(1 for x in dda if x < 0))
    print("DA_DELTA_ZERO\t%d" % sum(1 for x in dda if x == 0))

    ctx = {}
    for s in steps:
        ctx[s.get("contextId")] = ctx.get(s.get("contextId"), 0) + 1
    print("CONTEXTS\t%s" % ",".join("%s:%d" % (k, ctx[k]) for k in sorted(ctx)))
    print("CONTEXT_COUNT\t%d" % len(ctx))

    if len(sys.argv) < 3:
        return 0

    # THE DIFFERENTIAL. One record per step, compared field by field, plus a SHIFTED comparison as
    # the comparer's own positive control: a comparer that always answers "agree" would report zero
    # mismatches for the shifted pairing too.
    with open(sys.argv[2], encoding="utf-8") as fh:
        drained = [parse_record(l) for l in fh.read().split("\n") if l.strip()]
    print("DRAINED\t%d" % len(drained))
    n = min(len(steps), len(drained))

    def mismatches(offset):
        # `offset` is 0 for the real pairing and 1 for the control. It is never negative, and the
        # branch that handled a negative one is gone: a fail-safe arm that never executes is a
        # property of dead code, which this campaign has a rule about.
        bad = 0
        for i in range(n - offset):
            s = steps[i]
            r = drained[i + offset]
            if str(s.get("contextId")) != r.get("ctx") \
               or str(s.get("opcode")) != r.get("op") \
               or str(s.get("l2Gas")) != r.get("l2") \
               or str(s.get("daGas")) != r.get("da") \
               or str(s.get("contractAddress")) != r.get("addr"):
                bad += 1
        return bad

    print("PAIRED\t%d" % n)
    print("MISMATCH\t%d" % mismatches(0))
    print("MISMATCH_SHIFTED\t%d" % mismatches(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
