#!/usr/bin/env bash
# test_integration_shape_results_identical
#
# THE TWO SHAPES AGREE, SO THE CHOICE IS ABOUT COST RATHER THAN SEMANTICS.
#
# This is the check that has to run first, because every number the rest of M15 produces is only
# interesting if the thing being priced is the same thing on both sides. A cheaper shape that
# computes a different answer is not cheaper.
#
#   resident   `avm_simulate(inputs, contractDb, merkleDb)` — the DBs live in the module and the
#              boundary carries a transaction in and a result out.
#   chatty     `avm_simulate_with_hinted_dbs(inputs)` — the module holds NO world state; every
#              answer the AVM needs was supplied from outside.
#
# THE COMPARISON IS BOUNDED BY WHAT THE HINTED PATH PRODUCES, AND THE BOUND IS ASSERTED RATHER
# THAN ASSUMED. Upstream's own `AvmSimAPI::simulate_with_hinted_dbs` constructs
# `const PublicSimulatorConfig config = {}` for its simulation, so the hinted result carries
# neither public inputs nor statistics. That is not a defect and it is not worked around: the
# check asserts that the resident arm DOES produce public inputs and the chatty arm does NOT, so
# the exclusion is a measured property of upstream's entry point rather than a field quietly
# dropped from a comparison.
#
# ON THE FIELDS BOTH PRODUCE, EVERY ONE OF THE SEVEN CORPUS PROGRAMS IS COMPARED, AND THE
# COMPARISON IS A DIFF OF TWO NON-EMPTY FILES. Two empty outputs compare equal — this campaign has
# already had one of those — so the line count is asserted before the diff is taken, on both
# sides, and the fields are named individually as well.
#
# AND THE COMPARISON IS SHOWN TO BE ABLE TO FAIL. A mutation is applied to one arm's transcript and
# the same comparison must reject it. Without that, "the two files are identical" is a statement
# about the comparison rather than about the shapes.

set -uo pipefail
TEST_NAME=test_integration_shape_results_identical
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m15_shapes.sh"

M15_TREE="$(m15_tree)"; m6_tree_or_die M15_TREE
TREE="$M15_TREE"
assert_dir "the reactor tree is prepared" "$TREE"
assert_eq "it is the pinned anchor plus M13's ten patches" "10" \
  "$(git -C "$TREE" rev-list --count "$M6_BASE_REV..HEAD")"

m15_build_wasm "$TREE"
assert_eq "the wasm configure succeeded" "0" "$M15_WASM_CONFIGURE_RC"
assert_eq "and avm.wasm built" "0" "$M15_WASM_BUILD_RC"
WASM="$(m15_wasm_module "$TREE")"
assert_file "the module is on disk" "$WASM"

m15_build_native "$TREE"
assert_eq "the native configure succeeded" "0" "$M15_NATIVE_CONFIGURE_RC"
assert_eq "and avm_differential built" "0" "$M15_NATIVE_BUILD_RC"

m15_make_inputs "$TREE"
assert_eq "the driver emitted its inputs" "0" "$?"
INPUTS="$(m15_reactor_inputs)"
assert_file "the inputs file exists" "$INPUTS"
assert_eq "it declares the seven corpus programs" "$M15_EXPECTED_PROGRAMS" \
  "$(m15_key "$INPUTS" reactorInputs.programs.count)"
assert_eq "and it is complete" "1" "$(m15_key "$INPUTS" reactorInputs.done)"

# ---------------------------------------------------------------------------
# Every program, both shapes.
# ---------------------------------------------------------------------------
SCRATCH="$M15_WORK/shapes"; rm -rf "$SCRATCH"; mkdir -p "$SCRATCH"
COMPARED=0
for p in $M15_PROGRAMS; do
  OUT="$SCRATCH/$p.txt"
  m15_host "$WASM" "$INPUTS" shapes "$OUT" "$p"
  assert_eq "$p: the shape host exited 0" "0" "$?"
  assert_eq "$p: it ran to the end" "1" "$(m15_key "$OUT" shapes.done)"
  assert_eq "$p: and wrote nothing from the failure vocabulary to stderr (D11: the AVM logs there)" "0" "$(m15_stderr_unexpected "$OUT.err")"
  assert_ge "$p: it produced its lines" 20 "$(m15_lines "$OUT")"

  # The two halves, extracted by prefix and compared as whole files. `sed` strips the arm name so
  # what is left is field-for-field.
  sed -n 's/^resident\.//p' "$OUT" | grep -v '^inputBytes\|^steps\|^resultBytes\|^publicInputsPresent\|^roots\.' | LC_ALL=C sort >"$SCRATCH/$p.res"
  sed -n 's/^chatty\.//p'   "$OUT" | grep -v '^inputBytes\|^steps\|^resultBytes\|^publicInputsPresent\|^residentTreesPresent' | LC_ALL=C sort >"$SCRATCH/$p.cha"
  # Non-emptiness FIRST. Two empty files are identical and prove nothing.
  assert_ge "$p: the resident arm reported comparable fields" 8 "$(m15_lines "$SCRATCH/$p.res")"
  assert_eq "$p: and the chatty arm reported the same number of them" \
    "$(m15_lines "$SCRATCH/$p.res")" "$(m15_lines "$SCRATCH/$p.cha")"
  assert_true "$p: the two shapes agree field for field" \
    cmp -s "$SCRATCH/$p.res" "$SCRATCH/$p.cha"

  # Named individually as well, so a diff that passed because both sides were reformatted the same
  # way is not the whole evidence.
  for f in revertCode totalGas publicGas billedGas txFee nullifiers.count noteHashes.count dataWrites.count; do
    rv="$(m15_key "$OUT" "resident.$f")"
    cv="$(m15_key "$OUT" "chatty.$f")"
    assert_true "$p: $f is non-empty on both sides" test -n "$rv" -a -n "$cv"
    assert_eq "$p: $f agrees" "$rv" "$cv"
  done
  # THE STEP STREAM IS NOT COMPARED HERE, and the reason is upstream's rather than ours: with the
  # default `PublicSimulatorConfig` neither entry point collects execution steps, so both arms
  # report zero and comparing them would be comparing two zeroes. What IS asserted is that they
  # both report zero for the same reason — the config — rather than one of them losing a stream the
  # other kept.
  assert_eq "$p: neither shape collected steps under the default config" "0 0" \
    "$(m15_key "$OUT" resident.steps) $(m15_key "$OUT" chatty.steps)"

  # The bound on the comparison, measured rather than assumed: the resident arm produces public
  # inputs and the hinted one does not, because upstream's own entry point builds an empty config
  # for it.
  assert_eq "$p: the resident arm produced public inputs" "1" "$(m15_key "$OUT" resident.publicInputsPresent)"
  assert_eq "$p: the hinted arm did not — upstream's own config, not a dropped field" "0" \
    "$(m15_key "$OUT" chatty.publicInputsPresent)"
  # And the chatty arm holds no world state at all, which is the shape's defining property.
  assert_eq "$p: the chatty arm has no resident trees to read" "0" \
    "$(m15_key "$OUT" chatty.residentTreesPresent)"
  assert_ge "$p: while the resident arm reported four tree roots" 4 \
    "$(grep -c '^resident\.roots\.' "$OUT" || true)"
  COMPARED=$((COMPARED + 1))
done
assert_eq "all seven corpus programs were compared" "$M15_EXPECTED_PROGRAMS" "$COMPARED"

# The payload asymmetry, which is the whole trade and is recorded here as a number rather than as
# an adjective: the chatty arm's boundary payload carries the world state the resident arm keeps.
FAST="$(m15_key "$SCRATCH/$M15_REPRESENTATIVE.txt" resident.inputBytes)"
PROV="$(m15_key "$SCRATCH/$M15_REPRESENTATIVE.txt" chatty.inputBytes)"
note "$M15_REPRESENTATIVE: resident input $FAST bytes, chatty input $PROV bytes"
assert_ge "the chatty arm's input is at least fifty times the resident arm's" \
  $((FAST * 50)) "$PROV"

# ---------------------------------------------------------------------------
# The comparison can fail. Three mutations, each of a DIFFERENT field, because a discriminator
# exercised on one field is a discriminator for one field.
# ---------------------------------------------------------------------------
for mut in revertCode txFee nullifiers.count; do
  sed "s/^$mut \(.*\)$/$mut MUTATED/" "$SCRATCH/$M15_REPRESENTATIVE.cha" >"$SCRATCH/mut-$mut"
  assert_false "the mutation of $mut changed the file" \
    cmp -s "$SCRATCH/$M15_REPRESENTATIVE.cha" "$SCRATCH/mut-$mut"
  assert_false "and the comparison rejects it" \
    cmp -s "$SCRATCH/$M15_REPRESENTATIVE.res" "$SCRATCH/mut-$mut"
done
# A mutation that removes a LINE rather than changing one, since a length-blind comparison would
# miss it.
sed '1d' "$SCRATCH/$M15_REPRESENTATIVE.cha" >"$SCRATCH/mut-short"
assert_false "a dropped field is rejected too" \
  cmp -s "$SCRATCH/$M15_REPRESENTATIVE.res" "$SCRATCH/mut-short"
assert_eq "and it really was one line shorter" \
  "$(( $(m15_lines "$SCRATCH/$M15_REPRESENTATIVE.cha") - 1 ))" "$(m15_lines "$SCRATCH/mut-short")"

finish
