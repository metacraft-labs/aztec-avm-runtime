#!/usr/bin/env bash
# test_contract_artifacts_load — M2, Tier C.
#
# All six contract artifacts load and expose the public functions the app tests call.
#
# The list of "the public functions the app tests call" is DERIVED, not declared:
# `diffsim/check_contract_artifacts.mjs` scans every `.ts` under `diffsim/src` for quoted
# identifiers and intersects that with each artifact's own function list. A hand-written list can be
# trimmed until the check passes; a derived one cannot. The derived result is then compared against
# the checked-in `fixtures/contracts/artifacts.json` in BOTH directions, so a function disappearing
# from an artifact and the corpus quietly ceasing to call one are both failures.
#
# It fails, rather than skipping, if node or the npm packages are missing.

TEST_NAME="test_contract_artifacts_load"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIFFSIM="$REPO_ROOT/diffsim"
DRIFT="$REPO_ROOT/drift"
CHECKER="$DIFFSIM/check_contract_artifacts.mjs"
RECORDED="$REPO_ROOT/fixtures/contracts/artifacts.json"
PINS="$REPO_ROOT/pins.json"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
command -v node >/dev/null 2>&1 || die "node is not available"
[ -f "$CHECKER" ] || die "diffsim/check_contract_artifacts.mjs does not exist"
[ -f "$RECORDED" ] || die "fixtures/contracts/artifacts.json does not exist"
[ -d "$DIFFSIM/node_modules/@aztec/noir-contracts.js" ] || die "diffsim/node_modules/@aztec/noir-contracts.js is missing"
[ -d "$DIFFSIM/node_modules/@aztec/noir-test-contracts.js" ] || die "diffsim/node_modules/@aztec/noir-test-contracts.js is missing"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "== all six artifacts load, and every function the corpus calls is present"
if ( cd "$DIFFSIM" && node check_contract_artifacts.mjs ) >"$SCRATCH/fresh.json" 2>"$SCRATCH/fresh.err"; then
  pass "the artifact checker exited 0"
else
  cat "$SCRATCH/fresh.err" >&2
  fail "the artifact checker failed"
  finish
fi

assert_true "it produced JSON" python3 -c "import json;json.load(open('$SCRATCH/fresh.json'))"
if cmp -s "$SCRATCH/fresh.json" "$RECORDED"; then
  pass "the derived result reproduces fixtures/contracts/artifacts.json byte for byte"
else
  fail "the derived result differs from the checked-in record"
  diff "$RECORDED" "$SCRATCH/fresh.json" | head -30 >&2
fi

read_json() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null; }

echo "== the six the milestone names, and nothing missing"
NAMES="$(read_json "$SCRATCH/fresh.json" "' '.join(sorted(d['artifacts']))")"
assert_eq "the six artifacts" "AMM AvmGadgetsTest AvmTest PublicFnsWithEmitRepro StorageProofTest Token" "$NAMES"

echo "== each artifact has a real transpiled entry point and a non-trivial called set"
for name in Token AMM AvmTest AvmGadgetsTest StorageProofTest PublicFnsWithEmitRepro; do
  BYTES="$(read_json "$SCRATCH/fresh.json" "d['artifacts']['$name']['dispatchBytecodeBytes']")"
  CALLED="$(read_json "$SCRATCH/fresh.json" "len(d['artifacts']['$name']['calledPublicFunctions'])")"
  PUB="$(read_json "$SCRATCH/fresh.json" "d['artifacts']['$name']['publicFunctionCount']")"
  assert_ge "$name: public_dispatch carries transpiled bytecode" 1000 "${BYTES:-0}"
  assert_ge "$name: the corpus calls at least one of its public functions" 1 "${CALLED:-0}"
  assert_ge "$name: declares public functions" 1 "${PUB:-0}"
done

echo "== the artifacts come from the declared npm pin, not from whatever happens to be installed"
# The comparison happens inside the generator, against `pins.json`, and the generator exits
# non-zero on a mismatch — so the version literal never lands in a tracked JSON file, which is what
# `verify_pinned_nightly_single_source` requires. What is asserted here is that the comparison ran
# and that it is capable of failing.
DECLARED="$(python3 -c "import json;p=json.load(open('$PINS'));print(p['npm'][p['npm_consumers']['diffsim']]['version'])")"
assert_ge "pins.json declares diffsim's npm line" 5 "${#DECLARED}"
for name in Token AMM AvmTest AvmGadgetsTest StorageProofTest PublicFnsWithEmitRepro; do
  MATCHES="$(read_json "$SCRATCH/fresh.json" "d['artifacts']['$name']['aztecVersionMatchesDeclaredPin']")"
  assert_eq "$name: aztecVersion equals the declared pin" "True" "$MATCHES"
done
assert_false "the record carries no nightly version literal of its own" \
  grep -q "nightly" "$RECORDED"
cp "$CHECKER" "$DIFFSIM/.check_contract_artifacts_control.mjs"
python3 - "$DIFFSIM/.check_contract_artifacts_control.mjs" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace(
    "const DECLARED_VERSION = PINS.npm[PINS.npm_consumers.diffsim].version;",
    "const DECLARED_VERSION = 'not-the-declared-pin';",
    1,
)
open(p, "w").write(t)
PY
if ( cd "$DIFFSIM" && node .check_contract_artifacts_control.mjs ) >/dev/null 2>&1; then
  fail "negative control NOT caught: a wrong declared pin still exited 0"
else
  pass "negative control caught: an artifact off the declared pin makes the checker exit non-zero"
fi
rm -f "$DIFFSIM/.check_contract_artifacts_control.mjs"

echo "== the same six also resolve on the current nightly, so the corpus is not pinned to a dead line"
# drift/ is the tree on `npm.current`. Loading the artifacts there proves the Tier C corpus is not
# tied to the frozen `deletion_era` evidence line — which matters because `deletion_era` never moves.
DRIFT_OK=0
if [ -d "$DRIFT/node_modules/@aztec/noir-test-contracts.js" ]; then
  if ( cd "$DRIFT" && node -e "
    const specs = [
      ['@aztec/noir-contracts.js/Token','TokenContractArtifact'],
      ['@aztec/noir-contracts.js/AMM','AMMContractArtifact'],
      ['@aztec/noir-test-contracts.js/AvmTest','AvmTestContractArtifact'],
      ['@aztec/noir-test-contracts.js/AvmGadgetsTest','AvmGadgetsTestContractArtifact'],
      ['@aztec/noir-test-contracts.js/StorageProofTest','StorageProofTestContractArtifact'],
      ['@aztec/noir-test-contracts.js/PublicFnsWithEmitRepro','PublicFnsWithEmitReproContractArtifact'],
    ];
    for (const [m, e] of specs) {
      const a = (await import(m))[e];
      if (!a || !a.functions.find(f => f.name === 'public_dispatch')) { throw new Error(m); }
    }
  " ) >/dev/null 2>&1; then
    DRIFT_OK=1
  fi
else
  die "drift/node_modules/@aztec/noir-test-contracts.js is missing (run npm install in drift/)"
fi
assert_eq "all six load on the npm.current line too" "1" "$DRIFT_OK"

# ---------------------------------------------------------------------------
echo "== negative controls"
# ---------------------------------------------------------------------------
# (1) A record with a function removed must not reproduce the derivation. This is the direction
#     that matters: the derived list cannot be trimmed to make the check pass.
python3 - "$RECORDED" "$SCRATCH/trimmed.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["artifacts"]["Token"]["calledPublicFunctions"].pop()
json.dump(d, open(sys.argv[2], "w"), indent=2)
PY
assert_false "negative control: a trimmed called-function list no longer reproduces the derivation" \
  cmp -s "$SCRATCH/trimmed.json" "$SCRATCH/fresh.json"

# (2) The checker must FAIL, not warn, when an artifact cannot be imported.
cp "$CHECKER" "$SCRATCH/broken.mjs"
python3 - "$SCRATCH/broken.mjs" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("'@aztec/noir-contracts.js/Token'", "'@aztec/noir-contracts.js/NoSuchContract'", 1)
open(p, "w").write(t)
PY
cp "$SCRATCH/broken.mjs" "$DIFFSIM/.check_contract_artifacts_control.mjs"
if ( cd "$DIFFSIM" && node .check_contract_artifacts_control.mjs ) >/dev/null 2>&1; then
  fail "negative control NOT caught: an unimportable artifact still exited 0"
else
  pass "negative control caught: an unimportable artifact makes the checker exit non-zero"
fi
rm -f "$DIFFSIM/.check_contract_artifacts_control.mjs"

# (3) The checker must FAIL when an artifact's public surface is untouched by the corpus, so
#     "the corpus calls none of them" is an error rather than an empty list.
cp "$CHECKER" "$SCRATCH/nocalls.mjs"
python3 - "$SCRATCH/nocalls.mjs" <<'PY'
import sys
p = sys.argv[1]
t = open(p).read().replace("const referenced = quotedIdentifiers('src');", "const referenced = new Set();", 1)
open(p, "w").write(t)
PY
cp "$SCRATCH/nocalls.mjs" "$DIFFSIM/.check_contract_artifacts_control.mjs"
if ( cd "$DIFFSIM" && node .check_contract_artifacts_control.mjs ) >/dev/null 2>&1; then
  fail "negative control NOT caught: an artifact whose surface is never called still exited 0"
else
  pass "negative control caught: an artifact whose surface is never called makes the checker fail"
fi
rm -f "$DIFFSIM/.check_contract_artifacts_control.mjs"

# (4) The derived set really is derived from the sources: removing a source reference removes it
#     from the result. `set_minter` is referenced in exactly ONE file (`fixtures/amm_test.ts`),
#     which is asserted here rather than assumed — an earlier revision of this control used
#     `burn_public`, which two files reference, so mutating one left the derived set unchanged and
#     the control quietly proved nothing.
CONTROL_FN="set_minter"
REFS="$(cd "$DIFFSIM" && grep -rl "'$CONTROL_FN'" src/ | wc -l)"
assert_eq "the control identifier is referenced in exactly one source file" "1" "$REFS"
SRC="$(cd "$DIFFSIM" && grep -rl "'$CONTROL_FN'" src/ | head -1)"
SRC="$DIFFSIM/$SRC"
assert_file "the source the derivation reads it from" "$SRC"
assert_true "it is in the derived set to begin with" \
  bash -c "[ \"\$(python3 -c \"import json;print('$CONTROL_FN' in json.load(open('$SCRATCH/fresh.json'))['artifacts']['Token']['calledPublicFunctions'])\")\" = True ]"
cp "$SRC" "$SCRATCH/control-src.bak"
python3 - "$SRC" "$CONTROL_FN" <<'PY'
import sys
p, fn = sys.argv[1], sys.argv[2]
open(p, "w").write(open(p).read().replace(f"'{fn}'", f"'{fn}_CONTROL'"))
PY
( cd "$DIFFSIM" && node check_contract_artifacts.mjs ) >"$SCRATCH/mutated-src.json" 2>/dev/null
cp "$SCRATCH/control-src.bak" "$SRC"
STILL_THERE="$(read_json "$SCRATCH/mutated-src.json" "'$CONTROL_FN' in d['artifacts']['Token']['calledPublicFunctions']")"
assert_eq "negative control: removing a source reference removes it from the derived set" "False" "$STILL_THERE"
assert_true "the source file was restored" cmp -s "$SCRATCH/control-src.bak" "$SRC"

finish
