#!/usr/bin/env bash
# verify_browser_chunk_budget
#
# M27 verification: "each chunk stays within its recorded gzipped budget and CI fails on regression".
#
# ===========================================================================================
# THE BUILD IS WHERE THE ENFORCEMENT LIVES; THIS CHECK PROVES THE ENFORCEMENT EXISTS.
# ===========================================================================================
#
# `browser/build.mjs` walks the output, gzips every file, matches it against `chunk-budgets.json`
# and THROWS on a violation — upstream's Playground plugin's shape, and the deliverable's word is
# "a regression is a build failure rather than a discovery". So a check that merely re-measured the
# sizes would be measuring the same thing twice and enforcing nothing.
#
# What this check adds is the property a build cannot assert about itself: that the enforcement
# CAN FAIL. It builds the bundle with a deliberately impossible budget, in a scratch copy of the
# budgets file, and requires the build to exit NON-ZERO with the violating file named. Without
# that, "the build passed" is equally consistent with "the budgets are enormous", "the matcher
# matches nothing" and "the throw was removed".
#
# TWO NEGATIVE CONTROLS, because there are two ways the budget file can be vacuous:
#   * A BUDGET THAT IS TOO SMALL must fail, naming the file. (the enforcement works)
#   * A FILE COVERED BY NO BUDGET must fail too. (the coverage is total)
# The second is this repository's divergence from upstream's config, which ends with a catch-all;
# here an uncovered file is a failure, because "the budget did not catch it" and "nothing had a
# budget" are indistinguishable from the outside.
#
# Run: just verify-browser-chunk-budget

TEST_NAME="verify_browser_chunk_budget"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m27_require_bundle

echo "== 1. the recorded budgets, and what the build measured against them"

assert_file "the budgets are recorded in a tracked file" "$M27_BUDGETS"
assert_true "…and that file is tracked by git" \
  git -C "$REPO_ROOT" ls-files --error-unmatch "browser/chunk-budgets.json"

SUMMARY="$(python3 - "$M27_BUDGETS" "$BROWSER_DIST/chunks.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1]))
c = json.load(open(sys.argv[2]))
print("BUDGETS %d" % len(b["budgets"]))
print("ENTRYBUDGETS %d" % len(b["entryBudgets"]))
print("FILES %d" % len(c["files"]))
print("UNCOVERED %d" % len(c["uncovered"]))
print("VIOLATIONS %d" % len(c["violations"]))
print("TOTALGZIP %d" % c["totalGzipBytes"])
for row in c["files"]:
    print("FILE %s %d %s %s" % (row["file"], row["gzipBytes"], row.get("budget", "NONE"), row.get("maxGzipKB", "NONE")))
for row in c["eager"]:
    print("EAGER %s %d %s %d" % (row["entry"], row["gzipBytes"], row["maxGzipKB"], len(row["files"])))
PY
)"

N_BUDGETS="$(printf '%s\n' "$SUMMARY" | sed -n 's/^BUDGETS //p')"
N_ENTRY="$(printf '%s\n' "$SUMMARY" | sed -n 's/^ENTRYBUDGETS //p')"
N_FILES="$(printf '%s\n' "$SUMMARY" | sed -n 's/^FILES //p')"
assert_ge "there are at least eight per-file budgets" 8 "$N_BUDGETS"
assert_ge "…and four per-entry-point eager budgets" 4 "$N_ENTRY"
assert_ge "…measured against a substantial number of output files" 20 "$N_FILES"
assert_eq "no output file is covered by no budget" "0" "$(printf '%s\n' "$SUMMARY" | sed -n 's/^UNCOVERED //p')"
assert_eq "…and no budget was exceeded" "0" "$(printf '%s\n' "$SUMMARY" | sed -n 's/^VIOLATIONS //p')"

echo "== 2. the numbers DD-11 is about, read out of the build's own report"

BROWSER_EAGER="$(printf '%s\n' "$SUMMARY" | sed -n 's/^EAGER browser.js //p' | cut -d' ' -f1)"
BROWSER_FILES="$(printf '%s\n' "$SUMMARY" | sed -n 's/^EAGER browser.js //p' | cut -d' ' -f3)"
note "the browser entry's EAGER set is $BROWSER_EAGER bytes gzipped across $BROWSER_FILES file(s)"
assert_ge "the eager set is non-trivial, i.e. it is the real runtime" 100000 "$BROWSER_EAGER"
assert_true "…and it is under 300 KB gzipped" test "$BROWSER_EAGER" -lt 307200
assert_ge "…across several chunks, i.e. splitting happened" 3 "$BROWSER_FILES"

# THE PROVING WASM AND THE ARTIFACTS ARE RECORDED AND ARE NOT IN THAT SET. Their SIZES are budgeted
# rather than merely their absence, so a reader sees what the page is not paying for.
BB_GZIP="$(printf '%s\n' "$SUMMARY" | grep -E '^FILE chunks/barretenberg-[A-Z0-9]+\.js ' | awk '{print $3}')"
assert_ge "the barretenberg proving chunk is recorded, and it is enormous" 2000000 "${BB_GZIP:-0}"
EAGER_FILE_LIST="$(python3 - "$BROWSER_DIST/chunks.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
row = next(r for r in c["eager"] if r["entry"] == "browser.js")
print("\n".join(row["files"]))
PY
)"
assert_false "…and it is NOT in the browser entry's eager set" str_has_sub "$EAGER_FILE_LIST" 'barretenberg'
assert_false "…nor is any protocol-contract artifact" str_has_sub "$EAGER_FILE_LIST" 'Registry'
assert_false "…nor FeeJuice" str_has_sub "$EAGER_FILE_LIST" 'FeeJuice'

echo "== 3. THE ENFORCEMENT CAN FAIL — a budget made impossible"

WORK="$M27_WORK/budget-control"
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$M27_BUDGETS" "$WORK/budgets.orig.json"

# A MUTATION HARNESS AND A BUILD ARE TWO WRITERS. The budgets file is restored in a trap, and the
# restoration is VERIFIED by comparing against the copy taken above rather than by `git status` —
# `CAMPAIGN-BRIEF.md` records that `git status --porcelain` on an untracked path proves nothing.
_restore_budgets() {
  cp "$WORK/budgets.orig.json" "$M27_BUDGETS"
  touch "$M27_BUDGETS"
}
trap '_restore_budgets' EXIT

python3 - "$M27_BUDGETS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
for b in d["budgets"]:
    if b["name"] == "shared-chunk":
        b["maxGzipKB"] = 1
json.dump(d, open(p, "w"), indent=2)
PY
TOO_SMALL="$(m27_bounded "$M27_BUILD_TIMEOUT" "the budget-control build" node "$BROWSER_DIR/build.mjs"; printf '%s' "$?")"
CONTROL_OUT="$(cat "$M27_WORK/bounded.log")"
assert_false "a shared chunk budget of 1 KB makes the build FAIL" test "$TOO_SMALL" -eq 0
assert_true "…and the failure names the chunk-budget rule" \
  str_has_sub "$CONTROL_OUT" 'chunk budget exceeded'
assert_true "…and says it is a build failure rather than a warning" \
  str_has_sub "$CONTROL_OUT" 'BUILD FAILURE, not a warning'
assert_true "…and names the offending chunk by path" str_has_sub "$CONTROL_OUT" 'chunks/chunk-'

echo "== 4. …and so does a file covered by NO budget"

_restore_budgets
python3 - "$M27_BUDGETS" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["budgets"] = [b for b in d["budgets"] if b["name"] != "shared-chunk"]
json.dump(d, open(p, "w"), indent=2)
PY
UNCOVERED_RC="$(m27_bounded "$M27_BUILD_TIMEOUT" "the coverage-control build" node "$BROWSER_DIR/build.mjs"; printf '%s' "$?")"
UNCOVERED_OUT="$(cat "$M27_WORK/bounded.log")"
assert_false "deleting a budget makes the build FAIL rather than pass silently" test "$UNCOVERED_RC" -eq 0
assert_true "…naming coverage rather than size" \
  str_has_sub "$UNCOVERED_OUT" 'covered by no budget'

echo "== 5. …and the restored file rebuilds green"

_restore_budgets
trap - EXIT
assert_true "the budgets file is byte-identical to what it was" \
  cmp -s "$WORK/budgets.orig.json" "$M27_BUDGETS"
FINAL_RC="$(m27_bounded "$M27_BUILD_TIMEOUT" "the restored build" node "$BROWSER_DIR/build.mjs"; printf '%s' "$?")"
FINAL_OUT="$(cat "$M27_WORK/bounded.log")"
assert_eq "the restored budgets build cleanly" "0" "$FINAL_RC"
assert_true "…and the build says so" str_has_sub "$FINAL_OUT" 'all chunks within their recorded gzipped budgets'

m27_finish
