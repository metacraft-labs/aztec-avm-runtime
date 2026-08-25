#!/usr/bin/env bash
# test_public_processor_never_defaults_to_cpp — M18.
#
# DD-9, as a property of the repository rather than an intention: "No public export allows
# reaching the C++-over-IPC simulator path; the facade owns the subclass and the upstream
# constructor is not exported."
#
# THREE FACTS ABOUT UPSTREAM ARE RE-DERIVED FIRST, because DD-9 is a claim about what upstream
# does and a check that only looked at our own file would be asserting our intentions back at
# ourselves. Re-deriving them also corrects the deliverable's wording, which compresses two
# different seams into one name:
#
#   1. `PublicProcessorFactory.createPublicTxSimulator` IS `protected` and DOES hard-default to
#      the C++ path — there is no flag on it at all. It is an override seam WITH NO OVERRIDES
#      anywhere in the tree, so "Aztec built it to run two AVM implementations side by side" is
#      not what its history shows; that seam is `PublicTxSimulationTester`'s `simulatorFactory`.
#      Using a `protected` method as an override point is still using it as intended.
#   2. `createPublicTxSimulatorForBlockBuilding` is a FREE exported function and is the
#      production selection point. It hard-defaults to the C++ path too.
#   3. `PublicProcessor`'s constructor takes the SIMULATOR as its fourth positional argument,
#      typed to the interface. That is why DD-9 is satisfiable by not exporting a factory rather
#      than by subclassing anything.
#
# THE EXPORT SET IS READ OUT OF THE MODULE, NOT GREPPED OUT OF THE SOURCE. A grep over
# `export {` answers a question about text; `Object.keys(await import(...))` answers the question
# DD-9 asks, which is what a consumer can reach. The campaign's most recent two defects were
# printed literals standing in for measurements, and a source grep is the same family.
#
# Run: just verify-no-cpp-default

TEST_NAME="test_public_processor_never_defaults_to_cpp"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m18_orchestration.sh"

m18_require_anchor
m18_require_packages

mkdir -p "$M18_WORK"
SCRATCH="$(mktemp -d "$M18_WORK/ddnine.XXXXXX")" || die "no scratch under $M18_WORK"
trap 'rm -rf "$SCRATCH"; rm -f "$ORCH_SRC/.probe_"*.ts' EXIT INT TERM HUP

# ---------------------------------------------------------------------------
# PART 1 — upstream, re-derived at the anchor
# ---------------------------------------------------------------------------

PP="$SCRATCH/public_processor.ts"
m18_anchor_file yarn-project/simulator/src/public/public_processor/public_processor.ts > "$PP"
FACT="$SCRATCH/factories.ts"
m18_anchor_file yarn-project/simulator/src/public/public_tx_simulator/factories.ts > "$FACT"

assert_ge "public_processor.ts was read from the anchor and is not empty" 100 "$(wc -l < "$PP")"
assert_contains "createPublicTxSimulator is protected" \
  "protected createPublicTxSimulator(" "$(cat "$PP")"
assert_contains "and it constructs the C++ simulator unconditionally" \
  "new TelemetryCppPublicTxSimulator(" "$(cat "$PP")"
# "hard-defaults" means there is no branch. Asserted as a count of zero over the method's own
# body rather than by reading it: a flag added later must turn this red.
# The SIGNATURE is excluded and the BODY is counted. `config?: Partial<…>` is an optional
# parameter, and the first draft of this assertion counted its `?` as a conditional and reported
# a branch in a method that has none — a check that would have gone green the day someone added
# a real one, because the count was already 1.
PP_METHOD="$(awk '/protected createPublicTxSimulator\(/,/^  \}/' "$PP" \
  | awk 'body { print } /\): PublicTxSimulatorInterface \{/ { body = 1 }')"
assert_ge "the method body was extracted and is not empty" 3 \
  "$(printf '%s\n' "$PP_METHOD" | grep -c . || true)"
assert_eq "the method's body contains no conditional at all, so 'hard-defaults' is exact" "0" \
  "$(printf '%s\n' "$PP_METHOD" | grep -cE '\bif\b|\?|&&|\|\|' || true)"
# …and the control for that count: the free factory DOES have exactly one branch, so a zero here
# is a measurement and not a pattern that never matches.
FACT_FN="$(awk '/export function createPublicTxSimulatorForBlockBuilding/,/^\}/' "$FACT")"
assert_ge "the free factory, by contrast, does have a branch — so the count above can be non-zero" \
  1 "$(printf '%s\n' "$FACT_FN" | grep -cE '\bif\b|\?' || true)"
assert_contains "and the free factory hard-defaults to the C++ path too" \
  "TelemetryCppPublicTxSimulator" "$FACT_FN"

# Nothing overrides the protected seam anywhere in the tree, which is the part of the
# deliverable's justification that does not survive.
N_OVERRIDES="$(git -C "$FORK_ROOT" grep -cE 'extends PublicProcessorFactory\b' "$M18_TS_ANCHOR" -- 2>/dev/null | grep -c . || true)"
assert_eq "no class in the whole fork extends PublicProcessorFactory, so we would be the seam's first user" \
  "0" "$N_OVERRIDES"

# The injection point DD-9 relies on.
PP_CTOR="$(awk '/^  constructor\(/,/^  \) \{/' "$PP")"
assert_contains "PublicProcessor takes the simulator by INTERFACE, as a constructor argument" \
  "publicTxSimulator: PublicTxSimulatorInterface" "$PP_CTOR"

# ---------------------------------------------------------------------------
# PART 2 — our export surface, read out of the module
# ---------------------------------------------------------------------------

read_exports() { # <entry> -> newline-separated export names
  node -e "
import('$1').then(m => console.log(Object.keys(m).sort().join('\n')))
            .catch(e => { console.error(e.message); process.exit(1); })"
}

EXPORTS="$(read_exports "$ORCH_SRC/index.ts")" \
  || die "the orchestration package's entry point does not import"
printf '%s\n' "$EXPORTS" | sed 's/^/      export: /'
N_EXPORTS="$(printf '%s\n' "$EXPORTS" | grep -c . || true)"
assert_ge "the entry point exports something, so the absences below are over a real set" 5 "$N_EXPORTS"

# Word-boundary matching on names read out of the module. A substring needle would let
# `WasmAvmPublicTxSimulator` satisfy a search for `PublicTxSimulator` and the check would go
# green for the opposite of the reason it means.
FORBIDDEN_EXPORTS="PublicProcessor PublicProcessorFactory createPublicTxSimulator
createPublicTxSimulatorForBlockBuilding CppPublicTxSimulator MeasuredCppPublicTxSimulator
TelemetryCppPublicTxSimulator DumpingCppPublicTxSimulator CppVsTsPublicTxSimulator
avmSimulate NativeWorldStateService"
for name in $FORBIDDEN_EXPORTS; do
  assert_eq "no public export is named $name" "0" \
    "$(printf '%s\n' "$EXPORTS" | grep -cx "$name" || true)"
done

# The exports that MUST be there — because "exports nothing forbidden" is also true of a module
# that exports nothing.
for name in WasmAvmPublicTxSimulator ForkCheckpoint defaultConfiguration reachesNativeAddon; do
  assert_eq "the entry point does export $name" "1" \
    "$(printf '%s\n' "$EXPORTS" | grep -cx "$name" || true)"
done

# ---------------------------------------------------------------------------
# PART 3 — the export-name test can fail
#
# A probe re-exports a forbidden NAME from the entry point and the same reader must catch it.
# Without this, "no export named CppPublicTxSimulator" is indistinguishable from a reader that
# never matched anything.
# ---------------------------------------------------------------------------

saved="$SCRATCH/index.ts.saved"
cp "$ORCH_SRC/index.ts" "$saved"
printf 'export class CppPublicTxSimulator {}\n' > "$ORCH_SRC/.probe_cpp.ts"
printf "\nexport { CppPublicTxSimulator } from './.probe_cpp.ts';\n" >> "$ORCH_SRC/index.ts"
PROBED="$(read_exports "$ORCH_SRC/index.ts" || true)"
cp "$saved" "$ORCH_SRC/index.ts"
rm -f "$ORCH_SRC/.probe_cpp.ts"
assert_eq "negative case: the reader DOES see a forbidden name when one is exported" "1" \
  "$(printf '%s\n' "$PROBED" | grep -cx "CppPublicTxSimulator" || true)"
# Restoration, compared against the copy this check made rather than against `git status`.
# THE GIT VERSION WAS VACUOUS AND M18's REVIEW FOUND IT: while `orchestration/` was untracked,
# `git status --porcelain -- orchestration/src/index.ts` printed nothing whatever the probe had
# done to the file, so the assertion reported 0 either way. `cmp` answers the question that was
# meant, and answers it the same before and after the directory is committed.
if cmp -s "$saved" "$ORCH_SRC/index.ts"; then
  pass "and the probe left index.ts byte-for-byte as it found it"
else
  fail "the probe did NOT restore index.ts; it differs from the copy taken before the probe"
fi
assert_eq "…and the comparison can tell them apart, so the restoration check is not vacuous" "1" \
  "$(cmp -s "$saved" "$ORCH_SRC/fork_checkpoint.ts" && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# PART 4 — reachability by ARGUMENT, not only by import
#
# An export surface says what a consumer can reach by importing. It says nothing about a
# consumer who imports the one simulator we do export and hands it a configuration naming the
# native AVM. That is a second way to reach the forbidden path and it fails differently, so it
# is checked separately — and in both directions, because a refusal that refused everything
# would pass the first half.
# ---------------------------------------------------------------------------

refusal() { # <configuration-export-name> -> "<kind>|<name>" or "ACCEPTED"
  node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const boundary = { simulate: () => ({ revertCode: 0, result: {} }), moduleCalls: 0 };
  try {
    const s = new m.WasmAvmPublicTxSimulator(boundary, { contractDb: 1, merkleDb: 2 }, {},
      () => new Uint8Array(), (r) => r, { configuration: m['$1'] });
    console.log('ACCEPTED|' + s.configuration.name);
  } catch (e) {
    console.log((e.kind ?? e.name) + '|' + (e.configurationName ?? ''));
  }
}).catch(e => console.log('IMPORT-FAILED|' + e.message))"
}

assert_eq "a configuration that reaches the native AVM is refused, by name" \
  "native-avm-path-refused|native-cpp-avm" "$(refusal NATIVE_CPP_AVM)"
assert_eq "so is the differential pair that contains it" \
  "native-avm-path-refused|differential-typescript-vs-native-cpp" \
  "$(refusal DIFFERENTIAL_TS_VS_NATIVE_CPP)"
assert_eq "and so is the wasm-versus-native pair, which also reaches it" \
  "native-avm-path-refused|differential-wasm-vs-native-cpp" \
  "$(refusal DIFFERENTIAL_WASM_VS_NATIVE_CPP)"
# The other direction. A refusal that refused everything would satisfy the three above and would
# make the runtime unusable, which is a different bug with the same green.
assert_eq "the shipped configuration is ACCEPTED" "ACCEPTED|wasm-avm" "$(refusal WASM_AVM)"
assert_eq "and so is the TypeScript interpreter alone, which reaches no native addon" \
  "ACCEPTED|typescript-interpreter" "$(refusal TYPESCRIPT_INTERPRETER)"

# The default, when nothing is named at all — DD-9's actual subject.
DEFAULTED="$(node -e "
import('$ORCH_SRC/index.ts').then(m => {
  const boundary = { simulate: () => ({ revertCode: 0, result: {} }), moduleCalls: 0 };
  const s = new m.WasmAvmPublicTxSimulator(boundary, { contractDb: 1, merkleDb: 2 }, {},
    () => new Uint8Array(), (r) => r);
  console.log(s.configuration.name + '|' + m.reachesNativeAddon(s.configuration));
}).catch(e => console.log('FAILED|' + e.message))")"
assert_eq "constructed with no configuration at all, it is the wasm AVM and reaches no native addon" \
  "wasm-avm|false" "$DEFAULTED"

# …and that default is not a function of the environment, which is the other way a default gets
# changed without a code review. Set every plausible switch and require the answer not to move.
DEFAULTED_ENV="$(AVM_IMPLEMENTATION=native-cpp-avm USE_CPP_SIMULATOR=1 useCppSimulator=true \
  AVM_CONFIGURATION=native-cpp-avm DUMP_AVM_INPUTS_TO_DIR=/tmp node -e "
import('$ORCH_SRC/index.ts').then(m => console.log(m.defaultConfiguration().name))
  .catch(e => console.log('FAILED'))")"
assert_eq "and the default does not move when the environment tries to move it" \
  "wasm-avm" "$DEFAULTED_ENV"

# ---------------------------------------------------------------------------
# PART 5 — and nothing in the graph reaches the addon either
# ---------------------------------------------------------------------------

GRAPH="$SCRATCH/graph.json"
m18_import_graph "$ORCH_DIR" ./src/index.ts "$GRAPH" >/dev/null 2>&1 \
  || die "could not walk the shipped import graph"
assert_ge "the graph is a real closure" 200 "$(m18_graph_modules "$GRAPH")"
assert_eq "the shipped import graph reaches no @aztec/native" "no" \
  "$(m18_graph_has_package "$GRAPH" "@aztec/native")"
assert_eq "nor @aztec/bb.js's native addon package" "no" \
  "$(m18_graph_has_package "$GRAPH" "@aztec/native")"

finish
