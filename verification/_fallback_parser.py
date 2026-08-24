#!/usr/bin/env python3
"""Parse and validate FALLBACK.md's trigger block.

M16's first deliverable is "the triggers, narrowed and stated before the fact", and its first
verification entry asks for "a recorded evaluation against M14 and M15's findings, so the decision
not to execute is evidenced rather than assumed". The failure mode this parser exists to catch is a
document that *reads* like an evaluation: three triggers, three confident verdicts, and nothing
underneath any of them.

So the rules are about substance rather than shape:

  * exactly three triggers, numbered 1, 2, 3;
  * every trigger is a CONJUNCTION, so every trigger has at least two conjuncts, and every conjunct
    carries its own verdict, its own evidence and its own reason — a trigger judged as a whole is
    rejected, because that is how a conjunction gets dismissed on its weakest limb without anybody
    noticing the others were never looked at;
  * a verdict is `true`, `false` or `unresolved`, and nothing else;
  * EVIDENCE MUST RESOLVE. It is `<path> :: <needle>`, the path must exist, and the needle must
    occur in that file. A needle is matched against the file with whitespace collapsed, so a claim
    may be a sentence even where the file wraps it; and it must be at least 20 characters, because
    a two-word needle resolves against anything;
  * a reason is at least 120 characters, which is not a quality bar but does refuse `false.`;
  * `conjunction: fired` if and only if EVERY conjunct is `true`. Both directions are checked: a
    conjunction marked not-fired with all-true conjuncts is rejected, and so is one marked fired
    with a conjunct that is false or unresolved;
  * `outcome: not-required` if and only if NO conjunction fired, again in both directions;
  * the not-a-trigger record must name what it closes with.

Output is `PROBLEM <text>` lines for every violation and `OK <key>=<value>` lines for what it
measured. The caller asserts; this prints.

Usage:  _fallback_parser.py <repo-root>
"""

import os
import re
import sys

VERDICTS = ("true", "false", "unresolved")
MIN_NEEDLE = 20
MIN_REASON = 120


def normalise(text):
    return re.sub(r"\s+", " ", text)


def main():
    if len(sys.argv) != 2:
        print("PROBLEM usage: _fallback_parser.py <repo-root>")
        return 1
    root = sys.argv[1]
    path = os.path.join(root, "FALLBACK.md")
    if not os.path.isfile(path):
        print("PROBLEM FALLBACK.md does not exist at %s" % path)
        return 1

    doc = open(path, encoding="utf-8").read()
    m = re.search(r"<!-- BEGIN:triggers -->(.*?)<!-- END:triggers -->", doc, re.S)
    if not m:
        print("PROBLEM FALLBACK.md has no <!-- BEGIN:triggers --> ... <!-- END:triggers --> block")
        return 1
    block = m.group(1)

    problems = []
    measured = []
    file_cache = {}

    def body_of(rel):
        if rel not in file_cache:
            p = os.path.normpath(os.path.join(root, rel))
            if not os.path.isfile(p):
                file_cache[rel] = None
            else:
                file_cache[rel] = normalise(open(p, encoding="utf-8", errors="replace").read())
        return file_cache[rel]

    # Split into `### ` sections, keeping the heading with its body.
    sections = re.split(r"^### ", block, flags=re.M)[1:]
    triggers = {}
    outcome = None
    outcome_reason = ""
    not_a_trigger = None
    closed_by = []

    for sec in sections:
        heading = sec.splitlines()[0].strip()
        fields = []
        for line in sec.splitlines()[1:]:
            fm = re.match(r"^- ([a-z-]+):\s*(.*)$", line)
            if fm:
                fields.append((fm.group(1), fm.group(2).strip()))

        keys = [k for k, _ in fields]

        if "trigger" in keys:
            num = dict(fields).get("trigger")
            if not re.fullmatch(r"[123]", num or ""):
                problems.append("trigger number is not 1, 2 or 3 in section %r" % heading)
                continue
            num = int(num)
            if num in triggers:
                problems.append("trigger %d is declared twice" % num)
                continue
            clause = dict(fields).get("clause", "")
            if len(clause) < 40:
                problems.append("trigger %d has no clause, or one too short to be the milestone's" % num)

            # Walk the fields in order: every `conjunct` must be followed by exactly
            # verdict, evidence, reason, in that order, before the next conjunct.
            conjuncts = []
            i = 0
            while i < len(fields):
                k, v = fields[i]
                if k != "conjunct":
                    i += 1
                    continue
                want = ["verdict", "evidence", "reason"]
                got = {}
                ok = True
                for j, w in enumerate(want, start=1):
                    if i + j >= len(fields) or fields[i + j][0] != w:
                        problems.append(
                            "trigger %d, conjunct %r: expected a '%s:' line here" % (num, v[:60], w))
                        ok = False
                        break
                    got[w] = fields[i + j][1]
                if not ok:
                    i += 1
                    continue
                conjuncts.append((v, got))
                i += 4

            if len(conjuncts) < 2:
                problems.append(
                    "trigger %d has %d conjunct(s); each of M16's triggers is a conjunction and "
                    "must be evaluated conjunct by conjunct" % (num, len(conjuncts)))

            for text, got in conjuncts:
                if got["verdict"] not in VERDICTS:
                    problems.append("trigger %d, conjunct %r: verdict %r is outside the vocabulary %s"
                                    % (num, text[:60], got["verdict"], "/".join(VERDICTS)))
                ev = got["evidence"]
                if " :: " not in ev:
                    problems.append("trigger %d, conjunct %r: evidence is not '<path> :: <needle>'"
                                    % (num, text[:60]))
                else:
                    rel, needle = ev.split(" :: ", 1)
                    rel, needle = rel.strip(), needle.strip()
                    if len(needle) < MIN_NEEDLE:
                        problems.append(
                            "trigger %d, conjunct %r: the evidence needle is %d characters; a needle "
                            "shorter than %d resolves against anything"
                            % (num, text[:60], len(needle), MIN_NEEDLE))
                    body = body_of(rel)
                    if body is None:
                        problems.append("trigger %d, conjunct %r: evidence names %s, which does not exist"
                                        % (num, text[:60], rel))
                    elif normalise(needle) not in body:
                        problems.append(
                            "trigger %d, conjunct %r: the evidence needle is absent from %s: %r"
                            % (num, text[:60], rel, needle[:80]))
                if len(got["reason"]) < MIN_REASON:
                    problems.append(
                        "trigger %d, conjunct %r: the reason is %d characters, which is too short to "
                        "be an evaluation" % (num, text[:60], len(got["reason"])))

            conj = dict(fields).get("conjunction")
            if conj not in ("fired", "not-fired"):
                problems.append("trigger %d has no conjunction verdict of 'fired' or 'not-fired'" % num)
            else:
                all_true = bool(conjuncts) and all(g["verdict"] == "true" for _, g in conjuncts)
                if all_true and conj != "fired":
                    problems.append(
                        "trigger %d records every conjunct as true and the conjunction as %s" % (num, conj))
                if not all_true and conj == "fired":
                    problems.append(
                        "trigger %d records the conjunction as fired while a conjunct is not true" % num)
            triggers[num] = (conjuncts, conj)
            measured.append(("trigger.%d.conjuncts" % num, len(conjuncts)))
            measured.append(("trigger.%d.conjunction" % num, conj))
            for idx, (_t, g) in enumerate(conjuncts, start=1):
                measured.append(("trigger.%d.verdict.%d" % (num, idx), g["verdict"]))

        elif "outcome" in keys:
            d = dict(fields)
            outcome = d.get("outcome")
            outcome_reason = d.get("reason", "")

        elif "not-a-trigger" in keys:
            d = dict(fields)
            not_a_trigger = d.get("not-a-trigger")
            closed_by = (d.get("closed-by") or "").split()
            if len((d.get("reason") or "")) < MIN_REASON:
                problems.append("the not-a-trigger record has no reason, or one too short")

    for n in (1, 2, 3):
        if n not in triggers:
            problems.append("trigger %d is missing; M16 states three and all three must be evaluated" % n)

    if outcome not in ("not-required", "executed"):
        problems.append("the outcome is %r; it must be 'not-required' or 'executed'" % outcome)
    else:
        any_fired = any(c == "fired" for _cs, c in triggers.values())
        if any_fired and outcome != "executed":
            problems.append("a conjunction fired and the outcome is %r" % outcome)
        if not any_fired and outcome != "not-required":
            problems.append("no conjunction fired and the outcome is %r" % outcome)
        if len(outcome_reason) < MIN_REASON:
            problems.append("the outcome has no reason, or one too short to be one")
    measured.append(("outcome", outcome))

    if not not_a_trigger or "correctness" not in not_a_trigger:
        problems.append("FALLBACK.md does not record that doubt about the trees' correctness is NOT a trigger")
    if sorted(closed_by) != ["M7", "M8"]:
        problems.append("the not-a-trigger record must name M7 and M8 as what closes it; it names %r"
                        % (closed_by,))
    measured.append(("not_a_trigger.closed_by", ",".join(closed_by)))

    total_conjuncts = sum(len(cs) for cs, _ in triggers.values())
    measured.append(("conjuncts.total", total_conjuncts))
    measured.append(("triggers.total", len(triggers)))

    for p in problems:
        print("PROBLEM %s" % p)
    for k, v in measured:
        print("OK %s=%s" % (k, v))
    return 0


if __name__ == "__main__":
    sys.exit(main())
