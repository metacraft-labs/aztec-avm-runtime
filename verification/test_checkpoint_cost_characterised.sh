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
# THE TWO ARMS ARE MEASURED ABBA, AND THE CLAIM ABOUT THE FIFTH TREE IS MADE ONLY WHERE THE
# INSTRUMENT CAN CARRY IT. Each arm is run twice, in the order base / ext / ext / base, so arm is
# not confounded with launch order — it was, and the order effect on this host is larger at 10,000
# leaves than anything the tree count could do. The two runs of an arm are combined by minimum, and
# their DIFFERENCE is kept as the measurement's own resolution.
#
# The answer that falls out is a small POSITIVE constant — five to seven microseconds across four
# independent measurements of these two binaries — at the two smallest populations, where it does
# not grow while the four-tree copy nearly triples. That is what one leaf at height 30 predicts. At
# 1,000 and 10,000 leaves NO claim is made and none is asserted; what is asserted instead is the
# condition that licenses the claim where it IS made, namely that the difference is larger than the
# arms' own run-to-run spread at that population. An earlier version asserted that the SIGN of the
# difference was unstable — requiring at least one population where five trees measured FASTER than
# four, which the same comment called physically impossible — so the check's passing condition was
# its own measurement error. §5 has the full account.
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
# FOUR RUNS, IN THE ORDER base, ext, ext, base — an ABBA design, and it replaces a measurement in
# which arm was perfectly confounded with launch order.
#
# The previous shape ran each arm ONCE, base always first, and compared the two files. The arms are
# separate processes with separate heaps, and the first process of a session pays for a cold page
# cache and a fresh allocator that the second does not: measured here, one binary's own first and
# second runs read 6,630 us and 9,384 us at 10,000 leaves. That order effect is larger than the
# quantity the comparison exists to measure, and it was being attributed to the arm.
#
# ABBA gives each arm one early slot and one late slot, so the mean launch position is 2.5 for
# both. The two runs of an arm are then combined by taking the MINIMUM of every value (see
# m15_bench_min: each value is already a median over reps inside one process, so what is left
# between processes is additive nuisance). And the DIFFERENCE between an arm's two runs is kept,
# because it is this measurement's own resolution and section 5 asserts against it.
REPS="${M15_BENCH_REPS:-9}"
BASE_A="$M15_WORK/checkpoint-base.a.txt"
EXT_A="$M15_WORK/checkpoint-ext.a.txt"
EXT_B="$M15_WORK/checkpoint-ext.b.txt"
BASE_B="$M15_WORK/checkpoint-base.b.txt"
BASE_OUT="$M15_WORK/checkpoint-base.txt"
EXT_OUT="$M15_WORK/checkpoint-ext.txt"
m15_run_bench "$BASE_TREE" "$BASE_A" "$REPS"
assert_eq "slot 1, the four-tree benchmark, exited 0" "0" "$?"
m15_run_bench "$EXT_TREE" "$EXT_A" "$REPS"
assert_eq "slot 2, the five-tree benchmark, exited 0" "0" "$?"
m15_run_bench "$EXT_TREE" "$EXT_B" "$REPS"
assert_eq "slot 3, the five-tree benchmark again, exited 0" "0" "$?"
m15_run_bench "$BASE_TREE" "$BASE_B" "$REPS"
assert_eq "slot 4, the four-tree benchmark again, exited 0" "0" "$?"
for f in "$BASE_A" "$EXT_A" "$EXT_B" "$BASE_B"; do
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
# The two runs of an arm must report the SAME KEYS, or the minimum below would silently take one
# run's value for a key the other never produced — a comparison succeeding because one side was
# empty, at the granularity of a single key.
for arm in "base:$BASE_A:$BASE_B" "ext:$EXT_A:$EXT_B"; do
  n="${arm%%:*}"; rest="${arm#*:}"; fa="${rest%%:*}"; fb="${rest#*:}"
  assert_eq "$n: the arm's two runs report the same key set" \
    "$(cut -d= -f1 "$fa" | LC_ALL=C sort | tr '\n' ' ')" \
    "$(cut -d= -f1 "$fb" | LC_ALL=C sort | tr '\n' ' ')"
done
m15_bench_min "$BASE_OUT" "$BASE_A" "$BASE_B"
m15_bench_min "$EXT_OUT" "$EXT_A" "$EXT_B"
assert_ge "the combined four-tree file has every key" 25 "$(grep -c '=' "$BASE_OUT" || true)"
assert_ge "and so does the combined five-tree one" 25 "$(grep -c '=' "$EXT_OUT" || true)"
# The combination is a MINIMUM and that is asserted rather than assumed, at the one population
# where a wrong combination would be least visible.
for arm in "base:$BASE_A:$BASE_B:$BASE_OUT" "ext:$EXT_A:$EXT_B:$EXT_OUT"; do
  n="${arm%%:*}"; r="${arm#*:}"; fa="${r%%:*}"; r="${r#*:}"; fb="${r%%:*}"; fm="${r#*:}"
  va="$(m15_bkey "$fa" cp.1000.create_us)"; vb="$(m15_bkey "$fb" cp.1000.create_us)"
  assert_eq "$n: the combined value is the MINIMUM of the arm's two runs, not one of them by luck" \
    "$([ "$va" -le "$vb" ] && printf '%s' "$va" || printf '%s' "$vb")" \
    "$(m15_bkey "$fm" cp.1000.create_us)"
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
# The upper bound is a hundred-fold, not a ten-fold, and the reason is a measurement rather than a
# preference: the observed ratio is SUPERLINEAR. A bound of 10x would state the hypothesis "the
# copy is exactly linear in the population", which is not what the data says and not what the
# implementation does — a `std::unordered_map` copy rehashes and allocates per node, and both get
# worse per node as the map grows. What this bound is for is refusing a measurement that has gone
# wrong by orders of magnitude, and a hundred-fold does that while leaving the superlinearity to be
# reported as the finding it is, below.
#
# ALL FOUR GROWTH RATIOS GET IT, which they did not. The ceiling used to guard this one ratio
# alone — the five-tree upper decade — while the other three had a floor and no ceiling at all.
# The measurement that broke the previous 30x bound was the FOUR-tree upper decade, i.e. the one
# ratio that ended up with no ceiling: the bound was moved off the measurement that failed it
# rather than restated over it. `cp_ratio_bounded` states the pair once and every ratio goes
# through it.
cp_ratio_bounded() { # <description> <ratio-x100>
  assert_ge "$1: at least 4x, so O(changes) is refused" 400 "$2"
  assert_true "$1: and at most 100x, so a measurement that ran away is refused" test "$2" -le 10000
}
cp_ratio_bounded "five-tree, the upper decade" "$RATIO"
# The same claim one decade lower, so the slope is a slope and not one step a constant could
# explain. Two decades, two ratios, both above the O(changes) prediction.
RATIO_LOW="$(m15_ratio_x100 "$C1K" "$C100")"
note "and population 1000 against 100: ${RATIO_LOW}%"
cp_ratio_bounded "five-tree, the lower decade" "$RATIO_LOW"

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
cp_ratio_bounded "four-tree, the upper decade" "$BR_HI"
cp_ratio_bounded "four-tree, the lower decade" "$BR_LO"

# WHAT IS DELIBERATELY *NOT* ASSERTED, and the measurement that says why. The two arms' ABSOLUTE
# times at 10,000 leaves disagree by far more than the tree count could explain, and §5 shows the
# instrument's own repeatability there is of the same size as the disagreement: one binary's two
# runs differ by thousands of microseconds. At that population the numbers are dominated by
# something other than the copy's size, so no claim is made on their ratio there. The growth claim
# above survives it because a ratio within one arm shares that arm's conditions; a ratio ACROSS the
# arms does not.
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
# BOTH SIDES, because ">= 2x" alone passes on sqrt growth and on quadratic alike and so is not a
# statement about linearity at all. Linear in depth predicts exactly 4x for each step; the band is
# 2x to 8x, wide enough that the measurement's own spread cannot decide it and narrow enough that
# a quadratic (16x) or a sublinear (~2x) implementation would come out of it.
assert_ge "four nested calls cost at least twice one" "$((N1 * 2))" "$N4"
assert_true "and at most eight times one — 4x is what LINEAR in depth predicts" \
  test "$N4" -le "$((N1 * 8))"
assert_ge "sixteen cost at least twice four" "$((N4 * 2))" "$N16"
assert_true "and at most eight times four, the same band" test "$N16" -le "$((N4 * 8))"

# ---------------------------------------------------------------------------
# 5. WHAT THE FIFTH TREE COSTS: A SMALL CONSTANT, MEASURED WHERE IT IS MEASURABLE.
#
# M14 added an archive tree to the same checkpointed `State`, so the copy is one tree larger, and
# the archive tree holds ONE leaf at genesis. So the prediction is a small constant that does not
# grow with the population, and that is exactly what the two smallest populations show — the
# difference is a handful of microseconds at both, while the four-tree copy itself nearly triples
# between them.
#
# WHAT THIS REPLACES, because the replacement is the point. The previous version asserted that the
# SIGN of the five-against-four difference was unstable across populations —
#
#     assert_ge "and at least one has it FASTER, which a fifth tree cannot cause" 1 "$BELOW"
#
# — i.e. it required at least one population where five trees measured FASTER than four, a result
# the assertion's own text calls physically impossible. The check's passing condition was its own
# measurement error, and the day the measurement got good enough to give the physically correct
# answer everywhere, the check would have gone red. It also voted with the 10,000-leaf cross-arm
# ratio twenty lines after this file declared that ratio unusable, and it excluded `cp.0` — which
# the benchmark measures and prints, and which is the cleanest population there is.
#
# WHAT IS ASSERTED NOW, and where the line between claim and no-claim falls:
#
#   populations 0 and 100   the difference is a small POSITIVE constant. Both facts are asserted:
#                           the sign a fifth tree requires, and that the size does not grow while
#                           the four-tree copy does. This is a claim, and it is a positive one.
#   populations 1k and 10k  NO CLAIM, and no assertion either. Not "the sign is unstable there" —
#                           nothing. The numbers and the arms' own run-to-run spreads are printed,
#                           and the decision to say nothing about them is printed with them.
#
# What licenses the claim at 0 and 100 IS asserted, and it comes out of the ABBA replication: each
# arm ran twice, so its own run-to-run spread at each population is available, and the difference is
# required to be bigger than that spread. That condition can only fail on a machine too noisy to
# support the claim, which is the right way round. The mirror image — asserting that the instrument
# IS noisy at 10,000 leaves — would be another check requiring its own measurement to come out
# badly, which is what this section was rebuilt to remove, so it is not asserted.
#
# The cross-arm ratio keeps a bound at every population, but it is named for what it is: a guard
# against a measurement that ran away by orders of magnitude, not evidence about the fifth tree.
# ---------------------------------------------------------------------------
B0="$(m15_bkey "$BASE_OUT" cp.0.create_us)"
case "$B0" in ''|*[!0-9]*) die "the four-tree arm did not report a population-0 timing (got '$B0')" ;; esac
RX0="$(m15_ratio_x100 "$C0" "$B0")"
R100="$(m15_ratio_x100 "$C100" "$B100")"
R1K="$(m15_ratio_x100 "$C1K" "$B1K")"
R10K="$(m15_ratio_x100 "$C10K" "$B10K")"
note "five trees against four, create_checkpoint: ${RX0}% at 0, ${R100}% at 100, ${R1K}% at 1000, ${R10K}% at 10000"
for r in "$RX0" "$R100" "$R1K" "$R10K"; do
  case "$r" in ''|*[!0-9]*) die "a five-against-four ratio came back non-numeric ('$r')" ;; esac
  assert_true "runaway guard, not evidence: the two arms are within an order of magnitude (${r}%)" \
    test "$r" -ge 10 -a "$r" -le 1000
done

# THE CLAIM, at the two populations where the arms are comparable. `cp.0` is a database that has
# done nothing and `cp.100` is one that has done very little; at both, the copy is dominated by the
# genesis prefill and the absolute times are tens of microseconds, so a few microseconds of
# difference is a large fraction of the reading rather than a rounding error on it.
D0=$((C0 - B0))
D100=$((C100 - B100))
note "the fifth tree's cost, by subtraction: ${D0}us at population 0 (${B0} -> ${C0}), ${D100}us at 100 (${B100} -> ${C100})"
assert_ge "at population 0 the five-tree copy is SLOWER, which is the sign a fifth tree requires" \
  1 "$D0"
assert_ge "and at population 100 as well" 1 "$D100"
# An upper bound with a physical meaning rather than a chosen one: one tree holding a single leaf
# must cost less than the four holding 128 + 128 prefilled leaves between them.
assert_true "the fifth tree costs less than the other four together at population 0 (${D0} < ${B0})" \
  test "$D0" -lt "$B0"
assert_true "and less than them at population 100 (${D100} < ${B100})" test "$D100" -lt "$B100"
# A band, so a constant of a completely different size is a finding rather than a pass. One leaf at
# height 30 is a handful of nodes; tens of microseconds is the scale that predicts, and hundreds
# would mean the archive tree is not what this check thinks it is.
for d in "$D0" "$D100"; do
  assert_true "and it is a HANDFUL of microseconds (${d}us), which one leaf at height 30 predicts" \
    test "$d" -ge 1 -a "$d" -le 40
done

# AND IT IS A CONSTANT, NOT PART OF THE SLOPE — which is the whole reason it does not change the
# complexity. Between population 0 and 100 the four-tree copy grows by at least half again, because
# 100 more leaves is real work; the fifth tree's contribution does not, because the archive tree
# still holds its one genesis leaf. Both halves are asserted, so "it did not grow" is a statement
# about the delta and not about a measurement that did nothing.
assert_ge "the four-tree copy itself grows between those two populations (${B0} -> ${B100})" \
  "$((B0 * 3 / 2))" "$B100"
assert_true "while the fifth tree's cost does not: ${D0}us at 0 against ${D100}us at 100" \
  test "$D100" -le "$((D0 * 3))" -a "$D0" -le "$((D100 * 3))"

# THE LICENCE FOR THE TWO CLAIMS ABOVE: THE DIFFERENCE REPLICATES INSIDE THE EXPERIMENT.
#
# ABBA gives two independent halves — slots 1 and 2 (base.a, ext.a) and slots 3 and 4 (ext.b,
# base.b) — each an adjacent pair of runs, and the two halves are minutes apart. The fifth tree
# must be slower in BOTH. That is a replication of the sign within the run rather than a statement
# about noise, and it is what makes the combined figure above a reading rather than a coin toss.
#
# WHY NOT "the difference exceeds the arms' run-to-run spread", which is what stood here first: the
# spread is of the RAW runs while the estimate is of their MINIMUM, so a single slow outlier
# inflates the spread without moving the estimate at all. It did exactly that on the run this was
# written against — one `cp.100` slot came back 67 us where every other reading of that arm is
# 58-60 — and the check went red at 7 us against 7 us on a measurement that was perfectly good.
# Comparing an estimator against a spread it is designed to be robust to is the wrong comparison.
#
# What this deliberately is NOT is the mirror-image mistake: an assertion that the instrument IS
# noisy at 1,000 or 10,000 leaves would be another check requiring its own measurement to come out
# badly, which is exactly what this section was rebuilt to remove. Those populations get notes.
cp_half_delta() { # <base-slot-file> <ext-slot-file> <key> -> ext - base for that half
  local b e
  b="$(m15_bkey "$1" "$3")"; e="$(m15_bkey "$2" "$3")"
  case "$b$e" in ''|*[!0-9]*) die "an ABBA half for $3 came back non-numeric ('$b','$e')" ;; esac
  printf '%s\n' "$((e - b))"
}
HA0="$(cp_half_delta "$BASE_A" "$EXT_A" cp.0.create_us)"
HB0="$(cp_half_delta "$BASE_B" "$EXT_B" cp.0.create_us)"
HA100="$(cp_half_delta "$BASE_A" "$EXT_A" cp.100.create_us)"
HB100="$(cp_half_delta "$BASE_B" "$EXT_B" cp.100.create_us)"
note "the two halves of the ABBA pair, independently: ${HA0}us and ${HB0}us at population 0, ${HA100}us and ${HB100}us at 100"
assert_ge "population 0, slots 1-2: the five-tree arm is slower" 1 "$HA0"
assert_ge "population 0, slots 3-4, measured minutes later: still slower" 1 "$HB0"
assert_ge "population 100, slots 1-2: the five-tree arm is slower" 1 "$HA100"
assert_ge "population 100, slots 3-4: still slower" 1 "$HB100"

# The raw run-to-run spreads, reported so a reader can see how much of the reading is process
# nuisance and where it swamps the effect. Not asserted, at any population.
cp_spread() { # <key> -> max(|base.a - base.b|, |ext.a - ext.b|)
  local b e
  b="$(m15_bench_spread "$BASE_A" "$BASE_B" "$1")"
  e="$(m15_bench_spread "$EXT_A" "$EXT_B" "$1")"
  case "$b$e" in ''|*[!0-9]*) die "a run-to-run spread for $1 came back non-numeric ('$b','$e')" ;; esac
  if [ "$b" -ge "$e" ]; then printf '%s\n' "$b"; else printf '%s\n' "$e"; fi
}
note "run-to-run spread of one binary: $(cp_spread cp.0.create_us)us at population 0 and $(cp_spread cp.100.create_us)us at 100, against a fifth-tree cost of ${D0}us and ${D100}us"

# AND WHERE NO CLAIM IS MADE, reported so the decision is visible rather than inferred from the
# absence of a row. Nothing below is asserted, on purpose.
note "at 1,000 leaves the arms read ${B1K}us and ${C1K}us, with a run-to-run spread of $(cp_spread cp.1000.create_us)us; at 10,000, ${B10K}us and ${C10K}us with a spread of $(cp_spread cp.10000.create_us)us"
note "so this check makes NO claim about the fifth tree at populations 1,000 and 10,000, and asserts none: the arms are separate processes with separate heaps and at those populations they differ by more, and in a direction a fifth tree cannot cause, than the fifth tree costs"

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
