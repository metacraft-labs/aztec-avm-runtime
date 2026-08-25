#!/usr/bin/env bash
# e2e_form_a_external_tx_roundtrip — M20.
#
# The deliverable: "A serialized Tx deserializes, executes its public half against the in-memory
# world state on the wasm AVM, and lands its side effects."
#
# WHAT MAKES THIS AN END-TO-END RATHER THAN A SHAPE TEST. Every arm goes
# `mockTx -> tx.toBuffer() -> Tx.fromBuffer -> validateTxShape -> AvmTxHint.fromTx ->
# serializeWithMessagePack -> avm.wasm -> PublicTxResult`, against the resident world state that
# lives inside the module, and NOTHING downstream of the buffer reads the transaction the mock
# built. If the round trip lost a field, the phases would not line up and the arms would not
# discriminate.
#
# "LANDS ITS SIDE EFFECTS" IS ASSERTED AGAINST THE TREE, NOT AGAINST THE RESULT. The result is
# what the module says happened; the public data tree read back through
# `avm_merkle_db_get_low_indexed_leaf` + `avm_merkle_db_get_leaf_preimage_public_data_tree` is
# what it actually did. The landing arm's fee payer balance goes DOWN by exactly the reported fee,
# and the rejected arms' balances do not move at all — three of them, so "the balance changed" is
# never satisfiable by a check that simply always writes.
#
# THE PHASE IS THE ONLY VARIABLE BETWEEN THE FIRST TWO ARMS AND THAT IS THE POINT. The same kind
# of failing call — a call to a contract that was never registered, which fails bytecode retrieval,
# one of the six CHECKED exception types the AVM converts into an exceptional halt — LANDS as a
# soft revert in APP_LOGIC and THROWS THE TRANSACTION OUT in SETUP. A check that only ran one of
# them would pass against an engine that treated both the same way.
#
# Run: just verify-form-a-roundtrip

TEST_NAME="e2e_form_a_external_tx_roundtrip"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m20_form_a.sh"

m20_require_anchor
m20_require_arms
mkdir -p "$M20_WORK"
SCRATCH="$(mktemp -d "$M20_WORK/roundtrip.XXXXXX")" || die "no scratch under $M20_WORK"
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.m20_"* "$ORCH_SRC/m20_stale_control.ts"' EXIT INT TERM HUP

note "module $AVM_WASM_PATH"
note "sha256 $M20_MODULE_SHA"
note "arms   $M20_ARMS"

# ---------------------------------------------------------------------------
# PART 1 — the run happened, and it is the run this check thinks it is
# ---------------------------------------------------------------------------

ARM_NAMES="$(m20_arm_names)"
printf '%s\n' "$ARM_NAMES" | sed 's/^/      /'
assert_eq "the arm run produced all seven arms" "7" \
  "$(printf '%s\n' "$ARM_NAMES" | grep -c .)"

for arm in appLogicOnlyFunded appLogicOnlyUnfunded setupCallFails \
           nonRevertibleNullifierClash revertibleNullifierClash teardownReverts noTeardown ; do
  assert_true "arm $arm is present" test "$(m20_arm "$arm" arm)" = "$arm"
done

# The accessor's own control: a name that is not there must read MISSING rather than empty, or
# every `assert_eq` below could be comparing two absences.
assert_eq "an arm name that does not exist reads MISSING, not empty" "MISSING" \
  "$(m20_arm noSuchArm external.kind)"
assert_eq "and so does a field that does not exist" "MISSING" \
  "$(m20_arm appLogicOnlyFunded external.noSuchField)"

# ---------------------------------------------------------------------------
# PART 2 — the round trip carried the transaction
# ---------------------------------------------------------------------------

# The phase counts are read off the DESERIALIZED transaction inside the driver, so a lossy
# round trip shows up here as the wrong split rather than as a mysterious result.
assert_eq "the app-logic arm deserialized with one revertible call and no setup call" "0|1|0" \
  "$(m20_arm appLogicOnlyFunded shape.setup)|$(m20_arm appLogicOnlyFunded shape.appLogic)|$(m20_arm appLogicOnlyFunded shape.teardown)"
assert_eq "the setup arm deserialized with one non-revertible call and no revertible call" "1|0|0" \
  "$(m20_arm setupCallFails shape.setup)|$(m20_arm setupCallFails shape.appLogic)|$(m20_arm setupCallFails shape.teardown)"
assert_eq "the teardown arm deserialized with a teardown request" "1" \
  "$(m20_arm teardownReverts shape.teardown)"
assert_ge "and the serialized transaction was a real one rather than an empty buffer" 100000 \
  "$(m20_arm appLogicOnlyFunded shape.wireBytes)"

# The teardown request is the ONLY difference between the last two arms, and it costs bytes.
BYTES_WITH="$(m20_arm teardownReverts shape.wireBytes)"
BYTES_WITHOUT="$(m20_arm noTeardown shape.wireBytes)"
assert_true "the teardown request makes the wire form larger, so the pair really does differ" \
  test "$BYTES_WITH" -gt "$BYTES_WITHOUT"

# ---------------------------------------------------------------------------
# PART 3 — the public half executed, and the phase decided the outcome
# ---------------------------------------------------------------------------

assert_eq "an APP_LOGIC call that fails LANDS as a soft revert" "landed" \
  "$(m20_arm appLogicOnlyFunded external.kind)"
assert_eq "and its revert code is non-zero" "1" \
  "$(m20_arm appLogicOnlyFunded external.rawRevertCode)"
# "THE WHOLE ALLOCATED L2 GAS" IS TWO MEASURED NUMBERS, NOT ONE AND A CONSTANT. This was
# `assert_eq "…" "6540000" "$(m20_arm … external.totalGas)"`: the value is correct — `mockTx`
# defaults to `MAX_PROCESSABLE_L2_GAS`, which `@aztec/constants` declares as 6540000 — but the
# ALLOCATION was never read, so the assertion's name claimed a relationship its body did not test
# and an upstream bump would have read as the AVM no longer consuming all its gas. The limit is now
# read off the deserialized transaction, the pinned value is kept as a THIRD assertion so a silent
# upstream bump is still visible, and a non-zero guard sits beside them because 0 == 0 would
# otherwise satisfy the equality.
GAS_LIMIT_L2="$(m20_arm appLogicOnlyFunded shape.gasLimitL2)"
note "allocated l2Gas $GAS_LIMIT_L2, consumed $(m20_arm appLogicOnlyFunded external.totalGas)"
assert_true "the transaction's own L2 gas allocation was read off it and is non-zero" \
  test "$GAS_LIMIT_L2" -gt 0
assert_eq "and it consumed the whole allocated L2 gas, which is what an exceptional halt does" \
  "$GAS_LIMIT_L2" "$(m20_arm appLogicOnlyFunded external.totalGas)"
assert_eq "the allocation is still upstream's MAX_PROCESSABLE_L2_GAS, so a bump is visible here" \
  "6540000" "$GAS_LIMIT_L2"

assert_eq "THE SAME FAILING CALL IN SETUP throws the transaction out instead" "rejected" \
  "$(m20_arm setupCallFails external.kind)"
assert_eq "and names the SETUP arm of the C++ control flow" "setupCallFailed" \
  "$(m20_arm setupCallFails external.reason)"

# ---------------------------------------------------------------------------
# PART 4 — the side effects landed in the TREE
# ---------------------------------------------------------------------------

BEFORE="$(m20_arm appLogicOnlyFunded balanceBefore)"
AFTER="$(m20_arm appLogicOnlyFunded balanceAfter)"
FEE_HEX="$(m20_arm appLogicOnlyFunded external.transactionFee)"
FEE="$(python3 -c 'import sys; print(int(sys.argv[1], 16))' "$FEE_HEX")"

note "fee payer balance $BEFORE -> $AFTER, reported fee $FEE"
assert_true "the funded arm's balance was read back out of the tree before the run" \
  test "$BEFORE" != "null"
assert_true "and after it" test "$AFTER" != "null"
assert_true "the reported fee is not zero, or 'it still paid' would be vacuous" test "$FEE" -gt 0
assert_eq "the balance went DOWN by exactly the reported fee" "$FEE" \
  "$(python3 -c 'import sys; print(int(sys.argv[1]) - int(sys.argv[2]))' "$BEFORE" "$AFTER")"

# Three arms that were thrown out: nothing moved. The balance assertion above cannot be satisfied
# by an implementation that debits unconditionally.
for arm in setupCallFails nonRevertibleNullifierClash revertibleNullifierClash ; do
  B="$(m20_arm "$arm" balanceBefore)"
  A="$(m20_arm "$arm" balanceAfter)"
  assert_true "$arm read a balance before the run" test "$B" != "null"
  assert_eq "$arm was thrown out and its fee payer was NOT debited" "$B" "$A"
done

# ---------------------------------------------------------------------------
# PART 5 — nothing was classified by accident
# ---------------------------------------------------------------------------

# Every arm reached a verdict. `threw` means the driver caught something the classifier did not
# recognise, which for these five inputs is a defect rather than an outcome.
THREW="$(python3 -c '
import json, sys
doc = json.load(open(sys.argv[1]))
bad = [a["arm"] for a in doc["arms"] if a["external"].get("kind") == "threw"]
print(",".join(bad) if bad else "none")' "$M20_ARMS")"
assert_eq "no arm produced an unclassified throw" "none" "$THREW"

# ---------------------------------------------------------------------------
# PART 6 — the three phases are wired to upstream's own call sources
# ---------------------------------------------------------------------------
#
# M20's third deliverable. It had NO check at all: `tx_intake.ts` cited a
# `test_phase_sources_match_upstream_helper` that does not exist, and nothing in `verification/`
# so much as mentioned `getCallRequestsWithCalldataByPhase`, `phaseCallRequests`, or any of the
# three accessors. A comment claiming a property is pinned, over a property nothing pins, is worse
# than no comment: it tells the next reader to stop looking.
#
# WHAT IS COMPARED, AND WHY IT IS THE SWITCH BODY. `getCallRequestsWithCalldataByPhase` exists
# unchanged in `@aztec/simulator`, but it is NOT on the execution path — its only callers at the
# anchor are the two p2p tx validators. What actually runs is `AvmTxHint.fromTx`, which calls the
# same three `Tx` accessors directly. So the equivalence worth pinning is between OUR splitter and
# UPSTREAM'S, and between both and what the encoder calls.
#
# EXACT LINES, NOT FRAGMENTS. This campaign has shipped a pin that matched changed lines against a
# regex of substrings and excused `this.depth = depth + 1` because it contained `this.depth =
# depth`. The two switch bodies are compared line for line after leading-whitespace normalisation,
# with the mutation control being that a single differing line fails.

UPSTREAM_SPLITTER="$SCRATCH/upstream_utils.ts"
m20_anchor_file yarn-project/simulator/src/public/utils.ts > "$UPSTREAM_SPLITTER"
AVM_TS="$SCRATCH/avm.ts"
m20_anchor_file yarn-project/stdlib/src/avm/avm.ts > "$AVM_TS"
assert_ge "upstream's splitter was read from the anchor" 10 "$(wc -l < "$UPSTREAM_SPLITTER")"
assert_ge "and stdlib's avm.ts, which carries AvmTxHint.fromTx" 500 "$(wc -l < "$AVM_TS")"

# The switch body of each, from `switch (phase) {` to the line before `default:`.
switch_body() { # <file> <function-signature-needle>
  python3 - "$1" "$2" <<'PY'
import re, sys
text = open(sys.argv[1]).read()
start = text.find(sys.argv[2])
if start < 0:
    print("SIGNATURE-NOT-FOUND"); raise SystemExit
body = text[start:]
begin = body.find("switch (phase) {")
end = body.find("default:")
if begin < 0 or end < 0 or end < begin:
    print("SWITCH-NOT-FOUND"); raise SystemExit
lines = [l.strip() for l in body[begin:end].split("\n")]
print("\n".join(l for l in lines if l))
PY
}

OURS="$(switch_body "$ORCH_SRC/tx_intake.ts" 'export function phaseCallRequests')"
THEIRS="$(switch_body "$UPSTREAM_SPLITTER" 'export function getCallRequestsWithCalldataByPhase')"
printf '%s\n' "$THEIRS" | sed 's/^/      /'

assert_true "our splitter's switch body was extracted" \
  test "$OURS" != "SIGNATURE-NOT-FOUND" -a "$OURS" != "SWITCH-NOT-FOUND"
assert_true "and upstream's" \
  test "$THEIRS" != "SIGNATURE-NOT-FOUND" -a "$THEIRS" != "SWITCH-NOT-FOUND"
assert_ge "and neither is empty, so the comparison below has two sides" 6 \
  "$(printf '%s\n' "$OURS" | grep -c .)"
assert_eq "phaseCallRequests' switch body is upstream's, line for line" "$THEIRS" "$OURS"

# THE PIN'S OWN CONTROLS, and the second is the one that matters: a pin that compares the WRONG
# REGION passes on anything. Three things are shown, over doctored copies rather than by argument.
#
#   (a) the extracted region really is the switch body — it names all three phases;
#   (b) a change to UPSTREAM's switch is caught, not just a change to ours. The mutation that
#       proves our side is a source edit; this one doctors upstream's file and requires the
#       comparison to move, so "would it fail if upstream's changed" is answered by measurement;
#   (c) a change OUTSIDE the switch — in the function's signature or its default arm — is NOT
#       caught, which is the honest boundary of what this pin claims and stops it from being read
#       as "the two functions are identical".
assert_ge "the extracted region is the switch body: it names all three phases" 3 \
  "$(printf '%s\n' "$THEIRS" | grep -c 'TxExecutionPhase\.\(SETUP\|APP_LOGIC\|TEARDOWN\)')"

DOCTORED="$SCRATCH/upstream_utils_doctored.ts"
sed 's|return tx.getNonRevertiblePublicCallRequestsWithCalldata();|return tx.getRevertiblePublicCallRequestsWithCalldata();|' \
  "$UPSTREAM_SPLITTER" > "$DOCTORED"
assert_true "the doctored upstream copy really differs from the original" \
  test -n "$(cmp -s "$UPSTREAM_SPLITTER" "$DOCTORED" || echo differs)"
DOCTORED_BODY="$(switch_body "$DOCTORED" 'export function getCallRequestsWithCalldataByPhase')"
assert_true "a change to UPSTREAM's switch body would fail this pin" \
  test "$DOCTORED_BODY" != "$OURS"

OUTSIDE="$SCRATCH/upstream_utils_outside.ts"
sed 's|throw new Error(`Unknown phase: ${phase}`);|throw new Error("something else entirely");|' \
  "$UPSTREAM_SPLITTER" > "$OUTSIDE"
assert_true "the outside-the-switch edit really was applied" \
  test -n "$(cmp -s "$UPSTREAM_SPLITTER" "$OUTSIDE" || echo differs)"
assert_eq "while a change OUTSIDE the switch is deliberately NOT caught, which is what this pin claims" \
  "$OURS" "$(switch_body "$OUTSIDE" 'export function getCallRequestsWithCalldataByPhase')"

# The equivalence that matters at runtime: the ENCODER calls the same three accessors, so there is
# one phase split in this runtime and it is upstream's.
for accessor in getNonRevertiblePublicCallRequestsWithCalldata \
                getRevertiblePublicCallRequestsWithCalldata \
                getTeardownPublicCallRequestWithCalldata ; do
  assert_ge "AvmTxHint.fromTx — what actually runs — calls $accessor" 1 \
    "$(grep -c "tx\.$accessor()" "$AVM_TS")"
  assert_ge "and so does our phaseCallRequests" 1 \
    "$(grep -c "tx\.$accessor()" "$ORCH_SRC/tx_intake.ts")"
done

# THE CONTROL for those six greps: an accessor spelling upstream does NOT use must not be found by
# the same command in either file, or all six are greps that match anything.
assert_eq "an accessor upstream does not have is found in neither file" "0|0" \
  "$(grep -c 'tx\.getPublicCallRequestsWithCalldata()' "$AVM_TS" || true)|$(grep -c 'tx\.getPublicCallRequestsWithCalldata()' "$ORCH_SRC/tx_intake.ts" || true)"

# And the deliverable's own caveat, asserted rather than asserted-about: upstream's named helper is
# off the execution path. Its only callers at the anchor are the two p2p validators.
CALLERS="$(cd "$FORK_ROOT" && git grep -lw 'getCallRequestsWithCalldataByPhase' "$M20_CPP_ANCHOR" \
  -- yarn-project | sed 's/^[0-9a-f]*://' | grep -v '^yarn-project/simulator/src/public/' | sort)"
printf '%s\n' "$CALLERS" | sed 's/^/      /'
assert_eq "upstream's named phase helper is called only from the two p2p tx validators" \
  "yarn-project/p2p/src/msg_validators/tx_validator/fee_payer_balance.ts
yarn-project/p2p/src/msg_validators/tx_validator/phases_validator.ts" "$CALLERS"

# ---------------------------------------------------------------------------
# PART 7 — the shared arm run really is shared
# ---------------------------------------------------------------------------
#
# `lib_m20_form_a.sh` promises "measured once and shared … two checks each deriving 'the fee'
# would eventually disagree about a number nothing had changed". It was not delivering that: the
# staleness test compared against the `orchestration/src` DIRECTORY, and two checks write a probe
# into that directory before asking for the arms, so one `verify-m20` ran the module three times.
# Both directions are asserted, because a staleness test that never fires would also give a count
# of one — and would then happily report against a genuinely stale run.

PROBE_LIKE="$ORCH_SRC/.m20_stale_probe.mjs"
CONTROL_LIKE="$ORCH_SRC/m20_stale_control.ts"

printf 'export const x = 1;\n' > "$PROBE_LIKE"
assert_eq "a check's own dot-prefixed probe does NOT invalidate the shared arm run" "" \
  "$(m20_arms_newer_inputs)"
rm -f "$PROBE_LIKE"

printf 'export const y = 1;\n' > "$CONTROL_LIKE"
assert_true "while a real new source file under orchestration/src DOES" \
  test -n "$(m20_arms_newer_inputs)"
rm -f "$CONTROL_LIKE"

assert_eq "and the probe files were removed again" "0" \
  "$(find "$ORCH_SRC" -maxdepth 1 \( -name '.m20_*' -o -name 'm20_stale_control.ts' \) | grep -c . || true)"

# ---------------------------------------------------------------------------
# PART 8 — D14: the encoding delta is exactly one named key, COMPUTED
# ---------------------------------------------------------------------------
#
# `shipped_module_config.ts` exists because the shipped module is NOT
# upstream-encoding-compatible: M9's observation-hook patch adds
# `collect_execution_steps` to `PublicSimulatorConfig`'s msgpack field list, bb's reader treats a
# listed field as required, and the module answers upstream's own encoding with
# `Missing field collectExecutionSteps`. That is DRIFT.md D14.
#
# The file's own stated discipline is that "the extra keys are a named constant, the two encodings
# are produced side by side, and the DELTA IS COMPUTED from the bytes rather than asserted from the
# list — so a second, unnoticed key would fail the comparison instead of riding along", and it
# named a `verify_form_a_encoding_delta_is_one_named_key` as that comparison. **That check did not
# exist.** Nothing called `encodeForShippedModule` — the function that produces both encodings —
# and nothing used its `injectedConfigFields` parameter, which the file says exists "for the fault
# injection that proves the delta comparison can fail". The discipline was stated and not
# delivered; `diffsim/` has it, and the shipped package must not depend on `diffsim/`.
#
# THE WALK IS THE CHECK'S, NOT THE SUBJECT'S. A driver that computed its own delta would have to be
# trusted about it. The probe emits the two DECODED maps and this file's python walks them.

cat > "$SCRATCH/encoding.mjs" <<'EOF'
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';
import { GasFees } from '@aztec/stdlib/gas';
import { GlobalVariables } from '@aztec/stdlib/tx';
import { deserializeFromMessagePack } from '@aztec/stdlib/avm';
import { mockTx } from '@aztec/stdlib/testing';

import {
  PATCH_REQUIRED_CONFIG_FIELDS, defaultPublicSimulatorConfig, encodeForShippedModule,
  residentWorldStateRevision,
} from './index.ts';

const globals = GlobalVariables.from({ ...GlobalVariables.empty(), gasFees: new GasFees(1n, 1n) });
const feePayer = await AztecAddress.fromField(new Fr(7_001_011n));
const tx = await mockTx(1011, {
  numberOfNonRevertiblePublicCallRequests: 0,
  numberOfRevertiblePublicCallRequests: 1,
  numberOfRevertibleNullifiers: 0,
  hasPublicTeardownCallRequest: false,
  feePayer,
});
const config = defaultPublicSimulatorConfig();
const rev = residentWorldStateRevision(1);

// `Fr`/`AztecAddress`/`Buffer` do not survive JSON, and the delta only needs to see SHAPE and
// scalar difference, so every leaf is stringified on the way out.
const plain = (v) => {
  if (v === null || v === undefined) return null;
  if (Array.isArray(v)) return v.map(plain);
  if (v instanceof Uint8Array) return 'bytes:' + v.length;
  if (typeof v === 'object') {
    const out = {};
    for (const k of Object.keys(v)) out[k] = plain(v[k]);
    return out;
  }
  return typeof v === 'bigint' ? v.toString() : v;
};
const decode = (bytes) => plain(deserializeFromMessagePack(Buffer.from(bytes)));

const clean = encodeForShippedModule(tx, globals, config, rev);
const injected = encodeForShippedModule(tx, globals, config, rev, { m20ProbeSecondKey: true });

console.log(JSON.stringify({
  declaredKeys: Object.keys(PATCH_REQUIRED_CONFIG_FIELDS),
  upstreamBytes: clean.upstream.length,
  patchedBytes: clean.patched.length,
  upstream: decode(clean.upstream),
  patched: decode(clean.patched),
  injectedPatched: decode(injected.patched),
}));
EOF
cp "$SCRATCH/encoding.mjs" "$ORCH_SRC/.m20_encoding.mjs"
ENC="$(cd "$ORCH_SRC" && node .m20_encoding.mjs 2>&1 | tail -1)" || die "the encoding probe failed: $ENC"
rm -f "$ORCH_SRC/.m20_encoding.mjs"
printf '%s\n' "$ENC" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("      declared:",d["declaredKeys"],"upstream",d["upstreamBytes"],"bytes / patched",d["patchedBytes"],"bytes")'

# The recursive walk, here rather than in the subject.
delta() { # <left-key> <right-key>
  python3 - "$ENC" "$1" "$2" <<'PY'
import json, sys
doc = json.loads(sys.argv[1])
out = []
def walk(a, b, path):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in a:
            if k not in b:
                out.append(f"{path + '.' if path else ''}{k}: present on the left only")
        for k in b:
            if k not in a:
                out.append(f"{path + '.' if path else ''}{k}: present on the right only")
            else:
                walk(a[k], b[k], f"{path + '.' if path else ''}{k}")
        return
    if isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            out.append(f"{path}: length {len(a)} -> {len(b)}")
            return
        for i, (x, y) in enumerate(zip(a, b)):
            walk(x, y, f"{path}[{i}]")
        return
    if a != b:
        out.append(f"{path}: {a} -> {b}")
walk(doc[sys.argv[2]], doc[sys.argv[3]], "")
print("\n".join(sorted(out)) if out else "IDENTICAL")
PY
}

assert_eq "the patch requires exactly one extra config key, named" "collectExecutionSteps" \
  "$(python3 -c 'import json,sys; print(",".join(json.loads(sys.argv[1])["declaredKeys"]))' "$ENC")"
assert_true "and the two encodings are different byte strings, so there is something to compare" \
  test "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["upstreamBytes"])' "$ENC")" \
    -ne "$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(d["patchedBytes"])' "$ENC")"

CLEAN_DELTA="$(delta upstream patched)"
printf '%s\n' "$CLEAN_DELTA" | sed 's/^/      /'
assert_eq "the whole difference between upstream's encoding and the shipped module's is the one declared key" \
  "config.collectExecutionSteps: present on the right only" "$CLEAN_DELTA"

# THE FAULT INJECTION the file says exists for this. A second key must make the delta GROW —
# otherwise "the delta is exactly one key" is an assertion that could not have failed.
INJECTED_DELTA="$(delta upstream injectedPatched)"
printf '%s\n' "$INJECTED_DELTA" | sed 's/^/      /'
assert_eq "a second, undeclared key makes the computed delta grow rather than riding along" "2" \
  "$(printf '%s\n' "$INJECTED_DELTA" | grep -c .)"
assert_ge "and the injected key is named in it, so the walk found THAT key and not some other move" 1 \
  "$(printf '%s\n' "$INJECTED_DELTA" | grep -c 'config.m20ProbeSecondKey: present on the right only')"

# The control in the other direction: comparing a decoding with itself must find nothing, or
# "IDENTICAL" is not a value this comparison can produce.
assert_eq "and comparing an encoding with itself finds nothing at all" "IDENTICAL" \
  "$(delta patched patched)"

finish
