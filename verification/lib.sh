#!/usr/bin/env bash
# Shared assertion helpers for the M0 verification checks.
#
# Design rules these checks follow, and which a reviewer should hold them to:
#
#   * A check that cannot run in this environment FAILS. It never prints a
#     "SKIP" line and exits 0 — a check that reports success without having
#     executed anything is worse than no check at all.
#   * Assertions are on substance: specific tool versions, specific exported
#     variables, specific emitted bytes. "the command exited 0" is not an
#     assertion about anything the milestone claims.
#   * Every assertion is counted; the script exits non-zero if any failed, and
#     prints every failure rather than stopping at the first, so one run tells
#     you everything that is broken.
#
# Not to be executed directly: sourced by verification/verify_*.sh.

set -uo pipefail

if [ -z "${TEST_NAME:-}" ]; then
  echo "lib.sh: sourcing script must set TEST_NAME before sourcing" >&2
  exit 1
fi

_ASSERTIONS=0
_FAILURES=0

# Absolute path of the repository this check lives in.
VERIFY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$VERIFY_DIR/.." && pwd)"
# The upstream fork is a WORKSPACE-ROOT SIBLING of this repo (the M0 layout
# decision). It is deliberately not searched for anywhere else: if the fork is
# not here, the layout is wrong and the checks must say so.
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
FORK_ROOT="$WORKSPACE_ROOT/aztec-packages"

export VERIFY_DIR REPO_ROOT WORKSPACE_ROOT FORK_ROOT

pass() {
  _ASSERTIONS=$((_ASSERTIONS + 1))
  printf '  ok   %s\n' "$*"
}

fail() {
  _ASSERTIONS=$((_ASSERTIONS + 1))
  _FAILURES=$((_FAILURES + 1))
  printf '  FAIL %s\n' "$*" >&2
}

note() {
  printf '  --   %s\n' "$*"
}

# die: an unrecoverable precondition. Distinct from a failed assertion only in
# that nothing after it can be meaningfully evaluated.
die() {
  printf '%s: cannot run: %s\n' "$TEST_NAME" "$*" >&2
  exit 1
}

assert_true() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    pass "$desc"
  else
    fail "$desc (command failed: $*)"
  fi
}

assert_false() { # <description> <command...>
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    fail "$desc (command unexpectedly succeeded: $*)"
  else
    pass "$desc"
  fi
}

assert_eq() { # <description> <expected> <actual>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass "$desc  [$actual]"
  else
    fail "$desc  expected [$expected], got [$actual]"
  fi
}

assert_prefix() { # <description> <expected-prefix> <actual>
  local desc="$1" prefix="$2" actual="$3"
  case "$actual" in
    "$prefix"*) pass "$desc  [$actual]" ;;
    *)          fail "$desc  expected prefix [$prefix], got [$actual]" ;;
  esac
}

assert_contains() { # <description> <needle> <haystack>
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) pass "$desc" ;;
    *)           fail "$desc  [$needle] not found in: $(printf '%s' "$haystack" | head -c 400)" ;;
  esac
}

assert_not_contains() { # <description> <needle> <haystack>
  local desc="$1" needle="$2" haystack="$3"
  case "$haystack" in
    *"$needle"*) fail "$desc  [$needle] unexpectedly present" ;;
    *)           pass "$desc" ;;
  esac
}

assert_file() { # <description> <path>
  local desc="$1" path="$2"
  if [ -f "$path" ]; then
    pass "$desc  [$path]"
  else
    fail "$desc  missing file [$path]"
  fi
}

assert_dir() { # <description> <path>
  local desc="$1" path="$2"
  if [ -d "$path" ]; then
    pass "$desc  [$path]"
  else
    fail "$desc  missing directory [$path]"
  fi
}

assert_ge() { # <description> <minimum> <actual>
  local desc="$1" min="$2" actual="$3"
  if [ -n "$actual" ] && [ "$actual" -ge "$min" ] 2>/dev/null; then
    pass "$desc  [$actual >= $min]"
  else
    fail "$desc  expected >= $min, got [$actual]"
  fi
}

# assert_nix_store: the point of the dev shells is that the toolchain comes from
# nix and not from the host. Every tool the checks name must resolve into the
# nix store.
assert_nix_store() { # <description> <path>
  local desc="$1" path="$2"
  case "$path" in
    /nix/store/*) pass "$desc  [$path]" ;;
    *)            fail "$desc  not a /nix/store path: [$path]" ;;
  esac
}

require_nix() {
  command -v nix >/dev/null 2>&1 || die "the 'nix' command is not available"
}

# ---------------------------------------------------------------------------
# require_work_dir <dir> <minimum-gb>
#
# Every milestone from M3 on builds aztec-packages into a work directory, and a work directory that
# cannot hold the build is a PRECONDITION failure — one line naming the directory and the shortfall
# — and not the twenty-five wrong answers it otherwise produces.
#
# M9's review found that the hard way: `/tmp` on that host is a quota-limited tmpfs, the quota went
# during M5's build, and M5 through M8 then emitted more than a hundred failed assertions
# interleaved with `write error: Disk quota exceeded` from `printf` itself. Every one of those
# failures was a true statement about a file that could not be written and a false statement about
# the thing the check was named for.
#
# Free space is checked AND a real write is attempted, because they are different questions: a
# quota is not free space, so `df` can report gigabytes available on a filesystem that will refuse
# the next byte this user writes. The probe is 4 MB, written and removed.
#
# The exit status is `die`'s 1 by default, which is what a check wants. Scripts with their own exit
# vocabulary set WORK_DIR_PRECONDITION_EXIT before sourcing their lib: run_avm_differential.sh sets
# it to 2, because in its vocabulary 1 means DIVERGENCE, and a work directory it cannot write is a
# broken run rather than a differing one. Collapsing those two is exactly what that script's
# exit-status contract exists to prevent.
#
# AND THE WORK DIRECTORY IS TAKEN EXCLUSIVELY, WHICH IS M15's REVIEW'S FINDING.
#
# Two `just verify-m9` runs were launched four minutes apart, both defaulting to the same
# `~/.cache/aztec-m9-observer`, and they clobbered each other: one rebuilt the tree while the other
# was benchmarking out of it ("required artefact missing: .../build-native-avm/bin/avm_differential"
# is in the loser's own log), and both appended to the SAME `bench/native.tsv`, so the samples file
# a timing interval was computed over held two runs' sessions under one set of session ids. The
# reading that came out of that — +2.28% CI [-1.42%, +6.07%] with the same-bytes control failing
# too — was then written up as a finding about foreign load on the machine. There was no foreign
# load. The contention was self-inflicted, and nothing anywhere refused it, because this function
# checked free space and nothing else.
#
# So a work directory is now HELD, for the lifetime of the process that took it, and a second
# holder is a precondition failure that names the first. The lock is an `flock` on a file inside
# the directory, so it is released by the kernel when the holder dies however it dies — no stale
# lock file survives a kill, which a PID file would.
#
# TWO THINGS MUST NOT TRIP OVER IT, and both are handled by the same exported ledger rather than by
# two mechanisms:
#
#   * the libraries ALIAS work directories on purpose — `lib_m14_world_state.sh` sets
#     `M6_WORK="$M14_WORK"`, `lib_m9_observer.sh` sets `M8_WORK="$M9_WORK"`, and M15 points four of
#     them at one directory — so one process calls this several times for the same path. flock
#     conflicts between two open file descriptions even inside one process, so a naive lock would
#     deadlock the campaign's own layering.
#   * a check may run another check, or the differential runner, as a CHILD against the same work
#     directory. That child is part of the same run and must not be refused by its own parent.
#
# `_WORK_DIR_LOCKS_HELD` is exported, so both cases are the same case: a path already in it is
# already held by this run, and the second request is a no-op.
# ---------------------------------------------------------------------------
WORK_DIR_PRECONDITION_EXIT="${WORK_DIR_PRECONDITION_EXIT:-1}"
_WORK_DIR_LOCKS_HELD="${_WORK_DIR_LOCKS_HELD:-}"
export _WORK_DIR_LOCKS_HELD

# There is deliberately NO opt-out. An unlocked run is exactly the run this exists to stop, and a
# switch that turned a refusal back into a silent share would be the first thing reached for the
# next time two runs collide. The refusal names the holder and says what to do about it; that is
# the whole interface.

_work_dir_hold() { # <canonical-dir> ; returns 0 if held (or already held), 1 if someone else has it
  local dir="$1" fd
  case ":$_WORK_DIR_LOCKS_HELD:" in
    *":$dir:"*) return 0 ;;
  esac
  command -v flock >/dev/null 2>&1 || {
    printf '  --   work-directory locking unavailable (no flock); concurrent runs are not refused\n'
    return 0
  }
  exec {fd}>"$dir/.work-dir.lock" || return 1
  if ! flock -n "$fd"; then
    exec {fd}>&-
    return 1
  fi
  # Who holds it, for the diagnostic the NEXT run prints. Written after the lock is taken, so it
  # can never describe a holder that does not exist.
  printf 'pid %s  check %s  since %s\n' "$$" "${TEST_NAME:-?}" "$(date -Is 2>/dev/null || date)" \
    >"$dir/.work-dir.owner" 2>/dev/null || true
  _WORK_DIR_LOCKS_HELD="$_WORK_DIR_LOCKS_HELD:$dir"
  export _WORK_DIR_LOCKS_HELD
  return 0
}

require_work_dir() { # <dir> <minimum-gb>
  local dir="$1" min_gb="${2:-1}" avail_kb probe canon holder
  _wd_die() {
    printf '%s: cannot run: %s\n' "$TEST_NAME" "$*" >&2
    exit "$WORK_DIR_PRECONDITION_EXIT"
  }
  mkdir -p "$dir" 2>/dev/null \
    || _wd_die "the work directory cannot be created: $dir (set the milestone's <M>_WORK)"
  [ -w "$dir" ] || _wd_die "the work directory is not writable: $dir"
  avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 { print $4 }')"
  case "$avail_kb" in
    ''|*[!0-9]*) _wd_die "could not read the free space of the work directory: $dir" ;;
  esac
  if [ "$avail_kb" -lt $((min_gb * 1024 * 1024)) ]; then
    _wd_die "the work directory has $((avail_kb / 1024 / 1024)) GB free and this milestone needs about ${min_gb} GB: $dir
             /tmp is usually a small tmpfs; point the milestone's <M>_WORK somewhere with room."
  fi
  probe="$dir/.write-probe.$$"
  if ! dd if=/dev/zero of="$probe" bs=1M count=4 >/dev/null 2>&1; then
    rm -f "$probe" 2>/dev/null
    _wd_die "the work directory reports free space but refuses a 4 MB write: $dir
             a disk quota, not a full filesystem — the checks would otherwise report this as
             dozens of unrelated assertion failures."
  fi
  rm -f "$probe"
  # LAST, so that a directory which cannot be written is reported as that rather than as a lock
  # failure. `-P` resolves symlinks, so two spellings of one directory are one lock.
  canon="$(cd "$dir" && pwd -P)" || _wd_die "the work directory vanished while it was being checked: $dir"
  if ! _work_dir_hold "$canon"; then
    holder="$(cat "$canon/.work-dir.owner" 2>/dev/null || true)"
    _wd_die "another run already holds this work directory: $canon
             held by: ${holder:-(unknown — the lock is taken but the owner file is unreadable)}
             Two runs sharing one work directory rebuild the tree under each other and append to
             one samples file; M15's review found a timing interval computed over two runs' sessions
             under one set of session ids, and it was written up as foreign load on the machine.
             Wait for that run, kill it, or give this one its own directory by setting the
             milestone's <M>_WORK."
  fi
}

# in_shell <repo> <script>: run <script> under `nix develop` for <repo>.
# stdout is the script's stdout; the dev shell's own shellHook banner goes to
# the caller's stderr, so parsing stdout stays reliable.
in_shell() { # <repo-root> <script-text>
  local root="$1" script="$2"
  ( cd "$root" && nix develop --command bash -c "$script" ) 2>/dev/null
}

in_shell_status() { # <repo-root> <script-text> -> exit status, output on stdout
  local root="$1" script="$2"
  ( cd "$root" && nix develop --command bash -c "$script" ) 2>&1
}

finish() {
  printf '%s: %d assertion(s), %d failure(s)\n' \
    "$TEST_NAME" "$_ASSERTIONS" "$_FAILURES"
  if [ "$_ASSERTIONS" -eq 0 ]; then
    printf '%s: FAIL — no assertions ran\n' "$TEST_NAME" >&2
    exit 1
  fi
  if [ "$_FAILURES" -ne 0 ]; then
    printf '%s: FAIL\n' "$TEST_NAME" >&2
    exit 1
  fi
  printf '%s: PASS\n' "$TEST_NAME"
}
