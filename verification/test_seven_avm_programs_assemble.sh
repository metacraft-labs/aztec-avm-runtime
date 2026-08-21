#!/usr/bin/env bash
# test_seven_avm_programs_assemble — M2.
#
# Each of the seven corpus programs assembles through upstream's BytecodeBuilder to the recorded
# byte length and derived contract address.
#
# HOW THE TWO SIDES ARE KEPT INDEPENDENT, since that is the whole value of this check. The recorded
# side is upstream's C++ `vm2/testing/BytecodeBuilder` + `InstructionBuilder`, whose output is
# checked in as the `-- program NAME bytes=N` and `address 0x…` lines of
# `fixtures/wasm-parity/native-with-roots.results`. The re-derived side is upstream's TypeScript
# encoder — the per-opcode `wireFormat` tables and `serializeAs` — plus upstream's own
# `computePublicBytecodeCommitment` / `computeContractClassId` / `computeContractAddressFromInstance`.
#
# The contract address is a hash over the ENTIRE bytecode, so agreement on it is agreement on every
# byte. A byte-length comparison alone would be far weaker; two encoders can agree on a length and
# disagree on the bytes. That is why the address is the load-bearing assertion, and it is what lets
# this run in ordinary CI with no barretenberg build.
#
# It fails, rather than skipping, if the transcripts, node, or diffsim's jest are missing.

TEST_NAME="test_seven_avm_programs_assemble"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DIFFSIM="$REPO_ROOT/diffsim"
TEST_FILE="$DIFFSIM/src/corpus/avm_corpus_programs.test.ts"
MODULE="$DIFFSIM/src/corpus/avm_corpus_programs.ts"
NATIVE="$REPO_ROOT/fixtures/wasm-parity/native-with-roots.results"
WASM="$REPO_ROOT/fixtures/wasm-parity/wasm-with-roots.results"
SUMMARY="$REPO_ROOT/fixtures/avm-programs/programs.json"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
command -v node >/dev/null 2>&1 || die "node is not available"
[ -f "$TEST_FILE" ] || die "diffsim/src/corpus/avm_corpus_programs.test.ts does not exist"
[ -f "$NATIVE" ] || die "fixtures/wasm-parity/native-with-roots.results does not exist"
[ -f "$WASM" ] || die "fixtures/wasm-parity/wasm-with-roots.results does not exist"
[ -f "$SUMMARY" ] || die "fixtures/avm-programs/programs.json does not exist"
[ -x "$DIFFSIM/node_modules/.bin/jest" ] || die "diffsim's jest is not installed (run npm install in diffsim/)"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

echo "== the test named by this check exists and is greppable where it lives"
assert_true "test_seven_avm_programs_assemble is the jest test's name" \
  grep -q "it('test_seven_avm_programs_assemble'" "$TEST_FILE"

echo "== the re-assembly runs green"
( cd "$DIFFSIM" && NODE_NO_WARNINGS=1 node --experimental-vm-modules ./node_modules/.bin/jest \
    --passWithNoTests src/corpus/avm_corpus_programs.test.ts ) >"$SCRATCH/jest.log" 2>&1
JEST_RC=$?
if [ "$JEST_RC" -ne 0 ]; then
  tail -40 "$SCRATCH/jest.log" >&2
fi
assert_eq "jest exited 0" "0" "$JEST_RC"
assert_true "exactly one test ran and passed" grep -q "Tests:       1 passed, 1 total" "$SCRATCH/jest.log"
assert_false "no test was skipped" grep -q "skipped" "$SCRATCH/jest.log"

echo "== the seven programs, byte length and address, against upstream's C++ output"
REPORT="$(python3 - "$SUMMARY" "$NATIVE" "$WASM" <<'PY'
import json, re, sys

summary = json.load(open(sys.argv[1]))["programs"]


def parse(path):
    out = {}
    lines = open(path).read().split("\n")
    for i, line in enumerate(lines):
        m = re.match(r"^-- program (\S+) bytes=(\d+)$", line.strip())
        if not m:
            continue
        a = re.match(r"^address\s+(0x[0-9a-f]{64})$", lines[i + 1].strip())
        if not a:
            raise SystemExit(f"{path}: no address after {line!r}")
        out[m.group(1)] = {"bytes": int(m.group(2)), "address": a.group(1)}
    return out


native = parse(sys.argv[2])
wasm = parse(sys.argv[3])
expected = ["add", "revert", "loop", "sha256", "poseidon2", "storage", "burn"]

rows = []


def check(name, ok, detail=""):
    rows.append(("PASS" if ok else "FAIL", name, str(detail)))


check("the summary records exactly the seven named programs", sorted(summary) == sorted(expected), sorted(summary))
check("the native transcript records exactly seven programs", sorted(native) == sorted(expected), sorted(native))
check("the wasm transcript records exactly seven programs", sorted(wasm) == sorted(expected), sorted(wasm))

for name in expected:
    if name not in summary or name not in native:
        check(f"{name}: present in both", False, "")
        continue
    check(
        f"{name}: byte length equals the C++ BytecodeBuilder output",
        summary[name]["bytes"] == native[name]["bytes"],
        f"{summary[name]['bytes']} vs {native[name]['bytes']}",
    )
    check(
        f"{name}: derived address equals the C++ derived address",
        summary[name]["address"] == native[name]["address"],
        f"{summary[name]['address']} vs {native[name]['address']}",
    )
    check(
        f"{name}: the native and wasm C++ builds agree with each other",
        native[name] == wasm.get(name),
        "",
    )
    check(f"{name}: carries a recorded intent", len(summary[name].get("intent", "")) >= 80, len(summary[name].get("intent", "")))
    check(f"{name}: instruction count is non-trivial", summary[name]["instructionCount"] >= 2, summary[name]["instructionCount"])

# The seven must be genuinely different programs, or the checks above hold for seven copies of one.
check("seven distinct bytecode digests", len({summary[n]["sha256"] for n in expected}) == 7, "")
check("seven distinct derived addresses", len({summary[n]["address"] for n in expected}) == 7, "")
check("seven distinct bytecode commitments", len({summary[n]["bytecodeCommitment"] for n in expected}) == 7, "")
total = sum(summary[n]["bytes"] for n in expected)
check("the seven total more than a kilobyte of bytecode", total > 1000, total)

for status, name, detail in rows:
    print(f"{status}\t{name}\t{detail}")
PY
)"
while IFS=$'\t' read -r status name detail; do
  [ -n "$name" ] || continue
  if [ "$status" = "PASS" ]; then pass "$name"; else fail "$name  ($detail)"; fi
done <<<"$REPORT"

echo "== the programs are the ones upstream's C++ driver builds"
assert_true "the C++ driver uses upstream's BytecodeBuilder" \
  grep -q "vm2/testing/bytecode_builder.hpp" "$REPO_ROOT/fixtures/wasm-parity/vm2_spike-sources/avm_run.cpp"
assert_true "the C++ driver uses upstream's InstructionBuilder" \
  grep -q "vm2/testing/instruction_builder.hpp" "$REPO_ROOT/fixtures/wasm-parity/vm2_spike-sources/avm_run.cpp"
assert_true "the C++ driver deploys through upstream's PublicTxSimulationTester" \
  grep -q "public_tx_simulation_tester.hpp" "$REPO_ROOT/fixtures/wasm-parity/vm2_spike-sources/avm_run.cpp"
for name in add revert loop sha256 poseidon2 storage burn; do
  assert_true "the C++ driver builds program_$name" \
    grep -q "program_$name" "$REPO_ROOT/fixtures/wasm-parity/vm2_spike-sources/avm_run.cpp"
done

# ---------------------------------------------------------------------------
echo "== negative controls"
# ---------------------------------------------------------------------------
run_control() { # <description> <python-mutation-of-the-module>
  local desc="$1" prog="$2"
  cp "$MODULE" "$SCRATCH/module.bak"
  python3 - "$MODULE" "$prog" <<'PY'
import sys
path, prog = sys.argv[1], sys.argv[2]
text = open(path).read()
new = eval(prog, {"text": text})
if new == text:
    sys.stderr.write("control mutation was a no-op\n")
    sys.exit(2)
open(path, "w").write(new)
PY
  local applied=$?
  if [ "$applied" -ne 0 ]; then
    cp "$SCRATCH/module.bak" "$MODULE"
    fail "negative control could not be applied: $desc"
    return
  fi
  ( cd "$DIFFSIM" && NODE_NO_WARNINGS=1 node --experimental-vm-modules ./node_modules/.bin/jest \
      --passWithNoTests src/corpus/avm_corpus_programs.test.ts ) >"$SCRATCH/control.log" 2>&1
  local rc=$?
  cp "$SCRATCH/module.bak" "$MODULE"
  if [ "$rc" -eq 0 ]; then
    fail "negative control NOT caught: $desc"
  else
    pass "negative control caught: $desc"
  fi
}

# (1) One extra instruction changes the byte length AND the address.
run_control "an extra instruction appended to program add" \
  'text.replace("add8(0, 1, 2), ret(0, 2)]", "add8(0, 1, 2), add8(0, 1, 2), ret(0, 2)]", 1)'
# (2) One changed OPERAND leaves the byte length identical and changes only the bytes — this is the
#     case a length-only check would miss entirely, and the address is what catches it.
run_control "one operand changed, with the byte length unaffected" \
  'text.replace("set8(0, TypeTag.UINT32, 1), set8(1, TypeTag.UINT32, 2)", "set8(0, TypeTag.UINT32, 9), set8(1, TypeTag.UINT32, 2)", 1)'
# (3) A changed memory TAG, likewise length-preserving.
run_control "one memory tag changed, with the byte length unaffected" \
  'text.replace("set8(1, TypeTag.UINT64, 1), set8(2, TypeTag.UINT64, 3)", "set8(1, TypeTag.UINT32, 1), set8(2, TypeTag.UINT64, 3)", 1)'
# (4) The deployment parameters must matter: a different deployer address must fail.
run_control "a different deployer in the address derivation" \
  'text.replace("AztecAddress.fromBigInt(100n)", "AztecAddress.fromBigInt(101n)", 1)'
# (5) The public keys must matter too — this is the field whose value was DERIVED by matching
#     upstream's output, so a check that did not depend on it would be hiding a guess.
run_control "the grumpkin generator replaced by the other square root" \
  'text.replace("return new Point(Fr.ONE, y.negate(), false);", "return new Point(Fr.ONE, y, false);", 1)'
# (6) A program dropped from the corpus.
run_control "one of the seven programs removed" \
  "text.replace(\"    name: 'storage',\", \"    name: 'storage_RENAMED',\", 1)"
# (7) An intent stripped to nothing.
run_control "a program with its recorded intent emptied" \
  "text.replace(\"      'SSTORE of a field to a slot\", \"      'x' + (0 && 'SSTORE of a field to a slot\", 1).replace(\"public-data tree, which is why its end-public-data root differs from every other program in the native-versus-wasm transcript. Without it the tree-root lines in that transcript would be seven copies of the same constant.',\", \"public-data tree.'),\", 1)"

assert_true "the module was restored after the controls" cmp -s "$SCRATCH/module.bak" "$MODULE"

finish
