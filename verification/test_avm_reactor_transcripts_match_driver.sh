#!/usr/bin/env bash
# M12: the reactor produces the same transcripts as the M8 differential driver, including tree
# roots, for all seven corpus programs.
#
# WHAT IS BEING COMPARED, AND WHAT THAT IS EVIDENCE FOR.
#
# The left-hand side is the native `avm_differential` — x86-64, one process, `PublicTxSimulationTester`
# driving `AvmSimAPI` directly in C++. The right-hand side is `avm.wasm` on V8, driven from
# JavaScript across a msgpack boundary: the transaction goes in as upstream's `AvmFastSimulationInputs`,
# the resident contract DB and merkle DB are seeded through four exported methods with upstream's own
# types, and the result comes back as upstream's `TxSimulationResult` and is decoded by a host that
# knows the msgpack wire format and nothing about the schemas.
#
# So this is not "the wasm build agrees with the native build" — M8 established that and it is
# M8's number. It is "the ABI does not lose or alter anything on the way through", across a
# different target, a different language and a serialisation round trip.
#
# COVERAGE: the SAME SEVEN hand-assembled corpus programs, compared line for line, of which
# fifty-six lines are tree roots and sizes. That is an integration check across a boundary. Breadth
# is M7's 391 upstream tests; semantics is M19's 77-comparison oracle; the per-record step agreement
# is M9's 39,086 and M12's own batching check.
#
# The comparison is directional and says so: every line the reactor emits must be present and
# identical in the driver's transcript. The driver emits lines the reactor's ABI has no counterpart
# for — `.beforeDeploy`, `.afterDeploy` and `.afterSimulate` are the *tester's* own DB rather than
# the simulation's result — and those are enumerated below rather than dropped by a wildcard.
#
# THE COMPARATOR'S OWN DISCRIMINATING POWER IS MEASURED. A comparison that reports zero mismatches
# on a corrupted transcript is not a comparison, and this campaign has had a check pass over an
# empty haystack before. One root digit is altered and the same comparator must find exactly one.

set -uo pipefail

TEST_NAME=test_avm_reactor_transcripts_match_driver
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"

require_nix
m12_measured
note "tree: $M12_TREE"

NATIVE="$(m12_native_transcript)"
INPUTS="$(m12_reactor_inputs)"
m8_require_artifacts "$NATIVE" "$INPUTS" "$(m12_wasm_bin avm.wasm)"

# --- the inputs are upstream's own data, not something we recomputed --------
assert_eq "the inputs declare the seven corpus programs" "$M12_EXPECTED_PROGRAMS" \
  "$(m12_field "$INPUTS" reactorInputs.programs.count)"
for p in $M12_PROGRAMS; do
  assert_prefix "the inputs carry $p's derived address" "0x" \
    "$(m12_field "$INPUTS" "reactorInputs.$p.address")"
  assert_ge "and a non-empty AvmFastSimulationInputs blob" 100 \
    "$(m12_field "$INPUTS" "reactorInputs.$p.fast.bytes")"
  assert_ge "and a non-empty AvmProvingInputs blob" 1000 \
    "$(m12_field "$INPUTS" "reactorInputs.$p.proving.bytes")"
  for s in class instance nullifier publicdata; do
    assert_ge "and a $s seeding blob" 1 "$(m12_field "$INPUTS" "reactorInputs.$p.setup.$s.bytes")"
  done
  # The deployment nullifier and the fee-juice leaf are READ BACK out of the tester's own trees at
  # the index they landed at rather than re-derived from DOM_SEP__* constants on our side. The
  # index the driver reports is the genesis prefill's size, which is upstream's own constant.
  assert_eq "the deployment nullifier was read back at the genesis prefill boundary" "128" \
    "$(m12_field "$INPUTS" "reactorInputs.$p.setup.nullifierIndex")"
  assert_eq "and the fee-juice leaf likewise" "128" \
    "$(m12_field "$INPUTS" "reactorInputs.$p.setup.publicDataIndex")"
done
# The prefill constants those two indices are, taken from upstream rather than from us.
WSR="$M12_WORK/memory_merkle_db.hpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp "$WSR"
assert_ge "upstream's own reference world state declares a 128-leaf nullifier prefill" 1 \
  "$(grep -cE 'DEFAULT_NULLIFIER_TREE_PREFILL *= *128' "$WSR")"
assert_ge "and a 128-leaf public-data prefill" 1 \
  "$(grep -cE 'DEFAULT_PUBLIC_DATA_TREE_PREFILL *= *128' "$WSR")"

# --- the run ----------------------------------------------------------------
OUT="$(m12_reactor_transcript)"
ERR="$M12_WORK/reactor.transcript.err"
m12_run_reactor transcript "$OUT" "$ERR"
run_rc=$?
assert_eq "the reactor transcript run exits 0 on V8" 0 "$run_rc"
if [ "$run_rc" -ne 0 ]; then
  note "stderr: $ERR"
  grep -v '^\[' "$ERR" | tail -10
fi
assert_file "and produced a transcript" "$OUT"
require_complete_transcript "$OUT" reactor.done "the reactor's"
assert_eq "which finished" "complete" "$(transcript_completeness "$OUT" reactor.done)"
assert_eq "the ABI version the module reports" "1" "$(m12_field "$OUT" reactor.version)"
assert_eq "it used the host-provided-DB entry point" "simulate" "$(m12_field "$OUT" reactor.entryPoint)"
assert_eq "for the seven corpus programs" "$M12_EXPECTED_PROGRAMS" \
  "$(m12_field "$OUT" reactor.programs.count)"
assert_eq "and the host owns no allocation at exit" 0 \
  "$(m12_field "$OUT" reactor.ownedAllocationsAtExit)"

# The AVM logs on fd 2 and this build is VERBOSE under __wasm__ (common/log.cpp sets
# bb_log_level = VERBOSE unconditionally there), so the streams are kept apart. Saying so, and
# checking there IS something on the error stream, is what keeps "the transcript is stdout" from
# being an accident.
assert_ge "the AVM's own progress logging went to the separate error stream" 1 \
  "$(grep -c 'APP_LOGIC' "$ERR" 2>/dev/null || true)"
assert_eq "and none of it leaked into the transcript" 0 \
  "$(grep -c 'APP_LOGIC' "$OUT" 2>/dev/null || true)"

# --- the comparison ---------------------------------------------------------
REACTOR_LINES="$(grep -c '^program\.' "$OUT")"
assert_ge "the reactor emitted result lines for every program" 140 "$REACTOR_LINES"

CMP="$M12_WORK/transcript-compare.txt"
m12_compare_keyed "$NATIVE" "$OUT" 'program.' >"$CMP"
MISMATCHES="$(grep -c . "$CMP" 2>/dev/null || true)"
assert_eq "every one of the reactor's $REACTOR_LINES result lines is identical to the driver's" \
  0 "$MISMATCHES"
if [ "$MISMATCHES" != "0" ]; then
  head -10 "$CMP"
fi

# The tree roots specifically, because "including tree roots" is the deliverable's own wording and a
# line count over the whole transcript would not show whether they were in it.
ROOT_LINES="$(grep -cE '^program\.[a-z0-9]+\.(start|end)\.[A-Z0-9_]+ 0x[0-9a-f]{64} size=[0-9]+$' "$OUT")"
assert_eq "the reactor emitted $((M12_EXPECTED_PROGRAMS * 8)) start/end tree-root lines" \
  "$((M12_EXPECTED_PROGRAMS * 8))" "$ROOT_LINES"
root_mismatch=0
while IFS= read -r l; do
  key="${l%% *}"
  want="$(m12_field "$NATIVE" "$key")"
  [ "$want" = "${l#* }" ] || { root_mismatch=$((root_mismatch + 1)); fail "root line differs: $key"; }
done <<<"$(grep -E '^program\.[a-z0-9]+\.(start|end)\.[A-Z0-9_]+ 0x[0-9a-f]{64} size=[0-9]+$' "$OUT")"
assert_eq "and every one of them equals the driver's, root and size" 0 "$root_mismatch"

# Per program, so a failure names itself rather than being one number for all seven.
for p in $M12_PROGRAMS; do
  n="$(grep -c "^program\.$p\." "$OUT")"
  assert_ge "program $p produced result lines through the reactor" 15 "$n"
  assert_eq "program $p: revertCode agrees" "$(m12_field "$NATIVE" "program.$p.revertCode")" \
    "$(m12_field "$OUT" "program.$p.revertCode")"
  assert_eq "program $p: all four gas dimensions agree" \
    "$(m12_field "$NATIVE" "program.$p.totalGas")/$(m12_field "$NATIVE" "program.$p.billedGas")" \
    "$(m12_field "$OUT" "program.$p.totalGas")/$(m12_field "$OUT" "program.$p.billedGas")"
  assert_eq "program $p: the transaction fee agrees" "$(m12_field "$NATIVE" "program.$p.txFee")" \
    "$(m12_field "$OUT" "program.$p.txFee")"
  assert_eq "program $p: the derived contract address agrees" \
    "$(m12_field "$NATIVE" "program.$p.address")" "$(m12_field "$OUT" "program.$p.address")"
  assert_eq "program $p: the executed-instruction statistic agrees" \
    "$(m12_field "$NATIVE" "program.$p.stat.total_instructions_executed")" \
    "$(m12_field "$OUT" "program.$p.stat.total_instructions_executed")"
done
# `revert` is the one that must NOT be reported as a failure of the boundary: revertCode 1 is a
# transaction outcome that crossed intact, not a trap and not an error status.
assert_eq "the reverting program crossed as revertCode 1, a transaction outcome" "1" \
  "$(m12_field "$OUT" "program.revert.revertCode")"

# --- what the driver emits and the reactor does not, enumerated -------------
# Named rather than filtered by a wildcard: each of these is the TESTER's own DB, which is a C++
# harness object with no counterpart on the reactor's ABI.
for suffix in beforeDeploy afterDeploy afterSimulate; do
  assert_ge "the driver emits $suffix lines the reactor's ABI has no counterpart for" 1 \
    "$(grep -c "^program\.[a-z0-9]*\.$suffix\." "$NATIVE")"
  assert_eq "and the reactor emits none" 0 "$(grep -c "^program\.[a-z0-9]*\.$suffix\." "$OUT")"
done
assert_ge "the driver also emits a bytes line per program, which the reactor's result does not carry" \
  "$M12_EXPECTED_PROGRAMS" "$(grep -c '^program\.[a-z0-9]*\.bytes ' "$NATIVE")"

# --- THE COMPARATOR'S OWN DISCRIMINATING POWER ------------------------------
CORRUPT="$M12_WORK/native.transcript.corrupt"
sed 's|^program\.add\.end\.NOTE_HASH_TREE 0x2|program.add.end.NOTE_HASH_TREE 0x3|' "$NATIVE" >"$CORRUPT"
assert_true "the control transcript really differs from the driver's" \
  test "$(sha256sum <"$CORRUPT" | awk '{print $1}')" != "$(sha256sum <"$NATIVE" | awk '{print $1}')"
CTRL="$M12_WORK/transcript-compare-control.txt"
m12_compare_keyed "$CORRUPT" "$OUT" 'program.' >"$CTRL"
assert_eq "and the same comparator finds exactly one mismatch against it" 1 \
  "$(grep -c . "$CTRL" 2>/dev/null || true)"
assert_contains "naming the line it altered" "program.add.end.NOTE_HASH_TREE" "$(cat "$CTRL")"
# And the vacuous case: a prefix that matches nothing must be reported rather than pass silently.
VAC="$M12_WORK/transcript-compare-vacuous.txt"
m12_compare_keyed "$NATIVE" "$OUT" 'nosuchprefix.' >"$VAC"
assert_contains "a prefix that matches nothing is reported, not silently green" "NO-KEYS" "$(cat "$VAC")"

# --- the hinted entry point, on the fields it produces ----------------------
# `simulate_with_hinted_dbs` builds its own config internally, so it collects no public inputs and
# no statistics — upstream's behaviour, asserted in the msgpack check. On the fields it DOES
# produce it must agree with the driver exactly, or the two entry points are not two ways of doing
# the same thing and M15 has no choice to make.
HINTED="$(m12_reactor_hinted)"
if [ ! -f "$HINTED" ]; then
  m12_run_reactor hinted "$HINTED" "$M12_WORK/reactor.hinted.err"
  assert_eq "the hinted run exits 0" 0 $?
fi
assert_file "the hinted transcript is present" "$HINTED"
for p in $M12_PROGRAMS; do
  assert_eq "hinted $p: revertCode agrees with the driver" \
    "$(m12_field "$NATIVE" "program.$p.revertCode")" "$(m12_field "$HINTED" "hinted.$p.revertCode")"
  assert_eq "hinted $p: totalGas agrees" "$(m12_field "$NATIVE" "program.$p.totalGas")" \
    "$(m12_field "$HINTED" "hinted.$p.totalGas")"
  assert_eq "hinted $p: publicGas agrees" "$(m12_field "$NATIVE" "program.$p.publicGas")" \
    "$(m12_field "$HINTED" "hinted.$p.publicGas")"
  assert_eq "hinted $p: billedGas agrees" "$(m12_field "$NATIVE" "program.$p.billedGas")" \
    "$(m12_field "$HINTED" "hinted.$p.billedGas")"
  assert_eq "hinted $p: the transaction fee agrees" "$(m12_field "$NATIVE" "program.$p.txFee")" \
    "$(m12_field "$HINTED" "hinted.$p.txFee")"
  assert_eq "hinted $p: the nullifier count agrees" \
    "$(m12_field "$NATIVE" "program.$p.nullifiers.count")" \
    "$(m12_field "$HINTED" "hinted.$p.nullifiers.count")"
  assert_eq "hinted $p: the data-write count agrees" \
    "$(m12_field "$NATIVE" "program.$p.dataWrites.count")" \
    "$(m12_field "$HINTED" "hinted.$p.dataWrites.count")"
done
# The two entry points agree with each other as well as with the driver — which is the property M15
# needs and which neither comparison against the driver alone establishes.
for p in $M12_PROGRAMS; do
  assert_eq "both entry points agree with each other on $p's fee" \
    "$(m12_field "$OUT" "program.$p.txFee")" "$(m12_field "$HINTED" "hinted.$p.txFee")"
done

# --- both entry points were built and measured ------------------------------
# The deliverable asks for both BUILT and MEASURED, with the choice deferred to M15, so the input
# and result sizes and the wall time of each are recorded rather than left to that milestone to
# discover.
for p in $M12_PROGRAMS; do
  fast_bytes="$(m12_field "$INPUTS" "reactorInputs.$p.fast.bytes")"
  proving_bytes="$(m12_field "$INPUTS" "reactorInputs.$p.proving.bytes")"
  assert_true "$p: the hinted entry point's input is much larger than the resident one's ($proving_bytes against $fast_bytes)" \
    test "$proving_bytes" -gt "$((fast_bytes * 10))"
  note "$p: fast inputs $fast_bytes bytes, hinted inputs $proving_bytes bytes, hinted run $(m12_field "$HINTED" "hinted.$p.us") us"
done

finish
