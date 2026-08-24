#!/usr/bin/env bash
# test_checkpoint_cost_characterised
#
# WHAT A CHECKPOINT OF THE REFERENCE WORLD STATE COSTS, AND WHETHER IT IS O(state) OR O(changes).
#
# `world_state_reference::MemoryMerkleDB`'s own header says it:
#
#     "Checkpoints deep-copy the whole tree state onto a stack and restore on revert"
#
# and §6.4's design constraint asked for O(changes). Checkpoints are taken per nested call, per
# phase and per transaction, so if the header is describing what it sounds like it is describing,
# the cost of a transaction grows with the size of the world state it runs against.
#
# NOBODY HAS EVER MEASURED IT, and that is established here rather than assumed: at the pinned
# anchor no benchmark anywhere in the fork names `world_state_reference`, `MemoryMerkleDB` or
# `memory_merkle_db`, and the one file that exercises checkpoints at all —
# `world_state/memory_merkle_db.test.cpp` — asserts equivalence and times nothing. Both facts are
# re-derived on every run, over the WHOLE fork rather than over `world_state_reference/`, because
# this campaign has been wrong six times about what lives in a directory parallel to the one it was
# looking in.
#
# THE MEASUREMENT IS A COMPLEXITY CLAIM AND IS ASSERTED AS ONE.
#
# The benchmark runs the same three operations — create, commit, revert — at populations an order
# of magnitude apart, and the check asserts the RATIO. Absolute microseconds are a property of this
# host; a microsecond budget written here would fail on a slower machine and pass on a faster one
# without either telling anybody anything about the implementation. A ratio fails when the
# implementation changes, which is the thing worth being told.
#
# The two hypotheses are separated, and BOTH are stated so neither can be the one that happens to
# be left:
#
#   O(state)    the cost of `create_checkpoint` grows with the population.
#               10x the population predicts roughly 10x the cost.
#   O(changes)  the cost is independent of the population and depends only on what was dirtied
#               since the last checkpoint. 10x the population predicts ~1x the cost.
#
# The bounds around "roughly" are wide on purpose (the point is which of two hypotheses is true,
# not the third significant figure) and they are asserted in BOTH directions, so a run that
# measured nothing at all — every timing zero, ratio 1 — is refused by the lower bound rather than
# accepted as evidence for O(changes).
#
# THE FLOOR IS A SEPARATE FINDING FROM THE SLOPE. A freshly constructed DB has already written the
# two indexed trees' genesis prefill — 128 leaves each — so the FIRST checkpoint of a transaction
# that has done nothing still copies that. `population=0` measures it, and it is asserted to be
# non-trivial: a design in which an empty transaction's checkpoint is free would be a different
# design and this check should notice if it ever becomes one.
#
# AND THE FIFTH TREE IS MEASURED, NOT ARGUED. M14 has just extended the same `State` with an
# archive tree, so the copy is now one tree larger. The benchmark is compiled and run against TWO
# trees of the fork — the pinned anchor, four trees, and the anchor plus M14's patch, five — from
# ONE source that detects which it has with a `requires`-expression and REPORTS the answer. Neither
# arm is told which one it is; `bench.archive_present` is a statement the compiler made about that
# tree's own header. That is M14's probe technique and it is used here for the same reason: an
# `#ifdef` would make this two programs sharing a file.
#
# THE TREES ARE THIS CHECK'S OWN. They are prepared under `$M15_WORK`, not read out of
# `$M14_WORK`. A check must not depend on state it did not produce, and M15's own carried fix is
# about exactly that; reading a work directory another milestone happens to have left behind is the
# same defect one level up.

set -uo pipefail
TEST_NAME=test_checkpoint_cost_characterised
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

M15_WORK="${M15_WORK:-$HOME/.cache/aztec-m15-shapes}"
M14_WORK="$M15_WORK"
export M15_WORK M14_WORK
. "$VERIFY_DIR/lib_m14_world_state.sh"
. "$VERIFY_DIR/lib_m15_shapes.sh"

assert_file "the checkpoint benchmark source is present" "$M15_BENCH_SRC"

# ---------------------------------------------------------------------------
# 1. The claim the header makes, and the absence of any measurement of it.
# ---------------------------------------------------------------------------
REF_HPP="$FORK_ROOT/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"
assert_file "the reference's header is where it is expected" "$REF_HPP"
assert_true "its own header says checkpoints deep-copy the whole tree state" \
  grep -q 'deep-copy the whole tree state onto a stack and restore on revert' "$REF_HPP"
assert_eq "the checkpoint stack is a stack of whole States, as declared" "1" \
  "$(grep -c 'std::stack<State> checkpoints_;' "$REF_HPP" || true)"
assert_eq "and the State it stacks has the four AVM trees as members" "4" \
  "$(sed -n '/struct State {/,/};/p' "$REF_HPP" | grep -cE '^ +(NullifierTree|PublicDataTree|NoteHashTree|L1ToL2MessageTree) ' || true)"

# No benchmark, anywhere in the fork. Enumerated over the WHOLE tree and by name, three needles,
# each derived from the artefact: the module directory, the class, and the file stem. `--include`
# rather than a path prefix, because the misses this campaign has made were all directories nobody
# thought to look in.
BENCH_HITS="$(grep -rIl --include='*.cpp' --include='*.hpp' --include='*.cmake' --include='CMakeLists.txt' \
  -E '\b(world_state_reference|MemoryMerkleDB|memory_merkle_db)\b' \
  "$FORK_ROOT/barretenberg/cpp/src" 2>/dev/null | grep -i 'bench' || true)"
assert_eq "no file in the fork that names the reference is a benchmark" "0" \
  "$(printf '%s' "$BENCH_HITS" | grep -c . || true)"
# And the needle is not vacuous: the same expression without the `bench` filter must find plenty,
# or the zero above is a statement about a broken regular expression rather than about the fork.
ALL_HITS="$(grep -rIl --include='*.cpp' --include='*.hpp' --include='*.cmake' --include='CMakeLists.txt' \
  -E '\b(world_state_reference|MemoryMerkleDB|memory_merkle_db)\b' \
  "$FORK_ROOT/barretenberg/cpp/src" 2>/dev/null || true)"
assert_ge "the same needle finds the reference itself in several files, so the zero above means something" \
  5 "$(printf '%s' "$ALL_HITS" | grep -c . || true)"
GATE="$FORK_ROOT/barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp"
assert_file "the one file that does exercise checkpoints is upstream's fidelity gate" "$GATE"
assert_ge "which does exercise them" 1 "$(grep -c 'create_checkpoint' "$GATE" || true)"
assert_eq "and times nothing: it contains no clock at all" "0" \
  "$(grep -cE '\b(steady_clock|high_resolution_clock|system_clock|chrono)\b' "$GATE" || true)"

# ---------------------------------------------------------------------------
# 2. The two trees, prepared here.
# ---------------------------------------------------------------------------
[ -f "$M14_PATCH" ] || die "M14's world-state patch is missing: $M14_PATCH"
# Assigned into the NAMED variables, not into local aliases: `m14_base_tree` prints the path from
# a SUBSHELL, so `X=$(m14_base_tree)` leaves `M14_BASE_TREE` unset in this shell and
# `m6_tree_or_die M14_BASE_TREE` then fails on a tree that was prepared perfectly well.
M14_BASE_TREE="$(m14_base_tree)"; m6_tree_or_die M14_BASE_TREE
M14_TREE="$(m14_ext_tree)";       m6_tree_or_die M14_TREE
BASE_TREE="$M14_BASE_TREE"
EXT_TREE="$M14_TREE"
assert_dir "the four-tree arm is the pinned anchor" "$BASE_TREE"
assert_dir "the five-tree arm is the anchor plus M14's patch" "$EXT_TREE"
assert_eq "the anchor arm carries no patches" "0" \
  "$(git -C "$BASE_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_eq "the extended arm carries exactly one" "1" \
  "$(git -C "$EXT_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_true "and the one it carries is the archive tree" \
  grep -q 'archive_tree' "$EXT_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"
assert_false "which the anchor arm does not have" \
  grep -q 'archive_tree' "$BASE_TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"

for arm in base ext; do
  case "$arm" in base) t="$BASE_TREE" ;; *) t="$EXT_TREE" ;; esac
  # M14's own `m14_build_native` deletes the build directory first, which is right for M14 and
  # wrong here: this check is a MEASUREMENT and re-running it should not cost two configures. It
  # configures incrementally instead, into M14's build-directory NAME inside M15's own work
  # directory, and still builds the target itself, so the artefact it measures is one it produced.
  m15_native_configure_incremental "$t" "$M14_NATIVE_BUILD" -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M14_NATIVE_CONFIGURE_RC=$?
  if [ "$M14_NATIVE_CONFIGURE_RC" -eq 0 ]; then
    m6_build "$t" "$M14_NATIVE_BUILD" world_state_reference
    M14_NATIVE_BUILD_RC=$?
  else
    M14_NATIVE_BUILD_RC=1
  fi
  assert_eq "$arm: the native configure succeeded" "0" "$M14_NATIVE_CONFIGURE_RC"
  assert_eq "$arm: and world_state_reference built" "0" "$M14_NATIVE_BUILD_RC"
  assert_file "$arm: the library is on disk" "$t/barretenberg/cpp/$M14_NATIVE_BUILD/lib/libworld_state_reference.a"
  m15_build_bench "$t"
  assert_eq "$arm: the benchmark compiled against that tree" "0" "$?"
  assert_file "$arm: and its binary is there" "$(m15_bench_bin "$t")"
done
# The two binaries are not the same program, which is what makes comparing them a comparison. This
# campaign has already had one check that compared a binary with itself.
assert_false "the two arms' benchmark binaries differ" \
  cmp -s "$(m15_bench_bin "$BASE_TREE")" "$(m15_bench_bin "$EXT_TREE")"

# ---------------------------------------------------------------------------
# 3. Run both, and require that they ran.
# ---------------------------------------------------------------------------
REPS="${M15_BENCH_REPS:-9}"
BASE_OUT="$M15_WORK/checkpoint-base.txt"
EXT_OUT="$M15_WORK/checkpoint-ext.txt"
m15_run_bench "$BASE_TREE" "$BASE_OUT" "$REPS"
assert_eq "the four-tree benchmark exited 0" "0" "$?"
m15_run_bench "$EXT_TREE" "$EXT_OUT" "$REPS"
assert_eq "the five-tree benchmark exited 0" "0" "$?"
for f in "$BASE_OUT" "$EXT_OUT"; do
  assert_eq "$(basename "$f"): it ran to the end" "1" "$(m15_bkey "$f" bench_complete)"
  assert_ge "$(basename "$f"): and produced its key=value lines" 25 "$(grep -c '=' "$f" || true)"
  # The BENCHMARK's own stderr, not the shell's. `nix develop` writes its own chatter there — an
  # eval-cache "error (ignored): SQLite database ... is busy" turned up on one run — and a check
  # that required an empty file would be asserting something about nix. The benchmark writes
  # exactly one shape of line, `world_state_checkpoint_bench: <what>`, and only on failure, so that
  # is the needle and it comes from the program rather than from the environment around it.
  assert_eq "$(basename "$f"): the benchmark itself reported nothing on stderr" "0" \
    "$(grep -c '^world_state_checkpoint_bench:' "$f.err" || true)"
done
assert_eq "the four-tree arm reports the archive absent" "0" "$(m15_bkey "$BASE_OUT" bench.archive_present)"
assert_eq "the five-tree arm reports it present" "1" "$(m15_bkey "$EXT_OUT" bench.archive_present)"
assert_eq "both prefill the nullifier tree with 128" "128 128" \
  "$(m15_bkey "$BASE_OUT" bench.nullifier_prefill) $(m15_bkey "$EXT_OUT" bench.nullifier_prefill)"
assert_eq "both populated the note-hash tree to 1000 at the largest point" "1000 1000" \
  "$(m15_bkey "$BASE_OUT" final.note_hash_tree.size) $(m15_bkey "$EXT_OUT" final.note_hash_tree.size)"
assert_eq "and the nullifier tree to 128 prefill plus 1000 inserted" "1128 1128" \
  "$(m15_bkey "$BASE_OUT" final.nullifier_tree.size) $(m15_bkey "$EXT_OUT" final.nullifier_tree.size)"

# ---------------------------------------------------------------------------
# 4. THE COMPLEXITY, from the five-tree arm — the one M15 inherits.
# ---------------------------------------------------------------------------
C0="$(m15_bkey "$EXT_OUT" cp.0.create_us)"
C100="$(m15_bkey "$EXT_OUT" cp.100.create_us)"
C1K="$(m15_bkey "$EXT_OUT" cp.1000.create_us)"
C10K="$(m15_bkey "$EXT_OUT" cp.10000.create_us)"
R0="$(m15_bkey "$EXT_OUT" cp.1000.revert_us)"
M0="$(m15_bkey "$EXT_OUT" cp.1000.commit_us)"
note "create_checkpoint us at population 0/100/1000/10000: $C0 / $C100 / $C1K / $C10K"
note "at population 1000: create $C1K, commit $M0, revert $R0"
for v in "$C0" "$C100" "$C1K" "$C10K" "$R0" "$M0"; do
  case "$v" in ''|*[!0-9]*) die "the benchmark did not report a numeric timing (got '$v')" ;; esac
done

# The FLOOR. An empty transaction's first checkpoint already copies the genesis prefill, so it is
# not free, and that it is not free is the property asserted rather than how much it is.
assert_ge "an empty database's checkpoint is not free — the genesis prefill is already in it" \
  1 "$C0"

# THE SLOPE, over an order of magnitude, both bounds.
RATIO="$(m15_ratio_x100 "$C10K" "$C1K")"
note "create_checkpoint cost ratio, population 10000 against 1000: ${RATIO}%"
assert_ge "10x the population costs at least 4x the checkpoint — this is NOT O(changes)" \
  400 "$RATIO"
# The upper bound is a hundred-fold, not a ten-fold, and the reason is a measurement rather than a
# preference: the observed ratio is SUPERLINEAR. A bound of 10x would state the hypothesis "the
# copy is exactly linear in the population", which is not what the data says and not what the
# implementation does — a `std::unordered_map` copy rehashes and allocates per node, and both get
# worse per node as the map grows. What this bound is for is refusing a measurement that has gone
# wrong by orders of magnitude, and a hundred-fold does that while leaving the superlinearity to be
# reported as the finding it is, below.
assert_true "and at most 100x, so a measurement that ran away is still refused" \
  test "$RATIO" -le 10000
# The same claim one decade lower, so the slope is a slope and not one step a constant could
# explain. Two decades, two ratios, both above the O(changes) prediction.
RATIO_LOW="$(m15_ratio_x100 "$C1K" "$C100")"
note "and population 1000 against 100: ${RATIO_LOW}%"
assert_ge "the decade below shows the same growth" 400 "$RATIO_LOW"

# THE SAME TWO DECADES IN THE OTHER ARM, because a complexity claim made on one build is a claim
# about that build. The four-tree arm must show the same growth, or what was measured is a property
# of M14's patch rather than of the design.
B100="$(m15_bkey "$BASE_OUT" cp.100.create_us)"
B1K="$(m15_bkey "$BASE_OUT" cp.1000.create_us)"
B10K="$(m15_bkey "$BASE_OUT" cp.10000.create_us)"
for v in "$B100" "$B1K" "$B10K"; do
  case "$v" in ''|*[!0-9]*) die "the four-tree arm did not report a timing (got '$v')" ;; esac
done
BR_HI="$(m15_ratio_x100 "$B10K" "$B1K")"
BR_LO="$(m15_ratio_x100 "$B1K" "$B100")"
note "four-tree arm: ${BR_LO}% over the lower decade, ${BR_HI}% over the upper"
assert_ge "the four-tree arm grows over the upper decade too" 400 "$BR_HI"
assert_ge "and over the lower one" 400 "$BR_LO"

# WHAT IS DELIBERATELY *NOT* ASSERTED, and the measurement that says why. The two arms' ABSOLUTE
# times at 10,000 leaves disagree by more than the tree count could explain — and in the wrong
# direction, the FOUR-tree arm being the slower of the two, which having fewer trees cannot cause.
# At that population the numbers are dominated by something other than the copy's size (a
# long-running process's allocator and page state are the obvious candidates), so no claim is made
# on their ratio there. The growth claim above survives it because a ratio within one arm shares
# that arm's conditions; a ratio ACROSS the arms does not.
note "at 10,000 leaves the four-tree arm reports ${B10K}us and the five-tree arm ${C10K}us — the arms' absolute times do not agree at that population"

# THE NEGATIVE CASE FOR THE HYPOTHESIS THAT WAS REJECTED. O(changes) predicts a ratio near 100%.
# Stated as its own assertion rather than left implied by the bound above, because "the number was
# big" and "the O(changes) hypothesis is refused" are different sentences and only the second is
# the finding.
assert_true "the O(changes) hypothesis — cost independent of population — is refused by the data" \
  test "$RATIO" -gt 200

# `commit` copies nothing, but it destroys a whole State, so it is not free either — and it is a
# different number from `create`, which is why the benchmark times them apart.
assert_ge "commit is not free either: popping a State destroys four or five hash maps" 1 "$M0"
assert_ge "and revert, which restores one, is not free" 1 "$R0"

# THE NESTED-CALL SHAPE, which is how a transaction actually pays this. Linear in depth is what
# O(state)-per-checkpoint predicts.
N1="$(m15_bkey "$EXT_OUT" nested.d1.us)"
N4="$(m15_bkey "$EXT_OUT" nested.d4.us)"
N16="$(m15_bkey "$EXT_OUT" nested.d16.us)"
note "a depth-1/4/16 nested-call checkpoint sequence at population 1000: $N1 / $N4 / $N16 us"
assert_ge "four nested calls cost at least twice one" "$((N1 * 2))" "$N4"
assert_ge "sixteen cost at least twice four" "$((N4 * 2))" "$N16"

# ---------------------------------------------------------------------------
# 5. THE FIFTH TREE: ITS COST IS BELOW THIS MEASUREMENT'S RESOLUTION, AND THAT IS THE ANSWER.
#
# M14 added an archive tree to the same checkpointed `State`, so the copy is one tree larger. How
# much larger is a question with a measurable answer only if the addition is bigger than the noise,
# and it is not: the archive tree holds ONE leaf at genesis, so it contributes a handful of nodes
# to a copy of hundreds of thousands.
#
# What is asserted is therefore what the data supports — the two arms agree to within an order of
# magnitude at every population, so the fifth tree does not change the COMPLEXITY — plus the fact
# that establishes "below resolution" by measurement rather than by assertion: the SIGN of the
# difference is not stable across populations. If the fifth tree cost a measurable amount, the
# five-tree arm would be slower at every population. It is not.
# ---------------------------------------------------------------------------
R100="$(m15_ratio_x100 "$C100" "$B100")"
R1K="$(m15_ratio_x100 "$C1K" "$B1K")"
R10K="$(m15_ratio_x100 "$C10K" "$B10K")"
note "five trees against four, create_checkpoint: ${R100}% at 100, ${R1K}% at 1000, ${R10K}% at 10000"
for r in "$R100" "$R1K" "$R10K"; do
  case "$r" in ''|*[!0-9]*) die "a five-against-four ratio came back non-numeric ('$r')" ;; esac
  assert_true "the two arms agree to within an order of magnitude (${r}%)" \
    test "$r" -ge 10 -a "$r" -le 1000
done
# The sign is unstable: at least one population has the five-tree arm slower and at least one has
# it faster. A fifth tree cannot make a copy cheaper, so this is the measurement saying its cost is
# smaller than what it can resolve.
ABOVE=0; BELOW=0
for r in "$R100" "$R1K" "$R10K"; do
  [ "$r" -ge 100 ] && ABOVE=$((ABOVE + 1)) || BELOW=$((BELOW + 1))
done
assert_ge "at least one population has the five-tree arm slower" 1 "$ABOVE"
assert_ge "and at least one has it FASTER, which a fifth tree cannot cause" 1 "$BELOW"
assert_eq "so the three populations do not agree on the sign" "3" "$((ABOVE + BELOW))"

# ---------------------------------------------------------------------------
# 6. The disposition, recorded where a reader will find it.
# ---------------------------------------------------------------------------
assert_file "the boundary write-up exists" "$M15_WRITEUP"
assert_true "it records the checkpoint cost as an UPSTREAM optimisation, not a rewrite" \
  grep -q 'upstream optimisation with independent merit' "$M15_WRITEUP"
assert_true "it names the deep copy as the cause" \
  grep -q 'std::stack<State>' "$M15_WRITEUP"
assert_true "and it carries the measured ratio rather than an adjective" \
  grep -qE 'create_checkpoint.*(1[0-9]|[2-9])[0-9]{2}%|ratio' "$M15_WRITEUP"

finish
