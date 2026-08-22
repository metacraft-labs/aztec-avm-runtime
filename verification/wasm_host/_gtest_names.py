#!/usr/bin/env python3
"""Read gtest output and print full test names, one per line.

Two modes, because the two things M7 compares are produced by two different gtest
outputs and a check that conflated them would compare a list of tests that EXIST
with a list of tests that PASSED:

  list <file>     parse `--gtest_list_tests` output           -> every test that exists
  ran  <file>     parse a run transcript                      -> every test that STARTED
  passed <file>   parse a run transcript                      -> every test that reported OK

`--gtest_list_tests` prints

    SuiteName.
      TestName
      TestName/0  # GetParam() = 4

and value-parameterised suites arrive as `Prefix/SuiteName.` with `TestName/0`
under them. The `#` comment is gtest's own annotation and is not part of the name.

A run transcript prints `[ RUN      ] Suite.Test` and `[       OK ] Suite.Test (0 ms)`.
`[  FAILED  ] Suite.Test` is deliberately NOT counted as passed.

Exit status is 2 on an unreadable file and 3 when the requested mode found no
names at all -- an empty answer here is always a broken input, never a result,
and every caller compares SETS, where an empty set silently satisfies "is a
subset of".
"""

import re
import sys


def parse_list(text):
    names = []
    suite = None
    for raw in text.splitlines():
        if not raw.strip():
            continue
        line = raw.split("#", 1)[0].rstrip()
        if not line:
            continue
        if not raw.startswith(" ") and not raw.startswith("\t"):
            if line.endswith("."):
                suite = line[:-1]
            else:
                # gtest also prints "Running main() from ..." and similar preamble.
                suite = None
            continue
        if suite is not None:
            names.append(suite + "." + line.strip())
    return names


RUN_RE = re.compile(r"^\[ RUN      \] (\S+)$")
OK_RE = re.compile(r"^\[       OK \] (\S+) \(")
FAIL_RE = re.compile(r"^\[  FAILED  \] (\S+)(?: \(| \()")


def parse_transcript(text, which):
    names = []
    for line in text.splitlines():
        if which == "ran":
            m = RUN_RE.match(line)
        elif which == "passed":
            m = OK_RE.match(line)
        elif which == "failed":
            m = FAIL_RE.match(line)
        else:
            raise SystemExit("unknown mode " + which)
        if m:
            names.append(m.group(1))
    return names


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: _gtest_names.py <list|ran|passed|failed> <file>\n")
        return 2
    mode, path = argv[1], argv[2]
    try:
        with open(path, "r", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        sys.stderr.write("_gtest_names.py: %s\n" % exc)
        return 2
    if mode == "list":
        names = parse_list(text)
    elif mode in ("ran", "passed", "failed"):
        names = parse_transcript(text, mode)
    else:
        sys.stderr.write("_gtest_names.py: unknown mode %r\n" % mode)
        return 2
    if mode != "failed" and not names:
        sys.stderr.write("_gtest_names.py: %s: no test names in %s\n" % (mode, path))
        return 3
    # Sorted and de-duplicated: every caller compares this as a SET, and a
    # duplicate would make a count disagree with a set comparison.
    for n in sorted(set(names)):
        print(n)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
