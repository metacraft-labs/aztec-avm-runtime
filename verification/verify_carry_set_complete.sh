#!/usr/bin/env bash
# verify_carry_set_complete
#
# The downstream carry set is an ordered list, and this holds it to the two things
# that make it trustworthy: every member is traceable to a directory under
# codetracer-specs/upstream-bugs/, and nothing in that directory is missing from
# it. A carry set that quietly omits a patch is worse than no carry set — the
# rebase harness would then report green while a patch rots.
#
# It also holds the FOUR copies of each patch's title to each other: the one in
# carry/series.json, the one in the entry's PR.md, the `Subject:` of the patch file
# itself (unwrapped the way git unwraps it), and the subject of the commit on the
# published branch that would be filed. This project has twice shipped documents
# that disagreed about a number; four copies of a string is the same failure
# waiting to happen, so all four are compared rather than one being trusted.

TEST_NAME="verify_carry_set_complete"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
SPECS="$WORKSPACE_ROOT/codetracer-specs"
BUGS="$SPECS/upstream-bugs"

assert_file "the carry set manifest exists" "$SERIES"
assert_dir  "the upstream-bugs directory exists" "$BUGS"

# The branch identities below are read from `origin/<branch>`, not from a local
# branch: a fresh clone of the fork (CI's, for one) has only its default branch
# locally, and what a pull request is opened from is the published ref anyway.
# Fetch first, so "published" means published rather than last-fetched.
if ! git -C "$FORK_ROOT" fetch --quiet origin 2>/dev/null; then
  die "could not fetch the fork's origin; the branch identities are read from it"
fi
[ -f "$SERIES" ] || die "no carry set to check"
[ -d "$BUGS" ] || die "no upstream-bugs directory at $BUGS"

ids="$(python3 -c 'import json,sys;print(" ".join(p["id"] for p in json.load(open(sys.argv[1]))["patches"]))' "$SERIES")"
n_ids="$(printf '%s\n' $ids | grep -c .)"
assert_eq "the carry set has five patches" "5" "$n_ids"

# Order must be 1..N with no gaps and no repeats: the set is replayed in it.
orders="$(python3 -c 'import json,sys;print(",".join(str(p["order"]) for p in json.load(open(sys.argv[1]))["patches"]))' "$SERIES")"
assert_eq "the orders are 1..5 in sequence" "1,2,3,4,5" "$orders"

# Every aztec-* entry in upstream-bugs is in the carry set. Derived from the
# directory rather than from a list here, so adding a sixth contribution and
# forgetting the manifest is a FAILURE and not a silent omission.
on_disk="$(cd "$BUGS" && ls -d aztec-*/ 2>/dev/null | sed 's#/$##' | sort | tr '\n' ' ')"
in_set="$(python3 -c 'import json,sys;print(" ".join(sorted(p["entry"] for p in json.load(open(sys.argv[1]))["patches"])) + " ")' "$SERIES")"
assert_eq "every aztec-* entry on disk is in the carry set" "$on_disk" "$in_set"

base_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["base"]["commit"])' "$SERIES")"
pins_commit="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
assert_eq "the carry set's base is the pinned C++ anchor, not a second declaration" \
  "$pins_commit" "$base_commit"

for id in $ids; do
  entry="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]==sys.argv[2])["entry"])' "$SERIES" "$id")"
  patch="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]==sys.argv[2])["patch"])' "$SERIES" "$id")"
  title="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]==sys.argv[2])["title"])' "$SERIES" "$id")"
  branch="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]==sys.argv[2])["branch"])' "$SERIES" "$id")"

  assert_file "$id: the patch file is where the carry set says" "$BUGS/$entry/$patch"
  assert_file "$id: the entry has a PR.md" "$BUGS/$entry/PR.md"
  assert_file "$id: the entry has a verify.sh" "$BUGS/$entry/verify.sh"

  # Copy 1 vs copy 2: PR.md's suggested title against the manifest's.
  md_title="$(awk '/^Suggested PR title:/{want=1;next} want && /^> `/{sub(/^> `/,"");sub(/`[[:space:]]*$/,"");print;exit}' "$BUGS/$entry/PR.md")"
  assert_eq "$id: PR.md's suggested title equals the carry set's" "$title" "$md_title"

  # Copy 3: the subject of the patch itself, unwrapped the way git does it.
  patch_subject="$(python3 - "$BUGS/$entry/$patch" <<'PY'
import re, sys
lines = open(sys.argv[1], errors="replace").read().splitlines()
out = []
for i, line in enumerate(lines):
    if line.startswith("Subject: "):
        s = re.sub(r"^Subject: (\[PATCH[^\]]*\] )?", "", line)
        out.append(s)
        # git unfolds a wrapped subject by joining continuation lines
        for cont in lines[i + 1:]:
            if cont.startswith(" ") or cont.startswith("\t"):
                out.append(cont.strip())
            else:
                break
        break
print(" ".join(out))
PY
)"
  assert_eq "$id: the patch file's own Subject equals the carry set's title" \
    "$title" "$patch_subject"

  # Copy 4, the one that actually gets filed: the branch's head commit.
  head_subject="$(git -C "$FORK_ROOT" log -1 --format=%s "origin/$branch" 2>/dev/null)"
  assert_eq "$id: the published branch head's subject equals the carry set's title" \
    "$title" "$head_subject"
done

# The dependency structure has to be internally consistent: every named
# dependency exists, and comes earlier in the order.
python3 - "$SERIES" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
by = {p["id"]: p for p in d["patches"]}
bad = []
for p in d["patches"]:
    for kind in ("apply_depends_on", "build_depends_on"):
        for dep in p[kind]:
            if dep not in by:
                bad.append("%s %s names unknown %s" % (p["id"], kind, dep))
            elif by[dep]["order"] >= p["order"]:
                bad.append("%s %s names %s, which is not earlier" % (p["id"], kind, dep))
        if kind == "apply_depends_on":
            overlap = set(p["apply_depends_on"]) & set(p["build_depends_on"])
            if overlap:
                bad.append("%s lists %s as BOTH an apply and a build dependency"
                           % (p["id"], ",".join(sorted(overlap))))
    if p["standalone"] and (p["apply_depends_on"] or p["build_depends_on"]):
        bad.append("%s claims standalone but has dependencies" % p["id"])
    if not p["standalone"] and not (p["apply_depends_on"] or p["build_depends_on"]):
        bad.append("%s claims non-standalone but has no dependencies" % p["id"])
sys.exit("\n".join(bad) if bad else 0)
PY
if [ "$?" -eq 0 ]; then
  pass "the dependency structure is consistent: every dependency exists, is earlier, and apply and build sets are disjoint"
else
  fail "the dependency structure is inconsistent (see above)"
fi

finish
