#!/usr/bin/env bash
# verify_facade_surface_compared_against_txe — the facade's shape is informed, not invented.
#
# The verification entry: "Each AvmRuntime method is mapped to its TXE counterpart or marked as
# having none, so the facade's shape is informed by the prior art whichever verdict TXE received."
#
# THE MEMBER LIST COMES FROM THE CLASS, NOT FROM THE DOCUMENT. `CHAIN-LOOP.md` section 4 is a table,
# and a table is a thing somebody wrote. So this check enumerates `AvmRuntime.prototype` at run
# time and requires EVERY public member to appear in that table — which is what makes "each method
# is mapped" a total claim rather than a claim about the ones somebody remembered.
#
# AND EVERY CLAIMED COUNTERPART IS CHECKED UPSTREAM. A mapping that named a TXE method TXE does not
# have would be prior art invented rather than consulted, which is the failure mode this deliverable
# exists to prevent — so each non-`none` TXE cell is required to be a method declaration in
# `txe_oracle_top_level_context.ts` at the anchor.
#
# `AztecNodeDebug` IS THE SECOND COLUMN AND IT NAMES TWO DIFFERENT SURFACES. At the `cpp` anchor it
# declares five methods; the `@aztec/stdlib` this package INSTALLS declares three, because
# `warpL2TimeAtLeastTo` and `warpL2TimeAtLeastBy` were added after the pin. Both are measured, and
# the document is required to record the difference — "follow `AztecNodeDebug`" is ambiguous
# otherwise, and an instruction whose meaning depends on which artefact you read is how a decision
# gets lost.
#
# Run: just verify-chain-facade-map

TEST_NAME="verify_facade_surface_compared_against_txe"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor
m23_require_packages

DOC="$(cat "$M23_DOC")"
CTX="$(m23_anchor_file yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts)"

# ---------------------------------------------------------------------------
# PART 1 — the member list, from the class
# ---------------------------------------------------------------------------
echo "== every public member of AvmRuntime appears in the mapping"

MEMBERS="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { AvmRuntime } from "./src/avm_runtime.ts";
// Private members are TypeScript-private, so they exist on the prototype; the two that are
// implementation detail are excluded BY NAME and the exclusion is asserted below, so a future
// private method cannot be quietly dropped from the mapping by adding it to this list.
const skip = new Set(["constructor", "submitSubmitted", "receipt"]);
console.log(Object.getOwnPropertyNames(AvmRuntime.prototype).filter(n => !skip.has(n)).sort().join("\n"));
' 2>&1 | grep -v '^$')"
N_MEMBERS="$(printf '%s\n' "$MEMBERS" | grep -c .)"
assert_ge "the facade has a substantial public surface" 18 "$N_MEMBERS"

# The table's own rows, extracted from the document.
# THE HEADER ROW IS EXCLUDED BY NAME. It starts `| \`AvmRuntime\` |` like every data row, and
# leaving it in put the literal strings `TXE` and `AztecNodeDebug` into the claimed-counterpart
# set — where they were then looked up as TXE methods and reported as missing. Caught by this
# check's own first run.
TABLE="$(awk '/^## 4\. The facade, mapped/,/^Fourteen of the/' "$M23_DOC" \
  | grep '^| `' | grep -v '^| `AvmRuntime` | TXE |')"
N_ROWS="$(printf '%s\n' "$TABLE" | grep -c .)"
assert_ge "the mapping table has a row per member" "$N_MEMBERS" "$N_ROWS"

MISSING=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  # `str_has_sub`, never `printf … | grep -q`: that shape is a catalogued defect in this shell and
  # `verify_no_pipeline_predicates` pins the surviving census at five BY NAME, so a new one fails
  # the repo-wide check. It found this line on its first run.
  if ! str_has_sub "$TABLE" "| \`$m\` |"; then
    MISSING="$MISSING $m"
  fi
done <<EOF
$MEMBERS
EOF
assert_eq "every public member is mapped" "" "$MISSING"

# THE CONTROL: a member the class does not have is NOT in the table either, so "every member is
# mapped" is not passing because the table matches everything.
assert_false "…and a member the class does not have is not in the table" \
  str_has_sub "$TABLE" "| \`warpToSlot\` |"
# AND THE SKIP LIST IS SHOWN TO BE LOAD-BEARING RATHER THAN A HOLE: the three skipped names really
# are on the prototype, so the filter removed something.
ALL="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { AvmRuntime } from "./src/avm_runtime.ts";
console.log(Object.getOwnPropertyNames(AvmRuntime.prototype).join(" "));
' 2>&1 | tail -1)"
assert_true "the skipped members are really on the prototype" str_has_word "$ALL" "submitSubmitted"
assert_true "…both of them" str_has_word "$ALL" "receipt"

# ---------------------------------------------------------------------------
# PART 2 — every claimed TXE counterpart exists upstream
# ---------------------------------------------------------------------------
echo "== every TXE counterpart named in the mapping is a real TXE method"

CLAIMED="$(printf '%s\n' "$TABLE" | awk -F'|' '{print $3}' \
  | sed -e 's/[[:space:]]//g' -e 's/`//g' -e 's/(private)//' | grep -v '^none$' | grep -v '^$' | sort -u)"
N_CLAIMED="$(printf '%s\n' "$CLAIMED" | grep -c .)"
assert_ge "the mapping claims a substantial number of TXE counterparts" 8 "$N_CLAIMED"

BAD=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if ! str_has_line_re "$CTX" "^  (private )?(async )?$m\("; then
    BAD="$BAD $m"
  fi
done <<EOF
$CLAIMED
EOF
assert_eq "every one of them is declared in TXE's top-level context" "" "$BAD"

# THE CONTROL for that matcher: a plausible method name TXE does NOT have is rejected by it.
assert_false "a method TXE does not have would have been reported" \
  str_has_line_re "$CTX" "^  (private )?(async )?mineCheckpoint\("

echo "== and the counterparts that do NOT exist are marked none rather than omitted"
N_NONE="$(printf '%s\n' "$TABLE" | awk -F'|' '{print $3}' | sed 's/[[:space:]]//g' | grep -c '^none$' || true)"
assert_ge "several members are marked as having no TXE counterpart" 5 "$N_NONE"
# The two totals must account for every row: claimed + none == rows. A row with an empty cell
# would otherwise be neither, and would look like a mapping while being a blank.
N_CELLS="$(printf '%s\n' "$TABLE" | awk -F'|' '{print $3}' | sed -e 's/[[:space:]]//g' -e 's/`//g' \
  | grep -c . || true)"
assert_eq "every row's TXE cell is filled in" "$N_ROWS" "$N_CELLS"

# ---------------------------------------------------------------------------
# PART 3 — AztecNodeDebug, at BOTH artefacts
# ---------------------------------------------------------------------------
echo "== AztecNodeDebug names two different surfaces, and both are measured"

DEBUG_SRC="$(m23_anchor_file yarn-project/stdlib/src/interfaces/aztec-node-debug.ts)"
# THE CHARACTER CLASS CARRIES DIGITS, and this campaign has the defect on record: `[A-Za-z_]+`
# found seven where the truth was eight because `avm2` has a digit. Here it would find THREE of
# five, because `warpL2TimeAtLeastTo` and `warpL2TimeAtLeastBy` have a `2` in them — reproduced on
# this check's own first run, in the section whose entire subject is those two methods.
ANCHOR_METHODS="$(printf '%s\n' "$DEBUG_SRC" | grep -cE '^  [A-Za-z0-9_]+\(.*\): Promise<' || true)"
assert_eq "at the cpp anchor it declares five methods" "5" "$ANCHOR_METHODS"
for m in mineBlock prove warpL2TimeAtLeastTo warpL2TimeAtLeastBy registerContractFunctionSignatures; do
  assert_true "…including $m" str_has_line_re "$DEBUG_SRC" "^  $m\("
done
assert_true "…and it has a zod schema beside it" str_has_sub "$DEBUG_SRC" "AztecNodeDebugApiSchema"

INSTALLED="$ORCH_DIR/node_modules/@aztec/stdlib/dest/interfaces/aztec-node-debug.d.ts"
assert_file "the installed @aztec/stdlib declares it too" "$INSTALLED"
INSTALLED_SRC="$(cat "$INSTALLED")"
assert_true "the installed one has mineBlock" str_has_sub "$INSTALLED_SRC" "mineBlock("
assert_true "…and prove" str_has_sub "$INSTALLED_SRC" "prove("
# THE DIFFERENCE: the two warp methods are NOT in the installed declaration.
assert_false "…but NOT warpL2TimeAtLeastTo" str_has_sub "$INSTALLED_SRC" "warpL2TimeAtLeastTo"
assert_false "…and NOT warpL2TimeAtLeastBy" str_has_sub "$INSTALLED_SRC" "warpL2TimeAtLeastBy"

assert_true "CHAIN-LOOP.md records that the two surfaces differ" \
  str_has_sub "$DOC" "names two different surfaces"
assert_true "…and names the commit that added the two methods" \
  str_has_sub "$DOC" "c6a6dbd8bb00"
assert_true "…and says which one we follow" str_has_sub "$DOC" "deliberately not"

echo "== and the mapping's AztecNodeDebug column is checked the same way"
DEBUG_CLAIMED="$(printf '%s\n' "$TABLE" | awk -F'|' '{print $4}' \
  | sed -e 's/[[:space:]]//g' -e 's/`//g' | grep -v '^none$' | grep -v '^$' | sort -u)"
N_DEBUG="$(printf '%s\n' "$DEBUG_CLAIMED" | grep -c . || true)"
assert_ge "the mapping claims at least two AztecNodeDebug counterparts" 2 "$N_DEBUG"
BAD2=""
while IFS= read -r m; do
  [ -n "$m" ] || continue
  str_has_line_re "$DEBUG_SRC" "^  $m\(" || BAD2="$BAD2 $m"
done <<EOF
$DEBUG_CLAIMED
EOF
assert_eq "…and each is a real AztecNodeDebug method" "" "$BAD2"

# ---------------------------------------------------------------------------
# PART 4 — the divergences are DECLARED, which is the deliverable's own condition
# ---------------------------------------------------------------------------
echo "== the two divergences from the prior art are recorded with reasons"

assert_true "the document has a section for them" str_has_sub "$DOC" "## 3. Where we diverge from the prior art"
assert_true "…the delta-versus-absolute timestamp divergence" \
  str_has_sub "$DOC" "We do not take \`advanceTimestampBy\` as a delta"
assert_true "…and the reason, which is that TXE has no timer at all" \
  str_has_sub "$DOC" "TXE has no timer at"
# NEEDLES ARE LINE FRAGMENTS AND NOT SENTENCES, because this document wraps at 100 columns and a
# needle that spans a line break stops matching the day somebody reflows a paragraph. Three of
# these went red on the first run for exactly that reason and none of them was about the subject.
assert_true "…and the warp divergence, with a slot being an L1 concept as the reason" \
  str_has_sub "$DOC" "a slot is an L1"

echo "== prove() has no counterpart and that is §8.4 rather than an omission"
assert_true "the document says so" str_has_sub "$DOC" "\`prove\` will never have a counterpart"
RUNTIME="$(cd "$ORCH_DIR" && node --input-type=module -e '
import { AvmRuntime } from "./src/avm_runtime.ts";
console.log(Object.getOwnPropertyNames(AvmRuntime.prototype).join(" "));
' 2>&1 | tail -1)"
assert_false "…and the facade really has no prove method" str_has_word "$RUNTIME" "prove"
assert_true "…while it does have produceBlock, so the lookup works" str_has_word "$RUNTIME" "produceBlock"

m23_finish
