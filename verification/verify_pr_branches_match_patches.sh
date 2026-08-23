#!/usr/bin/env bash
# verify_pr_branches_match_patches
#
# What gets filed upstream is a BRANCH, and what was reviewed is a PATCH FILE. If
# those two ever diverge — a fixup committed onto a branch, a patch file
# regenerated and the branch forgotten — the pull request stops being the thing
# the write-up describes, and nothing else in this repository would notice.
#
# So every branch is rebuilt from its patch file(s) and required to equal, to the
# commit id, what is PUBLISHED on our fork's origin — the ref a pull request is
# actually opened from. The rebuild is deterministic by construction (committer
# identity and date come from the patch's own headers, signing off), so this
# compares commit ids rather than "equivalent" trees.
#
# The commit COUNT per branch is asserted separately, because "the pull request
# diff is exactly that patch" is a claim about how many commits are on the branch
# and an identity check alone would not make it.
#
# The `codetracer` development branch is held to the same standard.

TEST_NAME="verify_pr_branches_match_patches"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
assert_file "the carry set manifest exists" "$SERIES"
[ -d "$FORK_ROOT/.git" ] || die "the fork is not at $FORK_ROOT"

# Fresh remote-tracking refs: the point is to compare against what is PUBLISHED,
# and a stale origin/ ref would compare against what was published last time.
if ! git -C "$FORK_ROOT" fetch --quiet origin 2>/dev/null; then
  die "could not fetch our fork's origin; this check compares against published branches"
fi

work="${M11_WORK:-$HOME/.cache/aztec-m11-branches}"
require_work_dir "$work" 2

out="$(python3 "$REPO_ROOT/tools/make_fork_branches.py" --check --work "$work" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  |  /'

n_ok="$(printf '%s\n' "$out" | grep -c '^ok   ' || true)"
n_fail="$(printf '%s\n' "$out" | grep -c '^FAIL ' || true)"

# Six branches, each compared against what is PUBLISHED on our fork.
assert_eq "six branch identities were compared" "6" "$n_ok"
assert_eq "no branch differs from what its patch file(s) produce" "0" "$n_fail"
if [ "$rc" -eq 0 ]; then
  pass "the branch generator's own exit status is 0"
else
  fail "the branch generator exited $rc"
fi

# Each named branch is present in the output by NAME, so a generator that silently
# stopped after two branches cannot pass this by producing two ok lines.
for branch in $(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
print(" ".join(p["branch"] for p in d["patches"]))
' "$SERIES") $(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["fork"]["downstream_branch"])' "$SERIES"); do
  line_origin="$(printf '%s\n' "$out" | grep -c "^ok   origin/$branch  *[0-9a-f]" || true)"
  assert_eq "$branch: the published branch equals the rebuild" "1" "$line_origin"
done

# The one non-standalone branch must actually carry its dependencies, and the
# standalone ones must NOT: a pull request whose diff is "exactly that patch" is
# a claim about commit count.
base="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base"]["commit"])' "$SERIES")"
# `< <(...)` and not a pipe: a `while` on the right of a pipe runs in a subshell,
# so every pass and fail it recorded would be discarded and the assertion count
# would silently drop by five.
while read -r id branch want; do
  got="$(git -C "$FORK_ROOT" rev-list --count "$base..origin/$branch" 2>/dev/null)"
  assert_eq "$id: $branch carries $want commit(s) over the base" "$want" "$got"
done < <(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
for p in d["patches"]:
    deps = sorted(set(p["apply_depends_on"]) | set(p["build_depends_on"]))
    print("%s %s %d" % (p["id"], p["branch"], len(deps) + 1))
' "$SERIES")

finish
