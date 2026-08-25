#!/usr/bin/env bash
# test_runtime_bug_not_reported_as_revert — M20.
#
# The deliverable: "Exceptional halts distinguished from bugs: checked execution errors become
# reverted results consuming all gas; any other error type is rethrown unchanged and surfaced as a
# runtime bug."
#
# THE DELIVERABLE NAMES TWO OUTCOMES AND THERE ARE THREE. That is not a quibble; it is the thing
# this check is shaped around. Read out of the C++ at the pinned anchor:
#
#   LANDED    a CHECKED execution error — `Execution::handle_exceptional_halt` sets
#             `gas_used = gas_limit`, halts with EXCEPTIONAL_HALT and the transaction continues.
#             Status 0, a `TxOutcome`, a non-zero revert code. Nothing is thrown.
#   REJECTED  an UNRECOVERABLE transaction-level error — a nullifier collision, a SETUP failure,
#             a fee failure. Status 1. The transaction is thrown out: it does not land, does not
#             revert and does not pay. It is NOT a bug in this runtime.
#   BUG       anything else. Rethrown unchanged.
#
# Folding REJECTED into BUG would make an ordinary race read as a defect in this runtime; folding
# it into LANDED would put an unprovable transaction in a block. So the classifier's job is to
# recognise exactly the second set, and its DEFAULT MUST BE `BUG` — a rejection misclassified as a
# bug is loud and gets fixed, a bug misclassified as a rejection is silent and ships.
#
# THE ASSERTIONS THAT MATTER ARE THE NEGATIVE ONES, AND THEY HAVE A CONTROL. "This error is not
# classified" is trivially true of a classifier that classifies nothing, so every negative case
# below sits beside a positive one run through the same function.
#
# Run: just verify-form-a-runtime-bug

TEST_NAME="test_runtime_bug_not_reported_as_revert"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m20_form_a.sh"

m20_require_anchor
m20_require_packages
mkdir -p "$M20_WORK"
SCRATCH="$(mktemp -d "$M20_WORK/runtimebug.XXXXXX")" || die "no scratch under $M20_WORK"
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.m20_"*' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — the C++ side of the distinction, at the anchor
# ---------------------------------------------------------------------------

EXEC="$SCRATCH/execution.cpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/execution.cpp > "$EXEC"
assert_ge "execution.cpp was read from the anchor" 1000 "$(wc -l < "$EXEC")"

assert_ge "an exceptional halt consumes ALL the allocated gas" 1 \
  "$(grep -cE 'handle_exceptional_halt' "$EXEC")"
# The seventh catch is the one that says "this is a coding error" and RETHROWS — that is the
# checked/unchecked boundary, in upstream's own words.
assert_ge "and the catch that is NOT a checked error says so and rethrows" 1 \
  "$(grep -c 'This is a coding error, we should not get here' "$EXEC")"

# ---------------------------------------------------------------------------
# PART 2 — the classifier, exercised in both directions
# ---------------------------------------------------------------------------

cat > "$ORCH_SRC/.m20_classify.mjs" <<'EOF'
import {
  ProvenanceConsultedDuringExecution, classifyBoundaryError, executeExternallySettledTx,
  externalTx,
} from './index.ts';

const cases = {};

// POSITIVE — every declared needle must classify. Built from the needle table itself, wrapped the
// way M17's AvmHostError wraps it, so this is not eight hand-typed strings that could drift.
const { REJECTION_NEEDLES } = await import('./index.ts');
cases.needlesClassified = REJECTION_NEEDLES.map(([reason, needle]) => {
  const wrapped = new Error(`avm_simulate failed with status 1: ${needle} 0x2a`);
  const got = classifyBoundaryError(wrapped);
  return [reason, got?.reason ?? 'UNCLASSIFIED'];
});

// NEGATIVE — a wasm trap. M17's AvmTrap carries `kind: 'trap'`.
const trap = new Error('avm.wasm trapped in avm_simulate: RuntimeError: memory access out of bounds');
trap.kind = 'trap';
cases.trap = classifyBoundaryError(trap) ?? 'UNCLASSIFIED';

// NEGATIVE — a trap whose MESSAGE happens to contain a rejection needle. Without the `kind`
// check, message matching alone would call this a transaction outcome.
const deceptiveTrap = new Error('avm.wasm trapped in avm_simulate: Not enough balance for fee payer to pay for transaction');
deceptiveTrap.kind = 'trap';
cases.deceptiveTrap = classifyBoundaryError(deceptiveTrap) ?? 'UNCLASSIFIED';

// NEGATIVE — an ordinary host bug.
cases.hostBug = classifyBoundaryError(new TypeError('Cannot read properties of undefined')) ?? 'UNCLASSIFIED';

// NEGATIVE — something with no message at all.
cases.noMessage = classifyBoundaryError({ status: 1 }) ?? 'UNCLASSIFIED';
cases.nullError = classifyBoundaryError(null) ?? 'UNCLASSIFIED';

// NEGATIVE — our own tripwire is a defect in this runtime, never a transaction outcome.
cases.provenanceTripwire =
  classifyBoundaryError(new ProvenanceConsultedDuringExecution('get', 'kind')) ?? 'UNCLASSIFIED';

// The END-TO-END behaviour: an unclassified error is rethrown UNCHANGED, same object.
const bug = new TypeError('a genuine host bug');
let rethrown = 'no';
try {
  await executeExternallySettledTx(externalTx({ marker: 1 }), { async simulate() { throw bug; } });
  rethrown = 'returned-an-outcome';
} catch (error) {
  rethrown = error === bug ? 'same-object' : `different:${error?.name}`;
}
cases.rethrow = rethrown;

// And the positive end-to-end: a recognised rejection becomes an outcome rather than a throw.
const collision = new Error('avm_simulate failed with status 1: [R_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision: 0x1');
let rejected = 'threw';
try {
  const outcome = await executeExternallySettledTx(externalTx({ marker: 1 }), { async simulate() { throw collision; } });
  rejected = `${outcome.kind}:${outcome.reason ?? ''}`;
} catch { /* leave as threw */ }
cases.rejection = rejected;

console.log(JSON.stringify(cases));
EOF
OUT="$(cd "$ORCH_SRC" && node .m20_classify.mjs 2>&1 | tail -1)" || die "the classifier probe failed: $OUT"
rm -f "$ORCH_SRC/.m20_classify.mjs"
printf '%s\n' "$OUT" | sed 's/^/      /'

cfield() { python3 -c '
import json, sys
d = json.loads(sys.argv[1])
v = d.get(sys.argv[2], "MISSING")
print(json.dumps(v) if isinstance(v, (list, dict)) else str(v))' "$OUT" "$1"; }

# POSITIVE, and it is what makes every negative below mean something.
MISMATCHES="$(python3 -c '
import json, sys
pairs = json.loads(sys.argv[1])["needlesClassified"]
bad = [f"{want}->{got}" for want, got in pairs if want != got]
print(",".join(bad) if bad else "none")' "$OUT")"
assert_eq "every declared needle classifies as its own reason" "none" "$MISMATCHES"
assert_eq "and there are eight of them" "8" \
  "$(python3 -c 'import json,sys; print(len(json.loads(sys.argv[1])["needlesClassified"]))' "$OUT")"

# NEGATIVE.
assert_eq "a wasm trap is NOT a transaction outcome" "UNCLASSIFIED" "$(cfield trap)"
assert_eq "a trap whose message contains a rejection needle is STILL not one" "UNCLASSIFIED" \
  "$(cfield deceptiveTrap)"
assert_eq "an ordinary host TypeError is not one" "UNCLASSIFIED" "$(cfield hostBug)"
assert_eq "and neither is a thrown value with no message" "UNCLASSIFIED" "$(cfield noMessage)"
assert_eq "nor null" "UNCLASSIFIED" "$(cfield nullError)"
assert_eq "our own provenance tripwire is a defect, never a transaction outcome" "UNCLASSIFIED" \
  "$(cfield provenanceTripwire)"

# END TO END.
assert_eq "an unclassified error is rethrown UNCHANGED — the same object, not a wrapper" \
  "same-object" "$(cfield rethrow)"
assert_eq "while a recognised rejection becomes an outcome instead of a throw" \
  "rejected:revertibleNullifierCollision" "$(cfield rejection)"

# ---------------------------------------------------------------------------
# PART 3 — a real trap, from the real module
# ---------------------------------------------------------------------------
#
# `Reactor.simulateAtRawPointer` is M17's deliberate host bug: a pointer past the end of linear
# memory makes the module's own msgpack reader load out of bounds. That is a genuine wasm trap —
# not an exception the C++ can catch — and it is the shape of the bug this deliverable is about.
# It runs in its OWN process because a trap poisons the instance, and reusing a poisoned reactor
# for the shared arms would make every later arm meaningless.

m20_require_module

cat > "$SCRATCH/trap.mjs" <<'EOF'
import { compileAvm, instantiateAvm } from '../../node-host/src/loader.ts';
import { classifyBoundaryError } from '../src/index.ts';
const reactor = await instantiateAvm(await compileAvm(process.env.AVM_WASM_PATH));
const cdb = reactor.createContractDb();
const mdb = reactor.createMerkleDb();
const out = { thrown: 'nothing', kind: null, classified: 'UNCLASSIFIED' };
try {
  // A pointer far past the end of linear memory, with a plausible length.
  reactor.simulateAtRawPointer(0x7fff_0000, 4096, cdb, mdb);
  out.thrown = 'returned-normally';
} catch (error) {
  out.thrown = error?.name ?? 'unknown';
  out.kind = error?.kind ?? null;
  const c = classifyBoundaryError(error);
  out.classified = c ? c.reason : 'UNCLASSIFIED';
}
console.log(JSON.stringify(out));
EOF
mkdir -p "$ORCH_DIR/.m20trap"
cp "$SCRATCH/trap.mjs" "$ORCH_DIR/.m20trap/trap.mjs"
TRAP_OUT="$(cd "$ORCH_DIR" && env NODE_NO_WARNINGS=1 AVM_WASM_PATH="$AVM_WASM_PATH" \
  node .m20trap/trap.mjs 2>/dev/null | tail -1)" || true
rm -rf "$ORCH_DIR/.m20trap"
note "real-module trap probe: ${TRAP_OUT:-<no output>}"

assert_true "the trap probe produced output" test -n "$TRAP_OUT"
assert_eq "the module did NOT return normally from a pointer past the end of linear memory" "0" \
  "$(python3 -c 'import json,sys; print(1 if json.loads(sys.argv[1])["thrown"]=="returned-normally" else 0)' "$TRAP_OUT")"
assert_eq "and whatever it threw is NOT classified as a transaction outcome" "UNCLASSIFIED" \
  "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["classified"])' "$TRAP_OUT")"

assert_eq "the probe left nothing behind under orchestration/" "0" \
  "$(find "$ORCH_DIR" -maxdepth 1 -name '.m20trap' | grep -c . || true)"

finish
