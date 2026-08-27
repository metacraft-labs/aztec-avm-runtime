#!/usr/bin/env bash
# M26 verification: RI-72's reduced closure is VENDORED from the `ts` anchor, not reimplemented —
# and the transaction it builds calls a registered contract.
#
#   verification/verify_tx_builder_vendored_not_reimplemented.sh   (or: just verify-tx-builder)
#
# ---------------------------------------------------------------------------
# THIS IS A DELIVERABLE IN ITS OWN RIGHT AND IS CHECKED AS ONE. Eight milestones deferred "a
# transaction that calls a registered contract"; M25 priced it at four files and 880 lines and
# recorded the decision as RI-72 `vendor`. What that decision buys is only real if the copy IS
# upstream's, so the check has four parts and none stands in for another:
#
#   PROVENANCE   the four rows exist, name the right upstream paths at the right anchor, and the
#                files are tracked and carry generated headers.
#   THE DIFF     every line of every vendored file is EITHER byte-identical to a line of the
#                upstream original OR one of the lines declared below. `check-drift` asserts only
#                the DIRECTION of a difference and never what it is — M22's review measured a real
#                one-for-one corruption passing 59 assertions — so the content is pinned here.
#   THE TRIMS    the edges the reduction severs are severed, and each is shown to be PRESENT at the
#                anchor, so an absence is a removal rather than a needle that never matched.
#   THE PAYOFF   the builder is RUN: it produces a transaction whose enqueued call names come from
#                upstream's own `getDebugFunctionName`, whose calldata begins with the selector the
#                contract's own ABI derives, and which never touches its `merkleTree`.
#
# THE MERKLE TRIPWIRE IS THE ENTRY'S OWN LOAD-BEARING SENTENCE, EXECUTED. RI-72 rests on
# `grep -c 'merkleTree\.'` being 0 against 7 mentions at the anchor — a claim about TEXT. The
# driver passes a `Proxy` that throws on every read, every `in` and every enumeration, so the same
# claim is run. Its own control is that the builder DID run and DID produce a transaction; a
# tripwire that never fires because nothing executed is an absence of nothing.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=verify_tx_builder_vendored_not_reimplemented
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m26_join.sh"

m24_summary_on_abnormal_exit

WORK="${M26_VENDOR_WORK:-$HOME/.cache/aztec-m26-vendor}"
require_work_dir "$WORK" 1
rm -rf "${WORK:?}/up" "${WORK:?}/declared"
mkdir -p "$WORK/up" "$WORK/declared" || die "could not create $WORK"

ANCHOR="$(m24_pin ts commit)"
assert_ge "pins.json declares a ts anchor" 40 "${#ANCHOR}"
assert_dir "the fork's object store is present" "$FORK_ROOT/.git"

VENDOR="$REPO_ROOT/orchestration/src/vendor"
UP_PREFIX="yarn-project/simulator/src/public"

# local-basename : upstream-path : declared upstream line count
FILES="\
public_tx_simulation_tester.ts:$UP_PREFIX/fixtures/public_tx_simulation_tester.ts:329
public_fixtures_utils.ts:$UP_PREFIX/fixtures/utils.ts:275
avm_fixtures_utils.ts:$UP_PREFIX/avm/fixtures/utils.ts:154
simple_contract_data_source.ts:$UP_PREFIX/fixtures/simple_contract_data_source.ts:122"

# ===========================================================================
# PART 1 — PROVENANCE. Four rows, one added shim, and the mapping a tool executes.
# ===========================================================================
MAP="$(python3 "$REPO_ROOT/tools/provenance.py" map 2>/dev/null)"
assert_ge "the provenance mapping reads back" 500 "$(printf '%s\n' "$MAP" | grep -c . || true)"
TOTAL_UP=0
while IFS=: read -r base up want; do
  [ -n "$base" ] || continue
  row="$(printf '%s\n' "$MAP" | awk -F'\t' -v p="orchestration/src/vendor/$base" '$1==p {print; exit}')"
  assert_ge "PROVENANCE.md maps $base" 1 "$(printf '%s\n' "$row" | grep -c . || true)"
  assert_eq "…to $up" "$up" "$(printf '%s\n' "$row" | cut -f2)"
  assert_eq "…at the ts anchor" "$ANCHOR" "$(printf '%s\n' "$row" | cut -f3)"
  assert_eq "…citing RI-72" "RI-72" "$(printf '%s\n' "$row" | cut -f6)"
  assert_eq "…with the edit class M26 declared" "tx-builder-calldata-half" "$(printf '%s\n' "$row" | cut -f8)"
  assert_true "…and the file is tracked" \
    git -C "$REPO_ROOT" ls-files --error-unmatch "orchestration/src/vendor/$base"
  # Materialise the upstream original FROM THE OBJECT STORE, never from a worktree.
  git -C "$FORK_ROOT" show "$ANCHOR:$up" > "$WORK/up/$base" 2>/dev/null \
    || die "could not read $up at $ANCHOR out of $FORK_ROOT"
  got="$(wc -l < "$WORK/up/$base" | tr -d '[:space:]')"
  assert_eq "…and upstream's $base is the $want lines RI-72 prices it at" "$want" "$got"
  TOTAL_UP=$((TOTAL_UP + got))
done <<EOF
$FILES
EOF
assert_eq "the four together are RI-72's 880 lines" "880" "$TOTAL_UP"

# The added shim is declared as ADDED, which is a different row shape from the four above.
SHIM_ROW="$(printf '%s\n' "$MAP" | awk -F'\t' '$1=="orchestration/src/vendor/gas_compat.ts" {print; exit}')"
assert_ge "PROVENANCE.md maps the gas-compat shim too" 1 "$(printf '%s\n' "$SHIM_ROW" | grep -c . || true)"
assert_eq "…as having NO upstream counterpart" "(none — added in this repo)" \
  "$(printf '%s\n' "$SHIM_ROW" | cut -f2)"
assert_true "…and its header says so rather than naming a path that does not exist" \
  str_has_sub "$(cat "$VENDOR/gas_compat.ts")" 'ADDED HERE — this file has NO upstream counterpart'

# ===========================================================================
# PART 2 — THE DIFF, PINNED LINE FOR LINE.
#
# `_vendor_lines.py` classifies every content line of the vendored file as retained (byte-identical
# to some upstream line) or added. The DECLARED added set below is exhaustive, and the residue —
# added lines nobody declared — is asserted EMPTY. A line corrupted in place is neither retained nor
# declared, so it lands in the residue; a shape-based classifier would have accepted it.
# ===========================================================================
cat > "$WORK/declared/public_tx_simulation_tester.ts" <<'DECLARED'
import { createLogger } from '@aztec/foundation/log';
import { Gas, GasFees } from '@aztec/stdlib/gas';
} from './avm_fixtures_utils.ts';
// The two names the anchor imports from '@aztec/stdlib/gas' and the pinned nightly does not export.
import { FALLBACK_TEARDOWN_DA_GAS_LIMIT, FALLBACK_TEARDOWN_L2_GAS_LIMIT } from './gas_compat.ts';
import { type TestPrivateInsertions, createTxForPublicCalls } from './public_fixtures_utils.ts';
import { SimpleContractDataSource } from './simple_contract_data_source.ts';
export class PublicTxSimulationTester {
  public logger = createLogger('public-tx-simulation-tester');
  protected contractDataSource: SimpleContractDataSource;
  protected merkleTree: MerkleTreeWriteOperations;
    _globals: GlobalVariables = defaultGlobals(),
    this.merkleTree = merkleTree;
    this.contractDataSource = contractDataSource;
DECLARED
cat > "$WORK/declared/public_fixtures_utils.ts" <<'DECLARED'
import { Gas, GasFees, GasSettings } from '@aztec/stdlib/gas';
// The two names the anchor imports from '@aztec/stdlib/gas' and the pinned nightly does not export.
import { FALLBACK_TEARDOWN_DA_GAS_LIMIT, FALLBACK_TEARDOWN_L2_GAS_LIMIT } from './gas_compat.ts';
DECLARED
: > "$WORK/declared/avm_fixtures_utils.ts"
cat > "$WORK/declared/simple_contract_data_source.ts" <<'DECLARED'
import { getFunctionSelector } from './avm_fixtures_utils.ts';
DECLARED

# base : declared-added-count : declared-dropped-count : content-line-count
#
# THE FOURTH COLUMN AND THE `ORDERED` ASSERTION BELOW ARE M26'S REVIEW, AND BOTH ARE MEASURED HOLES
# RATHER THAN BELT-AND-BRACES. `_vendor_lines.py`'s classification was pure MEMBERSHIP, so a scratch
# copy with one retained line repeated TWENTY times, and a scratch copy with two adjacent retained
# lines SWAPPED, each passed every assertion in this loop — the second with counts byte-identical to
# the uncorrupted file. `VENDORED_LINES` was computed and printed on every run and compared with
# nothing. Duplication now has a number to fail against, and reordering has an in-order walk.
EXPECT="\
public_tx_simulation_tester.ts:14:150:123
public_fixtures_utils.ts:3:6:246
avm_fixtures_utils.ts:0:28:98
simple_contract_data_source.ts:1:1:106"
while IFS=: read -r base wadd wdrop wlines; do
  [ -n "$base" ] || continue
  rep="$(python3 "$VERIFY_DIR/_vendor_lines.py" "$WORK/up/$base" "$VENDOR/$base" \
        "$WORK/declared/$base" 2>&1)"
  assert_ge "$base classifies" 5 "$(printf '%s\n' "$rep" | grep -c . || true)"
  assert_eq "$base adds exactly the lines M26 declares" "$wadd" \
    "$(printf '%s\n' "$rep" | awk -F'\t' '$1=="ADDED" {print $2; exit}')"
  assert_eq "…and drops exactly the lines the reduction removes" "$wdrop" \
    "$(printf '%s\n' "$rep" | awk -F'\t' '$1=="DROPPED" {print $2; exit}')"
  # THE PIN. Everything else in the file is upstream's, byte for byte.
  assert_eq "…and NOTHING in it is neither upstream's nor declared" "" \
    "$(printf '%s\n' "$rep" | sed -n 's/^UNDECLARED\t//p' | head -3 | tr '\n' '|')"
  assert_ge "…over a file with real content in it" 90 \
    "$(printf '%s\n' "$rep" | awk -F'\t' '$1=="RETAINED" {print $2; exit}')"
  # DUPLICATION. A `set` has no opinion about how many times a line may appear, so the count of
  # content lines is pinned exactly rather than left to the membership test.
  assert_eq "…and has exactly the content lines it should, so a repeated line is not free" \
    "$wlines" "$(printf '%s\n' "$rep" | awk -F'\t' '$1=="VENDORED_LINES" {print $2; exit}')"
  # ORDER. Membership cannot see a statement moved from one method to another; an in-order walk
  # through the upstream original can, and it names the line it could not place.
  assert_eq "…and everything it kept is still in UPSTREAM'S ORDER" "1" \
    "$(printf '%s\n' "$rep" | awk -F'\t' '$1=="ORDERED" {print $2; exit}')"
done <<EOF
$EXPECT
EOF

# THE CONTROL FOR THE FOUR `UNDECLARED` ASSERTIONS ABOVE, and it is the one M22's review said this
# family needs: a corrupted copy must be REPORTED. One line of one vendored file is changed in a
# scratch copy, in the way that keeps every count and every shape — a one-for-one identifier swap —
# and the classifier must name it.
cp "$VENDOR/simple_contract_data_source.ts" "$WORK/corrupted.ts" || die "could not stage a control copy"
python3 - "$WORK/corrupted.ts" <<'PY' || die "could not corrupt the control copy"
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
old = "    this.contractClasses.set(contractClass.id.toString(), contractClass);"
new = "    this.contractClasses.set(contractClass.id.toString(), contractClass.id);"
assert old in s, "the control's target line moved; re-point it"
open(p, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
CTRL="$(python3 "$VERIFY_DIR/_vendor_lines.py" "$WORK/up/simple_contract_data_source.ts" \
      "$WORK/corrupted.ts" "$WORK/declared/simple_contract_data_source.ts" 2>&1)"
assert_ge "a one-for-one corruption of a vendored line IS reported as undeclared" 1 \
  "$(printf '%s\n' "$CTRL" | grep -c '^UNDECLARED' || true)"
assert_true "…naming the corrupted line rather than a count" \
  str_has_sub "$CTRL" 'this.contractClasses.set(contractClass.id.toString(), contractClass.id);'
assert_eq "…and the corruption keeps the LINE COUNT identical, which is why a count cannot catch it" \
  "$(wc -l < "$VENDOR/simple_contract_data_source.ts" | tr -d '[:space:]')" \
  "$(wc -l < "$WORK/corrupted.ts" | tr -d '[:space:]')"
rm -f "$WORK/corrupted.ts"

# THE CONTROLS FOR THE TWO NEW ASSERTIONS, and each is the corruption its assertion exists for.
# Neither is hypothetical: both were measured passing this whole check before those assertions
# existed, which is why they are here rather than in a comment.
#
# (1) REORDERING. Two adjacent retained lines swapped. Every count — VENDORED_LINES, RETAINED,
#     ADDED, DROPPED — comes back byte-identical to the uncorrupted file and the residue is still
#     empty, so `ORDERED` is the only thing in this check that can see it.
python3 - "$VENDOR/simple_contract_data_source.ts" "$WORK/reordered.ts" <<'REORDER' || die "could not stage the reorder control"
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines()
idx = [i for i, ln in enumerate(lines)
       if ln.strip() != "" and not ln.lstrip().startswith("//")]
a = b = None
for j in range(len(idx) - 1):
    if idx[j + 1] == idx[j] + 1:
        a, b = idx[j], idx[j + 1]
        break
assert a is not None, "no two adjacent content lines to swap; re-point this control"
lines[a], lines[b] = lines[b], lines[a]
open(dst, "w", encoding="utf-8").write("\n".join(lines) + "\n")
REORDER
REORD="$(python3 "$VERIFY_DIR/_vendor_lines.py" "$WORK/up/simple_contract_data_source.ts" \
       "$WORK/reordered.ts" "$WORK/declared/simple_contract_data_source.ts" 2>&1)"
assert_eq "two adjacent vendored lines SWAPPED is reported as out of upstream's order" "0" \
  "$(printf '%s\n' "$REORD" | awk -F'\t' '$1=="ORDERED" {print $2; exit}')"
assert_ge "…naming the line the in-order walk could not place" 1 \
  "$(printf '%s\n' "$REORD" | grep -c '^OUTOFORDER' || true)"
assert_eq "…while every COUNT stays exactly what it was, which is why nothing else can see it" \
  "106:105:1:1" \
  "$(printf '%s\n' "$REORD" | awk -F'\t' '
     $1=="VENDORED_LINES"{v=$2} $1=="RETAINED"{r=$2} $1=="ADDED"{a=$2} $1=="DROPPED"{d=$2}
     END{printf "%s:%s:%s:%s", v, r, a, d}')"
rm -f "$WORK/reordered.ts"

# (2) DUPLICATION. One retained line repeated twenty times, which membership calls retained every
#     time. The residue is asserted STILL EMPTY beside it, because that is the assertion that used
#     to be the whole pin and the point is that it does not move.
python3 - "$VENDOR/simple_contract_data_source.ts" "$WORK/duplicated.ts" <<'DUPES' || die "could not stage the duplication control"
import sys
src, dst = sys.argv[1], sys.argv[2]
lines = open(src, encoding="utf-8").read().splitlines()
target = next(i for i, ln in enumerate(lines)
              if ln.strip() != "" and not ln.lstrip().startswith("//"))
out = lines[: target + 1] + [lines[target]] * 20 + lines[target + 1 :]
open(dst, "w", encoding="utf-8").write("\n".join(out) + "\n")
DUPES
DUP="$(python3 "$VERIFY_DIR/_vendor_lines.py" "$WORK/up/simple_contract_data_source.ts" \
     "$WORK/duplicated.ts" "$WORK/declared/simple_contract_data_source.ts" 2>&1)"
assert_eq "a retained line repeated twenty times moves the content-line count" "126" \
  "$(printf '%s\n' "$DUP" | awk -F'\t' '$1=="VENDORED_LINES" {print $2; exit}')"
assert_eq "…and the residue is STILL empty, which is why membership alone could not see it" "" \
  "$(printf '%s\n' "$DUP" | sed -n 's/^UNDECLARED\t//p' | head -3 | tr '\n' '|')"
rm -f "$WORK/duplicated.ts"

# ===========================================================================
# PART 3 — THE TRIMS. Each severed edge is shown PRESENT upstream and ABSENT here.
#
# An absence on its own is only as good as the needle; every one below has its own control in the
# upstream original, so "0 occurrences" is a removal rather than a spelling that never matched.
# ===========================================================================
ALL_VENDORED="$(cat "$VENDOR/public_tx_simulation_tester.ts" "$VENDOR/public_fixtures_utils.ts" \
                    "$VENDOR/avm_fixtures_utils.ts" "$VENDOR/simple_contract_data_source.ts" 2>/dev/null)"
ALL_UPSTREAM="$(cat "$WORK/up/public_tx_simulation_tester.ts" "$WORK/up/public_fixtures_utils.ts" \
                    "$WORK/up/avm_fixtures_utils.ts" "$WORK/up/simple_contract_data_source.ts" 2>/dev/null)"
assert_ge "the four vendored files read back" 500 "$(printf '%s\n' "$ALL_VENDORED" | grep -c . || true)"
assert_ge "…and the four upstream originals do too" 700 "$(printf '%s\n' "$ALL_UPSTREAM" | grep -c . || true)"

for needle in '@aztec/world-state' 'NativeWorldStateService' 'lodash.merge' \
              '../avm/fixtures/base_avm_simulation_tester.js' '../public_db_sources.js' \
              '../public_tx_simulator/cpp_public_tx_simulator.js' \
              '../public_tx_simulator/cpp_vs_ts_public_tx_simulator.js' \
              '../test'"_executor_metrics.js" '../../../common/index.js' \
              '../avm_memory_types.js' '../errors.js'; do
  assert_true "the reduction's target [$needle] IS present in the upstream originals" \
    str_has_sub "$ALL_UPSTREAM" "$needle"
  assert_false "…and is GONE from the vendored copies" str_has_sub "$ALL_VENDORED" "$needle"
done
# THE CONTROL FOR THE ELEVEN ABSENCES: something upstream that is NOT trimmed is still here.
for kept in 'createTxForPublicCalls' 'PublicCallRequest.fromCalldata' 'createContractClassAndInstance' \
            'getDebugFunctionName' 'MerkleTreeWriteOperations'; do
  assert_true "…while [$kept], which the reduction KEEPS, is in both" \
    str_has_sub "$ALL_VENDORED" "$kept"
done

# RI-72's own measurement, re-derived on the anchor's text rather than quoted.
assert_eq "upstream's builder mentions NativeWorldStateService exactly twice" "2" \
  "$(grep -c 'NativeWorldStateService' "$WORK/up/public_tx_simulation_tester.ts" || true)"
assert_eq "…and never CONSTRUCTS one" "0" \
  "$(grep -c 'new NativeWorldStateService' "$WORK/up/public_tx_simulation_tester.ts" || true)"
assert_eq "…and never CALLS a method on its merkleTree" "0" \
  "$(grep -c 'merkleTree\.' "$WORK/up/public_tx_simulation_tester.ts" || true)"
assert_ge "…against seven mentions of it, which is the control for that zero" 7 \
  "$(grep -c 'merkleTree' "$WORK/up/public_tx_simulation_tester.ts" || true)"

# ===========================================================================
# PART 4 — THE GAS-COMPAT SHIM, and the measurement that justifies it.
#
# BOTH HALVES, because either alone rots. The names ARE at the anchor and are NOT in the installed
# package; the day the nightly starts exporting them, the second assertion reddens rather than the
# shim quietly becoming dead code.
# ===========================================================================
GAS_UP="$(git -C "$FORK_ROOT" show "$ANCHOR:yarn-project/stdlib/src/gas/gas_settings.ts" 2>/dev/null)"
assert_ge "upstream's gas_settings.ts reads back at the anchor" 20 \
  "$(printf '%s\n' "$GAS_UP" | grep -c . || true)"
for c in FALLBACK_TEARDOWN_DA_GAS_LIMIT FALLBACK_TEARDOWN_L2_GAS_LIMIT; do
  assert_true "$c IS exported at the ts anchor" str_has_sub "$GAS_UP" "export const $c"
done
# THE CWD IS LOAD-BEARING. Node's ESM resolution walks up from the importing file, and an `-e`
# script's notional file is the CWD — so `@aztec/*` resolves only from inside the package that
# depends on it. Asked from the repository root the answer is `LOADFAIL`, which is the shape that
# would make this absence assertion pass for the wrong reason if it were spelled as a grep.
INSTALLED="$(cd "$REPO_ROOT/orchestration" && node -e '
  import("@aztec/stdlib/gas").then(m => {
    const hit = Object.keys(m).filter(k => /FALLBACK_TEARDOWN/.test(k));
    console.log(hit.length === 0 ? "ABSENT" : hit.join(","));
  }).catch(e => console.log("LOADFAIL:" + e.message));
' 2>/dev/null)"
[ -n "$INSTALLED" ] || die "could not ask the installed @aztec/stdlib what it exports"
assert_eq "…and is NOT exported by the pinned nightly, which is why the shim exists" "ABSENT" \
  "$INSTALLED"
# The shim's VALUES are derived from @aztec/constants rather than typed in.
SHIM_VALUES="$(cd "$REPO_ROOT/orchestration" && node -e '
  Promise.all([import("@aztec/constants"),
               import("'"$VENDOR"'/gas_compat.ts")]).then(([c, g]) => {
    console.log([Math.floor(c.MAX_PROCESSABLE_L2_GAS / 8) === g.FALLBACK_TEARDOWN_L2_GAS_LIMIT,
                 Math.floor(Math.floor(c.MAX_PROCESSABLE_DA_GAS_PER_CHECKPOINT / 4) / 2)
                   === g.FALLBACK_TEARDOWN_DA_GAS_LIMIT,
                 g.FALLBACK_TEARDOWN_L2_GAS_LIMIT > 0].join(","));
  }).catch(e => console.log("LOADFAIL:" + e.message));
' 2>/dev/null)"
assert_eq "the shim reproduces the anchor's arithmetic over @aztec/constants, non-degenerately" \
  "true,true,true" "$SHIM_VALUES"

# ===========================================================================
# PART 5 — THE PAYOFF, RUN. A transaction that calls a registered contract.
# ===========================================================================
m24_require_module
m26_require_arms

assert_eq "the contract the transaction calls is registered as a class" "1" \
  "$(m26_arm 'd["tx"]["registeredClasses"]')"
assert_eq "…and as an instance at an address" "1" "$(m26_arm 'd["tx"]["registeredInstances"]')"
assert_eq "the artifact is upstream's own Token, at the pinned nightly" "Token" \
  "$(m26_arm 'd["tx"]["artifactName"]')"
assert_eq "…at the nightly pins.json declares" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["npm"]["deletion_era"]["version"])' \
     "$REPO_ROOT/pins.json" 2>/dev/null || printf 'MISSING\n')" \
  "$(m26_arm 'd["tx"]["aztecVersion"]')"
assert_ge "…with real packed bytecode behind it" 1000 "$(m26_arm 'd["tx"]["packedBytecodeBytes"]')"
assert_eq "the builder enqueued two public calls" "2" "$(m26_arm 'd["tx"]["enqueuedPublicCalls"]')"
assert_eq "…and no setup calls, which is what this transaction shape is" "0" \
  "$(m26_arm 'd["tx"]["setupPublicCalls"]')"
# THE CALLDATA IS A CALL TO A NAMED FUNCTION, not a blob of fields: its first word is the selector
# the contract's OWN ABI derives, compared against the selector rather than restated.
SELECTOR="$(m26_arm 'd["tx"]["fnSelector"]')"
assert_ge "the function selector is derived from the ABI" 8 "${#SELECTOR}"
assert_true "…and the calldata's first field IS that selector" \
  str_has_sub "$(m26_arm 'd["tx"]["calldataSelector"]')" "${SELECTOR#0x}"
assert_eq "…with the four ABI parameters after it" "5" "$(m26_arm 'd["tx"]["calldataFields"]')"
# Guarded for the reason `test_private_public_frame_nesting` records: `m26_arm` prints `MISSING`
# rather than nothing on failure, and `$(( MISSING + 1 ))` is an unbound variable under `set -u`.
PARAMS="$(m26_arm 'd["tx"]["fnParameters"]')"
EXPECT_CALLDATA="UNCOMPUTABLE"
case "$PARAMS" in ''|*[!0-9]*) ;; *) EXPECT_CALLDATA="$((PARAMS + 1))" ;; esac
assert_eq "…which is one more than the function's parameter count" \
  "$EXPECT_CALLDATA" "$(m26_arm 'd["tx"]["calldataFields"]')"
assert_eq "the frame name comes from upstream's own getDebugFunctionName" \
  "Token.transfer_in_public" "$(m26_arm 'd["tx"]["debugFunctionName"]')"

# THE TRIPWIRE, AND ITS CONTROL. Zero observations of `merkleTree` — and the builder DID run, which
# is what stops the zero from being an absence of nothing.
# COUNTED RATHER THAN COMPARED TO AN EMPTY STRING: `assert_eq "" ""` is this campaign's oldest
# vacuity, and an empty list and a missing key render the same way.
assert_eq "the vendored builder never observed its merkleTree, not even with an 'in'" "0" \
  "$(m26_arm 'len(d["tx"]["merkleTouches"])')"
# THE CONTROL THAT THE TRIPWIRE IS WIRED TO THE OBJECT THE BUILDER HOLDS — M26's review, and the
# zero above means nothing without it. Every trap THROWS, so an observation aborts the driver and
# no report exists; therefore `merkleTouches` is empty in every report a check can read, INCLUDING
# a report produced with the tripwire wired to nothing at all. The driver reads `tester.merkleTree`
# back off the builder after the transaction is built — the field the vendored constructor assigned
# — and touches THAT, so this is the same reference the vendored code was handed.
assert_true "…and the tripwire is ARMED, which is what makes that zero a measurement" \
  str_has_sub "$(m26_arm 'd["tx"]["merkleTripwireControl"]')" 'threw:'
assert_true "…throwing the tripwire's own message, so it is the proxy and not some other error" \
  str_has_sub "$(m26_arm 'd["tx"]["merkleTripwireControl"]')" \
  'the vendored transaction builder read merkleTree.getTreeInfo'
assert_eq "…and the observation list CAN be non-empty, which the build's own zero cannot show" "1" \
  "$(m26_arm 'd["tx"]["merkleTouchesAfterControl"]')"
TXHASH="$(m26_arm 'd["tx"]["txHash"]')"
assert_ge "…and it DID produce a transaction, so that zero is about a run" 66 "${#TXHASH}"
assert_true "…whose hash is a field element" str_has_re "$TXHASH" '^0x[0-9a-f]{64}$'
# The control that the builder is not producing one fixed answer whatever it is asked for.
assert_false "…and a DIFFERENT transaction from the same builder hashes differently" \
  test "$TXHASH" = "$(m26_arm 'd["tx"]["controlTxHash"]')"

# ===========================================================================
# PART 6 — RI-72 and the inventory say the same thing the measurement does.
# ===========================================================================
INV="$(cat "$REPO_ROOT/REUSE-INVENTORY.md" 2>/dev/null)"
assert_ge "the reuse inventory reads back" 500 "$(printf '%s\n' "$INV" | grep -c . || true)"
assert_true "RI-72 records the decision as vendor" \
  str_has_sub "$INV" '### RI-72 — Upstream'"'"'s transaction builder, and the closure it drags'
assert_true "…and the figure the four files reproduce" \
  str_has_sub "$INV" '**The calldata-and-call-request half is 4 files and 880 lines**'
assert_true "…and M26 records that the vendoring landed, with the row ids" \
  str_has_sub "$INV" 'VENDORED BY M26 as `PROVENANCE.md` F20..F23'
# The lodash finding RI-72 did not have, recorded rather than left in a commit message.
assert_true "…and records the non-@aztec package the original sentence did not cover" \
  str_has_sub "$INV" 'lodash.merge'

m24_finish
