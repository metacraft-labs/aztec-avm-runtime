#!/usr/bin/env bash
# e2e_form_b_local_tx_roundtrip — M21.
#
# WHAT THIS COVERS, AND WHAT IT DOES NOT, stated first because the milestone's wording is wider than
# what is built and a check must not read as if it covered the difference.
#
# §5.4's Form B is four steps:
#
#   1. execute the private functions with `WASMSimulator`   -> `PrivateExecutionResult`
#   2. `generateSimulatedProvingResult(...)`                -> `PrivateKernelTailCircuitPublicInputs`
#   3. `new PrivateSimulationResult(...).toSimulatedTx()`   -> a real `Tx`
#   4. wrap as `{ tx, provenance: { kind: 'local', privateExecution } }`
#
# THIS CHECK COVERS 3 AND 4 AND THE HANDOFF INTO THE PUBLIC PATH, EXECUTED. It does NOT cover 1 or
# 2, and the reason is a dependency fact rather than a difficulty: `WASMSimulator` is in
# `@aztec/simulator/client` and `generateSimulatedProvingResult` in `@aztec/pxe`, and both packages
# hard-depend — transitively for `@aztec/pxe`, directly for `@aztec/simulator` — on `@aztec/native`
# and `@aztec/world-state`, which DD-9 forbids in the shipped tree. That is OQ-2's real answer and
# `verify_oq2_pxe_embedding_decision_recorded` measures it live; RI-64/RI-65 record the vendoring
# route and its cost. The milestone status is `partially_completed` for exactly this.
#
# WHAT MAKES 3 AND 4 WORTH EXECUTING RATHER THAN ASSUMING. The tail this check feeds in comes from
# upstream's own `mockTx`, so the `Tx` step 3 builds can be compared against the `Tx` upstream built
# from the same tail — and it is compared BY TX HASH and by the serialized kernel data, not by
# "it returned a Tx". If `toSimulatedTx` were reimplemented rather than called, that equality is the
# thing that would break.
#
# AND THE HANDOFF IS THE DELIVERABLE'S OWN SENTENCE. "Form B is a producer of `Tx`, not a fork of
# the execution path." So what step 4 produces is handed to `executeExternallySettledTx` — M20's
# function, unchanged, provenance-blind — and the outcome that comes back is M20's `processed` /
# `failed`, the chain's own words. There is no second execution entry point and no second outcome
# vocabulary, and both are asserted.

set -uo pipefail
TEST_NAME="e2e_form_b_local_tx_roundtrip"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m21_form_b.sh"

echo "== $TEST_NAME"
m21_prepare

PROBE="$(m21_imports)
$(cat <<'EOS'

import { PrivateCircuitPublicInputs } from '@aztec/stdlib/kernel';
import { Fr } from '@aztec/foundation/curves/bn254';
import { mockTx } from '@aztec/stdlib/testing';

const line = (k, v) => console.log(`${k} ${v}`);

// UPSTREAM'S OWN TRANSACTION IS THE REFERENCE. `mockTx` builds a `Tx` whose `data` is a real
// `PrivateKernelTailCircuitPublicInputs` — the exact type step 2 produces — so step 3 can be run
// against a tail nobody here invented, and its output compared with upstream's.
//
// SEED 1001 AND NOT 11. M20 measured that `mockTx(seed)` derives its private nullifiers as
// `seed + 1` and `seed + 2`, and that every value up to at least 102 is already in the resident
// nullifier tree's genesis prefill; seeds under about a hundred therefore collide by accident and a
// suite built on them reports the right verdicts for the wrong reason.
const reference = await mockTx(1001);
line('reference.dataType', reference.data.constructor.name);
line('reference.hash', (await reference.getTxHash()).toString());

// The public-only private execution, in upstream's own shape — `wallet-sdk`'s `simulatePublicOnly`
// builds exactly this. The first nullifier is a CONSTANT and not `Fr.random()`, which is the one
// place this deliberately departs from wallet-sdk: DD-4 makes this runtime deterministic, and a
// transaction whose nonce generator is random cannot be compared byte for byte against anything.
const privateResult = publicOnlyPrivateExecution(PrivateCircuitPublicInputs.empty(), new Fr(7n), []);
line('private.entrypointIsEmpty', privateResult.entrypoint.acir.length === 0 ? 1 : 0);
line('private.publicCalldata', privateResult.publicFunctionCalldata.length);

// ---- STEP 3 ---------------------------------------------------------------
const built = await txFromTail(privateResult, reference.data);
line('built.type', built.constructor.name);
line('built.hash', (await built.getTxHash()).toString());
line('built.dataEqualsReference',
  Buffer.from(built.data.toBuffer()).equals(Buffer.from(reference.data.toBuffer())) ? 1 : 0);
line('built.hashEqualsReference',
  (await built.getTxHash()).toString() === (await reference.getTxHash()).toString() ? 1 : 0);

// THE CONTROL FOR THAT EQUALITY. A DIFFERENT tail must produce a DIFFERENT transaction, or
// "matches upstream" would be true of a function that ignored its argument.
const other = await mockTx(2002);
const builtOther = await txFromTail(privateResult, other.data);
line('control.otherHashDiffers',
  (await builtOther.getTxHash()).toString() !== (await built.getTxHash()).toString() ? 1 : 0);
line('control.otherMatchesItsOwnReference',
  (await builtOther.getTxHash()).toString() === (await other.getTxHash()).toString() ? 1 : 0);

// ---- STEP 4 ---------------------------------------------------------------
const submitted = await originateLocalTx(privateResult, reference.data, PRIVATE_SIMULATORS.none);
line('provenance.kind', submitted.provenance.kind);
line('provenance.hasPrivateExecution', submitted.provenance.privateExecution === undefined ? 0 : 1);
line('provenance.simulator', submitted.provenance.privateExecution.simulator);
line('provenance.nestedCalls', submitted.provenance.privateExecution.nestedCalls);
line('provenance.publicCalls', submitted.provenance.privateExecution.publicCalls);
line('provenance.contract', submitted.provenance.privateExecution.contract);
line('provenance.hasTrace', submitted.provenance.privateTrace === undefined ? 0 : 1);
line('provenance.txIsTheBuiltOne',
  (await submitted.tx.getTxHash()).toString() === (await built.getTxHash()).toString() ? 1 : 0);

// …and with a trace handle, which M26 consumes.
const traced = await originateLocalTx(privateResult, reference.data, PRIVATE_SIMULATORS.wasm,
  { id: 'trace-42' });
line('traced.simulator', traced.provenance.privateExecution.simulator);
line('traced.traceId', traced.provenance.privateTrace?.id ?? 'none');

// THE CONTROL ON STEP 4. M20's discriminant-only local constructor must NOT carry a private
// execution, or "the producer cannot forget it" would be true of a type that has it by default.
const discriminantOnly = locallyOriginatedTx(built);
line('control.discriminantOnlyKind', discriminantOnly.provenance.kind);
line('control.discriminantOnlyHasPrivateExecution',
  discriminantOnly.provenance.privateExecution === undefined ? 0 : 1);
line('control.externalHasPrivateExecution',
  externalTx(built).provenance.privateExecution === undefined ? 0 : 1);

// ---- THE HANDOFF: ONE EXECUTION WINDOW, ONE OUTCOME VOCABULARY ------------
// A recording simulator rather than the wasm module: this check is about the SEAM. The module arm
// is M20's, already measured over seven arms twice each, and re-running it here would be a second
// place for one number to live.
const seen = [];
const recordingSimulator = {
  rawRevertCode: 3,
  async simulate(tx) {
    seen.push((await tx.getTxHash()).toString());
    return { revertCode: { getCode: () => 1 }, gasUsed: {}, transactionFee: 0n };
  },
};
const outcome = await executeExternallySettledTx(submitted, recordingSimulator);
line('handoff.kind', outcome.kind);
line('handoff.rawRevertCode', outcome.revertCode);
line('handoff.revertedIn', outcome.revertedIn);
line('handoff.upstreamCollapsed', outcome.result.revertCode.getCode());
line('handoff.simulatorSawOurTx',
  seen.length === 1 && seen[0] === (await built.getTxHash()).toString() ? 1 : 0);

// The SAME function on an EXTERNAL transaction returns the same shape, which is what "not a fork of
// the execution path" means when it is executed rather than asserted.
const externalOutcome = await executeExternallySettledTx(externalTx(built), recordingSimulator);
line('handoff.externalKind', externalOutcome.kind);
line('handoff.externalRawRevertCode', externalOutcome.revertCode);
line('handoff.sameShape',
  Object.keys(outcome).sort().join(',') === Object.keys(externalOutcome).sort().join(',') ? 1 : 0);

// AND THE PROVENANCE WAS NOT CONSULTED. DD-1 holds for Form B's provenance too, and its `local`
// arm now carries fields a branch could read — which is precisely why this is asserted here and not
// only in M20's suite, where the local arm had nothing on it to read.
const reads = provenanceReadsDuring(submitted, (sealed) => { void sealed.tx; });
line('dd1.readsDuringExecution', reads.length);

line('formB.done', 1);
EOS
)"

# `provenanceReadsDuring` is not in the shared import prologue — it is M20's and only this check
# uses it — so it is appended rather than added to `m21_imports`, where an unused import in five
# other probes would be five chances for a rename to go unnoticed.
PROBE="import { provenanceReadsDuring } from '$M21_SRC/index.ts';
$PROBE"

OUT="$M21_WORK/probes/roundtrip.out"
m21_probe roundtrip "$PROBE" >"$OUT"
RC=$?
assert_eq "the Form B roundtrip probe exited 0" "0" "$RC"
[ "$RC" -eq 0 ] || die "the roundtrip probe exited $RC. Its stderr, which is where the reason is:
$(head -15 "$(m21_probe_err roundtrip)")"
require_complete_transcript "$OUT" formB.done "the Form B roundtrip probe's"
assert_eq "…and its transcript is complete rather than truncated" "complete" \
  "$(transcript_completeness "$OUT" formB.done)"

f() { m21_field "$OUT" "$1"; }

echo "== 1. the reference is upstream's own transaction, at a seed that does not collide"
assert_eq "mockTx's data is the type step 2 produces" "PrivateKernelTailCircuitPublicInputs" \
  "$(f reference.dataType)"
assert_prefix "…and it has a transaction hash" "0x" "$(f reference.hash)"

echo "== 2. the private execution is upstream's public-only shape"
assert_eq "the entrypoint carries no ACIR, which is what 'no private execution' means" "1" \
  "$(f private.entrypointIsEmpty)"
assert_eq "…and no public calldata, so the tail is the only input to step 3" "0" \
  "$(f private.publicCalldata)"

echo "== 3. STEP 3: the Tx this runtime builds IS the one upstream builds"
assert_eq "txFromTail returns a real Tx" "Tx" "$(f built.type)"
assert_eq "…whose kernel data is byte-identical to the reference's" "1" \
  "$(f built.dataEqualsReference)"
assert_eq "…and whose TRANSACTION HASH equals the reference's" "1" "$(f built.hashEqualsReference)"
assert_eq "…and the two hashes are the same string, printed" "$(f reference.hash)" "$(f built.hash)"
assert_eq "THE CONTROL: a different tail gives a different transaction" "1" \
  "$(f control.otherHashDiffers)"
assert_eq "…and that one matches ITS reference, so the equality is a property and not a constant" \
  "1" "$(f control.otherMatchesItsOwnReference)"

echo "== 4. STEP 4: the provenance says what ran"
assert_eq "the transaction is locally originated" "local" "$(f provenance.kind)"
assert_eq "…and carries a private-execution summary" "1" "$(f provenance.hasPrivateExecution)"
assert_eq "…naming the simulator, which for a public-only transaction is 'none' and not a guess" \
  "none" "$(f provenance.simulator)"
assert_eq "…with the nested private calls counted by walking" "0" "$(f provenance.nestedCalls)"
assert_eq "…and the enqueued public calls" "0" "$(f provenance.publicCalls)"
assert_prefix "…and the entrypoint contract, read off the execution" "0x" "$(f provenance.contract)"
assert_eq "…and no trace handle, because none was given" "0" "$(f provenance.hasTrace)"
assert_eq "…and the tx it carries is the one step 3 built" "1" "$(f provenance.txIsTheBuiltOne)"
assert_eq "with a trace handle, the simulator label follows the caller" "wasm-acvm" \
  "$(f traced.simulator)"
assert_eq "…and M26's handle is carried through" "trace-42" "$(f traced.traceId)"
assert_eq "THE CONTROL: M20's discriminant-only constructor is still 'local'" "local" \
  "$(f control.discriminantOnlyKind)"
assert_eq "…and carries NO private execution, so the field is not there by default" "0" \
  "$(f control.discriminantOnlyHasPrivateExecution)"
assert_eq "…and neither does an external transaction" "0" "$(f control.externalHasPrivateExecution)"

echo "== 5. the handoff: ONE execution window and ONE outcome vocabulary"
assert_eq "the locally-originated transaction is PROCESSED, the chain's own word" "processed" \
  "$(f handoff.kind)"
assert_eq "…and the simulator was handed exactly our transaction" "1" \
  "$(f handoff.simulatorSawOurTx)"
assert_eq "an EXTERNAL transaction through the same function reports the same kind" "processed" \
  "$(f handoff.externalKind)"
assert_eq "…and the same outcome shape, which is what 'not a fork' means when it is executed" "1" \
  "$(f handoff.sameShape)"

echo "== 6. D18: the RAW four-valued revert code survives Form B"
assert_eq "the outcome reports the module's own four-valued code" "3" "$(f handoff.rawRevertCode)"
assert_eq "…named, so a consumer can tell WHICH phase reverted" "both" "$(f handoff.revertedIn)"
assert_eq "…while upstream's collapsed code reads 1, which cannot" "1" \
  "$(f handoff.upstreamCollapsed)"
assert_eq "…and the external arm reports the same raw code, so Form B does not re-collapse it" "3" \
  "$(f handoff.externalRawRevertCode)"

echo "== 7. DD-1 still holds, and now there is something on 'local' to read"
assert_eq "nothing observed the provenance during the execution window" "0" \
  "$(f dd1.readsDuringExecution)"

finish
