#!/usr/bin/env bash
# verify_private_oracle_synchrony_enumerated — M38's FIRST deliverable, which is a measurement.
#
# For the private functions that run, every oracle they call is classified: answerable
# SYNCHRONOUSLY from state already inside wasm, needing a HOST ROUND TRIP, or UNIMPLEMENTED. The
# three sets are disjoint and sum to the calls the run actually made.
#
# WHY THIS EXISTS AT ALL, in one paragraph, because the milestone it replaces got it wrong.
# The previous M38 measured what `@aztec/noir-acvm_js` exports and concluded that nothing steps.
# That measurement was correct and the conclusion was false, because it asked what the npm artifact
# can do and never asked what this project already built. So the rule this check enforces is not
# "count the oracles" — it is *the observed call list is taken from a RUN, and the classification
# from the handler's own SOURCE, and neither is a list somebody typed*.
#
# THE THREE CLASSES AND WHAT DECIDES EACH — see `_m38_oracle_synchrony.py`'s header for the full
# statement. In short: `unimplemented` is the RUN's ledger saying the call was not answered;
# `host-round-trip` is the handler method being declared `async` or awaiting, which a synchronous
# `ForeignCallExecutor::execute` cannot cross; `sync-in-wasm` is what is left.
#
# CONTROLS, and each is here because its absence is a shape this campaign has shipped:
#   * a FABRICATED oracle name is in none of the three sets — a classifier that classified
#     everything would put it somewhere;
#   * the observed list is compared against the run's own ledger, so "it is in the table" cannot
#     stand in for "it was called";
#   * the comment stripper is asserted in BOTH directions — it left code behind AND it removed
#     prose — because a stripper that returned nothing would make every method unresolved and a
#     stripper that stripped nothing would count a citation as a declaration;
#   * the classifier is shown to be able to answer `host-round-trip` at all, on a frame that
#     produces one, so a run of four `sync-in-wasm` answers is a measurement rather than a constant.
#
# Run: just verify-m38-synchrony

TEST_NAME="verify_private_oracle_synchrony_enumerated"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m38_private_trace.sh"
trap m38_summary_on_abnormal_exit EXIT

command -v python3 >/dev/null 2>&1 || die "python3 is required"

ORACLES_SRC="$REPO_ROOT/browser/src/wallet/private_oracles.ts"
[ -s "$ORACLES_SRC" ] || die "no handler source at $ORACLES_SRC"
[ -s "$M38_TAPE_SOURCE" ] || die "there is no M35 arm report at $M38_TAPE_SOURCE.
             Remedy: just m35-arms"

EXECUTES=executes
REFUSES=refuses
EXECUTES_PATH=arms.private.report.executes
REFUSES_PATH=arms.private.report.refuses

SYNC_JSON="$(m38_synchrony "$M38_TAPE_SOURCE" "$EXECUTES=$EXECUTES_PATH" "$REFUSES=$REFUSES_PATH")" \
  || die "the synchrony classifier failed"

s() { printf '%s' "$SYNC_JSON" | python3 -c '
import json, sys
node = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    if isinstance(node, list):
        try:
            node = node[int(part)]; continue
        except (ValueError, IndexError):
            print("MISSING"); raise SystemExit(0)
    if not isinstance(node, dict) or part not in node:
        print("MISSING"); raise SystemExit(0)
    node = node[part]
print(json.dumps(node, separators=(",", ":"), sort_keys=True) if isinstance(node, (list, dict)) else node)
' "$1"; }

echo "== 1. THE SCANNER READ SOMETHING, AND ITS STRIPPER WORKED IN BOTH DIRECTIONS"
METHODS="$(s handlerMethods)"
CODE_CHARS="$(s codeChars)"
STRIPPED="$(s strippedChars)"
m38_absent handlerMethods="$METHODS" codeChars="$CODE_CHARS" strippedChars="$STRIPPED"
assert_ge "the handler declares a real number of methods" 40 "$(m38_num "$METHODS" 'handlerMethods')"
assert_ge "the stripper left code behind" 20000 "$(m38_num "$CODE_CHARS" 'codeChars')"
# THE OTHER HALF, AND IT IS THE ONE THAT MATTERS. `private_oracles.ts` is heavily commented — its
# refusal reasons and its four upstream validations are prose — so a stripper that removed nothing
# would leave every one of those paragraphs in the bodies it scans for `await`, and a citation in a
# comment would read as a call. Asserted as a QUANTITY of removed characters rather than as a
# boolean, because "it removed something" is satisfied by removing one character.
assert_ge "and it removed a substantial amount of prose" 20000 "$(m38_num "$STRIPPED" 'strippedChars')"

echo "== 2. THE FRAME THAT COMPLETES: EVERY CALL CLASSIFIED, AND THE SETS SUM"
CONTRACT="$(s "frames.$EXECUTES.contract")"
FUNCTION="$(s "frames.$EXECUTES.function")"
OUTCOME="$(s "frames.$EXECUTES.outcome")"
SYNC_N="$(s "frames.$EXECUTES.counts.sync-in-wasm")"
HOST_N="$(s "frames.$EXECUTES.counts.host-round-trip")"
UNIMPL_N="$(s "frames.$EXECUTES.counts.unimplemented")"
UNRES_N="$(s "frames.$EXECUTES.counts.unresolved")"
CALLS_JSON="$(s "frames.$EXECUTES.calls")"
DISTINCT="$(s "frames.$EXECUTES.distinctOracles")"
m38_absent contract="$CONTRACT" function="$FUNCTION" outcome="$OUTCOME" \
  sync="$SYNC_N" host="$HOST_N" unimplemented="$UNIMPL_N" unresolved="$UNRES_N" \
  calls="$CALLS_JSON" distinct="$DISTINCT"

assert_eq "the subject is the frame that COMPLETES" "OracleVersionCheck/private_function/executed" \
  "$CONTRACT/$FUNCTION/$OUTCOME"

OBSERVED="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["arms"]["private"]["report"]["executes"]["oracleCalls"]))' \
  "$M38_TAPE_SOURCE")"
assert_ge "the run made oracle calls at all" 1 "$(m38_num "$OBSERVED" 'observed calls')"
TOTAL=$(( $(m38_num "$SYNC_N" sync) + $(m38_num "$HOST_N" host) \
        + $(m38_num "$UNIMPL_N" unimplemented) + $(m38_num "$UNRES_N" unresolved) ))
assert_eq "the four classes sum to the calls the RUN made" "$OBSERVED" "$TOTAL"
assert_eq "nothing is unresolved — a method the scanner could not find is named, not classified" \
  "0" "$UNRES_N"

# THE HEADLINE NUMBER, AND IT IS A RELATION RATHER THAN A CONSTANT. A typed 4 would go stale the
# day the handler or the contract moves, and a constant a check has just been handed looks like a
# measurement to the person typing it. What is asserted is that the frame which COMPLETES needs
# nothing this boundary cannot cross.
assert_eq "the frame that completes needs NO host round trip" "0" "$HOST_N"
assert_eq "and nothing it calls is unimplemented" "0" "$UNIMPL_N"
assert_eq "so every one of its calls is answerable synchronously" "$OBSERVED" "$SYNC_N"
assert_ge "over more than one distinct oracle, so the answer is not about a single call" 3 \
  "$(printf '%s' "$DISTINCT" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

echo "== 3. THE CLASSIFIER CAN ANSWER host-round-trip, ON A FRAME THAT PRODUCES ONE"
# WITHOUT THIS, SECTION 2's `host-round-trip == 0` IS AN ABSENCE MEASURED BY AN INSTRUMENT NOBODY
# SAW PRODUCE THE OTHER ANSWER. `Token.transfer` calls `isNullifierPending`, which is declared
# `async` and awaits `siloNullifier` — so the same classifier over the same handler answers
# `host-round-trip` there, and the zero above is a reading rather than a constant.
R_SYNC="$(s "frames.$REFUSES.counts.sync-in-wasm")"
R_HOST="$(s "frames.$REFUSES.counts.host-round-trip")"
R_UNIMPL="$(s "frames.$REFUSES.counts.unimplemented")"
R_STOP="$(s "frames.$REFUSES.stoppedAtOracle")"
R_CALLS="$(s "frames.$REFUSES.calls")"
m38_absent refusesSync="$R_SYNC" refusesHost="$R_HOST" refusesUnimpl="$R_UNIMPL" \
  refusesStop="$R_STOP" refusesCalls="$R_CALLS"
assert_ge "the refusing frame produced at least one host-round-trip classification" 1 \
  "$(m38_num "$R_HOST" 'refuses host')"
assert_ge "and at least one unimplemented" 1 "$(m38_num "$R_UNIMPL" 'refuses unimplemented')"
assert_ge "and at least one sync-in-wasm, so all three classes are occupied" 1 \
  "$(m38_num "$R_SYNC" 'refuses sync')"
assert_eq "the unimplemented one is the oracle the run itself stopped at" "true" \
  "$(printf '%s' "$R_CALLS" | python3 -c '
import json, sys
calls = json.load(sys.stdin)
stopped = [c for c in calls if c["class"] == "unimplemented"]
print("true" if stopped and stopped[-1]["oracle"] == sys.argv[1] else "false")' "$R_STOP")"

echo "== 4. THE ASYNC SET IS THE HANDLER'S OWN, AND IT NAMES ITS MEMBERS"
ASYNC="$(s asyncMethods)"
m38_absent asyncMethods="$ASYNC"
ASYNC_N="$(printf '%s' "$ASYNC" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_ge "the handler declares async methods at all" 5 "$(m38_num "$ASYNC_N" 'async methods')"
# NAMED AS WELL AS COUNTED. A count moves when upstream adds an oracle; a membership does not, and
# it is the membership that decides whether a frame can be replayed. `isNullifierPending` is the one
# section 3 rests on, and `getRandomField` is the one every note-creating contract reaches.
assert_true "isNullifierPending is one of them" \
  str_has_sub "$ASYNC" '"isNullifierPending"'
assert_true "and getRandomField" str_has_sub "$ASYNC" '"getRandomField"'
# The negative half: a method that is NOT async must not be in the set, or the scanner is answering
# `async` for everything.
assert_false "isExecutionInRevertiblePhase is NOT" \
  str_has_sub "$ASYNC" '"isExecutionInRevertiblePhase"'

echo "== 5. THE CONTROL: A FABRICATED ORACLE IS IN NONE OF THE THREE SETS"
# A classifier that classified everything would put a name nobody serves somewhere. This plants one
# in a COPY of the arm report and asserts the classifier reports it as `unresolved` — which is the
# residue class, named rather than counted — and that the three real classes do not grow.
PLANT_WORK="$(mktemp -d)"
trap 'rm -rf "$PLANT_WORK"' RETURN
python3 - "$M38_TAPE_SOURCE" "$PLANT_WORK/planted.json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
frame = doc["arms"]["private"]["report"]["executes"]
calls = list(frame["oracleCalls"])
calls.append({"seq": len(calls), "oracle": "aztec_utl_getNothingAtAll", "outcome": "served", "detail": "planted"})
frame["oracleCalls"] = calls
json.dump(doc, open(sys.argv[2], "w"))
PY
PLANTED="$(m38_synchrony "$PLANT_WORK/planted.json" "$EXECUTES=$EXECUTES_PATH")" || die "the planted run failed"
p() { printf '%s' "$PLANTED" | python3 -c '
import json, sys
node = json.load(sys.stdin)
for part in sys.argv[1].split("."):
    if not isinstance(node, dict) or part not in node:
        print("MISSING"); raise SystemExit(0)
    node = node[part]
print(json.dumps(node, separators=(",", ":"), sort_keys=True) if isinstance(node, (list, dict)) else node)
' "$1"; }
P_UNRES="$(p "frames.$EXECUTES.counts.unresolved")"
P_SYNC="$(p "frames.$EXECUTES.counts.sync-in-wasm")"
P_HOST="$(p "frames.$EXECUTES.counts.host-round-trip")"
P_UNIMPL="$(p "frames.$EXECUTES.counts.unimplemented")"
m38_absent plantedUnresolved="$P_UNRES" plantedSync="$P_SYNC" plantedHost="$P_HOST" plantedUnimpl="$P_UNIMPL"
assert_eq "the fabricated oracle is reported as unresolved" "1" "$P_UNRES"
assert_eq "and it did not join sync-in-wasm" "$SYNC_N" "$P_SYNC"
assert_eq "nor host-round-trip" "$HOST_N" "$P_HOST"
assert_eq "nor unimplemented" "$UNIMPL_N" "$P_UNIMPL"

echo "== 6. THE DOCUMENT CARRIES WHAT WAS MEASURED"
[ -s "$M38_DOC" ] || die "no $M38_DOC"
DOC="$(cat "$M38_DOC")"
# EACH FIGURE IS MATCHED ON THE LINE THAT NAMES ITS SUBJECT rather than anywhere in the file, which
# is M24's OQ-6 finding: every figure can be present while the table states the reverse of the data.
assert_true "the write-up states the completing frame's call count on its own row" \
  str_has_re "$DOC" "oracle calls it made.*\\*\\*$OBSERVED\\*\\*"
assert_true "and how many of them are answerable synchronously" \
  str_has_re "$DOC" "answerable synchronously in wasm.*\\*\\*$SYNC_N\\*\\*"
assert_true "and how many need a host round trip" \
  str_has_re "$DOC" "needing a host round trip.*\\*\\*$HOST_N\\*\\*"
assert_true "and how many are unimplemented" \
  str_has_re "$DOC" "unimplemented.*\\*\\*$UNIMPL_N\\*\\*"
assert_true "and the handler's async method count, which is the boundary's size" \
  str_has_re "$DOC" "handler methods declared .async.*\\*\\*$ASYNC_N\\*\\*"

m38_finish
