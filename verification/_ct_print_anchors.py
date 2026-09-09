#!/usr/bin/env python3
"""The three trace-format-nim revisions `build_ct_print.sh` builds a reader at.

    _ct_print_anchors.py <pins.json>  ->  "<reader> <control> <writer>"

A file rather than a heredoc inside the shell script, because the shell already opens a heredoc to
feed this program and a heredoc inside a heredoc terminates at whichever delimiter comes first.
That is not a style preference: the nested form silently ended the outer document early and left
the rest of the script as shell input.

Every field is required. A missing one prints an empty string in its slot and the caller refuses
by name, rather than this program guessing a default that would send a build at the wrong revision.
"""

import json
import sys


def main(path):
    anchors = json.load(open(path, encoding="utf-8"))["anchors"]
    reader = anchors.get("trace_format_nim") or {}
    writer = anchors.get("trace_format_nim_writer") or {}
    print(
        reader.get("commit", ""),
        reader.get("control_commit", ""),
        writer.get("commit", ""),
    )
    return 0


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: _ct_print_anchors.py <pins.json>", file=sys.stderr)
        raise SystemExit(2)
    raise SystemExit(main(sys.argv[1]))
