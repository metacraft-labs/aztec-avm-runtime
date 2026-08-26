#!/usr/bin/env bash
# test_receipt_declares_no_proving — §8.4, and the claim that it cannot be silenced.
#
# The verification entry: "Every receipt carries simulated, the pinned protocol version and proving
# 'none', and the create-time disclosure cannot be suppressed."
#
# WHY THIS IS THE HONESTY SURFACE. Somebody will eventually point this runtime at something that
# matters. The disclosure is what stops that being our fault, and a disclosure that lives in a
# README is one the second reader never sees — so it travels on the RECEIPT, which is the object a
# caller logs, stores and shows to somebody else.
#
# "CANNOT BE SUPPRESSED" IS AN OVERSTATEMENT UNLESS IT IS DEFINED, and this check defines it by
# measuring three separate things rather than by asserting the sentence:
#
#   1. there is no option, flag or argument that turns it OFF — `disclosureSink` REDIRECTS;
#   2. a runtime created with a DISCARDING sink still carries the record, which is the control
#      that distinguishes "the caller chose not to display it" from "the runtime never disclosed";
#   3. the three receipt fields are LITERAL TYPES in the source, so a receipt that said otherwise
#      would not type-check.
#
# THE VERSION IS NOT TYPED HERE. It is read out of `pins.json` — the single authority — and
# `disclosure.ts` is registered in `npm_pin_witnesses` so `repin.py --check` requires the two to
# agree. A version typed into this check would be a constant that looks like a measurement, and
# would go stale in exactly the way the witness mechanism exists to prevent.
#
# Run: just verify-chain-disclosure

TEST_NAME="test_receipt_declares_no_proving"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_arms

# ---------------------------------------------------------------------------
# PART 1 — the version comes from pins.json
# ---------------------------------------------------------------------------
echo "== the pinned protocol version is pins.json's, not a literal in a check"

PIN="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm"]["deletion_era"]["version"])' "$REPO_ROOT/pins.json")"
assert_true "pins.json names the deletion_era npm pin" test -n "$PIN"
assert_true "…and it looks like a nightly version" str_has_re "$PIN" '^[0-9]+\.[0-9]+\.[0-9]+-nightly\.[0-9]{8}$'

# The consumer this package IS. If `orchestration` were moved to another pin, this check would
# start comparing against the wrong one, so the mapping is read rather than assumed.
CONSUMER="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm_consumers"]["orchestration"])' "$REPO_ROOT/pins.json")"
assert_eq "orchestration is on the deletion_era pin" "deletion_era" "$CONSUMER"

WITNESS="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm_pin_witnesses"].get("orchestration/src/disclosure.ts", "ABSENT"))' \
  "$REPO_ROOT/pins.json")"
assert_eq "disclosure.ts is a declared pin witness for that same pin" "deletion_era" "$WITNESS"

# ---------------------------------------------------------------------------
# PART 2 — the receipt
# ---------------------------------------------------------------------------
echo "== every receipt carries the three fields"

assert_eq "the receipt says simulated" "true" "$(m23_arm disclosure receipt.simulated)"
assert_eq "…and names the pinned protocol version" "$PIN" "$(m23_arm disclosure receipt.protocolVersion)"
assert_eq "…and says proving: none" "none" "$(m23_arm disclosure receipt.proving)"

echo "== including a receipt re-read after the block landed"
assert_eq "the settled receipt says simulated" "true" "$(m23_arm disclosure settledReceipt.simulated)"
assert_eq "…names the same version" "$PIN" "$(m23_arm disclosure settledReceipt.protocolVersion)"
assert_eq "…and still says proving: none" "none" "$(m23_arm disclosure settledReceipt.proving)"
# AND THE RECEIPT MOVED, so the two are not the same object read twice.
assert_eq "the first receipt was queued" "queued" "$(m23_arm disclosure receipt.outcomeKind)"
assert_eq "…and the re-read one is processed" "processed" "$(m23_arm disclosure settledReceipt.outcomeKind)"
assert_eq "…in block 1" "1" "$(m23_arm disclosure settledReceipt.blockNumber)"

echo "== and a dry run carries them too"
assert_eq "simulateTx's result says simulated" "true" "$(m23_arm disclosure simulation.simulated)"
assert_eq "…names the pinned version" "$PIN" "$(m23_arm disclosure simulation.protocolVersion)"
assert_eq "…and says proving: none" "none" "$(m23_arm disclosure simulation.proving)"

# ---------------------------------------------------------------------------
# PART 3 — the create-time disclosure
# ---------------------------------------------------------------------------
echo "== one line at create time, naming the version and the absence of proofs"

SPOKEN="$(m23_arm disclosure spoken)"
N_SPOKEN="$(python3 - "$M23_ARMS" <<'PY'
import json, sys
print(len(json.load(open(sys.argv[1]))["arms"]["disclosure"]["spoken"]))
PY
)"
assert_eq "exactly one line was written to the sink" "1" "$N_SPOKEN"
LINE="$(python3 - "$M23_ARMS" <<'PY'
import json, sys
print(json.load(open(sys.argv[1]))["arms"]["disclosure"]["spoken"][0])
PY
)"
assert_true "the line names the pinned version" str_has_sub "$LINE" "$PIN"
assert_true "…and states that no proofs are produced" str_has_sub "$LINE" "NO PROOFS"
assert_true "…and says the runtime is simulated" str_has_sub "$LINE" "SIMULATED"
assert_true "…and says proving: none" str_has_sub "$LINE" "proving: none"
# A CONTROL for those needles: a phrase the line does not contain is not found by the same lookup.
assert_false "a phrase the line does not carry is not found" str_has_sub "$LINE" "PROOFS ARE VERIFIED"

echo "== THE CONTROL: a discarding sink redirects it and does not suppress the record"
assert_eq "the silent runtime's record says simulated" "true" \
  "$(m23_arm disclosure silentDisclosure.simulated)"
assert_eq "…names the pinned version" "$PIN" "$(m23_arm disclosure silentDisclosure.protocolVersion)"
assert_eq "…says proving: none" "none" "$(m23_arm disclosure silentDisclosure.proving)"
assert_eq "…records that it disclosed at create time" "create" \
  "$(m23_arm disclosure silentDisclosure.disclosedAt)"
assert_eq "…and carries the same line, verbatim" "$LINE" \
  "$(m23_arm disclosure silentDisclosure.line)"

# ---------------------------------------------------------------------------
# PART 4 — there is no way to turn it off, and the types say so
# ---------------------------------------------------------------------------
echo "== no option turns it off, and the fields are literal types"

RUNTIME="$(cat "$ORCH_SRC/avm_runtime.ts")"
DISC="$(cat "$ORCH_SRC/disclosure.ts")"

assert_true "the receipt's simulated field is the literal true" \
  str_has_sub "$RUNTIME" "readonly simulated: true;"
assert_true "…and its proving field is the literal 'none'" \
  str_has_sub "$RUNTIME" "readonly proving: 'none';"
assert_true "the disclosure record's fields are literal too" \
  str_has_sub "$DISC" "readonly simulated: true;"

# The OPTIONS type has exactly two fields and neither disables anything.
OPTS="$(awk '/^export interface AvmRuntimeOptions/,/^}/' "$ORCH_SRC/avm_runtime.ts")"
assert_ge "the options interface was extracted" 5 "$(printf '%s\n' "$OPTS" | grep -c .)"
assert_false "there is no 'disclose' boolean" str_has_sub "$OPTS" "disclose?:"
assert_false "there is no 'quiet' option" str_has_sub "$OPTS" "quiet"
assert_false "there is no 'silent' option" str_has_sub "$OPTS" "silent"
assert_true "…and the only disclosure-related option is the SINK" str_has_sub "$OPTS" "disclosureSink?:"

# THE DISCLOSURE IS IN THE CONSTRUCTOR AND NOT IN `create`, AND THAT IS WHAT MAKES IT
# UNSUPPRESSIBLE RATHER THAN MERELY UNDOCUMENTED. See PART 5 for the measurement that moved it.
# It writes to the sink UNCONDITIONALLY — no branch guards it — and the default is `console.warn`
# and not a no-op.
CTOR="$(awk '/^  private constructor\(/,/^  }/' "$ORCH_SRC/avm_runtime.ts")"
assert_ge "the constructor body was extracted" 8 "$(printf '%s\n' "$CTOR" | grep -c .)"
assert_true "the constructor calls the sink" str_has_sub "$CTOR" "sink(this.disclosure.line);"
assert_false "…and no branch guards that call" str_has_line_re "$CTOR" '^ *if .*sink'
assert_true "…and the default sink is console.warn, not a no-op" \
  str_has_sub "$CTOR" "console.warn(l)"

# THE MUTATION CONTROL, run rather than described: a runtime built with a sink that throws still
# discloses, because the record is not the sink. This is the one that would catch a `create` that
# recorded the disclosure only when the sink succeeded.
THROWS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { AvmRuntime } from "./src/avm_runtime.ts";
const deps = { merkleDb: {}, contractsDb: {}, makeProcessor: () => ({}), simulator: {}, publicDataTree: {} };
try {
  const r = AvmRuntime.create(deps, { disclosureSink: () => { throw new Error("sink refused"); } });
  console.log("NO-THROW " + r.disclosure.proving);
} catch (e) {
  console.log("THREW " + e.message);
}
' 2>&1 | tail -1)"
# A sink that throws propagates — the runtime is not constructed. That is the RIGHT behaviour and
# it is the opposite of suppression: a caller cannot get a runtime by breaking the disclosure.
assert_eq "a sink that refuses does not yield an undisclosed runtime" "THREW sink refused" "$THROWS"

# ---------------------------------------------------------------------------
# PART 5 — THE ROUTE THIS CHECK DID NOT TAKE, AND IT WAS OPEN
# ---------------------------------------------------------------------------
echo "== the constructor is reachable, and it discloses too"

# `private constructor` IS A TYPESCRIPT ANNOTATION AND NOTHING ELSE. This package runs its `.ts`
# sources under Node's type stripping, which erases it, and `AvmRuntime` is a public export of
# `index.ts` — so `new AvmRuntime(...)` is reachable in the language the runtime actually executes
# in. Everything above went through `create()`, and while the disclosure lived in `create()` this
# route produced a working runtime with NO line written and a FORGED `disclosure` record —
# `simulated: false`, `proving: 'groth16'` — which is the object every assertion above treats as
# the evidence that a disclosure was made. Measured by M23's review, on the shipped source.
#
# The disclosure is the constructor's first act now, so the route is closed rather than
# undocumented. It is EXERCISED here rather than asserted, because "the constructor discloses" read
# out of the source is the shape this campaign has a name for.
BYPASS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { AvmRuntime } from "./src/avm_runtime.ts";
const deps = { merkleDb: {}, contractsDb: {}, makeProcessor: () => ({}), simulator: {}, publicDataTree: {} };
const spoken = [];
// The third argument is what the factory used to pass. A caller supplying a forged one must not be
// able to make it the record.
const forged = { simulated: false, protocolVersion: "NOT-PINNED", proving: "groth16", line: "", disclosedAt: "never" };
const r = new (AvmRuntime)(deps, { disclosureSink: l => spoken.push(l) }, forged);
console.log("LINES " + spoken.length);
console.log("SIMULATED " + r.disclosure.simulated);
console.log("VERSION " + r.disclosure.protocolVersion);
console.log("PROVING " + r.disclosure.proving);
console.log("SAMELINE " + (spoken[0] === r.disclosure.line));
' 2>&1 | tail -5)"
assert_eq "constructing the class directly writes exactly one disclosure line" "LINES 1" \
  "$(printf '%s\n' "$BYPASS" | sed -n 1p)"
assert_eq "…and the record is the real one, not the caller's" "SIMULATED true" \
  "$(printf '%s\n' "$BYPASS" | sed -n 2p)"
assert_eq "…naming the pinned version rather than the forged one" "VERSION $PIN" \
  "$(printf '%s\n' "$BYPASS" | sed -n 3p)"
assert_eq "…and saying proving: none rather than the forged one" "PROVING none" \
  "$(printf '%s\n' "$BYPASS" | sed -n 4p)"
assert_eq "…and the line written is the line recorded" "SAMELINE true" \
  "$(printf '%s\n' "$BYPASS" | sed -n 5p)"

m23_finish
