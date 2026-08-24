#!/usr/bin/env bash
# test_wasm_trap_vs_avm_revert_distinguished — M17.
#
# A WASM TRAP AND AN AVM REVERT MUST NEVER BE CONFUSED, AND THE TYPE SYSTEM IS WHAT ENFORCES IT.
#
# The two are not two flavours of failure. A REVERT is a transaction outcome: the transaction ran,
# it reverted, it lands in a block and it pays its fee. A TRAP is a runtime bug: the instance is
# dead and its linear memory is undefined. A boundary that surfaced both as "the call failed" would
# make a bug in our host look like a contract that reverted — the one confusion that makes a
# debugger lie to its user — and would make a genuine host bug look like a normal outcome, which is
# worse.
#
# THIS CHECK ATTACKS THE DISTINCTION FROM BOTH ENDS.
#
#   AT RUN TIME, five arms through the same boundary function, on the REAL module:
#     * the `revert` corpus program              -> a transaction outcome, revertCode non-zero
#     * the `add` corpus program (the control)   -> a transaction outcome, revertCode zero
#     * a DB handle that was never created       -> a host error, status 3
#     * bytes that are not msgpack               -> a host error, status 1
#     * a pointer past the end of linear memory  -> a TRAP
#   The trap is a genuine one on the real module rather than on a toy: the host hands `avm_simulate`
#   a pointer outside linear memory, the module's own msgpack reader loads out of bounds, and that
#   is a wasm trap and therefore something the C++ `guarded()` CANNOT catch, because it is not an
#   exception. It is also exactly the shape of the host bug the deliverable is about. The two
#   host-error arms are what make it a discrimination: the same export, the same code path, and
#   only the pointer differs.
#
#   AT COMPILE TIME, four negative cases that must FAIL TO COMPILE and one positive control that
#   must compile with the same compiler and the same flags:
#     * a trap returned where a TxOutcome is expected
#     * `.revertCode` read off a trap
#     * an outcome passed where a failure is expected
#     * a switch over the failure kinds that forgets one
#   The positive control is not decoration: without it, "the negative cases fail to compile" would
#   be a claim about the compiler invocation — a misspelled flag, a wrong path or a missing file
#   all make `tsc` exit non-zero too.
#
# AND THE INSTANCE IS POISONED. A trapped instance's memory is undefined, so everything it says
# afterwards is meaningless; the pool must retire it rather than hand it out again. That is
# measured here too, because a pool that recycled a trapped instance would turn one runtime bug
# into an unbounded number of wrong answers.
#
# Run: just verify-node-trap-revert

TEST_NAME="test_wasm_trap_vs_avm_revert_distinguished"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"

m17_measured

# ---------------------------------------------------------------------------
echo "== 1. the run"
# ---------------------------------------------------------------------------
m17_run traprevert "$(m17_out traprevert)" "$(m17_err traprevert)"
RC=$?
assert_eq "the trap/revert probe exits 0 — every arm was reached and classified" 0 "$RC"
assert_eq "…and its transcript is complete rather than truncated" \
  "complete" "$(m17_completeness "$(m17_out traprevert)" traprevert)"
T="$(m17_out traprevert)"
f() { m17_field "$T" "$1"; }

# ---------------------------------------------------------------------------
echo "== 2. a revert is a TRANSACTION OUTCOME"
# ---------------------------------------------------------------------------
assert_eq "the revert program produces a transaction outcome" "tx-outcome" "$(f traprevert.revert.kind)"
assert_true "…whose revert code is non-zero" test "$(f traprevert.revert.revertCode)" -ne 0
assert_eq "…so it reports as reverted" "1" "$(f traprevert.revert.reverted)"
assert_eq "…and the instance is untouched, because nothing went wrong with the runtime" \
  "1" "$(f traprevert.revert.instanceStillUsable)"

# THE CONTROL that makes the above a discrimination rather than an observation: a program that does
# NOT revert, through the same code path. A boundary that called everything a revert passes the
# four assertions above and fails these.
assert_eq "a successful program also produces a transaction outcome" \
  "tx-outcome" "$(f traprevert.success.kind)"
assert_eq "…with revert code zero" "0" "$(f traprevert.success.revertCode)"
assert_eq "…so it does NOT report as reverted" "0" "$(f traprevert.success.reverted)"
assert_true "the two outcomes differ in their revert code, so the field is read and not defaulted" \
  test "$(f traprevert.revert.revertCode)" != "$(f traprevert.success.revertCode)"

# ---------------------------------------------------------------------------
echo "== 3. a host error is neither an outcome nor a trap"
# ---------------------------------------------------------------------------
assert_eq "a DB handle that was never created is a host error" \
  "host-error" "$(f traprevert.badHandle.classified)"
assert_eq "…with the module's own status 3, 'no such DB handle'" "3" "$(f traprevert.badHandle.status)"
assert_eq "bytes that are not msgpack are a host error too" \
  "host-error" "$(f traprevert.malformedInput.classified)"
assert_eq "…with status 1, a std::exception that the module caught" \
  "1" "$(f traprevert.malformedInput.status)"
assert_eq "…and it carries the module's own error message rather than an empty envelope" \
  "1" "$(f traprevert.malformedInput.messagePresent)"
assert_eq "neither of them poisoned the instance, because neither is a trap" \
  "1" "$(f traprevert.beforeTrap.instanceUsable)"

# ---------------------------------------------------------------------------
echo "== 4. a trap is a TRAP, and it is a real one on the real module"
# ---------------------------------------------------------------------------
note "linear memory $(f traprevert.trap.memoryBytes) bytes; the induced pointer is $(f traprevert.trap.pointer)"
assert_true "the induced pointer is genuinely past the end of linear memory" \
  test "$(f traprevert.trap.pointer)" -gt "$(f traprevert.trap.memoryBytes)"
assert_eq "an out-of-bounds pointer traps" "trap" "$(f traprevert.trap.classified)"
assert_eq "…and the trap names the export it happened in" "avm_simulate" "$(f traprevert.trap.exportName)"
# THE ASSERTION THIS WHOLE CHECK IS FOR.
assert_eq "a trap is NEVER reported as a transaction outcome" "0" "$(f traprevert.trap.reportedAsOutcome)"
# READ OFF THE CAUGHT OBJECT, not written down as a constant. The probe used to print a literal 0
# here because `errors.ts` declares no `revertCode` on `AvmTrap`; a mutation round showed that a
# `poison()` which attached one at RUNTIME passed the type check, passed the class-body grep in
# section 7, and still left a caught trap answering 0 to `.revertCode` — a runtime bug reported as
# a transaction that succeeded. The control beside it is the same `in` test over the REVERT, which
# does have one, so a probe answering 0 to everything cannot satisfy this pair.
assert_eq "…and it carries no revert code at all, so nothing can read success out of it" \
  "0" "$(f traprevert.trap.hasRevertCodeProperty)"
assert_eq "…while the SAME test finds one on the revert outcome, so the reading discriminates" \
  "1" "$(f traprevert.revert.hasRevertCodeProperty)"
assert_eq "the trapped instance is poisoned" "1" "$(f traprevert.trap.instancePoisoned)"
assert_eq "a call on a poisoned instance is refused rather than answered from a dead memory" \
  "poisoned" "$(f traprevert.afterTrap.classified)"
# The four classifications are four DIFFERENT tokens. A classifier that collapsed two of them would
# still satisfy each assertion above taken alone.
CLASSES="$(printf '%s\n%s\n%s\n%s\n' "$(f traprevert.revert.kind)" "$(f traprevert.badHandle.classified)" \
  "$(f traprevert.trap.classified)" "$(f traprevert.afterTrap.classified)" | LC_ALL=C sort -u | grep -c .)"
assert_eq "the four outcomes are four distinct classifications, not one word for everything" "4" "$CLASSES"

# ---------------------------------------------------------------------------
echo "== 5. the pool retires a trapped instance"
# ---------------------------------------------------------------------------
assert_eq "the pooled instance really did trap, so the retirement has something to retire" \
  "1" "$(f traprevert.pool.firstPoisoned)"
assert_eq "the next acquisition is a fresh instance, not the poisoned one" \
  "0" "$(f traprevert.pool.secondPoisoned)"
assert_eq "…and the pool says it retired one" "1" "$(f traprevert.pool.retired)"
assert_eq "…having constructed two in total" "2" "$(f traprevert.pool.created)"

# ---------------------------------------------------------------------------
echo "== 6. the TYPE SYSTEM enforces it: four negatives and a positive control"
# ---------------------------------------------------------------------------
POS="$M17_PKG/typecheck/positive/discriminates.ts"
assert_file "the positive control exists" "$POS"
POS_OUT="$(m17_tsc_file "$POS")"
POS_RC=$?
assert_eq "the CORRECT use of the types compiles, with the same compiler and the same flags" 0 "$POS_RC"
[ "$POS_RC" -eq 0 ] || note "$POS_OUT"

neg_typecheck() { # <file> <expected TS code> <what it is>
  local file="$1" code="$2" what="$3" out rc
  assert_file "the negative case exists: $what" "$file"
  out="$(m17_tsc_file "$file")"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$what — IT COMPILED. The type system does not enforce this."
    return
  fi
  pass "$what — rejected by the compiler"
  # By error code, not merely non-zero: a typo in the path, a missing import or an unrelated
  # mistake in the file would also make tsc exit non-zero, and would prove nothing about the types.
  assert_contains "…and specifically with $code, which is the error the distinction produces" \
    "error $code" "$out"
}

neg_typecheck "$M17_PKG/typecheck/negative/trap_is_not_an_outcome.ts" "TS2739" \
  "a trap returned where a transaction outcome is expected"
neg_typecheck "$M17_PKG/typecheck/negative/trap_has_no_revert_code.ts" "TS2339" \
  "a revert code read off a trap"
neg_typecheck "$M17_PKG/typecheck/negative/outcome_is_not_a_failure.ts" "TS2345" \
  "a transaction outcome passed where a failure is expected"
neg_typecheck "$M17_PKG/typecheck/negative/failure_switch_is_exhaustive.ts" "TS2345" \
  "a switch over the failure kinds that forgets one"

# The four negatives are four DIFFERENT files, not one file counted four times.
assert_eq "there are four negative cases" "4" \
  "$(ls -1 "$M17_PKG/typecheck/negative"/*.ts 2>/dev/null | grep -c .)"

# ---------------------------------------------------------------------------
echo "== 7. the distinction is in ONE place, so it cannot be right here and wrong elsewhere"
# ---------------------------------------------------------------------------
ERRORS_TS="$(cat "$M17_PKG/src/errors.ts")"
assert_contains "AvmTrap's discriminant is 'trap'" "readonly kind = 'trap' as const" "$ERRORS_TS"
assert_contains "…and a transaction outcome's is 'tx-outcome'" "readonly kind: 'tx-outcome'" "$ERRORS_TS"
# No failure class declares a revert code. Asserted over the class BODIES rather than over the
# file, because the file necessarily mentions `revertCode` — that is what a TxOutcome has — and a
# whole-file `grep -v` would be a claim of zero that could never fail. The same extractor is run
# over `TxOutcome`, where the count must be non-zero, as the control.
class_body() { # <name> -> the lines from `class <name>`/`interface <name>` to its closing brace
  awk -v n="$1" '
    $0 ~ ("^(export )?(class|interface) " n "([ <]|$)") { inb = 1 }
    inb { print }
    inb && /^}/ { exit }
  ' "$M17_PKG/src/errors.ts"
}
for cls in AvmTrap AvmHostError AvmInstancePoisoned; do
  BODY="$(class_body "$cls")"
  assert_ge "$cls's declaration was found to inspect" 3 "$(printf '%s\n' "$BODY" | grep -c .)"
  assert_eq "$cls declares no revert code" "0" "$(printf '%s\n' "$BODY" | grep -c 'revertCode')"
done
OUTCOME_BODY="$(class_body TxOutcome)"
assert_ge "TxOutcome's declaration was found to inspect" 3 "$(printf '%s\n' "$OUTCOME_BODY" | grep -c .)"
assert_ge "…and the same extractor finds a revert code where there IS one" 1 \
  "$(printf '%s\n' "$OUTCOME_BODY" | grep -c 'revertCode')"
REACTOR_TS="$(cat "$M17_PKG/src/reactor.ts")"
assert_contains "every export call goes through one guarded boundary" \
  "callGuarded(exportName: string, call: () => number)" "$REACTOR_TS"
assert_contains "…which poisons the instance on a trap" "throw this.poison(exportName, e)" "$REACTOR_TS"
# `guarded()`'s C++ half says the same thing, and it is read out of the fork rather than quoted.
assert_true "REACTOR-ABI.md records that a revert is not an error on the C++ side either" \
  grep -q 'A revert is not an error' "$M17_REACTOR_ABI"

finish
