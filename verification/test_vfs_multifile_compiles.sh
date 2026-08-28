#!/usr/bin/env bash
# test_vfs_multifile_compiles
#
# M30's first entry: a tree of Noir sources held in a browser's memory, with a LOCAL PATH
# DEPENDENCY, compiles in-page.
#
# ===========================================================================================
# WHAT THIS IS ABOUT, IN ONE PARAGRAPH.
# ===========================================================================================
#
# `compiler/wasm` has always taken an in-memory `path -> source` map — that is
# `PathToFileSourceMap`, and `file_manager_with_source_map` is where it becomes an
# `fm::FileManager`. What it has never done is READ A MANIFEST. The crate graph arrived
# pre-computed from JavaScript (`compile.rs:126-130`'s `DependencyGraph`), and everything
# that produces one — parsing `Nargo.toml`, walking `[dependencies]`, deciding which file is
# the crate root — lived in `src/noir/*.ts` behind `@ltd/j-toml`, a `FileManager` shim and,
# for anything remote, a live `fetch`. M30 moves that half into the module: `src/vfs.rs`.
#
# ===========================================================================================
# THE ASSERTION THAT ASKS WHETHER THE SUBJECT DID ANYTHING.
# ===========================================================================================
#
# "It compiled" is satisfiable by a compile that never looked at the dependency, and by one
# that swallowed the whole virtual filesystem instead of choosing from it. Both are green
# under every obvious assertion. So §5 and §6 are the two that matter, and they are a pair:
#
#   §5  editing the DEPENDENCY's body changes the artifact — so the dependency is IN the
#       program rather than merely resolved and dropped. IT CAN FAIL AND IT DID: the first
#       version of that fixture changed `x + x` to `x + x + x - x`, which is different SOURCE
#       and the same CIRCUIT — the SSA passes fold it back and the artifact came out
#       byte-identical. §5 went red on its first run over an edit that had not edited
#       anything the compiler could see;
#   §6  ADDING a `.nr` file to the virtual filesystem OUTSIDE `src/` changes nothing — so
#       `sources` is a decision the resolver took and not a copy of its input. THIS ONE ALSO
#       HAD TO BE FIXED: it first compared two artifacts after EDITING such a file, and an
#       edit to a file that is not part of the program cannot change the artifact whatever
#       the resolver does. The mutation harness measured it — with the resolver swallowing
#       the whole tree, §6 stayed green — and it is an ADDITION now, which shifts `FileId`s
#       and therefore the program `hash`.
#
# Neither alone is worth much. §5 with a resolver that ingested the whole tree would still
# pass; §6 with a resolver that ingested nothing would too. Together they pin the boundary.
#
# ===========================================================================================
# AND THE COMPILE HAPPENED INSIDE WEBASSEMBLY, MEASURED RATHER THAN CONFIGURED.
# ===========================================================================================
#
# The page fetches a `.wasm` and calls its C ABI. Every import the module DECLARES is
# satisfied with a function that records the call and then throws, so `reachedImports` being
# empty is a measurement — and `declaredImports` being 28 is what stops that measurement
# being vacuous: there were twenty-eight doors and the module opened none of them.
# `BROWSER-PACKAGING.md` §4 is the precedent: that section's first draft said an import
# "would never be called" and the counter said 1.
#
# ===========================================================================================
# THE SOURCE IS EXERCISED TOO, IN THE SAME RUN.
# ===========================================================================================
#
# §9 runs `cargo test -p noir_wasm` in the Noir checkout. The page proves the MODULE does it;
# the suite proves the SOURCE does, so a page measurement taken over a module built before an
# edit cannot stand in for either. It needs the sibling `codetracer-trace-format` dev shell,
# because `noir`'s workspace resolves `codetracer_trace_writer` to the Nim FFI crate whose
# `build.rs` wants `nim` on PATH — a misdiagnosis of exactly that once hid six failing tests
# for a whole milestone.
#
# Run: just verify-m30-multifile

TEST_NAME="test_vfs_multifile_compiles"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m30_vfs.sh"

m30_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m30_require_arms

echo "== 1. the arm report is present, and so are the fields every comparison below reads"

ENTRY="$(m30_arm arms.compile.multifile.plan.entry_point)"
SOURCES="$(m30_arm arms.compile.multifile.plan.sources)"
WANT_ENTRY="$(m30_arm arms.modules.expectations.multifileEntryPoint)"
WANT_SOURCES="$(m30_arm arms.modules.expectations.multifileSources)"
OK="$(m30_arm arms.compile.multifile.ok)"
HASH="$(m30_arm arms.compile.multifile.artifact.hash)"
HASH_DEP="$(m30_arm arms.compile.multifileDependencyEdited.artifact.hash)"
HASH_DECOY="$(m30_arm arms.compile.multifileDecoyAdded.artifact.hash)"
HASH_UNDER_SRC="$(m30_arm arms.compile.multifileDecoyAddedUnderSrc.artifact.hash)"

# ONE assertion that names every absent field, before the first comparison, with a `die`
# behind it. M29's remedy: two `MISSING`s compare equal, and `test 5 -eq MISSING` is a bash
# ERROR that `assert_false` reads as the false it wanted.
ABSENT="$(m30_absent "entry=$ENTRY" "sources=$SOURCES" "wantEntry=$WANT_ENTRY" \
                     "wantSources=$WANT_SOURCES" "ok=$OK" "hash=$HASH" \
                     "hashDependencyEdited=$HASH_DEP" "hashDecoyAdded=$HASH_DECOY" \
                     "hashDecoyAddedUnderSrc=$HASH_UNDER_SRC")"
assert_eq "every field the comparisons below read is present in the arm report" "" "$ABSENT"
[ -z "$ABSENT" ] || die "the arm report is missing $ABSENT; every comparison below would be between
             two absences. A failure, not a smaller check."

assert_eq "the page has no uncaught errors" "[]" "$(m30_arm arms.modules.pageErrors)"
assert_eq "and no console errors" "[]" "$(m30_arm arms.modules.consoleErrors)"

echo "== 2. the virtual filesystem the page held really carries the files §6 excludes"

TREE_PATHS="$(m30_arm arms.compile.multifile.treePaths)"
DECOYS="$(m30_arm arms.modules.expectations.decoys)"
assert_true "the tree carries a Nargo.toml for the entry package" str_has_sub "$TREE_PATHS" '"app/Nargo.toml"'
assert_true "…and one for the dependency" str_has_sub "$TREE_PATHS" '"util/Nargo.toml"'
assert_true "…and a .nr file OUTSIDE src/, which is what §6's control turns on" \
  str_has_sub "$TREE_PATHS" '"app/scratch.nr"'
assert_true "…and a Prover.toml, a README and a stale target/ artifact" \
  str_has_sub "$TREE_PATHS" '"app/target/app.json"'
assert_eq "the tree is nine files" "9" "$(printf '%s' "$TREE_PATHS" | tr ',' '\n' | grep -c .)"
assert_eq "the decoy list the expectations declare is four files" "4" \
  "$(printf '%s' "$DECOYS" | tr ',' '\n' | grep -c .)"

echo "== 3. the plan: Nargo.toml honoured, the dependency resolved inside the tree"

assert_eq "the tree compiles" "true" "$OK"
# The two sides are derived differently: the left by the module, from the manifest's
# `[package].type` and the default crate-root rule; the right by scanning the fixture in
# JavaScript. A single derivation agreeing with itself is the shape this campaign calls a
# tautology.
assert_eq "the crate root is the one Nargo.toml's package type implies" "$WANT_ENTRY" "$ENTRY"
assert_eq "and the program is exactly the three .nr files under the two src/ directories" \
  "$WANT_SOURCES" "$SOURCES"
assert_eq "two packages were resolved" "2" \
  "$(python3 -c 'import json,sys;print(len(json.loads(sys.argv[1])))' "$(m30_arm arms.compile.multifile.plan.packages)")"
assert_eq "the entry package names the dependency" '["util"]' \
  "$(m30_arm arms.compile.multifile.plan.packages.0.dependencies)"
assert_eq "the dependency resolved to a library" "lib" \
  "$(m30_arm arms.compile.multifile.plan.packages.1.package_type)"
assert_eq "…at the alias the manifest gave it" "util" \
  "$(m30_arm arms.compile.multifile.plan.packages.1.alias)"
assert_eq "…with its own crate root inside the virtual filesystem" "util/src/lib.nr" \
  "$(m30_arm arms.compile.multifile.plan.packages.1.entry_point)"
assert_eq "…found through the manifest the dependency's path names" "util/Nargo.toml" \
  "$(m30_arm arms.compile.multifile.plan.packages.1.manifest)"
assert_eq "no entry point was declared, so the default rule is what chose it" "false" \
  "$(m30_arm arms.compile.multifile.plan.packages.0.entry_was_declared)"

for decoy in "app/Prover.toml" "app/README.md" "app/scratch.nr" "app/target/app.json"; do
  assert_false "…and $decoy is in the tree and NOT in the program" \
    str_has_sub "$SOURCES" "\"$decoy\""
done

echo "== 3b. [package].entry IS HONOURED, IN THE MODULE, IN THE PAGE"

# WHY THIS SECTION EXISTS AT ALL: the mutation harness's M5 arm makes the resolver ignore
# `[package].entry` again — the shipped TypeScript's behaviour, and a silent wrong answer —
# and when M30 was delivered the ONLY thing that noticed was §9's native suite, because no
# browser fixture declared the field. A deliverable that says a browser page honours a
# manifest key, verified by a `cargo test` on the source the module was built from, is an
# inference and not a measurement. These assertions are the measurement.
#
# The fixture is built so the two answers are distinguishable in the ARTIFACT and not only in
# the plan: `src/main.nr` — the root the default rule would pick — takes two parameters, and
# the declared root takes one. So the ABI is the discriminator.
ENTRY_DECLARED="$(m30_arm arms.compile.declaredEntry.plan.entry_point)"
WANT_DECLARED="$(m30_arm arms.modules.expectations.declaredEntryPoint)"
WANT_DECLARED_ABI="$(m30_arm arms.modules.expectations.declaredRootAbi)"
WANT_DEFAULT_ABI="$(m30_arm arms.modules.expectations.defaultRootAbi)"
ABSENT_ENTRY="$(m30_absent "declaredEntry=$ENTRY_DECLARED" "wantDeclaredEntry=$WANT_DECLARED" \
                           "wantDeclaredAbi=$WANT_DECLARED_ABI" "wantDefaultAbi=$WANT_DEFAULT_ABI")"
assert_eq "the entry fields the section below reads are present" "" "$ABSENT_ENTRY"
[ -z "$ABSENT_ENTRY" ] || die "the arm report is missing $ABSENT_ENTRY; §3b would compare absences."

assert_eq "a manifest that declares [package].entry gets that file as its crate root" \
  "$WANT_DECLARED" "$ENTRY_DECLARED"
assert_eq "…and the module says the root was DECLARED rather than defaulted" "true" \
  "$(m30_arm arms.compile.declaredEntry.plan.packages.0.entry_was_declared)"
assert_eq "…and the artifact is the declared root's, which is the reading the plan cannot give" \
  "$WANT_DECLARED_ABI" "$(m30_arm arms.compile.declaredEntry.artifact.abiParameters)"
# The control that makes the one above a discriminator: the file the DEFAULT rule would have
# chosen is still in the tree, still in the program, and has a DIFFERENT ABI — so a resolver
# that ignored the field would answer this section rather than pass it.
assert_false "…and NOT the default root's, whose ABI differs" \
  test "$WANT_DECLARED_ABI" = "$WANT_DEFAULT_ABI"
assert_true "…while src/main.nr is still one of the program's sources: entry chooses a ROOT, not a filter" \
  str_has_sub "$(m30_arm arms.compile.declaredEntry.plan.sources)" '"app/src/main.nr"'

assert_eq "a declared entry that is not in the tree is refused" "missing-entry" \
  "$(m30_arm arms.compile.declaredEntryMissing.kind)"
MSG_ENTRY="$(m30_arm arms.compile.declaredEntryMissing.message)"
assert_true "…naming the path the manifest asked for" \
  str_has_sub "$MSG_ENTRY" "$(m30_arm arms.modules.expectations.declaredEntryMissingPoint)"
assert_true "…and saying it was DECLARED, not defaulted — which is what tells a caller where to look" \
  str_has_sub "$MSG_ENTRY" '`[package].entry`'
# …and the same refusal for a MISSING DEFAULT root says the other thing, so the two are not
# one message with a noun swapped.
assert_false "…while a missing DEFAULT root does not mention the field" \
  str_has_sub "$(m30_arm arms.compile.missingDependencySource.message)" '`[package].entry`'

echo "== 4. the artifact is a compiled program, not an empty envelope"

assert_eq "the artifact came back" "true" "$(m30_arm arms.compile.multifile.artifact.present)"
ART_KEYS="$(m30_arm arms.compile.multifile.artifact.keys)"
for key in abi bytecode debug_symbols file_map hash noir_version; do
  assert_true "…carrying $key" str_has_sub "$ART_KEYS" "\"$key\""
done
assert_eq "the ABI names both of main's parameters" '["x","y"]' \
  "$(m30_arm arms.compile.multifile.artifact.abiParameters)"
assert_ge "the bytecode is not an empty string" 64 \
  "$(m30_arm arms.compile.multifile.artifact.bytecodeLength)"
assert_ge "the debug symbols are not an empty string" 64 \
  "$(m30_arm arms.compile.multifile.artifact.debugSymbolsLength)"

FILE_MAP="$(m30_arm arms.compile.multifile.artifact.fileMapPaths)"
assert_true "the artifact's file map is not empty" test "$FILE_MAP" != "[]"
# EVERY path the artifact names must be a path the CALLER put in the tree. This is the
# property `src/noir/package.ts:112-114` gives up when it re-keys a library's sources to
# `<alias>/<suffix>`: an artifact compiled that way names a path the caller's VFS does not
# contain.
UNKNOWN="$(python3 -c '
import json,sys
paths=set(json.loads(sys.argv[1])); tree=set(json.loads(sys.argv[2]))
print(",".join(sorted(paths - tree)))' "$FILE_MAP" "$TREE_PATHS")"
assert_eq "and every path in it is a path the caller put in the virtual filesystem" "" "$UNKNOWN"

assert_eq "resolve mode produces the same plan" "$SOURCES" \
  "$(m30_arm arms.compile.multifileResolveOnly.plan.sources)"
assert_eq "…and no artifact, so resolving and compiling are separable" "false" \
  "$(m30_arm arms.compile.multifileResolveOnly.artifact.present)"

echo "== 5. THE SUBJECT DID SOMETHING: the dependency is IN the program"

BYTECODE="$(m30_arm arms.compile.multifile.artifact.bytecode)"
BYTECODE_DEP="$(m30_arm arms.compile.multifileDependencyEdited.artifact.bytecode)"
BYTECODE_DECOY="$(m30_arm arms.compile.multifileDecoyAdded.artifact.bytecode)"
ABSENT2="$(m30_absent "bytecode=$BYTECODE" "bytecodeDependencyEdited=$BYTECODE_DEP" \
                      "bytecodeDecoyAdded=$BYTECODE_DECOY")"
assert_eq "the three artifacts' bytecode is present" "" "$ABSENT2"
[ -z "$ABSENT2" ] || die "the arm report is missing $ABSENT2; §5 and §6 would compare absences."

assert_false "editing the DEPENDENCY's body changes the compiled bytecode" \
  test "$BYTECODE" = "$BYTECODE_DEP"
assert_false "…and its hash" test "$HASH" = "$HASH_DEP"

echo "== 6. THE CONTROL FOR §5: a file in the tree and not in the program changes nothing"

# `app/aaa_decoy.nr` is a `.nr` file ADDED to the entry package's own directory, outside
# `src/`. A resolver that ingested the whole virtual filesystem would pull it in and these
# assertions would fail; a resolver that ingested nothing would fail §5. The pair is the
# boundary.
#
# IT IS AN ADDITION AND NOT AN EDIT, AND THE HASH IS THE DISCRIMINATING READING. An EDIT to a
# file that is not part of the program cannot change the artifact whatever the resolver does
# — an unreferenced file contributes no code — so the first version of this section compared
# two artifacts that were equal by construction, and the mutation harness proved it: with the
# resolver swallowing the whole tree (arm M4) the plan gained `app/scratch.nr` and these two
# assertions stayed GREEN. An ADDITION is different: a file that enters `sources` enters the
# `FileManager` and shifts every later `FileId`, which `compile.rs:136-140` records as what
# the program `hash` is based on. So the bytecode comparison below is a determinism reading and
# the HASH comparison is the control — and the calibration that says the hash CAN move is the
# arm immediately after it, measured in this run, rather than a pair of numbers in a comment.
assert_eq "adding a .nr file outside src/ leaves the artifact hash unchanged" "$HASH" "$HASH_DECOY"
assert_eq "…and the bytecode byte-identical" "$BYTECODE" "$BYTECODE_DECOY"

# AND THE INSTRUMENT IS CALIBRATED IN THIS RUN RATHER THAN IN A COMMENT. The two assertions
# above are an ABSENCE of movement, and an absence is only worth what the instrument's ability
# to move is worth. `multifileDecoyAddedUnderSrc` is the SAME file one directory lower, INSIDE
# `src/`, where the resolver's own rule puts it in the program: the hash must move and the
# bytecode must not. This used to be a measured pair quoted in a comment — 1206613220 ->
# 4090147220 — that nothing re-derived, and by the time it was re-taken the fixture had moved
# under it and the true pair was 1076565353 -> 848041253. It is an arm now, so neither number
# appears anywhere and both are measured on every run.
assert_false "…while the SAME file one directory lower, inside src/, DOES move the hash" \
  test "$HASH" = "$HASH_UNDER_SRC"
assert_true "…because it enters the program, which is the mechanism" \
  str_has_sub "$(m30_arm arms.compile.multifileDecoyAddedUnderSrc.plan.sources)" '"app/src/aaa_decoy.nr"'
assert_eq "…and even THAT leaves the bytecode byte-identical, so the hash is the reading" \
  "$BYTECODE" "$(m30_arm arms.compile.multifileDecoyAddedUnderSrc.artifact.bytecode)"

echo "== 7. THE CONTROLS: a missing file fails with THAT path named"

assert_eq "a missing dependency manifest is refused" "false" \
  "$(m30_arm arms.compile.missingDependencyManifest.ok)"
assert_eq "…at the resolve stage" "resolve" "$(m30_arm arms.compile.missingDependencyManifest.stage)"
assert_eq "…with a kind a host can branch on" "missing-dependency-manifest" \
  "$(m30_arm arms.compile.missingDependencyManifest.kind)"
MSG_MANIFEST="$(m30_arm arms.compile.missingDependencyManifest.message)"
assert_true "…naming the path it looked for" str_has_sub "$MSG_MANIFEST" "util/Nargo.toml"
assert_true "…and the dependency that asked for it" str_has_sub "$MSG_MANIFEST" '`util`'
assert_true "…and the manifest that declares it, with a line" \
  str_has_sub "$MSG_MANIFEST" "app/Nargo.toml:"
assert_eq "…and it produced no plan" "false" \
  "$(m30_arm arms.compile.missingDependencyManifest.planPresent)"
assert_eq "…while the tree that resolves does produce one, so that field is being read" "true" \
  "$(m30_arm arms.compile.multifile.planPresent)"
assert_eq "…and no artifact: a refusal is a throw, never a partial success" "false" \
  "$(m30_arm arms.compile.missingDependencyManifest.artifact.present)"

assert_eq "a missing crate root inside the dependency is refused" "missing-entry" \
  "$(m30_arm arms.compile.missingDependencySource.kind)"
MSG_SOURCE="$(m30_arm arms.compile.missingDependencySource.message)"
assert_true "…naming THAT file" str_has_sub "$MSG_SOURCE" "util/src/lib.nr"
assert_true "…and the manifest whose package it is" str_has_sub "$MSG_SOURCE" "util/Nargo.toml"

# The third shape: a file the entry package's own `mod` statement names. This one is NOT a
# resolver refusal — `mod helper;` is resolved by the frontend, not by `Nargo.toml` — so it
# arrives as a positioned diagnostic. Asserted here rather than in §2's check, because the
# distinction between "the resolver could not find it" and "the compiler could not find it"
# is exactly what a caller has to be told.
assert_eq "a missing local module is refused at the COMPILE stage, not the resolve stage" \
  "compile" "$(m30_arm arms.compile.missingLocalModule.stage)"
MODULE_DIAGS="$(m30_arm arms.compile.missingLocalModule.diagnostics)"
assert_true "…naming the module and the two paths it looked for" \
  str_has_sub "$MODULE_DIAGS" "app/src/helper.nr"
assert_eq "…positioned in the file that declares the mod" "app/src/main.nr" \
  "$(m30_arm arms.compile.missingLocalModule.diagnostics.0.file)"

echo "== 8. the compile happened inside WebAssembly, and that is a measurement"

DECLARED="$(m30_arm arms.modules.modules.compiler.declaredImports)"
REACHED="$(m30_arm arms.modules.reached.compiler)"
assert_ge "the module DECLARES imports, so 'reached none' is not vacuous" 20 "$DECLARED"
# The count is the compile arm's, and it is the list in `vfs_page.mjs`'s `compileArms()` plus
# the resolve-only pass — not a number typed here. `e2e_vfs_edit_recompile_retrace` §2 reads
# the same list for the trace page's six passes; the two together are every compile the run does.
assert_eq "and it reached none of them, across every compile the arm ran" "[]" "$REACHED"
assert_eq "the C ABI is the four entry points the page calls" \
  '["nv_alloc","nv_compile_vfs","nv_free","nv_result_len"]' \
  "$(m30_arm arms.modules.modules.compiler.exportsNv)"
assert_ge "the module is a real compiler and not a stub" 5000000 \
  "$(m30_arm arms.modules.modules.compiler.bytes)"
# THE FIXTURE THE PAGE WAS SERVED IS COMPARED AGAINST A DIGEST THIS CHECK TAKES ITSELF.
# It used to compare `trees.sha256` with `trees.servedSha256` — but the runner copies the
# source file into the site and then hashes BOTH, in one process, so those two are equal by
# construction and the assertion could not fail. The left-hand side is now `sha256sum` of the
# file on disk, taken here, so a report measured over a different fixture is a red assertion
# rather than a green one.
assert_eq "the trees the page was served are the ones on disk now" \
  "$(sha256sum "$M30_TREES" | cut -d' ' -f1)" "$(m30_arm trees.servedSha256)"

echo "== 9. the same code path, natively, in the Noir checkout"

m30_native_tests noir_wasm
assert_eq "cargo test -p noir_wasm passes" "0" "$M30_CARGO_RC"
CARGO_OUT="$(cat "$M30_CARGO_LOG" 2>/dev/null)"
PASSED="$(printf '%s\n' "$CARGO_OUT" | sed -n 's/^test result: ok\. \([0-9]*\) passed.*/\1/p' | head -1)"
assert_ge "…over a suite that is not empty (cargo test exits 0 over zero tests)" 30 "$PASSED"
for t in a_three_file_tree_with_a_local_dependency_compiles \
         files_outside_src_are_not_part_of_the_program \
         a_missing_dependency_names_the_path_it_looked_for; do
  assert_true "…including $t" str_has_line_re "$CARGO_OUT" "^test .*${t} \.\.\. ok\$"
done

m30_finish
