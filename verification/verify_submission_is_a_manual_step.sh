#!/usr/bin/env bash
# verify_submission_is_a_manual_step
#
# Filing upstream is a person's decision. This milestone deliberately does NOT
# submit anything: it prepares branches and one script per pull request, and a
# human runs them. That is a property of the repository and it is checked here
# rather than left as an intention, because "we did not mean to file it" is not a
# defence once a pull request exists on someone else's project.
#
# What is asserted:
#
#   * Nothing in this repository, outside the five submission scripts a human
#     invokes, calls `gh pr create` — not CI, not a Justfile recipe, not a tool.
#   * Each of the five scripts exists, is executable, and is the one the carry set
#     names for that patch.
#   * Each one, in --dry-run, produces a body DERIVED from its PR.md, and creates
#     nothing.
#   * That body carries no internal repository, milestone or roadmap name. The
#     upstream-bugs convention requires the argument be made on upstream's own
#     terms, with our motive disclosed at the end and nothing else of ours in it.
#   * The stacked one refuses to run at all until its prerequisites are filed.
#   * The ledger's status agrees with reality: while everything is `prepared`,
#     no upstream URL exists anywhere.
#
# The dry runs make network calls (the tracker search), so this check requires
# network and says so rather than skipping.

TEST_NAME="verify_submission_is_a_manual_step"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SERIES="$REPO_ROOT/carry/series.json"
SPECS="$WORKSPACE_ROOT/codetracer-specs"
assert_file "the carry set manifest exists" "$SERIES"
command -v gh >/dev/null 2>&1 || die "gh is not on PATH; the submission scripts need it"
gh auth status >/dev/null 2>&1 || die "gh is not authenticated; the tracker search cannot run"

# --- nothing else can file ---------------------------------------------------
# This check names the string too, so it excludes itself BY PATH rather than by
# some pattern that could also exclude a real caller.
self="verification/$(basename "${BASH_SOURCE[0]}")"
# `git grep --untracked` and not `grep -r`: the scope of the claim is the files
# this repository SHIPS. A plain recursive grep also reads the vendored upstream
# sources under vm2wasm/src/, which are gitignored, are not ours, and contain the
# string in an unrelated document — and would have made this assertion fail for a
# reason that has nothing to do with what it is checking.
callers="$(git -C "$REPO_ROOT" grep -l --untracked --exclude-standard \
             -e "gh pr create" -- . 2>/dev/null \
           | grep -vx "$self" | LC_ALL=C sort)"
expected="submit/_lib.sh"
assert_eq "exactly one file in this repository can open a pull request" \
  "$expected" "$callers"

# And it is behind the dry-run guard rather than at the top level of the script.
guarded="$(awk '/if \[ "\$dry_run" -eq 1 \]/{seen=1} /gh pr create --repo/{ if (seen) print "after"; else print "before" }' \
             "$REPO_ROOT/submit/_lib.sh" | LC_ALL=C sort -u | tr '\n' ' ')"
assert_eq "the only gh pr create is downstream of the dry-run early return" \
  "after " "$guarded"

# --- the five scripts --------------------------------------------------------
n=0
while IFS='|' read -r id script entry; do
  n=$((n + 1))
  assert_file "$id: the submission script the carry set names exists" "$REPO_ROOT/$script"
  if [ -x "$REPO_ROOT/$script" ]; then
    pass "$id: it is executable"
  else
    fail "$id: $script is not executable"
  fi
  # It must invoke the shared implementation for ITS id and no other.
  ids_in_script="$(grep -oE 'submit_main p[0-9]' "$REPO_ROOT/$script" | awk '{print $2}' | LC_ALL=C sort -u | tr '\n' ' ')"
  assert_eq "$id: the script files exactly its own patch" "$id " "$ids_in_script"
done < <(python3 -c 'import json,sys
for p in sorted(json.load(open(sys.argv[1]))["patches"], key=lambda p: p["order"]):
    print("%s|%s|%s" % (p["id"], p["ledger"]["submission_script"], p["entry"]))' "$SERIES")
assert_eq "there is one submission script per patch" "5" "$n"

# --- the four standalone ones dry-run, and file nothing ----------------------
before_prs="$(gh pr list --repo AztecProtocol/aztec-packages --state all --author '@me' \
                --json number --limit 100 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
n_dry=0
for id in p1 p2 p3 p4; do
  script="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]==sys.argv[2])["ledger"]["submission_script"])' "$SERIES" "$id")"
  entry="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]==sys.argv[2])["entry"])' "$SERIES" "$id")"
  out="$("$REPO_ROOT/$script" --dry-run 2>&1)"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$id: the dry run completes"
  else
    fail "$id: the dry run exited $rc: $(printf '%s' "$out" | tail -3)"
    continue
  fi
  assert_contains "$id: the dry run says it filed nothing" "DRY RUN — nothing was filed" "$out"
  assert_contains "$id: the dry run ran the tracker search" "tracker search completed" "$out"

  body="$REPO_ROOT/.submit/$id/body.md"
  assert_file "$id: the dry run wrote a pull-request body" "$body"
  [ -f "$body" ] || continue

  # Derived, not typed: every `##` heading of PR.md's argument is in the body.
  want="$(awk '/^## /{f=1} f && /^## /' "$SPECS/upstream-bugs/$entry/PR.md" | LC_ALL=C sort)"
  got="$(grep '^## ' "$body" | LC_ALL=C sort)"
  assert_eq "$id: the body carries exactly PR.md's sections" "$want" "$got"

  # And nothing of ours. Each of these is a real leak that has to be absent.
  for needle in codetracer-specs aztec-avm-runtime metacraft-labs blocktracer \
                "upstream-bugs" "SERIES.md" "milestone" "M10" "M11" "roadmap"; do
    assert_not_contains "$id: the body does not name '$needle'" "$needle" "$(cat "$body")"
  done
  n_dry=$((n_dry + 1))
done
assert_eq "four standalone dry runs completed" "4" "$n_dry"

after_prs="$(gh pr list --repo AztecProtocol/aztec-packages --state all --author '@me' \
               --json number --limit 100 2>/dev/null | python3 -c 'import json,sys;print(len(json.load(sys.stdin)))')"
assert_eq "the dry runs opened no pull request upstream" "$before_prs" "$after_prs"

# --- the stacked one refuses ------------------------------------------------
p5_script="$(python3 -c 'import json,sys
d=json.load(open(sys.argv[1]));print(next(p for p in d["patches"] if p["id"]=="p5")["ledger"]["submission_script"])' "$SERIES")"
out5="$("$REPO_ROOT/$p5_script" --dry-run 2>&1)"
rc5=$?
if [ "$rc5" -ne 0 ]; then
  pass "the stacked patch's script refuses to run before its prerequisites are filed"
else
  fail "the stacked patch's script ran with no prerequisite filed (exit 0)"
fi
assert_contains "and it names the prerequisite it is waiting on" \
  "prerequisite p1 has not been filed" "$out5"
assert_contains "and it names the order to run them in" \
  "submit/pr3-widen-before-shifting.sh" "$out5"

# --- the ledger's claim about reality ---------------------------------------
n_prepared="$(python3 -c 'import json,sys
print(sum(1 for p in json.load(open(sys.argv[1]))["patches"] if p["ledger"]["status"] == "prepared"))' "$SERIES")"
n_url="$(python3 -c 'import json,sys
print(sum(1 for p in json.load(open(sys.argv[1]))["patches"] if p["ledger"]["url"]))' "$SERIES")"
assert_eq "all five are recorded as prepared, which is what unfiled means" "5" "$n_prepared"
assert_eq "no upstream URL is recorded, because nothing has been filed" "0" "$n_url"
n_ready="$(grep -c 'READY TO REVIEW — not filed' "$SPECS"/upstream-bugs/aztec-*/PR.md | grep -c ':1$')"
assert_eq "all five PR.md files still say READY TO REVIEW, not filed" "5" "$n_ready"

finish
