#!/usr/bin/env bash
# test_missing_contract_artifact_refused — L1 (Aztec-Live-Chain-Replay).
#
# "A transaction referencing a contract the node does not know is refused, naming the address.
#  Control: a known contract resolves. This is the check that would have caught the sibling
#  campaign's reverting demo."
#
# ─────────────────────────────────────────────────────────────────────────────
# THIS IS L1'S PRIMARY DELIVERABLE AND THE CAMPAIGN WROTE IT FOR A REASON THAT ALREADY HAPPENED.
#
# CAMPAIGN-BRIEF.md: "M29 found that M27's demo transaction reverted at its first instruction …
# Every assertion was correct and none of them asked whether the subject did what it was for." And
# the milestone's own words: "a transaction whose address had no bytecode produced one record, the
# sentinel opcode, and a well-formed container."
#
# So the property under test is not "the code has a guard". It is that the ONLY two outcomes of
# asking for a contract are (a) real bytecode, or (b) a throw naming the address — and that the
# third outcome, a well-formed artefact with nothing in it, is reachable ONLY with the guard
# explicitly disabled. §6 is where that third outcome is produced and looked at.
#
# ─────────────────────────────────────────────────────────────────────────────
# EVERY ARM IS THE REAL FIXTURE WITH ONE RECORDED ANSWER CHANGED.
#
# `replay/fixtures/testnet_settled_tx.json` is a recording of Aztec testnet transaction
# 0x2090b63c…, whose public half calls a real contract with 23,157 bytes of real bytecode. Each arm
# below takes THAT recording and replaces exactly one response — `getContract` -> null,
# `getContractClass` -> null, or the class's `packedBytecode` -> empty — so the refusal names a real
# address on a real chain rather than a fixture somebody typed. Every substitution asserts it FOUND
# ITS NEEDLE: M32's arm M2 printed its predicted result over a subject it had never touched, and
# "the arm's prediction agreeing with the arm's result is not evidence the arm ran".
#
# §5 is the arm that needs no edit at all: the capture asked the live node about an address that
# does not exist and recorded its `null`, so one refusal here is the chain's own answer.
#
# Run: just verify-l1-artifact

set -uo pipefail
TEST_NAME="test_missing_contract_artifact_refused"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l1_settled_tx.sh"

echo "== $TEST_NAME"
l1_prepare

FIXTURE="$L1_FIXTURE_DIR/testnet_settled_tx.json"

PROBE="$(l1_imports)
$(cat <<'EOS'

import { TxHash } from '@aztec/stdlib/tx/tx-hash';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';

const fixture = readFixture('testnet_settled_tx.json');
const hash = TxHash.fromString(fixture.provenance.txHash);
const known = fixture.provenance.nodeReported.contracts[0];
const knownAddress = AztecAddress.fromFieldUnsafe(Fr.fromHexString(known.address));

const resolveWith = (fx, addresses) =>
  resolvePublicContracts(fixtureClient(fx), addresses, { refuseUnknown: true, txHash: fixture.provenance.txHash });
const resolveUnguarded = (fx, addresses) =>
  resolvePublicContractsUnguardedForControls(fixtureClient(fx), addresses, fixture.provenance.txHash);

// ---- THE CONTROL, FIRST: a known contract resolves --------------------------
// Every assertion below this line is about a refusal, and a resolver that refused everything would
// satisfy all of them.
const control = await classify('control', () => resolveWith(fixture, [knownAddress]));
const controlOne = control.value?.[0];
line('control.resolved', controlOne?.resolved ? 'yes' : 'no');
line('control.address', controlOne?.address ?? 'none');
line('control.classId', controlOne?.contractClassId ?? 'none');
line('control.bytecodeBytes', controlOne?.packedBytecodeBytes ?? 'none');
line('control.bufferBytes', controlOne?.contractClass?.packedBytecode?.length ?? 'none');
line('control.missing', String(controlOne?.missing));
// The two node methods the resolution is supposed to go through, asked of the RECORDING: if it had
// answered from somewhere else, these calls would not be in the fixture.
line('control.fixtureHasGetContract',
     fixture.calls.some((c) => c.method === 'aztec_getContract' && c.params[0] === known.address) ? 'yes' : 'no');
line('control.fixtureHasGetContractClass',
     fixture.calls.some((c) => c.method === 'aztec_getContractClass' && c.params[0] === known.contractClassId) ? 'yes' : 'no');
// The declared resolution methods, and whether each of them is ON THE WIRE in this recording. A
// constant compared with itself would be the most degenerate shape on this campaign's list; this
// ties the declaration to what actually crossed.
line('resolution.declaredMethods', CONTRACT_RESOLUTION_METHODS.join(','));
line('resolution.declaredMethodsOnWire',
     CONTRACT_RESOLUTION_METHODS.every((m) => fixture.calls.some((c) => c.method === `aztec_${m}`)) ? 'yes' : 'no');
line('resolution.wireMethodCount', new Set(fixture.calls.map((c) => c.method)).size);
// THE STATED LIMITATION, CARRIED IN THE VALUE. `getContract` resolves an instance's CURRENT class
// as of a reference block, and L1 does not pass one — so an upgraded contract would resolve to the
// class it runs today rather than the one that ran in the settling block. Declared rather than left
// to be discovered as a divergence somebody attributes to the runtime; the fix is L2's, because a
// reference block has to go to the witness queries in the same change.
line('resolution.referenceBlock', CONTRACT_RESOLUTION_REFERENCE_BLOCK);
line('control.resolvedAsOf', controlOne?.resolvedAsOf ?? 'none');
line('resolution.callHasNoReferenceBlock',
     fixture.calls.some((c) => c.method === 'aztec_getContract' && c.params.length === 1) ? 'yes' : 'no');

// ---- ARM 1: the node has no INSTANCE for this address -----------------------
const noInstance = edit(fixture, 'aztec_getContract', [known.address], null);
line('noInstance.hits', noInstance.hits);
const armInstance = await classify('armInstance', () => resolveWith(noInstance.fixture, [knownAddress]));
line('armInstance.stage', armInstance.error?.stage ?? 'none');
line('armInstance.address', armInstance.error?.address ?? 'none');
line('armInstance.namesRealAddress', armInstance.error?.address === known.address ? 'yes' : 'no');
line('armInstance.classId', String(armInstance.error?.contractClassId));
line('armInstance.namesTx', armInstance.error?.txHash === fixture.provenance.txHash ? 'yes' : 'no');
line('armInstance.namesUrl', armInstance.error?.url === fixture.provenance.endpoint ? 'yes' : 'no');
line('armInstance.messageNamesAddress',
     String(armInstance.error?.message ?? '').includes(known.address) ? 'yes' : 'no');
line('armInstance.messageSaysAbsentBytecode',
     /ABSENT BYTECODE/.test(String(armInstance.error?.message ?? '')) ? 'yes' : 'no');

// …and the WHOLE FETCH refuses, rather than returning a SettledTransaction with an empty
// `contracts` array. Nothing partial escapes.
const fetchInstance = await classify('fetchInstance',
  () => fetchSettledTransaction(fixtureClient(noInstance.fixture), hash));
line('fetchInstance.returnedSomething', fetchInstance.value === undefined ? 'no' : 'yes');

// ---- ARM 2: the instance is published and the node has no CLASS -------------
const noClass = edit(fixture, 'aztec_getContractClass', [known.contractClassId], null);
line('noClass.hits', noClass.hits);
const armClass = await classify('armClass', () => resolveWith(noClass.fixture, [knownAddress]));
line('armClass.stage', armClass.error?.stage ?? 'none');
line('armClass.namesRealAddress', armClass.error?.address === known.address ? 'yes' : 'no');
// THE CLASS ID IS NAMED HERE AND NOT IN ARM 1, because in arm 1 there is no instance to read one
// from. A refusal that invented a class id would be worse than one that said nothing.
line('armClass.classId', armClass.error?.contractClassId ?? 'none');
line('armClass.namesRealClassId', armClass.error?.contractClassId === known.contractClassId ? 'yes' : 'no');
const fetchClass = await classify('fetchClass',
  () => fetchSettledTransaction(fixtureClient(noClass.fixture), hash));
line('fetchClass.returnedSomething', fetchClass.value === undefined ? 'no' : 'yes');

// ---- ARM 3: both resolve and the BYTECODE IS EMPTY --------------------------
// The sibling campaign's own failure, exactly: an artefact that resolves, a length of zero, and an
// AVM that starts, reads nothing and emits a sentinel.
const classCall = fixture.calls.find(
  (c) => c.method === 'aztec_getContractClass' && c.params[0] === known.contractClassId);
const emptyBytecode = edit(fixture, 'aztec_getContractClass', [known.contractClassId],
                           { ...classCall.result, packedBytecode: '' });
line('emptyBytecode.hits', emptyBytecode.hits);
const armBytecode = await classify('armBytecode', () => resolveWith(emptyBytecode.fixture, [knownAddress]));
line('armBytecode.stage', armBytecode.error?.stage ?? 'none');
line('armBytecode.namesRealAddress', armBytecode.error?.address === known.address ? 'yes' : 'no');
line('armBytecode.namesRealClassId', armBytecode.error?.contractClassId === known.contractClassId ? 'yes' : 'no');
const fetchBytecode = await classify('fetchBytecode',
  () => fetchSettledTransaction(fixtureClient(emptyBytecode.fixture), hash));
line('fetchBytecode.returnedSomething', fetchBytecode.value === undefined ? 'no' : 'yes');

// ---- ARM 4: an address the LIVE NODE said it does not know ------------------
// No edit at all. The capture asked the chain about this address and recorded its `null`.
const fabricated = AztecAddress.fromFieldUnsafe(
  Fr.fromHexString(fixture.provenance.fabricatedProbes.contractAddress));
const armLive = await classify('armLive', () => resolveWith(fixture, [fabricated]));
line('armLive.stage', armLive.error?.stage ?? 'none');
line('armLive.address', armLive.error?.address ?? 'none');
line('armLive.namesFabricated',
     armLive.error?.address === fixture.provenance.fabricatedProbes.contractAddress ? 'yes' : 'no');

// ---- §6. THE UNGUARDED CONTROL: what happens WITHOUT the refusal ------------
// The same function, the same node calls, one flag. This is the well-formed nothing the guard
// exists to prevent, produced so it can be looked at rather than described.
const unguardedRun = await classify('unguarded.instance', () => resolveUnguarded(noInstance.fixture, [knownAddress]));
const unguardedInstance = unguardedRun.value[0];
line('unguarded.instance.resolved', unguardedInstance.resolved ? 'yes' : 'no');
line('unguarded.instance.missing', unguardedInstance.missing);
line('unguarded.instance.address', unguardedInstance.address);
line('unguarded.instance.bytecodeBytes', unguardedInstance.packedBytecodeBytes);
line('unguarded.instance.hasClass', unguardedInstance.contractClass === undefined ? 'no' : 'yes');
// It is WELL FORMED — an object with an address, a shape and a length. That is the whole danger.
line('unguarded.instance.wellFormed',
     typeof unguardedInstance.address === 'string'
       && typeof unguardedInstance.packedBytecodeBytes === 'number' ? 'yes' : 'no');

const unguardedClass = (await resolveUnguarded(noClass.fixture, [knownAddress]))[0];
line('unguarded.class.missing', unguardedClass.missing);
line('unguarded.class.bytecodeBytes', unguardedClass.packedBytecodeBytes);
const unguardedBytecode = (await resolveUnguarded(emptyBytecode.fixture, [knownAddress]))[0];
line('unguarded.bytecode.missing', unguardedBytecode.missing);
line('unguarded.bytecode.bytecodeBytes', unguardedBytecode.packedBytecodeBytes);

// AND THE UNGUARDED PATH IS NOT ONE THAT ALWAYS SAYS 'MISSING'. Over the INTACT recording it
// resolves, with the same bytes the guarded path reports — so `resolved: false` above is a
// measurement of the edit and not a property of the flag.
const unguardedGood = (await resolveUnguarded(fixture, [knownAddress]))[0];
line('unguarded.good.resolved', unguardedGood.resolved ? 'yes' : 'no');
line('unguarded.good.bytecodeBytes', unguardedGood.packedBytecodeBytes);
line('unguarded.good.missing', String(unguardedGood.missing));

// ---- §7. the three stages are three stages, and this class is its own -------
line('stages.declared', MISSING_ARTIFACT_STAGES.join(','));
line('stages.observed', [armInstance.error?.stage, armClass.error?.stage, armBytecode.error?.stage].join(','));
line('stages.distinct',
     new Set([armInstance.error?.stage, armClass.error?.stage, armBytecode.error?.stage]).size);
line('class.isOwnClass', armInstance.error instanceof MissingContractArtifact ? 'yes' : 'no');
line('class.notNotFound', armInstance.error instanceof SettledTransactionNotFound ? 'yes' : 'no');
line('class.notUnreachable', armInstance.error instanceof NodeUnreachable ? 'yes' : 'no');
line('class.notSurfaceExceeded', armInstance.error instanceof ReplayNodeSurfaceExceeded ? 'yes' : 'no');
line('class.notFixtureMiss', armInstance.error instanceof FixtureMiss ? 'yes' : 'no');
line('class.isError', armInstance.error instanceof Error ? 'yes' : 'no');
// …and the not-found refusal is NOT a MissingContractArtifact, which is the other direction.
const notFound = await classify('notFound',
  () => fetchSettledTransaction(fixtureClient(fixture),
                                TxHash.fromString(fixture.provenance.fabricatedProbes.txHash)));
line('notFound.isMissingArtifact', notFound.error instanceof MissingContractArtifact ? 'yes' : 'no');

line('l1.done', 1);
EOS
)"

OUT="$L1_WORK/probes/artifact.out"
l0_run_probe artifact "$PROBE" "$OUT" l1.done
f() { l0_field "$OUT" "$1"; }
j() { l1_json "$FIXTURE" "$1"; }

KNOWN_ADDRESS="$(j "d['provenance']['nodeReported']['contracts'][0]['address']")"
KNOWN_CLASS="$(j "d['provenance']['nodeReported']['contracts'][0]['contractClassId']")"
KNOWN_BYTES="$(j "d['provenance']['nodeReported']['contracts'][0]['packedBytecodeBytes']")"

# ---------------------------------------------------------------------------
echo "== 1. THE CONTROL: a known contract resolves, with real bytecode"
#
# First and deliberately first. Every arm below is a refusal.
# ---------------------------------------------------------------------------
assert_eq "resolving the contract this settled transaction actually calls returns" "returned" \
  "$(f control.outcome)"
assert_eq "…and it resolved" "yes" "$(f control.resolved)"
assert_eq "…at the address the chain named" "$KNOWN_ADDRESS" "$(f control.address)"
assert_eq "…running the class the chain named" "$KNOWN_CLASS" "$(f control.classId)"
assert_eq "…with the bytecode the chain published" "$KNOWN_BYTES" "$(f control.bytecodeBytes)"
assert_eq "…which is the buffer's own length and not a number beside it" "$KNOWN_BYTES" \
  "$(f control.bufferBytes)"
assert_ge "…and it is real bytecode" 1000 "$(f control.bytecodeBytes)"
assert_eq "…with nothing recorded missing" "undefined" "$(f control.missing)"
# THE RESOLUTION WENT THROUGH UPSTREAM'S TWO METHODS. Asked of the recording, so this is what
# crossed the wire and not what the source says it calls.
assert_eq "the recording carries the getContract call the resolution made" "yes" \
  "$(f control.fixtureHasGetContract)"
assert_eq "…and the getContractClass call" "yes" "$(f control.fixtureHasGetContractClass)"
assert_eq "…which are exactly the two methods this module declares it resolves through" \
  "getContract,getContractClass" "$(f resolution.declaredMethods)"
assert_eq "…and every declared method is one this recording actually saw on the wire" "yes" \
  "$(f resolution.declaredMethodsOnWire)"
assert_ge "…out of a recording that carries more wire methods than those two" 4 \
  "$(f resolution.wireMethodCount)"
# THE STATED LIMITATION, ASSERTED SO IT CANNOT BE SILENTLY CHANGED IN EITHER DIRECTION. L1 resolves
# an instance as of `latest` and not as of the settling block; an upgraded contract would therefore
# resolve to the class it runs TODAY. The value says so, the wire says so, and L2 is where the
# reference block goes in — together with the one the witness queries need.
assert_eq "the reference block a contract is resolved as of is declared" "latest" \
  "$(f resolution.referenceBlock)"
assert_eq "…and every resolution carries it, so a caller can see which block it is about" "latest" \
  "$(f control.resolvedAsOf)"
assert_eq "…and the wire agrees: getContract went out with no reference-block argument" "yes" \
  "$(f resolution.callHasNoReferenceBlock)"

# ---------------------------------------------------------------------------
echo "== 2. ARM 1 — the node has no instance for the address"
# ---------------------------------------------------------------------------
assert_eq "the substitution found its needle, so this arm ran over a changed recording" "1" \
  "$(f noInstance.hits)"
assert_eq "a contract the node does not know is REFUSED" "replay-missing-contract-artifact" \
  "$(f armInstance.outcome)"
assert_eq "…by its own class" "MissingContractArtifact" "$(f armInstance.class)"
assert_eq "…at the instance stage" "instance" "$(f armInstance.stage)"
assert_eq "…NAMING THE ADDRESS, which is the deliverable's own word" "$KNOWN_ADDRESS" \
  "$(f armInstance.address)"
assert_eq "…and it is the real address from a real chain, not a fixture value" "yes" \
  "$(f armInstance.namesRealAddress)"
assert_eq "…without inventing a class id it could not have known" "undefined" "$(f armInstance.classId)"
assert_eq "…naming the transaction that called it" "yes" "$(f armInstance.namesTx)"
assert_eq "…and the node that was asked" "yes" "$(f armInstance.namesUrl)"
assert_eq "the message a reader sees carries the address" "yes" "$(f armInstance.messageNamesAddress)"
assert_eq "…and says what continuing would have done" "yes" "$(f armInstance.messageSaysAbsentBytecode)"
assert_eq "and the WHOLE FETCH refuses rather than returning a transaction with no contracts" "no" \
  "$(f fetchInstance.returnedSomething)"
assert_eq "…with the same refusal" "replay-missing-contract-artifact" "$(f fetchInstance.outcome)"

# ---------------------------------------------------------------------------
echo "== 3. ARM 2 — the instance is published and the class is not"
# ---------------------------------------------------------------------------
assert_eq "the substitution found its needle" "1" "$(f noClass.hits)"
assert_eq "a published contract whose class the node lacks is REFUSED" \
  "replay-missing-contract-artifact" "$(f armClass.outcome)"
assert_eq "…at the class stage, which is a different stage from arm 1" "class" "$(f armClass.stage)"
assert_eq "…naming the address" "yes" "$(f armClass.namesRealAddress)"
assert_eq "…AND the class id, which arm 1 could not know" "$KNOWN_CLASS" "$(f armClass.classId)"
assert_eq "…and it is the real one" "yes" "$(f armClass.namesRealClassId)"
assert_eq "the whole fetch refuses here too" "replay-missing-contract-artifact" "$(f fetchClass.outcome)"
assert_eq "…returning nothing" "no" "$(f fetchClass.returnedSomething)"

# ---------------------------------------------------------------------------
echo "== 4. ARM 3 — both resolve and the bytecode is EMPTY"
#
# This is the sibling campaign's failure in its own shape: an artefact that resolves, a length of
# zero, and an AVM that starts, reads nothing and emits a sentinel inside a well-formed container.
# ---------------------------------------------------------------------------
assert_eq "the substitution found its needle" "1" "$(f emptyBytecode.hits)"
assert_eq "a contract class with zero bytes of bytecode is REFUSED" \
  "replay-missing-contract-artifact" "$(f armBytecode.outcome)"
assert_eq "…at the bytecode stage, the third of three" "bytecode" "$(f armBytecode.stage)"
assert_eq "…naming the address" "yes" "$(f armBytecode.namesRealAddress)"
assert_eq "…and the class that resolved to nothing" "yes" "$(f armBytecode.namesRealClassId)"
assert_eq "the whole fetch refuses" "replay-missing-contract-artifact" "$(f fetchBytecode.outcome)"
assert_eq "…returning nothing" "no" "$(f fetchBytecode.returnedSomething)"

# ---------------------------------------------------------------------------
echo "== 5. ARM 4 — an address the LIVE NODE itself said it does not know"
#
# No edit. The capture asked the chain and recorded its answer.
# ---------------------------------------------------------------------------
assert_eq "the fabricated address the live node answered null for is refused" \
  "replay-missing-contract-artifact" "$(f armLive.outcome)"
assert_eq "…at the instance stage" "instance" "$(f armLive.stage)"
assert_eq "…naming it" "$(j "d['provenance']['fabricatedProbes']['contractAddress']")" \
  "$(f armLive.address)"
assert_eq "…and it is the address the capture declared fabricated" "yes" "$(f armLive.namesFabricated)"

# ---------------------------------------------------------------------------
echo "== 6. THE UNGUARDED CONTROL: the well-formed nothing, produced and looked at"
#
# The same function with `refuseUnknown: false` — one flag, one resolution path, so the control runs
# THROUGH the instrument rather than beside it. What comes back is an object with an address, a
# shape and a byte count of zero: exactly what a caller would have handed to an AVM.
# ---------------------------------------------------------------------------
assert_eq "with the guard off, the same call RETURNS instead of throwing" "returned" \
  "$(f unguarded.instance.outcome)"
assert_eq "…and what it returns is well formed" "yes" "$(f unguarded.instance.wellFormed)"
assert_eq "…carrying the address, so it looks like every other resolution" "$KNOWN_ADDRESS" \
  "$(f unguarded.instance.address)"
assert_eq "…and ZERO bytes of bytecode" "0" "$(f unguarded.instance.bytecodeBytes)"
assert_eq "…with no contract class at all" "no" "$(f unguarded.instance.hasClass)"
assert_eq "…marked unresolved, which is the only thing distinguishing it" "no" \
  "$(f unguarded.instance.resolved)"
assert_eq "…at the stage it failed" "instance" "$(f unguarded.instance.missing)"
assert_eq "the class arm without the guard is the same shape" "class" "$(f unguarded.class.missing)"
assert_eq "…also zero bytes" "0" "$(f unguarded.class.bytecodeBytes)"
assert_eq "the empty-bytecode arm without the guard is the same shape" "bytecode" \
  "$(f unguarded.bytecode.missing)"
assert_eq "…also zero bytes" "0" "$(f unguarded.bytecode.bytecodeBytes)"
# THE UNGUARDED PATH IS NOT ONE THAT ALWAYS FAILS. Over the intact recording it resolves, with the
# same bytes — so the zeros above are a measurement of the edits and not a property of the flag.
assert_eq "over the INTACT recording the unguarded path resolves" "yes" "$(f unguarded.good.resolved)"
assert_eq "…with the same bytecode the guarded path reports" "$KNOWN_BYTES" \
  "$(f unguarded.good.bytecodeBytes)"
assert_eq "…and nothing missing" "undefined" "$(f unguarded.good.missing)"

# ---------------------------------------------------------------------------
echo "== 7. the three stages are three stages, and the class is nobody else's"
# ---------------------------------------------------------------------------
assert_eq "the three arms produced the three declared stages, in order" \
  "$(f stages.declared)" "$(f stages.observed)"
assert_eq "…and they are three distinct values" "3" "$(f stages.distinct)"
assert_eq "the refusal is MissingContractArtifact" "yes" "$(f class.isOwnClass)"
assert_eq "…and NOT the not-found refusal" "no" "$(f class.notNotFound)"
assert_eq "…nor the unreachable one" "no" "$(f class.notUnreachable)"
assert_eq "…nor the surface guard's" "no" "$(f class.notSurfaceExceeded)"
assert_eq "…nor a fixture miss" "no" "$(f class.notFixtureMiss)"
assert_eq "…and it is an Error, so a caller's catch sees a stack" "yes" "$(f class.isError)"
# The other direction: an unknown TRANSACTION must not read as an unknown CONTRACT.
assert_eq "an unknown transaction hash is refused as not-found" "replay-transaction-not-found" \
  "$(f notFound.outcome)"
assert_eq "…and is NOT a missing-artifact refusal" "no" "$(f notFound.isMissingArtifact)"

finish
