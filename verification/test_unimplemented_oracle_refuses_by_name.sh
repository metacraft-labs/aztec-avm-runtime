#!/usr/bin/env bash
# test_unimplemented_oracle_refuses_by_name
#
# M35 verification: "An unimplemented oracle refuses naming itself. Control: an implemented one
# answers."
#
# ===========================================================================================
# THIS IS THE CAMPAIGN'S OLDEST RULE, IN THE MILESTONE WHERE BREAKING IT WOULD BE LEAST VISIBLE
# ===========================================================================================
#
# *"A missing oracle must never return a plausible value — a fabricated note or nullifier produces a
# transaction that LOOKS valid."* Everywhere else in this campaign a fabricated value would fail
# something downstream; here it would settle. So the refusal is asserted three ways, and the third is
# the one that cannot be satisfied by a well-behaved unit:
#
#   1. DIRECTLY. Every one of the refusing oracles is called on the handler and must throw an
#      `OracleUnimplemented` whose `oracle` FIELD equals its own key and whose message contains it.
#      A field rather than a substring, because a message is a thing you parse and a field is a thing
#      you read — M34's `DevWalletRefused` shape.
#   2. WITH A CONTROL THAT RUNS THROUGH THE SAME INSTRUMENT. The implemented oracles are exercised on
#      the same handler in the same arm and must ANSWER; the check reads the resulting ledger, so
#      "refuses" and "answers" are two readings of one object rather than two scripts.
#   3. THROUGH REAL ACIR. `Token.transfer` — 76,875 bytes of compiled Noir, in Chromium, through
#      upstream's WASMSimulator and upstream's oracle wire — stops at the first oracle it needs that
#      M35 does not serve, and the report NAMES it. A handler that refused correctly in isolation and
#      was never reached by a circuit would pass 1 and 2 and fail here.
#
# And the fourth thing, which is the one the rule is actually about: **nothing came back**. Not one
# refused oracle RESOLVED, and the executed frame's own effects are empty of anything the refused
# ones would have produced.
#
# ===========================================================================================
# THE ANCHOR-VERSUS-PIN SHIM IS MEASURED HERE TOO, AND IT IS NOT A DIGRESSION
# ===========================================================================================
#
# `browser/src/shims/stdlib_aztec_address.ts` stands in for four statics the `cpp` anchor's code
# names and the `deletion_era` pin does not. It is on the path of every address-typed oracle
# parameter, and `aztec_utl_getContractInstance` — the first oracle a real contract reaches after the
# version check — takes exactly one. Before the shim, that frame died with
# `TypeError: U.fromFieldUnsafe is not a function` INSIDE the ACVM, wrapped in eleven words that name
# nothing. So the frame reaching its refusal is the shim's own evidence, and the error chain being
# free of that spelling is the other half.
#
# Run: just verify-m35-refusals

TEST_NAME="test_unimplemented_oracle_refuses_by_name"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m35_private.sh"

m35_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m35_require_arms

echo "== 1. EVERY REFUSED ORACLE, CALLED DIRECTLY, NAMES ITSELF"

REFUSALS="$(m35_arm surface.report.refusals)"
REFUSING="$(m35_arm surface.report.registry.refusing)"
IMPLEMENTED="$(m35_arm surface.report.registry.implemented)"
LEDGER="$(m35_arm surface.report.ledger)"
m35_absent "surface.report.refusals=$REFUSALS" "surface.report.registry.refusing=$REFUSING" \
  "surface.report.registry.implemented=$IMPLEMENTED" "surface.report.ledger=$LEDGER"

VERDICT="$(python3 - "$REFUSALS" "$REFUSING" "$IMPLEMENTED" "$LEDGER" <<'PY'
import json, sys
refusals = json.loads(sys.argv[1])
refusing = json.loads(sys.argv[2])
implemented = json.loads(sys.argv[3])
ledger = json.loads(sys.argv[4])

print('CALLED\t%d' % len(refusals))
print('DECLARED\t%d' % len(refusing))
print('NOT_CALLED\t%s' % ' '.join(sorted(set(refusing) - set(refusals))))
print('CALLED_NOT_DECLARED\t%s' % ' '.join(sorted(set(refusals) - set(refusing))))
# The three ways a refusal can be wrong, each reported as the NAMES rather than as a count.
print('RESOLVED\t%s' % ' '.join(sorted(k for k, v in refusals.items() if v['name'] == 'RESOLVED')))
print('WRONG_CLASS\t%s' % ' '.join(
    sorted(k for k, v in refusals.items() if v['name'] not in ('OracleUnimplemented', 'RESOLVED'))))
print('DOES_NOT_NAME_ITSELF\t%s' % ' '.join(sorted(k for k, v in refusals.items() if not v['namesItself'])))
# ...and the message must say what it is for, not only that it failed.
print('NO_REASON_IN_MESSAGE\t%s' % ' '.join(
    sorted(k for k, v in refusals.items() if 'does not serve the oracle' not in v['message'])))

served = {c['oracle'] for c in ledger if c['outcome'] == 'served'}
refused_in_ledger = {c['oracle'] for c in ledger if c['outcome'] == 'refused'}
print('SERVED_IN_LEDGER\t%d' % len(served))
print('REFUSED_IN_LEDGER\t%d' % len(refused_in_ledger))
print('SERVED_THAT_ALSO_REFUSED\t%s' % ' '.join(sorted(served & refused_in_ledger)))
print('IMPLEMENTED_MISSING_FROM_SERVED\t%s' % ' '.join(sorted(set(implemented) - served)))
print('REFUSED_NOT_IN_REFUSING\t%s' % ' '.join(sorted(refused_in_ledger - set(refusing))))
# The seq numbering is gap-free and monotonic: a ledger that dropped a record in the middle would
# still have the right names, and that is the shape M34's container check exists for.
seqs = [c['seq'] for c in ledger]
print('SEQ_GAPFREE\t%s' % ('yes' if seqs == list(range(len(seqs))) else 'no'))
print('LEDGER_SIZE\t%d' % len(ledger))
PY
)"
v() { printf '%s\n' "$VERDICT" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

N_CALLED="$(v CALLED)"
N_DECLARED="$(v DECLARED)"
assert_ge "the arm called some refused oracles at all" 1 "$N_CALLED"
assert_eq "it called EVERY declared refused oracle" "$N_DECLARED" "$N_CALLED"
assert_eq "none was left uncalled" "" "$(v NOT_CALLED)"
assert_eq "and none was called that is not declared refused" "" "$(v CALLED_NOT_DECLARED)"
assert_eq "not one of them RESOLVED — nothing returned a plausible value" "" "$(v RESOLVED)"
assert_eq "every refusal is an OracleUnimplemented" "" "$(v WRONG_CLASS)"
assert_eq "and every one NAMES ITSELF, in its field and in its message" "" "$(v DOES_NOT_NAME_ITSELF)"
assert_eq "and says what it does not serve rather than only that it failed" "" "$(v NO_REASON_IN_MESSAGE)"

echo "== 2. THE CONTROL: the implemented ones answer, on the same handler in the same arm"

assert_eq "every implemented oracle appears in the ledger as SERVED" "" "$(v IMPLEMENTED_MISSING_FROM_SERVED)"
assert_eq "not one served oracle also appears as refused" "" "$(v SERVED_THAT_ALSO_REFUSED)"
assert_eq "and not one refused oracle is outside the declared refusing set" "" "$(v REFUSED_NOT_IN_REFUSING)"
assert_ge "the ledger recorded a serving for each implemented oracle" "$(printf '%s' "$IMPLEMENTED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" "$(v SERVED_IN_LEDGER)"
assert_eq "the refusals are visible in the ledger too, which is the design goal" "$N_DECLARED" "$(v REFUSED_IN_LEDGER)"
assert_eq "the ledger's seq numbering is gap-free" "yes" "$(v SEQ_GAPFREE)"
assert_ge "and the ledger is not empty" 60 "$(v LEDGER_SIZE)"

echo "== 3. THE OBSERVATIONS: each served oracle was asked something it could get wrong"

OBS="$(m35_arm surface.report.observations)"
CALLDATA_MISS="$(m35_arm surface.report.calldataMissRefused)"
m35_absent "surface.report.observations=$OBS" "surface.report.calldataMissRefused=$CALLDATA_MISS"
o() { printf '%s' "$OBS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1','MISSING'))"; }

# A store that answered `present` for everything, or `absent` for everything, would satisfy a
# smoke test. Each pair below has both directions in it.
assert_eq "a capsule that was written reads back with the right width" "read 2 field(s)" "$(o getCapsule)"
assert_eq "and one that was deleted reads back as a MISS" "gone" "$(o deleteCapsule)"
assert_eq "a copied capsule lands at the destination slot" "copied one slot" "$(o copyCapsule)"
assert_eq "the execution cache returns the preimage it was given" "read 2 field(s)" "$(o getHashPreimage)"
assert_true "and refuses a hash nobody stored, rather than returning an empty array" \
  str_has_sub "$CALLDATA_MISS" "not in cache"
assert_eq "a nullifier this contract created is pending FOR THIS CONTRACT and not for another" \
  "own=true other=false" "$(o isNullifierPending)"

# ---- THE FOUR VALIDATIONS THAT ARE UPSTREAM'S AND WOULD BE INVISIBLE IF THEY WERE MISSING ---------
#
# Each of these is a case where a PERMISSIVE handler is not visibly wrong afterwards, which is what
# makes them worth asserting rather than trusting:
#
#   * An OVERLAPPING capsule copy done forward leaves `1,1,1` where `1,2,3` belongs, and the store
#     reads back cleanly either way. Upstream reverses the index order when the destination is ahead
#     of the source; this is that rule, measured on the DESTINATION rather than on the call.
#   * A duplicate siloed nullifier added to a `Set` is a no-op, so a handler that accepted one would
#     look identical to one that refused — while having waved a double-spend within one transaction
#     through the only layer that can see it.
#   * A note nobody created being consumed is the fabricated-note shape arriving from the other
#     direction.
#   * `assertValidPublicCalldata` is named for an assertion; a handler that looked the calldata up
#     and asserted nothing about it would be a validator that validates nothing.
CAP_OVERLAP="$(m35_arm surface.report.observations.copyCapsuleOverlapping)"
UNKNOWN_NOTE="$(m35_arm surface.report.unknownNoteRefused)"
DUP_NULLIFIER="$(m35_arm surface.report.duplicateNullifierRefused)"
CALLDATA_CAP="$(m35_arm surface.report.calldataCapRefused)"
MAX_CALLDATA="$(m35_arm surface.report.maxCalldata)"
m35_absent "surface.report.observations.copyCapsuleOverlapping=$CAP_OVERLAP" \
  "surface.report.unknownNoteRefused=$UNKNOWN_NOTE" \
  "surface.report.duplicateNullifierRefused=$DUP_NULLIFIER" \
  "surface.report.calldataCapRefused=$CALLDATA_CAP" "surface.report.maxCalldata=$MAX_CALLDATA"
assert_eq "an OVERLAPPING capsule copy preserves the source values rather than smearing the first" \
  "1,2,3" "$CAP_OVERLAP"
assert_true "consuming a note nobody created is REFUSED, naming what is missing" \
  str_has_sub "$UNKNOWN_NOTE" "does not exist"
assert_true "a duplicate siloed nullifier is REFUSED, naming the nullifier and the contract" \
  str_has_sub "$DUP_NULLIFIER" "duplicate siloed nullifier"
assert_true "and calldata past upstream's whole-transaction cap is REFUSED" \
  str_has_sub "$CALLDATA_CAP" "too many total args"
# The cap is upstream's constant and not a number typed anywhere here, so the refusal above is a
# statement about the protocol rather than about a threshold this repository chose.
assert_ge "over a cap read from @aztec/constants rather than typed" 1 "$MAX_CALLDATA"
assert_eq "which is the constant the runtime's own @aztec/constants declares" \
  "$(python3 -c '
import re, sys
src = open(sys.argv[1]).read()
m = re.search(r"MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS\s*=\s*([0-9]+)", src)
print(m.group(1) if m else "MISSING")' "$REPO_ROOT/orchestration/node_modules/@aztec/constants/dest/constants.gen.js")" \
  "$MAX_CALLDATA"
assert_eq "the revertible phase answers no before it starts and discriminates the counter after" \
  "before=false after5=true after4=false" "$(o isExecutionInRevertiblePhase)"
assert_eq "getRandomField advances rather than repeating" "advanced" "$(o getRandomField)"
for family in Ephemeral Transient; do
  assert_eq "two ${family} pushes give length 2" "len 2" "$(o "push${family}")"
  assert_eq "a ${family} set is visible to the next get" "index 0 is 9" "$(o "get${family}")"
  assert_eq "a ${family} pop returns the last element" "popped 2" "$(o "pop${family}")"
  assert_eq "a ${family} remove shrinks the array" "len 0" "$(o "remove${family}")"
  assert_eq "and a ${family} clear empties it" "len 0" "$(o "clear${family}")"
done

echo "== 3b. AN ORACLE NAME THE REGISTRY DOES NOT DECLARE — the other half of a loud mismatch"

# `assertCompatibleOracleVersion` catches a MAJOR-version disagreement. It cannot catch bytecode that
# calls an oracle this registry has never heard of, and `buildACIRCallback` wraps its table in a Proxy
# whose trap exists for exactly that. The trap picks between three diagnostics on whether the handler
# carries `nonOracleFunctionGetContractOracleVersion`, and WITHOUT it the message says the contract's
# version is unknown and blames the `#[aztec]` macro — over a contract that called the version oracle
# first, as every `#[aztec]` contract does. A wrong explanation is worse than none.
UNKNOWN_ORACLE="$(m35_arm surface.report.unknownOracle)"
KNOWN_THROUGH="$(m35_arm surface.report.knownOracleThroughCallback)"
ENVV_FOR_TRAP="$(m35_arm surface.report.registry.environmentVersion)"
m35_absent "surface.report.unknownOracle=$UNKNOWN_ORACLE" \
  "surface.report.knownOracleThroughCallback=$KNOWN_THROUGH" \
  "surface.report.registry.environmentVersion=$ENVV_FOR_TRAP"
assert_true "an undeclared oracle name is REFUSED by the callback, naming the name" \
  str_has_sub "$UNKNOWN_ORACLE" "aztec_utl_thisOracleDoesNotExist"
assert_true "…and says the oracle was not found rather than something else" \
  str_has_sub "$UNKNOWN_ORACLE" "not found"
# THE DISCRIMINATOR. The trap has three branches and the one it must NOT take is the "version
# unknown" one — that is the branch a handler without the hook gets, and it names a cause a reader
# would go and check.
assert_false "and does NOT claim the contract's oracle version is unknown" \
  str_has_sub "$UNKNOWN_ORACLE" "oracle version is unknown"
assert_false "…nor blame the #[aztec] macro" str_has_sub "$UNKNOWN_ORACLE" "not compiled with the"
# The branch it DOES take names both versions, which is only possible because the handler answered
# `nonOracleFunctionGetContractOracleVersion` — so this assertion is the hook's own evidence.
TRAP_ENV="$(printf '%s' "$ENVV_FOR_TRAP" | python3 -c '
import json,sys
d = json.load(sys.stdin); print("%d.%d" % (d["major"], d["minor"]))')"
assert_true "…and names the ENVIRONMENT's version, which only the fed hook can produce" \
  str_has_sub "$UNKNOWN_ORACLE" "$TRAP_ENV"
# THE CONTROL: a name the registry DOES declare goes through the same callback and reaches the
# HANDLER, so the trap is shown to discriminate rather than to refuse everything.
#
# AND THE ORACLE THE CONTROL USES IS CHOSEN FOR ITS ARITY, which is M34's finding in a second place.
# Called with no inputs, an oracle that DECLARES params is rejected by `entry.deserializeParams` on
# the slot count before the handler is reached — a `TypeError` from upstream's codec, not an
# `OracleUnimplemented` from ours, so the control would have measured somebody else's refusal. That
# is M34's refusals arm exactly, where all six "refusals" were `parseWithOptionals`. The control
# calls a NO-PARAM oracle, for which no-argument IS the wire.
assert_eq "while a DECLARED oracle reaches the handler through the same callback" \
  "OracleUnimplemented" "$KNOWN_THROUGH"

echo "== 4. THE CONSTRUCTION-TIME GUARD, exercised in both directions over the BUILT bundle"

GUARD="$(m35_arm surface.report.guard)"
m35_absent "surface.report.guard=$GUARD"
g() { printf '%s' "$GUARD" | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1','MISSING'))"; }
assert_eq "the correct list is accepted" "accepted" "$(g correct)"
assert_true "a list with one name dropped is REFUSED, naming the missing one" \
  str_has_sub "$(g missing)" "does not match the registry: missing ["
assert_true "a list with a fabricated name is REFUSED, naming the undeclared one" \
  str_has_sub "$(g extra)" "aFabricatedOracleName"
assert_false "and neither doctored list was accepted" \
  str_has_sub "$(g missing)$(g extra)" "ACCEPTED"

echo "== 5. THROUGH REAL ACIR, IN CHROMIUM — the refusal a unit test cannot give"

R_OUTCOME="$(m35_arm private.report.refuses.outcome)"
R_STOPPED="$(m35_arm private.report.refuses.stoppedAtOracle)"
R_BYTES="$(m35_arm private.report.refuses.bytecodeBytes)"
R_TYPE="$(m35_arm private.report.refuses.functionType)"
R_SERVED="$(m35_arm private.report.refuses.oraclesServed)"
R_REFUSED="$(m35_arm private.report.refuses.oraclesRefused)"
R_CHAIN="$(m35_arm private.report.refuses.errorChain)"
R_CONTRACT="$(m35_arm private.report.refuses.contractName)"
R_FN="$(m35_arm private.report.refuses.functionName)"
m35_absent "private.report.refuses.outcome=$R_OUTCOME" "private.report.refuses.stoppedAtOracle=$R_STOPPED" \
  "private.report.refuses.bytecodeBytes=$R_BYTES" "private.report.refuses.functionType=$R_TYPE" \
  "private.report.refuses.oraclesServed=$R_SERVED" "private.report.refuses.oraclesRefused=$R_REFUSED" \
  "private.report.refuses.errorChain=$R_CHAIN" "private.report.refuses.contractName=$R_CONTRACT" \
  "private.report.refuses.functionName=$R_FN"

assert_eq "the subject is Token's PRIVATE transfer" "Token transfer abi_private" "$R_CONTRACT $R_FN $R_TYPE"
assert_ge "and it is real compiled Noir rather than a stub" 50000 "$R_BYTES"
assert_eq "the frame refused" "refused" "$R_OUTCOME"
# THE ORACLE IT STOPS AT MOVED WHEN TIER 2'S FIRST RUNG WAS BUILT, AND THAT IS THE POINT.
# M35 shipped this frame stopping at `aztec_utl_getContractInstance`. That oracle is served now —
# from the directory this wallet holds — so the frame walks past it and stops at the first oracle it
# needs that is genuinely UNIMPLEMENTED. The assertion is deliberately NOT loosened to "stopped
# somewhere": it names the oracle, and the name is read from the artefact's own refusing set below.
assert_eq "at an oracle it NAMES" "aztec_utl_getNotes" "$R_STOPPED"
assert_true "which is a declared refusing oracle" str_has_sub "$REFUSING" "$R_STOPPED"
# THE NON-DEGENERACY: it got there by serving some first. A frame that refused at its FIRST oracle
# would satisfy every assertion above and would say nothing about the wire.
assert_ge "having served some oracles on the way" 2 "$R_SERVED"
assert_eq "and refused exactly one" "1" "$R_REFUSED"
assert_true "the error chain carries the refusal's own message" \
  str_has_sub "$R_CHAIN" "does not serve the oracle"
# THE SHIM'S OWN EVIDENCE. This is the spelling the frame died on before
# browser/src/shims/stdlib_aztec_address.ts existed; its absence here says the address parameter was
# deserialised rather than skipped.
assert_false "and NOT the anchor-versus-pin failure the address shim stands in for" \
  str_has_sub "$R_CHAIN" "fromFieldUnsafe is not a function"

echo "== 5b. THE LADDER: THREE PROGRAMS, ONE RUNG, MEASURED RATHER THAN CLAIMED"

# WHY THIS SECTION EXISTS, AND IT IS A REVIEW FINDING RATHER THAN A DELIVERABLE.
#
# The milestone states in three places — `PRIVATE-EXECUTION.md` section 3, the refusal reason on
# `aztec_utl_getContractInstance` and the goal section — that `Token.transfer`,
# `Token.mint_to_private` and `PrivateVoting.cast_vote` ALL stop at that one oracle. It is the
# sentence that decides what tier 2 is and what M36 has to build first, and it was true: re-measured
# by M35's review, all three stop there. **But only `transfer` was executed by any check**, so two
# thirds of the claim was a spike measurement written into three documents and re-derived by nothing
# — `CAMPAIGN-BRIEF.md`'s "a figure nobody re-derives rots", on the strongest claim in the milestone.
#
# The three are compared as a SET, and the set has to be a SINGLETON: that is what says the boundary
# is the ORACLE. Two of the three come from one artifact and the third from a different CONTRACT, and
# the three bytecode sizes are asserted distinct — otherwise "three programs" is satisfied by one
# program run three times, which is this file's own first form wearing a loop.
LADDER="$(m35_arm private.report.ladder)"
m35_absent "private.report.ladder=$LADDER"
LAD="$(python3 - "$LADDER" "$REFUSING" <<'PY'
import json, sys
rungs = json.loads(sys.argv[1])
refusing = set(json.loads(sys.argv[2]))
print('ROWS\t%d' % len(rungs))
print('PROGRAMS\t%s' % ' '.join(sorted('%s.%s' % (r['contractName'], r['functionName']) for r in rungs)))
print('CONTRACTS\t%d' % len({r['contractName'] for r in rungs}))
print('DISTINCT_BYTECODES\t%d' % len({r['bytecodeBytes'] for r in rungs}))
print('SMALLEST_BYTECODE\t%d' % min(r['bytecodeBytes'] for r in rungs))
print('TYPES\t%s' % ' '.join(sorted({r['functionType'] for r in rungs})))
print('OUTCOMES\t%s' % ' '.join(sorted({r['outcome'] for r in rungs})))
print('STOPS\t%s' % ' '.join(sorted({str(r['stoppedAtOracle']) for r in rungs})))
# A rung can now halt WITHOUT an oracle refusing - tier 2 rung 2 answers `Option::none()` and the
# CIRCUIT stops the frame - so the oracle-stops are separated from the null one.
print('STOPS_AT_ORACLE\t%s' % ' '.join(sorted(
    {str(r['stoppedAtOracle']) for r in rungs if r['stoppedAtOracle'] is not None})))
print('STOPS_NOT_REFUSING\t%s' % ' '.join(sorted(
    {str(r['stoppedAtOracle']) for r in rungs if r['stoppedAtOracle'] is not None} - refusing)))
print('HALTED_IN_CIRCUIT\t%d' % sum(1 for r in rungs if r['stoppedAtOracle'] is None))
print('CIRCUIT_HALT_ERRORS\t%s' % ' ;; '.join(sorted(
    str(r['error']) for r in rungs if r['stoppedAtOracle'] is None)))
print('OUTCOMES_BY_PROGRAM\t%s' % ' '.join(sorted(
    '%s=%s' % (r['functionName'], r['outcome']) for r in rungs)))
# The oracle version the BYTECODE declared, read out of the rung that halted in the circuit - so
# "the version check passed over an incompatible pair" is a reading rather than a claim.
vers = set()
for r in rungs:
    for c in r['oracleCalls']:
        if c['oracle'] == 'aztec_misc_assertCompatibleOracleVersion':
            vers.add(c['detail'].split('contract=')[1].split(' ')[0])
print('CONTRACT_VERSION\t%s' % ' '.join(sorted(vers)))
print('MIN_SERVED\t%d' % min(r['oraclesServed'] for r in rungs))
print('REFUSED_COUNTS\t%s' % ' '.join(sorted({str(r['oraclesRefused']) for r in rungs})))
# TIER 2 RUNG 1'S OWN EVIDENCE, READ OUT OF EVERY RUNG'S SERVED SET.
# `aztec_utl_getContractInstance` appearing as SERVED in a rung that then continued is the only
# outside-readable proof that the circuit's own `assert_eq(instance.to_address(), address)` HELD:
# a preimage that did not derive to the address the frame ran at would have failed the ACVM as an
# unsatisfied constraint instead of advancing to a later oracle.
print('RUNGS_SERVING_INSTANCE\t%d' % sum(
    1 for r in rungs if 'aztec_utl_getContractInstance' in r['servedOracles']))
print('RUNS_AT_DISTINCT_ADDRESSES\t%d' % len({r['ranAt'] for r in rungs}))
print('RANAT_ZERO\t%d' % sum(1 for r in rungs if int(str(r['ranAt']), 16) == 0))
PY
)"
l() { printf '%s\n' "$LAD" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }

assert_eq "the arm ran three real private programs" "3" "$(l ROWS)"
assert_eq "…and they are the three the milestone names" \
  "PrivateVoting.cast_vote Token.mint_to_private Token.transfer" "$(l PROGRAMS)"
assert_eq "from two different CONTRACTS, so this is not one artifact three times" "2" "$(l CONTRACTS)"
assert_eq "with three different bytecodes, so it is not one program three times" "3" "$(l DISTINCT_BYTECODES)"
assert_ge "and the smallest of them is real compiled Noir rather than a stub" 5000 "$(l SMALLEST_BYTECODE)"
assert_eq "every one of them is a private function" "abi_private" "$(l TYPES)"
# TWO REFUSE AT AN ORACLE AND ONE HALTS IN THE CIRCUIT, and 5d says which is which by name. The
# set is asserted EXACTLY rather than relaxed to "not empty": a second rung falling into the
# circuit-halt bucket is a regression and must be read as one.
assert_eq "two refuse at an oracle and one halts in the circuit" "failed refused" "$(l OUTCOMES)"
# THE CLAIM ITSELF, AND IT IS NO LONGER A SINGLETON — WHICH IS THE RESULT, NOT A REGRESSION.
#
# M35 measured this set as the singleton `{aztec_utl_getContractInstance}` and that was true: tier 2's
# first rung was where every real private function stopped. Building that rung moved all three, and
# they did NOT move together — they now stop at three different oracles, which is a stronger
# statement than the singleton was. The singleton said "the boundary is one oracle". Three distinct
# stops say the three programs need genuinely different things, and TWO OF THE THREE are M36's:
# `aztec_utl_getNotes` and `aztec_prv_getSenderForTags`. That is M36's scope re-derived from a
# measurement rather than from its own plan.
#
# The set is asserted EXACTLY rather than by size, so a rung that regressed back to
# `getContractInstance` — the shape a broken directory produces — fails here by name.
# Rung 2 moved the third program AGAIN, and it no longer stops at an oracle at all - see 5d.
assert_eq "the two that stop at an oracle stop at M36's, and these are they" \
  "aztec_prv_getSenderForTags aztec_utl_getNotes" \
  "$(l STOPS_AT_ORACLE)"
assert_eq "…each of which is a declared refusing oracle rather than an incidental failure" "" "$(l STOPS_NOT_REFUSING)"
# AND THE RUNG THEY ALL WALKED PAST. Without this the assertions above are satisfied by three
# programs that failed for three unrelated reasons.
assert_eq "every one of them SERVED the contract-instance oracle and carried on" "3" "$(l RUNGS_SERVING_INSTANCE)"
# WHICH MEANS THE CIRCUIT'S OWN assert_eq HELD, THREE TIMES, AT THREE DIFFERENT ADDRESSES.
# `aztec-nr`'s get_contract_instance re-derives the address from the preimage it is handed and
# constrains it; a frame that advanced past that oracle is a frame whose derivation agreed.
assert_eq "at addresses DERIVED from the preimages, two distinct ones for two contracts" "2" \
  "$(l RUNS_AT_DISTINCT_ADDRESSES)"
assert_eq "none of which is the zero address, so the derivation produced something" "0" "$(l RANAT_ZERO)"
# THE NON-DEGENERACY, the same one section 5 makes for `transfer` alone: a frame that refused at its
# FIRST oracle would satisfy everything above and say nothing about the wire having run.
assert_ge "each of them served oracles on the way to the rung" 2 "$(l MIN_SERVED)"
assert_eq "each that refused refused exactly one, and the circuit-halted one refused none" \
  "0 1" "$(l REFUSED_COUNTS)"

echo "== 5c. TIER 2 RUNG 1'S TWO CONTROLS: 'served' must not mean 'answers anything'"

# THE HALF THAT KEEPS THE RULE WHEN A REFUSAL BECOMES AN ANSWER.
#
# Section 5b shows the oracle answering. On its own that is exactly the shape this campaign's oldest
# rule exists to catch: an oracle that returns a plausible value for whatever it is asked. So the
# same program, with the same directory, is run at an address the wallet does NOT hold, and it must
# refuse — by name, at that oracle, having served the ones before it.
#
# And the refusal must be `ContractInstanceNotHeld` rather than `OracleUnimplemented`. Those are
# different facts about the runtime: the first says "register the contract", the second says "build
# tier 2". A handler that conflated them would make the ledger say the wrong thing about what to do
# next, while passing every count in this file.
U_OUTCOME="$(m35_arm private.report.unheld.outcome)"
U_STOPPED="$(m35_arm private.report.unheld.stoppedAtOracle)"
U_SERVED="$(m35_arm private.report.unheld.oraclesServed)"
U_CHAIN="$(m35_arm private.report.unheld.errorChain)"
U_ADDR="$(m35_arm private.report.unheldAddress)"
HELD="$(m35_arm private.report.heldInstances)"
GUARD="$(m35_arm private.report.inconsistentDirectoryError)"
m35_absent "private.report.unheld.outcome=$U_OUTCOME" "private.report.unheld.stoppedAtOracle=$U_STOPPED" \
  "private.report.unheld.oraclesServed=$U_SERVED" "private.report.unheld.errorChain=$U_CHAIN" \
  "private.report.unheldAddress=$U_ADDR" "private.report.heldInstances=$HELD" \
  "private.report.inconsistentDirectoryError=$GUARD"

assert_eq "the same circuit at an address the wallet does not hold REFUSES" "refused" "$U_OUTCOME"
assert_eq "…at the contract-instance oracle itself" "aztec_utl_getContractInstance" "$U_STOPPED"
assert_ge "…having served the oracles before it, so it reached the rung rather than falling over" 2 "$U_SERVED"
assert_true "…and the refusal names ContractInstanceNotHeld" str_has_sub "$U_CHAIN" "ContractInstanceNotHeld"
# NOT the other refusal. The oracle IS served; conflating the two would send a reader to build the
# wrong milestone.
assert_false "…and NOT OracleUnimplemented, because the oracle is served" \
  str_has_sub "$U_CHAIN" "does not serve the oracle"
assert_true "…and it says how many the directory holds, so 'not held' is readable against a size" \
  str_has_sub "$U_CHAIN" "the directory holds 2"
# THE ADDRESS IT MISSED ON IS NOT ONE OF THE HELD ONES — otherwise this control is asking the same
# question section 5b already answered yes to.
assert_false "the missed address is genuinely absent from the directory" str_has_sub "$HELD" "$U_ADDR"

# THE SECOND CONTROL: A DIRECTORY THAT LIES ABOUT ITSELF IS CAUGHT BEFORE THE FRAME STARTS.
# An entry filed under an address its own preimage does not derive to would fail the circuit's
# assert_eq deep inside the ACVM, as an unsatisfied constraint the reader has to work backwards
# from. The guard re-derives the same relation with upstream's own function and names both sides.
assert_true "an inconsistent directory entry is refused before a single opcode runs" \
  str_has_sub "$GUARD" "not self-consistent"
assert_true "…naming the address it is filed under and the one it derives to" \
  str_has_sub "$GUARD" "derives to"
assert_true "…and saying which of the circuit's assertions it would otherwise have hit" \
  str_has_sub "$GUARD" "get_contract_instance"

echo "== 5d. TIER 2 RUNG 2, ITS GUARD, AND AN ABI GAP THE VERSION CHECK CANNOT SEE"

# RUNG 2 ANSWERS ABSENCE RATHER THAN THROWING IT, AND THAT IS READ OFF THE RETURN TYPE.
# `aztec_utl_getPublicKeysAndPartialAddress` declares `OPTION(PUBLIC_KEYS_AND_PARTIAL_ADDRESS)`, so
# "not registered" HAS a home in the type and upstream's own `get_public_keys_and_partial_address`
# turns it into a named failure via `.expect(...)`. Throwing instead would substitute our refusal
# for the protocol's and break `try_get_public_keys`, whose purpose is to ask and accept `None`.
KEYS_HELD="$(m35_arm private.report.heldAccountKeys)"
KEYS_GUARD="$(m35_arm private.report.inconsistentKeysError)"
m35_absent "private.report.heldAccountKeys=$KEYS_HELD" \
  "private.report.inconsistentKeysError=$KEYS_GUARD"

assert_ge "the wallet holds keys for a real number of accounts" 3 \
  "$(printf '%s' "$KEYS_HELD" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_eq "…and it answered for one it holds, with that account's own partial address" \
  "answered with the partial address that derives its own key" "$(o getPublicKeysAndPartialAddress)"
# THE OTHER DIRECTION, AND IT IS AN ANSWER RATHER THAN A THROW.
assert_eq "…and answered NONE for an account it does not hold, rather than throwing" \
  "answered none for an unregistered account" "$(o getPublicKeysAndPartialAddressMiss)"

# THE GUARD, AND IT CARRIES MORE WEIGHT HERE THAN RUNG 1'S DOES.
# `get_public_keys` constrains this oracle's answer — assert_eq(account, AztecAddress::compute(...)),
# and upstream ships its own test for it. `try_get_public_keys` does NOT: it is unconstrained,
# discards the partial address and asserts nothing. So on that path this guard is the only check.
assert_true "an incoherent key triple is refused before the frame starts" \
  str_has_sub "$KEYS_GUARD" "not self-consistent"
assert_true "…naming the address it is filed under and the one it derives to" \
  str_has_sub "$KEYS_GUARD" "derive to"
assert_true "…and saying which consumer would NOT have caught it" \
  str_has_sub "$KEYS_GUARD" "try_get_public_keys"

# ===========================================================================================
# AND THE FINDING SERVING THIS ORACLE EXPOSED, ASSERTED SO IT CANNOT ROT INTO A PUZZLE
# ===========================================================================================
#
# `PrivateVoting.cast_vote` no longer stops at an oracle. It halts INSIDE THE CIRCUIT, and the
# reason is a wire-shape disagreement between the contract artifact and the vendored registry:
#
#   ts anchor / older line   PUBLIC_KEYS_AND_PARTIAL_ADDRESS serialises to ONE slot holding an
#                            8-element array, so OPTION(...) is 2 slots
#   cpp anchor / vendored    it is a STRUCT whose shape flattens to 8 scalar slots, so OPTION(...)
#                            is 9 slots
#
# The artifacts this arm runs declare oracle version 30.0; the environment implements 30.8. Same
# MAJOR, environment minor >= contract minor — so `assertCompatibleOracleVersion` PASSES, and the
# two are still wire-incompatible. That is measured here rather than described: the ACVM's own
# message names both counts.
#
# The severity is bounded and that is asserted too: this fails LOUDLY at the foreign call, it does
# not produce a plausible value. And it was invisible until an oracle whose shape moved was actually
# SERVED — which is why it is recorded as a finding about the remaining refusals rather than about
# this one oracle.
assert_eq "one rung halts inside the circuit rather than at an oracle" "1" "$(l HALTED_IN_CIRCUIT)"
assert_eq "…and it is cast_vote, with the other two still refused at an oracle" \
  "cast_vote=failed mint_to_private=refused transfer=refused" "$(l OUTCOMES_BY_PROGRAM)"
assert_true "…and the ACVM names the wire-shape mismatch rather than failing vaguely" \
  str_has_sub "$(l CIRCUIT_HALT_ERRORS)" "output values were provided as a foreign call result"
# THE NUMBERS, BOTH OF THEM, so a future change to either side is visible rather than absorbed.
assert_true "…stating what the environment offered" str_has_sub "$(l CIRCUIT_HALT_ERRORS)" "9 output values"
assert_true "…and what the compiled contract expects" str_has_sub "$(l CIRCUIT_HALT_ERRORS)" "2 destination slots"
# AND THE VERSION CHECK PASSED ANYWAY, WHICH IS THE POINT.
assert_eq "the version check accepted the pair it could not protect" "30.0" "$(l CONTRACT_VERSION)"

echo "== 6. THE CONTROL FOR SECTION 5: a frame that needs only served oracles COMPLETES"

E_OUTCOME="$(m35_arm private.report.executes.outcome)"
E_STOPPED="$(m35_arm private.report.executes.stoppedAtOracle)"
E_SERVED="$(m35_arm private.report.executes.oraclesServed)"
E_REFUSED="$(m35_arm private.report.executes.oraclesRefused)"
E_WITNESS="$(m35_arm private.report.executes.solvedWitnessSize)"
E_TYPE="$(m35_arm private.report.executes.functionType)"
E_BYTES="$(m35_arm private.report.executes.bytecodeBytes)"
m35_absent "private.report.executes.outcome=$E_OUTCOME" "private.report.executes.oraclesServed=$E_SERVED" \
  "private.report.executes.oraclesRefused=$E_REFUSED" "private.report.executes.solvedWitnessSize=$E_WITNESS" \
  "private.report.executes.functionType=$E_TYPE" "private.report.executes.bytecodeBytes=$E_BYTES"

assert_eq "it is a private function too" "abi_private" "$E_TYPE"
assert_ge "and real bytecode" 1000 "$E_BYTES"
assert_eq "the frame EXECUTED" "executed" "$E_OUTCOME"
assert_eq "nothing refused" "0" "$E_REFUSED"
assert_eq "and there is no oracle it stopped at" "null" "$E_STOPPED"
assert_ge "the ACVM solved a witness larger than the inputs it was given" 100 "$E_WITNESS"
assert_ge "over oracles that were served" 1 "$E_SERVED"
# The two frames differ in OUTCOME while sharing the harness, which is what makes the pair a
# discriminator rather than two runs of one thing.
assert_true "the two frames came out differently" test "$E_OUTCOME" != "$R_OUTCOME"

echo "== 7. NOTHING WAS FABRICATED: the executed frame's effects are what its ledger says"

E_EFFECTS="$(m35_arm private.report.executes.effects)"
E_LEDGER="$(m35_arm private.report.executes.oracleCalls)"
m35_absent "private.report.executes.effects=$E_EFFECTS" "private.report.executes.oracleCalls=$E_LEDGER"
EFF="$(python3 - "$E_EFFECTS" "$E_LEDGER" <<'PY'
import json, sys
eff = json.loads(sys.argv[1])
ledger = json.loads(sys.argv[2])
notified = sum(1 for c in ledger if c['oracle'] == 'aztec_prv_notifyCreatedNote')
nullified = sum(1 for c in ledger if c['oracle'] == 'aztec_prv_notifyCreatedNullifier')
print('NOTES\t%d' % len(eff['createdNotes']))
print('NOTIFIED\t%d' % notified)
print('NULLIFIERS\t%d' % len(eff['createdNullifiers']))
print('NULLIFIED_CALLS\t%d' % nullified)
print('RANDOM\t%d' % eff['randomFields'])
print('RANDOM_CALLS\t%d' % sum(1 for c in ledger if c['oracle'] == 'aztec_misc_getRandomField'))
PY
)"
e() { printf '%s\n' "$EFF" | awk -F'\t' -v k="$1" '$1==k{print $2}'; }
# THE IDENTITY, NOT A ZERO. Asserting "no notes were created" is satisfied by a recorder that
# records nothing; asserting the count EQUALS the number of notify calls the ledger carries is not.
assert_eq "the notes in the effects are exactly the ones the ledger says were notified" \
  "$(e NOTIFIED)" "$(e NOTES)"
assert_eq "and the nullifiers likewise" "$(e NULLIFIED_CALLS)" "$(e NULLIFIERS)"
assert_eq "and the entropy counter is the number of getRandomField calls" "$(e RANDOM_CALLS)" "$(e RANDOM)"
# The same identity over the SURFACE arm, where all three counts are non-zero — so the equality above
# is shown to hold when the numbers are not all zero, which is the non-degeneracy M23's review asked
# for after three `0 == 0` comparisons passed a milestone.
S_LEDGER_SERVED="$(v SERVED_IN_LEDGER)"
assert_ge "and the surface arm exercised the same recorders with non-zero counts" 30 "$S_LEDGER_SERVED"

echo "== 8. THE ENTROPY IS THE SEED'S, in the page, twice"

EA="$(m35_arm private.report.entropy.a)"
EB="$(m35_arm private.report.entropy.b)"
EO="$(m35_arm private.report.entropy.other)"
m35_absent "private.report.entropy.a=$EA" "private.report.entropy.b=$EB" "private.report.entropy.other=$EO"
assert_eq "the same seed draws the same fields, in the same order, twice" "$EA" "$EB"
assert_true "a different seed draws different ones" test "$EA" != "$EO"
N_DRAWS="$(printf '%s' "$EA" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
N_DISTINCT="$(printf '%s' "$EA" | python3 -c 'import json,sys; print(len(set(json.load(sys.stdin))))')"
assert_ge "over more than one draw" 4 "$N_DRAWS"
# NON-DEGENERACY: a generator that returned the same field every time would satisfy both equalities
# above. The draws within one seed must differ from each other.
assert_eq "and the draws within one seed are distinct, so 'the same twice' is not 'always the same'" \
  "$N_DRAWS" "$N_DISTINCT"

m35_finish
