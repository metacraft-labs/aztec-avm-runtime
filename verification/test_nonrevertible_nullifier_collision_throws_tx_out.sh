#!/usr/bin/env bash
# test_nonrevertible_nullifier_collision_throws_tx_out — M20, and the milestone's stated risk.
#
# The deliverable: "The asymmetric revert model preserved exactly, including that a nullifier
# collision inserting revertible private side effects throws the transaction out while an
# APP_LOGIC revert only soft-reverts."
#
# NOTE THE MISMATCH BETWEEN THAT SENTENCE AND THIS TEST'S NAME, because it matters. The
# deliverable is about the REVERTIBLE collision; the verification entry is named for the
# NON-revertible one. Both throw the transaction out, and only one of them is surprising. This
# check carries BOTH, and the assertion that would catch a wrong implementation is the revertible
# one — everything else about revertible insertion soft-reverts, so an engine that treated a
# revertible collision as recoverable would look correct until a real collision happened, at which
# point it would put an unprovable transaction in a block.
#
# WHERE THE MODEL LIVES, AND WHY THIS CHECK READS C++. Upstream moved public transaction execution
# out of TypeScript between the two anchors: `PublicTxContext` no longer exists and
# `PublicTxSimulator` no longer has a phase loop. The three-phase model, the gas accounting and
# this asymmetry are all in
# `barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/tx_execution.cpp`, which is compiled
# INTO `avm.wasm`. So there is nothing of ours to get wrong here and nothing to vendor — what
# there is to prove is that the shipped module still behaves this way and that our classification
# of its output preserves the distinction rather than flattening it.
#
# FOUR ARMS AND THEY MUST DISAGREE. A test that only showed "the collision arms were rejected"
# would pass against an engine that rejected everything. The APP_LOGIC arm beside them LANDS, from
# the same tree, in the same phase as the revertible insertion, with the same kind of failure.
#
# Run: just verify-form-a-asymmetry

TEST_NAME="test_nonrevertible_nullifier_collision_throws_tx_out"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m20_form_a.sh"

m20_require_anchor
mkdir -p "$M20_WORK"
SCRATCH="$(mktemp -d "$M20_WORK/asymmetry.XXXXXX")" || die "no scratch under $M20_WORK"
trap 'rm -rf "$SCRATCH"' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — the model, read out of the C++ at the pinned anchor
# ---------------------------------------------------------------------------

TXE="$SCRATCH/tx_execution.cpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/tx_execution.cpp > "$TXE"
assert_ge "tx_execution.cpp was read from the anchor and is not empty" 400 "$(wc -l < "$TXE")"
note "anchor $M20_CPP_ANCHOR"

# The doc comment states the rule. Asserted as text because it is the only place upstream WRITES
# the rule down, and because a rewording is a signal worth catching.
assert_ge "the header states that a revertible-insertion collision is ALSO unprovable" 1 \
  "$(grep -c 'A nullifier collision during revertible insertions is ALSO unprovable' "$TXE")"
assert_ge "and that a side-effect limit or an APP_LOGIC failure reverts to the post-setup state" 1 \
  "$(grep -c 'If a side-effect limit is reached during revertible insertions or App Logic phase fails' "$TXE")"

# The mechanism, not just the prose. `emit_nullifier` is shared by both phases and rethrows the
# collision; `simulate`'s catch clause is typed to `TxExecutionException`, which
# `NullifierCollisionException` is NOT, so it passes straight through.
assert_eq "emit_nullifier serves both phases from one body" "1" \
  "$(grep -c 'void TxExecution::emit_nullifier(bool revertible, const FF& nullifier)' "$TXE")"
assert_ge "it rethrows the collision with the phase in the message" 1 \
  "$(grep -c '_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision: ' "$TXE")"
assert_ge "and says in a comment that the rethrow is deliberately not caught in this file" 1 \
  "$(grep -c "note that this exception isn't being caught in this file" "$TXE")"

# THE LOAD-BEARING TYPE FACT: every catch in the file is typed to one of exactly two exception
# types. If any of them were `catch (...)`, or named a BASE of the collision type, the asymmetry
# would collapse and an unprovable transaction would soft-revert into a block.
#
# ASSERTED, NOT PRINTED. An earlier revision computed the type census, printed it, and asserted
# only `grep -c 'catch (\.\.\.)' == 0` — one fixed spelling with one space. Measured: a file
# containing BOTH `catch(...)` (no space) AND `catch (const std::exception& e)` scores 0 on that
# needle, and either one catches `NullifierCollisionException`, because it derives from
# `std::runtime_error` (simulation/interfaces/db.hpp) exactly as `TxExecutionException` does. A
# printed census beside an assertion that cannot see the dangerous case is the campaign's
# printed-literal defect wearing a census.
#
# So: every catch clause in the file is ENUMERATED, and the set of types is compared against the
# expected set exactly. A new catch of any type — base class, catch-all, or a third exception —
# changes the set and fails here rather than passing quietly.
CATCH_CLAUSES="$(grep -oE 'catch[[:space:]]*\([^)]*\)' "$TXE")"
CATCH_TYPES="$(printf '%s\n' "$CATCH_CLAUSES" \
  | sed -E 's/^catch[[:space:]]*\([[:space:]]*(const[[:space:]]+)?//; s/[[:space:]]*&?[[:space:]]*[A-Za-z_]*[[:space:]]*\)$//' \
  | sed -E 's/^[[:space:]]*//; s/[[:space:]]*$//' | sort -u)"
printf '%s\n' "$CATCH_CLAUSES" | sort | uniq -c | sed 's/^ *//; s/^/      /'
assert_ge "the catch clauses were actually found, so the census is not a census of nothing" 5 \
  "$(printf '%s\n' "$CATCH_CLAUSES" | grep -c .)"
assert_eq "and EVERY catch in the file is one of exactly two typed handlers" \
  "NullifierCollisionException
TxExecutionException" "$CATCH_TYPES"

# The four spellings that would each collapse the asymmetry, named individually so a failure says
# WHICH one appeared. `std::runtime_error` and `std::exception` are bases of the collision type;
# `catch(...)` is matched in both spacings.
assert_eq "no catch-all anywhere in tx_execution.cpp, in either spacing" "0" \
  "$(grep -cE 'catch[[:space:]]*\([[:space:]]*\.\.\.[[:space:]]*\)' "$TXE" || true)"
assert_eq "and nothing catches std::exception, which WOULD catch the collision" "0" \
  "$(grep -cE 'catch[[:space:]]*\([^)]*std::exception' "$TXE" || true)"
assert_eq "nor std::runtime_error, the collision type's actual base" "0" \
  "$(grep -cE 'catch[[:space:]]*\([^)]*std::runtime_error' "$TXE" || true)"
# THE CONTROL for those three zeroes: the same command family must find a catch that IS there,
# or all three are greps that cannot match.
assert_ge "while the same command family does find the typed catches that are there" 6 \
  "$(grep -cE 'catch[[:space:]]*\([^)]*TxExecutionException' "$TXE" || true)"

assert_eq "and NullifierCollisionException is caught in exactly one place — where it is rethrown" \
  "1" "$(grep -c 'catch (const NullifierCollisionException& e)' "$TXE")"

# THE HIERARCHY, READ RATHER THAN ASSUMED. "TxExecutionException does not catch the collision" is
# only true because the two are SIBLINGS. If either ever derived from the other, or from a common
# non-std base that the other caught, every assertion above would still pass and the asymmetry
# would be gone. Both declarations are read out of the anchor.
DBH="$SCRATCH/db.hpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/db.hpp > "$DBH"
assert_ge "db.hpp was read from the anchor" 50 "$(wc -l < "$DBH")"
assert_eq "NullifierCollisionException derives from std::runtime_error" "1" \
  "$(grep -c 'class NullifierCollisionException : public std::runtime_error' "$DBH")"
assert_eq "TxExecutionException derives from std::runtime_error TOO — they are SIBLINGS" "1" \
  "$(grep -c 'class TxExecutionException : public std::runtime_error' "$TXE")"
assert_eq "so nothing declares one a base of the other" "0" \
  "$(grep -cE 'class (NullifierCollisionException : public TxExecutionException|TxExecutionException : public NullifierCollisionException)' "$TXE" "$DBH" | awk -F: '{s+=$2} END {print s+0}')"

# The three throw sites that a host can ever see from pay_fee, which runs OUTSIDE every try.
assert_ge "pay_fee is called after the teardown catch, outside every try" 1 \
  "$(grep -c '^    pay_fee(tx.fee_payer, fee, fee_per_da_gas, fee_per_l2_gas);' "$TXE")"

# ---------------------------------------------------------------------------
# PART 2 — every needle our classifier matches exists in the C++ it claims to come from
# ---------------------------------------------------------------------------

NEEDLES="$(cd "$ORCH_DIR" && node --input-type=module -e "
const m = await import('./src/index.ts');
for (const [reason, needle] of m.FAILURE_NEEDLES) console.log(reason + '\t' + needle);
" 2>&1)" || die "could not read FAILURE_NEEDLES: $NEEDLES"
printf '%s\n' "$NEEDLES" | sed 's/^/      /'
assert_eq "the classifier declares eight needles" "8" "$(printf '%s\n' "$NEEDLES" | grep -c .)"

# Each needle is a FIXED-STRING substring of a format string in the C++. The collision pair is
# assembled by the C++ from `revertible ? "R" : "NR"`, so those two are matched by their two
# halves rather than as one literal — which is exactly the concatenation a naive grep would miss.
while IFS=$'\t' read -r reason needle ; do
  [ -n "$needle" ] || continue
  case "$needle" in
    '[NR_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision:'|'[R_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision:')
      assert_ge "$reason: the C++ assembles this message from the phase letter and the tail" 1 \
        "$(grep -c '_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision: ' "$TXE")"
      ;;
    *)
      assert_ge "$reason: the needle appears verbatim in tx_execution.cpp" 1 \
        "$(grep -cF -- "$needle" "$TXE")"
      ;;
  esac
done <<< "$NEEDLES"

# The control for that loop: a plausible-looking needle that is NOT in the C++ must not be found,
# or every assertion above is a grep that matches anything.
assert_eq "a needle the C++ does not contain is not found by the same grep" "0" \
  "$(grep -cF -- '[NR_NOTE_HASH_INSERTION] UNRECOVERABLE' "$TXE" || true)"

# ---------------------------------------------------------------------------
# PART 3 — the module, run: three arms, and they disagree
# ---------------------------------------------------------------------------

m20_require_arms
note "module $AVM_WASM_PATH"

assert_eq "a NON-REVERTIBLE private nullifier collision throws the transaction out" "failed" \
  "$(m20_arm nonRevertibleNullifierClash external.kind)"
assert_eq "and is classified from the module's own [NR_...] message" \
  "nonRevertibleNullifierCollision" "$(m20_arm nonRevertibleNullifierClash external.reason)"

assert_eq "A REVERTIBLE private nullifier collision ALSO throws the transaction out" "failed" \
  "$(m20_arm revertibleNullifierClash external.kind)"
assert_eq "and is classified separately, so 'which phase' survives" \
  "revertibleNullifierCollision" "$(m20_arm revertibleNullifierClash external.reason)"

# THE ARM THAT MAKES THE TWO ABOVE MEAN SOMETHING. Same tree, same phase, a failure of the same
# kind — an exceptional halt from a checked exception — and it LANDS.
assert_eq "an APP_LOGIC failure in the same phase LANDS as a soft revert" "processed" \
  "$(m20_arm appLogicOnlyFunded external.kind)"
assert_eq "with a non-zero revert code" "1" "$(m20_arm appLogicOnlyFunded external.rawRevertCode)"

# Each collision arm seeded the nullifier it then collided with. Without this the arms could be
# colliding with a genesis nullifier they did not put there — measured hazard: `mockTx` seeds
# under ~100 produce nullifiers the prefilled tree already holds.
for arm in nonRevertibleNullifierClash revertibleNullifierClash ; do
  SEEDED="$(m20_arm "$arm" seededNullifier)"
  assert_true "$arm seeded the colliding nullifier itself" test "$SEEDED" != "null"
  assert_true "and it is not the zero field" test "$SEEDED" != "0x0000000000000000000000000000000000000000000000000000000000000000"
done
assert_eq "the arms that are not about collisions seeded nothing" "null|null" \
  "$(m20_arm appLogicOnlyFunded seededNullifier)|$(m20_arm setupCallFails seededNullifier)"

# The two collision arms seeded DIFFERENT nullifiers, so they are two runs and not one repeated.
assert_true "the two collision arms are distinct transactions" \
  test "$(m20_arm nonRevertibleNullifierClash seededNullifier)" != "$(m20_arm revertibleNullifierClash seededNullifier)"

# ---------------------------------------------------------------------------
# PART 4 — a thrown-out transaction is not a reverted one, anywhere in our types
# ---------------------------------------------------------------------------

# `FormAFailed` has no revert code and no result: a caller reaching for one gets `undefined`
# rather than a plausible zero.
assert_eq "the rejected outcome carries no revertCode field" "0" \
  "$(grep -c 'revertCode' <(sed -n '/export interface FormAFailed/,/^}/p' "$ORCH_SRC/form_a.ts") || true)"
assert_eq "and no result field" "0" \
  "$(grep -c 'readonly result' <(sed -n '/export interface FormAFailed/,/^}/p' "$ORCH_SRC/form_a.ts") || true)"
assert_ge "while the landed outcome does carry the result" 1 \
  "$(grep -c 'readonly result: PublicTxResult' <(sed -n '/export interface FormAProcessed/,/^}/p' "$ORCH_SRC/form_a.ts") || true)"

finish
