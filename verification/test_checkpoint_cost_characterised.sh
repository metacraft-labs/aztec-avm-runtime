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
# THE TWO ARMS ARE MEASURED AGAINST EACH OTHER INSIDE ONE PROCESS, AND THE CLAIM ABOUT THE FIFTH TREE
# IS MADE ONLY WHERE THE INSTRUMENT CAN CARRY IT. The effect is a few microseconds; the same binary's
# run-to-run spread on a shared runner is 9-56 us, and one whole process runs 15-30 us faster or
# slower than its partner (core, frequency, heap placement). A comparison between processes cannot
# resolve that, however it is ordered or batched, so both trees are linked into ONE program that
# pins itself to one core and times the two arms in alternating batches (ABBA blocks of rounds,
# every batch at least 20 ms), and the asserted effect is the median over blocks of the PAIRED
# difference, in nanoseconds. A process-level shift moves both arms and cancels.
#
# The answer that falls out is a small POSITIVE constant at the two smallest populations, where it
# does not grow while the four-tree copy nearly triples. That is what one leaf at height 30
# predicts. At 1,000 and 10,000 leaves NO claim is made and none is asserted; what is asserted
# instead is the condition that licenses the claim where it IS made, namely that the sign replicates
# in both halves of the run. An earlier version asserted that the SIGN of the
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

# ONE benchmark binary holds BOTH trees: each tree contributes an arm object (the benchmark source
# compiled against that tree's headers, linked with that tree's libraries, every symbol but its entry
# points made local) and a driver measures the two against each other in one process. See the
# header of the benchmark source and lib_m15_shapes.sh for why.
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
  # The arm object goes BEFORE the build, so the one found afterwards is one this run produced. The
  # build writes to a fixed path that outlives every run: when a compile fails the previous run's
  # object is still sitting there, linked against libraries that have since been rebuilt, and every
  # number below would be read off it.
  rm -f "$(m15_arm_object "$t" "$arm")"
  m15_build_bench_arm "$t" "$arm"
  M15_BENCH_CC_RC=$?
  # `m15_build_bench_arm` sends every word of its own diagnosis — the `### bench_cc_rc=` line,
  # `### no static libraries in`, `### no liblmdb.a under`, the compile-database error, and the
  # whole of clang's stderr — to `$tree/m15-bench.log`, and the artefact step collects
  # `m15-work/*.txt`, not this. So the tail is printed on failure: run 34160613484 reported
  # `expected [0], got [90]` with no compiler output anywhere, and 90 is ambiguous besides.
  assert_eq "$arm: the benchmark arm compiled and linked against that tree" "0" "$M15_BENCH_CC_RC"
  [ "$M15_BENCH_CC_RC" -eq 0 ] || note "$arm: arm build rc=$M15_BENCH_CC_RC; tail of $t/m15-bench.log:
$(tail -30 "$t/m15-bench.log" 2>/dev/null || echo '(the log does not exist — the devshell wrapper never ran the script)')"
  assert_file "$arm: and its arm object is there, built by this run" "$(m15_arm_object "$t" "$arm")"
done
# Nothing below is measured unless BOTH arms came out of this run's compile. A timing section run
# against whatever an earlier run left behind would print its numbers and pass its bounds while
# saying nothing about the trees prepared above.
if [ ! -f "$(m15_arm_object "$BASE_TREE" base)" ] || [ ! -f "$(m15_arm_object "$EXT_TREE" ext)" ]; then
  fail "an arm object was not built by this run, so nothing was measured"
  finish
fi
# The two arms are not the same program, which is what makes comparing them a comparison. This
# campaign has already had one check that compared a binary with itself.
assert_false "the two arms' objects differ" \
  cmp -s "$(m15_arm_object "$BASE_TREE" base)" "$(m15_arm_object "$EXT_TREE" ext)"
# What makes two builds of one class safe in one program: each arm exports its own entry points and
# nothing else, so no definition of one tree can be resolved against the other's.
assert_eq "the four-tree arm exports nothing but its own entry points" "0" \
  "$(m15_arm_leaked_globals "$(m15_arm_object "$BASE_TREE" base)" base)"
assert_eq "and neither does the five-tree arm" "0" \
  "$(m15_arm_leaked_globals "$(m15_arm_object "$EXT_TREE" ext)" ext)"

rm -f "$(m15_bench_bin)"
m15_link_bench "$BASE_TREE" "$EXT_TREE"
M15_BENCH_LINK_RC=$?
assert_eq "the driver compiled and linked with both arms into one program" "0" "$M15_BENCH_LINK_RC"
[ "$M15_BENCH_LINK_RC" -eq 0 ] || note "link rc=$M15_BENCH_LINK_RC; tail of $EXT_TREE/m15-bench-link.log:
$(tail -30 "$EXT_TREE/m15-bench-link.log" 2>/dev/null || echo '(the log does not exist)')"
assert_file "and that program is there, built by this run" "$(m15_bench_bin)"
[ -x "$(m15_bench_bin)" ] || { fail "the benchmark program was not built by this run, so nothing was measured"; finish; }

# ---------------------------------------------------------------------------
# 3. Run it once, and require that it ran.
# ---------------------------------------------------------------------------
# ONE PROCESS, BOTH TREES, ONE CORE, ALTERNATING BATCHES. The previous design ran four processes
# (base, ext, ext, base) and compared them, and it asserted a ~1 us effect between processes that
# differ from their own partners by 15-30 us on a shared runner (core, frequency and heap placement
# are properties of a PROCESS, and no batching inside a process removes a shift that every batch of
# it shares). The program now measures the two arms against each other in the same process, from
# the same heap, pinned to the CPU it started on, in ABBA blocks of rounds (the order of the arms is
# swapped each round). A shift of the whole process moves both arms and cancels in the paired
# difference; what is asserted below is the median of those paired differences, in nanoseconds.
#
# WHY THE ARMS WERE SEPARATE PROCESSES BEFORE, AND WHAT STANDS IN THEIR PLACE. The earlier text gave
# two reasons: arm must not be confounded with LAUNCH ORDER (cold page cache, fresh allocator), and
# the arms have separate heaps. Both are about a process's first-touch and placement effects. Inside
# one process they are handled directly: launch order is replaced by the batch order inside a round,
# which alternates and cancels inside each ABBA block (its size is reported as `order_gap`); the
# first-touch cost is paid by discarded warm-up batches; and for the populations where the effect is
# asserted both databases are REBUILT in every round, so allocator placement is drawn again each
# round instead of being one bias the whole run carries. A reason that survives is that the two
# trees' symbols collide, which the arm objects' local symbols and dissolved COMDAT groups answer.
REPS="${M15_BENCH_REPS:-96}"
BENCH_OUT="$M15_WORK/checkpoint-pair.txt"
m15_run_bench "$BENCH_OUT" "$REPS"
assert_eq "the one-process benchmark exited 0" "0" "$?"
assert_eq "it ran to the end" "1" "$(m15_bkey "$BENCH_OUT" bench_complete)"
assert_ge "and produced its key=value lines" 100 "$(grep -c '=' "$BENCH_OUT" || true)"
# The BENCHMARK's own stderr, not the shell's. `nix develop` writes its own chatter there — an
# eval-cache "error (ignored): SQLite database ... is busy" turned up on one run — and a check
# that required an empty file would be asserting something about nix. The benchmark writes
# exactly one shape of line, `world_state_checkpoint_bench: <what>`, and only on failure, so that
# is the needle and it comes from the program rather than from the environment around it.
assert_eq "the benchmark itself reported nothing on stderr" "0" \
  "$(grep -c '^world_state_checkpoint_bench:' "$BENCH_OUT.err" || true)"
# Both arms are in the one file, under their own prefix. The accessors are named for what they read,
# so an arm cannot be confused for the other at a call site.
base_key() { m15_bkey "$BENCH_OUT" "base.$1"; }
ext_key() { m15_bkey "$BENCH_OUT" "ext.$1"; }
pair_key() { m15_bkey "$BENCH_OUT" "pair.$1"; }
assert_eq "the four-tree arm reports the archive absent" "0" "$(base_key bench.archive_present)"
assert_eq "the five-tree arm reports it present" "1" "$(ext_key bench.archive_present)"
assert_eq "both prefill the nullifier tree with 128" "128 128" \
  "$(base_key bench.nullifier_prefill) $(ext_key bench.nullifier_prefill)"
assert_eq "both populated the note-hash tree to 1000 at the largest point" "1000 1000" \
  "$(base_key final.note_hash_tree.size) $(ext_key final.note_hash_tree.size)"
assert_eq "and the nullifier tree to 128 prefill plus 1000 inserted" "1128 1128" \
  "$(base_key final.nullifier_tree.size) $(ext_key final.nullifier_tree.size)"
# The design is reported by the program and checked here rather than trusted: an even number of ABBA
# blocks, so each half of the run has the same size, and batches of at least 20 ms.
BENCH_ROUNDS="$(m15_bkey "$BENCH_OUT" bench.rounds)"
assert_true "the run has a whole number of ABBA blocks in each half (rounds=${BENCH_ROUNDS})" \
  test "$((BENCH_ROUNDS % 4))" -eq 0 -a "$BENCH_ROUNDS" -ge 4
assert_eq "batches last at least 20 ms" "20000000" "$(m15_bkey "$BENCH_OUT" bench.batch_ns_min)"
assert_eq "at the populations where the fifth tree is asserted the databases are rebuilt every round" "1 1" \
  "$(pair_key cp.0.fresh_dbs_per_round) $(pair_key cp.100.fresh_dbs_per_round)"
note "design: $(m15_bkey "$BENCH_OUT" bench.design); ${BENCH_ROUNDS} rounds, pinned to cpu $(m15_bkey "$BENCH_OUT" bench.pinned_cpu) (-1: not pinned)"

# ---------------------------------------------------------------------------
# 4. THE COMPLEXITY, from the five-tree arm — the one M15 inherits.
# ---------------------------------------------------------------------------
# ALL TIMINGS BELOW ARE NANOSECONDS (batch means). Every floor that was written in microseconds is
# written here as the same physical size: 1 us is 1000. An earlier attempt converted the unit and
# left three floors at 1, which would have been a thousand-fold loosening.
C0="$(ext_key cp.0.create_ns)"
C100="$(ext_key cp.100.create_ns)"
C1K="$(ext_key cp.1000.create_ns)"
C10K="$(ext_key cp.10000.create_ns)"
R0="$(ext_key cp.1000.revert_ns)"
M0="$(ext_key cp.1000.commit_ns)"
note "create_checkpoint ns at population 0/100/1000/10000: $C0 / $C100 / $C1K / $C10K"
note "at population 1000: create $C1K, commit $M0, revert $R0"
for v in "$C0" "$C100" "$C1K" "$C10K" "$R0" "$M0"; do
  case "$v" in ''|*[!0-9]*) die "the benchmark did not report a numeric timing (got '$v')" ;; esac
done
# A SIGNED number, for the paired differences: the sign is the claim, so it must be readable.
num_or_die() { # <what> <value>
  case "$2" in ''|-|*[!0-9-]*|?*-*) die "$1 came back non-numeric ('$2')" ;; esac
}

# The FLOOR. An empty transaction's first checkpoint already copies the genesis prefill, so it is
# not free, and that it is not free is the property asserted rather than how much it is.
assert_ge "an empty database's checkpoint is not free — the genesis prefill is already in it (at least 1 us)" \
  1000 "$C0"

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
B100="$(base_key cp.100.create_ns)"
B1K="$(base_key cp.1000.create_ns)"
B10K="$(base_key cp.10000.create_ns)"
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
note "at 10,000 leaves the four-tree arm reports ${B10K}ns and the five-tree arm ${C10K}ns — the arms' absolute times do not agree at that population"

# THE NEGATIVE CASE FOR THE HYPOTHESIS THAT WAS REJECTED. O(changes) predicts a ratio near 100%.
# Stated as its own assertion rather than left implied by the bound above, because "the number was
# big" and "the O(changes) hypothesis is refused" are different sentences and only the second is
# the finding.
assert_true "the O(changes) hypothesis — cost independent of population — is refused by the data" \
  test "$RATIO" -gt 200

# `commit` copies nothing, but it destroys a whole State, so it is not free either — and it is a
# different number from `create`, which is why the benchmark times them apart.
assert_ge "commit is not free either: popping a State destroys four or five hash maps (at least 1 us)" 1000 "$M0"
assert_ge "and revert, which restores one, is not free (at least 1 us)" 1000 "$R0"

# THE NESTED-CALL SHAPE, which is how a transaction actually pays this. Linear in depth is what
# O(state)-per-checkpoint predicts.
N1="$(ext_key nested.d1.ns)"
N4="$(ext_key nested.d4.ns)"
N16="$(ext_key nested.d16.ns)"
for v in "$N1" "$N4" "$N16"; do
  case "$v" in ''|*[!0-9]*) die "the benchmark did not report a numeric nested timing (got '$v')" ;; esac
done
note "a depth-1/4/16 nested-call checkpoint sequence at population 1000: $N1 / $N4 / $N16 ns"
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
# What licenses the claim at 0 and 100 IS asserted: the run is split into a first and a second half
# of its rounds and the paired difference must have the fifth tree slower in BOTH. That condition can
# only fail on a machine too noisy to support the claim, which is the right way round. The mirror
# image — asserting that the instrument IS noisy at 10,000 leaves — would be another check requiring
# its own measurement to come out badly, which is what this section was rebuilt to remove, so it is
# not asserted.
#
# The cross-arm ratio keeps a bound at every population, but it is named for what it is: a guard
# against a measurement that ran away by orders of magnitude, not evidence about the fifth tree.
# ---------------------------------------------------------------------------
B0="$(base_key cp.0.create_ns)"
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
#
# THE EFFECT IS THE PAIRED ONE: the median over ABBA blocks of (five-tree batch mean minus four-tree
# batch mean), both taken in the same process, on the same core, a few tens of milliseconds apart.
# It is NOT the difference of two per-arm medians, which would carry whatever the two sets of
# rounds saw differently.
D0="$(pair_key cp.0.create_diff_ns)"
D100="$(pair_key cp.100.create_diff_ns)"
num_or_die "the population-0 paired difference" "$D0"
num_or_die "the population-100 paired difference" "$D100"
note "the fifth tree's cost, paired in one process: ${D0}ns at population 0 (${B0} -> ${C0} by per-arm medians), ${D100}ns at 100 (${B100} -> ${C100})"
assert_ge "at population 0 the five-tree copy is SLOWER, which is the sign a fifth tree requires (at least 1 us)" \
  1000 "$D0"
assert_ge "and at population 100 as well (at least 1 us)" 1000 "$D100"
# An upper bound with a physical meaning rather than a chosen one: one tree holding a single leaf
# must cost less than the four holding 128 + 128 prefilled leaves between them.
assert_true "the fifth tree costs less than the other four together at population 0 (${D0} < ${B0})" \
  test "$D0" -lt "$B0"
assert_true "and less than them at population 100 (${D100} < ${B100})" test "$D100" -lt "$B100"
# A band, so a constant of a completely different size is a finding rather than a pass. One leaf at
# height 30 is a handful of nodes; tens of microseconds is the scale that predicts, and hundreds
# would mean the archive tree is not what this check thinks it is. 1 us to 40 us.
for d in "$D0" "$D100"; do
  assert_true "and it is a HANDFUL of microseconds (${d}ns), which one leaf at height 30 predicts" \
    test "$d" -ge 1000 -a "$d" -le 40000
done

# AND IT IS A CONSTANT, NOT PART OF THE SLOPE — which is the whole reason it does not change the
# complexity. Between population 0 and 100 the four-tree copy grows by at least half again, because
# 100 more leaves is real work; the fifth tree's contribution does not, because the archive tree
# still holds its one genesis leaf. Both halves are asserted, so "it did not grow" is a statement
# about the delta and not about a measurement that did nothing.
assert_ge "the four-tree copy itself grows between those two populations (${B0} -> ${B100})" \
  "$((B0 * 3 / 2))" "$B100"
assert_true "while the fifth tree's cost does not: ${D0}ns at 0 against ${D100}ns at 100" \
  test "$D100" -le "$((D0 * 3))" -a "$D0" -le "$((D100 * 3))"

# THE LICENCE FOR THE TWO CLAIMS ABOVE: THE DIFFERENCE REPLICATES INSIDE THE EXPERIMENT.
#
# The run's ABBA blocks are split into its FIRST HALF and its SECOND HALF (by round, in time order),
# and the median paired difference is taken over each. The fifth tree must be slower in BOTH. That
# is a replication of the sign within the run rather than a statement about noise, and it is what
# makes the combined figure above a reading rather than a coin toss. What changed against the
# earlier design is what a half IS: it used to be one adjacent pair of whole processes, so a
# process-level shift (core, frequency, heap placement) decided its sign; it is now half of the
# rounds of one process, every one of which pairs the arms on the same core and heap.
#
# What this deliberately is NOT is the mirror-image mistake: an assertion that the instrument IS
# noisy at 1,000 or 10,000 leaves would be another check requiring its own measurement to come out
# badly, which is exactly what this section was rebuilt to remove. Those populations get notes.
HA0="$(pair_key cp.0.create_diff_h1_ns)"
HB0="$(pair_key cp.0.create_diff_h2_ns)"
HA100="$(pair_key cp.100.create_diff_h1_ns)"
HB100="$(pair_key cp.100.create_diff_h2_ns)"
for v in "$HA0" "$HB0" "$HA100" "$HB100"; do num_or_die "a half's paired difference" "$v"; done
note "the two halves of the run, independently: ${HA0}ns and ${HB0}ns at population 0, ${HA100}ns and ${HB100}ns at 100"
assert_ge "population 0, first half of the rounds: the five-tree arm is slower (at least 1 us)" 1000 "$HA0"
assert_ge "population 0, second half of the rounds: still slower (at least 1 us)" 1000 "$HB0"
assert_ge "population 100, first half of the rounds: the five-tree arm is slower (at least 1 us)" 1000 "$HA100"
assert_ge "population 100, second half of the rounds: still slower (at least 1 us)" 1000 "$HB100"

# The noise of the instrument, reported so a reader can see how much of the reading is nuisance: the
# median absolute deviation of the paired block differences, the order effect the ABBA blocks
# cancel, and the extremes. Not asserted, at any population.
note "paired noise (MAD of block differences): $(pair_key cp.0.create_diff_mad_ns)ns at population 0 and $(pair_key cp.100.create_diff_mad_ns)ns at 100, against a fifth-tree cost of ${D0}ns and ${D100}ns; extremes $(pair_key cp.0.create_diff_min_ns)..$(pair_key cp.0.create_diff_max_ns) and $(pair_key cp.100.create_diff_min_ns)..$(pair_key cp.100.create_diff_max_ns); order effect cancelled by the blocks $(pair_key cp.0.create_order_gap_ns)ns and $(pair_key cp.100.create_order_gap_ns)ns"

# AND WHERE NO CLAIM IS MADE, reported so the decision is visible rather than inferred from the
# absence of a row. Nothing below is asserted, on purpose.
note "at 1,000 leaves the arms read ${B1K}ns and ${C1K}ns, paired difference $(pair_key cp.1000.create_diff_ns)ns (MAD $(pair_key cp.1000.create_diff_mad_ns)ns); at 10,000, ${B10K}ns and ${C10K}ns, paired difference $(pair_key cp.10000.create_diff_ns)ns (MAD $(pair_key cp.10000.create_diff_mad_ns)ns)"
note "so this check makes NO claim about the fifth tree at populations 1,000 and 10,000, and asserts none: the two databases are built once and each keeps its own heap placement for the whole run, which at those populations moves the copy by more, and in a direction a fifth tree cannot cause, than the fifth tree costs"

# ---------------------------------------------------------------------------
# 6. The disposition, recorded where a reader will find it.
# ---------------------------------------------------------------------------
assert_file "the boundary write-up exists" "$M15_WRITEUP"
assert_true "it records the checkpoint cost as an UPSTREAM optimisation, not a rewrite" \
  grep -q 'upstream optimisation with independent merit' "$M15_WRITEUP"
assert_true "it names the deep copy as the cause" \
  grep -q 'std::stack<State>' "$M15_WRITEUP"
# The ratio is read out of the sentence that states it, as the number it is, and held to the same
# band this check holds the measurement to. A search for the word "ratio" anywhere in the document
# is satisfied by a write-up that has replaced every figure with an adjective.
WRITEUP_RATIOS="$(tr '\n' ' ' <"$M15_WRITEUP" \
  | sed -nE 's/.*A ten-fold population costs \*\*([0-9]+\.[0-9])x\*\* more per `create_checkpoint`.* growth at \*\*([0-9]+\.[0-9])x\*\*.*/\1 \2/p')"
assert_true "and it carries the measured ratio rather than an adjective: two decade ratios, as numbers ($WRITEUP_RATIOS)" \
  str_has_re "$WRITEUP_RATIOS" '^[0-9]+\.[0-9] [0-9]+\.[0-9]$'
for wr in $WRITEUP_RATIOS; do
  assert_true "the recorded ratio ${wr}x is inside the band this check measures against, 4x to 100x" \
    awk -v r="$wr" 'BEGIN { exit !(r >= 4.0 && r <= 100.0) }'
done

finish
