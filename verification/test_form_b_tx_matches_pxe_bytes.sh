#!/usr/bin/env bash
# test_form_b_tx_matches_pxe_bytes — M21.
#
#   verification/test_form_b_tx_matches_pxe_bytes.sh   (or: just verify-form-b-pxe-bytes)
#
# ============================================================================================
# THE ENTRY, AND THE TWO REASONS IT WAS PENDING — ONE OF WHICH TURNED OUT NOT TO BE A REASON.
# ============================================================================================
#
# *"For the same request and inputs, the Tx the runtime builds is byte-identical to the one PXE
# builds."* The recorded blocker, re-measured by the closeout pass on 2026-08-31, was in two parts:
#
#   1. `generateSimulatedProvingResult` — step 2 of §5.4's pipeline — "appears in this tree at FIVE
#      sites and every one of them is a COMMENT, with no definition and no call";
#   2. "there is still no PXE-built Tx fixture to compare against; the existing comparison is
#      against upstream's own `mockTx`, which is a different question".
#
# **The first is true and stays true: this runtime does not have step 2 and does not vendor it.**
# The second was a statement about what nobody had built, and it is what this check builds.
#
# `@aztec/pxe` publishes `generateSimulatedProvingResult` from `@aztec/pxe/simulator`. It cannot go
# anywhere near `orchestration/` — it hard-depends on `@aztec/simulator`, which hard-depends on
# `@aztec/native` and `@aztec/world-state`, and DD-9 forbids all three — so it is installed in
# `pxe-ref/`, a tree nothing ships, exactly as `diffsim/`, `spike/`, `drift/` and `probe-mt/`
# install what the shipped graph must not reach. §1 asserts that separation in both directions.
#
# ============================================================================================
# WHAT CROSSES BETWEEN THE TWO HALVES, AND IN WHICH DIRECTION.
# ============================================================================================
#
# Two processes, two `@aztec/stdlib` INSTALLS. A value built from one and handed to the other
# serialises as a plain object the receiver either rejects or — worse — decodes into something
# plausible; the hazard is documented at `diffsim/src/…/encode_inputs.ts:22-42` and
# `lib_m21_form_b.sh` records it too. So:
#
#   * the INPUTS cross as VALUES — a first nullifier and a list of calldata fields, from which each
#     half builds its own `PrivateExecutionResult` with its own install's classes;
#   * the TAIL crosses as BYTES — `PrivateKernelTailCircuitPublicInputs.toBuffer()` out of PXE,
#     `fromBuffer` into ours, because step 2 is the step this runtime does not have;
#   * the OUTPUTS cross as BYTES — `Tx.toBuffer()` on both sides, compared by sha256, and by
#     transaction hash beside it.
#
# ============================================================================================
# AND THE EQUALITY IS MADE FALSIFIABLE FOUR WAYS, BECAUSE IT WOULD OTHERWISE READ AS A TAUTOLOGY.
# ============================================================================================
#
# Both halves call the same upstream `toSimulatedTx`, so "the bytes agree" is a claim that needs
# every one of its inputs shown to matter:
#
#   * the comparer CAN report a difference — our transaction built from the OTHER case's tail is
#     compared against PXE's and must differ;
#   * the tail matters — PXE's own two cases differ from each other, and neither is the EMPTY tail;
#   * the calldata matters — our transaction built with an EMPTY calldata list is compared against
#     PXE's and must differ;
#   * and the node was NOT consulted, with the stub shown to count when it IS.
#
# Run: just verify-form-b-pxe-bytes

TEST_NAME="test_form_b_tx_matches_pxe_bytes"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m21_form_b.sh"

summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m21_prepare

PXE_REF="$REPO_ROOT/pxe-ref"
REF_JSON="$M21_WORK/pxe-reference.json"
REF_TIMEOUT="${M21_PXE_REF_TIMEOUT:-600}"

# ---------------------------------------------------------------------------
echo "== 0. the reference tree, and the reference it produces"
# ---------------------------------------------------------------------------

assert_dir "the PXE reference tree is in this repository" "$PXE_REF"
assert_file "…with its own manifest" "$PXE_REF/package.json"
assert_file "…its own lockfile, so the reference is pinned rather than resolved" "$PXE_REF/package-lock.json"
assert_file "…and the producer" "$PXE_REF/src/build_reference_tx.mjs"
[ -d "$PXE_REF/node_modules/@aztec/pxe" ] || die "the PXE reference tree's packages are not installed.
             Remedy: cd $PXE_REF && npm ci
             A skip reported as a pass would be worse than this failure."
assert_dir "…and its packages are installed" "$PXE_REF/node_modules/@aztec/pxe"

# THE PIN IS READ FROM `pins.json` AND COMPARED WITH WHAT IS ON DISK. A reference built against a
# different protocol version would be a comparison of two protocols, and it would look like this
# check passing or failing for a reason that has nothing to do with the seam.
DECLARED_PIN="$(python3 -c 'import json;print(json.load(open("pins.json"))["npm"]["deletion_era"]["version"])')"
assert_prefix "pins.json declares a deletion-era nightly" "5." "$DECLARED_PIN"
for pkg in pxe stdlib; do
  assert_eq "the installed @aztec/$pkg in the reference tree is that pin" "$DECLARED_PIN" \
    "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
        "$PXE_REF/node_modules/@aztec/$pkg/package.json")"
done
assert_eq "…and orchestration's @aztec/stdlib is the SAME pin, so the two halves are comparable" \
  "$DECLARED_PIN" \
  "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["version"])' \
      "$REPO_ROOT/orchestration/node_modules/@aztec/stdlib/package.json")"

# THE PRODUCER RUNS HERE, BOUNDED. A check that waits forever reports nothing at all and blocks the
# sweep behind it; `|| rc=$?` rather than `if …; then`, and no `--preserve-status`, so a hang comes
# back as 124 and not as the command's own status.
rm -f "$REF_JSON"
REF_RC=0
( cd "$PXE_REF" && timeout "$REF_TIMEOUT" node src/build_reference_tx.mjs "$REF_JSON" ) \
  >"$M21_WORK/pxe-reference.out" 2>"$M21_WORK/pxe-reference.err" || REF_RC=$?
if [ "$REF_RC" = "124" ] || [ "$REF_RC" = "137" ]; then
  die "the PXE reference producer exceeded its ${REF_TIMEOUT}s bound (rc $REF_RC). That is a HANG
             and not a failure; see $M21_WORK/pxe-reference.err"
fi
[ "$REF_RC" = "0" ] || die "the PXE reference producer exited $REF_RC; see $M21_WORK/pxe-reference.err"
assert_eq "the reference producer exited 0" "0" "$REF_RC"
assert_file "…and wrote its reference" "$REF_JSON"

ref() { python3 - "$REF_JSON" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1], encoding="utf-8"))
for key in sys.argv[2].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    else:
        print("MISSING"); raise SystemExit(0)
if isinstance(node, bool):
    print("true" if node else "false")
elif isinstance(node, (dict, list)):
    print(json.dumps(node, separators=(",", ":")))
else:
    print(node)
PY
}
assert_eq "a field that is not in the reference reads MISSING" "MISSING" "$(ref cases.noSuchCase)"
note "reference: @aztec/pxe $(ref pxeVersion), node $(ref node)"

# ---------------------------------------------------------------------------
echo "== 1. the reference is UPSTREAM'S PXE, and it is nowhere near the shipped graph"
# ---------------------------------------------------------------------------

PRODUCER_SRC="$(cat "$PXE_REF/src/build_reference_tx.mjs")"
# THE IMPORT, NOT A MENTION. Whole-line comments are stripped first, because this file's own header
# names the function repeatedly and a citation is the opposite of a dependency.
PRODUCER_CODE="$(grep -v '^[[:space:]]*//' "$PXE_REF/src/build_reference_tx.mjs")"
assert_ge "the comment stripper left code behind" 30 "$(printf '%s\n' "$PRODUCER_CODE" | grep -c . || true)"
assert_true "…and removed the prose" \
  test "$(printf '%s\n' "$PRODUCER_CODE" | grep -c . || true)" -lt "$(printf '%s\n' "$PRODUCER_SRC" | grep -c . || true)"
assert_true "the producer IMPORTS generateSimulatedProvingResult from @aztec/pxe" \
  str_has_sub "$PRODUCER_CODE" "import { generateSimulatedProvingResult } from '@aztec/pxe/simulator';"
assert_true "…and it is a real export of the installed package" \
  str_has_sub "$(cat "$PXE_REF/node_modules/@aztec/pxe/dest/contract_function_simulator/index.js")" \
  'export { generateSimulatedProvingResult }'

# DD-9 IS UNTOUCHED, IN BOTH DIRECTIONS. The shipped package declares none of the three and has none
# installed; the reference tree has them. An absence asked of a tree that could not contain the
# subject is this campaign's oldest recorded defect, so the same predicate is asked of both trees.
for pkg in '@aztec/pxe' '@aztec/simulator' '@aztec/native' '@aztec/world-state'; do
  assert_eq "orchestration declares no $pkg" "0" \
    "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
name = sys.argv[2]
print(sum(1 for f in ("dependencies","devDependencies","optionalDependencies","peerDependencies")
          if name in (d.get(f) or {})))' "$REPO_ROOT/orchestration/package.json" "$pkg")"
  assert_false "…and none is installed under orchestration/node_modules" \
    test -d "$REPO_ROOT/orchestration/node_modules/$pkg"
done
# THE PAIRED POSITIVE: the same two predicates, asked of the reference tree, answer YES.
assert_eq "the reference tree DECLARES @aztec/pxe, so the absences above are measurements" "1" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for f in ("dependencies","devDependencies","optionalDependencies","peerDependencies")
          if "@aztec/pxe" in (d.get(f) or {})))' "$PXE_REF/package.json")"
assert_dir "…and @aztec/simulator really is in its tree, which is why it is a separate one" \
  "$PXE_REF/node_modules/@aztec/simulator"
assert_dir "…with the native addon DD-9 forbids the shipped graph" \
  "$PXE_REF/node_modules/@aztec/native"

# ---------------------------------------------------------------------------
echo "== 2. the tail PXE produced is a real tail, and it moves with its input"
# ---------------------------------------------------------------------------

assert_eq "step 2 produced upstream's own type" "PrivateKernelTailCircuitPublicInputs" \
  "$(ref cases.primary.tail.class)"
assert_ge "…of a substantial size rather than a stub" 10000 "$(ref cases.primary.tail.bytes)"
EMPTY_TAIL="$(ref emptyTailSha256)"
assert_true "…and it is NOT the empty tail, so step 2 did something" \
  test "$(ref cases.primary.tail.sha256)" != "$EMPTY_TAIL"
assert_true "the two cases' tails differ, so the tail is a function of its input" \
  test "$(ref cases.primary.tail.sha256)" != "$(ref cases.variant.tail.sha256)"
assert_true "…and so do the transactions built from them" \
  test "$(ref cases.primary.tx.sha256)" != "$(ref cases.variant.tx.sha256)"
assert_true "the calldata case differs from the no-calldata case too" \
  test "$(ref cases.primary.tx.sha256)" != "$(ref cases.noCalldata.tx.sha256)"
assert_eq "the primary case carries public calldata" "1" "$(ref cases.primary.publicCalldataCount)"
assert_eq "…and the no-calldata case carries none" "0" "$(ref cases.noCalldata.publicCalldataCount)"

# The node stub, and its own positive control. A counter wired to nothing reads zero, and so does a
# stub nobody could have called.
assert_eq "the node was not consulted while the reference was built" "0" "$(ref nodeConsulted)"
assert_eq "…and the same stub counts when it IS called" "1" "$(ref nodeConsultedAfterProbe)"
assert_prefix "…by throwing, which is what makes an unconsulted node a measurement" "threw:" \
  "$(ref nodeProbe)"

# ---------------------------------------------------------------------------
echo "== 3. THE HEADLINE: this runtime's Tx is byte-identical to PXE's"
# ---------------------------------------------------------------------------
#
# The probe runs in `orchestration/`'s own import graph — no `@aztec/pxe`, no `@aztec/simulator` —
# rebuilds the SAME input from the reference's own values, deserialises PXE's tail from bytes, and
# calls this runtime's `txFromTail`.

OURS_FILE="$M21_WORK/probes/form_b_pxe_bytes.out"
m21_probe form_b_pxe_bytes "$(cat <<EOF
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import { Fr } from '@aztec/foundation/curves/bn254';
import { PrivateCircuitPublicInputs, PrivateKernelTailCircuitPublicInputs } from '@aztec/stdlib/kernel';
import { HashedValues } from '@aztec/stdlib/tx';
$(m21_imports)

const line = (k, v) => console.log(k, v);
const sha = b => createHash('sha256').update(b).digest('hex');
const ref = JSON.parse(readFileSync('$REF_JSON', 'utf8'));

async function ours(argFields, firstNullifier, tailHex) {
  const calldata = argFields.length === 0
    ? []
    : [await HashedValues.fromArgs(argFields.map(v => new Fr(BigInt(v))))];
  const privateResult = publicOnlyPrivateExecution(
    PrivateCircuitPublicInputs.empty(), new Fr(BigInt(firstNullifier)), calldata);
  const tail = PrivateKernelTailCircuitPublicInputs.fromBuffer(Buffer.from(tailHex, 'hex'));
  const tx = await txFromTail(privateResult, tail);
  return { tx, buf: tx.toBuffer(), privateResult };
}

for (const [name, c] of Object.entries(ref.cases)) {
  const r = await ours(c.publicCalldataArgFields, c.firstNullifier, c.tail.hex);
  line(\`ours.\${name}.class\`, r.tx.constructor.name);
  line(\`ours.\${name}.bytes\`, r.buf.length);
  line(\`ours.\${name}.sha256\`, sha(r.buf));
  line(\`ours.\${name}.hash\`, (await r.tx.getTxHash()).toString());
  line(\`ours.\${name}.firstNullifier\`, r.privateResult.firstNullifier.toString());
  line(\`ours.\${name}.calldataCount\`, r.privateResult.publicFunctionCalldata.length);
  // The tail this half deserialised, re-serialised: if \`fromBuffer\` lost anything, the bytes it
  // gives back are not the bytes it was handed and every comparison below would be about that.
  line(\`ours.\${name}.tailRoundTrip\`,
    sha(PrivateKernelTailCircuitPublicInputs.fromBuffer(Buffer.from(c.tail.hex, 'hex')).toBuffer()));
}

// THE CONTROL: the primary input against the VARIANT's tail. Same seam, same install, one changed
// input — the comparison must come out different, or "byte-identical" is a property of the comparer.
const crossed = await ours(
  ref.cases.primary.publicCalldataArgFields, ref.cases.primary.firstNullifier, ref.cases.variant.tail.hex);
line('control.crossedTail.sha256', sha(crossed.buf));

// THE SECOND CONTROL: the primary tail with the calldata DROPPED, which is what a seam that forgot
// to carry \`publicFunctionCalldata\` would produce.
const noArgs = await ours([], ref.cases.primary.firstNullifier, ref.cases.primary.tail.hex);
line('control.droppedCalldata.sha256', sha(noArgs.buf));

console.log('formB.done');
EOF
)" >"$OURS_FILE"
OURS_RC=$?
OURS_ERR="$(m21_probe_err form_b_pxe_bytes)"
[ "$OURS_RC" = "0" ] || die "the orchestration-side probe exited $OURS_RC; see $OURS_ERR"
assert_eq "the orchestration-side probe exited 0" "0" "$OURS_RC"
# THE TRANSCRIPT IS REFUSED IF IT IS SHORT, through `lib.sh`'s one implementation. D19's V8/WASI
# stdout truncation would otherwise turn a partial transcript into a set of digest comparisons
# against absent fields — and `verify_transcript_truncation_detection_uniform`'s census exists so
# that a new probe-driving check joins the REACHING set rather than the backlog.
require_complete_transcript "$OURS_FILE" formB.done "the Form B / PXE probe's"
OURS="$(cat "$OURS_FILE")"
assert_true "the probe ran to its own sentinel" str_has_line "$OURS" "formB.done"
o() { m21_field "$OURS_FILE" "$1"; }

for c in primary variant noCalldata; do
  assert_eq "$c: this runtime's seam produced a Tx" "Tx" "$(o "ours.$c.class")"
  assert_eq "$c: it rebuilt the reference's own first nullifier" \
    "$(ref "cases.$c.firstNullifier")" "$(o "ours.$c.firstNullifier")"
  assert_eq "$c: and the reference's own public calldata count" \
    "$(ref "cases.$c.publicCalldataCount")" "$(o "ours.$c.calldataCount")"
  assert_eq "$c: the tail survived the byte crossing unchanged" \
    "$(ref "cases.$c.tail.sha256")" "$(o "ours.$c.tailRoundTrip")"
  # ---- the entry's own sentence ----
  assert_eq "$c: THE TRANSACTION IS BYTE-IDENTICAL TO THE ONE PXE BUILT" \
    "$(ref "cases.$c.tx.sha256")" "$(o "ours.$c.sha256")"
  assert_eq "$c: …to the byte count as well as the digest" \
    "$(ref "cases.$c.tx.bytes")" "$(o "ours.$c.bytes")"
  assert_eq "$c: …and the two transaction hashes agree" \
    "$(ref "cases.$c.tx.hash")" "$(o "ours.$c.hash")"
done

# ---------------------------------------------------------------------------
echo "== 4. THE COMPARER CAN SAY NO, twice, in two different ways"
# ---------------------------------------------------------------------------

assert_true "our Tx from the OTHER case's tail differs from PXE's primary" \
  test "$(o control.crossedTail.sha256)" != "$(ref cases.primary.tx.sha256)"
assert_eq "…and equals PXE's transaction for the tail it was actually given" \
  "$(ref cases.variant.tx.sha256)" "$(o control.crossedTail.sha256)"
assert_true "our Tx with the public calldata DROPPED differs from PXE's" \
  test "$(o control.droppedCalldata.sha256)" != "$(ref cases.primary.tx.sha256)"
# AND IT DIFFERS FROM PXE'S NO-CALLDATA CASE TOO, WHICH IS NOT THE OBVIOUS ANSWER AND IS WHY THIS
# ASSERTION IS HERE RATHER THAN AN EQUALITY. The first draft asserted the equality and it went red:
# a `Tx` is decided by its TAIL as well as by its calldata, and PXE's no-calldata case was built
# from an execution with no calldata, so its tail is a different tail. Dropping the calldata on OUR
# side while keeping the PRIMARY tail is a third transaction — which is exactly the state a seam
# that forgot to carry `publicFunctionCalldata` would produce, and neither of PXE's two answers.
assert_true "…and from PXE's no-calldata case as well, because that case has a different TAIL" \
  test "$(o control.droppedCalldata.sha256)" != "$(ref cases.noCalldata.tx.sha256)"
assert_true "…while the two tails really are different, which is what makes that true" \
  test "$(ref cases.primary.tail.sha256)" != "$(ref cases.noCalldata.tail.sha256)"

# ---------------------------------------------------------------------------
echo "== 5. THE DIVERGENCE form_b.ts DOCUMENTS, measured rather than quoted"
# ---------------------------------------------------------------------------
#
# `form_b.ts` records that TWO of upstream's three call sites do NOT go through
# `PrivateSimulationResult`: TXE and `wallet-sdk` inline `Tx.create({ …, contractClassLogFields: []
# })` where `toSimulatedTx` passes `collectSortedContractClassLogs(privateExecutionResult)`, and
# says the difference is real for a transaction that published a contract class. The reference
# builds BOTH forms, and for these inputs they agree — because a public-only execution emits no
# contract-class log, so both lists are empty. That is recorded as a measurement, so the document's
# sentence is not read as "always differs".

assert_eq "for a public-only execution the inlined form equals toSimulatedTx" "true" \
  "$(ref cases.primary.inlined.equalsToSimulatedTx)"
assert_eq "…and this runtime matches both, because the two are one transaction here" \
  "$(ref cases.primary.inlined.sha256)" "$(o ours.primary.sha256)"
assert_true "…and the fact is a fact about the INPUT: form_b.ts says which field differs" \
  str_has_sub "$(cat "$REPO_ROOT/orchestration/src/form_b.ts")" 'contractClassLogFields'
assert_true "…and which two upstream call sites inline it" \
  str_has_sub "$(cat "$REPO_ROOT/orchestration/src/form_b.ts")" 'wallet-sdk inlines it the same way'

# ---------------------------------------------------------------------------
echo "== 6. the entry's OTHER half is still true, and it is asserted rather than quoted"
# ---------------------------------------------------------------------------
#
# Step 2 is NOT in this repository. That was the load-bearing half of the recorded blocker and it
# has not changed: what changed is that upstream's own step 2 is now RUN, in a tree nothing ships,
# so the seam this runtime does have can be compared against it.

SHIPPED_CODE="$(cat "$REPO_ROOT/orchestration/src"/*.ts "$REPO_ROOT/browser/src"/*.ts | grep -v '^[[:space:]]*[/*]')"
assert_ge "the shipped-source scan has code to look at" 500 \
  "$(printf '%s\n' "$SHIPPED_CODE" | grep -c . || true)"
assert_false "no shipped source DEFINES or CALLS generateSimulatedProvingResult" \
  str_has_sub "$SHIPPED_CODE" 'generateSimulatedProvingResult'
assert_true "…and the scanner can find it, shown on the reference producer's own code" \
  str_has_sub "$PRODUCER_CODE" 'generateSimulatedProvingResult'
assert_true "form_b.ts still says step 2 is not here, and why" \
  str_has_sub "$(cat "$REPO_ROOT/orchestration/src/form_b.ts")" 'Steps 1 and 2 are NOT here'

finish
