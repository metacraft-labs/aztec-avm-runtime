#!/usr/bin/env bash
# test_checkpoint_depth_balanced_after_nested_reverts
#
# Every corpus program simulated THROUGH the coordinator, with an outer checkpoint held open around
# it as a block-level owner would hold one. Both checkpoint stacks must be at the depth they started
# at when the simulation returns, and the outer revert must restore the trees exactly.
#
# THE NESTING IS UPSTREAM'S, NOT THIS CHECK'S. Inside `AvmSimAPI::simulate`, `TxExecution` opens a
# checkpoint on BOTH DBs at the end of setup and closes it on the app-logic and teardown paths,
# while `ContextProvider` and `Execution` open one on the MERKLE db alone per call frame —
# deliberately, because a nested call can write storage and cannot publish a contract class. So the
# two stacks are not at equal depth part-way through a transaction and a check that asserted they
# were would be wrong. What must hold is that they are balanced by the time the call returns, and
# that is what is asserted, before and after, by identity.
#
# THE CORPUS CARRIES BOTH OUTCOMES. `add`, `loop`, `poseidon2`, `sha256` and `storage` succeed;
# `revert` reverts its app logic and `burn` runs out of gas. A roundtrip whose programs only ever
# succeed exercises the commit path and calls it balanced. The revert codes are asserted per program
# from the same run, so the mix is a measurement rather than an assumption about the corpus.

TEST_NAME="test_checkpoint_depth_balanced_after_nested_reverts"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"

m13_measured

OUT="$M13_WORK/nested.out"
ERR="$M13_WORK/nested.err"
m13_run_host nested "$OUT" "$ERR"
rc=$?
assert_eq "the host ran every corpus program through the coordinator" "0" "$rc"
assert_file "it produced a transcript" "$OUT"
[ -s "$OUT" ] || die "the transcript is empty — see $ERR"
m13_assert_field "it ran to completion" "$OUT" "nested.done" "1"
m13_assert_field "over all seven corpus programs" "$OUT" "nested.programs.count" "$M13_EXPECTED_PROGRAMS"
m13_assert_field "and leaked no linear-memory allocation" "$OUT" "nested.ownedAllocationsAtExit" "0"

succeeded=0
reverted=0
for prog in $M13_PROGRAMS; do
  p="nested.$prog"
  m13_assert_field "$prog: the outer checkpoint is open at depth 1 on both stacks before the call" \
    "$OUT" "$p.before" "1/1/1"
  m13_assert_field "$prog: and the call returns with both stacks back at that depth" \
    "$OUT" "$p.after" "1/1/1"
  m13_assert_field "$prog: the module's own lockstep assertion succeeds after the simulation" \
    "$OUT" "$p.assertAfterSimulate" "0"
  m13_assert_field "$prog: unwinding the outer checkpoint leaves both stacks at zero" \
    "$OUT" "$p.end" "0/0/0"
  m13_assert_field "$prog: and restores every tree root the simulation moved" \
    "$OUT" "$p.rootsRestored" "1"

  code="$(m13_field "$OUT" "$p.revertCode")"
  case " $M13_REVERTING_PROGRAMS " in
    *" $prog "*)
      assert_eq "$prog: reverts, as the corpus says it does" "1" "$code"
      reverted=$((reverted + 1)) ;;
    *)
      assert_eq "$prog: succeeds, as the corpus says it does" "0" "$code"
      succeeded=$((succeeded + 1)) ;;
  esac
done
assert_eq "five programs succeeded" "5" "$succeeded"
assert_eq "and two reverted, so both paths through TxExecution's checkpoint pairs were taken" \
  "2" "$reverted"

# Every call frame the simulations opened is a merkle-only checkpoint that had to be balanced by
# `Execution` before the counts above could hold. Reported so the depth claim is not vacuous for a
# corpus that opened none.
frames=0
for prog in $M13_PROGRAMS; do
  n="$(m13_field "$OUT" "nested.$prog.callFrames")"
  case "$n" in ''|*[!0-9]*) fail "$prog: no call-frame count in the transcript" ;; *) frames=$((frames + n)) ;; esac
done
assert_ge "the seven simulations opened at least seven call frames between them" "7" "$frames"
note "call frames across the corpus: $frames"

finish
