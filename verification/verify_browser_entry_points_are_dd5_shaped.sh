#!/usr/bin/env bash
# verify_browser_entry_points_are_dd5_shaped
#
# DD-5: "the browser entry point is the reference, and the Node entry point is the superset. Every
# feature must work in the browser; Node may add CONVENIENCES (fs, process args), never CAPABILITIES."
#
# M23 SHIPPED ONE ENTRY POINT AND MARKED THIS DELIVERABLE UNMET rather than "met in spirit". It is
# M27's, and this is the check that holds it.
#
# ===========================================================================================
# "CONVENIENCE" AND "CAPABILITY" ARE EASY WORDS TO ARGUE ABOUT, SO THE RULE IS MECHANICAL.
# ===========================================================================================
#
# The export sets of the BUILT bundles are read by importing them in Node and taking `Object.keys` —
# not by grepping `export {`, which `CAMPAIGN-BRIEF.md` records as the difference between a
# measurement and a source scan. Then:
#
#   * (node exports) ⊇ (browser exports)              — every browser feature exists in Node
#   * (node exports) − (browser exports) == NODE_CONVENIENCES, EXACTLY, as a SET
#
# The second is what makes the rule enforceable: `NODE_CONVENIENCES` is a VALUE in
# `entry_node.ts`, exported and therefore readable out of the bundle, so an addition nobody declared
# fails AND a declaration for something that is not there fails. A comment could not be compared
# with a bundle.
#
# THE TESTING ENTRY IS A SUPERSET TOO, AND IT ADDS NO CAPABILITY. `aztec-avm-runtime/testing` is
# `export * from './entry_browser.ts'` plus fixtures, and everything it adds RUNS IN A PAGE —
# `smoke_browser_token_transfer` proves that by running `runTokenTransfer` in one. So its additions
# are asserted to be a superset of the browser's and to reach no Node builtin.
#
# Run: just verify-browser-entry-points

TEST_NAME="verify_browser_entry_points_are_dd5_shaped"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m27_require_bundle

echo "== 1. there are THREE entry points, and they are the three DD-5 names"

assert_file "aztec-avm-runtime/browser  — the reference" "$BROWSER_DIST/browser.js"
assert_file "aztec-avm-runtime/testing  — the test harness" "$BROWSER_DIST/testing.js"
assert_file "aztec-avm-runtime/node     — the superset" "$BROWSER_DIST/node/node.js"
for src in entry_browser entry_testing entry_node; do
  assert_file "…and its source, browser/src/$src.ts" "$BROWSER_SRC/$src.ts"
  assert_true "…which is tracked" git -C "$REPO_ROOT" ls-files --error-unmatch "browser/src/$src.ts"
done

echo "== 2. the export sets, read out of the BUILT bundles"

exports_of() { # <relative js>
  ( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./$1');
console.log(Object.keys(m).sort().join('\n'));
" 2>&1 )
}

BROWSER_EXPORTS="$(exports_of browser.js)" || die "the browser bundle could not be imported: $BROWSER_EXPORTS"
TESTING_EXPORTS="$(exports_of testing.js)" || die "the testing bundle could not be imported: $TESTING_EXPORTS"
NODE_EXPORTS="$(exports_of node/node.js)" || die "the node bundle could not be imported: $NODE_EXPORTS"

N_B="$(printf '%s\n' "$BROWSER_EXPORTS" | grep -c .)"
N_T="$(printf '%s\n' "$TESTING_EXPORTS" | grep -c .)"
N_N="$(printf '%s\n' "$NODE_EXPORTS" | grep -c .)"
note "browser $N_B, testing $N_T, node $N_N exported name(s)"
assert_ge "the browser entry exports a real surface" 40 "$N_B"
assert_ge "…the testing entry at least as many" "$N_B" "$N_T"
assert_ge "…and the node entry at least as many" "$N_B" "$N_N"

echo "== 3. THE RULE: node ⊇ browser, and the difference is DECLARED"

MISSING_IN_NODE=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  str_has_line "$NODE_EXPORTS" "$name" || MISSING_IN_NODE="$MISSING_IN_NODE $name"
done <<< "$BROWSER_EXPORTS"
assert_eq "every browser export exists in the node entry — Node is the SUPERSET" "" "$MISSING_IN_NODE"

MISSING_IN_TESTING=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  str_has_line "$TESTING_EXPORTS" "$name" || MISSING_IN_TESTING="$MISSING_IN_TESTING $name"
done <<< "$BROWSER_EXPORTS"
assert_eq "…and in the testing entry" "" "$MISSING_IN_TESTING"

EXTRA_IN_NODE=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  str_has_line "$BROWSER_EXPORTS" "$name" || EXTRA_IN_NODE="$EXTRA_IN_NODE$name
"
done <<< "$NODE_EXPORTS"
EXTRA_SORTED="$(printf '%s' "$EXTRA_IN_NODE" | grep . | LC_ALL=C sort | tr '\n' ' ')"
note "the node entry adds: $EXTRA_SORTED"

DECLARED="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./node/node.js');
console.log(Object.keys(m.NODE_CONVENIENCES).sort().join(' ') + ' ');
" 2>&1 )" || die "NODE_CONVENIENCES could not be read out of the node bundle: $DECLARED"
note "the node entry declares: $DECLARED"

# THE EXACT SET COMPARISON. Not a subset in either direction: an undeclared addition and a
# declaration for something absent are both failures, and only comparing both ways catches both.
assert_eq "the node entry's ADDITIONS are exactly its DECLARED conveniences" \
  "$(printf '%s' "$DECLARED" | tr -s ' ')" "$(printf '%s' "$EXTRA_SORTED" | tr -s ' ')"
assert_ge "…and there are at least four of them, so the comparison is not over an empty set" 4 \
  "$(printf '%s\n' "$EXTRA_SORTED" | tr ' ' '\n' | grep -c .)"

echo "== 4. every declared convenience says what browser call it saves"

REASONS="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./node/node.js');
for (const [k, v] of Object.entries(m.NODE_CONVENIENCES)) console.log(k + '\t' + v);
" 2>&1 )" || die "the conveniences' reasons could not be read"
SHORT=""
while IFS=$'\t' read -r name reason; do
  [ -n "$name" ] || continue
  [ "${#reason}" -ge 30 ] || SHORT="$SHORT $name"
done <<< "$REASONS"
assert_eq "every declared convenience carries a substantive reason" "" "$SHORT"
# A CAPABILITY WOULD NOT BE FS-SHAPED. Each reason must name the browser mechanism it stands in for,
# so "a convenience" is a claim about a specific replacement rather than a word.
assert_true "…and the module loader's reason names the browser's fetch" \
  str_has_sub "$REASONS" 'A page fetches it over HTTP'
assert_true "…and the snapshot writer's names a download" str_has_sub "$REASONS" 'a download'
assert_true "…and the snapshot reader's names a file input" str_has_sub "$REASONS" 'file input'

echo "== 5. the browser and testing entries reach no Node builtin; the node entry does"

BROWSER_BYTES="$(cat "$BROWSER_DIST"/browser.js "$BROWSER_DIST"/testing.js "$BROWSER_DIST"/chunks/*.js)"
NODE_BYTES="$(cat "$BROWSER_DIST"/node/node.js "$BROWSER_DIST"/node/chunks/*.js 2>/dev/null)"
BUILTINS='node:fs node:fs/promises node:path node:url node:wasi node:child_process node:worker_threads'
# BOTH SPELLINGS. `CAMPAIGN-BRIEF.md` records a graph claim that rested on a single-quote-only grep,
# so the same import spelled the other way passed everything.
_builtins_found() { # <bytes> -> the subset of BUILTINS present
  local hay="$1" b out=""
  for b in $BUILTINS; do
    { str_has_sub "$hay" "\"$b\"" || str_has_sub "$hay" "'$b'"; } && out="$out $b"
  done
  printf '%s' "$out"
}
FOUND="$(_builtins_found "$BROWSER_BYTES")"
assert_eq "the browser and testing bundles reach no Node builtin" "" "$FOUND"
# THE CONTROL, AND IT RUNS THE SAME CENSUS. It used to be a hand-written literal beside the loop —
# two needles that agree today rather than one instrument asked twice. Measured by M27's review:
# typo the loop's list to `nodeX:fs …` and the assertion above AND its control both stayed green,
# 34 assertions and 0 failures, which is the scanner-with-a-typo'd-needle case the comment claimed
# to rule out.
FOUND_NODE="$(_builtins_found "$NODE_BYTES")"
note "the same census over the NODE bundle finds:${FOUND_NODE:- (nothing)}"
assert_true "…while the SAME census finds node:fs/promises in the node bundle" \
  str_has_sub "$FOUND_NODE" 'node:fs/promises'

echo "== 6. DD-9 and §8.4 hold on all three surfaces"

for surface in "browser:$BROWSER_EXPORTS" "testing:$TESTING_EXPORTS" "node:$NODE_EXPORTS"; do
  label="${surface%%:*}"; names="${surface#*:}"
  assert_false "$label exports no PublicProcessor (DD-9)" str_has_line "$names" 'PublicProcessor'
  assert_false "$label exports no PublicProcessorFactory (DD-9)" str_has_line "$names" 'PublicProcessorFactory'
  # `AztecNode` IS A TYPE, AND A TYPE CANNOT APPEAR IN `Object.keys` OF A BUILT BUNDLE. This
  # assertion is kept because it catches a VALUE by that name, but on its own it is an absence asked
  # of a tree that excludes its subject by construction: measured by M27's review,
  # `export type { AztecNode } from '@aztec/stdlib/interfaces/client';` added to `entry_browser.ts`
  # left this assertion, its two siblings and `verify_browser_bundle_builds`'s copy all green —
  # 34/0 and 41/0. The load-bearing half is §6b.
  assert_false "$label exports no VALUE named AztecNode (§8.4)" str_has_line "$names" 'AztecNode'
  assert_true "$label DOES export the facade, so the absences above are not an empty module" \
    str_has_line "$names" 'AvmRuntime'
done

echo "== 6b. §8.4's TYPE half, asked of the source, where a type still exists"

# M21's `test_no_aztec_node_type_exported` owns this rule and measures `orchestration/src`. The
# three browser entry points are a NEW export surface that it does not reach, so the rule is
# re-asked here of the sources that produce them.
#
# ONE HAYSTACK, not three, because `entry_testing.ts` and `entry_node.ts` both
# `export * from './entry_browser.ts'` — a per-file absence would say nothing about what the star
# carries. COMMENTS ARE STRIPPED, because `entry_browser.ts` cites the type by name in the very
# paragraph that says it is not exported, and "a citation is the opposite of a dependency" is a rule
# this campaign has written down after being caught by it. The needle is the WORD, so
# `AztecNodeDebug` — M23's facade name, legitimately mentioned in this tree — does not satisfy it.
ENTRY_SRC=""
for entry in entry_browser entry_testing entry_node; do
  assert_file "the $entry source is where that surface comes from" "$BROWSER_SRC/$entry.ts"
  ENTRY_SRC="$ENTRY_SRC
$(grep -vE '^[[:space:]]*(//|/\*|\*)' "$BROWSER_SRC/$entry.ts")"
done
assert_ge "the three entry sources were read" 60 "$(printf '%s\n' "$ENTRY_SRC" | grep -c . || true)"
assert_false "no entry source names a type called AztecNode (§8.4)" \
  str_has_word "$ENTRY_SRC" 'AztecNode'
# THE CONTROL FOR THAT ZERO, same predicate, same haystack: a needle that quietly stopped matching
# would drive both to zero and this one fails.
assert_true "…while the same predicate finds AvmRuntime in the same haystack" \
  str_has_word "$ENTRY_SRC" 'AvmRuntime'

m27_finish
