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

# ---------------------------------------------------------------------------
# THE FAILURE VOCABULARY ITSELF, exercised. Every check in this milestone asserts that a run wrote
# nothing from it, and until review nothing established that it would recognise anything: the
# `(^|[^A-Za-z])` guard in front of `[Ee]rror` meant `TypeError:`, `ReferenceError:`, `RangeError:`
# and `SyntaxError:` — the four commonest ways a node host dies — did not match, nor did V8's
# all-caps `FATAL ERROR:`. A vocabulary nobody has ever seen reject a line is an assertion that
# passes because both sides are empty, one level up.
#
# So both directions are asserted here, on fabricated files, against the SAME function the seven
# per-program assertions above call.
# ---------------------------------------------------------------------------
VOC="$SCRATCH/vocab"; mkdir -p "$VOC"
i=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  i=$((i + 1))
  printf '%s\n' "$line" >"$VOC/pos$i"
  assert_ge "the failure vocabulary recognises: $line" 1 "$(m15_stderr_unexpected "$VOC/pos$i")"
done <<'POS'
TypeError: R.e.avm_simulate is not a function
ReferenceError: mdb is not defined
RangeError: Maximum call stack size exceeded
SyntaxError: Unexpected end of JSON input
FATAL ERROR: Reached heap limit Allocation failed - JavaScript heap out of memory
wasm trap: out of bounds memory access
terminate called after throwing an instance of 'std::runtime_error'
Segmentation fault (core dumped)
double free or corruption (out)
free(): invalid pointer
*** stack smashing detected ***: terminated
[NR_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision
POS
assert_eq "twelve failure shapes, each on its own" "12" "$i"

# The tolerated lines, which a correct run really does produce (D11), and which must stay
# tolerated — otherwise the vocabulary is asserting something about the AVM's log level.
j=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  j=$((j + 1))
  printf '%s\n' "$line" >"$VOC/neg$j"
  assert_eq "and tolerates, because a correct run writes it: $line" "0" \
    "$(m15_stderr_unexpected "$VOC/neg$j")"
done <<'NEG'
Simulating... (mem: N/A)
[NON_REVERTIBLE] Inserting 1 nullifiers, 0 note hashes, and 0 L2 to L1 messages for tx 0xtest (mem: N/A)
(node:12345) ExperimentalWarning: WASI is an experimental feature and might change at any time
Out of gas exception: Out of gas: total L2 used 1 of 2, total DA used 96 of 100 (mem: N/A)
PureTxBytecodeManager held 132 instructions in cache, totaling ~24 kB. (mem: N/A)
NEG
assert_eq "five tolerated shapes" "5" "$j"

# THE TWO EXEMPTIONS ARE ANCHORED, and the pair below is what makes that a property rather than a
# claim. The corpus's `revert` program reverts with an EMPTY message, and that line carries the
# word "Assertion" — so it is exempt. A revert carrying a MESSAGE is the channel an internal C++
# exception's `what()` travels on, and the class-wide `grep -v 'halted via REVERT with message:'`
# this replaced exempted those too.
printf '%s\n' '[APP_LOGIC] Enqueued call to 0x2a halted via REVERT with message: Assertion failed:  (mem: N/A)' \
  >"$VOC/revert-empty"
printf '%s\n' '[APP_LOGIC] Enqueued call to 0x2a halted via REVERT with message: Assertion failed: internal invariant broken (mem: N/A)' \
  >"$VOC/revert-carrying"
assert_eq "the corpus's own empty-message revert is exempt — a revert is an outcome, not a failure" \
  "0" "$(m15_stderr_unexpected "$VOC/revert-empty")"
assert_ge "but a revert CARRYING a message is not, because that is how an internal what() escapes" \
  1 "$(m15_stderr_unexpected "$VOC/revert-carrying")"
# The same shape for nix's own eval-cache chatter: its exact line is exempt, a lookalike is not.
printf '%s\n' "error (ignored): SQLite database '/home/u/.cache/nix/eval-cache-v6/ab.sqlite' is busy" \
  >"$VOC/nix-busy"
printf '%s\n' "error (ignored): SQLite database is corrupt and the module did not load" \
  >"$VOC/nix-lookalike"
assert_eq "nix's own eval-cache line is exempt by its exact shape" "0" \
  "$(m15_stderr_unexpected "$VOC/nix-busy")"
assert_ge "a line that merely resembles it is not" 1 "$(m15_stderr_unexpected "$VOC/nix-lookalike")"

# AND A MISSING FILE IS NOT A CLEAN ONE. This returned 0 — i.e. passed — so a call site that
# passed the wrong `$OUT` had a vacuous assertion. It cannot compare equal to 0 now, and it names
# the path it could not find.
MISSING="$(m15_stderr_unexpected "$VOC/there-is-no-such-file")"
assert_false "a missing stderr file does not read as a clean one" test "$MISSING" = "0"
assert_true "and the answer names the path that was not there" \
  test "$MISSING" = "no-stderr-file:$VOC/there-is-no-such-file"
# The real files this check just read DO exist, so the assertions above were about content.
assert_file "the representative program's stderr file is a real file" \
  "$SCRATCH/$M15_REPRESENTATIVE.txt.err"

finish
