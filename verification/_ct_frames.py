#!/usr/bin/env python3
"""Flatten a `ct-print --full` decode into the frame tree, as `KEY<TAB>VALUE` rows.

    _ct_frames.py <ct-print-full.json>

WHY A SEPARATE READER RATHER THAN A GREP. M26's deliverable is that a private-half step and a
public-half step are distinguishable **by frame**, and a frame is a `Call`/`Return` pair around a
run of `Step`s — a shape a line-oriented grep cannot see. Asserting on frame names alone would be
satisfied by a container in which every frame is a sibling, which is precisely the failure this is
written to catch: nesting is the claim, so nesting is what is computed.

WHAT IT PRINTS, and every row is a fact a check can compare rather than a summary it has to trust:

    EVENTS      <n>                        total decoded events
    STEPS       <n>
    CALLS       <n>
    RETURNS     <n>
    FUNCTION    <id>  <name>  <path_id>  <line>
    FRAME       <index>  <depth>  <name>  <steps>   one row per Call, in the order they open
    UNBALANCED  <n>                        frames still open at the end (0 is not required)
    EVENT       <metadata>  <content>      every `TraceLogEvent`
    VALUE       <name>  <kind>  <text-or-int>       every named value, in order
    VARNAMES    <n>                        the variable-name table's size
    PATH        <index>  <path>

`FRAME`'s `depth` is the number of frames open when it opened, so a nested frame's depth is
strictly greater than its parent's. `steps` counts the `Step` events between this `Call` and its
matching `Return` **inclusive of nested frames' steps**, because that is what a stepper shows when
it is stopped on the frame — and a check that wants the exclusive count can subtract its children.

A malformed decode is a non-zero exit with the reason on stderr, never a partial report: a reader
that printed what it could would turn "the container is wrong" into "the check found fewer frames".
"""

import json
import sys


def main(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    if not isinstance(doc, dict) or "events" not in doc:
        print(f"_ct_frames: {path} is not a ct-print --full decode", file=sys.stderr)
        return 2
    events = doc["events"]

    # `ct-print` HAS TWO OUTPUT SCHEMAS AND THIS READS BOTH.
    #
    # The legacy combined-stream decode tags events with `type` (`"Step"`,
    # `"Call"`, `"Return"`, `"Function"`, `"VariableName"`). The split-stream
    # decode tags them with `kind` (`"step"`, `"call_entry"`, `"call_exit"`,
    # `"io"`) and hoists the interning tables into top-level `functions` /
    # `varnames` arrays instead of emitting them as events.
    #
    # Reading only the first shape over a split container is not an error — it
    # finds no matching events and reports ZERO, successfully. That is this
    # campaign's most repeated defect and it has already been paid for twice, so
    # the normalisation is here rather than at each call site.
    def ev_type(e):
        t = e.get("type")
        if t is not None:
            return t
        return {
            "step": "Step",
            "call_entry": "Call",
            "call_exit": "Return",
            "io": "Event",
        }.get(e.get("kind"), e.get("kind"))

    out = []
    functions = {}
    fn_order = 0
    # `VariableName` events number the variable table in emission order and `Value` events carry a
    # `variable_id` INTO it; a report that printed the id would make a check assert on an ordinal,
    # which is the shape that keeps passing when the table shifts underneath it.
    varnames = []
    if isinstance(doc.get("varnames"), list):
        varnames = [str(v) for v in doc["varnames"]]
    else:
        for e in events:
            if e.get("type") == "VariableName":
                varnames.append(e.get("name", ""))

    if isinstance(doc.get("functions"), list):
        # The split decode carries the interning table itself, so the function
        # table is read from it rather than reconstructed from events that the
        # split streams do not emit.
        for name in doc["functions"]:
            functions[fn_order] = (str(name), -1, -1)
            out.append("FUNCTION\t%d\t%s\t%s\t%s" % (fn_order, name, -1, -1))
            fn_order += 1
    else:
        for e in events:
            if e.get("type") == "Function":
                functions[fn_order] = (e.get("name", ""), e.get("path_id", -1), e.get("line", -1))
                out.append(
                    "FUNCTION\t%d\t%s\t%s\t%s"
                    % (fn_order, e.get("name", ""), e.get("path_id", -1), e.get("line", -1))
                )
                fn_order += 1

    stack = []
    frames = []
    steps = calls = returns = 0
    for e in events:
        t = ev_type(e)
        if t == "Step":
            steps += 1
            for fr in stack:
                frames[fr]["steps"] += 1
            # THE SPLIT DECODE CARRIES VALUES ON THE STEP, not as separate
            # events: `values.dat` is parallel-indexed to `steps.dat`, so a
            # step's variables arrive with it rather than after it. The legacy
            # combined stream emitted each as its own `Value` event, which is
            # the `t == "Value"` branch below.
            for var in e.get("vars") or []:
                v = var.get("value") or {}
                kind = v.get("kind", "")
                if kind == "String":
                    shown = v.get("text", "")
                elif kind == "Int":
                    shown = str(v.get("i", ""))
                elif kind == "Raw":
                    shown = v.get("r", "")
                else:
                    shown = kind
                name = var.get("varname") or "<unnamed>"
                out.append("VALUE\t%s\t%s\t%s" % (name, kind, str(shown).replace("\t", " ")))
        elif t == "Call":
            calls += 1
            fid = e.get("function_id", -1)
            name = functions.get(fid, ("<unknown>",))[0]
            frames.append({"name": name, "depth": len(stack), "steps": 0, "args": len(e.get("args", []))})
            stack.append(len(frames) - 1)
        elif t == "Return":
            returns += 1
            if stack:
                stack.pop()
        elif t == "Event":
            # `content` in the legacy decode, `text` in the split one. The
            # metadata slot is spelled the same in both — it is what carries
            # `ct.trace-join`, so reading only `content` finds the record's
            # TEXT missing while its key is right there.
            content = e.get("content")
            if content is None:
                content = e.get("text", "")
            out.append("EVENT\t%s\t%s" % (e.get("metadata", ""), str(content).replace("\t", " ")))
        elif t == "Value":
            v = e.get("value", {})
            kind = v.get("kind", "")
            if kind == "String":
                shown = v.get("text", "")
            elif kind == "Int":
                shown = str(v.get("i", ""))
            elif kind == "Raw":
                shown = v.get("r", "")
            else:
                shown = kind
            vid = e.get("variable_id", -1)
            name = varnames[vid] if isinstance(vid, int) and 0 <= vid < len(varnames) else "<unnamed>"
            out.append("VALUE\t%s\t%s\t%s" % (name, kind, shown))

    for i, p in enumerate(doc.get("paths", [])):
        out.append("PATH\t%d\t%s" % (i, p))
    for i, fr in enumerate(frames):
        out.append(
            "FRAME\t%d\t%d\t%s\t%d\t%d" % (i, fr["depth"], fr["name"], fr["steps"], fr["args"])
        )
    print("EVENTS\t%d" % len(events))
    print("STEPS\t%d" % steps)
    print("CALLS\t%d" % calls)
    print("RETURNS\t%d" % returns)
    print("UNBALANCED\t%d" % len(stack))
    print("VARNAMES\t%d" % len(varnames))
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: _ct_frames.py <ct-print-full.json>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
