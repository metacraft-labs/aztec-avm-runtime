#!/usr/bin/env bash
# verify_noir_base_is_reconciled
#
# M37 verification: the Noir working branch sits on the reconciled base, every
# campaign commit is still on it, and the SSA-timer fix exists on the reconciled
# tree as well as on the one it was found in.
#
# WHAT WAS STALE, AND WHY A VERSION STRING ALONE WOULD NOT SAY IT. `blocktracer` —
# the branch every Noir change in this campaign sits on — reported nargo
# `1.0.0-beta.18`, while `wasm/reconcile-then-extract`, the branch whose entire
# purpose was "reconcile with upstream first", reported `1.0.0-beta.26`. Eight beta
# releases apart, and the reconciliation had been done and never merged back.
#
# THE CONTROL IS THE POINT. A check that asserts `1.0.0-beta.26` and nothing else
# passes equally well on a branch that has ALWAYS said that, so it would measure a
# constant rather than a move. This one reads the version at the pre-reconciliation
# commit out of the object store as well, requires it to be the OLD one, and
# requires the two to differ — so the assertion is about a transition.
#
# AND A VERSION BUMP IS NOT A RECONCILIATION EITHER. Someone could edit one line of
# `Cargo.toml`. So the reconciled base commit is required to be an ANCESTOR of the
# working branch, which no edit can fake, and so is every campaign commit — matched
# by SUBJECT, because a rebase would preserve the work and change the hashes, and by
# CONTENT for the one that matters, because a subject is a sentence and the fix is a
# behaviour.
#
# Run: just verify-m37-noir

TEST_NAME="verify_noir_base_is_reconciled"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m37.sh"
m37_summary_on_abnormal_exit

command -v git >/dev/null 2>&1 || die "git is required"

NOIR="$WORKSPACE_ROOT/noir"
git -C "$NOIR" rev-parse --git-dir >/dev/null 2>&1 || die "the noir checkout is not at $NOIR"

# The two ends of the move, named as data rather than as prose. `PRE` is the
# pre-reconciliation tip of `blocktracer` and `BASE` is the reconciled tree the
# merge brought in; both are read out of the object store, so this check does not
# depend on any worktree being on any branch.
PRE="4d238163059802877a24250fe6af36f3d1ee3985"   # perf(ssa): read the pass timer's clock only when the timing is printed
BASE="f403193bbc5b28aca0cf99f4fc603a1672e2724a"  # test(nargo trace): repair the generated per-fixture trace tests
BRANCH="blocktracer"

printf '\n=== %s\n' "$TEST_NAME"

for c in "$PRE" "$BASE"; do
  assert_eq "the noir object store carries ${c:0:10}" "commit" \
    "$(git -C "$NOIR" cat-file -t "$c" 2>/dev/null || echo missing)"
done

TIP="$(git -C "$NOIR" rev-parse "refs/heads/$BRANCH" 2>/dev/null || true)"
assert_ge "the working branch exists" 40 "${#TIP}"
note "$BRANCH is at ${TIP:0:10}"

# --- the version, at both ends ----------------------------------------------
ver() { git -C "$NOIR" show "$1:Cargo.toml" 2>/dev/null | sed -n 's/^version = "\(.*\)"$/\1/p' | head -1; }
V_PRE="$(ver "$PRE")"
V_NOW="$(ver "$TIP")"
V_BASE="$(ver "$BASE")"

assert_eq "the PRE-reconciliation base reports the OLD nargo version — the control that this measures a move" \
  "1.0.0-beta.18" "$V_PRE"
assert_eq "the reconciled base reports the new one" "1.0.0-beta.26" "$V_BASE"
assert_eq "and the working branch now reports it too" "1.0.0-beta.26" "$V_NOW"
if [ -n "$V_PRE" ] && [ "$V_PRE" != "$V_NOW" ]; then
  pass "the two ends differ, so neither reading is a constant  [$V_PRE -> $V_NOW]"
else
  fail "the two ends are the same value [$V_PRE]; this check would pass on a branch that never moved"
fi

# --- the move is a MERGE, not an edit ---------------------------------------
assert_true "the reconciled base is an ancestor of the working branch, which a Cargo.toml edit cannot fake" \
  git -C "$NOIR" merge-base --is-ancestor "$BASE" "$TIP"
assert_true "…and so is the pre-reconciliation tip, so nothing was rewritten away" \
  git -C "$NOIR" merge-base --is-ancestor "$PRE" "$TIP"
assert_false "…and the reconciled base was NOT already an ancestor before the merge, which is what says the merge did something" \
  git -C "$NOIR" merge-base --is-ancestor "$BASE" "$PRE"

# --- every campaign commit is present, BY SUBJECT ---------------------------
# A rebase would keep the work and change every hash, so a hash list would be a
# check on a strategy rather than on the work. Subjects are matched as fixed
# strings against the branch's own log, and the count is asserted per subject so a
# subject that matched twice — or a `--grep` that quietly stopped matching — is
# visible rather than folded into a total.
n_found=0
while IFS= read -r subject; do
  [ -n "$subject" ] || continue
  hits="$(git -C "$NOIR" log --format='%h' --fixed-strings --grep="$subject" "$TIP" | grep -c . || true)"
  assert_eq "campaign commit present by subject: '$subject'" "1" "$hits"
  [ "$hits" = "1" ] && n_found=$((n_found + 1))
done <<'EOF'
feat(tracer): render Field as fixed-width hex
test(tracer): repin the fixture expectations that measurement moved
feat(wasm): compile a Noir package tree from an in-memory virtual filesystem
perf(ssa): read the pass timer's clock only when the timing is printed
EOF
assert_eq "all four campaign commits are on the reconciled branch" "4" "$n_found"

# …and the needle can miss, so "found" is a measurement. A subject that is not
# there must come back 0 — otherwise `--grep` matching everything would satisfy the
# four assertions above without reading anything.
assert_eq "the subject search returns nothing for a subject that is not there" "0" \
  "$(git -C "$NOIR" log --format='%h' --fixed-strings \
       --grep='feat(tracer): a subject no commit in this branch carries' "$TIP" | grep -c . || true)"

# --- THE SSA-TIMER FIX, BY CONTENT AND NOT BY SUBJECT -----------------------
#
# M37's deliverable is that the fix exists "where it was found as well as where it
# will be filed". The prepared patch is generated against upstream's `3d3a1ce78`,
# and M37's own text says it "has never been applied to the tree it was found in".
# MEASURED, that sentence is false in one direction and true in the other, and the
# two are asserted separately because they are different claims:
#   * the pre-reconciliation `blocktracer` DOES carry it — it is the commit the
#     patch's own `From:` line names;
#   * the reconciled BASE does not, and neither does upstream;
#   * the merged working branch does, which is the deliverable.
helper() { git -C "$NOIR" show "$1:compiler/noirc_evaluator/src/ssa/builder.rs" 2>/dev/null \
           | sed -n '/^pub(super) fn time<T>/,/^}/p'; }
EARLY='if !print_timings {'

assert_true "the pre-reconciliation branch already carried the SSA-timer fix" \
  str_has_sub "$(helper "$PRE")" "$EARLY"
assert_false "the reconciled BASE did not — which is the half M37's deliverable is about" \
  str_has_sub "$(helper "$BASE")" "$EARLY"
assert_true "and the reconciled working branch carries it now" \
  str_has_sub "$(helper "$TIP")" "$EARLY"
# The needle has to be able to miss, and the helper has to be non-empty, or all
# three readings above are statements about an empty string.
assert_ge "the helper was found in the working branch at all" 100 "$(printf '%s' "$(helper "$TIP")" | wc -c)"
assert_ge "…and in the reconciled base, so the FALSE reading above is about content" \
  100 "$(printf '%s' "$(helper "$BASE")" | wc -c)"
assert_true "…and both still read the clock on the printing path, so the fix is not a deletion" \
  str_has_sub "$(helper "$TIP")" "chrono::Utc::now().time();"

# --- the VFS compiler and the Field rendering survived the merge -------------
# Two files that only exist because of the campaign, asserted present in the tree
# rather than inferred from a commit subject.
for p in compiler/wasm/src/vfs.rs compiler/wasm/src/compile_vfs.rs; do
  assert_eq "the merged tree carries $p" "blob" \
    "$(git -C "$NOIR" cat-file -t "$TIP:$p" 2>/dev/null || echo missing)"
done
assert_true "the merged tracer still renders a Field as fixed-width hex" \
  str_has_sub "$(git -C "$NOIR" show "$TIP:tooling/tracer/src/tracer_glue.rs" 2>/dev/null)" \
  "ValueRecord::String"

# --- `wasm/webpage` is STILL unpublished, and that is fact 7 of OQ-7 ---------
#
# Publishing it would reopen a settled question (JOIN-SHAPE.md §6), so its absence
# from the remote is a property this milestone must not have changed. Asked of
# `ls-remote` when the network allows and of the local remote-tracking refs
# otherwise, and the counter carries its own positive control so "zero" is a
# measurement rather than a predicate that never matches.
REFS="$(git -C "$NOIR" ls-remote --heads origin 2>/dev/null || git -C "$NOIR" for-each-ref --format='%(refname)' refs/remotes/origin)"
assert_ge "the remote ref listing is not empty" 5 "$(printf '%s\n' "$REFS" | grep -c . || true)"
assert_eq "wasm/webpage appears in ZERO published refs" "0" \
  "$(printf '%s\n' "$REFS" | grep -c 'wasm/webpage' || true)"
assert_ge "…and the same predicate finds the branches that ARE published" 1 \
  "$(printf '%s\n' "$REFS" | grep -c 'wasm/reconcile-then-extract' || true)"
assert_ge "…and finds the working branch itself" 1 \
  "$(printf '%s\n' "$REFS" | grep -c "$BRANCH" || true)"

# The working branch's tip must be PUBLISHED, which is this campaign's own rule:
# a pin that is not published is a local file.
assert_ge "the working branch's tip is reachable from a published ref" 1 \
  "$(printf '%s\n' "$REFS" | grep -c "$TIP" || true)"

m37_finish
