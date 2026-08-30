#!/usr/bin/env bash
# verify_browser_bundle_no_native_deps
#
# M28 verification: "the shipped bundle contains no @aztec/native, no cpp_* file, no telemetry
# client and no @aztec/world-state" — DD-9's boundary, asserted on what ships.
#
# ==============================================================================================
# THIS CHECK'S SUBJECT IS AN ABSENCE, AND THIS CAMPAIGN HAS SHIPPED THREE VACUOUS ONES.
# ==============================================================================================
#
# `CAMPAIGN-BRIEF.md` records the archetype twice, and the second time the check's own header cited
# the first: "the shipped import graph does not reach `@aztec/native`", asked of
# `orchestration/node_modules`, where `@aztec/native` is not installed BECAUSE the orchestration
# does not depend on it — which is the thing under test. With a real import of it in a reached
# module the check printed 34 assertions, 0 failures, PASS.
#
# The browser bundle resolves from that same tree, so the naive version of this check has the same
# defect. Three things close it, and each is a different kind of evidence:
#
#   1. A FORBIDDEN THING THAT IS INSTALLED, IS RESOLVABLE, AND IS REACHED BY THE SIBLING ARTEFACT.
#      `msgpackr-extract` and `node-gyp-build-optional-packages` are the mechanism by which a
#      prebuilt `.node` binary gets loaded, they ARE installed under `orchestration/node_modules`,
#      the NODE pass of the SAME build reaches both, and the browser pass reaches neither — while
#      both passes reach `msgpackr` itself. One installed tree, one instrument, two artefacts,
#      opposite answers. That is not an absence from a tree that excludes its subject.
#   2. THE WALKER IS SHOWN TO REPORT `@aztec/native` AND `@aztec/world-state` WHERE THEY EXIST.
#      They cannot be asked of `orchestration/`, so they are asked of `diffsim/`, where both are
#      installed and genuinely imported. This is M19's route (`verify_differential_containment`),
#      reused rather than re-derived.
#   3. AN UNRESOLVABLE IMPORT IN THE BROWSER PASS IS A BUILD FAILURE, NOT A SILENT DROP. That is
#      what makes (1) and (2) sufficient: there is no third state where a forbidden import is
#      present and invisible. `esbuild --platform=browser` refuses, `browser/build.mjs` exits
#      non-zero, and `m27_require_bundle` turns that into a `die`. Asserted structurally below —
#      the browser bundle has exactly two external edges and both are classified — because
#      "nothing is being silently externalised" is the property that closes the gap.
#
# ==============================================================================================
# AND THE NEEDLE IS A PACKAGE BOUNDARY, NOT A SUBSTRING.
# ==============================================================================================
#
# `@aztec/stdlib/dest/world-state/world_state_revision.js` is IN this bundle — three files of it —
# and it has nothing to do with the `@aztec/world-state` package. A `grep world-state` over the
# input list returns 3 and would read as a violation; the package derivation returns 0 and is
# right. Both numbers are measured below, side by side, because "the needle matched more than it
# named" is this campaign's most-repeated scanner defect (`honk` in `chonk`, `world_state` in
# `world_state_reference`, `"DEPENDENCIES vm2"` in `vm2_sim`).
#
# Run: just verify-browser-no-native   (or: just ci-browser-gate)

TEST_NAME="verify_browser_bundle_no_native_deps"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m28_gate.sh"

m28_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v node >/dev/null 2>&1 || die "node is required"
require_work_dir "$M28_WORK" 1

echo "== 1. the built artefacts"

m27_require_bundle
BROWSER="$(m28_scan browser "$BROWSER_DIST" "$BROWSER_DIST/meta.json" node)" \
  || die "the browser bundle scan could not be read; see the message above and $M28_WORK/scan-browser.err"
NODE="$(m28_scan node "$BROWSER_DIST/node" "$BROWSER_DIST/node/meta.json")" \
  || die "the node bundle scan could not be read; see the message above and $M28_WORK/scan-node.err"

B_INPUTS="$(m28_value "$BROWSER" INPUTS)"
B_PACKAGES="$(m28_value "$BROWSER" PACKAGES)"
assert_ge "the browser graph has a substantial number of inputs" 800 "$B_INPUTS"
assert_ge "…drawn from a substantial number of npm packages, so a package absence means something" \
  20 "$B_PACKAGES"
note "browser graph: $B_INPUTS inputs across $B_PACKAGES packages"

echo "== 2. DD-9's four forbidden things are absent from the shipped graph"

for pkg in @aztec/native @aztec/world-state @aztec/telemetry-client; do
  assert_eq "the browser bundle's import graph does not reach $pkg" "0" \
    "$(m28_rows "$BROWSER" FORBIDDEN-PACKAGE | awk -F'\t' -v p="$pkg" '$1 == p { print $2 }')"
done
for label in cpp-file cpp-provider native-addon differential-dir; do
  assert_eq "the browser bundle's inputs contain no $label" "0" \
    "$(m28_rows "$BROWSER" FORBIDDEN-PATH | awk -F'\t' -v l="$label" '$1 == l { print $2 }')"
done

echo "== 3. the package derivation is a BOUNDARY, and the difference is measured"

WORLD_STATE_SUBSTRING="$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(len([k for k in m["inputs"] if "world-state" in k]))' "$BROWSER_DIST/meta.json")"
assert_eq "a SUBSTRING search for 'world-state' over the same inputs finds three files" "3" \
  "$WORLD_STATE_SUBSTRING"
assert_eq "…and every one of them belongs to @aztec/stdlib, not to @aztec/world-state" "3" \
  "$(python3 -c '
import json, sys
m = json.load(open(sys.argv[1]))
print(len([k for k in m["inputs"]
           if "world-state" in k and "node_modules/@aztec/stdlib/" in k]))' "$BROWSER_DIST/meta.json")"
assert_ge "@aztec/stdlib IS reached, so the attribution above is to a package that is really here" 1 \
  "$(m28_rows "$BROWSER" PACKAGE | grep -cx '@aztec/stdlib' || true)"

echo "== 4. CONTROL ONE — a native-addon loader that IS installed, IS resolvable, and IS reached next door"

# Both passes reach msgpackr. The question is whether they reach its OPTIONAL native accelerator.
assert_ge "the browser bundle reaches msgpackr itself, so its subtree is genuinely in this graph" 1 \
  "$(m28_rows "$BROWSER" PACKAGE | grep -cx 'msgpackr' || true)"
assert_ge "…and so does the node bundle" 1 \
  "$(m28_rows "$NODE" PACKAGE | grep -cx 'msgpackr' || true)"
for loader in msgpackr-extract node-gyp-build-optional-packages; do
  assert_dir "$loader IS installed in the tree the browser pass resolves from" \
    "$REPO_ROOT/orchestration/node_modules/$loader"
  assert_eq "the NODE bundle reaches $loader" "1" \
    "$(m28_rows "$NODE" NATIVE-LOADER | awk -F'\t' -v p="$loader" '$1 == p { print $2 }')"
  assert_eq "…and the BROWSER bundle does not" "0" \
    "$(m28_rows "$BROWSER" NATIVE-LOADER | awk -F'\t' -v p="$loader" '$1 == p { print $2 }')"
done
# `msgpackr` declares the accelerator as an OPTIONAL dependency, which is the mechanism the third
# M28 entry is named for. Read from the installed manifest rather than stated.
assert_eq "msgpackr declares msgpackr-extract as an optionalDependency, which is how a native addon arrives" \
  "msgpackr-extract" \
  "$(python3 -c '
import json, sys
print(" ".join(sorted(json.load(open(sys.argv[1])).get("optionalDependencies", {}))))' \
    "$REPO_ROOT/orchestration/node_modules/msgpackr/package.json")"

echo "== 5. CONTROL ONE, on the emitted bytes"

# The graph arm and the byte arm each need a control, for the reason the builtin check gives: a
# bundler that inlined a loader would be invisible to one of them.
browser_js() { grep -rIo "$1" "$BROWSER_DIST"/*.js "$BROWSER_DIST"/chunks/*.js 2>/dev/null | grep -c . || true; }
node_js() { grep -rIo "$1" "$BROWSER_DIST"/node/*.js "$BROWSER_DIST"/node/chunks/*.js 2>/dev/null | grep -c . || true; }
for needle in 'nodejs_module' 'msgpackr-extract' '\.node"'; do
  assert_eq "the browser bundle's emitted bytes contain no [$needle]" "0" "$(browser_js "$needle")"
  assert_ge "…while the SAME grep over the node bundle's bytes finds it" 1 "$(node_js "$needle")"
done

echo "== 6. CONTROL TWO — the walker does report @aztec/native and @aztec/world-state where they exist"

# M19's route, reused. The question cannot be asked of `orchestration/node_modules` (or of the
# browser bundle, which resolves from it), because the packages are not installed there for the
# very reason under test.
for pkg in @aztec/native @aztec/world-state @aztec/telemetry-client; do
  assert_dir "$pkg IS installed in diffsim/, so the control tree can answer the other way" \
    "$REPO_ROOT/diffsim/node_modules/$pkg"
  assert_eq "…and it is NOT installed in the tree the browser pass resolves from" "0" \
    "$([ -d "$REPO_ROOT/orchestration/node_modules/$pkg" ] && echo 1 || echo 0)"
done
PROBE="$M28_WORK/native-reachable.json"
m28_bounded 120 "the native-reachability probe" \
  node "$REPO_ROOT/tools/import_graph.mjs" --entry '@aztec/native' --from "$REPO_ROOT/diffsim" \
  --json "$PROBE" || true
assert_file "the control graph was produced" "$PROBE"
assert_ge "…and it is a real walk rather than an empty one" 50 \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["module_count"])' "$PROBE" 2>/dev/null || echo 0)"
assert_eq "the walker DOES report @aztec/native when a graph really reaches it" "1" \
  "$(python3 -c 'import json,sys; print(1 if "@aztec/native" in json.load(open(sys.argv[1]))["packages"] else 0)' "$PROBE" 2>/dev/null || echo 0)"
assert_ge "…and that graph reaches the prebuilt binary's own loader" 1 \
  "$(python3 -c '
import json, sys
mods = json.load(open(sys.argv[1]))["modules"]
print(len([m for m in mods if "node-gyp-build" in m or "nodejs_module" in m]))' "$PROBE" 2>/dev/null || echo 0)"

echo "== 7. there is no third state: an unresolvable import is a BUILD failure, not a silent drop"

# What makes sections 4 and 6 sufficient. If the browser pass could quietly externalise an import
# it could not resolve, a forbidden package would be neither in the graph nor in the failure — and
# the two controls above would say nothing about it. It cannot: `platform: 'browser'` has no
# implicit externals, and every external edge in this bundle is one the builtin check classifies by
# name — the injected globals file, plus TYPE-ONLY imports esbuild's loader elides.
#
# THE SET GREW FROM TWO TO EIGHT IN M35 and every addition is an elided `import type` in the vendored
# oracle wire layer. It is compared as a SET rather than as a size, so a ninth that is not type-only
# fails here, which is the property this section is for.
EXT="$( { m28_rows "$BROWSER" EXTERNAL-OTHER; m28_rows "$BROWSER" EXTERNAL-INJECT; } | cut -f1 | LC_ALL=C sort | tr '\n' ' ')"
assert_eq "the browser bundle's ENTIRE external set is the injected globals and the elided type imports" \
  "../../node-host/src/reactor.ts ./oracle_registry.js @aztec/foundation/curves/bn254 @aztec/foundation/trees @aztec/stdlib/avm @aztec/stdlib/aztec-address @aztec/stdlib/kernel browser/src/globals.js " \
  "$EXT"
# ...and not one of the @aztec specifiers in that set is a package this bundle may not reach, which
# is the question section 4 asks of the graph and this asks of the residue.
assert_eq "and no DD-9 package is among them" "" \
  "$(for f in '@aztec/pxe' '@aztec/simulator' '@aztec/native' '@aztec/world-state'; do
       case " $EXT " in *" $f"*) printf '%s ' "$f" ;; esac
     done)"
assert_eq "no Node builtin is external either, which would be the other way to leave one unresolved" \
  "" "$(m28_rows "$BROWSER" BUILTIN-EXTERNAL)"
# And the node pass DOES have implicit externals, which is what says the property above is a
# property of this pass rather than of esbuild.
assert_ge "while the node pass externalises many things, so 'no implicit externals' is a real distinction" 20 \
  "$(m28_rows "$NODE" BUILTIN-EXTERNAL | grep -c . || true)"

echo "== 8. the exclusion is a declared decision, not an accident of what happened to be installed"

PKGJSON="$(cat "$REPO_ROOT/orchestration/package.json")"
assert_true "the shipped package's own manifest records why @aztec/native is absent" \
  str_has_sub "$PKGJSON" "DELIBERATELY ABSENT"
assert_true "…and names the world-state replacement it uses instead" \
  str_has_sub "$PKGJSON" "world_state_reference"
assert_eq "the shipped package declares none of the three as a dependency of any kind" "0" \
  "$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
bad = 0
for field in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
    for name in d.get(field, {}):
        if name in ("@aztec/native", "@aztec/world-state", "@aztec/telemetry-client"):
            bad += 1
print(bad)' "$REPO_ROOT/orchestration/package.json")"
assert_ge "…while declaring the @aztec packages it legitimately uses, so that zero is not an empty list" 3 \
  "$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1])).get("dependencies", {})))' "$REPO_ROOT/orchestration/package.json")"

m28_finish
