#!/usr/bin/env python3
"""Derive M7's exclusion list, one row per EXCLUDED TEST, with its reason.

    _exclusions.py <vm2_tests-list> <vm2_sim_tests-list> <vm2-source-root>

prints, sorted, one tab-separated row per test that upstream's native `vm2_tests`
declares and the wasm `vm2_sim_tests` does not:

    <full test name>\t<file that declares its suite>\t<reason code>

The reason is DERIVED from the file, never typed in: `AVM_SIM_TESTS` selects test
sources by directory (`simulation/`, `common/`, `tooling/`), so where a test's
source file sits IS the reason it is in or out. Codes:

  proving-stack        constraining/**  -- the constrained-relation tests. They
                       exercise the `vm2` module, which links `sumcheck`,
                       `stdlib_honk_verifier` and `goblin_avm`.
  tracegen             tracegen/**      -- trace generation, same module.
  proving-stack+dsl    integration_tests/** -- simulate -> tracegen -> prove, and
                       `vm2_tests` links `dsl` for them.
  dsl                  dsl/**           -- recursion-constraint tests over `dsl`.
  tracegen-fixture     the ONE simulation-side file left out:
                       `common/avm_io.test.cpp`, whose tests call
                       `testing::get_minimal_trace_with_pi()`.

Any other simulation-side file appearing here is a fault, not a category: the
script exits 4 and names it, so the list cannot quietly grow a sixth reason.

Exit status: 0 with rows on stdout; 2 on a usage or input error; 3 if either
input list is empty or the sim list is not a subset of the full list (both of
which would make the exclusion list meaningless); 4 on an unattributable test.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _gtest_suite_sources import scan, suite_of  # noqa: E402
from _gtest_names import parse_list  # noqa: E402

REASONS = (
    ("constraining/", "proving-stack"),
    ("tracegen/", "tracegen"),
    ("integration_tests/", "proving-stack+dsl"),
    ("dsl/", "dsl"),
)

# The single simulation-side file the AVM_SIM_TESTS target drops, and why.
SIM_SIDE_EXCLUDED = {"common/avm_io.test.cpp": "tracegen-fixture"}


def reason_for(rel):
    for prefix, code in REASONS:
        if rel.startswith(prefix):
            return code
    return SIM_SIDE_EXCLUDED.get(rel)


def main(argv):
    if len(argv) != 4:
        sys.stderr.write(
            "usage: _exclusions.py <vm2_tests-list> <vm2_sim_tests-list> <vm2-source-root>\n"
        )
        return 2
    all_path, sim_path, root = argv[1], argv[2], argv[3]
    for p in (all_path, sim_path):
        if not os.path.isfile(p):
            sys.stderr.write("_exclusions.py: missing input: %s\n" % p)
            return 2
    if not os.path.isdir(root):
        sys.stderr.write("_exclusions.py: not a directory: %s\n" % root)
        return 2

    all_names = set(parse_list(open(all_path, errors="replace").read()))
    sim_names = set(parse_list(open(sim_path, errors="replace").read()))
    if not all_names or not sim_names:
        sys.stderr.write(
            "_exclusions.py: empty test list (%d in %s, %d in %s)\n"
            % (len(all_names), all_path, len(sim_names), sim_path)
        )
        return 3
    stray = sim_names - all_names
    if stray:
        sys.stderr.write(
            "_exclusions.py: %d test(s) in the wasm target are not in vm2_tests: %s\n"
            % (len(stray), ", ".join(sorted(stray)[:5]))
        )
        return 3

    table = scan(root)
    rows = []
    unattributed = []
    for name in sorted(all_names - sim_names):
        files = table.get(suite_of(name))
        if not files or len(files) != 1:
            unattributed.append((name, sorted(files) if files else []))
            continue
        rel = sorted(files)[0]
        code = reason_for(rel)
        if code is None:
            unattributed.append((name, [rel]))
            continue
        rows.append("%s\t%s\t%s" % (name, rel, code))
    if unattributed:
        for name, files in unattributed[:20]:
            sys.stderr.write(
                "_exclusions.py: cannot attribute %s (files: %s)\n" % (name, files)
            )
        sys.stderr.write(
            "_exclusions.py: %d test(s) have no derivable reason\n" % len(unattributed)
        )
        return 4
    for r in rows:
        print(r)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
