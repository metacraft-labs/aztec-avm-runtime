#!/usr/bin/env bash
# verify_merkle_lmdb_patch_applies_to_upstream
#
# The prepared `git format-patch` file applies cleanly to the base commit it
# names, `233d8e0993`, and the result configures and builds.
#
# "Applies cleanly" is re-measured every run against the pristine base worktree
# with `git apply --check` — the patch is not assumed to still apply because it
# once did. Two negative controls keep the measurement from being trivially
# green:
#
#   * the same patch must FAIL to apply to the already-patched tree, and
#   * `git apply --check -R` (reverse) must SUCCEED there,
#
# so a `git apply --check` that had degenerated into always-true would be caught.
#
# "The result configures and builds" is checked on the tree that `git am`
# actually produced: its CMake cache must exist, `ninja` must exit 0 for the
# full target list, and a binary produced from it must run. The build is
# incremental, so this costs seconds once the neutrality check has run; if it
# has not, the neutrality check is run first to produce the trees.
#
# Run: just verify-merkle-patch-applies

TEST_NAME="verify_merkle_lmdb_patch_applies_to_upstream"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_merkle_lmdb.sh"

m3_prepare_trees

# ---------------------------------------------------------------------------
# The file is a real format-patch, and it names the base we test against
# ---------------------------------------------------------------------------
assert_file "the prepared patch file is present" "$M3_PATCH_FILE"
assert_prefix "it is a git format-patch, and its From line names the split commit" \
  "From $M3_SPLIT_REV" "$(head -1 "$M3_PATCH_FILE")"
assert_contains "it carries a Subject line for the upstream audience" \
  "Subject: [PATCH] refactor(crypto): split crypto_merkle_tree" \
  "$(head -20 "$M3_PATCH_FILE")"

# PR.md must name the same base the patch is tested against; a patch verified
# against one commit and advertised against another is the failure this catches.
pr_md="$M3_PATCH_DIR/PR.md"
assert_file "PR.md is present next to the patch" "$pr_md"
assert_contains "PR.md names the base commit the patch is tested against" \
  "$M3_BASE_REV" "$(cat "$pr_md")"

# ---------------------------------------------------------------------------
# It applies to 233d8e0993 — measured now, in the pristine base worktree
# ---------------------------------------------------------------------------
assert_eq "the base worktree is still exactly $M3_BASE_REV" \
  "$(git -C "$FORK_ROOT" rev-parse "$M3_BASE_REV")" \
  "$(git -C "$M3_WORK/base" rev-parse HEAD)"

git -C "$M3_WORK/base" apply --check "$M3_PATCH_FILE" 2>"$M3_WORK/apply-check.log"
assert_eq "git apply --check succeeds against $M3_BASE_REV" 0 "$?"

# Negative control 1: it must not apply twice.
git -C "$M3_WORK/patched" apply --check "$M3_PATCH_FILE" >/dev/null 2>&1
rc_twice=$?
assert_false "negative control: it does NOT apply to the already-patched tree" \
  test "$rc_twice" -eq 0
# Negative control 2: but it does reverse-apply there, i.e. it is the same patch.
git -C "$M3_WORK/patched" apply --check -R "$M3_PATCH_FILE" >/dev/null 2>&1
assert_eq "negative control: it reverse-applies to the patched tree" 0 "$?"

# The size PR.md advertises, re-derived from the patch rather than trusted.
files_touched="$(git -C "$M3_WORK/base" apply --numstat "$M3_PATCH_FILE" 2>/dev/null | grep -c .)"
assert_ge "the patch touches a non-trivial number of paths" 30 "$files_touched"
note "paths touched by the patch (pre-rename-detection): $files_touched"

# ---------------------------------------------------------------------------
# `git am` produced the tree the milestone measured
# ---------------------------------------------------------------------------
assert_eq "the applied tree sits directly on the base commit" \
  "$(git -C "$FORK_ROOT" rev-parse "$M3_BASE_REV")" \
  "$(git -C "$M3_WORK/patched" rev-parse 'HEAD^')"
assert_eq "git am added exactly one commit" 1 \
  "$(git -C "$M3_WORK/patched" rev-list --count "$M3_BASE_REV..HEAD")"
if git -C "$FORK_ROOT" rev-parse --verify --quiet "$M3_SPLIT_REV^{commit}" >/dev/null; then
  assert_eq "applying the patch file reproduces the recorded commit's tree exactly" \
    "$(git -C "$FORK_ROOT" rev-parse "$M3_SPLIT_REV^{tree}")" \
    "$(git -C "$M3_WORK/patched" rev-parse 'HEAD^{tree}')"
else
  fail "the recorded split commit $M3_SPLIT_REV is not in $FORK_ROOT"
fi
# No leftovers on any path the patch itself touches. Scoped that way on purpose:
# `yarn install`, which the build has to run to get nodejs_module to configure,
# rewrites `nodejs_module/yarn.lock` and `.yarnrc.yml`, and that is our build
# seeding rather than anything the patch did.
patch_paths="$(git -C "$M3_WORK/base" apply --numstat "$M3_PATCH_FILE" 2>/dev/null | cut -f3-)"
leftovers="$(cd "$M3_WORK/patched" && git status --porcelain -- $patch_paths 2>/dev/null)"
assert_eq "no path the patch touches is left uncommitted in the applied tree" "" "$leftovers"

# ---------------------------------------------------------------------------
# ...and it configures and builds
# ---------------------------------------------------------------------------
BP="$M3_WORK/patched/barretenberg/cpp/build-native"

# Ensure the tree has been configured and built at least once.
m3_measured
assert_eq "the applied tree's build exited 0" 0 "${M3_BUILD_RC_PATCHED:--}"
assert_file "the applied tree configured (CMake cache exists)" "$BP/CMakeCache.txt"
assert_file "the applied tree's build.ninja exists" "$BP/build.ninja"

# Re-run the build now, so "builds" is a fact about this run and not only about
# a previous one. Incremental: seconds when nothing changed.
m3_build "$M3_WORK/patched" $M3_COMMON_TARGETS $M3_PATCHED_EXTRA_TARGETS
rc_build=$?
assert_eq "ninja exits 0 for the applied tree, re-run now" 0 "$rc_build"
[ "$rc_build" -eq 0 ] || note "see $M3_WORK/patched/m3-build.log"

# And a binary the patch is responsible for actually runs.
r="$(m3_run_gtest "$BP" crypto_merkle_tree_lmdb_tests "$M3_WORK/applies-lmdb-tests.txt")"
set -- $r
assert_eq "the new crypto_merkle_tree_lmdb_tests binary runs and exits 0" 0 "$1"
assert_eq "and reports the tests that moved into the new module" 96 "$2"

finish
