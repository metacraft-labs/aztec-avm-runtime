#!/usr/bin/env bash
# verify_ts_simulator_configuration_named_not_inverted — M18.
#
# The deliverable: "The revived TypeScript interpreter kept behind the same interface as the
# differential counterpart, explicitly not the default. Upstream's suites labelled
# `(TS Simulator)` actually run the differential harness, and `useCppSimulator: false` selects it
# — an inversion that becomes a first-class named configuration in our tree rather than an
# environment variable."
#
# TWO CLAIMS, AND THE FIRST IS ABOUT UPSTREAM. It is re-derived here from the fork at the anchor
# rather than carried forward from M2's write-up, because M2's headline number was overstated by
# an order of magnitude BY BELIEVING THIS LABEL, and a check that quoted the write-up would be
# quoting the thing that was wrong. The two sites that decide it:
#
#   yarn-project/simulator/src/public/fixtures/public_tx_simulation_tester.ts
#     useCppSimulator ? MeasuredCppPublicTxSimulator : MeasuredCppVsTsPublicTxSimulator
#   yarn-project/simulator/src/public/public_processor/apps_tests/deployments.test.ts
#     useCppSimulator ? CppPublicTxSimulator : CppVsTsPublicTxSimulator
#
# So `false` selects the DIFFERENTIAL pair and the suites labelled `(TS Simulator)` are those.
#
# THE SECOND CLAIM IS ABOUT OUR TREE and it is the one with a shape: "a first-class named
# configuration rather than an environment variable" is only worth asserting if the check can
# tell the difference. It does, three ways: the configurations are values with fields that say
# what they select; NO module under orchestration/src reads the environment to decide; and the
# translation from upstream's boolean is a FUNCTION, exercised in both directions, so a caller
# who gets the inversion backwards gets a different configuration rather than a different
# sentence.
#
# Run: just verify-ts-config

TEST_NAME="verify_ts_simulator_configuration_named_not_inverted"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m18_orchestration.sh"

m18_require_anchor

mkdir -p "$M18_WORK"
SCRATCH="$(mktemp -d "$M18_WORK/tsconfig.XXXXXX")" || die "no scratch under $M18_WORK"
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.probe_"*.ts' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — the inversion, re-derived at the anchor
# ---------------------------------------------------------------------------

TESTER="$SCRATCH/public_tx_simulation_tester.ts"
m18_anchor_file yarn-project/simulator/src/public/fixtures/public_tx_simulation_tester.ts > "$TESTER"
DEPLOY="$SCRATCH/deployments.test.ts"
m18_anchor_file yarn-project/simulator/src/public/public_processor/apps_tests/deployments.test.ts > "$DEPLOY"

assert_ge "the fixture was read from the anchor and is not empty" 50 "$(wc -l < "$TESTER")"
assert_ge "and so was the apps test" 50 "$(wc -l < "$DEPLOY")"

# The ternary, both arms, from the file. Read as text and then asserted per arm, because
# "contains CppVsTs" is also true of a file that merely imports it.
TERNARY="$(grep -n -A3 'useCppSimulator$\|useCppSimulator *$\|= useCppSimulator' "$TESTER" \
  | grep -E 'MeasuredCppPublicTxSimulator|MeasuredCppVsTsPublicTxSimulator' || true)"
printf '%s\n' "$TERNARY" | sed 's/^/      /'
assert_ge "the fixture selects on useCppSimulator" 2 \
  "$(printf '%s\n' "$TERNARY" | grep -c . || true)"
assert_eq "the TRUE arm is the pure C++ simulator" "1" \
  "$(printf '%s\n' "$TERNARY" | grep -c '? *(.*MeasuredCppPublicTxSimulator' || true)"
assert_eq "and the FALSE arm is the DIFFERENTIAL one" "1" \
  "$(printf '%s\n' "$TERNARY" | grep -c ': *(.*MeasuredCppVsTsPublicTxSimulator' || true)"

# The second site, which says it in upstream's own words.
assert_contains "upstream's own comment says the TS mode compares TS against C++" \
  "TS mode: use CppVsTs to compare TS and C++ results" "$(cat "$DEPLOY")"
assert_contains "and that the C++ mode uses only C++" \
  "C++ mode: use only C++" "$(cat "$DEPLOY")"

# The LABEL, and the row it sits on. This is the whole defect: `useCppSimulator: false` and
# `simulatorName: 'TS Simulator'` are on adjacent lines of one object literal.
LABEL_ROW="$(grep -A1 "useCppSimulator: false" "$DEPLOY" | tr -d ' ' | tr '\n' ' ')"
note "the row upstream labels: $LABEL_ROW"
assert_contains "the row carrying useCppSimulator: false is labelled 'TS Simulator'" \
  "TSSimulator" "$LABEL_ROW"
LABEL_ROW_TRUE="$(grep -A1 "useCppSimulator: true" "$DEPLOY" | tr -d ' ' | tr '\n' ' ')"
assert_contains "and the one carrying true is labelled 'Cpp Simulator'" \
  "CppSimulator" "$LABEL_ROW_TRUE"

# The differential class the false arm names really is a comparator, not a renamed TS simulator:
# it runs one side inside a checkpoint and reverts it before running the other.
CVT="$SCRATCH/cpp_vs_ts.ts"
m18_anchor_file yarn-project/simulator/src/public/public_tx_simulator/cpp_vs_ts_public_tx_simulator.ts > "$CVT"
assert_contains "CppVsTsPublicTxSimulator runs one side inside a merkle checkpoint" \
  "createCheckpoint()" "$(cat "$CVT")"
assert_contains "and reverts it before running the other" "revertCheckpoint()" "$(cat "$CVT")"
assert_contains "and it reaches the native addon, so the '(TS Simulator)' suites are not TS-only" \
  "@aztec/native" "$(cat "$CVT")"

# There is no pure-TypeScript configuration upstream at all — which is why our tree has a NAME
# for one and upstream does not. Asserted as a count over every describe.each table in the
# apps_tests directories rather than by reading one.
m18_anchor_paths yarn-project/simulator/src/public > "$SCRATCH/sim_paths.txt"
N_TABLES=0
N_TS_ROWS=0
N_TS_ROWS_LIVE=0
while IFS= read -r p; do
  case "$p" in *apps_tests/*.test.ts) ;; *) continue ;; esac
  body="$(m18_anchor_file "$p" 2>/dev/null || true)"
  str_has_sub "$body" "useCppSimulator" || continue
  N_TABLES=$((N_TABLES + 1))
  N_TS_ROWS=$((N_TS_ROWS + $(printf '%s\n' "$body" | grep -c "useCppSimulator: false" || true)))
  # AND THE SAME COUNT WITH COMMENTS STRIPPED. This file's own third defect was a grep that
  # counted a COMMENTED line as a `process.env` read; M18's review found the mirror image of it
  # sixty lines up — a raw grep here reported twelve `useCppSimulator: false` rows, two of which
  # are commented out (`avm_minimal.test.ts` and `opcode_spam.test.ts`, the latter labelled
  # 'CppVsTs' rather than 'TS Simulator', which is upstream naming it correctly in the one place
  # it was disabled). Ten rows are live. Both numbers are carried, because "how many rows carry
  # the misleading label" and "how many suites actually run" are different questions.
  N_TS_ROWS_LIVE=$((N_TS_ROWS_LIVE + $(printf '%s\n' "$body" \
    | sed 's://.*::' | grep -c "useCppSimulator: false" || true)))
done < "$SCRATCH/sim_paths.txt"
note "$N_TABLES apps-test files select on useCppSimulator; $N_TS_ROWS rows set it to false ($N_TS_ROWS_LIVE live)"
assert_ge "the enumeration found the tables rather than an empty directory" 3 "$N_TABLES"
assert_ge "and every 'TS Simulator' row in them is a differential row" 3 "$N_TS_ROWS"
assert_eq "eleven apps-test files select on it, and twelve rows set it false" "11|12" \
  "$N_TABLES|$N_TS_ROWS"
assert_eq "two of those twelve are commented out, so ten suites actually run under the label" \
  "10" "$N_TS_ROWS_LIVE"
assert_ge "and the comment stripper did not simply delete everything" 1 "$N_TS_ROWS_LIVE"

# ---------------------------------------------------------------------------
# PART 2 — our tree: a named configuration, and not an environment variable
# ---------------------------------------------------------------------------

# The translation, in both directions, read out of the module.
BOTH="$(node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const f = m.fromUpstreamUseCppSimulator(false);
  const t = m.fromUpstreamUseCppSimulator(true);
  console.log([f.name, m.isDifferential(f), (f.compares ?? []).join('+'), f.upstreamSuiteLabel,
               t.name, m.isDifferential(t), t.upstreamSuiteLabel].join('|'));
}).catch(e => console.log('FAILED|' + e.message))")"
note "translation: $BOTH"
assert_eq "useCppSimulator false maps to a NAMED differential configuration that says what it compares" \
  "differential-typescript-vs-native-cpp|true|typescript-interpreter+native-cpp-avm|(TS Simulator)|native-cpp-avm|false|(Cpp Simulator)" \
  "$BOTH"

# The interpreter alone is a configuration in our tree, and it is explicitly not the default.
SOLO="$(node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const c = m.TYPESCRIPT_INTERPRETER;
  console.log([c.name, c.implementation, c.isDefault, m.isDifferential(c),
               m.defaultConfiguration().name, m.defaultConfiguration().isDefault].join('|'));
}).catch(e => console.log('FAILED|' + e.message))")"
assert_eq "the TypeScript interpreter has its own name, is not differential, and is not the default" \
  "typescript-interpreter|typescript-interpreter|false|false|wasm-avm|true" "$SOLO"

# EXACTLY ONE configuration is the default. "Explicitly not the default" is a claim about the
# whole set, and a set with two defaults satisfies "X is not the default" for some X.
N_DEFAULT="$(node -e "
import('$ORCH_SRC/index.ts').then(m =>
  console.log(m.AVM_CONFIGURATIONS.filter(c => c.isDefault).length))
  .catch(() => console.log('FAILED'))")"
assert_eq "exactly one configuration in the set is the default" "1" "$N_DEFAULT"

# Every configuration is reachable by its own name, and the names are distinct — otherwise
# "a first-class named configuration" is a field nobody can select with.
NAMES="$(node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const names = m.AVM_CONFIGURATIONS.map(c => c.name);
  const roundtrip = names.every(n => m.configurationByName(n)?.name === n);
  console.log([names.length, new Set(names).size, roundtrip,
               m.configurationByName('no-such-configuration') === undefined].join('|'));
}).catch(() => console.log('FAILED'))")"
assert_eq "five distinctly-named configurations, each retrievable by name, and an unknown name is undefined" \
  "5|5|true|true" "$NAMES"

# `isDifferential` is a predicate over the DATA and not over the name. The negative case is a
# configuration that claims the differential implementation and names no pair: it must answer
# false, because a coverage count built on this predicate is exactly the number M2 overstated.
NEG="$(node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const fake = { name: 'looks-differential', implementation: 'differential', isDefault: false,
                 upstreamUseCppSimulator: null, upstreamSuiteLabel: null, why: '' };
  const named = { name: 'x', implementation: 'wasm-avm', isDefault: false,
                  compares: ['wasm-avm', 'native-cpp-avm'], upstreamUseCppSimulator: null,
                  upstreamSuiteLabel: null, why: '' };
  console.log([m.isDifferential(fake), m.isDifferential(named)].join('|'));
}).catch(() => console.log('FAILED'))")"
assert_eq "a configuration that claims to be differential but compares nothing is not counted, and one that names a pair without being differential is not either" \
  "false|false" "$NEG"

# NOT AN ENVIRONMENT VARIABLE. Counted over the shipped sources, with a control that the counter
# can find one — because "zero occurrences" is also what a grep with a broken pattern reports.
# COMMENTS ARE NOT CODE, and this counter learned that by going red on a sentence explaining
# why the default is not read out of `process.env`. A plain grep would have made this assertion
# unsatisfiable for any file that DISCUSSED the rule — which is the same defect as an assertion
# that can only pass, wearing the other hat.
env_hits() { # -> count of process.env occurrences in CODE under $ORCH_SRC
  python3 - "$ORCH_SRC" <<'PYENV'
import re, sys, pathlib
n = 0
for f in sorted(pathlib.Path(sys.argv[1]).rglob("*.ts")):
    src = f.read_text()
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"(?m)^\s*//.*$", "", src)
    src = re.sub(r"(?<![:'\"])//[^\n]*", "", src)
    n += len(re.findall(r"process\s*\.\s*env", src))
print(n)
PYENV
}
ENV_HITS="$(env_hits)"
assert_eq "no module in the shipped orchestration reads the environment" "0" "$ENV_HITS"
printf 'export const x = process.env.AVM_IMPLEMENTATION ?? "";\n' > "$ORCH_SRC/.probe_env.ts"
PROBE_HITS="$(env_hits)"
rm -f "$ORCH_SRC/.probe_env.ts"
assert_eq "and the counter finds one when it is there" "1" "$PROBE_HITS"
# …and it is not simply blind to comments in a way that would also hide code: a commented-out
# read must NOT count, and the same file with the comment marker removed must.
printf '// const x = process.env.AVM_IMPLEMENTATION;\n' > "$ORCH_SRC/.probe_env.ts"
COMMENTED="$(env_hits)"
printf 'export const x = process.env.AVM_IMPLEMENTATION ?? "";\n' > "$ORCH_SRC/.probe_env.ts"
UNCOMMENTED="$(env_hits)"
rm -f "$ORCH_SRC/.probe_env.ts"
assert_eq "a commented-out read does not count" "0" "$COMMENTED"
assert_eq "and the same line uncommented does" "1" "$UNCOMMENTED"
assert_eq "the probe left nothing behind" "0" \
  "$(find "$ORCH_SRC" -name '.probe_*' | grep -c . || true)"

# The upstream label is RECORDED against each configuration rather than used as its name — which
# is the difference between fixing the inversion and re-spelling it.
NAMED_NOT_LABELLED="$(node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const bad = m.AVM_CONFIGURATIONS.filter(c => c.upstreamSuiteLabel !== null &&
    c.name.toLowerCase().includes(c.upstreamSuiteLabel.toLowerCase().replace(/[()\\s]/g, '-')));
  const labelled = m.AVM_CONFIGURATIONS.filter(c => c.upstreamSuiteLabel !== null).length;
  console.log([bad.length, labelled].join('|'));
}).catch(() => console.log('FAILED'))")"
assert_eq "the two upstream labels are recorded, and neither is used as a configuration's name" \
  "0|2" "$NAMED_NOT_LABELLED"

finish
