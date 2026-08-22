#!/usr/bin/env bash
# verify_wasi_33_existing_wasm_targets_unchanged
#
# M4 verification, and the native-neutrality evidence for the bump: barretenberg's
# existing wasm targets build under wasi-sdk 33, the shipped artefact is the same
# artefact, and their tests run identically before and after.
#
# HOW THE TWO SIDES ARE MADE COMPARABLE, and why it is not one build with a flag
# flipped: the UNPATCHED `wasm` preset hardcodes `/opt/wasi-sdk` inside its own
# `environment` block, so it cannot be pointed at a toolchain anywhere else. Both
# builds therefore run under `bwrap --tmpfs /opt --bind <sdk> /opt/wasi-sdk` and
# invoke the preset verbatim: the compile lines are identical by construction and
# the only difference is which toolchain's bytes are at that path. See
# lib_wasi33.sh.
#
#   base    @ 233d8e0993, unmodified, wasi-sdk 27  — what upstream ships today
#   patched @ 233d8e0993 + the patch, wasi-sdk 33  — what the patch produces
#
# WHAT WAS DONE ABOUT THE TESTS, stated plainly because the earlier write-up of
# this patch could not do it at all. barretenberg links every wasm artefact
# `--import-memory`, so the host must supply `env::memory`; upstream's runner does
# that with `wasmtime -Sthreads=y`, and wasmtime 47 has REMOVED `-Sthreads` (this
# check asserts that, with its exact message, rather than repeating it). The test
# binaries are therefore run on V8 instead, through
# verification/wasm_host/run_wasm_test_binary.mjs, which supplies the memory
# import out of the module's own declared limits. That is a substitution and it is
# recorded as one: it runs the `wasm` (single-threaded) preset's `ecc_tests`, not
# the `wasm-threads` one upstream's CI runs. The `wasm-threads` binary is BUILT on
# both sides and the reason it is not executed here is asserted from the artefact
# — it imports a SHARED memory and a thread-spawn entry point — rather than
# asserted in prose.
#
# One thing DOES differ between the two artefacts, and it is recorded here and in
# PR.md rather than smoothed over: after an identical, complete, green transcript,
# the wasi-sdk 33 binary exits 0 and the wasi-sdk 27 binary never terminates. That
# reproduces on wasmtime as well as on V8, so it is the guest and not the host.
#
# Every count parsed out of a run is asserted SEPARATELY from that run's exit
# status, and the negative control for that is a fixture, not a promise:
# wasm_host/green_summary_exit7.cpp prints a complete green "132 ran / 132 PASSED"
# summary and exits 7.
#
# Run: just verify-wasi33-targets  (four wasm builds; ~35 min and 2.1 GB cold)

TEST_NAME="verify_wasi_33_existing_wasm_targets_unchanged"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_wasi33.sh"

require_nix
m4_prepare_trees
note "work directory: $M4_WORK"

BASE="$M4_WORK/base"
PATCHED="$M4_WORK/patched"
SDK27="$(m4_sdk 27)"
SDK33="$(m4_sdk 33)"
note "wasi-sdk 27: $SDK27"
note "wasi-sdk 33: $SDK33"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# ===========================================================================
# A. The builds. Exit status first, and asserted on its own.
# ===========================================================================
# The `wasm` BUILD preset's own target list (CMakePresets.json: barretenberg.wasm,
# barretenberg.wasm.gz, barretenberg-debug.wasm) plus ecc_tests, which is the
# target upstream's CI runs out of the sibling threads preset.
M4_WASM_TARGETS="barretenberg.wasm barretenberg.wasm.gz barretenberg-debug.wasm ecc_tests"
m4_wasm_build "$BASE"    "$SDK27" wasm $M4_WASM_TARGETS; RC_B=$?
m4_wasm_build "$PATCHED" "$SDK33" wasm $M4_WASM_TARGETS; RC_P=$?
assert_eq "the unmodified wasm preset builds with wasi-sdk 27" "0" "$RC_B"
assert_eq "the patched wasm preset builds with wasi-sdk 33" "0" "$RC_P"
[ "$RC_B" -eq 0 ] && [ "$RC_P" -eq 0 ] \
  || die "a wasm build failed — see $BASE/m4-wasm-build.log and $PATCHED/m4-wasm-build.log"

# The build log records the toolchain it actually used. Without this, a stale
# build directory could carry the previous run's toolchain and everything below
# would compare a thing to itself.
assert_prefix "the base build really used wasi-sdk 27" "27." \
  "$(sed -n 's/^### sdk: //p' "$BASE/m4-wasm-build.log" | head -1)"
assert_prefix "the patched build really used wasi-sdk 33" "33." \
  "$(sed -n 's/^### sdk: //p' "$PATCHED/m4-wasm-build.log" | head -1)"
assert_eq "ninja reports success for the base build" "0" \
  "$(sed -n 's/^### ninja_rc=//p' "$BASE/m4-wasm-build.log" | tail -1)"
assert_eq "ninja reports success for the patched build" "0" \
  "$(sed -n 's/^### ninja_rc=//p' "$PATCHED/m4-wasm-build.log" | tail -1)"

BB_BASE="$BASE/barretenberg/cpp/build-wasm/bin/barretenberg.wasm"
BB_PATCHED="$PATCHED/barretenberg/cpp/build-wasm/bin/barretenberg.wasm"
ECC_BASE="$BASE/barretenberg/cpp/build-wasm/bin/ecc_tests"
ECC_PATCHED="$PATCHED/barretenberg/cpp/build-wasm/bin/ecc_tests"
for f in "$BB_BASE" "$BB_PATCHED" "$ECC_BASE" "$ECC_PATCHED"; do
  assert_file "built: ${f#$M4_WORK/}" "$f"
done

# The patch explicitly does NOT turn exceptions on: -fno-exceptions and
# BB_NO_EXCEPTIONS stay. Asserted from the compile database of both builds,
# because "nothing about the shipped build changes" is the whole pitch.
for pair in "27:$BASE" "33:$PATCHED"; do
  v="${pair%%:*}"; t="${pair#*:}"
  cc="$t/barretenberg/cpp/build-wasm/compile_commands.json"
  if [ -f "$cc" ]; then
    assert_contains "the $v build still defines BB_NO_EXCEPTIONS" "-DBB_NO_EXCEPTIONS" "$(cat "$cc")"
    assert_contains "the $v build still compiles -fno-exceptions" "-fno-exceptions" "$(cat "$cc")"
  else
    fail "no compile_commands.json for the $v wasm build"
  fi
done

# ===========================================================================
# B. The shipped artefact, built both ways.
# ===========================================================================
SZ_B=$(stat -c%s "$BB_BASE"); SZ_P=$(stat -c%s "$BB_PATCHED")
note "barretenberg.wasm  27: $SZ_B bytes   33: $SZ_P bytes"
assert_eq "barretenberg.wasm under 27 is the recorded size" "17239547" "$SZ_B"
assert_eq "barretenberg.wasm under 33 is the recorded size" "17063295" "$SZ_P"
if [ "$SZ_P" -lt "$SZ_B" ]; then
  pass "the 33 artefact is smaller, not larger"
else
  fail "the 33 artefact is not smaller: $SZ_P >= $SZ_B"
fi
# PR.md quotes 1.02%. Re-derived here in hundredths of a percent so the number in
# the write-up cannot drift away from the artefacts.
PCT=$(( (SZ_B - SZ_P) * 10000 / SZ_B ))
assert_eq "and smaller by the recorded 1.02%" "102" "$PCT"

m4_wasm_imports "$BB_BASE"    > "$WORK/imp.27"
m4_wasm_imports "$BB_PATCHED" > "$WORK/imp.33"
N_IMP=$(wc -l < "$WORK/imp.33")
assert_eq "barretenberg.wasm imports the recorded 6 things" "6" "$N_IMP"
EXPECTED_IMPORTS='env.logstr
env.memory
env.throw_or_abort_impl
wasi_snapshot_preview1.clock_time_get
wasi_snapshot_preview1.proc_exit
wasi_snapshot_preview1.random_get'
assert_eq "and they are exactly the recorded names" "$EXPECTED_IMPORTS" "$(cat "$WORK/imp.33")"
if diff -q "$WORK/imp.27" "$WORK/imp.33" >/dev/null; then
  pass "the import list is identical under 27 and 33"
else
  fail "import lists differ: $(diff "$WORK/imp.27" "$WORK/imp.33" | tr '\n' ' ')"
fi

m4_wasm_c_exports "$BB_BASE"    > "$WORK/exp.27"
m4_wasm_c_exports "$BB_PATCHED" > "$WORK/exp.33"
N_EXP=$(wc -l < "$WORK/exp.33")
assert_eq "barretenberg.wasm exposes the recorded 5 C-ABI exports" "5" "$N_EXP"
if diff -q "$WORK/exp.27" "$WORK/exp.33" >/dev/null; then
  pass "the C-ABI export list is identical under 27 and 33  [$(tr '\n' ' ' < "$WORK/exp.33")]"
else
  fail "C-ABI exports differ: $(diff "$WORK/exp.27" "$WORK/exp.33" | tr '\n' ' ')"
fi

# ===========================================================================
# C. THE CONTROL FOR EVERY COUNT BELOW. A binary that prints a full green gtest
#    summary and exits 7. If the parsed counts alone decided anything, this would
#    read as 132/132 passing.
# ===========================================================================
LIAR="$WORK/green_summary_exit7.wasm"
"$SDK33/bin/clang++" --target=wasm32-wasip1 -O2 \
  "$VERIFY_DIR/wasm_host/green_summary_exit7.cpp" \
  -Wl,--export-memory,--import-memory,--stack-first,-z,stack-size=1048576,--max-memory=4294967296 \
  -o "$LIAR" 2>"$WORK/liar.log"
assert_eq "the green-summary-then-exit-7 control builds" "0" "$?"
read -r LIAR_ST LIAR_RAN LIAR_PASSED <<<"$(m4_run_wasm_gtest "$LIAR" "$WORK/liar.out")"
assert_eq "it parses as a full green run" "132" "$LIAR_RAN"
assert_eq "it parses as 132 passed" "132" "$LIAR_PASSED"
assert_eq "and the host still reports its real exit status" "7" "$LIAR_ST"

# ===========================================================================
# D. The tests, run on V8 through the host shim.
# ===========================================================================
# wasmtime 47 cannot supply env::memory any more. Asserted, not repeated: if a
# future wasmtime restores -Sthreads, this fails and the substitution above should
# be revisited.
WT_OUT="$(m4_in_devshell 'wasmtime run -Sthreads=y "$1" 2>&1' "$ECC_PATCHED")"
WT_RC=$?
if [ "$WT_RC" -ne 0 ]; then
  pass "wasmtime cannot run these binaries any more  [exit $WT_RC]"
else
  fail "wasmtime accepted -Sthreads — the reason for the V8 substitution is void"
fi
assert_contains "and says exactly why" \
  "the \`-Sthreads\` flag is no longer supported" "$WT_OUT"

# The full test-name sets. Equal counts survive a rename or a drop-plus-addition;
# equal name sets do not.
m4_wasm_gtest_names "$ECC_BASE"    > "$WORK/names.27"
m4_wasm_gtest_names "$ECC_PATCHED" > "$WORK/names.33"
N_NAMES=$(wc -l < "$WORK/names.33")
assert_ge "ecc_tests declares a real number of tests" 1000 "$N_NAMES"
if diff -q "$WORK/names.27" "$WORK/names.33" >/dev/null; then
  pass "the ecc_tests NAME SET is identical under 27 and 33  [$N_NAMES names]"
else
  fail "test name sets differ: $(diff "$WORK/names.27" "$WORK/names.33" | head -6 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# WHAT THE FILTER ACTUALLY REMOVES, derived from the binary's own declared census
# rather than left implicit in three pinned constants. An exclusion that quietly
# dropped a failing test somewhere else would keep 998/72/924 looking plausible;
# what it cannot do is satisfy `declared - ScalarMultiplication == ran`.
# ---------------------------------------------------------------------------
m4_wasm_gtest_list_raw "$ECC_PATCHED" > "$WORK/list.raw"
CENSUS="$(python3 - "$WORK/list.raw" <<'PY'
import re, sys
suite = None
suites, tests = [], []
for line in open(sys.argv[1], errors="ignore"):
    l = line.rstrip("\n")
    if not l.strip():
        continue
    if not l.startswith("  "):
        m = re.match(r'^([A-Za-z_][\w/]*)\.', l)
        if m:
            suite = m.group(1)
            suites.append(suite)
        continue
    m = re.match(r'^\s+(\S+)', l)
    if m and suite:
        tests.append(f"{suite}.{m.group(1)}")
sm_s = [s for s in suites if s.startswith("ScalarMultiplication")]
sm_t = [t for t in tests if t.startswith("ScalarMultiplication")]
print(len(suites), len(tests), len(sm_s), len(sm_t),
      len(suites) - len(sm_s), len(tests) - len(sm_t))
PY
)"
read -r N_SUITES N_TESTS N_SM_SUITES N_SM_TESTS N_KEPT_SUITES N_KEPT_TESTS <<<"$CENSUS"
note "declared census: $N_SUITES suites / $N_TESTS tests; ScalarMultiplication $N_SM_SUITES/$N_SM_TESTS"
assert_eq "ecc_tests declares the recorded number of suites" "78" "$N_SUITES"
assert_eq "ecc_tests declares the recorded number of tests" "1104" "$N_TESTS"
assert_eq "the filter names the recorded number of suites" "6" "$N_SM_SUITES"
assert_eq "holding the recorded number of tests" "106" "$N_SM_TESTS"
assert_eq "so the filter leaves exactly the suites the run reports" "$M4_ECC_SUITES" "$N_KEPT_SUITES"
assert_eq "and exactly the tests the run reports — the filter drops nothing else" \
  "$M4_ECC_RAN" "$N_KEPT_TESTS"

# The whole suite, unfiltered. Both sides abort in the same place for the same
# reason — the `wasm` preset is MULTITHREADING=OFF and the ScalarMultiplication
# suites call bb::set_parallel_for_concurrency. That is upstream's own
# configuration, identical before and after; it is asserted rather than filtered
# away silently.
read -r FULL_B_ST FULL_B_RAN FULL_B_PASSED <<<"$(m4_run_wasm_gtest "$ECC_BASE" "$WORK/full.27")"
read -r FULL_P_ST FULL_P_RAN FULL_P_PASSED <<<"$(m4_run_wasm_gtest "$ECC_PATCHED" "$WORK/full.33")"
assert_eq "the unfiltered run ends the same way under 27 and 33" "$FULL_B_ST" "$FULL_P_ST"
if [ "$FULL_B_ST" -ne 0 ]; then
  pass "and it is a FAILURE on both sides, not a pass  [exit $FULL_B_ST]"
else
  fail "the unfiltered run passed — then the filter below is unjustified"
fi
for f in "$WORK/full.27" "$WORK/full.33"; do
  assert_contains "${f##*/}: aborts on the hardware-concurrency setter" \
    "$M4_ECC_ABORT_MESSAGE" "$(cat "$f")"
  assert_contains "${f##*/}: and in a $M4_ECC_ABORT_SUITE suite" \
    "$M4_ECC_ABORT_SUITE" "$(tail -5 "$f")"
done
assert_eq "the two builds are configured MULTITHREADING=OFF identically" \
  "$(grep -c '^MULTITHREADING:BOOL=OFF' "$BASE/barretenberg/cpp/build-wasm/CMakeCache.txt")" \
  "$(grep -c '^MULTITHREADING:BOOL=OFF' "$PATCHED/barretenberg/cpp/build-wasm/CMakeCache.txt")"
assert_eq "and it really is OFF (so the abort is upstream's configuration)" "1" \
  "$(grep -c '^MULTITHREADING:BOOL=OFF' "$PATCHED/barretenberg/cpp/build-wasm/CMakeCache.txt")"

# Everything a single-threaded build CAN run. This is the "tests pass identically"
# statement, and it is made on the TRANSCRIPT, not on a pair of counts: the two
# runs are compared line by line with only the tree path and the per-test wall
# times normalised away.
read -r RUN_B_ST RUN_B_RAN RUN_B_PASSED <<<"$(m4_run_wasm_gtest "$ECC_BASE" "$WORK/run.27" "$M4_ECC_FILTER")"
read -r RUN_P_ST RUN_P_RAN RUN_P_PASSED <<<"$(m4_run_wasm_gtest "$ECC_PATCHED" "$WORK/run.33" "$M4_ECC_FILTER")"
assert_eq "the same number of tests ran under 27 as the record says" "$M4_ECC_RAN" "$RUN_B_RAN"
assert_eq "the same number ran under 33" "$M4_ECC_RAN" "$RUN_P_RAN"
assert_eq "the same number passed under 27" "$M4_ECC_PASSED" "$RUN_B_PASSED"
assert_eq "the same number passed under 33" "$M4_ECC_PASSED" "$RUN_P_PASSED"
assert_contains "27 reports the suite count too" \
  "$M4_ECC_RAN tests from $M4_ECC_SUITES test suites ran" "$(cat "$WORK/run.27")"
assert_not_contains "and nothing FAILED under 27" "[  FAILED  ]" "$(cat "$WORK/run.27")"
assert_not_contains "nor under 33" "[  FAILED  ]" "$(cat "$WORK/run.33")"

m4_normalise_transcript "$WORK/run.27" > "$WORK/run.27.n"
m4_normalise_transcript "$WORK/run.33" > "$WORK/run.33.n"
N_TRANSCRIPT=$(wc -l < "$WORK/run.33.n")
assert_ge "the transcript is a real transcript" 2000 "$N_TRANSCRIPT"
if diff -q "$WORK/run.27.n" "$WORK/run.33.n" >/dev/null; then
  pass "the ecc_tests TRANSCRIPT is identical under 27 and 33  [$N_TRANSCRIPT lines]"
else
  fail "transcripts differ: $(diff "$WORK/run.27.n" "$WORK/run.33.n" | head -6 | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
# The one place the two artefacts DO differ, recorded rather than smoothed over.
#
# After that identical transcript, the wasi-sdk 33 binary returns from main and
# EXITS 0. The wasi-sdk 27 binary spins in the guest, forever, having printed the
# same complete green summary. It is not the host: the same asymmetry reproduces
# on wasmtime, on a copy of each binary whose memory import has been satisfied
# statically by wasm-merge (m4_run_wasm_gtest_on_wasmtime), where no host code of
# ours is involved at all.
#
# This is evidence FOR the bump, so it is asserted in the direction that makes it
# go red if it ever stops being true — a 27 that starts exiting cleanly would mean
# this paragraph, and PR.md's, need revisiting.
# ---------------------------------------------------------------------------
assert_eq "wasi-sdk 33: the run terminates, exit 0" "0" "$RUN_P_ST"
if m4_is_timeout "$RUN_B_ST"; then
  pass "wasi-sdk 27: the same run does NOT terminate (SIGKILLed at ${M4_RUN_TIMEOUT}s, status $RUN_B_ST)"
else
  fail "wasi-sdk 27 exited $RUN_B_ST — the recorded non-termination no longer holds; revisit PR.md"
fi
assert_contains "and it hangs AFTER the summary, so it is the exit path, not a test" \
  "[  PASSED  ] $M4_ECC_PASSED tests." "$(cat "$WORK/run.27")"

# The cross-check on a second runtime, with our host taken out of the picture.
read -r WT_B_ST WT_B_RAN _ <<<"$(m4_run_wasm_gtest_on_wasmtime "$ECC_BASE" "$WORK/wt.27" --gtest_list_tests)"
read -r WT_P_ST WT_P_RAN _ <<<"$(m4_run_wasm_gtest_on_wasmtime "$ECC_PATCHED" "$WORK/wt.33" --gtest_list_tests)"
assert_eq "wasmtime, no host code of ours: the 33 binary terminates" "0" "$WT_P_ST"
if m4_is_timeout "$WT_B_ST"; then
  pass "wasmtime, no host code of ours: the 27 binary does not — so it is the guest  [status $WT_B_ST]"
else
  fail "on wasmtime the 27 binary exited $WT_B_ST — then the V8 host may be what hangs"
fi
assert_eq "and both listed the same tests before diverging" \
  "$(wc -l < "$WORK/wt.33")" "$(wc -l < "$WORK/wt.27")"

# ===========================================================================
# E. The `wasm-threads` preset — the one upstream's CI actually runs — and the
#    threading.cmake finding that comes with the bump.
# ===========================================================================
m4_wasm_build "$BASE" "$SDK33" wasm-threads ecc_tests; RC_TB=$?
if [ "$RC_TB" -ne 0 ]; then
  pass "the UNPATCHED wasm-threads preset does not build under 33  [exit $RC_TB]"
else
  fail "the unpatched wasm-threads preset built under 33 — the threading fix is unjustified"
fi
TLOG="$(cat "$BASE/m4-wasm-threads-build.log")"
assert_contains "and it fails FATALLY on the deprecated triple" \
  "fatal error: argument '--target=wasm32-wasi' is deprecated" "$TLOG"
assert_contains "naming the replacement" "use --target=wasm32-wasip1 instead" "$TLOG"
N_FATAL=$(grep -c "fatal error: argument '--target=wasm32-wasi' is deprecated" "$BASE/m4-wasm-threads-build.log")
N_FAILED=$(grep -c '^FAILED:' "$BASE/m4-wasm-threads-build.log")
assert_ge "every barretenberg TU it reached failed that way" 1 "$N_FATAL"
assert_eq "and nothing failed for any other reason" "$N_FAILED" "$N_FATAL"
# ...and every one of them is barretenberg's own source, not a vendored one. This
# is the "not one file that is OURS" half of the corrected claim.
N_FAILED_OWN=$(grep '^FAILED:' "$BASE/m4-wasm-threads-build.log" | grep -c 'src/barretenberg/')
assert_eq "and every failing target is barretenberg's own" "$N_FAILED" "$N_FAILED_OWN"
note "unpatched wasm-threads under 33: $N_FAILED translation units, all fatal on the triple"

# WHY the vendored ones get through, read out of the build's own compile database
# rather than left as an anecdote about how far ninja happened to get: the
# deprecated triple is on EVERY translation unit, and only the ones carrying
# -Werror turn the deprecation fatal.
TCC="$BASE/barretenberg/cpp/build-wasm-threads/compile_commands.json"
if [ -f "$TCC" ]; then
  WERR="$(python3 - "$TCC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
def cmd(e): return e.get("command") or " ".join(e.get("arguments", []))
own  = [e for e in d if "/_deps/" not in e["file"]]
gt   = [e for e in d if "/_deps/" in e["file"]
        and ("gtest" in e["file"] or "gmock" in e["file"])]
print(len(own), sum(1 for e in own if "-Werror" in cmd(e)),
      len(gt),  sum(1 for e in gt  if "-Werror" in cmd(e)),
      sum(1 for e in d if "--target=wasm32-wasi-threads" in cmd(e)), len(d))
PY
)"
  read -r N_OWN N_OWN_WERR N_GT N_GT_WERR N_TRIPLE N_ALL <<<"$WERR"
  note "wasm-threads compile database: $N_ALL TUs, $N_OWN barretenberg's own, $N_GT gtest/gmock"
  assert_eq "the deprecated triple is on EVERY translation unit" "$N_ALL" "$N_TRIPLE"
  assert_eq "and every barretenberg TU carries -Werror, which makes it fatal" "$N_OWN" "$N_OWN_WERR"
  assert_eq "the four FetchContent'd gtest/gmock TUs are there" "4" "$N_GT"
  assert_eq "and NOT ONE of them carries -Werror — which is why they get through" "0" "$N_GT_WERR"
else
  fail "no compile_commands.json for the unpatched wasm-threads build"
fi

m4_wasm_build "$PATCHED" "$SDK33" wasm-threads ecc_tests; RC_TP=$?
assert_eq "the PATCHED wasm-threads preset builds under 33" "0" "$RC_TP"
ECC_T="$PATCHED/barretenberg/cpp/build-wasm-threads/bin/ecc_tests"
assert_file "producing the binary upstream's CI runs" "$ECC_T"

# The triple fix is claimed to be safe on BOTH sides of the bump. The sysroot
# directory has to exist in 27 for that to be true.
assert_dir "wasm32-wasip1-threads exists in wasi-sdk 27's sysroot too" \
  "$SDK27/share/wasi-sysroot/lib/wasm32-wasip1-threads"

# Why this binary is NOT executed here — read out of the artefact, not asserted in
# prose. It imports a shared memory and a thread-spawn entry point, and the only
# runtime that used to supply them is the wasmtime flag removed above.
THREAD_IMPORTS="$(m4_in_devshell 'wasm-objdump -x "$1" | sed -n "/^Import\[/,/^Function\[/p"' "$ECC_T")"
assert_contains "the wasm-threads binary imports a SHARED memory" "shared" "$THREAD_IMPORTS"
assert_contains "and a thread-spawn entry point" "thread-spawn" "$THREAD_IMPORTS"
read -r T_ST _ _ <<<"$(m4_run_wasm_gtest "$ECC_T" "$WORK/threads.out")"
assert_eq "so the single-threaded V8 host declines it, loudly" "3" "$T_ST"
assert_contains "with the reason" "imports a SHARED memory" "$(cat "$WORK/threads.out")"

finish
