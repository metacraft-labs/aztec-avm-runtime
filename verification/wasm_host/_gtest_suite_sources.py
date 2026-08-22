#!/usr/bin/env python3
"""Map every gtest suite declared under a source tree to the file that declares it.

    _gtest_suite_sources.py <source-root>          -> "<suite>\t<relative path>" per line

This exists so M7's exclusion list has a REASON per excluded test that is
re-derived from the tree rather than typed into a document. A test's reason for
being outside the wasm build is a property of the file it lives in -- whether
that file is inside the `simulation/`, `common/` and `tooling/` globs the
`AVM_SIM_TESTS` target uses, or in `constraining/`, `tracegen/`,
`integration_tests/` or `dsl/`, which need the proving stack.

Suites are found from gtest's own declaration macros:

    TEST(Suite, Name)                     TEST_F(Suite, Name)
    TEST_P(Suite, Name)                   TYPED_TEST_SUITE(Suite, ...)
    TYPED_TEST(Suite, Name)               TYPED_TEST_P(Suite, Name)
    INSTANTIATE_TEST_SUITE_P(Prefix, Suite, ...)
    INSTANTIATE_TYPED_TEST_SUITE_P(Prefix, Suite, ...)

A value-parameterised run reports `Prefix/Suite.Name/0` and a typed one
`Suite/0.Name`; `suite_of(full_name)` below undoes both, so the caller maps a
name gtest PRINTED back to a file in the tree.
"""

import os
import re
import sys

DECL = re.compile(
    r"^\s*(TEST|TEST_F|TEST_P|TYPED_TEST|TYPED_TEST_P|TYPED_TEST_SUITE|"
    r"TYPED_TEST_SUITE_P|INSTANTIATE_TEST_SUITE_P|INSTANTIATE_TYPED_TEST_SUITE_P)"
    r"\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,",
    re.M,
)
INSTANTIATE = re.compile(
    r"^\s*(INSTANTIATE_TEST_SUITE_P|INSTANTIATE_TYPED_TEST_SUITE_P)"
    r"\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*,",
    re.M,
)


def suite_of(full_name):
    """`Prefix/Suite.Name/0` and `Suite/0.Name` -> `Suite`."""
    head = full_name.split(".", 1)[0]
    parts = head.split("/")
    # A trailing purely-numeric component is the typed-test index.
    while len(parts) > 1 and parts[-1].isdigit():
        parts.pop()
    # A leading component is the INSTANTIATE_TEST_SUITE_P prefix.
    return parts[-1]


def scan(root):
    out = {}
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if not (fn.endswith(".test.cpp") or fn.endswith(".test.hpp")):
                continue
            path = os.path.join(dirpath, fn)
            rel = os.path.relpath(path, root)
            with open(path, "r", errors="replace") as fh:
                text = fh.read()
            for m in DECL.finditer(text):
                out.setdefault(m.group(2), set()).add(rel)
            for m in INSTANTIATE.finditer(text):
                out.setdefault(m.group(3), set()).add(rel)
    return out


def main(argv):
    if len(argv) != 2:
        sys.stderr.write("usage: _gtest_suite_sources.py <source-root>\n")
        return 2
    root = argv[1]
    if not os.path.isdir(root):
        sys.stderr.write("_gtest_suite_sources.py: not a directory: %s\n" % root)
        return 2
    table = scan(root)
    if not table:
        sys.stderr.write("_gtest_suite_sources.py: no gtest suites under %s\n" % root)
        return 3
    for suite in sorted(table):
        for rel in sorted(table[suite]):
            print("%s\t%s" % (suite, rel))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
