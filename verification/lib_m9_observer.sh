#!/usr/bin/env bash
# Shared machinery for the M9 checks — the per-instruction execution observer and its upstream patch.
#
# WHAT M9 MEASURES, AND WHAT IT DOES NOT.
#
# The observer patch is prepared, not ours to accept on sight. M3, M4, M5 and M6 each verified a
# prepared patch BY EXECUTION rather than by reading it, and each found something; this does the
# same. Five worktrees of the fork, because every claim M9 makes is a comparison between two of
# them:
#
#   m9         233d8e0993 + the four AVM_WASM series patches + THE OBSERVER PATCH + M7's
#              AVM_SIM_TESTS overlay + M8's AVM_DIFFERENTIAL overlay + M9's driver overlay.
#              Built for wasm32-wasip1 AND for x86-64; both build `avm_differential`, whose
#              M9 modes are `steps`, `events`, `bench` and `benchsteps`.
#   m9ref      the same MINUS the observer patch. The driver source is byte-identical: it guards
#              its use of the new API on `__has_include` of the interface header, so one source
#              compiles in both trees. This is the unpatched half of the
#              disabled-costs-nothing comparison, and it is the tree the prepared verify.sh
#              asked for with AZTEC_REF and printed SKIPPED without.
#   m9nohoist  m9 plus ONE commit that moves the observer call back INSIDE the try block, i.e.
#              the hook without the hoist the patch performs. The control for
#              test_observer_fires_on_exceptional_halt: with it, `burn` records 38,902 of its
#              38,903 instructions and `oob` 2 of its 3, while the six programs that halt
#              normally are unaffected.
#   m9up       233d8e0993 + THE OBSERVER PATCH ALONE. Upstream's own `default` preset, upstream's
#              own `vm2_tests` target, no overlay of ours anywhere.
#   m9upbase   pristine 233d8e0993, the same target, as the before side of that comparison.
#
# COVERAGE, so that no number from here can be quoted as another milestone's. The step-record
# comparison is EIGHT hand-assembled programs — M8's seven plus `oob` — compared PER RECORD:
# 39,086 records, each carrying context id, pc, opcode, cumulative l2 and da gas and the contract
# address. That is an integration check across two targets and an agreement with upstream's own
# ExecutionEvent seam. It is NOT a breadth claim (M7's 391 upstream tests) and NOT a semantic one
# (M19's 77-comparison oracle).
#
# WHAT THE TIMING NUMBERS ARE AND ARE NOT. "Free when disabled" is an EQUIVALENCE claim, not a
# "the number is small" claim: a 95% CI of the patched-versus-unpatched difference in medians has
# to lie inside +/-2%. A point estimate near zero proves nothing on its own, because a noisy enough
# measurement produces one by accident — and it is NOT asserted that the observed difference is
# smaller than the control's, because across sessions it changes sign. What the control (a
# byte-for-byte copy of the patched binary, run in the same rotation) has to do is pass the SAME
# equivalence test, because a method that cannot resolve two copies of one binary would call
# anything equivalent by widening the interval.
#
# THE UNIT OF REPLICATION IS THE SESSION, and M9's review is why. The first version of this
# measurement bootstrapped over the samples of ONE session, which estimates how precisely that
# session's median is known and not the quantity being claimed. Six runs of it over the same two
# binaries produced mutually disjoint "95% intervals" spanning -1.03% to +1.48%, and the check
# failed on a correct tree.
#
# The nuisance behind that is now identified rather than guessed at. Probed directly, twelve
# sessions each, same three binaries, same rotation:
#
#   the three files copied once and reused    observed sd 0.22pp   same-bytes control sd 0.39pp
#   the three files RE-COPIED per session     observed sd 1.33pp   same-bytes control sd 1.50pp
#
# The control compares two copies of the same bytes, so all of its spread is nuisance — and a copy
# multiplies it by about four. What varies is where a file's pages physically land: fixed for a
# given file, re-drawn by a copy, invisible to a bootstrap over one session's samples, and re-drawn
# by every fresh run of the check (which copies the control, and on a cold run rebuilds both
# binaries). That is precisely the between-session variance the old interval could not see.
#
# So m9_bench_sessions re-copies ALL THREE arms at the start of every session — symmetrically, and
# rotating which is written first — and _timing_compare.py takes one point estimate per session and
# puts the interval over those. What that does NOT randomise is the link-time code layout of each
# build, which is fixed by the build: the bound is on the patch TOGETHER WITH the incidental layout
# change it causes, which is what a user of the patched build experiences but is not the cost of
# the branch alone.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, a runtime that
# is missing or a transcript with no lines in it is `die` or a failed assertion, never a printed
# SKIP. That rule is this milestone's own subject: the prepared
# upstream-bugs/aztec-execution-observer-hook/verify.sh shipped with a SKIPPED branch that exited 0.
#
# Not to be executed directly: sourced by verification/verify_*.sh and test_*.sh, AFTER lib.sh.

# Measured on 32 cores: 5.5 GB under $M9_WORK, of which the two upstream trees are 1.5 GB each
# because upstream's own native `vm2_tests` is 264 MB and the proving stack behind it is most of
# the rest, and about 0.5 GB is the per-session copies of the three timed arms (see
# m9_bench_sessions — they are kept until the run ends rather than deleted as it goes, because
# freeing them would let the next session's copy land on the pages just released and the whole
# point of the copy is that it is an independent draw). Plus about 1.1 GB in ~/.bb-crs, which
# fourteen of upstream's own tests need and which `barretenberg/crs/bootstrap.sh` downloads once.
# /tmp is usually a tmpfs and is the wrong place, so this defaults under $HOME; require_work_dir
# below turns "the work directory filled up" into one precondition failure rather than into a run
# of wrong answers.
M9_WORK="${M9_WORK:-$HOME/.cache/aztec-m9-observer}"
require_work_dir "$M9_WORK" 8

# ---------------------------------------------------------------------------
# m9_require_idle_machine
#
# The timing check's whole claim is that a difference between two binaries is
# smaller than the noise. That claim is only meaningful if the noise it measured
# is the noise the binaries actually ran in. A competing multi-core build is not
# noise this design can absorb: the between-session spread it characterises is
# sd 1.42pp, and a barretenberg build alongside it will exceed that comfortably
# and asymmetrically — whichever arm happens to overlap the busiest minutes takes
# the penalty, and the rotation cannot cancel a load that is not periodic.
#
# It happened: M11's re-run had `just verify-m10` building while `verify-m9`
# timed, and `test_observer_disabled_is_free` reported a failure that was an
# artefact of the box rather than of the patch.
#
# So this is a PRECONDITION and not an assertion, for the same reason
# require_work_dir is: nothing after it can be meaningfully evaluated, and a
# wrong answer is worse than no answer. It gets its OWN exit code, because M9's
# own review already found what happens when a precondition exit collides with a
# check's semantic vocabulary — WORK_DIR_PRECONDITION_EXIT exists because
# run_avm_differential.sh spends 1 on DIVERGENCE.
#
#   0  measured
#   1  an assertion failed
#   3  the machine was too busy to measure on (this)
#
# Two signals, because they fail differently. Competing build processes are exact
# and immediate; load average is coarse and lags by up to a minute, which is
# exactly the window in which a just-finished build still poisons a measurement.
# Either one refuses.
# ---------------------------------------------------------------------------
M9_LOAD_PRECONDITION_EXIT="${M9_LOAD_PRECONDITION_EXIT:-3}"

# It WAITS before it refuses, and that is not a softening. The load this check
# sees at the moment it starts timing is usually its OWN — it has just built two
# drivers with the whole machine, and the 1-minute average is still carrying that
# build when the first simulation would run. A precondition that refuses there is
# a precondition that can never pass, which is how a check gets an --i-mean-it
# flag bolted on and then gets run with it. So it polls for a bounded window and
# fails only if the machine is STILL busy at the end of it; the failure mode it
# exists for — somebody else's build running for the next half hour — outlasts the
# window and is still caught.
M9_IDLE_WAIT="${M9_IDLE_WAIT:-420}"

m9_require_idle_machine() {
  local cores load1 max_load busy self_tree pid waited=0 reason=""
  cores="$(nproc 2>/dev/null || echo 1)"
  # A quarter of the machine. The timed simulations are single-threaded, so this
  # is not "is anything running" — it is "is enough of the machine free that one
  # more single-threaded process is not queueing behind someone else's -j32".
  max_load="${M9_IDLE_MAX_LOAD:-$(awk -v c="$cores" 'BEGIN{v=c/4; if (v<2) v=2; printf "%.2f", v}')}"
  load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"

  # Our own ancestry is excluded by PID: `just`, this shell and the harness are
  # not competitors, and matching them by name would make this refuse to run
  # every time, which is its own kind of useless.
  self_tree=" "
  pid=$$
  while [ -n "$pid" ] && [ "$pid" != "0" ] && [ "$pid" != "1" ]; do
    self_tree="$self_tree$pid "
    pid="$(awk '{print $4}' "/proc/$pid/stat" 2>/dev/null)"
  done

  while : ; do
    busy=""
    for name in ninja cmake cc1plus cc1 clang clang++ ld.lld lld rustc cargo make gcc g++; do
      for p in $(pgrep -x "$name" 2>/dev/null); do
        case "$self_tree" in *" $p "*) continue ;; esac
        busy="$busy $name($p)"
      done
    done
    load1="$(awk '{print $1}' /proc/loadavg 2>/dev/null || echo 0)"

    reason=""
    [ -n "$busy" ] && reason="another build is running:$busy"
    if [ -z "$reason" ] && awk -v l="$load1" -v m="$max_load" 'BEGIN{exit !(l>m)}'; then
      reason="1-minute load average is $load1 on $cores core(s), above the limit of $max_load"
    fi
    [ -z "$reason" ] && break

    if [ "$waited" -ge "$M9_IDLE_WAIT" ]; then
      printf '%s: cannot run: %s\n' "$TEST_NAME" "$reason" >&2
      printf '%s: still busy after %ss. A timing measurement taken beside a competing build is\n' \
        "$TEST_NAME" "$waited" >&2
      printf '%s: not measuring what it claims, so this refuses rather than reporting a number.\n' \
        "$TEST_NAME" >&2
      printf '%s: run it on an idle machine. M9_IDLE_WAIT and M9_IDLE_MAX_LOAD override, and if\n' \
        "$TEST_NAME" >&2
      printf '%s: you use them, the interval this check reports is not the one it documents.\n' \
        "$TEST_NAME" >&2
      exit "$M9_LOAD_PRECONDITION_EXIT"
    fi
    [ "$waited" -eq 0 ] && note "waiting for the machine to go idle before timing: $reason"
    sleep 15
    waited=$((waited + 15))
  done

  note "machine is idle enough to time on: load1 $load1 on $cores core(s), limit $max_load, no competing builds, waited ${waited}s"
}

# M8's helpers keep their own name and their own variable; pointing that variable at M9's directory
# is what keeps the milestones' trees apart. lib_m8_differential.sh does the same for M7_WORK and
# lib_vm2_tests.sh for M6_WORK, so m6_prepare_tree, m6_configure, m6_build, m6_tree_or_die and the
# compile-database readers all operate inside $M9_WORK and cannot touch M6's, M7's or M8's evidence.
M8_WORK="$M9_WORK"
export M8_WORK M9_WORK

# shellcheck source=lib_m8_differential.sh
. "$VERIFY_DIR/lib_m8_differential.sh"

# The prepared patch this milestone verifies. Upstream's fourth; SERIES.md indexes it.
M9_OBSERVER_PATCH="$M6_UPSTREAM_BUGS/aztec-execution-observer-hook/0001-feat-vm2-per-instruction-observation-hook-for-the-fas.patch"
M9_OBSERVER_DIR="$M6_UPSTREAM_BUGS/aztec-execution-observer-hook"

# M9's own overlay: the step/event/timing modes on M8's driver. Ours, a downstream test target.
M9_PATCH_7="$REPO_ROOT/verification/m9/0001-test-vm2-step-records-the-upstream-ExecutionEvent-sea.patch"

M9_TREE_NAME=m9
M9_REF_TREE_NAME=m9ref
M9_NOHOIST_TREE_NAME=m9nohoist
M9_UP_TREE_NAME=m9up
M9_UPBASE_TREE_NAME=m9upbase

M9_WASM_BUILD=build-wasm-avm
M9_NATIVE_BUILD=build-native-avm
M9_UP_BUILD=build-native

# The step corpus as measured. Identities, not floors.
M9_PROGRAMS="add revert loop sha256 poseidon2 storage burn oob"
M9_EXPECTED_PROGRAMS=8
M9_EXPECTED_STEP_RECORDS=39086      # the individual per-instruction records, all eight programs
M9_EXPECTED_ORDINARY_LINES=39189    # every line of the `steps` transcript that is not a `diag`
M9_EXPECTED_EVENT_RECORDS=39086     # the same count from upstream's own ExecutionEvent seam

# Per program: instructions executed, which is also the step-record count.
M9_STEPS_add=4
M9_STEPS_revert=2
M9_STEPS_loop=132
M9_STEPS_sha256=28
M9_STEPS_poseidon2=8
M9_STEPS_storage=6
M9_STEPS_burn=38903
M9_STEPS_oob=3

# What the no-hoist control loses, per program. Zero everywhere except the two programs that halt
# exceptionally, which is what makes the control specific rather than merely different.
M9_NOHOIST_LOSS_burn=1
M9_NOHOIST_LOSS_oob=1

# WireOpCode::LAST_OPCODE_SENTINEL. Deliberately NOT written here as a number: it is derived from
# the fork's own common/opcodes.hpp at the anchor by m9_sentinel_opcode below, because a constant
# restated on our side is a constant that can drift away from upstream's silently.
M9_SENTINEL_OPCODE=

# The budgets. Deliberately NOT the measurements: a budget equal to the measurement fails on any
# change at all and therefore gets raised rather than read.
#
# ENABLED, with all 38,903 `burn` step records materialised into a vector — measured +9.8% on the
# minimum and +10.9% on the median natively, +2.6% / +2.5% on V8 and +1.5% / +1.6% on wasmtime.
# THE MILESTONE'S OWN
# ENTRY SAYS "2.3% native and 2.4% wasm" AND THE NATIVE HALF OF THAT IS WRONG: 2.3% belongs to the
# spike's 16-byte record, and the shipped ExecutionStep is 48 bytes on x86-64, 32 of them the
# contract address. PR.md already said +12%. The wasm figure is confirmed. The native untraced loop
# is about 2.3x faster than the wasm one, so the same absolute per-record store is a much larger
# fraction of it — which is why one number cannot serve for both targets.
M9_ENABLED_BUDGET_NATIVE_PCT="${M9_ENABLED_BUDGET_NATIVE_PCT:-20}"
M9_ENABLED_BUDGET_WASM_PCT="${M9_ENABLED_BUDGET_WASM_PCT:-10}"

# DISABLED. The budget is a bound, and the control below is what gives it meaning.
M9_DISABLED_BUDGET_PCT="${M9_DISABLED_BUDGET_PCT:-2}"

# Peak linear memory of the `steps` run, with every record materialised. M8's untraced run is 173
# pages; this one is 389 under node's WASI host and 400 under wasmtime, and the difference from 173
# is the records — three simulations per program, one of them traced, and the traced result copied
# once so the stripped comparison can be made.
#
# Only the BUDGET is asserted, and the eleven-page gap between the two hosts is the reason. M8
# established that peak linear memory is a function of the host's WASI environment by moving it in
# both directions, and M8's own review recorded pinning that number as an identity as a defect
# ("this check fails on a correct build on a machine whose environment block crosses the page
# boundary the other way"). So no measured page count is written here: the comparator asserts
# monotonicity, the budget, and that the whole-run peak equals the value after the last program.
# Those are properties of the module; the page count is a property of the host.
M9_STEPS_PEAK_PAGE_BUDGET="${M9_STEPS_PEAK_PAGE_BUDGET:-512}"

# How many timed samples the disabled-cost measurement takes, and how they are grouped.
#
# SESSIONS is the number that decides the interval's width, because the session is the unit of
# replication (see above): the standard error falls as 1/sqrt(sessions) while the samples inside a
# session buy almost nothing once the session median has settled. ROUNDS is 3 because that is the
# smallest number that gives each of the three binaries each of the three positions exactly once,
# and REPS is what amortises the ~0.6 s of fixed setup each process pays before its first timed
# simulation.
#
# 32 native sessions is about 4 minutes; the wasm arm costs about 2 s per process launch under
# node, so it takes 12. At the spreads measured on this host (native session-to-session sd 1.3 to
# 1.8pp, V8 0.6 to 1.1pp) that puts the 95% half-width at roughly 0.6pp on native and 0.4pp on V8 —
# comfortably inside the 2% budget without the budget being the measurement, which the comparator
# asserts separately. The count is chosen from that spread rather than from a round number: at 24
# sessions the half-width assertion had only 0.26pp of room, which is a second lottery.
M9_BENCH_SESSIONS="${M9_BENCH_SESSIONS:-32}"
M9_WASM_BENCH_SESSIONS="${M9_WASM_BENCH_SESSIONS:-12}"
M9_BENCH_ROUNDS="${M9_BENCH_ROUNDS:-3}"
M9_BENCH_REPS="${M9_BENCH_REPS:-5}"

M9_STEPS_COMPARE="$VERIFY_DIR/wasm_host/_steps_compare.py"
M9_RECORDS_COMPARE="$VERIFY_DIR/wasm_host/_step_records_compare.py"
M9_TIMING="$VERIFY_DIR/wasm_host/_timing_compare.py"

export M9_OBSERVER_PATCH M9_PATCH_7 M9_TREE_NAME M9_WASM_BUILD M9_NATIVE_BUILD

# ---------------------------------------------------------------------------
# The five trees. Each is 233d8e0993 + exactly the patches named, by `git am` with no -3, and
# m6_prepare_tree asserts the resulting commit count. A command substitution swallows `die`, so
# every one goes through m6_tree_or_die: M6 was bitten by a tree name that came back empty and
# every later `git -C ""` running in the CALLER's repository.
# ---------------------------------------------------------------------------
m9_require_patches() {
  [ -f "$M9_OBSERVER_PATCH" ] || die "the prepared observer patch is missing: $M9_OBSERVER_PATCH"
  [ -f "$M7_PATCH_5" ] || die "M7's overlay patch is missing: $M7_PATCH_5"
  [ -f "$M8_PATCH_6" ] || die "M8's overlay patch is missing: $M8_PATCH_6"
  [ -f "$M9_PATCH_7" ] || die "M9's overlay patch is missing: $M9_PATCH_7"
}

m9_tree() {
  m9_require_patches
  M9_TREE=$(m6_prepare_tree "$M9_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
    "$M9_OBSERVER_PATCH" "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7")
  m6_tree_or_die M9_TREE
  export M9_TREE
  printf '%s\n' "$M9_TREE"
}

# The same tree WITHOUT the observer patch. The overlay patches apply identically because none of
# them touches a file the observer patch touches — which is itself asserted, in
# test_observer_disabled_is_free, rather than assumed here.
m9_ref_tree() {
  m9_require_patches
  M9_REF_TREE=$(m6_prepare_tree "$M9_REF_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
    "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7")
  m6_tree_or_die M9_REF_TREE
  export M9_REF_TREE
  printf '%s\n' "$M9_REF_TREE"
}

# m9 plus the un-hoist mutation. Prepared from a patch under verification/m9/ so it is reproducible
# rather than a hand edit that exists only on one machine.
M9_NOHOIST_PATCH="$REPO_ROOT/verification/m9/0002-control-undo-the-hoist-observe-inside-the-try-block-o.patch"

m9_nohoist_tree() {
  m9_require_patches
  [ -f "$M9_NOHOIST_PATCH" ] || die "the no-hoist control patch is missing: $M9_NOHOIST_PATCH"
  M9_NOHOIST_TREE=$(m6_prepare_tree "$M9_NOHOIST_TREE_NAME" \
    "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
    "$M9_OBSERVER_PATCH" "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7" "$M9_NOHOIST_PATCH")
  m6_tree_or_die M9_NOHOIST_TREE
  export M9_NOHOIST_TREE
  printf '%s\n' "$M9_NOHOIST_TREE"
}

# The observer patch ALONE on the pinned anchor, and the pinned anchor alone. Upstream's own
# preset and upstream's own target, with nothing of ours anywhere in either tree.
m9_upstream_tree() {
  [ -f "$M9_OBSERVER_PATCH" ] || die "the prepared observer patch is missing: $M9_OBSERVER_PATCH"
  M9_UP_TREE=$(m6_prepare_tree "$M9_UP_TREE_NAME" "$M9_OBSERVER_PATCH")
  m6_tree_or_die M9_UP_TREE
  export M9_UP_TREE
  printf '%s\n' "$M9_UP_TREE"
}

m9_upstream_base_tree() {
  M9_UPBASE_TREE=$(m6_prepare_tree "$M9_UPBASE_TREE_NAME")
  m6_tree_or_die M9_UPBASE_TREE
  export M9_UPBASE_TREE
  printf '%s\n' "$M9_UPBASE_TREE"
}

# ---------------------------------------------------------------------------
# Builds. Configure and build return non-zero if EITHER step failed, and callers assert the two
# statuses SEPARATELY: a stale binary from a previous run will happily print a plausible transcript
# over a build that did not happen (M2's defect, M3's lesson).
#
# FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER on every native configure, for the reason M7's build
# check found and M8 repeats: cmake/gtest.cmake declares GTest with FIND_PACKAGE_ARGS, so a native
# configure otherwise prefers whatever find_package(GTest) turns up — on this host the SYSTEM gtest
# under /usr/lib. verify_execution_observer_patch_applies_to_upstream runs a gtest binary on both
# sides of a comparison, so this is not decoration.
# ---------------------------------------------------------------------------
m9_build_wasm() { # <tree>
  local tree="$1"
  m6_configure "$tree" wasm-avm "$M9_WASM_BUILD" -DAVM_DIFFERENTIAL=ON
  M9_WASM_CONFIGURE_RC=$?
  [ "$M9_WASM_CONFIGURE_RC" -eq 0 ] || return "$M9_WASM_CONFIGURE_RC"
  m6_build "$tree" "$M9_WASM_BUILD" avm_differential
  M9_WASM_BUILD_RC=$?
  return "$M9_WASM_BUILD_RC"
}

m9_build_native() { # <tree>
  local tree="$1"
  m6_native_configure "$tree" "$M9_NATIVE_BUILD" -DAVM_DIFFERENTIAL=ON \
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M9_NATIVE_CONFIGURE_RC=$?
  [ "$M9_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M9_NATIVE_CONFIGURE_RC"
  m6_build "$tree" "$M9_NATIVE_BUILD" avm_differential
  M9_NATIVE_BUILD_RC=$?
  return "$M9_NATIVE_BUILD_RC"
}

# Upstream's OWN target, in a tree carrying at most the one patch under review.
m9_build_upstream_vm2_tests() { # <tree>
  local tree="$1"
  m6_native_configure "$tree" "$M9_UP_BUILD" -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M9_UP_CONFIGURE_RC=$?
  [ "$M9_UP_CONFIGURE_RC" -eq 0 ] || return "$M9_UP_CONFIGURE_RC"
  m6_build "$tree" "$M9_UP_BUILD" vm2_tests
  M9_UP_BUILD_RC=$?
  return "$M9_UP_BUILD_RC"
}

m9_wasm_bin()   { printf '%s\n' "$1/barretenberg/cpp/$M9_WASM_BUILD/bin/avm_differential"; }
m9_native_bin() { printf '%s\n' "$1/barretenberg/cpp/$M9_NATIVE_BUILD/bin/avm_differential"; }
m9_up_bin()     { printf '%s\n' "$1/barretenberg/cpp/$M9_UP_BUILD/bin/$2"; }

# ---------------------------------------------------------------------------
# The runners. M8's, with arguments added, and for M8's reason: the AVM logs its own progress on
# fd 2 through `vinfo`, and common/log.cpp sets bb_log_level = VERBOSE unconditionally under
# __wasm__ and INFO otherwise, so the wasm build is chatty on stderr and the native one is silent.
# A merged stream would make the differential a comparison of log levels — M8 measured 231 of 1,308
# positions mismatching against wasmtime and all 1,308 against node. The transcript is stdout,
# exactly; stderr goes to its own file, where test_observer_fires_on_exceptional_halt reads the
# "halted via EXCEPTIONAL_HALT" lines out of it.
# ---------------------------------------------------------------------------
m9_run_native() { # <binary> <out> <err> [args...]
  local bin="$1" out="$2" err="$3"; shift 3
  [ -x "$bin" ] || die "no native binary at $bin — nothing to run"
  m6_in_devshell '
    bin="$1"; t="$2"; err="$3"; shift 3
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    timeout --foreground --preserve-status -s KILL "$t" "$bin" "$@" 2>"$err"
  ' "$bin" "$M7_RUN_TIMEOUT" "$err" "$@" >"$out"
}

# m9_run_native_verbose: the same, with BB_VERBOSE=1.
#
# M8 measured that `common/log.cpp` sets `bb_log_level = LogLevel::VERBOSE` UNCONDITIONALLY under
# `__wasm__` and `LogLevel::INFO` (unless BB_VERBOSE=1) otherwise, so the wasm build narrates its
# own progress on fd 2 and the native build is silent — and left "the logging surface around the
# hook" to this milestone. This runner is how M9 closes it: the asymmetry is established by MOVING
# it, rather than by tolerating an assertion that only holds on one target.
m9_run_native_verbose() { # <binary> <out> <err> [args...]
  local bin="$1" out="$2" err="$3"; shift 3
  [ -x "$bin" ] || die "no native binary at $bin — nothing to run"
  m6_in_devshell '
    bin="$1"; t="$2"; err="$3"; shift 3
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    export BB_VERBOSE=1
    timeout --foreground --preserve-status -s KILL "$t" "$bin" "$@" 2>"$err"
  ' "$bin" "$M7_RUN_TIMEOUT" "$err" "$@" >"$out"
}

m9_run_v8() { # <wasm> <out> <err> [args...]
  local wasm="$1" out="$2" err="$3"; shift 3
  [ -f "$wasm" ] || die "no wasm module at $wasm — nothing to run"
  m6_in_devshell '
    host="$1"; wasm="$2"; t="$3"; err="$4"; shift 4
    timeout --foreground --preserve-status -s KILL "$t" node "$host" "$wasm" "$@" 2>"$err"
  ' "$M7_V8_HOST" "$wasm" "$M7_RUN_TIMEOUT" "$err" "$@" >"$out"
}

m9_run_wasmtime() { # <wasm> <out> <err> [args...]
  local wasm="$1" out="$2" err="$3"; shift 3
  [ -f "$wasm" ] || die "no wasm module at $wasm — nothing to run"
  local limits mn mx merged
  limits="$(python3 "$M7_MEMLIMITS" "$wasm")" || die "could not read the memory import of $wasm"
  mn="$(printf '%s' "$limits" | awk '{print $3}')"
  mx="$(printf '%s' "$limits" | awk '{print $4}')"
  [ -n "$mn" ] && [ -n "$mx" ] || die "unreadable memory limits for $wasm: [$limits]"
  merged="$M9_WORK/$(basename "$(dirname "$(dirname "$wasm")")")-avm_differential.merged.wasm"
  m6_in_devshell '
    wasm="$1"; merged="$2"; mn="$3"; mx="$4"; t="$5"; err="$6"; shift 6
    tmp="$(mktemp -d)"; trap "rm -rf $tmp" EXIT
    printf "(module (memory (export \"memory\") %s %s))\n" "$mn" "$mx" > "$tmp/envmem.wat"
    wat2wasm "$tmp/envmem.wat" -o "$tmp/envmem.wasm" || exit 90
    wasm-merge "$tmp/envmem.wasm" env "$wasm" main -o "$merged" \
      --rename-export-conflicts --enable-bulk-memory --enable-simd \
      --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
      --enable-multivalue --enable-exception-handling --enable-reference-types \
      >/dev/null 2>&1 || exit 91
    timeout --foreground --preserve-status -s KILL "$t" wasmtime run --dir=. "$merged" "$@" 2>"$err"
  ' "$wasm" "$merged" "$mn" "$mx" "$M7_RUN_TIMEOUT" "$err" "$@" >"$out"
}

# ---------------------------------------------------------------------------
# m9_bench_sessions <native|v8> <patched> <unpatched> <dir> <samples.tsv> <inodes.tsv> <sessions>
#
# The disabled-cost measurement, with the SESSION as the unit of replication.
#
# Each session gets its own directory and its own FRESH COPY of all three arms — the patched
# binary, the unpatched one, and a second copy of the patched one as the same-bytes control. The
# copy is not a convenience: it is the re-draw. Where a file's pages physically land is fixed for
# that file and is the largest term in the difference between two builds on this host (measured:
# it multiplies the same-bytes control's session-to-session sd from 0.39pp to 1.50pp), so a
# measurement that reuses one set of files cannot see it and reports an interval two to three times
# narrower than the quantity it claims to cover.
#
# All three arms are copied, not just the control, so the three are treated identically — the old
# measurement compared two build outputs against one copy. The ORDER in which the three are written
# rotates with the session, so the order of allocation cannot systematically favour one arm, and
# the three positions in the timing rotation rotate with the round, so neither can the order they
# are run in.
#
# The inode of every copy is recorded. Three per session, all distinct, is what the caller asserts
# to establish that the sessions really were separate draws rather than one draw counted N times —
# the failure mode that would silently reinstate the defect this design exists to remove.
#
# The whole loop runs inside ONE dev shell: 216 process launches through `nix develop` would spend
# more time on the shell than on the measurement.
# ---------------------------------------------------------------------------
m9_bench_sessions() { # <kind> <patched> <unpatched> <dir> <out> <inodes> <sessions>
  local kind="$1" pat="$2" unp="$3" dir="$4" out="$5" ino="$6" sessions="$7"
  [ -e "$pat" ] || die "m9_bench_sessions: no patched artefact at $pat"
  [ -e "$unp" ] || die "m9_bench_sessions: no unpatched artefact at $unp"
  rm -rf "$dir"; mkdir -p "$dir" || die "m9_bench_sessions: cannot create $dir"
  m6_in_devshell '
    kind="$1"; pat="$2"; unp="$3"; dir="$4"; out="$5"; ino="$6"
    sessions="$7"; rounds="$8"; reps="$9"; shift 9
    hostjs="$1"; tmo="$2"
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    : >"$out"; : >"$ino"
    if [ "$kind" = native ]; then ext=""; else ext=".wasm"; fi
    s=0
    while [ "$s" -lt "$sessions" ]; do
      sd="$dir/s$(printf "%03d" "$s")"
      mkdir -p "$sd" || exit 90
      case $((s % 3)) in
        0) cporder="p u c" ;;
        1) cporder="u c p" ;;
        *) cporder="c p u" ;;
      esac
      for w in $cporder; do
        if [ "$w" = u ]; then src="$unp"; else src="$pat"; fi
        cp "$src" "$sd/arm_$w$ext" || exit 91
      done
      chmod +x "$sd"/arm_* 2>/dev/null
      for w in p u c; do
        printf "%s\t%s\t%s\n" "$s" "$w" "$(stat -c %i "$sd/arm_$w$ext")" >>"$ino"
      done
      r=0
      while [ "$r" -lt "$rounds" ]; do
        case $((r % 3)) in
          0) order="patched:p unpatched:u control:c" ;;
          1) order="unpatched:u control:c patched:p" ;;
          *) order="control:c patched:p unpatched:u" ;;
        esac
        for entry in $order; do
          lbl="${entry%%:*}"; w="${entry#*:}"
          if [ "$kind" = native ]; then
            timeout --foreground --preserve-status -s KILL "$tmo" \
              "$sd/arm_$w$ext" bench burn "$reps" >"$dir/run.out" 2>"$dir/run.err" || exit 92
          else
            timeout --foreground --preserve-status -s KILL "$tmo" \
              node "$hostjs" "$sd/arm_$w$ext" bench burn "$reps" \
              >"$dir/run.out" 2>"$dir/run.err" || exit 92
          fi
          sed -n "s/^bench\.us\.[0-9]* /$s\t$lbl\t/p" "$dir/run.out" >>"$out"
        done
        r=$((r + 1))
      done
      s=$((s + 1))
    done
  ' "$kind" "$pat" "$unp" "$dir" "$out" "$ino" "$sessions" \
    "$M9_BENCH_ROUNDS" "$M9_BENCH_REPS" "$M7_V8_HOST" "$M7_RUN_TIMEOUT" >/dev/null
  local rc=$?
  case "$rc" in
    0) ;;
    90) die "m9_bench_sessions: could not create a session directory under $dir" ;;
    91) die "m9_bench_sessions: could not copy an arm into a session directory under $dir" ;;
    92) die "m9_bench_sessions: a timed run failed — see $dir/run.err" ;;
    *)  die "m9_bench_sessions: the $kind timing loop exited $rc" ;;
  esac
  [ -s "$out" ] || die "m9_bench_sessions: the $kind timing loop produced no samples at all"
}

# ---------------------------------------------------------------------------
# The transcripts. Written by verify_observation_hook_step_records_identical, which is the check
# that BUILDS, and read by everything else, so no two checks can disagree about what was measured.
# ---------------------------------------------------------------------------
m9_steps_native()    { printf '%s\n' "$M9_WORK/native.steps"; }
m9_steps_v8()        { printf '%s\n' "$M9_WORK/wasm-v8.steps"; }
m9_steps_wasmtime()  { printf '%s\n' "$M9_WORK/wasm-wasmtime.steps"; }
m9_events_native()   { printf '%s\n' "$M9_WORK/native.events"; }
m9_events_v8()       { printf '%s\n' "$M9_WORK/wasm-v8.events"; }
m9_nohoist_steps()   { printf '%s\n' "$M9_WORK/nohoist.steps"; }
m9_steps_native_err()   { printf '%s\n' "$M9_WORK/native.steps.err"; }
m9_steps_v8_err()       { printf '%s\n' "$M9_WORK/wasm-v8.steps.err"; }
m9_steps_wasmtime_err() { printf '%s\n' "$M9_WORK/wasm-wasmtime.steps.err"; }
m9_events_native_err()  { printf '%s\n' "$M9_WORK/native.events.err"; }
m9_events_v8_err()      { printf '%s\n' "$M9_WORK/wasm-v8.events.err"; }

# ---------------------------------------------------------------------------
# m9_measured
#
# $M9_WORK/measured.env — the single record of what was built and run, written by
# verify_observation_hook_step_records_identical. Every other M9 check reads it. If it is not there
# that check is RUN to produce one; it is never invented, defaulted or skipped. And every artefact
# the record NAMES is asserted present before any predicate reads it — M6's review found four
# assertions passing over a build directory that held nothing, because every predicate returned 0
# over a missing path.
# ---------------------------------------------------------------------------
m9_measured() {
  if [ ! -f "$M9_WORK/measured.env" ]; then
    note "no measurement on record — running verify_observation_hook_step_records_identical to produce one"
    mkdir -p "$M9_WORK"
    "$VERIFY_DIR/verify_observation_hook_step_records_identical.sh" >"$M9_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M9_WORK/build-for-record.log"
  fi
  [ -f "$M9_WORK/measured.env" ] || die "measurement record missing at $M9_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M9_WORK/measured.env"
  [ -n "${M9_TREE:-}" ] && [ -d "$M9_TREE" ] \
    || die "measurement names no tree, or a tree that is gone: [${M9_TREE:-}]"
  m8_require_artifacts "$(m9_native_bin "$M9_TREE")" "$(m9_wasm_bin "$M9_TREE")" \
    "$(m9_steps_native)" "$(m9_steps_v8)"
}

# ---------------------------------------------------------------------------
# m9_sentinel_opcode -> the numeric value of WireOpCode::LAST_OPCODE_SENTINEL, DERIVED from the
# fork's own common/opcodes.hpp at the pinned anchor by counting the enumerators before it.
#
# Not a constant of ours. The whole point of the `oob` program is that the observer reports this
# value when an instruction fetch throws before the opcode is known, and a number restated on our
# side would keep agreeing with itself after upstream added an opcode.
# ---------------------------------------------------------------------------
m9_sentinel_opcode() {
  if [ -n "$M9_SENTINEL_OPCODE" ]; then
    printf '%s\n' "$M9_SENTINEL_OPCODE"
    return 0
  fi
  local src="$M9_WORK/opcodes.hpp"
  mkdir -p "$M9_WORK"
  m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/common/opcodes.hpp "$src"
  M9_SENTINEL_OPCODE="$(python3 - "$src" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"enum\s+class\s+WireOpCode\s*(?::[^{]*)?\{(.*?)\}\s*;", text, re.S)
if not m:
    sys.exit(3)
body = m.group(1)
body = re.sub(r"//[^\n]*", "", body)
body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
names = []
for part in body.split(","):
    part = part.strip()
    if not part:
        continue
    if "=" in part:
        sys.exit(4)          # an explicit value would make positional counting wrong
    names.append(part)
if "LAST_OPCODE_SENTINEL" not in names:
    sys.exit(5)
print(names.index("LAST_OPCODE_SENTINEL"))
PY
)" || die "could not derive WireOpCode::LAST_OPCODE_SENTINEL from the fork's own opcodes.hpp"
  [ -n "$M9_SENTINEL_OPCODE" ] \
    || die "WireOpCode::LAST_OPCODE_SENTINEL derived as the empty string"
  printf '%s\n' "$M9_SENTINEL_OPCODE"
}

# ---------------------------------------------------------------------------
# m9_field <transcript> <key> -> the value of a `<key> <value>` line, or the empty string.
# m9_expect_steps <program> -> the recorded instruction count for that program.
# ---------------------------------------------------------------------------
m9_field() {
  local file="$1" key="$2"
  [ -f "$file" ] || die "m9_field: no such file: $file"
  awk -v k="$key" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$file"
}

m9_expect_steps() {
  local var="M9_STEPS_$1"
  printf '%s\n' "${!var:-}"
}

# m9_ordinary <transcript> — every line that is not a diagnostic.
m9_ordinary() { grep -v '^diag ' "$1"; }

# m9_step_record_count <transcript> — the individual per-instruction records, which are the lines
# whose key ends in a decimal index and whose value carries every field.
m9_step_record_count() {
  grep -cE '^steps\.[a-z0-9]+\.[0-9]+ ctx=[0-9]+ pc=[0-9]+ op=[0-9]+ l2=[0-9]+ da=[0-9]+ addr=0x[0-9a-f]{64}$' "$1"
}

m9_event_record_count() {
  grep -cE '^events\.[a-z0-9]+\.[0-9]+ ctx=[0-9]+ pc=[0-9]+ op=[0-9]+ l2=[0-9]+ da=[0-9]+ addr=0x[0-9a-f]{64}$' "$1"
}

# m9_tree_dirty <tree> — the paths under barretenberg/ that differ from HEAD, EXCEPT
# nodejs_module/, whose CMakeLists runs `yarn --immutable` at configure time and forces a plain
# `yarn install` first. M3, M6, M7 and M8 all scope past that directory AND PAST NOTHING ELSE.
m9_tree_dirty() {
  git -C "$1" diff --name-only HEAD -- barretenberg \
    | grep -v '^barretenberg/cpp/src/barretenberg/nodejs_module/' \
    | tr '\n' ' ' | sed 's/ *$//'
}
