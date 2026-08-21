#!/usr/bin/env bash
# verify_merkle_lmdb_issue_md_complete
#
# The prepared contribution's write-up carries what the upstream-bugs convention
# requires — and, more importantly, what it says is TRUE.
#
# NOTE ON THE FILE NAME. The milestone text says `ISSUE.md`.
# `upstream-bugs/CLAUDE.md` requires **`PR.md`, not `ISSUE.md`**, for a non-defect
# contribution, and this patch is a refactor against a project that has no live
# defect. The directory therefore carries `PR.md`; this check asserts that, and
# asserts that no `ISSUE.md` was left beside it. The test name is unchanged so
# the milestone entry stays traceable.
#
# The form half of this check (headings and header fields are present) is the
# weak half: a padded, confident-sounding document passes it. So most of what
# follows RE-DERIVES the document's factual claims from the trees and from the
# recorded measurement, and fails when the prose and the evidence disagree:
#
#   * the diffstat it advertises, from `git diff --numstat -M`
#   * the base commit it names, from the patch's own parent
#   * every test count in its table, from $M3_WORK/measured.env
#   * "exactly one non-test .cpp", counted in the base tree
#   * "nine files move", counted as rename records in the patch
#   * the five merkle-tree headers vm2_sim and world_state_reference include,
#     re-derived by grepping those two directories
#   * `print_store_data` having no callers, counted in the base tree
#   * the `if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "wasm32" AND NOT BB_LITE)` guard
#     and the `BB_LITE` help string it quotes, matched verbatim in the base tree
#   * each stated limitation, checked against the patched tree
#
# Run: just verify-merkle-pr-md

TEST_NAME="verify_merkle_lmdb_issue_md_complete"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_merkle_lmdb.sh"

PR="$M3_PATCH_DIR/PR.md"
assert_file "the write-up is PR.md, as the non-defect workflow requires" "$PR"
assert_false "and there is no ISSUE.md beside it (that spelling is for defects)" \
  test -f "$M3_PATCH_DIR/ISSUE.md"
[ -f "$PR" ] || { finish; }

doc="$(cat "$PR")"
m3_prepare_trees

# ---------------------------------------------------------------------------
# Header fields required by the convention
# ---------------------------------------------------------------------------
assert_contains "PR.md names the upstream project" "**Upstream project:**" "$doc"
assert_contains "PR.md declares its Kind (the non-defect workflow's extra field)" \
  "**Kind:**" "$doc"
assert_contains "and the Kind is a refactor" "refactor" "$doc"
assert_contains "PR.md carries a Status line" "**Status:**" "$doc"
assert_contains "PR.md states it is not yet filed and has no upstream URL" \
  "not filed" "$doc"
assert_contains "PR.md names the base commit" "**Base commit:** \`$M3_BASE_REV\`" "$doc"
assert_contains "PR.md records its order in the series and whether it stands alone" \
  "**Order in the series:**" "$doc"
assert_contains "PR.md offers a suggested PR title" "Suggested PR title" "$doc"
assert_contains "the suggested title matches the patch's own subject" \
  "refactor(crypto): split crypto_merkle_tree from its LMDB backend" "$doc"

for section in "## Known limitations" "## Why we care" "## Prior art searched" \
               "## If this is declined" "## The discriminator"; do
  assert_contains "PR.md has a [$section] section" "$section" "$doc"
done
assert_contains "the prior-art search is dated so it can be re-checked before filing" \
  "Search was 2026-08-" "$doc"

# ---------------------------------------------------------------------------
# The patch it advertises is the patch that is there
# ---------------------------------------------------------------------------
assert_contains "PR.md names the patch file by name" "$(basename "$M3_PATCH_FILE")" "$doc"
assert_file "and that file exists" "$M3_PATCH_FILE"

stat_line="$(git -C "$FORK_ROOT" diff --shortstat -M "$M3_BASE_REV" "$M3_SPLIT_REV" 2>/dev/null)"
n_files="$(printf '%s' "$stat_line" | grep -oE '^ *[0-9]+' | tr -d ' ')"
n_ins="$(printf '%s' "$stat_line" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+')"
n_del="$(printf '%s' "$stat_line" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+')"
assert_eq "measured: the patch changes 35 files with rename detection" 35 "$n_files"
assert_eq "measured: 325 insertions" 325 "$n_ins"
assert_eq "measured: 252 deletions" 252 "$n_del"
# PR.md wraps that sentence across two lines, so compare against a
# whitespace-collapsed copy of the document rather than the raw text.
flat="$(printf '%s\n' "$doc" | tr '\n' ' ' | tr -s ' ')"
assert_contains "PR.md advertises the measured diffstat" \
  "$n_files files, +$n_ins / −$n_del" "$flat"

n_renames="$(grep -c '^rename from ' "$M3_PATCH_FILE")"
assert_eq "measured: nine files move" 9 "$n_renames"
assert_contains "PR.md says nine files move" "Nine files move" "$doc"

assert_eq "the base commit PR.md names really is the patch's parent" \
  "$(git -C "$FORK_ROOT" rev-parse "$M3_BASE_REV")" \
  "$(git -C "$FORK_ROOT" rev-parse "$M3_SPLIT_REV^")"

# ---------------------------------------------------------------------------
# Every number in the native-impact table, against the measurement
# ---------------------------------------------------------------------------
m3_measured
assert_eq "the recorded before-build exited 0" 0 "${M3_BUILD_RC_BASE:--}"
assert_eq "the recorded after-build exited 0"  0 "${M3_BUILD_RC_PATCHED:--}"

assert_contains "PR.md's before count for crypto_merkle_tree_tests matches the measurement" \
  "| \`crypto_merkle_tree_tests\` | ${M3_BEFORE_CMT_RAN} passed / 6 suites | ${M3_AFTER_CMT_RAN} passed / 3 suites |" \
  "$doc"
assert_contains "PR.md's count for the new crypto_merkle_tree_lmdb_tests matches" \
  "| \`crypto_merkle_tree_lmdb_tests\` | — | ${M3_AFTER_CMT_LMDB_RAN} passed / 3 suites |" \
  "$doc"
assert_contains "PR.md's world_state_tests row matches" \
  "| \`world_state_tests\` | ${M3_BEFORE_WS_RAN} passed | ${M3_AFTER_WS_RAN} passed |" \
  "$doc"
assert_eq "and the arithmetic PR.md states holds" \
  "$M3_BEFORE_CMT_RAN" "$((M3_AFTER_CMT_RAN + M3_AFTER_CMT_LMDB_RAN))"
assert_contains "PR.md states the identical-test-name result, not only the counts" \
  "identical as a set" "$doc"
assert_file "and that comparison's output is on disk" "$M3_WORK/names-before.txt"
assert_eq "the recorded name lists are the same size" \
  "$(wc -l <"$M3_WORK/names-before.txt" | tr -d ' ')" \
  "$(wc -l <"$M3_WORK/names-after.txt" | tr -d ' ')"

# ---------------------------------------------------------------------------
# The evidence claims, re-derived from the base tree
# ---------------------------------------------------------------------------
MT="$M3_WORK/base/barretenberg/cpp/src/barretenberg/crypto/merkle_tree"
non_test_cpp="$(find "$MT" -name '*.cpp' ! -name '*.test.cpp' ! -name '*.bench.cpp' \
                | sed "s|$MT/||" | sort | tr '\n' ' ')"
assert_eq "measured: the module has exactly one non-test .cpp" \
  "lmdb_store/lmdb_tree_store.cpp " "$non_test_cpp"
assert_contains "PR.md makes that claim, and names the same file" \
  "\`lmdb_store/lmdb_tree_store.cpp\`" "$doc"

SRC="$M3_WORK/base/barretenberg/cpp/src/barretenberg"
used_headers="$(grep -rhoE '#include "barretenberg/crypto/merkle_tree/[^"]+"' \
                  "$SRC/vm2" "$SRC/world_state_reference" \
                | sed 's|.*merkle_tree/||; s|"$||' | sort -u | tr '\n' ' ')"
assert_eq "measured: vm2_sim + world_state_reference use exactly five merkle_tree headers" \
  "hash_path.hpp indexed_tree/indexed_leaf.hpp memory_tree.hpp response.hpp types.hpp " \
  "$used_headers"

# The unused include that reached vm2_sim, and its removal.
assert_true "measured: before, response.hpp includes the LMDB tree store" \
  grep -q 'lmdb_store/lmdb_tree_store.hpp' "$MT/response.hpp"
assert_false "measured: after, it does not" \
  grep -q 'lmdb_store/lmdb_tree_store.hpp' \
    "$M3_WORK/patched/barretenberg/cpp/src/barretenberg/crypto/merkle_tree/response.hpp"
assert_contains "PR.md states response.hpp named nothing from that include" \
  "named nothing from it" "$doc"

# print_store_data: one occurrence in the whole tree — its own definition.
occurrences="$(grep -rl 'print_store_data' "$M3_WORK/base/barretenberg/cpp/src" \
                 "$M3_WORK/base/barretenberg/cpp/scripts" 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "measured: print_store_data appears in exactly one file (its definition)" \
  1 "$occurrences"
assert_contains "PR.md states print_store_data has no callers" \
  "has no callers anywhere in the tree" "$doc"

# The guard PR.md quotes, verbatim, in the base tree.
assert_true "measured: cmake/module.cmake carries the wasm32 / BB_LITE guard PR.md quotes" \
  grep -qF 'if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "wasm32" AND NOT BB_LITE)' \
    "$M3_WORK/base/barretenberg/cpp/cmake/module.cmake"
assert_contains "PR.md quotes that guard" \
  'if(NOT CMAKE_SYSTEM_PROCESSOR MATCHES "wasm32" AND NOT BB_LITE)' "$doc"
assert_true "measured: BB_LITE's help string is the one PR.md quotes" \
  grep -qF 'Exclude server-side subsystems: lmdb, world_state, ipc, nodejs_module' \
    "$M3_WORK/base/barretenberg/cpp/CMakeLists.txt"
assert_contains "PR.md quotes that help string" \
  "Exclude server-side subsystems: lmdb, world_state, ipc, nodejs_module" "$doc"

# bootstrap.sh really does discover test binaries by globbing.
assert_true "measured: bootstrap.sh globs test targets rather than listing them" \
  grep -qF 'for bin in ./bin/*_tests' "$M3_WORK/base/barretenberg/cpp/bootstrap.sh"
assert_contains "PR.md relies on exactly that" "for bin in ./bin/*_tests" "$doc"

# ---------------------------------------------------------------------------
# The stated limitations, checked against the patched tree
# ---------------------------------------------------------------------------
PSRC="$M3_WORK/patched/barretenberg/cpp/src"
assert_contains "PR.md states crypto_merkle_tree becomes an INTERFACE library" \
  "becomes an INTERFACE library" "$doc"
assert_eq "measured: crypto_merkle_tree_objects no longer exists anywhere in the tree" "" \
  "$(grep -rl 'crypto_merkle_tree_objects' "$PSRC" \
       "$M3_WORK/patched/barretenberg/cpp/cmake" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//')"
assert_true "measured: src/CMakeLists.txt now names crypto_merkle_tree_lmdb_objects" \
  grep -qF 'crypto_merkle_tree_lmdb_objects' "$PSRC/CMakeLists.txt"

assert_contains "PR.md states there are now two test binaries" \
  "Two test binaries instead of one" "$doc"
assert_true "measured: scripts/merkle_tree_tests.sh runs the second binary" \
  grep -qF 'crypto_merkle_tree_lmdb_tests' \
    "$M3_WORK/patched/barretenberg/cpp/scripts/merkle_tree_tests.sh"
assert_true "measured: the audit scope document was updated for the new paths" \
  grep -qF 'merkle_tree_lmdb' \
    "$M3_WORK/patched/barretenberg/cpp/scripts/audit/audit_scopes/merkle_tree_audit_scope.md"

assert_contains "PR.md states the pre-existing circular include it does not fix" \
  "circular include between two modules" "$doc"
assert_true "measured: the moved tree store still includes world_state/types.hpp" \
  grep -qF 'barretenberg/world_state/types.hpp' \
    "$PSRC/barretenberg/crypto/merkle_tree_lmdb/lmdb_store/lmdb_tree_store.hpp"
assert_true "measured: and world_state/types.hpp still includes the tree store" \
  grep -qF 'crypto/merkle_tree_lmdb/lmdb_store/lmdb_tree_store.hpp' \
    "$PSRC/barretenberg/world_state/types.hpp"

assert_contains "PR.md states the global LMDB include directory is NOT removed" \
  "still on every translation unit's command line" "$doc"
assert_contains "PR.md names the configurations it did not verify" \
  "Not verified: the \`fuzzing\` and \`wasm\` presets" "$flat"
assert_contains "PR.md states that AVM=ON was not exercised" \
  "Not verified: any configuration with \`-DAVM=ON\`" "$doc"

# The configurations it names must exist, or the limitation is about nothing.
# This is where the first draft of PR.md was wrong: it called BB_LITE a preset.
presets="$(cat "$M3_WORK/base/barretenberg/cpp/CMakePresets.json")"
for p in '"fuzzing"' '"wasm"' '"cross-base"'; do
  assert_contains "the preset $p it declines to claim for really exists" "$p" "$presets"
done
assert_not_contains "there is no 'bb-lite' preset, and PR.md no longer calls it one" \
  '"bb-lite"' "$presets"
assert_contains "PR.md says BB_LITE is an option rather than a preset" \
  "\`BB_LITE\` is a CMake option, not a preset" "$flat"
assert_true "measured: BB_LITE really is declared with option()" \
  grep -qF 'option(BB_LITE' "$M3_WORK/base/barretenberg/cpp/CMakeLists.txt"
assert_true "measured: the BB_LITE-sensitive guard PR.md names exists verbatim" \
  grep -qF 'if(NOT WASM AND NOT FUZZING AND NOT BB_LITE)' \
    "$M3_WORK/base/barretenberg/cpp/src/CMakeLists.txt"

# ---------------------------------------------------------------------------
# The motive is disclosed, and disclosed as a motive rather than as the argument
# ---------------------------------------------------------------------------
assert_contains "PR.md discloses why we care" "WebAssembly" "$doc"
assert_contains "and says plainly that this is not the reason to take the patch" \
  "not the reason to take it" "$doc"

# The series-level record the convention asks for.
series="$M3_PATCH_DIR/../SERIES.md"
assert_file "the series record exists at the upstream-bugs root" "$series"
assert_contains "and lists this patch with its dependencies and standalone status" \
  "aztec-merkle-tree-lmdb-split" "$(cat "$series")"

finish
