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
# ---------------------------------------------------------------------------
require_work_dir() { # <dir> <minimum-gb>
  local dir="$1" min_gb="${2:-1}" avail_kb probe
  mkdir -p "$dir" 2>/dev/null \
    || die "the work directory cannot be created: $dir (set the milestone's <M>_WORK)"
  [ -w "$dir" ] || die "the work directory is not writable: $dir"
  avail_kb="$(df -Pk "$dir" 2>/dev/null | awk 'NR==2 { print $4 }')"
  case "$avail_kb" in
    ''|*[!0-9]*) die "could not read the free space of the work directory: $dir" ;;
  esac
  if [ "$avail_kb" -lt $((min_gb * 1024 * 1024)) ]; then
    die "the work directory has $((avail_kb / 1024 / 1024)) GB free and this milestone needs about ${min_gb} GB: $dir
             /tmp is usually a small tmpfs; point the milestone's <M>_WORK somewhere with room."
  fi
  probe="$dir/.write-probe.$$"
  if ! dd if=/dev/zero of="$probe" bs=1M count=4 >/dev/null 2>&1; then
    rm -f "$probe" 2>/dev/null
    die "the work directory reports free space but refuses a 4 MB write: $dir
             a disk quota, not a full filesystem — the checks would otherwise report this as
             dozens of unrelated assertion failures."
  fi
  rm -f "$probe"
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
