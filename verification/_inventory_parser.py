#!/usr/bin/env python3
"""Parse and judge REUSE-INVENTORY.md. Sourced by verify_reuse_inventory_complete.sh.

Takes a directory containing REUSE-INVENTORY.md and PROVENANCE.md so the same
code path can be pointed at a MUTATED copy — the negative controls in the shell
wrapper depend on that, and a checker that has never been shown to reject
anything is not a checker.

Prints ENTRIES/CHECKS/COVERED/DECISIONS lines and one PROBLEM line per failure.
Exit status is 0 even with problems: the shell wrapper turns them into
assertions so every one is reported rather than only the first.
"""

import os
import re
import sys

DECISIONS = {"depend", "vendor", "extend", "replace", "build", "open", "vendor + extend"}
NEEDS_REJECTION = {"replace", "build"}
TAGS = ("does-not-exist:", "does-not-cover:", "cannot-reach-target:")

# Phrases that assert an absence without having established it. The inventory
# exists because these were the default once — four times, in the same direction.
WEASEL = re.compile(
    r"\b(we (?:did ?n[o']t|could ?n[o']t) find|did ?n[o']t find|no equivalent(?: was)? found|"
    r"presumably|probably (?:does ?n[o']t|not?)|seems to be none|as far as (?:we|i) know|"
    r"assume[ds]? (?:there is )?no|nothing (?:obvious|found)|couldn't find)\b",
    re.I,
)

KEYS = ["upstream", "covers", "decision", "milestone", "why", "confidence"]


def parse(text):
    entries = []
    for m in re.finditer(r"^### (RI-\d+) — (.+?)$\n(.*?)(?=^### RI-|\Z)", text, re.M | re.S):
        rid, name, body = m.group(1), m.group(2).strip(), m.group(3)
        fields, last = {}, None
        for line in body.splitlines():
            fm = re.match(r"^- ([a-z-]+):\s*(.*)$", line)
            if fm:
                last = fm.group(1)
                fields[last] = fm.group(2).strip()
            elif line.startswith("  ") and line.strip() and last:
                fields[last] = (fields[last] + " " + line.strip()).strip()
        entries.append((rid, name, fields))
    return entries


def main(root, required):
    inv_path = os.path.join(root, "REUSE-INVENTORY.md")
    prov_path = os.path.join(root, "PROVENANCE.md")
    text = open(inv_path, encoding="utf-8").read()
    entries = parse(text)

    problems = []
    state = {"checks": 0}

    def check(cond, msg):
        state["checks"] += 1
        if not cond:
            problems.append(msg)

    check(len(entries) >= 20, "inventory has only %d entries; that is not an inventory of this system" % len(entries))
    ids = [e[0] for e in entries]
    check(len(ids) == len(set(ids)), "duplicate RI ids: %s" % sorted({i for i in ids if ids.count(i) > 1}))

    covered = set()
    for rid, name, f in entries:
        for k in KEYS:
            check(k in f and f[k] != "", "%s (%s): missing key '%s'" % (rid, name, k))
        decision = f.get("decision", "")
        check(decision in DECISIONS, "%s: decision %r is not in the vocabulary" % (rid, decision))
        why = f.get("why", "")
        check(len(why) >= 60, "%s: 'why' is %d chars; too short to be a reason" % (rid, len(why)))
        check(not WEASEL.search(why), "%s: 'why' asserts an absence without evidence: %r" % (rid, why[:120]))

        for slug in f.get("covers", "-").split(","):
            slug = slug.strip()
            if slug and slug != "-":
                covered.add(slug)

        base = decision.split("+")[0].strip()
        if base in NEEDS_REJECTION or decision in NEEDS_REJECTION:
            rr = f.get("rejection-reason", "")
            check(rr != "", "%s is '%s' but carries no rejection-reason" % (rid, decision))
            check(
                rr.lower() not in ("n/a", "none", "-", "tbd", ""),
                "%s is '%s' but its rejection-reason is a placeholder (%r)" % (rid, decision, rr),
            )
            check(
                rr.startswith(TAGS),
                "%s: rejection-reason must begin with one of %s; got %r" % (rid, TAGS, rr[:60]),
            )
            check(
                len(rr) >= 150,
                "%s: rejection-reason is %d chars; a specific reason names what was looked at" % (rid, len(rr)),
            )
            check(
                not WEASEL.search(rr),
                "%s: rejection-reason asserts an absence without evidence: %r" % (rid, rr[:120]),
            )
        else:
            rr = f.get("rejection-reason", "n/a")
            check(
                rr.lower() in ("n/a", "none", "-"),
                "%s is '%s' yet carries a rejection-reason; that is a contradiction" % (rid, decision),
            )

        if decision == "open":
            exp = f.get("experiment", "")
            check(
                exp != "" and exp.lower() not in ("n/a", "none", "-", "tbd"),
                "%s is 'open' but names no experiment that would settle it" % rid,
            )
            check(len(exp) >= 80, "%s: 'experiment' is %d chars; too short to be an experiment" % (rid, len(exp)))
            check(
                re.search(r"\bM\d+\b", f.get("milestone", "")) is not None,
                "%s is 'open' but its milestone does not name where the verdict is due" % rid,
            )
            check(f.get("confidence") == "open", "%s decision is 'open' but confidence is %r" % (rid, f.get("confidence")))
        else:
            check(
                f.get("confidence") != "open" or decision == "open",
                "%s has confidence 'open' but a settled decision %r" % (rid, decision),
            )

    for slug in required:
        check(slug in covered, "no inventory entry covers the component '%s'" % slug)

    prov = open(prov_path, encoding="utf-8").read()
    referenced = set(re.findall(r"\bRI-\d+\b", prov))
    check(len(referenced) >= 5, "PROVENANCE.md references only %d inventory ids" % len(referenced))
    for r in sorted(referenced):
        check(r in ids, "PROVENANCE.md references %s, which the inventory does not define" % r)

    counts = {}
    for _, _, f in entries:
        counts[f.get("decision", "?")] = counts.get(f.get("decision", "?"), 0) + 1

    print("ENTRIES %d" % len(entries))
    print("CHECKS %d" % state["checks"])
    print("COVERED %s" % " ".join(sorted(covered)))
    print("DECISIONS %s" % " ".join("%s=%d" % kv for kv in sorted(counts.items())))
    for p in problems:
        print("PROBLEM %s" % p)
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("usage: _inventory_parser.py <dir> '<required slugs>'", file=sys.stderr)
        sys.exit(2)
    sys.exit(main(sys.argv[1], sys.argv[2].split()))
