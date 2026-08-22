#!/usr/bin/env python3
"""Compare the NEW fast-path observer's step records against upstream's EXISTING per-instruction
seam, record for record.

This is the check that makes the no-patch fallback a measurement rather than a sentence. Upstream
already emits one `ExecutionEvent` per instruction from `Execution::execute`; the patch adds a
seam on `HybridExecution::execute`, the loop that deliberately emits nothing. If the two disagree
about any instruction, the patch is wrong — and if they agree on all of them, the fallback is
exactly as good as advertised on everything except cost.

Both sides are produced by the same driver, in the same field format:

    steps.<program>.<i>  ctx=.. pc=.. op=.. l2=.. da=.. addr=0x..
    events.<program>.<i> ctx=.. pc=.. op=.. l2=.. da=.. addr=0x..

Usage:
    _step_records_compare.py <steps.transcript> <events.transcript>

Prints one `PASS\\t<name>\\t<detail>` or `FAIL\\t<name>\\t<detail>` row per assertion and exits 0.
Exit 3 means an input would have made every comparison vacuous.
"""

import re
import sys

PROGRAMS = ("add", "revert", "loop", "sha256", "poseidon2", "storage", "burn", "oob")

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, str(detail)))


def load(path, prefix):
    """-> ({(program, index): fields}, {key: value} for the non-record lines)"""
    rec_re = re.compile(
        r"^" + prefix + r"\.([a-z0-9]+)\.([0-9]+) (ctx=[0-9]+ pc=[0-9]+ op=[0-9]+ "
        r"l2=[0-9]+ da=[0-9]+ addr=0x[0-9a-f]{64})$"
    )
    records, fields = {}, {}
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("diag "):
                continue
            m = rec_re.match(ln)
            if m:
                records[(m.group(1), int(m.group(2)))] = m.group(3)
            else:
                k, _, v = ln.partition(" ")
                fields[k] = v
    return records, fields


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    steps, step_fields = load(sys.argv[1], "steps")
    events, event_fields = load(sys.argv[2], "events")

    if not steps or not events:
        sys.stderr.write(f"nothing to compare: steps={len(steps)} events={len(events)}\n")
        return 3

    check("the observer produced step records", len(steps) > 0, len(steps))
    check("upstream's own seam produced event records", len(events) > 0, len(events))
    check("both seams produced the same number of records",
          len(steps) == len(events), f"steps={len(steps)} events={len(events)}")

    only_steps = sorted(set(steps) - set(events))
    only_events = sorted(set(events) - set(steps))
    check("no instruction is observed by the new seam and not by upstream's",
          not only_steps, ",".join(f"{p}.{i}" for p, i in only_steps[:8]))
    check("no instruction is emitted by upstream's seam and not by the new one",
          not only_events, ",".join(f"{p}.{i}" for p, i in only_events[:8]))

    common = sorted(set(steps) & set(events))
    diffs = [k for k in common if steps[k] != events[k]]
    check("every record is identical field for field "
          "(context id, pc, opcode, cumulative l2 and da gas, contract address)",
          not diffs,
          "; ".join(f"{p}.{i}: [{steps[(p, i)]}] != [{events[(p, i)]}]" for p, i in diffs[:5])
          + (f" (+{len(diffs) - 5} more)" if len(diffs) > 5 else ""))

    # Per program, so a whole program going missing cannot hide inside a total.
    for prog in PROGRAMS:
        s = sum(1 for p, _ in steps if p == prog)
        e = sum(1 for p, _ in events if p == prog)
        want = step_fields.get(f"steps.{prog}.instructionsExecuted")
        check(f"`{prog}`: both seams report {s} records", s == e and s > 0, f"steps={s} events={e}")
        check(f"`{prog}`: upstream's own event count equals total_instructions_executed",
              event_fields.get(f"events.{prog}.count") == want,
              f"events={event_fields.get(f'events.{prog}.count')} stat={want}")
        check(f"`{prog}`: the hint-collecting run really produced hints",
              event_fields.get(f"events.{prog}.hintsPresent") == "1",
              event_fields.get(f"events.{prog}.hintsPresent"))

    # The counts must not all be the same, or "equal counts" would be a statement about a constant.
    counts = {event_fields.get(f"events.{p}.count") for p in PROGRAMS}
    check("the eight programs execute different numbers of instructions",
          len(counts) == len(PROGRAMS), sorted(counts, key=lambda x: int(x or 0)))

    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
