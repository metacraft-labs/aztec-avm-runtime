#!/usr/bin/env bash
# run_avm_differential — the thing behind `just avm-differential`.
#
# Builds the differential driver for x86-64 and for wasm32-wasip1 from one worktree, runs both,
# diffs the transcripts, and exits NON-ZERO on any divergence. It also compares the wasm side
# against Tier D's vectors from the real world state, because a differential that only says "the
# two agree" can agree on a wrong answer.
#
# There is no skip path. A missing input, a failed configure, a failed build, a guest that does not
# exit 0 or a transcript with no lines in it is an error with its own exit status and its own
# message — never a printed SKIP and never exit 0.
#
#   0   the two targets agree, and the wasm side agrees with Tier D
#   1   a divergence (this is the regression signal)
#   2   an input is missing or a precondition cannot be met
#   3   a build or configure failed
#   4   a run failed
#
# Environment:
#   M8_WORK               where the worktree and the two build directories live (~800 MB)
#   AVM_DIFF_FORCE_BUILD  =1 to reconfigure from scratch rather than incrementally
#   AVM_DIFF_INJECT       a deliberate divergence, for the checks that measure this script's own
#                         discriminating power. One of: root, diag, same, swap, truncate.
#                         Each must be REJECTED, and by its own message.

set -uo pipefail

TEST_NAME="run_avm_differential"
VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$VERIFY_DIR/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

fatal() { printf 'avm-differential: %s\n' "$2" >&2; exit "$1"; }

command -v python3 >/dev/null 2>&1 || fatal 2 "python3 is not available"
command -v nix     >/dev/null 2>&1 || fatal 2 "nix is not available (the builds run in the fork's dev shell)"
[ -f "$M8_TRANSCRIPT_COMPARE" ] || fatal 2 "the transcript comparator is missing: $M8_TRANSCRIPT_COMPARE"
[ -f "$M8_TIERD_COMPARE" ]      || fatal 2 "the Tier D comparator is missing: $M8_TIERD_COMPARE"
[ -f "$M8_VECTORS" ]            || fatal 2 "the Tier D vectors are missing: $M8_VECTORS"
[ -f "$M8_PATCH_6" ]            || fatal 2 "M8's overlay patch is missing: $M8_PATCH_6"

INJECT="${AVM_DIFF_INJECT:-}"
case "$INJECT" in
  ""|root|diag|same|swap|truncate) ;;
  *) fatal 2 "unknown AVM_DIFF_INJECT mode: [$INJECT] (root|diag|same|swap|truncate)" ;;
esac
[ -n "$INJECT" ] && printf 'avm-differential: INJECTING a deliberate divergence: %s\n' "$INJECT"

mkdir -p "$M8_WORK"

# --- 1. the tree ---------------------------------------------------------------------------------
printf 'avm-differential: preparing %s + six patches under %s\n' "$M6_BASE_REV" "$M8_WORK"
M8_TREE="$(m8_tree)" || fatal 2 "could not prepare the worktree"
[ -n "$M8_TREE" ] && [ -d "$M8_TREE" ] || fatal 2 "the prepared worktree is not there"

# --- 2. both builds ------------------------------------------------------------------------------
# Incremental unless asked otherwise: a full reconfigure removes the build directory, and on a warm
# tree ninja has nothing to do. The BUILD still runs either way, so "just avm-differential builds
# both" stays true rather than becoming "reads two binaries somebody else made".
build_side() { # <preset|native> <build-dir> <extra cmake args...>
  local kind="$1" bdir="$2"; shift 2
  local fresh=1
  if [ -z "${AVM_DIFF_FORCE_BUILD:-}" ] && [ -f "$M8_TREE/barretenberg/cpp/$bdir/CMakeCache.txt" ]; then
    fresh=0
  fi
  if [ "$kind" = native ]; then
    if [ "$fresh" = 1 ]; then
      m6_native_configure "$M8_TREE" "$bdir" "$@" || return 3
    fi
  else
    if [ "$fresh" = 1 ]; then
      m6_configure "$M8_TREE" "$kind" "$bdir" "$@" || return 3
    fi
  fi
  m6_build "$M8_TREE" "$bdir" avm_differential || return 4
  return 0
}

printf 'avm-differential: building for wasm32-wasip1\n'
build_side wasm-avm "$M8_WASM_BUILD" -DAVM_DIFFERENTIAL=ON
case $? in
  0) ;;
  3) fatal 3 "the wasm configure failed — see $M8_TREE/m6-$M8_WASM_BUILD.log" ;;
  *) fatal 3 "the wasm build failed — see $M8_TREE/m6-$M8_WASM_BUILD-build.log" ;;
esac

printf 'avm-differential: building for x86-64\n'
build_side native "$M8_NATIVE_BUILD" -DAVM_DIFFERENTIAL=ON -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
case $? in
  0) ;;
  3) fatal 3 "the native configure failed — see $M8_TREE/m6-$M8_NATIVE_BUILD.log" ;;
  *) fatal 3 "the native build failed — see $M8_TREE/m6-$M8_NATIVE_BUILD-build.log" ;;
esac

WASM_BIN="$(m8_wasm_bin avm_differential)"
NATIVE_BIN="$(m8_native_bin avm_differential)"
[ -f "$WASM_BIN" ]   || fatal 3 "the wasm build produced no binary at $WASM_BIN"
[ -x "$NATIVE_BIN" ] || fatal 3 "the native build produced no binary at $NATIVE_BIN"

# --- 3. run both ---------------------------------------------------------------------------------
NATIVE_T="$(m8_native_transcript)"; V8_T="$(m8_v8_transcript)"
printf 'avm-differential: running both\n'
m8_run_native "$NATIVE_BIN" "$NATIVE_T" "$(m8_native_stderr)" \
  || fatal 4 "the native driver exited non-zero — see $(m8_native_stderr)"
m8_run_v8 "$WASM_BIN" "$V8_T" "$(m8_v8_stderr)" \
  || fatal 4 "the wasm driver exited non-zero on V8 — see $(m8_v8_stderr)"
[ -s "$NATIVE_T" ] || fatal 4 "the native transcript is empty"
[ -s "$V8_T" ]     || fatal 4 "the wasm transcript is empty"

# --- 4. the deliberate divergence, when one was asked for ----------------------------------------
LEFT="$NATIVE_T"; RIGHT="$V8_T"
case "$INJECT" in
  root)
    RIGHT="$M8_WORK/inject-root.transcript"
    python3 - "$V8_T" "$RIGHT" <<'PY' || exit 2
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
for i, ln in enumerate(lines):
    if ln.startswith("tierD.step4.NULLIFIER_TREE "):
        m = re.search(r"0x([0-9a-f]{64})", ln)
        d = m.group(1)
        lines[i] = ln.replace("0x" + d, "0x" + d[:-1] + ("0" if d[-1] != "0" else "1"))
        break
else:
    sys.exit(2)
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lines))
PY
    ;;
  diag)
    RIGHT="$M8_WORK/inject-diag.transcript"
    { head -3 "$V8_T"; echo "diag wasm.aKeyNobodyEnumerated 1"; tail -n +4 "$V8_T"; } >"$RIGHT"
    ;;
  same)  RIGHT="$NATIVE_T" ;;
  swap)  LEFT="$V8_T"; RIGHT="$NATIVE_T" ;;
  truncate)
    RIGHT="$M8_WORK/inject-truncate.transcript"
    head -n 900 "$V8_T" >"$RIGHT"
    ;;
esac

# --- 5. compare ----------------------------------------------------------------------------------
REPORT="$M8_WORK/avm-differential.report"
python3 "$M8_TRANSCRIPT_COMPARE" "$LEFT" "$RIGHT" "$M8_PEAK_PAGE_BUDGET" >"$REPORT" 2>&1
COMPARE_RC=$?
[ "$COMPARE_RC" -eq 0 ] || { cat "$REPORT" >&2; fatal 2 "the transcript comparator could not run"; }
[ -s "$REPORT" ] || fatal 2 "the transcript comparator produced no rows"

TIERD_REPORT="$M8_WORK/avm-differential-tierd.report"
UP="$M8_WORK/upstream"; mkdir -p "$UP"
# `m8_upstream_file` dies with status 1 when the fork read comes back empty, and 1 is this script's
# code for a DIVERGENCE. Run it in a subshell so that failure becomes `fatal 2` instead: an
# unreadable fork is a broken run, not a differing one, and the whole point of the exit-status
# vocabulary above is that the two never collapse into each other.
upstream_or_fatal() { # <path-in-fork> <destination>
  ( m8_upstream_file "$1" "$2" ) \
    || fatal 2 "could not read $1 out of the fork at the pinned anchor — the Tier D comparison would be vacuous"
}
upstream_or_fatal "barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp" "$UP/world_state.test.cpp"
upstream_or_fatal "noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr" "$UP/constants.nr"
upstream_or_fatal "noir-projects/fnd/noir-protocol-circuits/crates/types/src/merkle_tree/root.nr" "$UP/root.nr"
python3 "$M8_TIERD_COMPARE" "$RIGHT" "$M8_VECTORS" \
  "$UP/world_state.test.cpp" "$UP/constants.nr" "$UP/root.nr" >"$TIERD_REPORT" 2>&1
TIERD_RC=$?
if [ "$TIERD_RC" -ne 0 ] && [ -z "$INJECT" ]; then
  cat "$TIERD_REPORT" >&2
  fatal 2 "the Tier D comparator refused to run (exit $TIERD_RC)"
fi

DIFF_FAILS="$(grep -c '^FAIL' "$REPORT" || true)"
DIFF_PASSES="$(grep -c '^PASS' "$REPORT" || true)"
TIERD_FAILS="$(grep -c '^FAIL' "$TIERD_REPORT" || true)"
TIERD_PASSES="$(grep -c '^PASS' "$TIERD_REPORT" || true)"

printf '\navm-differential: native versus wasm  — %s passed, %s failed\n' "$DIFF_PASSES" "$DIFF_FAILS"
printf 'avm-differential: wasm versus Tier D — %s passed, %s failed\n' "$TIERD_PASSES" "$TIERD_FAILS"
printf 'avm-differential: coverage — seven hand-assembled corpus programs compared field for field,\n'
printf '                  plus one scripted world-state sequence. An integration check across two\n'
printf '                  targets, NOT a breadth claim: breadth is M7 (391 upstream tests) and\n'
printf '                  semantics is M19 (77 comparisons).\n'

if [ "$DIFF_FAILS" -ne 0 ] || [ "$TIERD_FAILS" -ne 0 ] || [ "$TIERD_RC" -ne 0 ]; then
  printf '\navm-differential: DIVERGENCE\n' >&2
  grep '^FAIL' "$REPORT" >&2
  grep '^FAIL' "$TIERD_REPORT" >&2
  exit 1
fi

# A run that asserted nothing is not a green run.
[ "$DIFF_PASSES" -ge 20 ]  || fatal 2 "the transcript comparison made only $DIFF_PASSES assertions"
[ "$TIERD_PASSES" -ge 100 ] || fatal 2 "the Tier D comparison made only $TIERD_PASSES assertions"

printf '\navm-differential: OK\n'
exit 0
