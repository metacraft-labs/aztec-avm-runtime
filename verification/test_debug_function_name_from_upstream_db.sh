#!/usr/bin/env bash
# test_debug_function_name_from_upstream_db
#
# `get_debug_function_name` already exists on `ContractDBInterface`, so the names on M25's trace
# frames come from upstream rather than from a mapping of ours. This check holds that to three
# things, and the third is the one that makes it worth doing:
#
#   1. THE NAMES ARE THE ARTIFACTS'. They are derived by rule from
#      `fixtures/contracts/artifacts.json` — itself generated from the six compiled Noir contracts
#      by `diffsim/check_contract_artifacts.mjs` — and every name the DB returns must be one of that
#      artifact's own public functions. Checked in BOTH directions: the name the DB gives back is
#      the name the artifact declares, and it is not a name this check invented.
#
#   2. THE TYPE IS UPSTREAM'S. They cross the boundary as `DebugFunctionNameHint`, the struct
#      `ExecutionHints` already carries and `HintedRawContractDB` already consumes, with its own
#      msgpack schema and its own TypeScript counterpart. That the reactor's registration export
#      takes that type is asserted against the fork at the anchor, so "upstream's type" is a fact
#      about upstream's header rather than a name we chose.
#
#   3. THE NAME REACHES THE FRAME LABEL. `TxExecution::get_debug_function_name` reads `calldata[0]`
#      as a selector, asks the contract DB, and falls back to `<selector: …>` when there is no name;
#      the label goes to fd 2. So the check runs the whole corpus TWICE — once with the names
#      registered and once without — and requires seven name labels and zero selector labels in the
#      first, and zero and seven in the second. A single arm proves nothing: a label that always
#      read the same way would pass it.
#
# The name is also required to be part of the CHECKPOINTED state: registered inside a checkpoint and
# reverted, it must be gone. A debug name that survived a revert would be a small leak of one
# transaction's state into the next.

TEST_NAME="test_debug_function_name_from_upstream_db"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"

m13_measured

ARTIFACTS="$REPO_ROOT/fixtures/contracts/artifacts.json"
assert_file "the contract artifact index exists" "$ARTIFACTS"

# --- 2. the type is upstream's ----------------------------------------------
avm_io="$(git -C "$FORK_ROOT" show \
  "$M6_BASE_REV:barretenberg/cpp/src/barretenberg/vm2/common/avm_io.hpp" 2>/dev/null)"
assert_contains "DebugFunctionNameHint is declared upstream, at the anchor" \
  "struct DebugFunctionNameHint {" "$avm_io"
assert_contains "with its own msgpack schema" \
  "SERIALIZATION_FIELDS(address, selector, name);" "$avm_io"
assert_contains "and ExecutionHints already carries a vector of them" \
  "std::vector<DebugFunctionNameHint> debug_function_names;" "$avm_io"
raw_dbs="$(git -C "$FORK_ROOT" show \
  "$M6_BASE_REV:barretenberg/cpp/src/barretenberg/vm2/simulation/lib/raw_data_dbs.cpp" 2>/dev/null)"
assert_contains "and upstream's own hinted raw contract DB already consumes them" \
  "for (const auto& debug_function_name_hint : hints.debug_function_names)" "$raw_dbs"
assert_contains "the reactor's registration export takes that same type" \
  "std::vector<DebugFunctionNameHint>" "$(cat "$M13_PATCH_10")"

# --- 1. the names are the artifacts' ----------------------------------------
names_file="${M13_NAMES_FILE:-$M13_WORK/debug-names.txt}"
assert_file "the derived name list exists" "$names_file"
assert_eq "it carries one name per corpus program" "$M13_EXPECTED_PROGRAMS" \
  "$(grep -c . "$names_file" || true)"
# Both directions, against the artifact index: every derived name is a real public function of the
# artifact it names, and the derivation is reproducible from the index alone.
python3 - "$ARTIFACTS" "$names_file" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))["artifacts"]
names = [l.strip() for l in open(sys.argv[2]) if l.strip()]
bad = []
for n in names:
    artifact, _, fn = n.partition("::")
    if artifact not in d:
        bad.append("%s: no such artifact in the index" % n)
    elif fn not in d[artifact]["calledPublicFunctions"]:
        bad.append("%s: %s is not a public function the corpus calls on %s" % (n, fn, artifact))
order = ["Token", "AMM", "AvmTest", "AvmGadgetsTest", "StorageProofTest", "PublicFnsWithEmitRepro"]
expected = ["%s::%s" % (a, sorted(d[a]["calledPublicFunctions"])[0]) for a in order]
expected.append("Token::%s" % sorted(d["Token"]["calledPublicFunctions"])[1])
if names != expected:
    bad.append("the list is not what the rule derives from the index:\n  got      %s\n  expected %s"
               % (names, expected))
sys.exit("\n".join(bad) if bad else 0)
PY
if [ "$?" -eq 0 ]; then
  pass "every derived name is a public function of the artifact it names, and the list is the rule's"
else
  fail "the derived names do not come from the contract artifacts (see above)"
fi

# --- the two arms -----------------------------------------------------------
for arm in registered unregistered; do
  m13_run_host debugname "$M13_WORK/debugname.$arm.out" "$M13_WORK/debugname.$arm.err" "$arm"
  rc=$?
  assert_eq "the $arm arm ran" "0" "$rc"
  [ -s "$M13_WORK/debugname.$arm.out" ] || die "the $arm transcript is empty — see $M13_WORK/debugname.$arm.err"
  m13_assert_field "the $arm arm ran to completion" "$M13_WORK/debugname.$arm.out" "debugname.done" "1"
  m13_assert_field "the $arm arm covered all seven programs" \
    "$M13_WORK/debugname.$arm.out" "debugname.programs.count" "$M13_EXPECTED_PROGRAMS"
  m13_assert_field "and leaked no linear-memory allocation" \
    "$M13_WORK/debugname.$arm.out" "debugname.ownedAllocationsAtExit" "0"
done

REG="$M13_WORK/debugname.registered.out"
UNREG="$M13_WORK/debugname.unregistered.out"

matched=0
for prog in $M13_PROGRAMS; do
  want="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.functionName")"
  [ -n "$want" ] || { fail "$prog: the inputs carry no function name"; continue; }
  m13_assert_field "$prog: the DB has no name before one is registered" "$REG" "debugname.$prog.before" "nil"
  m13_assert_field "$prog: registered inside a checkpoint, the DB returns it" \
    "$REG" "debugname.$prog.insideCheckpoint" "$want"
  m13_assert_field "$prog: and reverting that checkpoint takes it away again" \
    "$REG" "debugname.$prog.afterRevert" "nil"
  m13_assert_field "$prog: registered for real, the DB returns the artifact's own name" \
    "$REG" "debugname.$prog.after" "$want"
  m13_assert_field "$prog: and the unregistered arm never has it" "$UNREG" "debugname.$prog.before" "nil"
  matched=$((matched + 1))
done
assert_eq "all seven names round-tripped through the shipped store" "$M13_EXPECTED_PROGRAMS" "$matched"

# --- 3. the name reaches the AVM's own frame label --------------------------
#
# The label is `…::<name>` on fd 2, followed by vinfo's own ` (mem: …)` suffix, so the needle is
# anchored on a following space or end of line. A bare substring match would also count a name that
# happened to be a prefix of another; every one of these is matched with its own boundary.
labelled=0
for prog in $M13_PROGRAMS; do
  want="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.functionName")"
  n="$(grep -cE "::$(printf '%s' "$want" | sed 's/[][\.*^$/]/\\&/g')( |\$)" \
       "$M13_WORK/debugname.registered.err" || true)"
  assert_eq "$prog: its frame label carries the artifact's function name, exactly once" "1" "$n"
  labelled=$((labelled + 1))
done
assert_eq "all seven frame labels carried a name" "$M13_EXPECTED_PROGRAMS" "$labelled"

selector_labels_registered="$(grep -cE '::<selector: ' "$M13_WORK/debugname.registered.err" || true)"
assert_eq "and NOT ONE frame fell back to a selector when the names were registered" \
  "0" "$selector_labels_registered"

# The negative arm: without the names, every one of the seven falls back — which is what
# `TestContractDB` would have produced for every frame, forever.
selector_labels_unregistered="$(grep -cE '::<selector: ' "$M13_WORK/debugname.unregistered.err" || true)"
assert_eq "without the names, every frame falls back to a selector" \
  "$M13_EXPECTED_PROGRAMS" "$selector_labels_unregistered"
name_labels_unregistered=0
for prog in $M13_PROGRAMS; do
  want="$(m13_field "$(m13_inputs)" "contractDbInputs.$prog.functionName")"
  n="$(grep -cE "::$(printf '%s' "$want" | sed 's/[][\.*^$/]/\\&/g')( |\$)" \
       "$M13_WORK/debugname.unregistered.err" || true)"
  name_labels_unregistered=$((name_labels_unregistered + n))
done
assert_eq "and no frame carries a name in that arm" "0" "$name_labels_unregistered"

finish
