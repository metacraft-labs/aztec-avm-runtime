#!/usr/bin/env bash
# lib_m37.sh — the two things M37's checks need that `lib.sh` does not provide.
#
# Sourced AFTER `lib.sh`. Not executable on its own.
#
# ---------------------------------------------------------------------------
# 1. A SUMMARY LINE ON AN ABNORMAL EXIT
#
# `die` exits 1 and prints no summary, so a check that dies contributes ZERO to the
# sweep total and nothing red. That is *"a missing check reads as a smaller milestone,
# not as a red one"* — the shape that cost this campaign 283 assertions once, when two
# M9 checks refused to compare and `verify-m9` read 524 against 807 with no failure
# attributable to it.
#
# M22 built the remedy and kept it local, deliberately: *"putting it in `lib.sh` would
# change the abnormal-exit behaviour of a hundred and fifty checks in the same commit
# that is supposed to be about block assembly"*. M23, M24 and M30 each took their own
# copy for the same reason, and M9 was recorded as a retrospective fourth caller. This
# is the sixth copy and the reasoning is unchanged — M37 is the reconciliation
# milestone and moving a hundred and fifty checks' failure behaviour inside it would be
# a change nobody asked for, measured by a sweep whose whole job is to account for
# every unit of movement.
#
# ---------------------------------------------------------------------------
# 2. A BOUND ON EVERY SUBPROCESS THE CHECKS WAIT ON
#
# *"A trap fires on exit; a process that never exits has no exit."* M23's review found
# the state the trap cannot reach: a mutated chain made a hundred-block arm wait for
# ever, the run sat at zero bytes of output, and it would have blocked the sweep behind
# it. Every subprocess these checks wait on goes through `m37_bounded`, so exceeding
# the bound is a NAMED failure carrying the command and the bound rather than a hang.
#
# The bound is generous (default 300 s) because none of M37's subprocesses does real
# work — they read object stores and compare field lists — so anything near it is a
# defect and not a slow machine.

_M37_FINISHED=0

m37_finish() {
  _M37_FINISHED=1
  finish
}

_m37_abnormal_exit() {
  local rc=$?
  [ "$_M37_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}

m37_summary_on_abnormal_exit() {
  trap _m37_abnormal_exit EXIT
}

# m37_bounded <seconds> <command...> — run with a bound; exceeding it is a named
# failure. Output goes to stdout as usual; the caller reads the exit status.
# `$?` IS READ WITH `|| rc=$?` AND NOT AFTER AN `if`, AND THAT IS A DEFECT THIS
# FUNCTION SHIPPED FOR ONE RUN. The first draft was
# `if timeout …; then return 0; fi; local rc=$?` — and an `if` whose condition is
# FALSE with no `else` branch exits **0**, so `$?` after the `fi` is the `if`
# statement's status and not the command's. Measured: the comparer exited 3 and
# `m37_bounded` returned 0, which reddened the two assertions that read the
# comparer's status while every other assertion stayed green. That is a wrapper
# swallowing the status of the thing it wraps — the same family as this campaign's
# "a pipe that put the failure counter in a subshell", one level out.
m37_bounded() {
  local secs="$1"; shift
  local rc=0
  # NO `--preserve-status`. With it, a killed command's own status (128+SIGTERM =
  # 143) is what comes back and the timeout is indistinguishable from an ordinary
  # failure — measured: `m37_bounded 2 sleep 20` returned **143** and fell through the
  # 124/137 test into `return "$rc"`, so a HANG would have been reported as a failing
  # command rather than as a bound exceeded. Without it, `timeout` returns **124** on
  # the bound and 137 if the follow-up KILL was needed, and a normal exit still
  # returns the command's own status.
  timeout -k 5 "$secs" "$@" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    die "the command exceeded its ${secs}s bound and was killed: $*
     A subprocess with no bound is a hang, and a hang blocks the sweep behind it with
     no exit for a trap to fire on."
  fi
  return "$rc"
}

# m37_bounded_out <outfile> <errfile> <seconds> <command...>
#
# **A REDIRECTION AT THE CALL SITE SWALLOWS THE TRAP'S SUMMARY, AND THE MUTATION MATRIX
# IS WHAT FOUND IT.** The hang arm mutated the comparer to spin, and `m37_bounded` did
# exactly what it was written to do — killed it at the bound and `die`d naming the
# command — but the call site was
# `m37_bounded … python3 … > "$WORK/out.json" 2>"$WORK/out.err"`, so the redirections
# were still in force when `exit` ran the EXIT trap. The summary line went INTO
# `out.json` and the diagnostic into `out.err`, and the arm printed **nothing at all**:
# a check that dies with its summary redirected into a scratch file reads to the sweep
# as a check that is not there. That is *"a missing check reads as a smaller milestone,
# not as a red one"* arriving through a file descriptor, in the very function written to
# prevent the hang half of it.
#
# So the redirection is the function's, not the caller's, and it is closed before
# anything can die under it.
m37_bounded_out() {
  local outf="$1" errf="$2" secs="$3"; shift 3
  local rc=0
  timeout -k 5 "$secs" "$@" > "$outf" 2> "$errf" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    die "the command exceeded its ${secs}s bound and was killed: $*
     A subprocess with no bound is a hang, and a hang blocks the sweep behind it with
     no exit for a trap to fire on. Its output, such as it is, is at $outf / $errf."
  fi
  return "$rc"
}

M37_BOUND="${M37_BOUND:-300}"
