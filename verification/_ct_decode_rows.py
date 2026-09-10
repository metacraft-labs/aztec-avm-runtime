#!/usr/bin/env python3
"""Flatten a `ct-print --full` decode into `KEY<TAB>VALUE` rows, from EITHER of its two schemas.

    _ct_decode_rows.py <ct-print-full.json>

---------------------------------------------------------------------------
WHY THIS EXISTS: `ct-print` HAS TWO OUTPUT SHAPES AND A CHECK CANNOT PICK ONE
---------------------------------------------------------------------------

`ct-print` diverts any container carrying an `events.log` to its LEGACY combined-stream reader, and
sends every other container to the split-stream reader. The two emit DIFFERENT JSON:

    legacy   {"events": [{"type": "Step", "line": N}, {"type": "Value", ...},
                         {"type": "Path"}, {"type": "Function"}, {"type": "VariableName"}]}
    split    {"events": [{"kind": "step", "line": N, "vars": [...]},
                         {"kind": "call_entry"}, {"kind": "io"}],
              "paths": [...], "varnames": [...], "counts": {...}}

The pure-Rust writer emits an `events.log`; the Nim writer does not. So which shape a check gets
back is decided by WHICH WRITER PRODUCED THE CONTAINER — and a check written against one shape
reports **zero of everything** for a container written by the other, with no error anywhere. That
is not a hypothetical: M24's roundtrip content assertions counted `type == "Step"` and every one of
them read 0 against a container the reader had decoded perfectly.

So the rows below are the same rows from either shape, and `SHAPE` says which one was read. A check
that cares can assert it; a check that only wants the content does not have to know.

---------------------------------------------------------------------------
WHAT IS AND IS NOT THE SAME ACROSS THE TWO
---------------------------------------------------------------------------

`COUNT_Value` is the one that needs saying. The legacy stream emits one `Value` EVENT per variable,
so five per step; the split stream carries one value RECORD per step with the five variables inside
it. Counting records where the other counts variables would report 5,000 against 25,000 and look
like four fifths of the data had gone missing. This counts VARIABLES in both.

`COUNT_Path` and `COUNT_Function` are interning-table sizes in the split shape and events in the
legacy one; both are reported as the number of distinct entries, which is what every caller means.

A decode this cannot classify is `SHAPE<TAB>unknown` and a `PROBLEM` row — never a report of zeroes,
because "the container is empty" and "I do not understand this decode" must not read the same.
"""

import json
import sys
from collections import Counter


def rows(d):
    events = d.get("events")
    if not isinstance(events, list):
        return None

    kinds = Counter(e.get("kind") for e in events if isinstance(e, dict))
    types = Counter(e.get("type") for e in events if isinstance(e, dict))
    # `counts` is emitted only by the split reader, and `kind` only appears on its events. Either
    # is sufficient; requiring one of the two rather than both means an empty split decode is still
    # classified as split.
    is_split = "counts" in d or any(kinds.get(k) for k in ("step", "call_entry", "io"))
    out = []

    meta = d.get("metadata") or {}
    out.append(("SHAPE", "split" if is_split else "legacy"))
    out.append(("PROGRAM", meta.get("program", "MISSING")))
    out.append(("WORKDIR", meta.get("workdir", "MISSING")))

    paths = d.get("paths") or []
    if is_split:
        steps = [e for e in events if e.get("kind") == "step"]
        counts = d.get("counts") or {}
        varnames = sorted({str(v) for v in (d.get("varnames") or [])})
        n_paths = len(paths)
        n_funcs = int(counts.get("functions", 0) or 0)
        n_calls = kinds.get("call_entry", 0)
        # Variables, not records — see the header.
        n_values = sum(len(e.get("vars") or []) for e in steps)
    else:
        steps = [e for e in events if e.get("type") == "Step"]
        varnames = sorted(
            {str(e.get("name")) for e in events if e.get("type") == "VariableName"}
        )
        n_paths = types.get("Path", 0) or len(paths)
        n_funcs = types.get("Function", 0)
        n_calls = types.get("Call", 0)
        n_values = types.get("Value", 0)
        if not paths:
            paths = [str(e.get("name")) for e in events if e.get("type") == "Path"]

    out.append(("PATHS", str(len(paths))))
    out.append(("PATH0", str(paths[0]) if paths else "MISSING"))
    out.append(("COUNT_Step", str(len(steps))))
    out.append(("COUNT_Value", str(n_values)))
    out.append(("COUNT_Path", str(n_paths)))
    out.append(("COUNT_Function", str(n_funcs)))
    out.append(("COUNT_Call", str(n_calls)))
    out.append(("FIRSTLINE", str(steps[0].get("line")) if steps else "MISSING"))
    out.append(("LASTLINE", str(steps[-1].get("line")) if steps else "MISSING"))
    out.append(("VARNAMES", ",".join(varnames)))
    return out


def main(path):
    try:
        d = json.load(open(path, encoding="utf-8"))
    except Exception as e:  # noqa: BLE001 — the caller wants the reason, whatever it is
        print(f"PROBLEM\t{e}")
        return 0
    r = rows(d)
    if r is None:
        print("SHAPE\tunknown")
        print(f"PROBLEM\t{path} carries no `events` array; it is not a ct-print --full decode")
        return 0
    for k, v in r:
        print(f"{k}\t{v}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: _ct_decode_rows.py <ct-print-full.json>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
