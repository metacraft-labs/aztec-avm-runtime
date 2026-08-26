#!/usr/bin/env bash
# e2e_differential_wasm_vs_native_cpp
#
# M19's headline check: the wasm AVM and the native C++ AVM are compared, per transaction, from a
# proved-identical pre-transaction state, on every field the milestone names — and the comparison
# is demonstrably capable of failing on each of them separately.
#
# WHAT IT DOES NOT CLAIM, stated first because the result is not the one the deliverable's wording
# expects. The two arms DO NOT agree on metered L2 gas, and they cannot: `avm.wasm` is built from
# anchor `cpp` and the NAPI oracle is the npm `deletion_era` line, two months and 276 changed
# `vm2/` files earlier. That is DRIFT.md D15, it is a fact about the ORACLE rather than about the
# subject, and it is enforced here as a MEASURED ledger of exact values rather than waved away:
# every disagreement must match a recorded signature, and a disagreement on any other field or with
# any other value fails.
#
# THE CONTROLS ARE THE POINT. ELEVEN fault injections — one per compared field, plus the pre-state
# proof, the input encoding and the TypeScript arm's presence — each run as its own arm invocation.
# Every one must turn the suite RED. A differential never observed to fail is indistinguishable from
# one that cannot fail, and this campaign has shipped twenty-four assertions that could not.
#
# What this loop asserts is that the arm goes red and that at least one TEST failed. It does NOT
# assert the injection's name appears in the message; an earlier version of this comment said it
# did. Each injection perturbs a different thing, so redness for an unrelated reason is unlikely —
# but unlikely is not asserted, and the comment now says what the code does.
#
# Run: just verify-three-way

TEST_NAME="e2e_differential_wasm_vs_native_cpp"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_work_dir "$M19_WORK" 1
m19_require_module
m19_require_packages
note "module $AVM_WASM_PATH"
note "sha256 $M19_MODULE_SHA"

# ---- 1. the module is the one this arm needs -------------------------------
exports="$(m19_module_exports)"
assert_ge "the module declares a plausible number of exports" 20 "$(printf '%s\n' "$exports" | wc -l)"
missing=0
for sym in $M19_REQUIRED_EXPORTS; do
  str_has_line "$exports" "$sym" || { fail "the module exports $sym"; missing=$((missing + 1)); }
done
[ "$missing" -eq 0 ] && pass "the module exports all $(printf '%s\n' $M19_REQUIRED_EXPORTS | wc -l) entry points the three-way arm calls"
# The negative half: a name that is NOT an export must not be found, or the loop above would pass
# for any module at all.
#
# COMPUTED INTO A VARIABLE FIRST, and the reason is a defect this very line shipped with. Written
# as `assert_false "..." printf '%s\n' "$exports" | grep -qx ...`, the pipe binds to `assert_false`
# rather than to `printf`: the helper ran `printf` (which succeeds), its own output went to `grep`,
# and its failure counter was incremented inside a SUBSHELL and lost. The check printed FAIL and
# reported 0 failures in the same run. An assertion whose failure cannot reach the summary is the
# twenty-four-times-over defect this campaign is named for, and it took a full-suite run to see it.
absent_hits="$(printf '%s\n' "$exports" | grep -cx 'avm_this_export_does_not_exist' || true)"
assert_eq "a name the module does not export is not found" "0" "$absent_hits"
present_hits="$(printf '%s\n' "$exports" | grep -cx 'avm_simulate' || true)"
assert_eq "while the same lookup does find one it does export, so the absence discriminates" "1" \
  "$present_hits"

# ---- 2. the arm runs clean -------------------------------------------------
clean_log="$M19_WORK/clean.log"
m19_run_arm "$clean_log"
rc_clean=$?
assert_eq "the three-way arm exits 0" "0" "$rc_clean"
[ "$rc_clean" -eq 0 ] || sed -n '1,60p' "$clean_log" >&2

expected_tests="$(m19_json "$M19_COUNTS" 'd["testCounts"]["totalPassed"]')"
assert_eq "every test in the arm passed, and the number is the recorded one" \
  "$expected_tests" "$(m19_tests_passed "$clean_log")"
assert_eq "no test in the arm failed" "" "$(m19_tests_failed "$clean_log")"
assert_eq "the arm ran exactly the recorded number of tests" \
  "$expected_tests" "$(m19_tests_total "$clean_log")"

# ---- 3. the measured counts, re-measured ------------------------------------
counts_dir="$M19_WORK/counters"
rm -rf "$counts_dir"; mkdir -p "$counts_dir"
m19_run_arm "$M19_WORK/counted.log" "DIFFSIM_COUNTERS_DIR=$counts_dir"
assert_eq "the counted run also exits 0" "0" "$?"

measured="$(python3 - "$counts_dir" <<'PY'
import json, pathlib, sys
recs = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.jsonl")):
    recs += [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
wasm = [r for r in recs if any(p.startswith("wasm-avm:") for p in r.get("pairs", []))]
print(len(wasm), sum(len(r.get("pairs", [])) for r in recs), sum(1 for r in wasm if r.get("preStateIdentical")))
PY
)"
set -- $measured
assert_eq "the transactions compared match the recorded count" \
  "$(m19_json "$M19_COUNTS" 'd["transactionsCompared"]')" "$1"
assert_eq "the implementation-pair comparisons match the recorded count" \
  "$(m19_json "$M19_COUNTS" 'd["pairsCompared"]')" "$2"
assert_eq "the transactions that began from byte-identical trees match the recorded count" \
  "$(m19_json "$M19_COUNTS" 'd["preStatesProvedIdentical"]')" "$3"
assert_ge "the arm compared a meaningful number of transactions" 25 "$1"
assert_ge "at least one transaction began from byte-identical trees, which is the pre-state proof" 1 "$3"

# ---- 4. what the ledger may and may not excuse -----------------------------
# The fields the swap has to preserve. If any of these ever appears in the ledger it is a finding
# about the AVM, not a housekeeping edit, and this check says so by name.
for field in revertCode gasUsed.teardownGas appLogicReturnValues revertReason publicInputs; do
  assert_eq "no recorded divergence excuses $field" "0" \
    "$(m19_json "$M19_LEDGER" "sum(1 for e in d['entries'] if e['field'] == '$field')")"
done
assert_ge "the ledger accounts for its entries by exact value, not by field" 50 \
  "$(m19_json "$M19_LEDGER" 'sum(len(e.get("signatures", [])) for e in d["entries"])')"
assert_eq "every ledger entry names a DRIFT.md entry" "0" \
  "$(m19_json "$M19_LEDGER" 'sum(1 for e in d["entries"] if not e.get("drift") or e["drift"] == "UNCLASSIFIED")')"
assert_eq "every ledger entry says what a reader must not conclude from it" "0" \
  "$(m19_json "$M19_LEDGER" 'sum(1 for e in d["entries"] if len(e.get("note", "")) < 40)')"
for id in $(m19_json "$M19_LEDGER" '" ".join(sorted({e["drift"] for e in d["entries"]}))'); do
  assert_true "DRIFT.md has an entry $id" grep -q "^## $id — " "$REPO_ROOT/DRIFT.md"
done

# ---- 5. THE CONTROLS -------------------------------------------------------
injections="$(python3 -c "
import re,sys
src = open('$DIFFSIM_DIR/src/public/public_tx_simulator/differential/fault_injection.ts').read()
block = re.search(r'export const INJECTIONS = \[(.*?)\] as const;', src, re.S).group(1)
print(' '.join(re.findall(r\"'([a-zA-Z]+)'\", block)))")"
assert_ge "the arm declares a control per compared field and then some" 10 "$(printf '%s\n' $injections | wc -l)"

for inj in $injections; do
  log="$M19_WORK/inject-$inj.log"
  m19_run_arm "$log" "M19_INJECT_DIVERGENCE=$inj"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "injecting $inj makes the three-way arm fail"
    continue
  fi
  failed="$(m19_tests_failed "$log")"
  if [ -z "$failed" ] || [ "$failed" -lt 1 ]; then
    fail "injecting $inj fails at least one test (exit $rc but no failing test)"
    continue
  fi
  pass "injecting $inj makes the three-way arm fail [$failed test(s)]"
done

# And the negative half of the controls: with no injection the same command is green, which is
# assertion 2 above — re-stated here as the pairing rather than left implicit, because a control
# set with no clean run beside it proves only that the suite can fail.
assert_eq "and with no injection the same command is green" "0" "$rc_clean"

finish
