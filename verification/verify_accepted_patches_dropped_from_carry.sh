#!/usr/bin/env bash
# verify_accepted_patches_dropped_from_carry
#
# The carry set has to shrink when upstream takes something. If it does not, the
# rebase harness reports a conflict on a patch upstream already merged — which
# looks like breakage, costs an afternoon, and teaches people to ignore the
# harness.
#
# The mechanism is `tools/rebase_upstream_patches.py`'s `already_applied`: a patch
# is dropped when upstream demonstrably contains it, tested by reverse-applying it
# against upstream's tree. This check exercises that mechanism with a POSITIVE and
# a NEGATIVE control, using upstream's own commits, rather than asserting it works
# or waiting for a real acceptance to find out.
#
#   POSITIVE: a commit that IS in upstream HEAD, turned back into a patch file,
#             must be detected as already applied.
#   NEGATIVE: each of our five carried patches, none of which upstream has, must
#             be detected as NOT already applied — otherwise "already applied"
#             would be true of everything and the drop would eat the whole set.
#
# It also checks the two failure directions in the ledger: a patch marked accepted
# that upstream does not contain, and a patch upstream contains that is not marked
# accepted, are both reported rather than silently tolerated.

TEST_NAME="verify_accepted_patches_dropped_from_carry"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
SPECS="$WORKSPACE_ROOT/codetracer-specs"
assert_file "the carry set manifest exists" "$SERIES"
[ -d "$FORK_ROOT/.git" ] || die "the fork is not at $FORK_ROOT"

tip="$(git -C "$FORK_ROOT" rev-parse upstream/next 2>/dev/null)"
[ -n "$tip" ] || die "upstream/next is not present in $FORK_ROOT; fetch upstream first"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# THE MANIFEST IS THE TRACKED AUTHORITY FOR THE CARRY SET AND THIS CHECK MUTATES IT. It must
# therefore be able to say, before it does, that what it is about to save is not already somebody
# else's wreckage. An earlier version of this check restored the file with a plain `cp` AFTER the
# probe, with nothing in between guarding an abort: when a run died between the two copies — M11's
# E2BIG did exactly that — the file was left holding the probe's fake `accepted` status and its
# `https://example.invalid/1` URL, and the next run read the corruption as fact. Worse, M16's
# T-2b evidence needle was a SUBSTRING match on `"status": "prepared"`, so it kept passing against
# a manifest in which one of the five entries said `accepted`.
if grep -q 'example\.invalid' "$SERIES"; then
  die "the carry set manifest already contains this check's own probe URL (example.invalid).
       That is the wreckage of an aborted earlier run, not a real acceptance. Restore it with
       'git -C $REPO_ROOT show HEAD:carry/series.json > $SERIES' and re-run."
fi

# The detector, lifted out of the tool by IMPORT rather than reimplemented here.
# A check that re-writes the logic it is checking checks nothing.
detect() { # <patch-file> -> prints "yes" or "no"
  python3 - "$REPO_ROOT" "$FORK_ROOT" "$tip" "$1" <<'PY'
import importlib.util, sys
from pathlib import Path
repo, fork, tip, patch = sys.argv[1:5]
spec = importlib.util.spec_from_file_location(
    "rup", Path(repo) / "tools" / "rebase_upstream_patches.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
print("yes" if mod.already_applied(Path(fork), tip, Path(patch)) else "no")
PY
}

# --- POSITIVE control: upstream's own most recent commits -------------------
n_pos=0
for rev in $(git -C "$FORK_ROOT" rev-list -n 3 "$tip"); do
  git -C "$FORK_ROOT" format-patch -1 --stdout "$rev" > "$work/$rev.patch" 2>/dev/null
  if [ ! -s "$work/$rev.patch" ]; then
    fail "could not format a patch for upstream commit $rev"
    continue
  fi
  got="$(detect "$work/$rev.patch")"
  subject="$(git -C "$FORK_ROOT" log -1 --format=%s "$rev" | head -c 60)"
  assert_eq "a commit that IS in upstream HEAD is detected as already applied ($subject)" \
    "yes" "$got"
  n_pos=$((n_pos + 1))
done
assert_eq "three positive controls ran" "3" "$n_pos"

# --- NEGATIVE control: our five, none of which upstream has -----------------
n_neg=0
while IFS='|' read -r id entry patch; do
  got="$(detect "$SPECS/upstream-bugs/$entry/$patch")"
  assert_eq "$id: a patch upstream does NOT have is detected as not applied" "no" "$got"
  n_neg=$((n_neg + 1))
done < <(python3 -c 'import json,sys
for p in sorted(json.load(open(sys.argv[1]))["patches"], key=lambda p: p["order"]):
    print("%s|%s|%s" % (p["id"], p["entry"], p["patch"]))' "$SERIES")
assert_eq "five negative controls ran" "5" "$n_neg"

# --- the two ledger failure directions --------------------------------------
# Marked accepted, but upstream does not have it: must be reported as a failure.
probe="$work/series-accepted.json"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
d["patches"][0]["ledger"].update(status="accepted", url="https://example.invalid/1")
open(sys.argv[2], "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' \
  "$SERIES" "$probe"

saved="$work/series-saved.json"
cp "$SERIES" "$saved"

# THE RESTORE IS ARMED BEFORE THE MUTATION, NOT AFTER IT, and it runs on a signal as well as on a
# normal exit. Ordered restore-then-remove, because `$saved` lives inside `$work`: the previous
# trap deleted the work directory and the copy inside it, so there was nothing left to restore
# from even if anything had tried.
trap 'cp -f "$saved" "$SERIES" 2>/dev/null || true; rm -rf "$work"' EXIT INT TERM HUP
cp "$probe" "$SERIES"

# `harness_out`, not `out`: `out` is exported by the surrounding nix/direnv environment, and an
# assignment to an already-exported name keeps the export attribute — which is how 738 KB of report
# ended up in the environment and made every later exec fail E2BIG. lib.sh now de-exports such
# names, and this one is renamed as well so the check does not depend on that guard alone.
harness_out="$(python3 "$REPO_ROOT/tools/rebase_upstream_patches.py" --no-fetch 2>&1)"
rc=$?
cp "$saved" "$SERIES"

if [ "$rc" -ne 0 ]; then
  pass "a patch marked accepted that upstream does not contain fails the harness"
else
  fail "the harness exited 0 for a patch marked accepted that upstream does not contain"
fi
assert_contains "and it says so by name" "ledger says accepted, but upstream does not" "$harness_out"

# Restored exactly: a check that leaves the manifest mutated is worse than none.
assert_eq "the probe left the carry set manifest exactly as it found it" \
  "$(sha256sum "$saved" | awk '{print $1}')" \
  "$(sha256sum "$SERIES" | awk '{print $1}')"

# And the honest current state: nothing is accepted yet, so nothing is dropped.
n_accepted="$(python3 -c 'import json,sys
print(sum(1 for p in json.load(open(sys.argv[1]))["patches"] if p["ledger"]["status"] == "accepted"))' "$SERIES")"
n_total="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$SERIES")"
note "carry set today: $n_total patch(es), $n_accepted accepted, so $((n_total - n_accepted)) carried"
assert_eq "the carry set is the whole series, because nothing has been accepted yet" \
  "0" "$n_accepted"

finish
