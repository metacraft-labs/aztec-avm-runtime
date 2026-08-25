#!/usr/bin/env bash
# test_bitwise_dyn_gas_divergence_detected
#
# THE ARCHETYPE. With the AND/OR/XOR dynamic-L2-gas divergence deliberately reintroduced, the
# harness reports it.
#
# WHAT THE ARCHETYPE IS. Upstream removed the dynamic L2 gas from AND / OR / XOR and deleted
# `AVM_BITWISE_DYN_L2_GAS` from the protocol constants. The published `@aztec/constants` nightly
# still ships it as 3, so the revived TypeScript gas table still charges it (DRIFT.md D1). That is
# silent semantic drift in its purest form: code depending on the stale constant compiles, passes
# every test in the tree, and meters differently from production. D1's decision was that it is
# resolved HERE — the divergence is deliberately perturbed and the harness is required to report
# it, or the differential layer is not doing the one job it exists for.
#
# WHY THE MUTATION IS A CHANGED VALUE RATHER THAN A REMOVAL. Removing the dynamic charge is what
# upstream did, and the TS table would then agree with the C++ anchor the wasm module is built
# from — so a removal makes one arm agree with another and is a weaker test than it looks.
# Multiplying it is unambiguous: it makes the TypeScript interpreter meter differently from BOTH
# C++ arms, on exactly the opcodes D1 names, and the harness must report that on both pairs.
#
# THE MUTATION IS RESTORED BY `cmp` AGAINST A COPY THIS CHECK TAKES, not by `git status`. Two
# checks in this campaign asserted a restore with `git status --porcelain -- <path>` on a path that
# was not tracked yet, and printed nothing whatever the probe had done.
#
# Run: just verify-m19

TEST_NAME="test_bitwise_dyn_gas_divergence_detected"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m19_differential.sh"

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_work_dir "$M19_WORK" 1
m19_require_module
m19_require_packages

GAS_TABLE="$REPO_ROOT/diffsim/src/public/avm/avm_gas.ts"
assert_file "the vendored TypeScript gas table is present" "$GAS_TABLE"
work="$M19_WORK/bitwise"
rm -rf "$work"; mkdir -p "$work"
BACKUP="$work/avm_gas.ts.orig"
cp "$GAS_TABLE" "$BACKUP"
restore() { cp "$BACKUP" "$GAS_TABLE"; }
trap restore EXIT

# ---- 1. the subject is where D1 says it is ---------------------------------
sites="$(grep -c 'AVM_BITWISE_DYN_L2_GAS' "$GAS_TABLE" || true)"
assert_eq "the TS gas table still charges the bitwise dynamic gas on six opcode encodings" "6" "$sites"
assert_true "and D1 records that it should not" grep -q '^## D1 — ' "$REPO_ROOT/DRIFT.md"
assert_eq "while the C++ anchor the module is built from charges zero for it" "0" \
  "$(git -C "$FORK_ROOT" show "$(m19_json "$REPO_ROOT/pins.json" 'd["anchors"]["cpp"]["commit"]'):barretenberg/cpp/src/barretenberg/vm2/common/instruction_spec.cpp" \
     2>/dev/null | grep -c 'AVM_BITWISE_DYN_L2_GAS' || true)"
assert_ge "and the TypeScript anchor's own C++ DID charge it, so D1 is a real change and not a misreading" 1 \
  "$(git -C "$FORK_ROOT" show "$(m19_json "$REPO_ROOT/pins.json" 'd["anchors"]["ts"]["commit"]'):barretenberg/cpp/src/barretenberg/vm2/common/instruction_spec.cpp" \
     2>/dev/null | grep -c 'AVM_BITWISE_DYN_L2_GAS' || true)"

# ---- 2. clean first, so the red below is attributable ----------------------
m19_run_arm "$work/clean.log"
assert_eq "the three-way arm is green before the mutation" "0" "$?"

# ---- 3. THE MUTATION -------------------------------------------------------
python3 - "$GAS_TABLE" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
out = src.replace("makeCost(c.AVM_BITWISE_DYN_L2_GAS, 0)", "makeCost(c.AVM_BITWISE_DYN_L2_GAS * 10, 0)")
assert out != src, "the mutation matched nothing"
open(p, "w").write(out)
PY
assert_eq "the mutation changed the six sites and nothing else" "6" \
  "$(diff "$BACKUP" "$GAS_TABLE" | grep -c '^> ' || true)"

m19_run_arm "$work/mutated.log"
rc=$?
assert_true "the three-way arm reports the reintroduced bitwise divergence" test "$rc" -ne 0
mutated_failures="$(m19_tests_failed "$work/mutated.log")"
assert_ge "and it reports it on more than one test, so it is the corpus and not one accident" 2 \
  "${mutated_failures:-0}"
# The SPECIFIC failure mode, not merely a red suite: the message must name a gas field and the
# TypeScript pair, or the arm could be failing for an unrelated reason.
mutated_out="$(cat "$work/mutated.log")"
assert_contains "and the failure names a gas field" "gasUsed." "$mutated_out"
# WHICH ASSERTION FIRES, and it is not the one this check first expected. The reintroduced
# divergence is between the TypeScript interpreter and the C++ AVM, so UPSTREAM'S OWN two-way
# assertion inside `cpp_vs_ts_public_tx_simulator.ts` fires first, from inside `super.simulate`,
# before the three-way comparison is reached. That is the harness reporting it — through the layer
# that owns that pair — and asserting on the three-way message instead would have been asserting on
# a code path this mutation cannot reach.
assert_contains "and the assertion that fires is the differential simulator's own gas comparison" \
  "cpp_vs_ts_public_tx_simulator.ts" "$mutated_out"
assert_contains "on totalGas specifically" "gasUsed.totalGas.equals" "$mutated_out"
# And the three-way arm's OWN comparison of that same field is separately shown to be capable of
# reporting it, using the permanent fault injection — because "upstream's assertion caught it"
# would otherwise leave the new arm's gas comparison unexercised by this check.
m19_run_arm "$work/injected.log" "M19_INJECT_DIVERGENCE=totalGas"
assert_true "the three-way arm's own gas comparison also reports a gas divergence" test "$?" -ne 0
injected_out="$(cat "$work/injected.log")"
assert_contains "naming the wasm-versus-TypeScript pair" "wasm-avm:typescript-interpreter" "$injected_out"
assert_contains "and saying no drift entry accounts for it" "no drift entry accounts for" "$injected_out"

# ---- 4. and the TWO-WAY suite catches it too --------------------------------
# The archetype is not only about the new arm: upstream's own C++-versus-TypeScript harness must
# also report it, because that is the layer that existed before M19 and D1 says it currently does
# not catch this class at all. One targeted suite rather than the whole corpus, for time.
( cd "$DIFFSIM_DIR" && NODE_NO_WARNINGS=1 node --experimental-vm-modules ./node_modules/.bin/jest \
    src/public/public_tx_simulator/apps_tests/token.test.ts ) >"$work/twoway-mutated.log" 2>&1
assert_true "the pre-existing two-way harness also reports it" test "$?" -ne 0
assert_contains "and it fails inside the differential simulator" "cpp_vs_ts_public_tx_simulator" \
  "$(cat "$work/twoway-mutated.log")"

# ---- 5. RESTORED, and the restoration is verified by comparison -------------
restore
trap - EXIT
if cmp -s "$BACKUP" "$GAS_TABLE"; then
  pass "the gas table is byte-identical to the copy this check took before mutating it"
else
  fail "the gas table was NOT restored"
fi
# The control for the comparison: it must be able to tell two files apart, or the line above is an
# assertion that cannot fail.
printf 'x\n' >>"$work/tamper"; cp "$GAS_TABLE" "$work/tampered"; printf '\n// tampered\n' >>"$work/tampered"
assert_false "and the same comparison distinguishes a file that differs" \
  cmp -s "$BACKUP" "$work/tampered"

# ---- 6. green again, which is what makes the red above the mutation's -------
m19_run_arm "$work/restored.log"
assert_eq "the three-way arm is green again after restoration" "0" "$?"

finish
