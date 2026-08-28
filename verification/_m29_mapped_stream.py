#!/usr/bin/env python3
"""M27's synthesised step stream, regenerated so it can be REFUSED.

    _m29_mapped_stream.py <token-artifact.json> <count>

Prints `pc<TAB>opcode` lines: the artifact's own first `count` mapped program counters, in
ascending order, with `opcode = (pc % 200) + 1`.

===========================================================================================
THIS IS THE NEGATIVE CONTROL, AND IT IS A RE-IMPLEMENTATION ON PURPOSE.
===========================================================================================

M29's deliverable is that the synthesised path is DELETED and not kept as a fallback. Deleted code
cannot be run, so the control that proves `test_browser_steps_are_executed_not_mapped` measures what
its name says has to reconstruct the stream from the same inputs M27's producer had. The three lines
that mattered in `browser/src/ct_download.ts` before M29 removed them were:

    const mapped = Object.keys(debugInfo.brillig_locations['0'] ?? {})
      .map(Number).filter(Number.isInteger).sort((a, b) => a - b).slice(0, options.steps ?? 64);
    ...
    opcode: (pc % 200) + 1,

and this file is those three lines in Python. If the verdict script ever stops calling this stream
`mapped`, the check that rests on it fails — which is the point: a discriminator that cannot say
"mapped" about the thing it was built to reject is not a discriminator.

`debug_symbols` is raw-DEFLATE + base64 + JSON, which is `zlib.decompressobj(-15)` here and
`DecompressionStream('deflate-raw')` in a page. It is the artifact's OWN encoding either way; this
file decodes it, it does not define it.
"""

import base64
import json
import sys
import zlib


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: _m29_mapped_stream.py <artifact.json> <count>", file=sys.stderr)
        return 2
    artifact = json.load(open(sys.argv[1], encoding="utf-8"))
    count = int(sys.argv[2])

    dispatch = next((f for f in artifact["functions"] if f["name"] == "public_dispatch"), None)
    if dispatch is None:
        print("the artifact has no public_dispatch function", file=sys.stderr)
        return 3

    raw = zlib.decompressobj(-15).decompress(base64.b64decode(dispatch["debug_symbols"]))
    debug_info = json.loads(raw.decode("utf-8"))["debug_infos"][0]
    locations = debug_info.get("brillig_locations", {}).get("0", {})

    pcs = sorted(int(k) for k in locations.keys())[:count]
    if not pcs:
        print("the artifact's brillig_locations['0'] is empty", file=sys.stderr)
        return 4
    for pc in pcs:
        print(f"{pc}\t{(pc % 200) + 1}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
