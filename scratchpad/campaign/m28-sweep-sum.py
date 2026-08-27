#!/usr/bin/env python3
"""Summarise a campaign sweep log — and REFUSE to print a total while a hole is open.

    scratchpad/campaign/m28-sweep-sum.py <sweep.log> [reference.json]

Why this exists, and why it refuses rather than warns. M22's sweep lost two regions of its own
log when `/tmp` filled, and the campaign TOTAL survived both holes while the per-milestone
attribution was destroyed — M2 read 475 (its own 178 plus all of M17's 297) and M17 read 0. A
summariser that prints a plausible total over a log with a gap in it is worse than one that
crashes, which is what M21's did.

Two rules from the standing brief, both of which have been got wrong before:

  * A SUMMARY LINE IS AT COLUMN 0 and ends `assertion(s), N failure(s)`. A NOTE is indented and
    may quote a sub-tool's internal count — `  --   repin: 175 assertion(s), 0 problem(s)` is why
    M1 was once reported as 316 when it is 141.
  * The check NAME may contain a space: `just check-repo-hygiene: 28 assertion(s), 0 failure(s)`
    is a real line, and an `^([A-Za-z_0-9]+):` needle silently DROPS it, which is how m0 once
    came out 128 against a reference of 156.
"""

import json
import re
import sys

SUMMARY = re.compile(
    r"^([A-Za-z_0-9][A-Za-z_0-9 .-]*): (\d+) assertion\(s\), (\d+) failure\(s\)$"
)
START = re.compile(r"^######## (m\d+)\s+\S")
END = re.compile(r"^######## (m\d+) rc=(-?\d+) secs=(\d+)$")

REFERENCE = {
    "m0": 156, "m1": 175, "m2": 292, "m3": 199, "m4": 218, "m5": 236, "m6": 363,
    "m7": 287, "m8": 516, "m9": 807, "m10": 450, "m11": 259, "m12": 691, "m13": 458,
    "m14": 460, "m15": 537, "m16": 223, "m17": 297, "m18": 283, "m19": 180, "m20": 237,
    "m21": 324, "m22": 260, "m23": 509, "m24": 350, "m25": 272, "m26": 313,
    "m27": 343, "m28": 348,
}


def main() -> int:
    path = sys.argv[1]
    ref = REFERENCE
    if len(sys.argv) > 2:
        ref = json.load(open(sys.argv[2], encoding="utf-8"))

    order, per, checks, rcs, secs = [], {}, {}, {}, {}
    holes, current, done = [], None, False

    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        # THE END MARKER IS TESTED FIRST, and that is not cosmetic: `######## m0 rc=0 secs=12`
        # also satisfies the START pattern (`m\d+` followed by whitespace and a non-space), so a
        # start-first reader opens a second m0, never closes either, and reports the whole sweep
        # as one long hole. Caught on this summariser's first run against a live log.
        m = END.match(line)
        if m:
            name, rc, s = m.group(1), int(m.group(2)), int(m.group(3))
            if current != name:
                holes.append(f"rc= marker for {name} while {current} was open")
            rcs[name] = rc
            secs[name] = s
            current = None
            continue
        m = START.match(line)
        if m:
            if current is not None:
                holes.append(f"{current} started and never reported an rc= marker")
            current = m.group(1)
            order.append(current)
            per[current] = 0
            checks[current] = []
            continue
        # THE COMPLETION MARKER THIS SUMMARISER LOOKED FOR WAS NEVER PRINTED BY ANYTHING.
        #
        # `m25-sweep.sh` ends with `printf 'SWEEPDONE\n'`, at column 0 and with no `########`
        # prefix; this line tested for `"######## SWEEP DONE"`, with a prefix and a space. So `done`
        # could never become True, the "no 'SWEEP DONE' marker" hole was ALWAYS open, and the
        # summariser REFUSED TO PRINT A TOTAL FOR EVERY RUN INCLUDING A PERFECT ONE. Found by M25's
        # review on a real log.
        #
        # It fails safe — it never printed a wrong total — which is exactly why it could survive:
        # the failure mode of a refusing instrument is indistinguishable from the thing it refuses
        # over, and the operator reads "there is a hole" rather than "I cannot see holes". An
        # instrument whose only output is a refusal is not obviously broken, and this one had a
        # 100% false-refusal rate.
        #
        # Both spellings are accepted, anchored at column 0 so a check's own output cannot forge one.
        if line.startswith("SWEEPDONE") or line.startswith("######## SWEEP DONE"):
            done = True
            continue
        m = SUMMARY.match(line)
        if m:
            if current is None:
                holes.append(f"a summary line outside any milestone: {line!r}")
                continue
            per[current] += int(m.group(2))
            checks[current].append((m.group(1), int(m.group(2)), int(m.group(3))))

    if current is not None:
        holes.append(f"{current} is still open at end of log (the sweep did not finish)")
    if not done:
        holes.append("no 'SWEEP DONE' marker")

    width = max((len(k) for k in order), default=3)
    for name in order:
        got = per[name]
        want = ref.get(name)
        rc = rcs.get(name, "MISSING")
        fails = sum(f for _, _, f in checks[name])
        flag = ""
        if want is None:
            flag = "  (no reference)"
        elif got != want:
            flag = f"  <-- MOVED, reference {want} ({got - want:+d})"
        print(f"{name:<{width}}  {got:>5}  rc={rc}  {secs.get(name, '?'):>5}s  "
              f"failures={fails}{flag}")
        if want is not None and got != want:
            for cname, ca, cf in checks[name]:
                print(f"        {cname}: {ca} assertion(s), {cf} failure(s)")

    total_failures = sum(f for name in order for _, _, f in checks[name])
    bad_rc = [n for n in order if rcs.get(n, 1) != 0]

    print()
    if holes:
        print("HOLES IN THE LOG — NO TOTAL IS PRINTED:")
        for h in holes:
            print(f"  * {h}")
        return 2

    print(f"TOTAL {sum(per.values())}   milestones {len(order)}   "
          f"failing assertions {total_failures}   non-zero exits {bad_rc or 'none'}")
    ref_total = sum(ref[n] for n in order if n in ref)
    print(f"reference total over the same milestones: {ref_total}  "
          f"(delta {sum(per.values()) - ref_total:+d})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
