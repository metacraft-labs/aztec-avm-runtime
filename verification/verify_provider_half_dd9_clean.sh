#!/usr/bin/env bash
# verify_provider_half_dd9_clean
#
# M33 verification: "no @aztec/native, no @aztec/world-state, no cpp_* in the built provider
# bundle. Control: a planted import is caught."
#
# ===========================================================================================
# THE DEFECT THIS CHECK IS BUILT AGAINST, BECAUSE IT SHIPPED TWICE
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md` records the same defect in two disguises, and both are exactly this check's
# shape: *"an absence asked of a tree that excludes the subject by construction"*. "No published
# `@aztec` package ships a `ForkCheckpoint`", measured against a `node_modules` from which
# `@aztec/world-state` is deliberately absent. And, in a check whose own header cited the first one,
# "the shipped import graph does not reach `@aztec/native`" asked of a tree where importing it is
# `MODULE_NOT_FOUND`. With a real import of it in a reached module, that check printed
# **34 assertions, 0 failures, PASS**.
#
# So three things are done differently here.
#
#  1. **THE METAFILE, NOT THE BYTES.** esbuild records every INPUT PATH it read, so a package that
#     contributed one byte is visible as `node_modules/@aztec/native/…` whether or not its NAME
#     survives minification. A grep of minified output is the byte-level version of the same
#     defect — the needle cannot match a package that was inlined.
#  2. **A CONTROL BUILT ON A TREE WHERE THE SUBJECT RESOLVES.** The control creates a stub
#     `@aztec/native` and `@aztec/world-state` in a scratch `node_modules`, plants an import of both
#     in a copy of the wallet entry, builds it with the same esbuild and the same shims, and
#     requires the scanner to REPORT them. That is the brief's own remedy, stated in as many words:
#     *"put the negative control on a tree where the package IS resolvable"*.
#  3. **THE SUBJECT AND THE CONTROL GO THROUGH THE SAME READING.** Both are read with
#     `_m33_dd9.py raw`, the same tally, so one edit moves both. M32's review's finding was a
#     control that was a second expression over a second buffer and therefore constrained only
#     itself.
#
# ===========================================================================================
# AND THE PACKAGING FACT, RE-DERIVED OFFLINE
# ===========================================================================================
#
# M33's enumeration found that the provider half of `@aztec/wallet-sdk` is separable from
# `@aztec/pxe` in the SOURCE — 408 value-reachable files, zero pxe edges — and not separable in the
# PACKAGE, because npm has no subpath-scoped install and `wallet-sdk`'s own `dependencies` names
# `@aztec/pxe`, which reaches `@aztec/native` and `@aztec/world-state`. That is the sentence the
# vendoring decision rests on, so it is re-derived here from the anchor's own `package.json` files
# out of the object store, with `@aztec/aztec.js` — which reaches none of them — as the control that
# the walker can answer both ways.
#
# Run: just verify-m33-dd9

TEST_NAME="verify_provider_half_dd9_clean"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m33_wallet.sh"

m33_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m27_require_esbuild
m33_require_arms

WORK="$M33_WORK/dd9"
rm -rf "$WORK"
mkdir -p "$WORK"

echo "== 1. the built wallet entry exists and is a real bundle"

assert_file "the wallet entry was built" "$BROWSER_DIST/wallet.js"
assert_file "…and the build's metafile is there" "$BROWSER_DIST/meta.json"
assert_file "…and its chunk report" "$BROWSER_DIST/chunks.json"

ENTRY="$(python3 "$VERIFY_DIR/_m33_dd9.py" entry "$BROWSER_DIST/meta.json" "$BROWSER_DIST/chunks.json" wallet)"
e() { printf '%s\n' "$ENTRY" | sed -n "s/^$1\t//p"; }

EAGER_FILES="$(e EAGER-FILES)"
EAGER_BYTES="$(e EAGER-BYTES)"
ALL_FILES="$(e ALL-FILES)"
note "wallet entry: $EAGER_FILES eager file(s), $EAGER_BYTES raw bytes; $ALL_FILES reachable output(s)"

# NON-EMPTINESS FIRST. Every assertion below this line is an absence, and an absence over an empty
# graph is this campaign's most-repeated defect.
assert_ge "the wallet entry's eager closure is several files" 3 "$EAGER_FILES"
assert_ge "…and a real bundle rather than a stub" 500000 "$EAGER_BYTES"
assert_ge "…and its reachable closure is larger still (the lazy chunks are reachable)" \
  "$EAGER_FILES" "$ALL_FILES"
assert_eq "every eager output was attributed; nothing was silently unplaced" "" "$(e UNPLACED)"

echo "== 2. DD-9 ON THE BUILT ARTEFACT"

assert_eq "no DD-9 package is in the wallet entry's EAGER set" "" "$(e FORBIDDEN-EAGER)"
assert_eq "…nor anywhere in its reachable closure, dynamic imports included" "" "$(e FORBIDDEN-ALL)"

# Named one at a time, so a failure says WHICH — and each is asked of the reachable closure, which
# is the larger of the two readings.
PKG_ALL="$(printf '%s\n' "$ENTRY" | sed -n 's/^PKG-ALL\t//p')"
assert_ge "the package attribution found a substantial number of packages" 20 \
  "$(printf '%s\n' "$PKG_ALL" | grep -c . || true)"
for pkg in '@aztec/native' '@aztec/world-state' '@aztec/pxe' '@aztec/simulator'; do
  hits="$(printf '%s\n' "$PKG_ALL" | awk -F'\t' -v n="$pkg" '$1 == n' | grep -c . || true)"
  assert_eq "the wallet bundle does not reach '$pkg'" "0" "$hits"
done

# `cpp_*`: the NAPI AVM's own symbol prefix. This one IS a byte-level needle, and it is paired with
# a needle that must MATCH, so a scan that silently stopped matching drives both to zero.
#
# OVER THE WHOLE EAGER SET, NOT OVER `wallet.js` ALONE, and the change was forced by M34 rather than
# chosen. With an eighth entry point sharing the wallet's modules, esbuild hoisted the protocol and
# the provider into a shared chunk and `wallet.js` became a re-export stub — so the positive-control
# needle `aztec-wallet-` stopped matching, which is the paired needle doing its job. The set is what
# a page downloads before it does anything, so this is also the stronger question.
# The keys are repository-relative paths (`browser/dist/chunks/chunk-*.js`), which is what the
# metafile carries, so they are read from `$REPO_ROOT`.
WALLET_BYTES="$(cd "$REPO_ROOT" && for k in $(e EAGER-KEY); do cat "$k"; done)"
assert_ge "the eager set was read as bytes, and it is a real bundle" 500000 "${#WALLET_BYTES}"
assert_false "no cpp_ symbol survives into the wallet entry's eager bytes" \
  str_has_sub "$WALLET_BYTES" 'cpp_'
assert_true "…and the scan CAN match something in that same set" \
  str_has_sub "$WALLET_BYTES" 'aztec-wallet-'

echo "== 3. no Node builtin is reachable from the wallet entry"

BUILTINS="$(printf '%s\n' "$ENTRY" | sed -n 's/^BUILTIN\t//p')"
assert_eq "no Node builtin specifier survives in the wallet entry's eager files" "" "$BUILTINS"

echo "== 4. THE WALLET SURFACE IS DISJOINT FROM THE REFERENCE BUNDLE'S — both directions"

# DD-11's reason for a separate entry point, asserted rather than asserted about. If a wallet export
# leaked into `browser.js` a page would pay for a protocol it did not ask for; if a wallet export
# vanished from `wallet.js` the seam would be gone and nothing else would notice.
BROWSER_EXPORTS="$( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./browser.js');
console.log(Object.keys(m).sort().join('\n'));
" 2>&1 )"
WALLET_EXPORTS="$(m33_bundle_exports)"
assert_ge "the reference bundle exports a real surface" 40 \
  "$(printf '%s\n' "$BROWSER_EXPORTS" | grep -c . || true)"
assert_ge "…and the wallet bundle does too" 15 \
  "$(printf '%s\n' "$WALLET_EXPORTS" | grep -c . || true)"
# NOT `comm`. Its first run here printed "file 1 is not in sorted order" three times and still
# produced an empty answer — an emptiness produced by a tool that had refused to compare, which is
# `CAMPAIGN-BRIEF.md`'s "both sides read, both sides zero" wearing a warning message. A set
# intersection, and a POSITIVE CONTROL that the intersector finds an overlap when there is one.
printf '%s\n' "$BROWSER_EXPORTS" > "$WORK/browser_exports.txt"
printf '%s\n' "$WALLET_EXPORTS" > "$WORK/wallet_exports.txt"
intersect() { # <file-a> <file-b>
  python3 -c '
import sys
a = {l.strip() for l in open(sys.argv[1]) if l.strip()}
b = {l.strip() for l in open(sys.argv[2]) if l.strip()}
print(" ".join(sorted(a & b)))' "$1" "$2"
}
assert_eq "no wallet export is in the reference bundle" "" "$(intersect "$WORK/browser_exports.txt" "$WORK/wallet_exports.txt")"
# The control runs through the SAME function: one name from each side, put on both lists.
{ cat "$WORK/wallet_exports.txt"; head -1 "$WORK/browser_exports.txt"; } > "$WORK/wallet_plus.txt"
assert_eq "…and the intersection CAN report an overlap, so the emptiness is a measurement" \
  "$(head -1 "$WORK/browser_exports.txt")" \
  "$(intersect "$WORK/browser_exports.txt" "$WORK/wallet_plus.txt")"

# The declaration and the artefact, compared as SETS in both directions — M32's WORKER_PROTOCOL_BACKING
# rule. `WALLET_ENTRY_OPS` is itself an export, so it is the one name excluded, exactly as M32
# excludes `call`.
DECLARED="$(m33_arm protocol.declaredOps)"
m33_absent "protocol.declaredOps=$DECLARED"
DECLARED_SORTED="$(python3 -c '
import json, sys
print("\n".join(sorted(json.loads(sys.argv[1]))))' "$DECLARED")"
ACTUAL_SORTED="$(printf '%s\n' "$WALLET_EXPORTS" | grep -v '^WALLET_ENTRY_OPS$' | LC_ALL=C sort)"
assert_eq "the entry's declared operations are EXACTLY what the bundle exports" \
  "$(printf '%s\n' "$DECLARED_SORTED" | LC_ALL=C sort | tr '\n' ' ')" \
  "$(printf '%s\n' "$ACTUAL_SORTED" | tr '\n' ' ')"
assert_ge "…over a non-empty declaration" 15 \
  "$(printf '%s\n' "$DECLARED_SORTED" | grep -c . || true)"

echo "== 5. THE CONTROL — a planted import IS caught, on a tree where the package resolves"

CTRL="$WORK/control"
mkdir -p "$CTRL/node_modules/@aztec/native" "$CTRL/node_modules/@aztec/world-state"
for stub in native world-state; do
  printf '{"name":"@aztec/%s","version":"0.0.0","main":"index.js","type":"module"}\n' "$stub" \
    > "$CTRL/node_modules/@aztec/$stub/package.json"
  printf 'export const planted_%s = "cpp_avmSimulate";\n' "${stub//-/_}" \
    > "$CTRL/node_modules/@aztec/$stub/index.js"
done
cat > "$CTRL/control_entry.ts" <<EOF
import { planted_native } from '@aztec/native';
import { planted_world_state } from '@aztec/world-state';
export * from '$M33_ENTRY_SRC';
export const planted = [planted_native, planted_world_state];
EOF
assert_file "the control entry was written" "$CTRL/control_entry.ts"
assert_file "…and the stub package it imports exists" "$CTRL/node_modules/@aztec/native/index.js"

# The SUBJECT's own reading, through the same mode the control is read with, so the two answers are
# produced by one code path.
SUBJ_RAW="$(python3 "$VERIFY_DIR/_m33_dd9.py" raw "$BROWSER_DIST/meta.json")"
assert_ge "the subject's raw reading covers the whole build" 20 \
  "$(printf '%s\n' "$SUBJ_RAW" | sed -n 's/^RAW-PKG\t//p' | grep -c . || true)"
assert_eq "…and it reports no DD-9 package" "" \
  "$(printf '%s\n' "$SUBJ_RAW" | sed -n 's/^RAW-FORBIDDEN\t//p' | tr '\n' ' ' | sed 's/ $//')"

CTRL_META="$CTRL/meta.json"
m33_bounded 600 "the control bundle build" \
  "$M27_ESBUILD" "$CTRL/control_entry.ts" --bundle --format=esm --platform=browser \
  --outfile="$CTRL/control.js" "--metafile=$CTRL_META" \
  "--alias:util=$REPO_ROOT/browser-probe/shims/util.js" \
  "--alias:assert=$REPO_ROOT/browser-probe/shims/assert.js" \
  "--alias:tty=$REPO_ROOT/browser-probe/shims/tty.js" \
  "--alias:module=$BROWSER_SRC/shims/module.js" \
  "--inject:$BROWSER_SRC/globals.js"
CTRL_RC=$?
assert_eq "the control bundle builds" "0" "$CTRL_RC"
assert_file "…and produces a metafile" "$CTRL_META"

CTRL_RAW="$(python3 "$VERIFY_DIR/_m33_dd9.py" raw "$CTRL_META")"
CTRL_FORBIDDEN="$(printf '%s\n' "$CTRL_RAW" | sed -n 's/^RAW-FORBIDDEN\t//p' | awk -F'\t' '{print $1}' | LC_ALL=C sort | tr '\n' ' ')"
note "the control reports: ${CTRL_FORBIDDEN:-<nothing>}"
assert_eq "the SAME scanner reports both planted packages when they are there" \
  "@aztec/native @aztec/world-state " "$CTRL_FORBIDDEN"
assert_ge "…over a control build that is a real bundle" 20 \
  "$(printf '%s\n' "$CTRL_RAW" | sed -n 's/^RAW-PKG\t//p' | grep -c . || true)"
# AND THE CONTROL'S OWN NEEDLE: the planted module's `cpp_` string reaches the emitted bytes, so
# §2's `cpp_` absence is measured by a needle seen to match.
assert_true "the control's bytes DO carry a cpp_ symbol, so §2's needle can match" \
  str_has_sub "$(cat "$CTRL/control.js")" 'cpp_'

echo "== 6. THE PACKAGING FACT, re-derived from the anchor's own package.json files"

PKGS="$WORK/anchor-pkgs/yarn-project"
mkdir -p "$PKGS"
ANCHOR="$(m33_cpp_anchor)"
while IFS= read -r p; do
  d="$PKGS/$(basename "$(dirname "$p")")"
  mkdir -p "$d"
  git -C "$FORK_ROOT" show "$ANCHOR:$p" > "$d/package.json" 2>/dev/null || true
done < <(git -C "$FORK_ROOT" ls-tree -r --name-only "$ANCHOR" yarn-project \
           | grep -E '^yarn-project/[^/]+/package\.json$')
assert_ge "the anchor's workspace package manifests were materialised" 40 \
  "$(find "$PKGS" -name package.json | wc -l)"

DEPS="$(python3 "$VERIFY_DIR/_m33_dd9.py" deps "$PKGS" \
  '@aztec/wallet-sdk' '@aztec/aztec.js' '@aztec/pxe' '@aztec/simulator' '@aztec/wallets')"
printf '%s\n' "$DEPS" > "$WORK/deps.tsv"
d_reach() { printf '%s\n' "$DEPS" | awk -F'\t' -v n="$1" '$1=="REACHES-FORBIDDEN" && $2==n {print $3}'; }
d_direct() { printf '%s\n' "$DEPS" | awk -F'\t' -v n="$1" '$1=="DIRECT" && $2==n {print $3}'; }
d_size() { printf '%s\n' "$DEPS" | awk -F'\t' -v n="$1" '$1=="CLOSURE" && $2==n {print $3}'; }

assert_ge "the walker read a real workspace" 40 \
  "$(printf '%s\n' "$DEPS" | sed -n 's/^WORKSPACE\t//p')"
note "@aztec/wallet-sdk closure $(d_size '@aztec/wallet-sdk'), @aztec/aztec.js closure $(d_size '@aztec/aztec.js')"

# THE SENTENCE THE VENDORING DECISION RESTS ON.
assert_true "@aztec/wallet-sdk names @aztec/pxe among its OWN declared dependencies" \
  str_has_sub "$(d_direct '@aztec/wallet-sdk')" '@aztec/pxe'
assert_eq "…so taking the package takes all four DD-9 packages" \
  "@aztec/native,@aztec/pxe,@aztec/simulator,@aztec/world-state" "$(d_reach '@aztec/wallet-sdk')"
assert_true "@aztec/pxe is why: it depends on @aztec/simulator" \
  str_has_sub "$(d_direct '@aztec/pxe')" '@aztec/simulator'
assert_true "…and @aztec/simulator depends on @aztec/native" \
  str_has_sub "$(d_direct '@aztec/simulator')" '@aztec/native'
assert_true "…and on @aztec/world-state" \
  str_has_sub "$(d_direct '@aztec/simulator')" '@aztec/world-state'

# THE CONTROL FOR THE WALKER: the package M33 DOES depend on reaches none of them, so
# "reaches-forbidden is empty" is an answer the walker has been seen to give both ways.
assert_eq "@aztec/aztec.js — the package M33 adds — reaches NONE of the four" "" \
  "$(d_reach '@aztec/aztec.js')"
assert_ge "…over a non-trivial closure, so the emptiness is not an empty walk" 10 \
  "$(d_size '@aztec/aztec.js')"

# AND @aztec/wallets, the tenth near-miss: recorded as rejected with a measured reason.
assert_eq "@aztec/wallets — the embedded wallet package — reaches all four too" \
  "@aztec/native,@aztec/pxe,@aztec/simulator,@aztec/world-state" "$(d_reach '@aztec/wallets')"
assert_true "…because it depends on both @aztec/pxe and @aztec/wallet-sdk" \
  str_has_sub "$(d_direct '@aztec/wallets')" '@aztec/wallet-sdk'

echo "== 7. and orchestration's declared dependencies are the four plus aztec.js, and nothing else"

ORCH_DEPS="$(python3 -c '
import json, sys
print(" ".join(sorted(json.load(open(sys.argv[1]))["dependencies"])))' "$REPO_ROOT/orchestration/package.json")"
note "orchestration depends on: $ORCH_DEPS"
assert_eq "the orchestration's dependency list is exactly what M33 leaves it" \
  "@aztec/aztec.js @aztec/constants @aztec/foundation @aztec/protocol-contracts @aztec/stdlib" \
  "$ORCH_DEPS"
for forbidden in '@aztec/pxe' '@aztec/wallet-sdk' '@aztec/wallets' '@aztec/simulator' '@aztec/native' '@aztec/world-state'; do
  assert_false "…and it does not declare '$forbidden'" str_has_word "$ORCH_DEPS" "$forbidden"
done
# AND THE INSTALLED TREE, not only the declaration — because npm installs transitively and a
# declaration is not an installation. The `@aztec` scope directory is asserted present first, so the
# six absences below are not six absences from a directory that is not there.
assert_dir "the installed @aztec scope directory exists" "$REPO_ROOT/orchestration/node_modules/@aztec"
assert_true "…and a package that IS installed is found by this predicate" \
  test -d "$REPO_ROOT/orchestration/node_modules/@aztec/aztec.js"
for forbidden in native world-state pxe simulator wallet-sdk wallets; do
  assert_false "…'@aztec/$forbidden' is not in the installed tree either" \
    test -d "$REPO_ROOT/orchestration/node_modules/@aztec/$forbidden"
done

echo "== 8. THE ENUMERATION, RE-DERIVED — the number M33's decision rests on"

# `CAMPAIGN-BRIEF.md`: "a figure nobody re-derives rots", and a number a milestone publishes about
# its own open question is the least likely to be re-derived and the most likely to rot. This is
# the milestone's headline number, so it is re-run out of the object store on every check.
m33_require_anchor_tree

closure() { # <group>
  python3 "$VERIFY_DIR/_m33_closure.py" "$M33_ANCHOR_TREE" "$1"
}
field() { printf '%s\n' "$2" | sed -n "s/^$1\t//p"; }

PROVIDER="$(closure provider)"
WALLETH="$(closure wallet)"
PROTOCOL="$(closure protocol)"
SCHEMA="$(closure schema)"

P_FILES="$(field FILES "$PROVIDER")"; P_LINES="$(field LINES "$PROVIDER")"
W_FILES="$(field FILES "$WALLETH")"; W_LINES="$(field LINES "$WALLETH")"
T_FILES="$(field FILES "$PROTOCOL")"; T_LINES="$(field LINES "$PROTOCOL")"
S_FILES="$(field FILES "$SCHEMA")"; S_LINES="$(field LINES "$SCHEMA")"
{
  printf 'provider\t%s\t%s\n' "$P_FILES" "$P_LINES"
  printf 'wallet\t%s\t%s\n'   "$W_FILES" "$W_LINES"
  printf 'protocol\t%s\t%s\n' "$T_FILES" "$T_LINES"
  printf 'schema\t%s\t%s\n'   "$S_FILES" "$S_LINES"
  # THE TWO PXE COUNTS, so §9 compares them against the document too. M33's review found this exact
  # figure stated as "four" in `entry_wallet.ts` and in RI-88 while the check asserted three and the
  # write-up said three: four is derivation 2's answer and nothing re-derived it. A figure that has
  # already rotted once is the one to bind.
  printf 'pxe-edges\t%s\t%s\n' \
    "$(printf '%s\n' "$WALLETH" | sed -n 's/^PXE_EDGE\t//p' | grep -c . || true)" \
    "$(printf '%s\n' "$WALLETH" | sed -n 's/^PXE_CLAUSE\t//p' | grep -c . || true)"
} > "$WORK/closure.tsv"
note "provider $P_FILES/$P_LINES, wallet $W_FILES/$W_LINES, protocol $T_FILES/$T_LINES, schema $S_FILES/$S_LINES"

# THE SCANNER'S OWN RESIDUE FIRST. A walker that silently drops an edge turns a containment
# measurement into an undercount in the direction that reads as good news.
for g in "$PROVIDER" "$WALLETH" "$PROTOCOL" "$SCHEMA"; do
  assert_eq "the closure walker classified every import clause" "0" "$(field UNCLASSIFIED "$g")"
done
for g in "$PROVIDER" "$PROTOCOL" "$SCHEMA"; do
  assert_eq "…and placed every workspace specifier it followed" "0" "$(field UNPLACEABLE "$g")"
done
# THE WALLET HALF IS THE EXCEPTION AND IT IS NAMED RATHER THAN EXCUSED: three specifiers
# `@aztec/pxe` reaches for that `@aztec/standard-contracts` does not export at this anchor. Pinned
# exactly, so a fourth would fail.
assert_eq "the wallet half's unplaceable specifiers are the three pxe-side ones" "3" \
  "$(field UNPLACEABLE "$WALLETH")"
assert_true "…and all three are @aztec/pxe reaching into @aztec/standard-contracts" \
  str_has_sub "$(printf '%s\n' "$WALLETH" | sed -n 's/^UNPLACEABLE_SPEC\t//p')" \
  'yarn-project/pxe/src/entrypoints/client/lazy/utils.ts'


# THE SEPARATION, in both directions.
assert_eq "the PROVIDER half reaches no DD-9 package" "" "$(field REACHES "$PROVIDER")"
assert_true "…and the WALLET half reaches @aztec/pxe, so the walker can answer both ways" \
  str_has_line "$(field REACHES "$WALLETH")" '@aztec/pxe'
PXE_EDGES="$(printf '%s\n' "$WALLETH" | sed -n 's/^PXE_EDGE\t//p')"
assert_eq "…by exactly the three VALUE edges this milestone names" "3" \
  "$(printf '%s\n' "$PXE_EDGES" | grep -c . || true)"
assert_true "…in base_wallet.ts" str_has_sub "$PXE_EDGES" 'base-wallet/base_wallet.ts'
assert_true "…and in base-wallet/utils.ts" str_has_sub "$PXE_EDGES" 'base-wallet/utils.ts'

# THE PROTOCOL LAYER'S ZERO, which is what makes vendoring three files enough.
assert_eq "the protocol declaration has NO value dependency on any workspace package" "0" \
  "$(printf '%s\n' "$PROTOCOL" | awk -F'\t' '$1=="WS_PKGS" {print $2}')"
assert_eq "…nor on any external one" "0" \
  "$(printf '%s\n' "$PROTOCOL" | awk -F'\t' '$1=="EXT_PKGS" {print $2}')"
# THE CONTROL FOR THAT PAIR OF ZEROES: the same two fields, over a group where they are NOT zero.
assert_eq "…while the provider half's workspace-package count is nine, so the zeroes are readings" \
  "9" "$(printf '%s\n' "$PROVIDER" | awk -F'\t' '$1=="WS_PKGS" {print $2}')"
assert_eq "…and it is exactly the three files this repository vendors" "3" "$T_FILES"

# THE SPELLINGS THE WALKER CANNOT FOLLOW, COUNTED — because "the provider half reaches no
# @aztec/pxe" is an absence, and an absence is only as wide as the spellings that were enumerated.
# `CAMPAIGN-BRIEF.md` says to write down which those were: this walker matches STATIC `import … from`,
# `export … from` and bare `import '…'`, and does NOT follow `import()` or `require()`. So the count
# of what it cannot follow is asserted zero for the provider half rather than left unsaid — an
# `import('@aztec/pxe')` added upstream would otherwise leave every pxe assertion green over a graph
# that reaches it.
assert_eq "the provider closure contains no dynamic import() the walker cannot follow" "0" \
  "$(field DYNAMIC "$PROVIDER")"
assert_eq "…and no require() either" "0" "$(field REQUIRE "$PROVIDER")"
# TWO CONTROLS, because a scanner that stopped matching would report zero for the same reason.
# The first is a real tree: the WALLET half has three, all of them JSON contract artifacts.
assert_eq "…while the WALLET half has three, so the scanner finds them where they exist" "3" \
  "$(field DYNAMIC "$WALLETH")"
assert_true "…and they are the lazily-loaded contract artifacts, not a door to a package" \
  str_has_sub "$(printf '%s\n' "$WALLETH" | sed -n 's/^DYNAMIC_SPEC\t//p')" 'artifacts/FeeJuice.json'
# The second is the scanner's own fixture, which it must FIND before its zero is believed — M29's
# review's remedy, where a needle was believed about a bundle without being seen to match anything.
assert_eq "the dynamic-import scanner matches both shapes in its own fixture" "2" \
  "$(field DYN_FIXTURE_SITES "$PROVIDER")"
assert_eq "…and reads the literal specifier out of the one that has one" "1" \
  "$(field DYN_FIXTURE_SPECS "$PROVIDER")"
assert_eq "…and the require() scanner matches its fixture too" "1" \
  "$(field REQUIRE_FIXTURE_SITES "$PROVIDER")"

# THE SIX GENERATED FILES, counted rather than assumed away.
assert_eq "the provider closure's unresolved specifiers are the six generated files" "6" \
  "$(field UNRESOLVED "$PROVIDER")"
UNRES="$(printf '%s\n' "$PROVIDER" | sed -n 's/^UNRESOLVED_SPEC\t//p')"
assert_true "…including the generated constants" str_has_sub "$UNRES" 'constants.gen.js'
assert_true "…and the generated protocol-contract data" str_has_sub "$UNRES" 'protocol_contract_data.js'

echo "== 9. WALLET-BOUNDARY.md's FIGURES, re-derived and compared AGAINST THE DOCUMENT"

# M27's shape, with M24's review's correction applied: each figure is looked for on the line that
# NAMES ITS SUBJECT, never anywhere in the file, because a check that matched `| <number> |`
# file-wide once passed a document whose two rows had been swapped.
assert_file "the write-up exists" "$M33_DOC"
DOCFIG="$(python3 "$VERIFY_DIR/_m33_doc_figures.py" "$M33_DOC" "$BROWSER_DIST/chunks.json" \
  "$BROWSER_DIST/meta.json" "$M33_ARMS" "$WORK/closure.tsv" "$WORK/deps.tsv")"
d() { printf '%s\n' "$DOCFIG" | sed -n "s/^$1\t//p"; }
note "$(d CHECKED) figure(s) re-derived and compared against $M33_DOC"
# NON-EMPTINESS FIRST: a comparer that found no rows reports no disagreements either.
assert_ge "the comparer found the document's rows" 20 "$(d CHECKED)"
assert_eq "every figure in the write-up equals what the artefacts measure" "" "$(d BAD)"
assert_eq "…and every row the comparer is about is present in the document" "" "$(d MISSING)"

echo "== 10. AND THE ARTEFACT IS LOADED IN A PAGE, because §1-§9 are all config-level"

# ===========================================================================================
# THE ONE CLAIM NODE CANNOT MAKE, AND M33 SHIPPED WITHOUT IT
# ===========================================================================================
#
# Everything above this line reads the METAFILE, the emitted bytes or a package manifest. That is
# the right instrument for "which packages are in the graph" and it is the wrong one for "a page can
# evaluate this", and `CAMPAIGN-BRIEF.md` records M27's lesson that a config-level assertion is
# weaker than an observed one. M33's review measured the size of the gap rather than asserting it:
#
#   `const _nodeOnlyProbe = setImmediate;` at the top of `port_wallet_provider.ts` — a Node GLOBAL,
#   read at module-evaluation time. Not an import, so no metafile records it. Not `Buffer` and not
#   `process`, so `browser/src/globals.js` does not supply it and `verify_browser_bundle_builds`'s
#   free-identifier scan does not name it.
#
# Rebuilt, that bundle imports fine in Node and dies in Chromium with
# `ReferenceError: setImmediate is not defined` — and `just verify-m33` was **224, 4/4, exit 0**,
# `verify_browser_bundle_no_node_builtins` **64 / 0**, `verify_browser_bundle_no_native_deps`
# **44 / 0**, `smoke_browser_headless_full_flow` **50 / 0** (it drives Chromium, over `browser.js`).
# Nothing in the repository referenced `wallet.js` from a page — grepped, and the answer was zero.
#
# So the smallest browser claim that closes it is made here: the module EVALUATES in a page and
# exports what it declares. The handshake stays in Node, and `WALLET-BOUNDARY.md` §5 stays the
# boundary, because a `MessagePort` and WebCrypto are the same thing in both engines. The CONTROL is
# the plant above, kept: a second served site whose `wallet.js` carries that one free identifier,
# which the page must REPORT — so "it evaluated" is an answer this instrument has been seen to give
# both ways.

m33_require_browser_arm

# THE VERDICT FIRST, AND ITS OWN PRESENCE CHECK, because everything below it is a field the probe
# only records when the module evaluated. Calibrated with the plant: read in the other order the
# check dies at `m33_absent` naming six absent fields, which is true and is the wrong diagnosis —
# the defect is that the module did not evaluate, and this is the line that says so.
B_EVAL="$(m33_browser subject.evaluated)"
m33_absent "subject.evaluated=$B_EVAL"
assert_eq "the wallet entry EVALUATES in a page" "true" "$B_EVAL"
[ "$B_EVAL" = "true" ] || die "the built wallet entry did not evaluate in Chromium:
             $(m33_browser subject.name): $(m33_browser subject.message)
             This is the condition no metafile assertion can reach. See $M33_BROWSER_ARM."

B_EXPORTS="$(m33_browser subject.exports)"
B_OPS="$(m33_browser subject.ops)"
B_TYPES="$(m33_browser subject.messageTypeCount)"
B_DOC="$(m33_browser subject.hasDocument)"
B_SUBTLE="$(m33_browser subject.hasSubtleCrypto)"
B_CHANNEL="$(m33_browser subject.hasMessageChannel)"
B_ERRORS="$(m33_browser subject.pageErrors)"
B_FETCHED="$(m33_browser subject.requestedWalletJs)"
C_EVAL="$(m33_browser control.evaluated)"
C_NAME="$(m33_browser control.name)"
C_MSG="$(m33_browser control.message)"
m33_absent "subject.exports=$B_EXPORTS" "subject.ops=$B_OPS" \
  "subject.messageTypeCount=$B_TYPES" "subject.hasDocument=$B_DOC" \
  "subject.hasSubtleCrypto=$B_SUBTLE" "subject.hasMessageChannel=$B_CHANNEL" \
  "subject.pageErrors=$B_ERRORS" "subject.requestedWalletJs=$B_FETCHED" \
  "control.evaluated=$C_EVAL" "control.name=$C_NAME" "control.message=$C_MSG"

# IT REALLY IS A PAGE. Asked of the page rather than inferred from the file it was built into,
# which is M32's finding about a worker being asked whether it has a `document`.
assert_eq "the probe ran in something that HAS a document, so this is a page" "true" "$B_DOC"
assert_eq "…and the module was FETCHED over HTTP rather than inlined into the probe" "1" "$B_FETCHED"

assert_eq "…with no page-level exception beside it" "[]" "$B_ERRORS"
# The export set the PAGE sees, against the declaration read out of the same bundle by Node. Two
# engines, two readings, one artefact.
assert_eq "…and the exports the PAGE sees are the declared operations plus the declaration itself" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.loads(sys.argv[1]) + ["WALLET_ENTRY_OPS"])))' "$(m33_arm protocol.declaredOps)")" \
  "$(python3 -c '
import json, sys
print(",".join(sorted(json.loads(sys.argv[1]))))' "$B_EXPORTS")"
assert_eq "…and the operation list the page reads is the one Node reads" \
  "$(m33_arm protocol.declaredOps)" "$B_OPS"
assert_eq "…and the protocol enum crossed intact: the same eleven members" \
  "$(python3 -c '
import json, sys
print(len(json.loads(sys.argv[1])))' "$(m33_arm protocol.messageTypes)")" "$B_TYPES"

# THE TWO PLATFORM FACTS THE HANDSHAKE NEEDS, measured where it would run rather than assumed.
# `crypto.subtle` is the sharp one: a browser withholds it outside a SECURE CONTEXT, and Node has
# no such rule, so this is a condition the Node arms cannot see at all.
assert_eq "the page has WebCrypto's SubtleCrypto — which Node cannot tell us, because a browser
             withholds it outside a secure context" "true" "$B_SUBTLE"
assert_eq "…and a MessageChannel, which is the transport" "true" "$B_CHANNEL"

# THE CONTROL, through the same probe, the same server and the same browser.
assert_eq "the SAME probe reports a module that does NOT evaluate" "false" "$C_EVAL"
assert_eq "…as a ReferenceError" "ReferenceError" "$C_NAME"
assert_true "…naming the Node-only global, which is the defect no metafile can see" \
  str_has_sub "$C_MSG" 'setImmediate'

m33_finish
