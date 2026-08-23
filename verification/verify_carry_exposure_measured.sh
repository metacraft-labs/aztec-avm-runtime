#!/usr/bin/env bash
# verify_carry_exposure_measured
#
# The milestone asks for "a recorded assessment of the total carry if NOTHING is
# accepted, so the exposure is a known number", and notes the spike's estimate:
# roughly 80 lines of CMake plus one function-level rebase risk in
# `hybrid_execution.cpp`. The instruction was to MEASURE it rather than repeat it.
#
# So this check does three things:
#
#   1. The measurement is reproducible — re-running the measurement tool over the
#      current patch files reproduces `carry/exposure.json` byte for byte.
#   2. The measurement is DERIVED from the patches, not typed — a probe that
#      perturbs one patch file must move the numbers.
#   3. The recorded exposure and the spike's estimate are compared explicitly, and
#      where they differ the recorded document says so. A measurement that
#      quietly replaces an estimate leaves the estimate in circulation.

TEST_NAME="verify_carry_exposure_measured"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

EXPOSURE="$REPO_ROOT/carry/exposure.json"
LEDGER="$REPO_ROOT/CARRY-LEDGER.md"
SPECS="$WORKSPACE_ROOT/codetracer-specs"

assert_file "the exposure measurement is recorded" "$EXPOSURE"
assert_file "the carry ledger is recorded" "$LEDGER"
[ -f "$EXPOSURE" ] || die "nothing to check"

# --- 1. reproducible ---------------------------------------------------------
before="$(sha256sum "$EXPOSURE" | awk '{print $1}')"
python3 "$REPO_ROOT/tools/measure_carry_exposure.py" >/dev/null 2>&1
rc=$?
after="$(sha256sum "$EXPOSURE" | awk '{print $1}')"
if [ "$rc" -eq 0 ]; then
  pass "the exposure measurement tool runs"
else
  fail "the exposure measurement tool exited $rc"
fi
assert_eq "re-measuring reproduces the recorded exposure exactly" "$before" "$after"

# --- 2. derived, not typed ---------------------------------------------------
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
entry="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["patches"][2]["entry"])' "$REPO_ROOT/carry/series.json")"
pfile="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["patches"][2]["patch"])' "$REPO_ROOT/carry/series.json")"
target="$SPECS/upstream-bugs/$entry/$pfile"
cp "$target" "$work/orig.patch"
# Append a VALID one-line new-file diff to the smallest patch, before git's own
# trailing signature. It has to stay a patch git can apply, because the
# measurement now takes its totals from a real diff between the base tree and the
# tree with every patch applied — an edit that corrupts a hunk header would make
# the tool fail rather than report a different number, which tests nothing.
python3 - "$target" <<'PY'
import sys
text = open(sys.argv[1]).read()
probe = ("diff --git a/SYNTHETIC_PROBE.txt b/SYNTHETIC_PROBE.txt\n"
         "new file mode 100644\n"
         "--- /dev/null\n"
         "+++ b/SYNTHETIC_PROBE.txt\n"
         "@@ -0,0 +1 @@\n"
         "+SYNTHETIC PROBE\n")
i = text.rfind("\n-- \n")
if i == -1:
    text = text + probe
else:
    text = text[:i + 1] + probe + text[i + 1:]
open(sys.argv[1], "w").write(text)
PY
python3 "$REPO_ROOT/tools/measure_carry_exposure.py" --json "$work/probe.json" >/dev/null 2>&1
cp "$work/orig.patch" "$target"
python3 "$REPO_ROOT/tools/measure_carry_exposure.py" >/dev/null 2>&1
restored="$(sha256sum "$EXPOSURE" | awk '{print $1}')"

probe_added="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["union_added"])' "$work/probe.json")"
real_added="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["union_added"])' "$EXPOSURE")"
assert_eq "perturbing a patch file moves the measured line count by exactly one" \
  "$((real_added + 1))" "$probe_added"
assert_eq "the probe left the recorded exposure exactly as it found it" "$before" "$restored"
assert_eq "the probe left the patch file exactly as it found it" \
  "$(sha256sum "$work/orig.patch" | awk '{print $1}')" \
  "$(sha256sum "$target" | awk '{print $1}')"

# --- 2b. cross-checked against git's own arithmetic --------------------------
# The tool parses the diff itself, so it can be wrong in ways that are invisible
# from the outside — it counted `git format-patch`'s trailing "-- " signature as a
# removed line, once per patch, until this assertion was added. Every patch file
# carries git's OWN `N files changed, M insertions(+), K deletions(-)` line, and
# the tool's per-patch row must equal it exactly.
n_stat=0
while IFS='|' read -r id entry pfile; do
  stat_line="$(grep -m1 -E '^ [0-9]+ files? changed' "$SPECS/upstream-bugs/$entry/$pfile")"
  want_files="$(printf '%s' "$stat_line" | grep -oE '^ [0-9]+' | tr -d ' ')"
  want_add="$(printf '%s' "$stat_line" | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
  want_del="$(printf '%s' "$stat_line" | grep -oE '[0-9]+ deletion' | grep -oE '[0-9]+' || echo 0)"
  got="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
r = next(x for x in d["per_patch"] if x["id"] == sys.argv[2])
print("%s %s %s" % (r["files"], r["added"], r["removed"]))' "$EXPOSURE" "$id")"
  assert_eq "$id: the measured file/insertion/deletion counts are git's own" \
    "$want_files $want_add $want_del" "$got"
  n_stat=$((n_stat + 1))
done < <(python3 -c 'import json,sys
for p in sorted(json.load(open(sys.argv[1]))["patches"], key=lambda p: p["order"]):
    print("%s|%s|%s" % (p["id"], p["entry"], p["patch"]))' "$REPO_ROOT/carry/series.json")
assert_eq "all five patches were cross-checked against git's arithmetic" "5" "$n_stat"

# --- 3. the numbers are real, and the estimate is corrected in writing -------
cmake_files="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["by_category_files"].get("cmake",0))' "$EXPOSURE")"
cmake_lines="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["by_category_lines"].get("cmake",0))' "$EXPOSURE")"
modified="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["files_modified"])' "$EXPOSURE")"
total="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["files_total"])' "$EXPOSURE")"
per_month="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["upstream_commits_per_month_touching_a_carried_hunk"])' "$EXPOSURE")"

assert_ge "the exposure covers every file the series touches" "50" "$total"
assert_ge "the conflict surface is measured, not left empty" "1" "$modified"
note "measured: $total file(s) total, $modified modified, ${cmake_files} CMake file(s) / ${cmake_lines} CMake line(s)"
note "measured: $per_month upstream commit(s) per month land on a carried hunk"

# The four numbers the ledger quotes must be the ones in the measurement. Not
# "the ledger mentions CMake" — the actual integers.
for n in "$cmake_files" "$cmake_lines" "$modified" "$total"; do
  if grep -Fq "$n" "$LEDGER"; then
    pass "the ledger quotes the measured value $n"
  else
    fail "the ledger does not carry the measured value $n"
  fi
done

# The spike's estimate is named and corrected rather than silently superseded.
assert_contains "the ledger names the spike's estimate it replaces" \
  "roughly 80 lines of CMake" "$(cat "$LEDGER")"
hy_key="barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/hybrid_execution.cpp"
sh_key="barretenberg/cpp/src/barretenberg/vm2/simulation_helper.cpp"
hy="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["line_churn_12mo_before_base"][sys.argv[2]])' "$EXPOSURE" "$hy_key")"
sh="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["line_churn_12mo_before_base"][sys.argv[2]])' "$EXPOSURE" "$sh_key")"
note "line churn over 12 months: hybrid_execution.cpp $hy, simulation_helper.cpp $sh"
if [ "$sh" -gt "$hy" ]; then
  pass "the file the spike named is measurably NOT the top rebase risk ($hy vs $sh)"
else
  fail "the spike's named file is the top rebase risk after all ($hy vs $sh) — the ledger says otherwise and must be corrected"
fi
assert_contains "the ledger records that correction" \
  "not** the top rebase risk" "$(cat "$LEDGER")"

finish
