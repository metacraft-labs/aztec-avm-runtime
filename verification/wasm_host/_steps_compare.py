#!/usr/bin/env python3
"""Compare two `avm_differential steps` transcripts, per record.

The subject is 39,086 individual per-instruction records, each carrying context id, pc, opcode,
cumulative l2 and da gas and the contract address. They are compared LINE FOR LINE AND IN ORDER,
never by count: equal counts survive a swap, a rename, or a drop plus an addition, and this
campaign has more than once quoted a number a set comparison would have caught.

As in M8's `_transcript_compare.py`, nothing is filtered. Every line allowed to differ between the
two targets carries a `diag ` prefix and is enumerated here by key; a `diag` key not in the table
is a FAILURE naming the key, not a line that gets skipped. There is deliberately no prefix rule.

Usage:
    _steps_compare.py <a.steps> <b.steps> <peak-page-budget> <sentinel-opcode>

Prints one `PASS\\t<name>\\t<detail>` or `FAIL\\t<name>\\t<detail>` row per assertion and exits 0.
A non-zero exit means the script itself could not run: 2 for a usage error, 3 for an input that
would make every comparison vacuous.
"""

import re
import sys

PROGRAMS = ("add", "revert", "loop", "sha256", "poseidon2", "storage", "burn", "oob")

# The instruction count of each program, which is also its step-record count. Identities.
EXPECTED_STEPS = {
    "add": 4,
    "revert": 2,
    "loop": 132,
    "sha256": 28,
    "poseidon2": 8,
    "storage": 6,
    "burn": 38903,
    "oob": 3,
}

# key -> the side(s) it must appear on. "both" or "wasm"; no wildcard and no "native", for M8's
# reason: a native-only diagnostic would be a hole in the direction that matters least, and adding
# one has to start here.
ENUMERATED_DIAGNOSTICS = {
    "target.pointerBits": "both",
    "wasm.stepsPeakLinearMemoryPages": "wasm",
    "wasm.stepsPeakLinearMemoryKiB": "wasm",
}
for _p in PROGRAMS:
    ENUMERATED_DIAGNOSTICS[f"wasm.stepsLinearMemoryPages.after.{_p}"] = "wasm"

RECORD_RE = re.compile(
    r"^steps\.([a-z0-9]+)\.([0-9]+) ctx=([0-9]+) pc=([0-9]+) op=([0-9]+) "
    r"l2=([0-9]+) da=([0-9]+) addr=(0x[0-9a-f]{64})$"
)

RESULTS = []


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, str(detail)))


def read(path):
    with open(path, encoding="utf-8") as fh:
        return [ln for ln in fh.read().split("\n") if ln != ""]


def split(lines):
    ordinary, diags, dup = [], {}, []
    for ln in lines:
        if ln.startswith("diag "):
            key, _, value = ln[len("diag "):].partition(" ")
            if key in diags:
                dup.append(key)
            diags[key] = value
        else:
            ordinary.append(ln)
    return ordinary, diags, dup


def main():
    if len(sys.argv) != 5:
        sys.stderr.write(__doc__)
        return 2
    a_path, b_path, budget, sentinel = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])

    a_lines, b_lines = read(a_path), read(b_path)
    # A membership test over an empty haystack is a silent success. Refuse rather than pass.
    if not a_lines or not b_lines:
        sys.stderr.write(f"empty transcript: {a_path}={len(a_lines)} {b_path}={len(b_lines)}\n")
        return 3

    # Both ends pinned, so a truncated run — whose surviving lines are an identical PREFIX —
    # cannot pass as a complete one.
    for label, lines in (("A", a_lines), ("B", b_lines)):
        check(f"{label} declares its version first", lines[0] == "avmSteps.version 1", lines[0])
        check(f"{label} ran to completion", lines[-1] == "avmSteps.done 1", lines[-1])
        check(f"{label} states its coverage",
              "avmSteps.coverage eight-hand-assembled-programs-per-record-seven-of-them-M8s-plus-oob"
              in lines, "")
        check(f"{label} was built from a tree carrying the observer patch",
              "avmSteps.observerCompiledIn 1" in lines, "")
        check(f"{label} ran all {len(PROGRAMS)} programs",
              f"avmSteps.programs.count {len(PROGRAMS)}" in lines, "")

    a_ord, a_diag, a_dup = split(a_lines)
    b_ord, b_diag, b_dup = split(b_lines)

    check("no diagnostic key is emitted twice on side A", not a_dup, ",".join(a_dup))
    check("no diagnostic key is emitted twice on side B", not b_dup, ",".join(b_dup))

    unknown = sorted((set(a_diag) | set(b_diag)) - set(ENUMERATED_DIAGNOSTICS))
    check("every `diag` key the transcripts emit is enumerated here", not unknown, ",".join(unknown))
    check("the enumeration is exhausted rather than merely large",
          len(ENUMERATED_DIAGNOSTICS) == 11, len(ENUMERATED_DIAGNOSTICS))

    for key, sides in sorted(ENUMERATED_DIAGNOSTICS.items()):
        if sides == "both":
            check(f"enumerated diagnostic `{key}` is present on both sides",
                  key in a_diag and key in b_diag, f"A={key in a_diag} B={key in b_diag}")
        else:
            check(f"enumerated diagnostic `{key}` is present under wasm and absent natively",
                  key in b_diag and key not in a_diag, f"A={key in a_diag} B={key in b_diag}")

    # Not merely allowed to differ: it MUST differ, and by the amount that makes the exercise
    # meaningful. A wasm side reporting 64 would be a native binary handed in twice.
    check("the A target is 64-bit", a_diag.get("target.pointerBits") == "64",
          a_diag.get("target.pointerBits"))
    check("the B target is 32-bit", b_diag.get("target.pointerBits") == "32",
          b_diag.get("target.pointerBits"))

    pages_s = b_diag.get("wasm.stepsPeakLinearMemoryPages", "")
    kib_s = b_diag.get("wasm.stepsPeakLinearMemoryKiB", "")
    check("peak linear memory is reported as an integer page count",
          re.fullmatch(r"[0-9]+", pages_s or "") is not None, pages_s)
    if re.fullmatch(r"[0-9]+", pages_s or ""):
        pages = int(pages_s)
        check("materialising every step record really costs linear memory "
              "(M8's untraced run is 173 pages)", pages > 173, pages)
        check(f"peak linear memory is within the recorded budget of {budget} pages",
              pages <= budget, f"{pages} pages / {pages * 64} KiB, budget {budget}")
        check("the KiB figure is the page count times 64", kib_s == str(pages * 64),
              f"{kib_s} vs {pages * 64}")
        # The PER-PROGRAM page counts are NOT asserted equal between hosts and must not be: M8
        # established that peak linear memory is a function of the host's WASI environment, and
        # the two hosts disagree on the intermediates here (V8 170/171/201, wasmtime 169/201)
        # while agreeing on the final peak. The sequence is asserted MONOTONE instead, which is a
        # property of wasm memory rather than of the host.
        seq, missing = [], []
        for prog in PROGRAMS:
            v = b_diag.get(f"wasm.stepsLinearMemoryPages.after.{prog}")
            if v is None or not re.fullmatch(r"[0-9]+", v):
                missing.append(prog)
            else:
                seq.append((prog, int(v)))
        check("every program reports the linear memory in use after it", not missing,
              ",".join(missing))
        if len(seq) == len(PROGRAMS):
            values = [v for _, v in seq]
            check("linear memory never shrinks across the corpus (wasm memory cannot)",
                  all(values[i] <= values[i + 1] for i in range(len(values) - 1)),
                  " ".join(f"{p}={v}" for p, v in seq))
            check("the whole-run peak equals the value after the last program",
                  values[-1] == pages, f"{values[-1]} vs {pages}")

    # --- everything else, per line and in order -------------------------------------------------
    check("the two transcripts carry the same number of non-diagnostic lines",
          len(a_ord) == len(b_ord), f"A={len(a_ord)} B={len(b_ord)}")
    diffs = [(i + 1, x, y) for i, (x, y) in enumerate(zip(a_ord, b_ord)) if x != y]
    check("every non-diagnostic line is identical, per line and in order", not diffs,
          "; ".join(f"line {i}: [{x}] != [{y}]" for i, x, y in diffs[:5])
          + (f" (+{len(diffs) - 5} more)" if len(diffs) > 5 else ""))

    # --- the records themselves, which is what the milestone is about ---------------------------
    a_rec = [RECORD_RE.match(l) for l in a_ord]
    b_rec = [RECORD_RE.match(l) for l in b_ord]
    a_rec = [m for m in a_rec if m]
    b_rec = [m for m in b_rec if m]
    check("side A carries per-instruction step records", len(a_rec) > 0, len(a_rec))
    check("the two sides carry the same number of step records",
          len(a_rec) == len(b_rec), f"A={len(a_rec)} B={len(b_rec)}")
    check("the step records are identical field for field",
          [m.groups() for m in a_rec] == [m.groups() for m in b_rec], "")

    per_program = {}
    for m in a_rec:
        per_program.setdefault(m.group(1), []).append(m)
    for prog in PROGRAMS:
        got = len(per_program.get(prog, []))
        want = EXPECTED_STEPS[prog]
        check(f"`{prog}` produced exactly {want} step records", got == want, got)
        # The indices must be 0..n-1 with no gap and no repeat: a record set that happens to have
        # the right size is not a record set that covers the execution.
        idx = sorted(int(m.group(2)) for m in per_program.get(prog, []))
        check(f"`{prog}`'s record indices are 0..{want - 1} with no gap",
              idx == list(range(want)), f"{len(idx)} indices, first={idx[:1]} last={idx[-1:]}")

    total = sum(EXPECTED_STEPS.values())
    check(f"the whole comparison is {total} step records", len(a_rec) == total, len(a_rec))

    # The records must not be constant, or "identical" would be a statement about a constant.
    distinct_pcs = {m.group(4) for m in a_rec}
    distinct_ops = {m.group(5) for m in a_rec}
    distinct_gas = {m.group(6) for m in a_rec}
    check("the pc moves across the records", len(distinct_pcs) >= 10, len(distinct_pcs))
    check("more than one opcode is observed", len(distinct_ops) >= 5, len(distinct_ops))
    check("the cumulative gas moves across the records", len(distinct_gas) >= 100,
          len(distinct_gas))

    # --- the observer's own promises, read off both transcripts ---------------------------------
    a_fields = {}
    for ln in a_ord:
        k, _, v = ln.partition(" ")
        if not RECORD_RE.match(ln):
            a_fields[k] = v
    for prog in PROGRAMS:
        want = EXPECTED_STEPS[prog]
        check(f"`{prog}` executed {want} instructions by the simulator's own statistic",
              a_fields.get(f"steps.{prog}.instructionsExecuted") == str(want),
              a_fields.get(f"steps.{prog}.instructionsExecuted"))
        check(f"`{prog}`'s record count equals that statistic",
              a_fields.get(f"steps.{prog}.countEqualsInstructionsExecuted") == "1",
              a_fields.get(f"steps.{prog}.countEqualsInstructionsExecuted"))

    # `oob` throws before the opcode is known, so its last record must carry the sentinel — and the
    # sentinel's numeric value is derived from upstream's own opcodes.hpp by the caller, not by us.
    last_oob = a_fields.get("steps.oob.last", "")
    check("`oob`'s last record reports the sentinel opcode "
          "(the fetch threw before the opcode was known)",
          f"op={sentinel} " in last_oob + " ", last_oob)
    check("`oob` is flagged as ending on the sentinel",
          a_fields.get("steps.oob.lastOpcodeIsSentinel") == "1",
          a_fields.get("steps.oob.lastOpcodeIsSentinel"))
    # And `revert`, which halts NORMALLY, must not be — otherwise "the sentinel marks a failed
    # fetch" would be a statement about every program.
    check("`revert` does NOT end on the sentinel (it halts normally)",
          a_fields.get("steps.revert.lastOpcodeIsSentinel") == "0",
          a_fields.get("steps.revert.lastOpcodeIsSentinel"))

    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
