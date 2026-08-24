#!/usr/bin/env bash
# verify_node_transcripts_match_native — M17.
#
# ALL SEVEN CORPUS PROGRAMS RUN UNDER NODE THROUGH THE TYPESCRIPT BINDINGS AND PRODUCE TRANSCRIPTS,
# INCLUDING TREE ROOTS, IDENTICAL TO THE NATIVE x86-64 REFERENCE.
#
# WHAT THIS ADDS TO M12, WHICH ALREADY COMPARED A TRANSCRIPT ACROSS THIS BOUNDARY. M12's host is a
# `.mjs` script written to measure the ABI. This one is the SHIPPABLE PACKAGE — the loader, the
# ownership rules, the pooled instance and the error surface M18 will import — and it is driven
# through its own public entry points rather than through a bespoke harness. A transcript that
# agreed for M12's host and not for this one would be a defect in the thing being shipped.
#
# THE COMPARISON IS DIRECTIONAL AND ITS EXCEPTIONS ARE ENUMERATED RATHER THAN FILTERED. The driver
# emits `.beforeDeploy`, `.afterDeploy` and `.afterSimulate` lines, which are the TESTER's own DB —
# a C++ harness object with no counterpart on the reactor's ABI — and a `.bytes` line per program,
# which is the bytecode length rather than a result field. So every `program.*` key the NODE host
# produces must be present in the native transcript with the same value; keys the native side has
# and the host does not are M12's enumerated exceptions and are not mismatches.
#
# AND THE COMPARATOR IS SHOWN TO FIND A DIFFERENCE. A zero from a comparator that cannot report one
# is not a measurement. One line of the node transcript is altered in a copy and the same
# comparator is run again; it must report exactly that key.
#
# Run: just verify-node-transcripts

TEST_NAME="verify_node_transcripts_match_native"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"

m17_measured

# ---------------------------------------------------------------------------
echo "== 1. the run"
# ---------------------------------------------------------------------------
m17_run transcript "$(m17_out transcript)" "$(m17_err transcript)"
RC=$?
assert_eq "the node host's transcript run exits 0" 0 "$RC"
# Exit status AND the specific failure mode: a run that exits 0 having written a PREFIX of its
# output is the shape M9 spent an afternoon on, and the sentinel is what tells them apart.
assert_eq "…and its transcript is complete rather than truncated" \
  "complete" "$(m17_completeness "$(m17_out transcript)" nodeHost)"

NODE_T="$(m17_out transcript)"
NATIVE_T="$(m17_native_transcript)"
m8_require_artifacts "$NODE_T" "$NATIVE_T"

assert_eq "it ran the whole corpus" "$M17_EXPECTED_PROGRAMS" \
  "$(m17_field "$NODE_T" nodeHost.programs.count)"
for p in $M17_PROGRAMS; do
  assert_true "…including $p" grep -q "^program\.$p\.revertCode " "$NODE_T"
done

# ---------------------------------------------------------------------------
echo "== 2. the comparison, key for key"
# ---------------------------------------------------------------------------
NODE_KEYS="$(grep -c '^program\.' "$NODE_T")"
NATIVE_KEYS="$(grep -c '^program\.' "$NATIVE_T")"
note "node host: $NODE_KEYS program.* lines; native driver: $NATIVE_KEYS"
# Both sides non-empty BEFORE they are compared. Two empty files agree with each other, and this
# campaign has shipped that mistake once already.
assert_ge "the node transcript carries result lines at all" 100 "$NODE_KEYS"
assert_ge "the native transcript carries result lines at all" 100 "$NATIVE_KEYS"

MISMATCH="$M17_WORK/transcript-compare.txt"
m12_compare_keyed "$NATIVE_T" "$NODE_T" "program." >"$MISMATCH"
MISMATCHES="$(grep -c . "$MISMATCH" || true)"
[ "$MISMATCHES" -eq 0 ] || note "first mismatches: $(head -5 "$MISMATCH" | tr '\n' ' ')"
assert_eq "every program.* key the node host produces matches the native reference" 0 "$MISMATCHES"

# ---------------------------------------------------------------------------
echo "== 3. tree roots specifically, because that is what the entry asks for"
# ---------------------------------------------------------------------------
# 56 of the lines are tree roots and sizes: four trees, before and after, for seven programs.
ROOT_LINES="$(grep -cE '^program\.[a-z0-9]+\.(start|end)\.(NOTE_HASH|NULLIFIER|PUBLIC_DATA|L1_TO_L2_MESSAGE)_TREE ' "$NODE_T")"
assert_eq "the transcript carries a root and a size for four trees, before and after, per program" \
  "$((M17_EXPECTED_PROGRAMS * 8))" "$ROOT_LINES"
assert_eq "…and they are all in the compared set" "0" \
  "$(m12_compare_keyed "$NATIVE_T" "$NODE_T" "program." | grep -cE '\.(start|end)\.' || true)"
# A root is a 32-byte field element rendered as 0x + 64 hex digits, and a size. Asserted so a
# formatter that printed `[object Object]` for all of them could not agree with itself.
assert_eq "every tree-root line is a field element and a size" "$ROOT_LINES" \
  "$(grep -cE '^program\.[a-z0-9]+\.(start|end)\.[A-Z0-9_]+_TREE 0x[0-9a-f]{64} size=[0-9]+$' "$NODE_T")"
# And they are not all the same value, which a constant formatter would also satisfy.
DISTINCT_ROOTS="$(grep -oE '^program\.[a-z0-9]+\.(start|end)\.[A-Z0-9_]+_TREE 0x[0-9a-f]{64}' "$NODE_T" \
  | awk '{print $2}' | LC_ALL=C sort -u | grep -c .)"
note "distinct tree roots across the corpus: $DISTINCT_ROOTS"
assert_ge "the roots are not one repeated constant" 8 "$DISTINCT_ROOTS"

# ---------------------------------------------------------------------------
echo "== 4. the comparator can report a difference"
# ---------------------------------------------------------------------------
CTL="$M17_WORK/transcript-control.txt"
# Alter exactly one value — the last program's total gas — and require the comparator to name it.
VICTIM="program.burn.totalGas"
ORIG="$(m17_field "$NODE_T" "$VICTIM")"
assert_true "the control's victim key exists to alter" test -n "$ORIG"
awk -v k="$VICTIM" '$1 == k { print k " 999999/999999"; next } { print }' "$NODE_T" >"$CTL"
assert_false "the altered copy differs from the transcript" cmp -s "$CTL" "$NODE_T"
CTL_OUT="$(m12_compare_keyed "$NATIVE_T" "$CTL" "program.")"
assert_eq "the comparator reports exactly one difference in the altered copy" \
  "1" "$(printf '%s\n' "$CTL_OUT" | grep -c . )"
assert_contains "…and it names the key that was altered" "$VICTIM" "$CTL_OUT"

# ---------------------------------------------------------------------------
echo "== 5. ONE decoder, not two"
# ---------------------------------------------------------------------------
# The deliverable says "decoding upstream's msgpack schemas rather than a parallel encoding", and
# the parallel implementation most likely to appear is one of OURS. M13 already extracted the
# decoder once so M12's and M13's hosts could not disagree about a wire format; M17 would have made
# a third copy of it in TypeScript, so `reactor_lib.mjs` re-exports the package's instead.
RLIB="$VERIFY_DIR/wasm_host/reactor_lib.mjs"
assert_file "the verification hosts' shared library exists" "$RLIB"
assert_contains "…and it re-exports the package's decoder rather than carrying one" \
  "from '../../node-host/src/msgpack.ts'" "$(cat "$RLIB")"
assert_eq "there is no second decoder anywhere under verification/wasm_host" "0" \
  "$(grep -rlE '^(export )?class Decoder' "$VERIFY_DIR/wasm_host" 2>/dev/null | grep -c . || true)"
# The zero is a measurement rather than an absence: the SAME grep finds the one in the package.
assert_ge "…and the same grep finds the one implementation, in the package" 1 \
  "$(grep -rlE '^export class Decoder' "$M17_PKG/src" 2>/dev/null | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 6. ownership: nothing is leaked, on any path"
# ---------------------------------------------------------------------------
assert_eq "the host owns no linear-memory allocation when the run ends" \
  "0" "$(m17_field "$NODE_T" nodeHost.ownedAllocationsAtExit)"
assert_eq "…and nothing was abandoned to a trap, because nothing trapped" \
  "0" "$(m17_field "$NODE_T" nodeHost.leakedAtTrap)"
# One compilation for seven transactions: the module cache doing what it is for.
assert_eq "the module was compiled once for the whole corpus" \
  "1" "$(m17_field "$NODE_T" nodeHost.moduleCompilations)"

finish
