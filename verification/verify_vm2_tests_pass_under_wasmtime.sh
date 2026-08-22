#!/usr/bin/env bash
# M7: the same suite runs to completion under wasmtime, so no result in this
# milestone rests on a single host.
#
# Getting there is not a formality and the two obstacles are stated rather than
# routed around:
#
#   * barretenberg links `--import-memory`, and wasmtime cannot supply an
#     imported memory from the command line in any version. Upstream's own runner
#     used `-Sthreads`, which wasmtime removed.
#   * wasmtime 21.0.2 (nixpkgs/nixos-24.05), which still HAS `-Sthreads` and which
#     M4's review used for exactly this job, cannot load this module at all:
#     M6's build carries real C++ exceptions and 21 rejects the exception refs.
#     That is asserted here, by running it, because "the old route is closed" is
#     a claim about a binary and not an opinion.
#
# So the import is satisfied statically with binaryen's `wasm-merge`, using the
# limits the module itself declares. The merged module is not byte-identical to
# the shipped one, which is why the V8 run over the unmodified artefact is the
# primary measurement and this is the cross-check; the two are required to agree
# PER TEST, not by count.

set -uo pipefail

TEST_NAME=verify_vm2_tests_pass_under_wasmtime
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"

require_nix
m7_measured
m7_require_artifacts "$M7_WASM_BIN"

# --- the shipped binary cannot run on wasmtime unaided ----------------------
BARE="$M7_WORK/wasmtime-bare.log"
m6_in_devshell '
  timeout --foreground --preserve-status -s KILL 120 wasmtime run --dir=. "$1" --gtest_list_tests 2>&1
' "$M7_WASM_BIN" >"$BARE" 2>&1
bare_rc=$?
assert_false "wasmtime cannot instantiate the shipped --import-memory binary" test "$bare_rc" -eq 0
assert_contains "and it says so by naming the import it has not been given" \
  "env::memory" "$(cat "$BARE")"

wt_version="$(m6_in_devshell 'wasmtime --version' 2>/dev/null | tail -1)"
assert_prefix "the dev shell's wasmtime is 47" "wasmtime 47" "$wt_version"

# --- the route M4 used is closed, and that is measured ----------------------
# wasmtime 21.0.2 still has -Sthreads, which is how M4 ran upstream's threaded CI
# binary. It cannot load THIS module.
WT21="$(nix build --no-link --print-out-paths 'github:NixOS/nixpkgs/nixos-24.05#wasmtime' 2>/dev/null)"
if [ -n "$WT21" ] && [ -x "$WT21/bin/wasmtime" ]; then
  assert_prefix "wasmtime 21.0.2 realises from nixpkgs/nixos-24.05" "wasmtime-cli 21.0.2" \
    "$("$WT21/bin/wasmtime" --version 2>&1 | head -1)"
  OLD="$M7_WORK/wasmtime21.log"
  timeout 120 "$WT21/bin/wasmtime" run -Wthreads=y -Sthreads=y --dir=/ "$M7_WASM_BIN" \
    --gtest_list_tests >"$OLD" 2>&1
  old_rc=$?
  assert_false "wasmtime 21 does NOT run this module" test "$old_rc" -eq 0
  assert_contains "and it fails on the exception handling M6's build introduced" \
    "exception refs not supported" "$(cat "$OLD")"
else
  die "could not realise wasmtime 21.0.2 from nixpkgs/nixos-24.05 — the negative arm cannot run"
fi

# --- the run ----------------------------------------------------------------
OUT="$M7_WORK/wasmtime-vm2_sim_tests.log"
m7_run_wasmtime "$M7_WASM_BIN" "$OUT"
wt_rc=$?

MERGED="$M7_WORK/$(basename "$M7_WASM_BIN").merged.wasm"
assert_file "the memory-satisfied module was produced" "$MERGED"
merged_imports="$(m6_in_devshell '
  node -e "
    const fs=require(\"fs\");
    const m=new WebAssembly.Module(fs.readFileSync(process.argv[1]));
    for (const i of WebAssembly.Module.imports(m)) console.log(i.module+\".\"+i.name);
  " "$1"' "$MERGED" 2>/dev/null)"
assert_eq "and it imports no memory any more" 0 \
  "$(printf '%s\n' "$merged_imports" | grep -c '^env\.memory$')"
assert_ge "while still importing WASI" 10 \
  "$(printf '%s\n' "$merged_imports" | grep -c '^wasi_snapshot_preview1\.')"

assert_eq "the suite exits 0 under wasmtime 47" 0 "$wt_rc"
assert_eq "gtest's summary reports $M7_EXPECTED_SIM_TESTS tests ran" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_summary_ran "$OUT")"
assert_eq "from $M7_EXPECTED_SIM_SUITES suites" \
  "$M7_EXPECTED_SIM_SUITES" "$(m7_summary_suites "$OUT")"
assert_eq "and $M7_EXPECTED_SIM_TESTS PASSED" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_summary_passed "$OUT")"
assert_eq "the per-test [ OK ] lines agree with it" \
  "$M7_EXPECTED_SIM_TESTS" "$(m7_count passed "$OUT")"
assert_eq "no test reported FAILED" 0 "$(m7_count failed "$OUT")"

# --- the two hosts agree PER TEST -------------------------------------------
m7_names passed "$OUT" >"$M7_WORK/wasmtime-passed.txt"
V8OUT="$M7_WORK/v8-vm2_sim_tests.log"
if [ ! -f "$V8OUT" ]; then
  note "no V8 transcript on record — running verify_vm2_tests_pass_under_v8 to produce one"
  "$VERIFY_DIR/verify_vm2_tests_pass_under_v8.sh" >"$M7_WORK/v8-for-record.log" 2>&1 \
    || die "could not produce a V8 transcript: see $M7_WORK/v8-for-record.log"
fi
m7_require_artifacts "$V8OUT"
m7_names passed "$V8OUT" >"$M7_WORK/v8-passed.txt"
m7_set_equal "wasmtime and V8 pass the same tests, per test" \
  "$M7_WORK/wasmtime-passed.txt" "$M7_WORK/v8-passed.txt"
m7_set_equal "and both are exactly the committed included-test list" \
  "$M7_WORK/wasmtime-passed.txt" "$M7_INCLUDED_TXT"

finish
