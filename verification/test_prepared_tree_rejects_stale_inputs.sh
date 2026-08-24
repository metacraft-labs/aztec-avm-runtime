#!/usr/bin/env bash
# test_prepared_tree_rejects_stale_inputs
#
# THE HARNESS'S OWN CACHE, held to the rule every other check in this campaign is held to:
# a check must not depend on state it did not produce.
#
# `m6_prepare_tree` materialises `$M6_WORK/<name>` as a worktree of the pinned anchor with a
# named list of patch files applied in order, and every milestone from M6 on gets its trees
# from it. Until M15 it reused ANY directory with a `.git` in it and asserted only the COMMIT
# COUNT. A work directory carrying an OLDER REVISION of the same patch file has the same
# count, so it was reused, and every number taken out of it was a number about a source tree
# nobody had asked for.
#
# That is not hypothetical and it was not one directory. Probed across the campaign's DEFAULT
# work directories at the moment this check was written, SEVEN prepared trees disagreed with
# the patch files that name them:
#
#   aztec-m7-vm2-tests/avm7, aztec-m8-differential/avm8,
#   aztec-m9-observer/{m9,m9ref,m9nohoist}   commit 4, the AVM_WASM cmake patch
#   aztec-m12-reactor/m12                    commit 9, M12's own AVM_REACTOR overlay
#   aztec-m14-archive/m14                    commit 1, M14's own world_state_reference patch
#
# The first five differ only by a COMMENT that M10's review corrected in
# `barretenberg/cpp/src/CMakeLists.txt` — the `src/` one; `barretenberg/cpp/CMakeLists.txt` is a
# different, real file that carries `option(AVM_WASM …)`, and this header named it for two
# revisions. Those milestones' numbers stand, and by artefact rather than by argument: the merged
# wasm built before and after the comment change is byte-identical. The M12 one is the
# stale overlay that turned M12 red in the M14 sweep. The M14 one is the pre-review revision
# of M14's own patch, which is material. A mechanism that cannot tell the first case from the
# third is the defect; that the first case happened to be harmless is luck.
#
# WHAT THIS CHECK DOES. It drives the real `m6_prepare_tree` — the same function the
# milestones call, not a copy of it — over a git repository it creates itself, with patch
# files it writes itself. Real `git worktree`, real `git am`, real `git patch-id`, real
# filesystem; nothing is mocked. The anchor is a scratch repository rather than
# aztec-packages only because checking out that tree six times would cost minutes to
# demonstrate a property of six lines of shell. The patch stacks of the REAL fork are then
# asserted separately, at the bottom, against the real files.
#
# THE CONJUNCTION IS DISCRIMINATED PER CONJUNCT. The identity being asserted is an ORDERED
# LIST, so a check that mutates only the last patch would pass with a comparison that looked
# at nothing but the last patch. Every position in a three-patch stack is mutated in turn and
# the diagnostic must name THAT position and THAT file.
#
# AND THE POSITIVE CASE IS ASSERTED, because the cheap way to pass the negative ones is to
# rebuild unconditionally — which would make every milestone rebuild from scratch on every
# run. A sentinel file written into the tree must SURVIVE a preparation with unchanged inputs
# and must be GONE after one with changed inputs. That is the difference between reuse and
# re-creation, observed rather than reported.

set -uo pipefail
TEST_NAME=test_prepared_tree_rejects_stale_inputs
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

SCRATCH="${TREE_FRESHNESS_WORK:-$HOME/.cache/aztec-m15-tree-freshness}"
rm -rf "$SCRATCH"
require_work_dir "$SCRATCH" 1

# ---------------------------------------------------------------------------
# A scratch anchor repository and three patch files against it.
# ---------------------------------------------------------------------------
ANCHOR="$SCRATCH/anchor"
mkdir -p "$ANCHOR"
git -C "$ANCHOR" init -q -b main
git -C "$ANCHOR" config user.email m15@example.invalid
git -C "$ANCHOR" config user.name  "M15 freshness probe"
mkdir -p "$ANCHOR/barretenberg/cpp"
printf 'anchor\n' >"$ANCHOR/barretenberg/cpp/CMakeLists.txt"
git -C "$ANCHOR" add -A >/dev/null
git -C "$ANCHOR" commit -qm "anchor"
BASE_SHA="$(git -C "$ANCHOR" rev-parse HEAD)"
assert_eq "the scratch anchor is one commit" "1" \
  "$(git -C "$ANCHOR" rev-list --count HEAD)"

# The three patches are produced by committing on a branch and running `format-patch`, so they
# are the same shape as the campaign's own prepared patches rather than hand-written diffs.
# Each touches its OWN file: revising one must be observable as a stale tree and not as an
# `git am` conflict in the next one, or the negative cases below would be testing `am` rather
# than the identity comparison.
git -C "$ANCHOR" checkout -q -b stack
for i in 1 2 3; do
  printf 'patch %s content\n' "$i" >"$ANCHOR/barretenberg/cpp/file$i.txt"
  git -C "$ANCHOR" add -A >/dev/null
  git -C "$ANCHOR" commit -qm "feat: change number $i"
done
PATCHDIR="$SCRATCH/patches"
mkdir -p "$PATCHDIR"
git -C "$ANCHOR" format-patch -q -3 -o "$PATCHDIR" >/dev/null
git -C "$ANCHOR" checkout -q main
git -C "$ANCHOR" branch -qD stack
P1="$PATCHDIR/0001-feat-change-number-1.patch"
P2="$PATCHDIR/0002-feat-change-number-2.patch"
P3="$PATCHDIR/0003-feat-change-number-3.patch"
for p in "$P1" "$P2" "$P3"; do
  assert_file "the scratch stack produced $(basename "$p")" "$p"
done

# The harness under test, with its anchor pointed at the scratch repository. This is the real
# function: lib_avm_wasm.sh is sourced, not reimplemented.
export M6_WORK="$SCRATCH/work"
. "$VERIFY_DIR/lib_avm_wasm.sh"
FORK_ROOT="$ANCHOR"
M6_BASE_REV="$BASE_SHA"
M6_WORK="$SCRATCH/work"
mkdir -p "$M6_WORK"

# ---------------------------------------------------------------------------
# The identity itself, before anything is prepared: three files, three DISTINCT ids, each a
# 40-character hex string. Asserted rather than assumed, because `git patch-id` prints nothing
# and exits 0 on input it cannot parse — and an empty list compares equal to an empty list.
# ---------------------------------------------------------------------------
IDS="$(m6_patch_ids_of_files "$P1" "$P2" "$P3")"
assert_eq "the three patch files yield three patch-ids" "3" "$(printf '%s\n' "$IDS" | grep -c .)"
assert_eq "and the three are distinct" "3" "$(printf '%s\n' "$IDS" | sort -u | grep -c .)"
assert_eq "each is a 40-character hex patch-id" "3" \
  "$(printf '%s\n' "$IDS" | grep -c '^[0-9a-f]\{40\}$')"

# ---------------------------------------------------------------------------
# Preparation from nothing, and the sentinel that will tell reuse from re-creation apart.
# ---------------------------------------------------------------------------
OUT="$SCRATCH/out"; ERR="$SCRATCH/err"
m6_prepare_tree stack "$P1" "$P2" "$P3" >"$OUT" 2>"$ERR"
rc=$?
assert_eq "a tree prepares from nothing" "0" "$rc"
TREE="$(cat "$OUT")"
assert_eq "it reports the directory it prepared" "$M6_WORK/stack" "$TREE"
assert_dir "and the worktree is there" "$TREE"
assert_eq "the fresh preparation is not a rebuild" "0" "$M6_TREE_REBUILT"
assert_eq "the tree is the anchor plus exactly three commits" "3" \
  "$(git -C "$TREE" rev-list --count "$BASE_SHA..HEAD")"
assert_eq "and its patch-ids are the files' patch-ids, in order" "$IDS" \
  "$(m6_patch_ids_of_tree "$TREE")"

SENTINEL="$TREE/.m15-sentinel"
printf 'a build directory would live here\n' >"$SENTINEL"
assert_file "a sentinel stands in for the build directories a reused tree keeps" "$SENTINEL"

# ---------------------------------------------------------------------------
# THE POSITIVE CASE. Unchanged inputs must REUSE — no rebuild, sentinel intact. Without this,
# the negative cases below are satisfied by a function that rebuilds every time, which would
# make every milestone in the campaign pay a from-scratch build on every run.
# ---------------------------------------------------------------------------
m6_prepare_tree stack "$P1" "$P2" "$P3" >"$OUT" 2>"$ERR"
assert_eq "preparing again with the same inputs succeeds" "0" "$?"
assert_eq "and does NOT rebuild" "0" "$M6_TREE_REBUILT"
assert_file "so the sentinel — and a real tree's build directories — survive" "$SENTINEL"
assert_eq "the reuse path printed no staleness diagnostic" "0" \
  "$(grep -c 'is stale' "$ERR" || true)"

# ---------------------------------------------------------------------------
# THE NEGATIVE CASES, ONE PER POSITION. The identity is an ordered list; a comparison that
# looked only at the last element, or only at the count, or only at HEAD, would pass some of
# these and fail others. Each mutation is a REVISION of one patch file — the shape the real
# failure took: same commit, same subject, same count, different content.
# ---------------------------------------------------------------------------
mutate() { # <src> <dst> — a revised patch: one added line inside the hunk's context is not
           # possible without re-generating, so the change is to the added CONTENT, which is
           # what a re-authored patch does and what patch-id is defined over.
  sed 's/^+patch \([0-9]\) content$/+patch \1 content REVISED/' "$1" >"$2"
  cmp -s "$1" "$2" && return 1
  return 0
}

for pos in 1 2 3; do
  MUT="$SCRATCH/mutated-$pos.patch"
  case "$pos" in
    1) src="$P1" ;; 2) src="$P2" ;; 3) src="$P3" ;;
  esac
  assert_true "position $pos: the revised patch file really differs from the original" \
    mutate "$src" "$MUT"
  a="$P1" b="$P2" c="$P3"
  case "$pos" in 1) a="$MUT" ;; 2) b="$MUT" ;; 3) c="$MUT" ;; esac

  # M6_REFUSE_REBUILD observes the DETECTION without paying for the recovery. It runs in a
  # subshell because `die` exits, and the status and the stderr are both asserted: "it exited
  # non-zero" would also be satisfied by a missing binary or a typo in the function.
  ( M6_REFUSE_REBUILD=1 m6_prepare_tree stack "$a" "$b" "$c" ) >"$OUT" 2>"$ERR"
  assert_eq "position $pos: a revised patch is detected, and the tree is not reused" "1" "$?"
  assert_true "position $pos: the diagnostic says the tree is STALE" \
    grep -q "the stack tree at $M6_WORK/stack is STALE" "$ERR"
  assert_true "position $pos: and it names commit $pos specifically" \
    grep -q "its commit $pos has patch-id" "$ERR"
  assert_true "position $pos: naming the file that disagrees, by basename" \
    grep -q "but $(basename "$MUT") has" "$ERR"
  assert_true "position $pos: and both patch-ids, so the reader can act on it" \
    grep -qE 'has patch-id [0-9a-f]{40}, but .* has [0-9a-f]{40}' "$ERR"
  # The position named is the position mutated and NOT another one. Without this the check
  # passes on an implementation that always says "commit 1".
  for other in 1 2 3; do
    [ "$other" = "$pos" ] && continue
    assert_eq "position $pos: it does not name commit $other" "0" \
      "$(grep -c "its commit $other has patch-id" "$ERR" || true)"
  done
  assert_file "position $pos: refusing left the tree alone — the sentinel is untouched" "$SENTINEL"
done

# ---------------------------------------------------------------------------
# THE COUNT is still asserted, and it is a different failure from the identity. A tree with
# one patch too few has correct ids as far as it goes.
# ---------------------------------------------------------------------------
( M6_REFUSE_REBUILD=1 m6_prepare_tree stack "$P1" "$P2" ) >"$OUT" 2>"$ERR"
assert_eq "a stack of two against a tree of three is refused" "1" "$?"
assert_true "and the diagnostic is about the COUNT, not the ids" \
  grep -q "it is $BASE_SHA + 3 commit(s), expected 2" "$ERR"
assert_eq "so it does not report a patch-id disagreement" "0" \
  "$(grep -c 'has patch-id' "$ERR" || true)"

# ---------------------------------------------------------------------------
# An EMPTY patch file. `git patch-id` reads it, prints nothing and exits 0, so a comparison
# built on its output alone would compare an empty list against an empty list and pass. The
# guard is a precondition on the file, and it is exercised.
# ---------------------------------------------------------------------------
: >"$SCRATCH/empty.patch"
( m6_prepare_tree stack "$P1" "$P2" "$SCRATCH/empty.patch" ) >"$OUT" 2>"$ERR"
assert_eq "an empty patch file is refused before any comparison" "1" "$?"
assert_true "naming it as empty rather than as a mismatch" \
  grep -q "prepared patch is empty: $SCRATCH/empty.patch" "$ERR"
assert_eq "and no staleness comparison was reached" "0" "$(grep -c 'is stale\|is STALE' "$ERR" || true)"

# ---------------------------------------------------------------------------
# THE RECOVERY. Without M6_REFUSE_REBUILD the stale tree is RE-CREATED, and that is observed
# three ways: the rebuild flag, the sentinel's disappearance, and the resulting ids.
# ---------------------------------------------------------------------------
MUT="$SCRATCH/mutated-2.patch"
m6_prepare_tree stack "$P1" "$MUT" "$P3" >"$OUT" 2>"$ERR"
assert_eq "a stale tree is recovered rather than reported" "0" "$?"
assert_eq "the function says it rebuilt" "1" "$M6_TREE_REBUILT"
assert_true "the rebuild announced itself on stderr" grep -q 'is stale' "$ERR"
assert_false "the sentinel is gone, so the tree was re-created and not patched in place" \
  test -f "$SENTINEL"
assert_eq "and the rebuilt tree's patch-ids are the ones asked for" \
  "$(m6_patch_ids_of_files "$P1" "$MUT" "$P3")" "$(m6_patch_ids_of_tree "$TREE")"
assert_eq "which is NOT the id list it had before" "1" \
  "$( [ "$(m6_patch_ids_of_tree "$TREE")" = "$IDS" ] && echo 0 || echo 1 )"

# Restoring the original stack rebuilds once more and lands exactly back on the original ids.
m6_prepare_tree stack "$P1" "$P2" "$P3" >"$OUT" 2>"$ERR"
assert_eq "and going back to the original stack rebuilds again" "1" "$M6_TREE_REBUILT"
assert_eq "landing on the original three ids" "$IDS" "$(m6_patch_ids_of_tree "$TREE")"

# ---------------------------------------------------------------------------
# THE REAL PATCH STACKS. Everything above is about the mechanism. This is about the campaign's
# own files: each declared stack must yield as many distinct 40-hex ids as it has patches, so
# a mis-declared or duplicated entry is caught here rather than by a milestone twenty minutes
# into a build.
# ---------------------------------------------------------------------------
# The paths come from the libraries that declare them, read in a subshell whose work
# directories point at this check's scratch area, so nothing here restates a path that a
# library owns and nothing here touches a milestone's evidence.
STACKS="$SCRATCH/stacks"
(
  export M12_WORK="$SCRATCH/libwork-m12" M14_WORK="$SCRATCH/libwork-m14" M6_WORK="$SCRATCH/libwork-m6"
  export TEST_NAME=test_prepared_tree_rejects_stale_inputs
  . "$VERIFY_DIR/lib.sh"
  . "$VERIFY_DIR/lib_m12_reactor.sh"
  . "$VERIFY_DIR/lib_m14_world_state.sh"
  printf 'M7\t%s\n'  "$M6_PATCH_1 $M6_PATCH_2 $M6_PATCH_3 $M6_PATCH_4 $M7_PATCH_5"
  printf 'M9\t%s\n'  "$M6_PATCH_1 $M6_PATCH_2 $M6_PATCH_3 $M6_PATCH_4 $M9_OBSERVER_PATCH $M7_PATCH_5 $M8_PATCH_6 $M9_PATCH_7"
  printf 'M12\t%s\n' "$M6_PATCH_1 $M6_PATCH_2 $M6_PATCH_3 $M6_PATCH_4 $M9_OBSERVER_PATCH $M7_PATCH_5 $M8_PATCH_6 $M9_PATCH_7 $M12_PATCH_9"
  printf 'M14\t%s\n' "$M14_PATCH"
) >"$STACKS" 2>/dev/null
assert_eq "the four declared patch stacks were read from the libraries that own them" "4" \
  "$(grep -c . "$STACKS" || true)"
stack_of() { awk -F'\t' -v n="$1" '$1 == n { print $2 }' "$STACKS"; }
declare -a STACK_M7 STACK_M9 STACK_M12 STACK_M14
read -r -a STACK_M7  <<<"$(stack_of M7)"
read -r -a STACK_M9  <<<"$(stack_of M9)"
read -r -a STACK_M12 <<<"$(stack_of M12)"
read -r -a STACK_M14 <<<"$(stack_of M14)"
assert_eq "M7 declares five, M9 eight, M12 nine and M14 one" "5 8 9 1" \
  "${#STACK_M7[@]} ${#STACK_M9[@]} ${#STACK_M12[@]} ${#STACK_M14[@]}"
for f in "${STACK_M12[@]}" "${STACK_M14[@]}"; do
  assert_file "a declared patch file exists" "$f"
done

for name in M7 M9 M12 M14; do
  eval "arr=(\"\${STACK_$name[@]}\")"
  n="${#arr[@]}"
  ids="$(m6_patch_ids_of_files "${arr[@]}")"
  assert_eq "the real $name stack is $n patch files with $n patch-ids" "$n" \
    "$(printf '%s\n' "$ids" | grep -c .)"
  assert_eq "and $n distinct ones — no file is declared twice" "$n" \
    "$(printf '%s\n' "$ids" | sort -u | grep -c .)"
  assert_eq "every one a 40-character hex id" "$n" \
    "$(printf '%s\n' "$ids" | grep -c '^[0-9a-f]\{40\}$')"
done

# M9's eight are the first eight of M12's nine, and M12 adds exactly one. Stated as an
# identity over the id lists rather than over the variable names, because the variable names
# are what a copy-paste error preserves. M7's five are NOT a prefix of M9's — the observer
# patch goes in at position five, ahead of M7's overlay — and that is asserted too, since
# "they nest" is the assumption a reader would otherwise carry into both.
assert_eq "M9's stack is the first eight of M12's" \
  "$(m6_patch_ids_of_files "${STACK_M9[@]}")" \
  "$(m6_patch_ids_of_files "${STACK_M12[@]}" | head -8)"
assert_eq "and M12 adds exactly one id on top" "1" \
  "$(m6_patch_ids_of_files "${STACK_M12[@]}" | tail -1 | grep -c '^[0-9a-f]\{40\}$')"
assert_eq "M7's four series patches are the first four of M9's" \
  "$(m6_patch_ids_of_files "${STACK_M7[@]}" | head -4)" \
  "$(m6_patch_ids_of_files "${STACK_M9[@]}" | head -4)"
assert_true "but M7's FIFTH is not M9's fifth — the observer patch is inserted there" \
  test "$(m6_patch_ids_of_files "${STACK_M7[@]}" | sed -n 5p)" \
       != "$(m6_patch_ids_of_files "${STACK_M9[@]}" | sed -n 5p)"

# ---------------------------------------------------------------------------
# THE OTHER WAY A PREPARED TREE STOPS BEING THE TREE YOU ASKED FOR: someone else is using it.
#
# The freshness mechanism above compares a directory against the patch files that name it. It has
# nothing to say about a SECOND RUN rebuilding that directory while the first is measuring out of
# it, and M15's review found exactly that: two `just verify-m9` trees, four minutes apart, both on
# the default `~/.cache/aztec-m9-observer`, appending to one `bench/native.tsv`. One of them logged
# "required artefact missing: .../build-native-avm/bin/avm_differential" while the other rebuilt
# the tree underneath it, and the timing interval that came out was computed over two runs'
# sessions carrying one set of session ids. It was written up as foreign load on the machine; there
# was none.
#
# `require_work_dir` holds the directory exclusively now, and the four properties that makes useful
# are asserted here against the REAL function, in real processes — a lock nobody has watched refuse
# anything is the "both sides were empty" defect one level down. A CHILD of the holding run is not
# refused; an INDEPENDENT run is, by name and by pid; an ORPHAN that outlives its launcher keeps
# the directory taken, which is the case review actually met; and the kernel frees it when the last
# holder is killed, which is why it is an flock on a file rather than a pid file.
# ---------------------------------------------------------------------------
LOCKDIR="$SCRATCH/lockdir"
mkdir -p "$LOCKDIR"
LOCKLIB="$VERIFY_DIR/lib.sh"
holder="$SCRATCH/lock-holder.sh"
taker="$SCRATCH/lock-taker.sh"
cat >"$holder" <<HOLDER
#!/usr/bin/env bash
set -uo pipefail
TEST_NAME=lock_holder
. "$LOCKLIB"
require_work_dir "\$1" 1
printf 'holder-took-it %s\n' "\$\$"
# A CHILD of this run must not be refused by its own parent: checks invoke the differential
# runner and each other, and the libraries alias four work-directory variables onto one path.
"\$2" "\$1"
printf 'child-rc %s\n' "\$?"
# An ORPHAN that will outlive this process, holding the inherited descriptor. This is the exact
# shape review found: two backgrounded \`just verify-m9\` trees reparented to init, still building
# in a directory their launcher had let go of.
sleep 300 &
printf '%s\n' "\$!" >"\$3"
# \`exec\` rather than a plain \`sleep\`: it REPLACES this process, so the pid the test kills is the
# pid holding the lock. A child \`sleep\` would hold the inherited descriptor after its parent died
# and the release below would be testing the wrong thing.
exec sleep 300
HOLDER
cat >"$taker" <<TAKER
#!/usr/bin/env bash
set -uo pipefail
TEST_NAME=lock_taker
. "$LOCKLIB"
require_work_dir "\$1" 1
printf 'taker-took-it %s\n' "\$\$"
TAKER
chmod +x "$holder" "$taker"
( "$holder" "$LOCKDIR" "$taker" "$SCRATCH/orphan.pid" >"$SCRATCH/holder.out" 2>"$SCRATCH/holder.err" & echo $! >"$SCRATCH/holder.pid" )
HOLDER_PID="$(cat "$SCRATCH/holder.pid")"
# Wait for the holder to have taken it rather than sleeping a guessed interval.
for _ in $(seq 1 100); do
  grep -q 'holder-took-it' "$SCRATCH/holder.out" 2>/dev/null && break
  sleep 0.1
done
assert_true "the first run took the work directory" \
  grep -q 'holder-took-it' "$SCRATCH/holder.out"
assert_file "and the lock file is inside the directory it locks" "$LOCKDIR/.work-dir.lock"
assert_true "with an owner record naming the pid and the check" \
  grep -qE "^pid $HOLDER_PID  check lock_holder  since " "$LOCKDIR/.work-dir.owner"
# The child, which shares the run and must not be refused. Its output is in the holder's file.
for _ in $(seq 1 100); do
  grep -q 'child-rc' "$SCRATCH/holder.out" 2>/dev/null && break
  sleep 0.1
done
assert_true "a CHILD of the holding run is not refused — it is the same run" \
  grep -q 'taker-took-it' "$SCRATCH/holder.out"
assert_true "and it exited 0" grep -q '^child-rc 0$' "$SCRATCH/holder.out"

# An INDEPENDENT run, which is the one that must be refused. `env -u` is what makes it
# independent: the ledger of held directories is exported, and inheriting it is exactly what
# distinguishes a child of this run from somebody else's run.
env -u _WORK_DIR_LOCKS_HELD "$taker" "$LOCKDIR" >"$SCRATCH/taker.out" 2>"$SCRATCH/taker.err"
TAKER_RC=$?
assert_eq "an INDEPENDENT second run is refused, and not with a zero status" "1" "$TAKER_RC"
assert_eq "it took nothing" "0" "$(grep -c 'taker-took-it' "$SCRATCH/taker.out" || true)"
assert_true "the refusal names the directory" \
  grep -q "another run already holds this work directory: $LOCKDIR" "$SCRATCH/taker.err"
assert_true "and names who holds it, by pid and by check" \
  grep -qE "held by: pid $HOLDER_PID  check lock_holder" "$SCRATCH/taker.err"
assert_true "and says what goes wrong when two runs share one, so the reader can act on it" \
  grep -q 'rebuild the tree under each other and append to' "$SCRATCH/taker.err"

# THE ORPHAN PROPERTY, which is the one that matters for what review found. The lock is held by
# every process that inherited the descriptor, not by the launcher, so killing the shell that
# started a run does NOT hand the directory to the next one while its build is still going. Assert
# it: the holder is killed, an orphaned `sleep` it left behind is not, and the directory stays
# taken.
lock_wait_gone() { # <pid>
  local _
  for _ in $(seq 1 100); do
    kill -0 "$1" 2>/dev/null || return 0
    sleep 0.1
  done
  return 1
}
# Waited for rather than assumed: the holder writes the pid a moment after it prints `child-rc`,
# and a check that raced it would report "no orphan" as a property of the lock.
for _ in $(seq 1 100); do
  [ -s "$SCRATCH/orphan.pid" ] && break
  sleep 0.1
done
ORPHAN_PID="$(cat "$SCRATCH/orphan.pid" 2>/dev/null || true)"
assert_true "the holding run left an orphan behind, as a backgrounded build does" \
  test -n "$ORPHAN_PID"
kill -9 "$HOLDER_PID" 2>/dev/null
assert_true "the holder is gone" lock_wait_gone "$HOLDER_PID"
assert_true "the orphan is still alive" kill -0 "$ORPHAN_PID"
env -u _WORK_DIR_LOCKS_HELD "$taker" "$LOCKDIR" >"$SCRATCH/taker2.out" 2>"$SCRATCH/taker2.err"
assert_eq "and the directory is STILL taken, because the orphan inherited the descriptor" "1" "$?"
assert_eq "so the next run still takes nothing" "0" \
  "$(grep -c 'taker-took-it' "$SCRATCH/taker2.out" || true)"

# AND IT IS RELEASED BY THE KERNEL once the last holder is gone, not by a cleanup path — which is
# the reason it is an flock on a file rather than a pid file. Both processes were KILLED, so no
# exit handler of either ran.
kill -9 "$ORPHAN_PID" 2>/dev/null
assert_true "the orphan is gone too" lock_wait_gone "$ORPHAN_PID"
env -u _WORK_DIR_LOCKS_HELD "$taker" "$LOCKDIR" >"$SCRATCH/taker3.out" 2>"$SCRATCH/taker3.err"
assert_eq "with the last holder gone the directory is free again — no stale lock file survives a kill" \
  "0" "$?"
assert_true "and the next run takes it" grep -q 'taker-took-it' "$SCRATCH/taker3.out"
assert_file "even though the lock file itself is still there" "$LOCKDIR/.work-dir.lock"

rm -rf "$SCRATCH"
finish
