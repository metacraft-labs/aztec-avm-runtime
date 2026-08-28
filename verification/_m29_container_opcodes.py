#!/usr/bin/env python3
"""The opcodes that are actually IN the container, read back through the reference reader.

    _m29_container_opcodes.py <ct-print --full output> [histogram]

With no second argument, prints one opcode per Step record, in order. With `histogram`, prints
`<opcode><TAB><count>` sorted by opcode.

===========================================================================================
WHY THIS EXISTS, AND IT IS A COVERAGE GAP THAT A MUTATION FOUND.
===========================================================================================

`test_browser_steps_are_executed_not_mapped` ran its discriminator over the stream the PAGE
DRAINED — `arms.publicOnly.transfer.executed.records` — and over the recording's own reported
`distinctOpcodes`, which `ct_download.ts` computes from the same drained steps. Both are upstream of
the writer. Mutation M1 put M27's `opcode: (pc % 200) + 1` back into the recorder, changing what is
WRITTEN while leaving what was DRAINED alone, and the check reported **42 assertions, 1 failure** —
the one failure being a `grep` of the source tree. Every behavioural assertion passed over a
container full of fabricated opcodes.

That is this campaign's "anything asserted must be read from the artefact" in its exact shape: the
number was read from the producer's own report rather than from the thing the producer produced.

===========================================================================================
HOW THE OPCODE IS FOUND, AND WHY IT IS NOT A FIXED VARIABLE ID.
===========================================================================================

`ct-print --full` interns a variable NAME once and then refers to it by id:

    { "type": "VariableName", "name": "opcode" }
    { "type": "Value", "variable_id": 1, "value": { "kind": "Int", "i": 39, … } }

so the id is whatever order the writer happened to emit the names in. This resolves the id from the
`VariableName` records rather than pinning `1`, and REFUSES if the name never appears — a scanner
that silently found no opcodes would print an empty histogram, which compares equal to another empty
one.

The pc is deliberately NOT reconstructed: at rung 1 a Step's `line` is a SOURCE line and the pc is
not in the container at all, which is the whole point of the source mapping. The opcode multiset is
what the container can be asked, and it is enough — the synthetic rule changes it beyond recognition.
"""

import json
import sys
from collections import Counter


def main() -> int:
    if len(sys.argv) not in (2, 3):
        print("usage: _m29_container_opcodes.py <ct-print.json> [histogram]", file=sys.stderr)
        return 2
    doc = json.load(open(sys.argv[1], encoding="utf-8"))
    events = doc.get("events")
    if not isinstance(events, list):
        print("the reader's output has no 'events' array", file=sys.stderr)
        return 3

    opcode_ids = set()
    pending_name = None
    opcodes = []
    in_step = False
    for event in events:
        kind = event.get("type")
        if kind == "VariableName":
            pending_name = event.get("name")
        elif kind == "Value":
            vid = event.get("variable_id")
            if pending_name == "opcode" and isinstance(vid, int):
                opcode_ids.add(vid)
            pending_name = None
            if in_step and vid in opcode_ids:
                value = event.get("value", {})
                if value.get("kind") == "Int":
                    opcodes.append(int(value["i"]))
                    in_step = False
        elif kind == "Step":
            in_step = True
            pending_name = None
        else:
            pending_name = None

    if not opcode_ids:
        print("no VariableName record names 'opcode'", file=sys.stderr)
        return 4
    if not opcodes:
        print("the 'opcode' variable was named but no Step carried a value for it", file=sys.stderr)
        return 5

    if len(sys.argv) == 3 and sys.argv[2] == "histogram":
        for op, n in sorted(Counter(opcodes).items()):
            print(f"{op}\t{n}")
    else:
        for op in opcodes:
            print(op)
    return 0


if __name__ == "__main__":
    sys.exit(main())
