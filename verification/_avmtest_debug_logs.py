#!/usr/bin/env python3
"""Extract a function's `debug_log*` calls out of the AvmTest contract's Noir SOURCE.

Read on stdin: the contract's `main.nr`. Argument: the function name whose body to scan.
Printed on stdout: one JSON object per call, `{"kind": …, "message": …, "fields": [ints]}`.

WHY THIS EXISTS RATHER THAN A LIST OF EXPECTED STRINGS IN THE CHECK. `test_debug_log_events_surface`
compares the messages the AVM surfaced against the messages the CONTRACT emits, and a list typed
into the check is a constant that drifts away from the contract silently — this campaign's
"a constant you have just typed into a check looks like a measurement to the person typing it".
The contract is read at the pinned anchor, so the comparison has two independently-derived sides.

IT PRINTS ITS RESIDUE. A scanner that counts its matches hides the ones it could not place; this one
reports every `logging::` line inside the body that it did not classify, and the check asserts that
list empty. A class that is too narrow then becomes a red line rather than a silent undercount —
`CAMPAIGN-BRIEF.md`'s own remedy for the `[A-Za-z0-9_/]+` family.

IT IS ALSO ITS OWN NEGATIVE CONTROL'S INSTRUMENT: asked for a function with no logging calls it
prints an empty list, which is what the check uses to show the extractor can answer "none".
"""

import json
import re
import sys

CALL = re.compile(
    r"logging::(?P<kind>debug_log|debug_log_format|fatal_log|trace_log_format)\s*\(\s*"
    r'"(?P<message>(?:[^"\\]|\\.)*)"'
    r"(?P<rest>[^;]*)\)\s*;"
)
ARRAY = re.compile(r"\[\s*([0-9]+(?:\s*,\s*[0-9]+)*)\s*\]")
# Any mention of the logging module inside the body, so a call shape this file cannot place is
# reported instead of dropped.
ANY = re.compile(r"logging::")


def body_of(source: str, fn: str) -> str:
    start = re.search(r"\bfn\s+" + re.escape(fn) + r"\s*\(", source)
    if start is None:
        raise SystemExit(f"_avmtest_debug_logs: no `fn {fn}(` in the source given")
    i = source.index("{", start.end() - 1)
    depth = 0
    for j in range(i, len(source)):
        if source[j] == "{":
            depth += 1
        elif source[j] == "}":
            depth -= 1
            if depth == 0:
                return source[i + 1 : j]
    raise SystemExit(f"_avmtest_debug_logs: `fn {fn}` has no balanced body")


def unescape(s: str) -> str:
    return s.encode("utf-8").decode("unicode_escape")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: _avmtest_debug_logs.py <function-name> < main.nr")
    body = body_of(sys.stdin.read(), sys.argv[1])
    calls = []
    covered = []
    for m in CALL.finditer(body):
        arr = ARRAY.search(m.group("rest"))
        calls.append(
            {
                "kind": m.group("kind"),
                "message": unescape(m.group("message")),
                "fields": [int(x.strip()) for x in arr.group(1).split(",")] if arr else [],
            }
        )
        covered.append((m.start(), m.end()))

    residue = []
    for m in ANY.finditer(body):
        if not any(a <= m.start() < b for a, b in covered):
            line = body[body.rfind("\n", 0, m.start()) + 1 : body.find("\n", m.start())]
            residue.append(line.strip())

    print(json.dumps({"calls": calls, "unclassified": residue}, separators=(",", ":")))


if __name__ == "__main__":
    main()
