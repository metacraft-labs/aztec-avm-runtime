#!/usr/bin/env bash
# e2e_differential_wasm_vs_ts_interpreter
#
# The second pair: the wasm AVM against the revived TypeScript interpreter, so the TS engine stays
# useful as a reference implementation and a second opinion rather than as decoration.
#
# WHY THIS IS NOT REDUNDANT WITH THE NATIVE PAIR. It looks derivable — if wasm agrees with C++ and
# C++ agrees with TS then wasm agrees with TS — and it is not, for two reasons that this check
# asserts rather than argues. First, the arms do NOT all agree (DRIFT.md D15), so transitivity has
# nothing to stand on. Second, and structurally: a comparison that is not made is a comparison
# whose failure is never seen, and the TS arm has fields the C++ arms do not populate at all
# (D16). The pair is therefore compared explicitly, on every transaction, and counted.
#
# THE CONTROL THAT MATTERS HERE is `tsResultMissing`. Upstream's own harness treats an absent TS
# result as a reason to continue — it logs a warning and runs C++ anyway. If the three-way arm
# inherited that, the wasm-versus-TypeScript comparison would be SKIPPED rather than made whenever
# the interpreter threw, and the suite would stay green. The injection proves the refusal is real.
#
# Run: just verify-three-way

TEST_NAME="e2e_differential_wasm_vs_ts_interpreter"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_work_dir "$M19_WORK" 1
m19_require_module
m19_require_packages

PAIR='wasm-avm:typescript-interpreter'

# ---- 1. the pair is compared on every transaction, measured ----------------
counts_dir="$M19_WORK/ts-counters"
rm -rf "$counts_dir"; mkdir -p "$counts_dir"
m19_run_arm "$M19_WORK/ts-clean.log" "DIFFSIM_COUNTERS_DIR=$counts_dir"
rc_clean=$?
assert_eq "the three-way arm exits 0" "0" "$rc_clean"
[ "$rc_clean" -eq 0 ] || sed -n '1,40p' "$M19_WORK/ts-clean.log" >&2

read -r txs with_ts without_ts <<EOF
$(python3 - "$counts_dir" "$PAIR" <<'PY'
import json, pathlib, sys
recs = []
for f in sorted(pathlib.Path(sys.argv[1]).glob("*.jsonl")):
    recs += [json.loads(l) for l in f.read_text().splitlines() if l.strip()]
wasm = [r for r in recs if any(p.startswith("wasm-avm:") for p in r.get("pairs", []))]
with_ts = [r for r in wasm if sys.argv[2] in r.get("pairs", [])]
print(len(wasm), len(with_ts), len(wasm) - len(with_ts))
PY
)
EOF
assert_eq "every three-way transaction compared the wasm arm against the TypeScript interpreter" \
  "$txs" "$with_ts"
assert_eq "no transaction skipped the TypeScript pair" "0" "$without_ts"
assert_eq "and the number of transactions is the recorded one" \
  "$(m19_json "$M19_COUNTS" 'd["transactionsCompared"]')" "$txs"
assert_ge "the pair was compared on a meaningful number of transactions" 25 "$with_ts"

# ---- 2. what the pair may and may not disagree on ---------------------------
# The TypeScript interpreter is a reference implementation, so the fields that define AVM semantics
# must agree with it exactly. Only gas and what follows from gas may be excused, and only by value.
for field in revertCode gasUsed.teardownGas appLogicReturnValues revertReason publicInputs; do
  assert_eq "no recorded divergence excuses $PAIR $field" "0" \
    "$(m19_json "$M19_LEDGER" "sum(1 for e in d['entries'] if e['pair'] == '$PAIR' and e['field'] == '$field')")"
done
assert_ge "the pair has recorded divergences, so this is not an empty comparison" 1 \
  "$(m19_json "$M19_LEDGER" "sum(1 for e in d['entries'] if e['pair'] == '$PAIR')")"
assert_eq "every recorded divergence of this pair is accounted for by exact value" "0" \
  "$(m19_json "$M19_LEDGER" "sum(1 for e in d['entries'] if e['pair'] == '$PAIR' and not e.get('signatures'))")"

# ---- 3. THE CONTROLS -------------------------------------------------------
# `tsResultMissing` is this check's own; the other two are fields the TS pair compares, run here so
# that a change which disabled the TS pair alone would be caught by THIS check rather than only by
# its sibling.
for inj in tsResultMissing totalGas publicInputsPresence; do
  log="$M19_WORK/ts-inject-$inj.log"
  m19_run_arm "$log" "M19_INJECT_DIVERGENCE=$inj"
  rc=$?
  failed="$(m19_tests_failed "$log")"
  if [ "$rc" -ne 0 ] && [ -n "$failed" ] && [ "$failed" -ge 1 ]; then
    pass "injecting $inj makes the arm fail [$failed test(s)]"
  else
    fail "injecting $inj makes the arm fail (exit $rc, failing tests '${failed:-none}')"
  fi
done
assert_contains "and dropping the TypeScript result is REFUSED rather than skipped" \
  "the TypeScript interpreter produced no result" "$(cat "$M19_WORK/ts-inject-tsResultMissing.log")"
assert_eq "and with no injection the same command is green" "0" "$rc_clean"

finish
