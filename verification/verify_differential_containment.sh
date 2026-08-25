#!/usr/bin/env bash
# verify_differential_containment
#
# `npm pack` output and the shipped bundle's import graph contain no `cpp_*` file, no
# `@aztec/native` and no optional native dependency.
#
# WHY IT IS A HARD REQUIREMENT AND NOT A TIDINESS RULE. `@aztec/native` loads a prebuilt
# `nodejs_module.node`, so a published package that can reach it is a package that needs a native
# addon for the four architectures bb.js ships one for — and cannot run in a browser at all, which
# is where M27 and M28 have to take it. DD-9 forbids the reachable path; this check measures the
# artefact rather than the intention.
#
# FOUR QUESTIONS, ASKED OF TREES THAT COULD ANSWER THEM THE OTHER WAY. The campaign has shipped an
# absence measured against a tree the subject was deliberately absent from ("no published @aztec
# package ships a ForkCheckpoint", asked of a node_modules @aztec/world-state is not installed in),
# so each half below names the tree it interrogates and asserts that the tree is non-empty first.
#
# Run: just verify-m19

TEST_NAME="verify_differential_containment"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

command -v node >/dev/null 2>&1 || die "node is required"
command -v npm  >/dev/null 2>&1 || die "npm is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_work_dir "$M19_WORK" 1
ORCH="$REPO_ROOT/orchestration"
assert_dir "the shipped package is present" "$ORCH"

# ---- 1. the package's DECLARED dependencies -------------------------------
deps="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for k in ("dependencies", "devDependencies", "optionalDependencies", "peerDependencies"):
    for name in sorted(d.get(k, {})):
        print(f"{k} {name}")' "$ORCH/package.json")"
assert_ge "the shipped package declares dependencies at all, so this is not a vacuous absence" 3 \
  "$(printf '%s\n' "$deps" | grep -c . )"
assert_eq "it declares no optionalDependencies (which is how a native addon usually arrives)" "0" \
  "$(printf '%s\n' "$deps" | grep -c '^optionalDependencies ' || true)"
assert_eq "it does not depend on @aztec/native" "0" \
  "$(printf '%s\n' "$deps" | grep -cE ' @aztec/native$' || true)"
assert_eq "nor on @aztec/bb.js, which is where the prebuilt nodejs_module.node lives" "0" \
  "$(printf '%s\n' "$deps" | grep -cE ' @aztec/bb\.js$' || true)"
# The positive control: the package DOES declare the @aztec packages it legitimately uses, so the
# three absences above are absences from a list that has entries.
assert_contains "and it does declare @aztec/stdlib, which it legitimately uses" \
  "dependencies @aztec/stdlib" "$deps"

# ---- 2. `npm pack` — the ARTEFACT, not the manifest -----------------------
pack_dir="$M19_WORK/pack"
rm -rf "$pack_dir"; mkdir -p "$pack_dir"
( cd "$ORCH" && npm pack --dry-run --json >"$pack_dir/pack.json" 2>"$pack_dir/pack.err" )
rc=$?
assert_eq "npm pack --dry-run succeeds for the shipped package" "0" "$rc"
[ "$rc" -eq 0 ] || sed -n '1,20p' "$pack_dir/pack.err" >&2
files="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for e in d[0]["files"]:
    print(e["path"])' "$pack_dir/pack.json" 2>/dev/null)"
assert_ge "the tarball has files in it, so the absences below are absences from something" 4 \
  "$(printf '%s\n' "$files" | grep -c . )"
assert_eq "the tarball contains no cpp_* file" "0" \
  "$(printf '%s\n' "$files" | grep -cE '(^|/)cpp_[A-Za-z0-9_]*\.' || true)"
assert_eq "the tarball contains no contract_provider_for_cpp" "0" \
  "$(printf '%s\n' "$files" | grep -c 'contract_provider_for_cpp' || true)"
assert_eq "the tarball contains nothing from a differential/ directory" "0" \
  "$(printf '%s\n' "$files" | grep -cE '(^|/)differential/' || true)"
# Control: a needle that IS in the tarball, matched the same way, so the greps above are not
# failing to match by construction.
assert_ge "and the same grep does find a file that IS shipped" 1 \
  "$(printf '%s\n' "$files" | grep -cE '(^|/)wasm_avm_public_tx_simulator\.ts$' || true)"

# ---- 3. the shipped IMPORT GRAPH ------------------------------------------
# The manifest says what is declared; the graph says what is reached. Both are needed: a file can
# import a package the manifest does not declare, and a manifest can declare one nothing imports.
[ -d "$ORCH/node_modules/@aztec/stdlib" ] \
  || die "the orchestration's packages are not installed and the import graph cannot be walked.
             Remedy: cd $ORCH && npm ci"
graph="$M19_WORK/orchestration-graph.json"
node "$REPO_ROOT/tools/import_graph.mjs" --entry ./src/index.ts --from "$ORCH" --json "$graph" >/dev/null
assert_file "the import graph was produced" "$graph"
modules="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["module_count"])' "$graph")"
packages="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["packages"]))' "$graph")"
assert_ge "the graph reached a meaningful number of modules" 5 "$modules"
assert_ge "the graph reached packages at all, so a package absence means something" 1 \
  "$(printf '%s\n' "$packages" | grep -c . )"
assert_eq "the shipped import graph does not reach @aztec/native" "0" \
  "$(printf '%s\n' "$packages" | grep -cx '@aztec/native' || true)"
#
# AND THAT ASSERTION ON ITS OWN COULD NOT FAIL. Found by the M19 review, by mutation rather than by
# reading: `@aztec/native` and `@aztec/world-state` are NOT INSTALLED in `orchestration/node_modules`
# — the orchestration does not depend on them, which is the very thing under test. So an import of
# either resolves to MODULE_NOT_FOUND, lands in the walker's `unresolvable` list, and never enters
# `packages` at all. With `import * as x from "@aztec/native";` prepended to a module the entry
# point reaches, this check printed `34 assertion(s), 0 failure(s)` and `ok  the shipped import
# graph does not reach @aztec/native  [0]` IN THE SAME RUN. That is the campaign's own archetype —
# an absence asked of a tree that excludes the subject by construction — and it was asked of the
# same package family as the precedent (`ForkCheckpoint`, against a node_modules with no
# `@aztec/world-state`). The non-emptiness assertions above do not close it: the tree is not empty,
# it merely cannot contain the subject.
#
# Two things close it, and both are needed.
#
# FIRST: the unresolvable specifiers are read, not ignored. A forbidden package that IS imported
# shows up there instead of in `packages`, so that is where the absence has to be asserted too.
# `ws` has two optional native accelerators that are legitimately absent, and requiring zero
# unresolvables would fail for a reason that says nothing about containment — so they are named,
# the way `verify_no_telemetry_client_in_import_graph.sh` names them.
unresolved="$(python3 -c '
import json, sys
for u in json.load(open(sys.argv[1]))["unresolvable"]:
    print(u["spec"])' "$graph" | LC_ALL=C sort -u)"
assert_ge "the walker reports unresolvable specifiers at all, so reading them is not vacuous" 1 \
  "$(printf '%s\n' "$unresolved" | grep -c . )"
assert_eq "no forbidden package is hiding in the unresolvable list rather than in the graph" "0" \
  "$(printf '%s\n' "$unresolved" | grep -cE '^@aztec/(native|world-state)$' || true)"
assert_eq "and every unresolved specifier is one of ws's two optional native accelerators" "0" \
  "$(printf '%s\n' "$unresolved" | grep -vxE 'bufferutil|utf-8-validate' | grep -c . || true)"
#
# SECOND: the walker is shown to be CAPABLE of reporting `@aztec/native` as a reached package. The
# question cannot be asked of `orchestration/`, where the package is absent for the reason under
# test, so it is asked of `diffsim/`, where it IS installed and IS genuinely imported. Without this
# the absence above is indistinguishable from a walker that cannot see the package.
native_probe="$M19_WORK/native-reachable.json"
node "$REPO_ROOT/tools/import_graph.mjs" --entry '@aztec/native' --from "$REPO_ROOT/diffsim" \
  --json "$native_probe" >/dev/null 2>&1
assert_file "the negative-case graph was produced" "$native_probe"
assert_ge "…and it is a real walk rather than an empty one" 50 \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["module_count"])' "$native_probe")"
assert_eq "negative case: the walker DOES report @aztec/native when a graph really reaches it" "1" \
  "$(python3 -c 'import json,sys; print(1 if "@aztec/native" in json.load(open(sys.argv[1]))["packages"] else 0)' "$native_probe")"
#
# @aztec/bb.js IS REACHED, and the honest thing is to measure it rather than to assert it away.
# DRIFT.md D17. It arrives through @aztec/foundation's Barretenberg-backed crypto (Poseidon,
# Pedersen, Grumpkin, AES), which @aztec/stdlib needs — not through anything of ours and not
# through the AVM. FIVE of its reached modules are its Node backend, three of which locate and load
# `build/<platform>/nodejs_module.node`. Five, not three: the first count here was of the modules
# whose TEXT mentions the addon, which is a different question from which modules are reached, and
# the check caught the difference.
# Pinned EXACTLY, in both directions, so the surface can neither grow nor silently vanish.
#
# This is the assertion the first version of this check got wrong in the dangerous direction: it
# asserted the absence, the absence was false, and had the graph walk failed for an unrelated
# reason (it did, on a path spelling) the assertion would have PASSED on an empty graph.
assert_eq "@aztec/bb.js is reached, which is D17, measured rather than asserted away" "1" \
  "$(printf '%s\n' "$packages" | grep -cx '@aztec/bb.js' || true)"
bb_native="$(python3 -c '
import json, re, sys
mods = [m.replace("file://", "") for m in json.load(open(sys.argv[1]))["modules"]]
print(len([m for m in mods if re.search(r"/@aztec/bb\.js/.*/bb_backends/node/", m)]))' "$graph")"
assert_eq "exactly five reached bb.js modules are its Node backend, which loads the addon (D17)" "5" "$bb_native"
# An IMPORT of ours, not a mention: `simulator_selection.ts` names the package in a doc comment,
# which is the whole point of that file, and a check that counted mentions would fail on prose.
assert_eq "no source of ours IMPORTS @aztec/bb.js, so the reach is upstream's and not ours" "0" \
  "$(cd "$REPO_ROOT/orchestration/src" && grep -rlE "^import .*'@aztec/bb\.js'|from '@aztec/bb\.js'" . 2>/dev/null | wc -l)"
assert_ge "and the file that MENTIONS it in prose is still there, so the grep above is a real distinction" 1 \
  "$(cd "$REPO_ROOT/orchestration/src" && grep -rl '@aztec/bb.js' . 2>/dev/null | wc -l)"
assert_ge "while upstream's own crypto does import it, so the attribution is measured not assumed" 3 \
  "$(grep -rl "from '@aztec/bb.js'" "$REPO_ROOT/orchestration/node_modules/@aztec/foundation/dest/crypto" 2>/dev/null | wc -l)"
assert_true "DRIFT.md records it" grep -q '^## D17 — ' "$REPO_ROOT/DRIFT.md"
assert_eq "nor @aztec/world-state, whose native/ subpath is the other native addon" "0" \
  "$(printf '%s\n' "$packages" | grep -cx '@aztec/world-state' || true)"
assert_ge "and it does reach @aztec/stdlib, so the absences are not an empty graph" 1 \
  "$(printf '%s\n' "$packages" | grep -cx '@aztec/stdlib' || true)"

# ---- 4. everything that CAN reach the native AVM is under differential/ ----
# Enumerated over the TREE rather than over a list, so a new file that reaches the addon fails this
# rather than being missed.
#
# UPSTREAM'S OWN C++ ADAPTER FILES ARE NOT MOVED, and the exception is enumerated BY NAME rather
# than by a pattern — because a pattern is exactly what let the first version of this check pass
# while a fifth file sat outside it. `contract_provider_for_cpp.ts` reaches `@aztec/native` and
# does not match `cpp_*`, so the deliverable's phrase "the four cpp_* files" is one file short of
# what is actually there.
#
# They stay where upstream put them because renaming a VENDORED path is a construct this
# repository's drift ledger does not have: `check_drift.sh` compares 742 vendored files against
# three anchors and records edits as (path, class, kind), so a rename reads as an unrecorded
# deletion plus an unrecorded addition and fails. Moving them is worth doing and belongs with a
# drift-ledger change that can express it. Until then the exception is a fixed list of five, every
# entry must exist, and the list may not grow.
UPSTREAM_CPP_ADAPTERS="public/public_tx_simulator/contract_provider_for_cpp.ts
public/public_tx_simulator/cpp_public_tx_simulator.ts
public/public_tx_simulator/cpp_public_tx_simulator_with_hinted_dbs.ts
public/public_tx_simulator/cpp_vs_ts_public_tx_simulator.ts
public/public_tx_simulator/apps_tests/cpp_exception_handling.test.ts"

# QUOTE-AGNOSTIC, and that is not tidiness. This grep is the only thing that caught the review's
# injected import when the graph assertion above did not — and it caught it only because the
# injection happened to use single quotes. Spelled `"@aztec/native"` the same import passed every
# assertion in this file. Nothing in this repository enforces a quote style on a source file.
NATIVE_IMPORT_RE="from [\"']@aztec/native[\"']"
native_importers="$(cd "$REPO_ROOT/diffsim/src" && grep -rlE "$NATIVE_IMPORT_RE" . | sed 's|^\./||' | sort)"
assert_ge "some file in diffsim does reach the native addon, so this enumeration is not empty" 1 \
  "$(printf '%s\n' "$native_importers" | grep -c . )"
unexpected="$(printf '%s\n' "$native_importers" \
  | grep -v '^public/public_tx_simulator/differential/' \
  | grep -vxF "$UPSTREAM_CPP_ADAPTERS" || true)"
assert_eq "every file reaching @aztec/native is under differential/ or is one of upstream's five C++ adapters" \
  "" "$unexpected"
assert_eq "the enumerated exception is exactly five files, so it cannot grow unnoticed" "5" \
  "$(printf '%s\n' "$UPSTREAM_CPP_ADAPTERS" | grep -c . )"
for f in $UPSTREAM_CPP_ADAPTERS; do
  assert_file "the exception names a file that exists: $f" "$REPO_ROOT/diffsim/src/$f"
done
# The control for the enumeration: a file that is NOT in the exception and does NOT reach the addon
# must not be matched by it, or `grep -vxF` could be excusing everything.
assert_eq "a file outside the exception is not excused by it" "1" \
  "$(printf '%s\n' 'public/public_tx_simulator/public_tx_simulator.ts' | grep -vxF "$UPSTREAM_CPP_ADAPTERS" | wc -l)"
assert_eq "nothing outside diffsim/ reaches the native addon in any package this repository ships" "0" \
  "$(cd "$REPO_ROOT" && grep -rlE "$NATIVE_IMPORT_RE" orchestration/src node-host/src 2>/dev/null | wc -l)"
# …and that grep is not failing to match by construction: the same expression, run over the tree
# where the import genuinely exists, finds it.
assert_ge "and the same expression does find the imports that ARE there" 1 \
  "$(printf '%s\n' "$native_importers" | grep -c . )"

finish
