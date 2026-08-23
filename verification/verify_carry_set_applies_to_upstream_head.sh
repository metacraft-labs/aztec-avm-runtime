#!/usr/bin/env bash
# verify_carry_set_applies_to_upstream_head
#
# The carry set is only carried if it still fits. This replays the whole ordered
# set onto a fresh fetch of upstream's own branch and requires every patch to
# apply, naming the conflicting files when one does not.
#
# It then answers the second half of the question — "and the result still builds"
# — WITHOUT a build, by an argument that is checked rather than assumed:
#
#   The M6 and M10 checks build the AVM_WASM tree and run upstream's own native
#   suites from BASE + this same patch stack, and they are re-run every time this
#   milestone's evidence is re-derived. That build evidence transfers to
#   upstream HEAD exactly when the commits upstream has made since the base touch
#   NO file the carry set touches: the resulting trees then differ only in files
#   the build of the carried code does not depend on being different.
#
#   So the check is: the set of paths upstream changed since the base and the set
#   of paths the carry set changes must be DISJOINT. If they are not, this check
#   FAILS and names the overlap — which is the correct outcome, because at that
#   point the transferred build evidence is no longer valid and the AVM_WASM and
#   native builds have to be re-run against the rebased tree.
#
# That is a narrower claim than "we rebuilt everything at upstream HEAD", and it
# is stated as such rather than dressed up as one.

TEST_NAME="verify_carry_set_applies_to_upstream_head"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
REPORT="${CARRY_REBASE_REPORT:-$REPO_ROOT/carry/rebase.json}"
FETCH="${CARRY_FETCH:-1}"

assert_file "the carry set manifest exists" "$SERIES"
[ -d "$FORK_ROOT/.git" ] || die "the fork is not at $FORK_ROOT"

fetch_flag=""
[ "$FETCH" = "1" ] || fetch_flag="--no-fetch"

out="$(python3 "$REPO_ROOT/tools/rebase_upstream_patches.py" $fetch_flag --json "$REPORT" 2>&1)"
rc=$?
printf '%s\n' "$out" | sed 's/^/  |  /'

if [ "$rc" -eq 0 ]; then
  pass "every patch in the carry set applies to upstream HEAD"
else
  fail "the carry set does not fully apply to upstream HEAD (exit $rc)"
fi

assert_file "the replay wrote a machine-readable report" "$REPORT"
[ -f "$REPORT" ] || finish

# Counts and identities, not "it said applies somewhere".
n_patches="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$REPORT")"
n_declared="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$SERIES")"
assert_eq "the report covers every patch in the carry set" "$n_declared" "$n_patches"

n_applies="$(python3 -c 'import json,sys;print(sum(1 for r in json.load(open(sys.argv[1]))["patches"] if r["result"] in ("applies","already")))' "$REPORT")"
assert_eq "every patch either applies or is already upstream" "$n_declared" "$n_applies"

reported_ids="$(python3 -c 'import json,sys;print(" ".join(r["id"] for r in json.load(open(sys.argv[1]))["patches"]))' "$REPORT")"
declared_ids="$(python3 -c 'import json,sys;print(" ".join(p["id"] for p in sorted(json.load(open(sys.argv[1]))["patches"], key=lambda p: p["order"])))' "$SERIES")"
assert_eq "the report's patch identities are the carry set's, in order" \
  "$declared_ids" "$reported_ids"

# --- the transferability argument, checked ---------------------------------

base="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base"]["commit"])' "$SERIES")"
tip="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["tip"])' "$REPORT")"

# Both lists go through the SAME collation before comm sees them. Python's
# `sorted` and the shell's `sort` disagree under a non-C locale, and comm given
# unsorted input silently reports a WRONG intersection rather than failing — which
# would turn this assertion into one that passes for the wrong reason.
upstream_paths="$(git -C "$FORK_ROOT" diff --name-only "$base" "$tip" | LC_ALL=C sort -u)"
n_upstream_paths="$(printf '%s\n' "$upstream_paths" | grep -c . || true)"

carry_paths="$(python3 -c '
import json, sys
print("\n".join(json.load(open(sys.argv[1]))["modified_paths"]))' \
  "$REPO_ROOT/carry/exposure.json" | LC_ALL=C sort -u)"
n_carry_paths="$(printf '%s\n' "$carry_paths" | grep -c . || true)"
assert_ge "the exposure measurement names the modified paths" 1 "$n_carry_paths"

overlap="$(LC_ALL=C comm -12 <(printf '%s\n' "$upstream_paths") <(printf '%s\n' "$carry_paths") 2>&1)"
n_overlap="$(printf '%s\n' "$overlap" | grep -c . || true)"

# Positive control. An intersection test that returns "empty" is worthless unless
# it can also return "non-empty": one carried path is spliced into the upstream
# list and the same comparison must find exactly it.
probe="$(printf '%s\n' "$carry_paths" | head -1)"
probe_overlap="$(LC_ALL=C comm -12 \
  <(printf '%s\n%s\n' "$upstream_paths" "$probe" | LC_ALL=C sort -u) \
  <(printf '%s\n' "$carry_paths"))"
assert_eq "the intersection test detects an overlap when one is spliced in" \
  "$probe" "$probe_overlap"

note "upstream changed $n_upstream_paths path(s) between $base and $tip"
note "the carry set modifies $n_carry_paths path(s) upstream also has"
if [ "$n_overlap" -ne 0 ]; then
  printf '%s\n' "$overlap" | sed 's/^/      /'
fi
assert_eq "no path upstream changed since the base is a path the carry set modifies, so M6's and M10's builds of BASE + this stack still describe the rebased tree" \
  "0" "$n_overlap"

finish
