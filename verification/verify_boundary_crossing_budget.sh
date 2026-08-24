#!/usr/bin/env bash
# verify_boundary_crossing_budget
#
# HOW MANY TIMES A TRANSACTION CROSSES THE BOUNDARY IN THE CHATTY SHAPE, AS A COUNT.
#
# The milestone's premise is that "a TypeScript layer that drives them from outside turns every
# read into a boundary round trip", and the whole decision turns on how many round trips that is.
# M15 does not estimate it. It reads it out of upstream's own record.
#
# `AvmProvingInputs.hints` is what `AvmSimAPI::simulate_with_hinted_dbs` consumes, and it exists so
# that a hinted replay can answer every DB call the original simulation made — so it is exactly a
# per-METHOD tally of those calls. Eighteen of its categories map one-to-one onto methods of
# `ContractDBInterface` and `LowLevelMerkleDBInterface`, and `startingTreeRoots` is the one
# `get_tree_roots`. The mapping lives in `wasm_host/_hint_crossings.mjs` so the host and this check
# cannot disagree about it, and the blob is produced by THIS milestone's own build of upstream's
# own `avm_differential reactorinputs`.
#
# THE MAPPING IS ASSERTED TO BE COMPLETE IN BOTH DIRECTIONS, because a table that silently ignores
# a hint category would under-count exactly the crossings a new AVM feature adds:
#
#   * every hint category present in the blob is either mapped to a method or named in
#     `NOT_CALL_TALLIES` — anything else comes back in `unmappedHintCategories` and this check
#     requires that list to be empty;
#   * every one of the twenty-two interface methods appears in the op table, and the three that
#     have no hint category are named individually with the reason.
#
# THE BUDGET IS A CEILING A REGRESSION CROSSES, and it is asserted both ways. Upper, so a shape
# change that made the AVM consult the host per memory access is caught. Lower, so a run in which
# the decoder returned nothing — every count zero, budget trivially satisfied — is refused rather
# than reported as an excellent result. This campaign has already had two comparisons that passed
# because both sides were empty.

set -uo pipefail
TEST_NAME=verify_boundary_crossing_budget
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m15_shapes.sh"

assert_file "the crossing-count mapping is where the host and this check both read it" "$M15_CROSSINGS_LIB"

M15_TREE="$(m15_tree)"; m6_tree_or_die M15_TREE
TREE="$M15_TREE"
m15_build_wasm "$TREE"
assert_eq "the wasm configure succeeded" "0" "$M15_WASM_CONFIGURE_RC"
assert_eq "and avm.wasm built" "0" "$M15_WASM_BUILD_RC"
m15_build_native "$TREE"
assert_eq "the native configure succeeded" "0" "$M15_NATIVE_CONFIGURE_RC"
assert_eq "and avm_differential built" "0" "$M15_NATIVE_BUILD_RC"
m15_make_inputs "$TREE"
assert_eq "the driver emitted its inputs" "0" "$?"
WASM="$(m15_wasm_module "$TREE")"
INPUTS="$(m15_reactor_inputs)"
assert_file "the module is on disk" "$WASM"
assert_ge "the inputs file is not empty" 50 "$(m15_lines "$INPUTS")"

OUT="$M15_WORK/crossings.txt"
m15_host "$WASM" "$INPUTS" crossings "$OUT"
assert_eq "the crossings host exited 0" "0" "$?"
assert_eq "it ran to the end" "1" "$(m15_key "$OUT" crossings.done)"
assert_eq "and wrote nothing from the failure vocabulary to stderr (D11: the AVM logs there)" "0" "$(m15_stderr_unexpected "$OUT.err")"
assert_eq "it covered the seven corpus programs" "$M15_EXPECTED_PROGRAMS" \
  "$(m15_key "$OUT" crossings.programs.count)"

# ---------------------------------------------------------------------------
# The op table is the two interfaces, entire.
# ---------------------------------------------------------------------------
assert_eq "the op table has one entry per interface method: 8 + 14" "22" \
  "$(m15_key "$OUT" crossings.opTableSize)"
# Named, in both directions, against the interface header itself rather than against a list here.
DB_HPP="$FORK_ROOT/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/db.hpp"
assert_file "the interface header is where it is expected" "$DB_HPP"
for m in get_contract_instance get_contract_class get_bytecode_commitment get_debug_function_name \
         add_contracts get_tree_roots get_sibling_path get_low_indexed_leaf get_leaf_value \
         get_leaf_preimage_public_data_tree get_leaf_preimage_nullifier_tree \
         insert_indexed_leaves_public_data_tree insert_indexed_leaves_nullifier_tree \
         append_leaves pad_tree get_checkpoint_id; do
  assert_ge "the interface declares $m" 1 "$(grep -cE "\b$m\b" "$DB_HPP" || true)"
  assert_ge "and the op table names it" 1 "$(grep -cE "\b$m'" "$M15_CROSSINGS_LIB" || true)"
done

# ---------------------------------------------------------------------------
# Every program, against the budget, in both directions.
# ---------------------------------------------------------------------------
MAXSEEN=0
for p in $M15_PROGRAMS; do
  n="$(m15_key "$OUT" "crossings.$p.total")"
  case "$n" in ''|*[!0-9]*) die "no crossing total for $p (got '$n')" ;; esac
  b="$(m15_key "$OUT" "crossings.$p.hintedBytes")"
  note "$p: $n DB crossings, hinted payload $b bytes"
  # Upper: the budget.
  assert_true "$p: within the per-transaction DB crossing budget of $M15_CROSSING_BUDGET" \
    test "$n" -le "$M15_CROSSING_BUDGET"
  # Lower: a transaction that read the world state zero times did not run. Twelve is below every
  # measured program and above zero, so it refuses an empty decode without pinning the corpus.
  assert_ge "$p: and it really crossed — a zero here would be a decoder that returned nothing" \
    12 "$n"
  # The hint record must have been fully understood, or the count is a lower bound of unknown depth.
  assert_eq "$p: every hint category in the blob is accounted for" "-" \
    "$(m15_key "$OUT" "crossings.$p.unmappedHintCategories")"
  [ "$n" -gt "$MAXSEEN" ] && MAXSEEN="$n"
done
note "the corpus maximum is $MAXSEEN against a budget of $M15_CROSSING_BUDGET"
assert_true "the budget is a ceiling with room, not the measurement itself" \
  test "$MAXSEEN" -lt "$M15_CROSSING_BUDGET"
# ...and not so much room that nothing could exceed it. A budget three times the worst case would
# not notice a shape change that tripled the crossings.
assert_true "and it is not so loose that a doubling would pass" \
  test "$M15_CROSSING_BUDGET" -lt $((MAXSEEN * 2))

# ---------------------------------------------------------------------------
# THE SHAPE OF THE COUNT IS THE FINDING, and it is asserted rather than left to the reader.
# `burn` executes 38,903 instructions and consults the host a couple of dozen times, because
# `PureMerkleDB` inside vm2 satisfies the high-level surface itself and only the low-level misses
# reach the boundary. If that ever stops being true — an AVM that consulted the host per memory
# access — this is the assertion that says so.
# ---------------------------------------------------------------------------
BURN="$(m15_key "$OUT" crossings.burn.total)"
assert_true "burn's 38,903 instructions cost fewer than fifty DB crossings" test "$BURN" -lt 50
# The per-op breakdown is present and non-degenerate: at least six distinct methods are used, so
# the total is not one method called n times.
DISTINCT="$(grep -c "^crossings.burn.op\." "$OUT" || true)"
assert_ge "and they are spread over at least six distinct interface methods" 6 "$DISTINCT"
assert_true "the sibling-path reads are a handful, not one per instruction" \
  test "$(m15_key "$OUT" crossings.burn.op.merkle.get_sibling_path)" -lt 20

# ---------------------------------------------------------------------------
# The recorded budget lives in the write-up too, and the check re-derives it rather than trusting
# it: a number in prose that no check asserts is a number that drifts, which is the defect M13's
# review found in REACTOR-ABI.md.
# ---------------------------------------------------------------------------
assert_file "the boundary write-up exists" "$M15_WRITEUP"
assert_ge "it states the per-transaction crossing budget" 1 \
  "$(grep -c "$M15_CROSSING_BUDGET" "$M15_WRITEUP" || true)"
for p in $M15_PROGRAMS; do
  n="$(m15_key "$OUT" "crossings.$p.total")"
  assert_ge "the write-up carries $p's measured count of $n" 1 \
    "$(grep -cE "\| *$p *\|.*\| *$n *\|" "$M15_WRITEUP" || true)"
done

finish
