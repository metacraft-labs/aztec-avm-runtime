#!/usr/bin/env python3
"""Classify the oracles a private frame actually called, by whether a SYNCHRONOUS caller could
have got the same answer.

    _m38_oracle_synchrony.py <private_oracles.ts> <m35-arm-report.json> <alias=frame.path> ...

Each frame is named `<alias>=<dotted path>`: the alias is the key the output is filed under, and it
exists because the paths themselves contain dots (`arms.private.report.executes`), so a reader that
split the output on dots would walk into the middle of a frame name.

M38's first deliverable is a measurement: for the private function that runs, which oracles does it
call, in order, and for each — can it be answered synchronously from state already inside wasm,
does it need a host round trip, or is it unimplemented?

THE THREE CLASSES, AND WHAT DECIDES EACH. None of them is a list typed here.

  unimplemented   the run's own ledger recorded the call as `refused` or `unavailable`. That is the
                  handler saying, at run time, that it did not answer — not a partition read off a
                  declaration.

  host-round-trip the handler method is declared `async`, or its body awaits. A synchronous
                  `ForeignCallExecutor::execute` cannot await a promise, in a browser or anywhere
                  else, so an `async` handler's answer cannot cross that boundary at the moment the
                  ACVM asks for it. This is a property of the DECLARATION, which is why it is read
                  off the source rather than inferred from what the call happened to do.

  sync-in-wasm    served, and the method is neither declared `async` nor awaits.

The three are disjoint by construction — `unimplemented` is decided first, and the other two
partition what is left by one predicate — and they sum to the calls the run actually made.

WHY THE OBSERVED LIST COMES FROM A RUN. A handler's declaration says what it COULD answer. This
milestone's question is what a private function DOES ask for, and those are different: of
sixty-eight oracles in the registry, the frame that completes calls three.

The residue is PRINTED rather than counted: a method the scanner cannot find is reported by name as
`unresolved` instead of falling into a class, so a parse that had silently stopped matching reads as
a list of names rather than as a smaller answer.
"""

import json
import re
import sys


def strip_comments(text: str) -> str:
    """Remove `//` and `/* */` comments without letting a `//` inside a string start one.

    The naive stripper is this repository's own recorded defect: a `//` inside a string literal ate
    the rest of the line and made a reached package look unreached.
    """
    out = []
    i, n = 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == quote:
                quote = None
            i += 1
            continue
        if c in "'\"`":
            quote = c
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


def method_bodies(code: str) -> dict:
    """Every `name(...) { ... }` / `async name(...) { ... }` shorthand method, by name.

    Returns `{name: (is_async, body)}`. Scanning the whole comment-stripped file rather than one
    object literal is deliberate: the handler is assembled from two objects (`served` and
    `discoveryServed`) plus a refusal loop, and a scanner scoped to one of them would report the
    other's methods as unresolved.
    """
    bodies = {}
    # THE INDENT RANGE IS 4 TO 8, NOT 4, AND THE FIRST DRAFT'S 4 UNDERCOUNTED IN THE DIRECTION THAT
    # READS AS GOOD NEWS. `discoveryServed` is inside a `discovery ? { … }` conditional, so its nine
    # methods sit at EIGHT spaces; with `^\s{4}` they were invisible and every one of them would have
    # been reported as `unresolved` or, worse, never asked about. Found by comparing the async set
    # this returned (4) against the one a reader counts in the file (9).
    #
    # Widening the indent lets ordinary CALL STATEMENTS at the same depth in — `record(…)` sits at
    # six — so a declaration is distinguished from a call by what FOLLOWS its parameter list: a
    # declaration is followed by a return-type annotation or a body brace, a call statement by `;`
    # or `,` or `.`. That is a property of the grammar rather than of this file's formatting.
    for m in re.finditer(r"(?m)^[ ]{4,8}(async\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*\(", code):
        is_async = m.group(1) is not None
        name = m.group(2)
        if name in ("if", "for", "while", "switch", "catch", "return", "function"):
            continue
        # Walk from the `(` to its `)`, then require a `{` and take the balanced body.
        i = m.end() - 1
        depth = 0
        while i < len(code):
            if code[i] == "(":
                depth += 1
            elif code[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        # `i` is the balanced `)`. A declaration continues with `{` or with `: <type> {`.
        tail = code[i + 1 : i + 400]
        stripped = tail.lstrip()
        if stripped.startswith((";", ",", ".", ")", "]", "=>")) or not stripped:
            continue
        if not stripped.startswith(("{", ":")):
            continue
        j = code.find("{", i)
        if j < 0:
            continue
        depth = 0
        k = j
        while k < len(code):
            if code[k] == "{":
                depth += 1
            elif code[k] == "}":
                depth -= 1
                if depth == 0:
                    break
            k += 1
        bodies[name] = (is_async, code[j : k + 1])
    return bodies


def method_name_of(oracle: str) -> str:
    """Upstream's own `^aztec_(\\w+?)_(.+)$`, which `oracleMethodName` implements."""
    m = re.match(r"^aztec_[a-z]+?_(.+)$", oracle)
    return m.group(1) if m else oracle


def json_at(doc, path):
    cur = doc
    for part in path.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def main() -> int:
    if len(sys.argv) < 4:
        sys.stderr.write(f"usage: {sys.argv[0]} <private_oracles.ts> <report.json> <frame> [frame…]\n")
        return 2

    source = open(sys.argv[1], encoding="utf8").read()
    code = strip_comments(source)
    bodies = method_bodies(code)

    # THE STRIPPER IS A THING UNDER TEST. Both halves are asserted by the caller: it left code
    # behind, and it removed prose. Reported rather than assumed.
    report = json.load(open(sys.argv[2], encoding="utf8"))

    frames = {}
    for spec in sys.argv[3:]:
        alias, _, frame_path = spec.partition("=")
        if not frame_path:
            sys.stderr.write(f"frame `{spec}` is not `<alias>=<path>`\n")
            return 2
        frame = json_at(report, frame_path)
        if frame is None:
            sys.stderr.write(f"no frame at `{frame_path}`\n")
            return 2
        calls = frame.get("oracleCalls") or []
        classified = []
        for call in calls:
            oracle = call["oracle"]
            outcome = call["outcome"]
            if outcome != "served":
                klass = "unimplemented"
                why = outcome
            else:
                method = method_name_of(oracle)
                entry = bodies.get(method)
                if entry is None:
                    klass = "unresolved"
                    why = f"no method `{method}` found in the handler source"
                else:
                    is_async, body = entry
                    awaits = re.search(r"\bawait\b", body) is not None
                    if is_async or awaits:
                        klass = "host-round-trip"
                        why = ("declared async" if is_async else "") + (
                            (" and awaits" if is_async and awaits else "awaits" if awaits else "")
                        )
                    else:
                        klass = "sync-in-wasm"
                        why = "neither declared async nor awaits"
            classified.append(
                {"seq": call["seq"], "oracle": oracle, "class": klass, "why": why}
            )
        frames[alias] = {
            "path": frame_path,
            "contract": frame.get("contractName"),
            "function": frame.get("functionName"),
            "outcome": frame.get("outcome"),
            "stoppedAtOracle": frame.get("stoppedAtOracle"),
            "calls": classified,
            "counts": {
                k: sum(1 for c in classified if c["class"] == k)
                for k in ("sync-in-wasm", "host-round-trip", "unimplemented", "unresolved")
            },
            "distinctOracles": sorted({c["oracle"] for c in classified}),
        }

    print(
        json.dumps(
            {
                "handlerMethods": len(bodies),
                "asyncMethods": sorted(n for n, (a, b) in bodies.items() if a),
                "strippedChars": len(source) - len(code),
                "codeChars": len(code),
                "frames": frames,
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
