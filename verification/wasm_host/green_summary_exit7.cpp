// A wasm test binary that LIES: it prints a complete, plausible, entirely green
// gtest summary and then exits 7.
//
// It is the negative control for every check in this repo that reads a test
// binary's output. The M2 review shipped a check that reported green over a red
// run, and the M3 review proved the hazard again with a global destructor calling
// _exit(7): the binary printed "132 ran / 132 PASSED" and exited 7, and only the
// exit-status assertion caught it. This file is that mutation, kept as a
// permanent fixture instead of being performed by hand once.
//
// It is linked with the same `--import-memory --export-memory` flags as
// barretenberg's own wasm binaries, so it also exercises the host shim's memory
// path rather than a simpler one.
//
// The counts below are deliberately the ones M3's write-up quotes, so a check
// that pattern-matches on "the expected number" is caught too.

#include <cstdio>

int main()
{
    printf("[==========] Running 132 tests from 9 test suites.\n");
    printf("[----------] Global test environment set-up.\n");
    printf("[----------] Global test environment tear-down\n");
    printf("[==========] 132 tests from 9 test suites ran. (1 ms total)\n");
    printf("[  PASSED  ] 132 tests.\n");
    return 7;
}
