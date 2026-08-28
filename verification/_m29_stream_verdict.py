#!/usr/bin/env python3
"""Executed, or a walk of the debug map? One predicate, applied to whichever stream it is given.

    _m29_stream_verdict.py <pairs.tsv>

`pairs.tsv` is one `pc<TAB>opcode` per line. Prints `KEY<TAB>VALUE` lines and nothing else.

===========================================================================================
WHY THIS IS A FILE AND NOT TWO INLINE SNIPPETS.
===========================================================================================

`test_browser_steps_are_executed_not_mapped` has to answer two questions with ONE instrument: does
the browser's stream look executed, and does the stream M27 used to synthesise look mapped? Two
copies of the predicate would be two things that can disagree, and the campaign's rule — "the
synthetic generator's own output must FAIL your check" — is only evidence when the failing run and
the passing run go through the same code.

===========================================================================================
THE TWO CRITERIA, AND WHY NEITHER ALONE IS ENOUGH.
===========================================================================================

  * `syntheticRuleHolds` — every opcode equals `(pc % 200) + 1`, which is the literal rule
    `browser/src/ct_download.ts` carried until M29 deleted it. It is decisive when it fires and it
    is not sufficient on its own: a producer that fabricated opcodes by a DIFFERENT rule, or that
    took them from the artifact rather than from the execution, would not trip it.

  * `pcsStrictlyIncreasing` and `pcsAllDistinct` — a walk of `brillig_locations` visits each key
    once, in ascending order, because that is what `Object.keys(...).map(Number).sort()` produces.
    An EXECUTION does not: it jumps, it calls, it loops, and it revisits. So a stream whose pcs are
    strictly increasing and pairwise distinct is a walk of a map whatever its opcodes say, and this
    is the criterion that would catch a producer that got its opcodes right and its pcs from the
    artifact.

`verdict` is `mapped` when EITHER fires and `executed` only when NEITHER does. Both are printed, so
a caller asserts the conjuncts rather than the conclusion — a conjunction whose negative case
exercises one conjunct is a conjunction this campaign has a recorded defect for.

An empty input is `verdict<TAB>degenerate`, not `executed`: an absence must not read as a pass.
"""

import sys


def main() -> int:
    if len(sys.argv) != 2:
        print("usage<TAB>_m29_stream_verdict.py <pairs.tsv>", file=sys.stderr)
        return 2
    pairs = []
    residue = []
    with open(sys.argv[1], encoding="utf-8") as handle:
        for lineno, raw in enumerate(handle, 1):
            line = raw.rstrip("\n")
            if not line:
                continue
            parts = line.split("\t")
            if len(parts) != 2:
                residue.append(f"{lineno}:{line[:40]}")
                continue
            try:
                pairs.append((int(parts[0]), int(parts[1])))
            except ValueError:
                residue.append(f"{lineno}:{line[:40]}")

    # PRINT THE RESIDUE RATHER THAN COUNTING THE MATCHES. A parser too narrow for its input
    # otherwise becomes a silent undercount in the direction that reads as good news.
    print(f"residue\t{len(residue)}")
    for item in residue[:5]:
        print(f"residueSample\t{item}")

    print(f"pairs\t{len(pairs)}")
    if not pairs:
        print("verdict\tdegenerate")
        return 0

    pcs = [p for p, _ in pairs]
    ops = [o for _, o in pairs]

    synthetic_matches = sum(1 for p, o in pairs if o == (p % 200) + 1)
    synthetic_holds = synthetic_matches == len(pairs)
    increasing = all(b > a for a, b in zip(pcs, pcs[1:]))
    all_distinct = len(set(pcs)) == len(pcs)

    print(f"distinctOpcodes\t{len(set(ops))}")
    print(f"distinctPcs\t{len(set(pcs))}")
    print(f"syntheticRuleMatches\t{synthetic_matches}")
    print(f"syntheticRuleHolds\t{1 if synthetic_holds else 0}")
    print(f"pcsStrictlyIncreasing\t{1 if increasing else 0}")
    print(f"pcsAllDistinct\t{1 if all_distinct else 0}")
    print(f"pcRevisits\t{len(pcs) - len(set(pcs))}")
    print(f"backwardJumps\t{sum(1 for a, b in zip(pcs, pcs[1:]) if b <= a)}")
    print(f"minOpcode\t{min(ops)}")
    print(f"maxOpcode\t{max(ops)}")
    mapped = synthetic_holds or (increasing and all_distinct)
    print(f"verdict\t{'mapped' if mapped else 'executed'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
