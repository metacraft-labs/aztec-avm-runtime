#!/usr/bin/env bash
# Shared machinery for the M8 checks — the native-versus-wasm differential, including tree roots.
#
# WHAT M8 MEASURES, AND WHAT IT DOES NOT.
#
# ONE worktree of the fork at 233d8e0993 carrying SIX patches: the four of the AVM_WASM series that
# M6 established, M7's `AVM_SIM_TESTS` overlay, and M8's own `AVM_DIFFERENTIAL` overlay. Two build
# directories inside it, because the whole milestone is a comparison between them:
#
#   build-wasm-avm     `wasm-avm` preset, -DAVM_DIFFERENTIAL=ON  -> bin/avm_differential (wasm32)
#   build-native-avm   `default`  preset, -DAVM_DIFFERENTIAL=ON  -> bin/avm_differential (x86-64)
#                      and upstream's OWN bin/world_state_tests, which carries the seven
#                      MemoryMerkleDBEquivalenceTest cases that are the standing fidelity gate.
#
# COVERAGE, so that no number from here can be quoted as another milestone's. The PROGRAM half of
# the differential is SEVEN hand-assembled corpus programs, compared field for field — an
# integration check across two targets, not a breadth claim. Breadth is M7's 391 upstream tests;
# semantics is M19's 77-comparison oracle. The TREE half is broader than the programs but is still
# one scripted sequence: 200 root+size lines, 622 sibling-path fields and 256 leaf preimages, of
# which the part compared against Aztec's REAL world state is Tier D's eight-step sequence, its
# checkpoint cycle, the genesis sibling path and the genesis prefill.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, a runtime that
# is missing or a transcript with no lines in it is `die` or a failed assertion, never a printed
# SKIP.
#
# It reuses M7's machinery, which reuses M6's, rather than re-implementing either: M7_WORK is
# pointed at $M8_WORK before lib_vm2_tests.sh is sourced, and lib_vm2_tests.sh does the same for
# M6_WORK, so m6_prepare_tree, m6_configure, m6_build, m6_tree_or_die, the compile-database readers
# and M7's three runners (native, V8, wasmtime) all operate inside M8's own directory and cannot
# touch M6's or M7's evidence. `m7_tree` is deliberately NOT called: M8's tree carries a sixth
# patch and is prepared here.
#
# Not to be executed directly: sourced by verification/verify_*.sh and test_*.sh, AFTER lib.sh.

# Measured cold from empty, on 32 cores: 4 min 42 s and 792 MB, native build included -- `ninja
# avm_differential` needs only the driver's own dependency subgraph (131 objects), not all 580
# translation units the wasm configure declares. /tmp is usually a tmpfs and is the wrong place:
# set M8_WORK.
M8_WORK="${M8_WORK:-$HOME/.cache/aztec-m8-differential}"
M7_WORK="$M8_WORK"
export M8_WORK M7_WORK

# shellcheck source=lib_vm2_tests.sh
. "$VERIFY_DIR/lib_vm2_tests.sh"

# M8's own overlay: the sixth patch. Ours, not upstream's.
M8_PATCH_6="$REPO_ROOT/verification/m8/0001-test-vm2-AVM_DIFFERENTIAL-a-native-versus-wasm-diffe.patch"

M8_TREE_NAME=avm8
M8_WASM_BUILD=build-wasm-avm
M8_NATIVE_BUILD=build-native-avm

# The differential as measured. Identities, not floors: a line appearing is as much a finding as one
# disappearing, and this campaign has more than once quoted a number a set comparison would have
# caught.
M8_EXPECTED_ORDINARY_LINES=1308   # every line that is NOT a `diag`, and they are all identical
M8_EXPECTED_ROOT_LINES=200        # `<key> 0x<64 hex> size=<n>` lines
M8_EXPECTED_SIBLING_FIELDS=622    # individual sibling-path hashes
M8_EXPECTED_PREFILL_LINES=256     # genesis indexed-leaf preimages, 128 + 128
M8_EXPECTED_PROGRAMS=7            # the corpus, and the coverage statement's whole subject

# The peak-linear-memory budget, in 64 KiB wasm pages. Measured at 173 pages / 11,072 KiB for the
# whole run. The budget is deliberately NOT the measurement: a budget equal to the measurement
# fails on any change at all and therefore gets raised rather than read. 256 pages / 16 MiB is the
# figure this milestone commits to, and the check reports the margin so a drift toward it is
# visible before it is a failure.
M8_PEAK_PAGE_BUDGET="${M8_PEAK_PAGE_BUDGET:-256}"
M8_MEASURED_PEAK_PAGES=173
M8_MEASURED_PEAK_KIB=11072

# Upstream's own fidelity gate: `world_state/memory_merkle_db.test.cpp`, whose header calls itself
# "the canonical-fidelity gate for MemoryMerkleDB". Reference versus REAL, maintained by Aztec.
M8_GATE_SUITE=MemoryMerkleDBEquivalenceTest
M8_GATE_TESTS="AppendNoteHashes Checkpoints GenesisMatches InsertAndUpdatePublicData InsertNullifiers MixedSequence PadNoteHashTree"
M8_GATE_SOURCE=barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp

M8_TRANSCRIPT_COMPARE="$VERIFY_DIR/wasm_host/_transcript_compare.py"
M8_TIERD_COMPARE="$VERIFY_DIR/wasm_host/_tierd_compare.py"
M8_VECTORS="$REPO_ROOT/fixtures/trees/world-state-vectors.json"
M8_PINS="$REPO_ROOT/pins.json"

export M8_PATCH_6 M8_TREE_NAME M8_WASM_BUILD M8_NATIVE_BUILD M8_PEAK_PAGE_BUDGET

# ---------------------------------------------------------------------------
# m8_tree -> the prepared worktree, or die
#
# 233d8e0993 + the four series patches + M7's overlay + M8's, in that order, by `git am` with no
# -3: each must apply to what precedes it exactly.
# ---------------------------------------------------------------------------
m8_tree() {
  [ -f "$M7_PATCH_5" ] || die "M7's overlay patch is missing: $M7_PATCH_5"
  [ -f "$M8_PATCH_6" ] || die "M8's overlay patch is missing: $M8_PATCH_6"
  M8_TREE=$(m6_prepare_tree "$M8_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" "$M7_PATCH_5" "$M8_PATCH_6")
  # A command substitution swallows `die`, so the tree can come back empty and every later
  # `git -C ""` would run in the CALLER's repository. M6 was bitten by exactly this.
  m6_tree_or_die M8_TREE
  export M8_TREE
  printf '%s\n' "$M8_TREE"
}

# ---------------------------------------------------------------------------
# m8_build_wasm / m8_build_native
#
# Configure and build, returning non-zero if EITHER step failed. Callers assert the two statuses
# separately, because a stale binary from a previous run will happily print a plausible transcript
# over a build that did not happen (M2's defect, M3's lesson).
# ---------------------------------------------------------------------------
m8_build_wasm() {
  m6_configure "$M8_TREE" wasm-avm "$M8_WASM_BUILD" -DAVM_DIFFERENTIAL=ON
  M8_WASM_CONFIGURE_RC=$?
  [ "$M8_WASM_CONFIGURE_RC" -eq 0 ] || return "$M8_WASM_CONFIGURE_RC"
  m6_build "$M8_TREE" "$M8_WASM_BUILD" avm_differential
  M8_WASM_BUILD_RC=$?
  return "$M8_WASM_BUILD_RC"
}

m8_build_native() {
  # FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER, for the reason M7 recorded and this milestone's own
  # lesson 7 repeats: `cmake/gtest.cmake` declares GTest with FIND_PACKAGE_ARGS, so a native
  # configure otherwise prefers whatever `find_package(GTest)` turns up — on this host the SYSTEM
  # gtest 1.17.0 under /usr/lib, which is neither pinned nor present on a CI runner. The fidelity
  # gate below is a gtest binary, so this is not decoration: without it the gate would run on a
  # gtest nobody chose. It is asserted, not merely passed.
  m6_native_configure "$M8_TREE" "$M8_NATIVE_BUILD" -DAVM_DIFFERENTIAL=ON \
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M8_NATIVE_CONFIGURE_RC=$?
  [ "$M8_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M8_NATIVE_CONFIGURE_RC"
  m6_build "$M8_TREE" "$M8_NATIVE_BUILD" avm_differential world_state_tests
  M8_NATIVE_BUILD_RC=$?
  return "$M8_NATIVE_BUILD_RC"
}

m8_wasm_bin()   { printf '%s\n' "$M8_TREE/barretenberg/cpp/$M8_WASM_BUILD/bin/$1"; }
m8_native_bin() { printf '%s\n' "$M8_TREE/barretenberg/cpp/$M8_NATIVE_BUILD/bin/$1"; }

# The transcripts. Written by verify_tree_roots_identical_native_wasm and read by everything else,
# so no two checks can disagree about what was measured.
m8_native_transcript()   { printf '%s\n' "$M8_WORK/native.transcript"; }
m8_v8_transcript()       { printf '%s\n' "$M8_WORK/wasm-v8.transcript"; }
m8_wasmtime_transcript() { printf '%s\n' "$M8_WORK/wasm-wasmtime.transcript"; }
# The AVM's own debug logging, kept SEPARATE. See m8_run_* below for why.
m8_native_stderr()       { printf '%s\n' "$M8_WORK/native.stderr"; }
m8_v8_stderr()           { printf '%s\n' "$M8_WORK/wasm-v8.stderr"; }
m8_wasmtime_stderr()     { printf '%s\n' "$M8_WORK/wasm-wasmtime.stderr"; }

# ---------------------------------------------------------------------------
# m8_run_native / m8_run_v8 / m8_run_wasmtime <binary> <transcript> <stderr>
#
# M7's three runners merge the guest's stderr into the captured file, which is right for a gtest
# transcript and WRONG here. The AVM logs its own progress -- "Simulating tx …", "[APP_LOGIC]
# Executing enqueued call to …", "halted via RETURN" -- on fd 2, through `vinfo`.
#
# THE ASYMMETRY IS BETWEEN THE TARGETS, NOT BETWEEN THE HOSTS, and the cause is upstream's own
# code: `common/log.cpp` sets `bb_log_level = LogLevel::VERBOSE` unconditionally under `__wasm__`
# and `LogLevel::INFO` (unless BB_VERBOSE=1) otherwise. So the WASM build emits 45 `vinfo` lines on
# fd 2 and the NATIVE build emits none at all -- measured, `native.stderr` is 0 bytes. Both wasm
# hosts interleave those 45 lines into the same place, so merging is not a host-buffering artefact:
# it is a comparison of a verbose stream against a quiet one.
#
# Merged, and measured: `native` against a merged wasmtime stream mismatches on 231 of 1,308
# positions -- identical up to the first log line and shifted by 45 thereafter -- and against a
# merged node stream on ALL 1,308, because node's host prints two ExperimentalWarning lines before
# the guest starts. (An earlier version of this comment said wasmtime interleaved and node did not;
# review measured both, and the real discriminator is the target's log level.)
#
# So the TRANSCRIPT is stdout, exactly, and stderr goes to its own file -- where it is not thrown
# away either: test_revert_program_does_not_trap_module reads it, because "the throw path executed
# inside wasm" is written there.
#
# These delegate the hard parts (the dev shell, the memory import, the wasm-merge) to M7's runners
# rather than re-implementing them; only the redirection differs.
# ---------------------------------------------------------------------------
m8_run_native() {
  local bin="$1" out="$2" err="$3"
  [ -x "$bin" ] || die "no native binary at $bin — nothing to run"
  m6_in_devshell '
    bin="$1"; t="$2"; err="$3"
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    timeout --foreground --preserve-status -s KILL "$t" "$bin" 2>"$err"
  ' "$bin" "$M7_RUN_TIMEOUT" "$err" >"$out"
}

m8_run_v8() {
  local wasm="$1" out="$2" err="$3"
  [ -f "$wasm" ] || die "no wasm module at $wasm — nothing to run"
  m6_in_devshell '
    host="$1"; wasm="$2"; t="$3"; err="$4"
    timeout --foreground --preserve-status -s KILL "$t" node "$host" "$wasm" 2>"$err"
  ' "$M7_V8_HOST" "$wasm" "$M7_RUN_TIMEOUT" "$err" >"$out"
}

m8_run_wasmtime() {
  local wasm="$1" out="$2" err="$3"
  [ -f "$wasm" ] || die "no wasm module at $wasm — nothing to run"
  local limits mn mx merged
  limits="$(python3 "$M7_MEMLIMITS" "$wasm")" || die "could not read the memory import of $wasm"
  mn="$(printf '%s' "$limits" | awk '{print $3}')"
  mx="$(printf '%s' "$limits" | awk '{print $4}')"
  [ -n "$mn" ] && [ -n "$mx" ] || die "unreadable memory limits for $wasm: [$limits]"
  merged="$M8_WORK/$(basename "$wasm").merged.wasm"
  m6_in_devshell '
    wasm="$1"; merged="$2"; mn="$3"; mx="$4"; t="$5"; err="$6"
    tmp="$(mktemp -d)"; trap "rm -rf $tmp" EXIT
    printf "(module (memory (export \"memory\") %s %s))\n" "$mn" "$mx" > "$tmp/envmem.wat"
    wat2wasm "$tmp/envmem.wat" -o "$tmp/envmem.wasm" || exit 90
    wasm-merge "$tmp/envmem.wasm" env "$wasm" main -o "$merged" \
      --rename-export-conflicts --enable-bulk-memory --enable-simd \
      --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
      --enable-multivalue --enable-exception-handling --enable-reference-types \
      >/dev/null 2>&1 || exit 91
    timeout --foreground --preserve-status -s KILL "$t" wasmtime run --dir=. "$merged" 2>"$err"
  ' "$wasm" "$merged" "$mn" "$mx" "$M7_RUN_TIMEOUT" "$err" >"$out"
}

# ---------------------------------------------------------------------------
# m8_upstream_file <path-in-fork> <destination>
#
# Reads a file out of the fork AT THE PINNED ANCHOR, on every run, and dies if it comes back empty.
# Nothing here compares our copy of an upstream constant against our copy of it: M2's split says
# every `upstreamPublished` value must be read live, and an empty haystack silently makes every
# membership test pass, which is a shape this campaign has met.
# ---------------------------------------------------------------------------
m8_upstream_file() {
  local path="$1" dest="$2"
  [ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"
  ( cd "$FORK_ROOT" && git show "$(m8_anchor):$path" ) >"$dest" 2>/dev/null
  [ -s "$dest" ] \
    || die "reading $path from the fork at $(m8_anchor) produced nothing — every comparison against it would be vacuous"
}

m8_anchor() {
  local a
  a="$(python3 -c "import json;print(json.load(open('$M8_PINS'))['anchors']['cpp']['commit'])" 2>/dev/null)"
  [ -n "$a" ] || die "could not read the cpp anchor from $M8_PINS"
  printf '%s\n' "$a"
}

# ---------------------------------------------------------------------------
# m8_measured
#
# $M8_WORK/measured.env — the single record of what was built and run, written by
# verify_tree_roots_identical_native_wasm, which is the check that builds. Every other M8 check
# reads it. If it is not there that check is RUN to produce one; it is never invented, defaulted
# or skipped.
# ---------------------------------------------------------------------------
m8_measured() {
  if [ ! -f "$M8_WORK/measured.env" ]; then
    note "no measurement on record — running verify_tree_roots_identical_native_wasm to produce one"
    mkdir -p "$M8_WORK"
    "$VERIFY_DIR/verify_tree_roots_identical_native_wasm.sh" >"$M8_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M8_WORK/build-for-record.log"
  fi
  [ -f "$M8_WORK/measured.env" ] || die "measurement record missing at $M8_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M8_WORK/measured.env"
  # The record names artefacts in a tree this check did not build. Assert they are THERE before
  # anything is claimed about them — M6's review found four assertions passing over a build
  # directory that held nothing, because every predicate returned 0 over a missing path.
  [ -n "${M8_TREE:-}" ] && [ -d "$M8_TREE" ] \
    || die "measurement names no tree, or a tree that is gone: [${M8_TREE:-}]"
  m8_require_artifacts "$(m8_wasm_bin avm_differential)" "$(m8_native_bin avm_differential)" \
    "$(m8_native_transcript)" "$(m8_v8_transcript)"
}

# m8_require_artifacts <path...> — assert every named artefact exists before any predicate reads
# it, and die naming the first that does not.
m8_require_artifacts() {
  local p
  for p in "$@"; do
    [ -e "$p" ] || die "required artefact missing: $p"
  done
}

# ---------------------------------------------------------------------------
# m8_report <file>
#
# Turns a `_transcript_compare.py` / `_tierd_compare.py` PASS/FAIL report into this harness's own
# assertions, one per row, so a failure names itself. Dies if the report is empty: a comparator
# that printed nothing has not agreed with anything.
# ---------------------------------------------------------------------------
m8_report() {
  local file="$1" rows=0
  [ -s "$file" ] || die "the comparator produced no rows at all: $file"
  while IFS=$'\t' read -r status name detail; do
    [ -n "$name" ] || continue
    rows=$((rows + 1))
    if [ "$status" = "PASS" ]; then
      pass "$name${detail:+  [$detail]}"
    else
      fail "$name  ($detail)"
    fi
  done <"$file"
  [ "$rows" -gt 0 ] || die "the comparator's report parsed to zero rows: $file"
}

# m8_root_lines <transcript> — the `<key> 0x<64 hex> size=<n>` lines, in order.
m8_root_lines() {
  grep -E ' 0x[0-9a-f]{64} size=[0-9]+$' "$1"
}

# m8_ordinary <transcript> — every line that is not a diagnostic.
m8_ordinary() {
  grep -v '^diag ' "$1"
}

# m8_gtest_ok_names <transcript> — the tests gtest reported as OK, sorted.
m8_gtest_ok_names() {
  sed -n 's/^\[       OK \] \([A-Za-z0-9_.\/]*\).*$/\1/p' "$1" | LC_ALL=C sort -u
}

# m8_tree_dirty — the paths under barretenberg/ that differ from HEAD, EXCEPT nodejs_module/,
# whose CMakeLists runs `yarn --immutable` at configure time and forces a plain `yarn install`
# first. M3, M6 and M7 all scope past that directory AND PAST NOTHING ELSE.
m8_tree_dirty() {
  git -C "$M8_TREE" diff --name-only HEAD -- barretenberg \
    | grep -v '^barretenberg/cpp/src/barretenberg/nodejs_module/' \
    | tr '\n' ' ' | sed 's/ *$//'
}
