#!/usr/bin/env bash
# test_fee_juice_debited_and_insufficiency_throws — M20, DD-2.
#
# The deliverable: "Fee payment through computeFeePayerBalanceStorageSlot. DD-2:
# skipFeeEnforcement defaults to *false*, with fundFeeJuice(address, amount) as the declared
# genesis-style shortcut."
#
# THREE CLAIMS, AND THE FIRST TWO ARE ABOUT AGREEMENT RATHER THAN ABOUT US.
#
#   1. THE SLOT. The AVM reads a balance at a slot it derives in C++; we write one at a slot we
#      derive in TypeScript. If the two derivations disagree, funding writes a leaf nothing reads
#      and every fee test fails for a reason that looks like a fee bug. So the TypeScript
#      composition is compared against upstream's own published composite AND both C++
#      derivations are pinned by reading them out of the anchor.
#   2. THE DEFAULT. `skipFeeEnforcement` is read off a constructed `PublicSimulatorConfig` rather
#      than quoted from a comment, and the C++ mirror is read out of the anchor. A default that
#      drifted to `true` would make every fee test pass while enforcing nothing — which is the
#      exact shape of the "printed literal" defect this campaign has met.
#   3. THE BEHAVIOUR, THROUGH THE MODULE. A funded payer is debited by exactly the reported fee;
#      an unfunded one is thrown out with `feePayerInsufficientBalance`. Two arms of the same
#      transaction — same seed, same calls, same globals — differing only in whether
#      `fundFeeJuice` ran.
#
# WHY THE UNFUNDED ARM IS NOT MERELY "IT FAILED". It fails with a NAMED reason taken from the
# C++'s own message, and it fails as a REJECTION rather than as a revert: an insufficiently funded
# transaction does not land, does not get a revert code and does not pay a partial fee. A check
# that only asserted "the outcome differed" would pass against an engine that soft-reverted it.
#
# Run: just verify-form-a-fee

TEST_NAME="test_fee_juice_debited_and_insufficiency_throws"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m20_form_a.sh"

m20_require_anchor
m20_require_packages
mkdir -p "$M20_WORK"
SCRATCH="$(mktemp -d "$M20_WORK/fee.XXXXXX")" || die "no scratch under $M20_WORK"
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.m20_"*' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — the slot derivation, on both sides of the boundary
# ---------------------------------------------------------------------------

TXE="$SCRATCH/tx_execution.cpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/tx_execution.cpp > "$TXE"
FUZZDB="$SCRATCH/dbs.cpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/avm_fuzzer/common/interfaces/dbs.cpp > "$FUZZDB"
assert_ge "tx_execution.cpp was read from the anchor" 400 "$(wc -l < "$TXE")"
assert_ge "and the fuzzer's world-state manager, which is upstream's own genesis funder" 100 \
  "$(wc -l < "$FUZZDB")"

# What the AVM READS.
assert_ge "pay_fee derives the storage slot from DOM_SEP__PUBLIC_STORAGE_MAP_SLOT, FEE_JUICE_BALANCES_SLOT and the payer" 1 \
  "$(grep -c 'DOM_SEP__PUBLIC_STORAGE_MAP_SLOT, FEE_JUICE_BALANCES_SLOT, fee_payer' "$TXE")"
assert_ge "and reads the balance at FEE_JUICE_ADDRESS with it" 1 \
  "$(grep -c 'merkle_db.storage_read(FEE_JUICE_ADDRESS, fee_juice_balance_slot)' "$TXE")"
assert_ge "and writes back balance minus fee" 1 \
  "$(grep -c 'merkle_db.storage_write(FEE_JUICE_ADDRESS, fee_juice_balance_slot, fee_payer_balance - fee, true)' "$TXE")"

# What upstream's own genesis funder WRITES: the SILOED leaf slot, not the storage slot. Confusing
# the two is the wrong answer this whole part exists to exclude.
assert_ge "the fuzzer's funder derives the same storage slot" 1 \
  "$(grep -c 'DOM_SEP__PUBLIC_STORAGE_MAP_SLOT, FEE_JUICE_BALANCES_SLOT, fee_payer' "$FUZZDB")"
assert_ge "and then SILOES it with DOM_SEP__PUBLIC_LEAF_SLOT and FEE_JUICE_ADDRESS before inserting" 1 \
  "$(grep -c 'DOM_SEP__PUBLIC_LEAF_SLOT, FF(FEE_JUICE_ADDRESS), fee_juice_balance_slot' "$FUZZDB")"

# The control for those five greps: a derivation the C++ does NOT use must not be found.
assert_eq "a domain separator the C++ does not use here is not found by the same grep" "0" \
  "$(grep -c 'DOM_SEP__NOTE_HASH' "$TXE" || true)"

# The TypeScript half, executed. Our composition must equal upstream's published composite, and
# the storage slot must NOT equal the leaf slot — otherwise the siloing step is a no-op and the
# equality above proves nothing.
cat > "$ORCH_SRC/.m20_fee.mjs" <<'EOF'
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { Fr } from '@aztec/foundation/curves/bn254';
import {
  computeFeePayerBalanceLeafSlot, defaultPublicSimulatorConfig, feeJuiceBalanceLeafSlot,
  feeJuiceBalanceStorageSlot, fundFeeJuice,
} from './index.ts';

const addr = await AztecAddress.fromField(new Fr(0x1234567n));
const storage = await feeJuiceBalanceStorageSlot(addr);
const leaf = await feeJuiceBalanceLeafSlot(addr);
const upstream = await computeFeePayerBalanceLeafSlot(addr);

const writes = [];
const written = await fundFeeJuice({ insertPublicDataLeaf: (s, v) => writes.push([s.toString(), v.toString()]) }, addr, new Fr(999n));

let zeroRefused = 'accepted';
try {
  await fundFeeJuice({ insertPublicDataLeaf() {} }, AztecAddress.zero(), new Fr(1n));
} catch (e) {
  zeroRefused = 'refused';
}

console.log(JSON.stringify({
  storage: storage.toString(),
  leaf: leaf.toString(),
  upstream: upstream.toString(),
  writeCount: writes.length,
  writtenSlot: written.toString(),
  writtenAt: writes[0]?.[0] ?? null,
  writtenValue: writes[0]?.[1] ?? null,
  skipFeeEnforcementDefault: defaultPublicSimulatorConfig().skipFeeEnforcement,
  skipFeeEnforcementWhenAsked: defaultPublicSimulatorConfig({ skipFeeEnforcement: true }).skipFeeEnforcement,
  zeroRefused,
}));
EOF
FEE="$(cd "$ORCH_SRC" && node .m20_fee.mjs 2>&1 | tail -1)" || die "the fee probe failed: $FEE"
rm -f "$ORCH_SRC/.m20_fee.mjs"
printf '%s\n' "$FEE" | sed 's/^/      /'

field() { python3 -c '
import json, sys
d = json.loads(sys.argv[1])
v = d.get(sys.argv[2], "MISSING")
print("MISSING" if v is None else (str(v).lower() if isinstance(v, bool) else str(v)))' "$FEE" "$1"; }

assert_true "the probe produced a storage slot" test "$(field storage)" != "MISSING"
assert_eq "our leaf-slot composition equals upstream's published composite" \
  "$(field upstream)" "$(field leaf)"
assert_true "and the leaf slot is NOT the storage slot, so the siloing step does something" \
  test "$(field leaf)" != "$(field storage)"

# ---------------------------------------------------------------------------
# PART 2 — fundFeeJuice writes at the leaf slot, once, and refuses the zero address
# ---------------------------------------------------------------------------

assert_eq "fundFeeJuice performed exactly one write" "1" "$(field writeCount)"
assert_eq "at the LEAF slot" "$(field leaf)" "$(field writtenAt)"
assert_eq "and returned the slot it wrote" "$(field leaf)" "$(field writtenSlot)"
# `Fr.toString()` is 0x-prefixed 32-byte hex, so the amount is compared as a NUMBER. Comparing
# the string against "999" is how this assertion first failed, which is the right direction: a
# formatting difference must not be able to pass for an equal value.
assert_eq "with the amount asked for" "999" \
  "$(python3 -c 'import sys; print(int(sys.argv[1], 16))' "$(field writtenValue)")"
assert_eq "and it refuses the zero address, which the AVM never reads a balance for" "refused" \
  "$(field zeroRefused)"

# ---------------------------------------------------------------------------
# PART 3 — DD-2: the default is false, on both sides, and it is not a printed literal
# ---------------------------------------------------------------------------

assert_eq "skipFeeEnforcement defaults to FALSE, read off a constructed PublicSimulatorConfig" \
  "false" "$(field skipFeeEnforcementDefault)"
assert_eq "and it is genuinely settable, so the default is a choice rather than a constant" \
  "true" "$(field skipFeeEnforcementWhenAsked)"

AVMIO="$SCRATCH/avm_io.hpp"
m20_anchor_file barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp > "$AVMIO"
assert_ge "the C++ mirror declares the same default" 1 \
  "$(grep -c 'bool skip_fee_enforcement = false;' "$AVMIO")"
assert_ge "and it is on the wire, so the two sides cannot disagree silently" 1 \
  "$(grep -c 'skip_fee_enforcement,' "$AVMIO")"

# Both C++ branches exist: without the flag the two conditions are unrecoverable errors.
assert_ge "a zero fee payer is an unrecoverable error unless enforcement is skipped" 1 \
  "$(grep -c 'Fee payer cannot be 0 unless skipping fee enforcement for simulation' "$TXE")"
assert_ge "and so is an insufficient balance" 1 \
  "$(grep -c 'Not enough balance for fee payer to pay for transaction' "$TXE")"

# ---------------------------------------------------------------------------
# PART 4 — the module, run: debited when funded, thrown out when not
# ---------------------------------------------------------------------------

m20_require_arms

BEFORE="$(m20_arm appLogicOnlyFunded balanceBefore)"
AFTER="$(m20_arm appLogicOnlyFunded balanceAfter)"
FEE_HEX="$(m20_arm appLogicOnlyFunded external.transactionFee)"
FEE_DEC="$(python3 -c 'import sys; print(int(sys.argv[1], 16))' "$FEE_HEX")"
note "funded arm: $BEFORE -> $AFTER, fee $FEE_DEC"

assert_eq "the funded arm landed" "landed" "$(m20_arm appLogicOnlyFunded external.kind)"
assert_true "and paid a non-zero fee" test "$FEE_DEC" -gt 0
assert_eq "and was debited by exactly that" "$FEE_DEC" \
  "$(python3 -c 'import sys; print(int(sys.argv[1]) - int(sys.argv[2]))' "$BEFORE" "$AFTER")"

assert_eq "the SAME transaction unfunded is thrown out rather than landing" "rejected" \
  "$(m20_arm appLogicOnlyUnfunded external.kind)"
assert_eq "and names the C++'s own insufficient-balance error" "feePayerInsufficientBalance" \
  "$(m20_arm appLogicOnlyUnfunded external.reason)"
assert_eq "the unfunded arm had no balance leaf at all" "null" \
  "$(m20_arm appLogicOnlyUnfunded balanceBefore)"

# The pair really is the same transaction: same wire bytes, same phase split.
assert_eq "funded and unfunded are the same serialized transaction" \
  "$(m20_arm appLogicOnlyFunded shape.wireBytes)" "$(m20_arm appLogicOnlyUnfunded shape.wireBytes)"

finish
