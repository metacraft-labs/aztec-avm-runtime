#!/usr/bin/env bash
# test_checkpoint_lockstep_contract_and_merkle
#
# The two interfaces have INDEPENDENT create/commit/revert stacks, and nothing in either type
# relates one to the other. If they drift, a reverted transaction leaves the contract state
# describing one history and the trees describing another — silently, and long before anyone looks.
#
# THIS CHECK IS TWO RUNS OF THE SAME INJECTION, and the pair is the point.
#
#   * Driven through the `CheckpointCoordinator`, an injected desynchronisation is DETECTED: the
#     next coordinated operation fails, names which side moved, and refuses to unwind. Three
#     integers — the coordinator's depth and each DB's checkpoint id — must be EQUAL, and the
#     equality is the assertion rather than "they were driven together", which is a claim about a
#     program and not about a state.
#
#   * Driven by hand, as a consumer without a coordinating owner would, the same injection produces
#     a WRONG STATE THAT LOOKS RIGHT. Every call succeeds, every root is well-formed, the contract
#     DB unwinds exactly as expected — and the trees unwind to the injected level instead of the
#     original one, keeping a write the contract state has no record of. That arm is required to
#     produce that outcome, so "detected rather than producing a plausible-looking wrong state" is
#     a comparison of two measured runs rather than an assurance.
#
# The injection is done through the per-DB checkpoint exports, which are still there because they
# are eight-of-eight and fourteen-of-fourteen of the two interfaces. A module that had removed them
# could not be desynchronised by a host and could also no longer claim its export list is the
# interface.
#
# The underflow guard is checked too: `world_state::MemoryMerkleDB::commit_checkpoint` pops a
# `std::stack` without testing it, so the coordinator's depth test is what stands between a host and
# undefined behaviour in upstream's code.

TEST_NAME="test_checkpoint_lockstep_contract_and_merkle"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"

m13_measured

OUT="$M13_WORK/lockstep.out"
ERR="$M13_WORK/lockstep.err"
m13_run_host lockstep "$OUT" "$ERR"
rc=$?
assert_eq "the host ran the lockstep arms" "0" "$rc"
assert_file "it produced a transcript" "$OUT"
[ -s "$OUT" ] || die "the transcript is empty — see $ERR"
m13_assert_field "it ran to completion" "$OUT" "lockstep.done" "1"
m13_assert_field "and leaked no linear-memory allocation" "$OUT" "lockstep.ownedAllocationsAtExit" "0"

# --- 1. the coordinator keeps the three integers equal ----------------------
for stage in initial:0 afterCreate:1 afterNestedCreate:2 afterRevert:1 afterCommit:0 \
             afterUnderflowAttempts:0; do
  label="${stage%%:*}"; want="${stage##*:}"
  m13_assert_field "$label: the coordinator is at depth $want" "$OUT" "lockstep.$label.depth" "$want"
  m13_assert_field "$label: the contract DB's checkpoint id agrees" "$OUT" "lockstep.$label.contractId" "$want"
  m13_assert_field "$label: the merkle DB's checkpoint id agrees" "$OUT" "lockstep.$label.merkleId" "$want"
  m13_assert_field "$label: and the module's own lockstep assertion succeeds" "$OUT" "lockstep.$label.assert" "0"
done

# --- 2. the underflow guard --------------------------------------------------
m13_assert_field "committing with nothing open fails" "$OUT" "lockstep.underflow.commit.status" "1"
m13_assert_field "with the TypeScript PublicContractsDB's own message" \
  "$OUT" "lockstep.underflow.commit.message" "No checkpoint to commit"
m13_assert_field "reverting with nothing open fails" "$OUT" "lockstep.underflow.revert.status" "1"
m13_assert_field "with its own message too" \
  "$OUT" "lockstep.underflow.revert.message" "No checkpoint to revert"

# --- 3. the injected desynchronisation, merkle side -------------------------
m13_assert_field "after the injection the coordinator is still at depth 1" "$OUT" "lockstep.injectMerkle.depth" "1"
m13_assert_field "and so is the contract DB" "$OUT" "lockstep.injectMerkle.contractId" "1"
m13_assert_field "but the merkle DB has moved to 2" "$OUT" "lockstep.injectMerkle.merkleId" "2"
m13_assert_field "the lockstep assertion FAILS" "$OUT" "lockstep.injectMerkle.assert.status" "1"
inject_msg="$(m13_field "$OUT" "lockstep.injectMerkle.assert.message")"
assert_contains "and it names the MERKLE side rather than saying they disagree" \
  "the MERKLE db stack moved outside the coordinator" "$inject_msg"
assert_not_contains "and does not name the innocent one" "CONTRACT db stack" "$inject_msg"
assert_contains "and reports all three integers" "coordinator=1 contractDb=1 merkleDb=2" "$inject_msg"
m13_assert_field "a coordinated create refuses" "$OUT" "lockstep.injectMerkle.create.status" "1"
m13_assert_field "a coordinated revert refuses rather than unwinding the wrong level" \
  "$OUT" "lockstep.injectMerkle.revert.status" "1"
m13_assert_field "and a simulation through the coordinator refuses to start" \
  "$OUT" "lockstep.injectMerkle.simulate.status" "1"

# --- 4. the injected desynchronisation, contract side -----------------------
m13_assert_field "an injection on the other side also fails" "$OUT" "lockstep.injectContract.assert.status" "1"
inject_msg2="$(m13_field "$OUT" "lockstep.injectContract.assert.message")"
assert_contains "and names the CONTRACT side" \
  "the CONTRACT db stack moved outside the coordinator" "$inject_msg2"
assert_not_contains "and not the merkle one" "MERKLE db stack" "$inject_msg2"
assert_contains "with its own three integers" "coordinator=1 contractDb=2 merkleDb=1" "$inject_msg2"

# --- 5. the wrong state a naive owner produces from the same injection ------
before="$(m13_field "$OUT" "lockstep.naive.rootsBeforeInjection")"
injected="$(m13_field "$OUT" "lockstep.naive.rootsAfterInjection")"
after="$(m13_field "$OUT" "lockstep.naive.rootsAfterRevert")"
assert_eq "the injection really moved the trees, so the arm below is measuring something" "1" \
  "$(m13_field "$OUT" "lockstep.naive.injectionMovedRoots")"
m13_assert_field "the hand-driven transaction really registered a contract" \
  "$OUT" "lockstep.naive.deployedInstancePresentInsideTx" "1"
m13_assert_field "and the contract DB unwound exactly as a reader would expect" \
  "$OUT" "lockstep.naive.contractUnwound" "1"
m13_assert_field "while the trees did NOT return to where the transaction found them" \
  "$OUT" "lockstep.naive.rootsMatchPreInjection" "0"
m13_assert_field "they returned to the INJECTED level instead" \
  "$OUT" "lockstep.naive.rootsMatchInjectedLevel" "1"
assert_eq "which is a different, well-formed state and not an error" "1" \
  "$([ -n "$after" ] && [ "$after" != "$before" ] && [ "$after" = "$injected" ] && echo 1 || echo 0)"
m13_assert_field "the two stacks are left at different positions" "$OUT" "lockstep.naive.contractId" "0"
m13_assert_field "which is the whole failure, stated as two integers" "$OUT" "lockstep.naive.merkleId" "1"
m13_assert_field "and a coordinator over that same state catches it" \
  "$OUT" "lockstep.naive.coordinatorDetects.status" "1"
assert_contains "naming the side that moved" "the MERKLE db stack moved outside the coordinator" \
  "$(m13_field "$OUT" "lockstep.naive.coordinatorDetects.message")"

finish
