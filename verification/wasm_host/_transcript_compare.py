#!/usr/bin/env python3
"""Compare the native and wasm `avm_differential` transcripts.

The whole point of this script is that it does NOT filter. A comparison that says "identical apart
from the wasm-specific lines" and implements that as `grep -v wasm` is a comparison whose scope
nobody has measured: it would also swallow a *value* divergence on any line that happened to
contain the word.

So the driver emits every line that is allowed to differ with a `diag ` prefix, and this script
carries a table of exactly which `diag` keys exist, which side each may appear on, and what its
value must look like. A `diag` key that is not in the table is a FAILURE naming the key, not a line
that gets skipped. Everything else must be byte-identical, per line, with the line counts equal.

Usage:
    _transcript_compare.py <native.transcript> <wasm.transcript> <peak-page-budget>

Prints one `PASS\\t<name>\\t<detail>` or `FAIL\\t<name>\\t<detail>` row per assertion and exits 0.
The caller counts the rows; a non-zero exit means the script itself could not run.
"""

import re
import sys

# key -> (sides it must appear on, validator(native_value, wasm_value) -> (ok, detail))
#
# "sides" is one of "both" or "wasm". There is deliberately no "native" entry and no wildcard: a
# native-only diagnostic would be a hole in this comparison in the direction that matters least,
# and if one is ever added it has to be added here first.
ENUMERATED_DIAGNOSTICS = {
    "target.pointerBits": "both",
    "wasm.peakLinearMemoryPages": "wasm",
    "wasm.peakLinearMemoryKiB": "wasm",
}
# The per-program peak-memory diagnostics. Spelled out one key at a time rather than matched by a
# prefix: a prefix rule is a wildcard wearing a different hat, and a driver that grew an eighth
# program would then add a line nothing here had ever looked at.
CORPUS_PROGRAMS = ("add", "revert", "loop", "sha256", "poseidon2", "storage", "burn")
for _p in CORPUS_PROGRAMS:
    ENUMERATED_DIAGNOSTICS[f"wasm.peakLinearMemoryPages.after.{_p}"] = "wasm"

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, str(detail)))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return fh.read().split("\n")


def split(lines):
    """-> (ordinary lines, {diag key: value})"""
    ordinary = []
    diags = {}
    dup = []
    for ln in lines:
        if ln == "":
            continue
        if ln.startswith("diag "):
            rest = ln[len("diag "):]
            key, _, value = rest.partition(" ")
            if key in diags:
                dup.append(key)
            diags[key] = value
        else:
            ordinary.append(ln)
    return ordinary, diags, dup


def main():
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    native_path, wasm_path, budget_s = sys.argv[1], sys.argv[2], sys.argv[3]
    budget = int(budget_s)

    native_lines = read(native_path)
    wasm_lines = read(wasm_path)

    # A truncated run has an identical PREFIX. Both ends are pinned so it cannot pass as one.
    for label, lines in (("native", native_lines), ("wasm", wasm_lines)):
        nonempty = [l for l in lines if l != ""]
        check(f"{label} transcript declares its version first",
              bool(nonempty) and nonempty[0] == "avmDifferential.version 1",
              nonempty[0] if nonempty else "<empty>")
        check(f"{label} transcript ran to completion",
              bool(nonempty) and nonempty[-1] == "avmDifferential.done 1",
              nonempty[-1] if nonempty else "<empty>")
        check(f"{label} transcript states its coverage",
              "avmDifferential.coverage seven-hand-assembled-corpus-programs-field-for-field" in nonempty,
              "")

    n_ord, n_diag, n_dup = split(native_lines)
    w_ord, w_diag, w_dup = split(wasm_lines)

    check("no diagnostic key is emitted twice natively", not n_dup, ",".join(n_dup))
    check("no diagnostic key is emitted twice under wasm", not w_dup, ",".join(w_dup))

    # --- the enumerated diagnostics ------------------------------------------------------------
    unknown = sorted((set(n_diag) | set(w_diag)) - set(ENUMERATED_DIAGNOSTICS))
    check("every `diag` key the transcripts emit is enumerated here", not unknown, ",".join(unknown))

    for key, sides in sorted(ENUMERATED_DIAGNOSTICS.items()):
        if sides == "both":
            check(f"enumerated diagnostic `{key}` is present on both sides",
                  key in n_diag and key in w_diag,
                  f"native={key in n_diag} wasm={key in w_diag}")
        elif sides == "wasm":
            check(f"enumerated diagnostic `{key}` is present under wasm and absent natively",
                  key in w_diag and key not in n_diag,
                  f"native={key in n_diag} wasm={key in w_diag}")

    # `target.pointerBits` is not merely "allowed to differ": it must differ, and by the exact
    # amount that makes the whole exercise meaningful. A wasm build that reported 64 would be a
    # native binary that had been handed in twice.
    check("the native target is 64-bit", n_diag.get("target.pointerBits") == "64",
          n_diag.get("target.pointerBits"))
    check("the wasm target is 32-bit", w_diag.get("target.pointerBits") == "32",
          w_diag.get("target.pointerBits"))

    pages_s = w_diag.get("wasm.peakLinearMemoryPages", "")
    kib_s = w_diag.get("wasm.peakLinearMemoryKiB", "")
    check("peak linear memory is reported as an integer page count",
          re.fullmatch(r"[0-9]+", pages_s or "") is not None, pages_s)
    if re.fullmatch(r"[0-9]+", pages_s or ""):
        pages = int(pages_s)
        check("peak linear memory is non-trivial (the AVM really allocated)", pages > 16, pages)
        check(f"peak linear memory is within the recorded budget of {budget} pages",
              pages <= budget, f"{pages} pages / {pages * 64} KiB, budget {budget}")
        check("the KiB figure is the page count times 64",
              kib_s == str(pages * 64), f"{kib_s} vs {pages * 64}")

        # Per program. wasm linear memory never shrinks, so the sequence must be monotone
        # non-decreasing and its last value must be the whole-run peak. That makes "the heaviest
        # corpus program" a measurement: it is the program after which the sequence last rose.
        per_program = []
        missing = []
        for prog in CORPUS_PROGRAMS:
            v = w_diag.get(f"wasm.peakLinearMemoryPages.after.{prog}")
            if v is None or not re.fullmatch(r"[0-9]+", v):
                missing.append(prog)
            else:
                per_program.append((prog, int(v)))
        check("every corpus program reports the linear memory in use after it", not missing,
              ",".join(missing))
        if len(per_program) == len(CORPUS_PROGRAMS):
            values = [v for _, v in per_program]
            check("linear memory never shrinks across the corpus (wasm memory cannot)",
                  all(values[i] <= values[i + 1] for i in range(len(values) - 1)),
                  " ".join(f"{p}={v}" for p, v in per_program))
            check("the whole-run peak equals the value after the last program",
                  values[-1] == pages, f"{values[-1]} vs {pages}")
            heaviest = per_program[0][0]
            for i in range(1, len(values)):
                if values[i] > values[i - 1]:
                    heaviest = per_program[i][0]
            check("the heaviest corpus program is identified by measurement", True,
                  f"{heaviest} ({max(values)} pages); full sequence " +
                  " ".join(f"{p}={v}" for p, v in per_program))
            # And the honest caveat, asserted rather than written down somewhere else: the spread
            # across the corpus is small, because the footprint is dominated by the world state's
            # genesis prefill and the module's static data rather than by the program.
            check("the corpus spread in peak pages is recorded", True,
                  f"min={min(values)} max={max(values)} spread={max(values) - min(values)}")

    # --- everything else must be identical, per line -------------------------------------------
    check("the two transcripts carry the same number of non-diagnostic lines",
          len(n_ord) == len(w_ord), f"native={len(n_ord)} wasm={len(w_ord)}")

    diffs = []
    for i, (a, b) in enumerate(zip(n_ord, w_ord)):
        if a != b:
            diffs.append((i + 1, a, b))
    check("every non-diagnostic line is identical native versus wasm",
          not diffs,
          "; ".join(f"line {i}: [{a}] != [{b}]" for i, a, b in diffs[:5]) + (
              f" (+{len(diffs) - 5} more)" if len(diffs) > 5 else ""))

    # A count, so the result is quotable and so an empty comparison cannot look like a green one.
    check("the compared set is not empty", len(n_ord) > 1000, len(n_ord))

    # Substance rather than volume: the lines that carry a ROOT are counted separately, because
    # "1,308 identical lines" would still be true of a transcript that printed no root at all.
    root_re = re.compile(r" 0x[0-9a-f]{64} size=[0-9]+$")
    n_roots = [l for l in n_ord if root_re.search(l)]
    w_roots = [l for l in w_ord if root_re.search(l)]
    check("the transcripts carry root+size lines", len(n_roots) >= 150, len(n_roots))
    check("the root+size lines are identical native versus wasm", n_roots == w_roots,
          f"native={len(n_roots)} wasm={len(w_roots)}")

    # And the roots must not all be the same value: a comparison of constants is not a comparison.
    distinct_roots = {root_re.search(l).group(0).split()[0] for l in n_roots}
    check("the roots actually move across the transcript", len(distinct_roots) >= 20,
          len(distinct_roots))

    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
