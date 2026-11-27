#!/usr/bin/env python3
"""Read a `ct-print --full` decode of a Live-Chain-Replay container, as L3 and L5 assert on it.

    _l3_decode.py check          <decode.json>        TOTAL_STEPS / RECORDER_STEPS / ENTRY rows
    _l3_decode.py lines          <decode.json>        one `line` per RECORDER step, in order
    _l3_decode.py path-lines     <decode.json>        one `path_id:line` per recorder step
    _l3_decode.py basename-lines <decode.json>        one `<basename of the path>:line` per step
    _l3_decode.py frames         <decode.json>        the frames opened, comma-joined, in order
    _l3_decode.py log            <decode.json> <key>  the text of the first TraceLogEvent <key>
    _l3_decode.py log-keys       <decode.json>        every TraceLogEvent key, sorted, comma-joined
    _l3_decode.py log-count      <decode.json> <key>  how many TraceLogEvents carry <key>

The three checks that use this (`e2e_settled_transaction_produces_steppable_ct`,
`test_recording_declares_its_provenance`, `e2e_resolved_contract_records_at_source_level`) were
written against the LEGACY combined-stream decode: `type == "Step"`, `Function` events, and
trace-log events spelled `event_kind == "elkTraceLogEvent"` with their text in `content`. The
reader at `pins.json` `anchors.trace_format_nim` (`051efd22b0`) emits only the SPLIT decode:
`kind` is `step` / `call_entry` / `call_exit` / `io`, a trace-log event is
`kind: "io", io_kind: "TraceLogEvent"` with its text in `text`, and the interning tables are
top-level arrays. Read with the old keys, every filter matched nothing and the checks reported
empty answers (`DRIFT.md` D37).

ONLY THE SPLIT SHAPE IS READ, AND ANYTHING ELSE IS A NON-ZERO EXIT. Accepting the legacy spelling
beside it would let a reader that regressed to it pass here unnoticed (`DRIFT.md` D31 made the same
choice for `io_kind`). And a decode this cannot classify must never come back as zero rows: "the
container has no steps" and "this is not the decode I understand" must not read the same, which is
exactly the failure these checks were in. Every command validates the decode first — its shape,
the step, call-entry and io listings against the reader's own `counts`, and the entry step below —
so none of them can print a partial or empty answer over a decode it refused.

THE ENTRY STEP IS NOT A RECORDER STEP, AND IT IS CHECKED RATHER THAN SKIPPED.
`codetracer-trace-format-spec` `trace-events.md`, "Recorder Integration — Starting a Recording":
*a recording contains one more step than the recorder emitted — the entry step, which `start`
emits.* The writer's `start` interns `<toplevel>`, opens its call (the root, depth 0) and records
that step at line 1 (`DRIFT.md` D27). The L3/L5 claims are about the AVM's steps, so the entry step
is excluded from every per-step listing — but only after it has been found exactly where the spec
puts it: the first step, index 0, `<toplevel>`, depth 0, path 0, line 1, carrying no variables, and
no other step in the root frame. A container with no entry step, two, or one that carries data is
refused (exit 3), so the exclusion is a measured fact and can never hide a recorder step.
"""

import json
import sys

ENTRY_FUNCTION = "<toplevel>"


class Refused(Exception):
    """The decode is not one this reader may answer for."""


def load(path):
    try:
        with open(path, encoding="utf-8") as f:
            doc = json.load(f)
    except (OSError, ValueError) as exc:
        raise Refused(f"{path}: not readable JSON: {exc}") from exc
    if not isinstance(doc, dict) or not isinstance(doc.get("events"), list):
        raise Refused(f"{path}: not a ct-print --full decode (no events array)")
    if not isinstance(doc.get("counts"), dict) or not isinstance(doc.get("paths"), list):
        raise Refused(f"{path}: not a SPLIT-stream decode (no top-level counts / paths)")
    for i, e in enumerate(doc["events"]):
        if not isinstance(e, dict) or "kind" not in e:
            raise Refused(f"{path}: event {i} has no `kind`, so this is not the split decode")
        if "type" in e:
            raise Refused(f"{path}: event {i} carries the LEGACY `type` key; refusing to read "
                          "the legacy combined-stream decode")
    # Every listed stream is cross-checked against the reader's own `counts`, so a decode that
    # dropped records (or a filter here that stopped matching them) is a refusal, never a short
    # answer: the step, call-entry and io listings each must carry exactly what `counts` declares.
    steps = [e for e in doc["events"] if e["kind"] == "step"]
    for kind, key in (("step", "steps"), ("call_entry", "calls"), ("io", "io_events")):
        declared = doc["counts"].get(key)
        found = sum(1 for e in doc["events"] if e["kind"] == kind)
        if declared != found:
            raise Refused(f"{path}: counts.{key} is {declared!r} but the decode carries "
                          f"{found} `{kind}` event(s)")
    return doc, steps


def recorder_steps(path):
    doc, steps = load(path)
    if not steps:
        raise Refused(f"{path}: no step at all, so not even the entry step `start` writes")
    entry = steps[0]
    want = {"step_index": 0, "function": ENTRY_FUNCTION, "depth": 0, "path_id": 0, "line": 1}
    for k, v in want.items():
        if entry.get(k) != v:
            raise Refused(f"{path}: the first step is not the writer's entry step: "
                          f"{k} is {entry.get(k)!r}, expected {v!r}")
    if entry.get("vars"):
        raise Refused(f"{path}: the entry step carries {len(entry['vars'])} variable(s); "
                      "the recorder writes none there")
    rest = steps[1:]
    for e in rest:
        if e.get("depth") == 0 or e.get("function") == ENTRY_FUNCTION:
            raise Refused(f"{path}: step {e.get('step_index')!r} is a second step in the root "
                          "frame, so the entry step is not unique")
    return doc, steps, rest


def trace_log_events(path):
    # Through `recorder_steps`, not bare `load`: a decode with no entry step (an empty one, say)
    # must be a refusal here too, not an empty key list or a count of 0.
    doc, _, _ = recorder_steps(path)
    return [e for e in doc["events"] if e["kind"] == "io" and e.get("io_kind") == "TraceLogEvent"]


def main(argv):
    if len(argv) < 3:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        return 2
    cmd, path, args = argv[1], argv[2], argv[3:]
    try:
        if cmd == "check":
            _, steps, rest = recorder_steps(path)
            print(f"TOTAL_STEPS\t{len(steps)}")
            print(f"RECORDER_STEPS\t{len(rest)}")
            print("ENTRY\tok")
        elif cmd == "lines":
            _, _, rest = recorder_steps(path)
            for e in rest:
                print(e["line"])
        elif cmd == "path-lines":
            _, _, rest = recorder_steps(path)
            for e in rest:
                print(f'{e["path_id"]}:{e["line"]}')
        elif cmd == "basename-lines":
            doc, _, rest = recorder_steps(path)
            paths = doc["paths"]
            for e in rest:
                print(f'{paths[e["path_id"]].split("/")[-1]}:{e["line"]}')
        elif cmd == "frames":
            doc, _, _ = recorder_steps(path)
            print(",".join(str(e.get("function", "")) for e in doc["events"]
                           if e["kind"] == "call_entry"))
        elif cmd == "log" and len(args) == 1:
            for e in trace_log_events(path):
                if e.get("metadata") == args[0]:
                    print(e.get("text", ""))
                    break
        elif cmd == "log-keys":
            print(",".join(sorted({e["metadata"] for e in trace_log_events(path)
                                   if "metadata" in e})))
        elif cmd == "log-count" and len(args) == 1:
            print(sum(1 for e in trace_log_events(path) if e.get("metadata") == args[0]))
        else:
            print(f"_l3_decode: unknown command or arity: {cmd} {args}", file=sys.stderr)
            return 2
    except Refused as exc:
        print(f"_l3_decode: {exc}", file=sys.stderr)
        return 3
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
