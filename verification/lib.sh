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

# ---------------------------------------------------------------------------
# AMBIENT EXPORTED NAMES THAT COLLIDE WITH THESE SCRIPTS' OWN VARIABLES.
#
# A bash assignment to a name that is ALREADY EXPORTED KEEPS THE EXPORT ATTRIBUTE. That is the
# whole bug, and it cost M11 sixty assertions.
#
# This environment exports `out` — direnv leaks a nix build environment, and `declare -p out` reads
# `declare -x out=...`. `verify_submission_is_a_manual_step` then does `out="$(… --dry-run 2>&1)"`,
# 738 KB of report, which therefore went INTO THE ENVIRONMENT, past Linux's MAX_ARG_STRLEN of
# 128 KB, and every subsequent `exec` in that shell failed with E2BIG. The check scored 35
# assertions instead of 95 and its only diagnostic was
# `python3: Argument list too long` — which names neither the variable nor the cause. Two sibling
# checks failed downstream of it for the same reason and were written up as network or upstream
# problems.
#
# The rule applied here: POSIX reserves ALL-LOWERCASE names for applications, and every environment
# variable these checks legitimately read is upper-case (HOME, PATH, TMPDIR, LD_LIBRARY_PATH,
# M3_WORK, …). An exported all-lowercase name is therefore a leak from a surrounding build
# environment, and it is exactly the namespace the check scripts use for their own locals. Measured
# in this environment: `out`, `outputs`, `name`, `patches`, `phases`, `shell`, `stdenv`, `builder`
# are all exported, and at least four of those are plausible names for a shell script's own
# variable.
#
# DE-EXPORTED, NOT UNSET: the value stays readable for anything that wants it, and only the leak is
# removed. `_`-prefixed names are left alone — bash owns `_`, and the campaign's own exported state
# (`_WORK_DIR_LOCKS_HELD`) must survive.
#
# `test_large_assignment_survives_an_exported_name` proves both directions: the same 738 KB
# assignment followed by an exec fails E2BIG WITHOUT this guard and succeeds with it, and the value
# is still there afterwards.
# `declare -x` rather than `compgen -e`, because the dev shells' bash reports
# `compgen: command not found` — it is built without programmable completion — and a guard that
# silently did nothing is the failure this whole comment is about. `declare -x` is a POSIX-mode-
# proof builtin, and matching on the `declare -x ` prefix is what makes a value containing newlines
# harmless: a continuation line cannot start with it.
_deexport_ambient_lowercase() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] && export -n "$n" 2>/dev/null
  done < <(
    declare -x | sed -n \
      -e 's/^declare -x \([a-z][a-z0-9_]*\)=.*$/\1/p' \
      -e 's/^declare -x \([a-z][a-z0-9_]*\)$/\1/p'
  )
  return 0
}
_deexport_ambient_lowercase

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

# ---------------------------------------------------------------------------
# STRING PREDICATES THAT ARE NOT PIPELINES.
#
# `printf '%s\n' "$x" | grep -q NEEDLE` is a DEFECT in this shell, and it has now bitten this
# campaign in three distinct ways. Every one of them is silent.
#
#   1. THE PIPE BINDS TO THE HELPER, NOT TO `printf`.
#      `assert_true "…" printf '%s\n' "$x" | grep -qx 'y'` parses as
#      `{ assert_true "…" printf '%s\n' "$x" ; } | grep -qx 'y'`. `assert_true` runs `printf`,
#      which always succeeds, so the assertion can only pass — and its `ok` line goes INTO grep, so
#      it is not even printed, and the `_ASSERTIONS` increment happens in the subshell and is lost.
#      Reproduced here before it was fixed: three such assertions, one of them on a needle that
#      cannot match and one on an EMPTY haystack, produced `TOTAL 0 assertion(s), 0 failure(s)`.
#      Two live instances were in `verify_wasi_shim_reuse_decision_recorded.sh` (M17), invisible in
#      its own transcript between two neighbouring `ok` lines.
#
#   2. UNDER `pipefail`, THE PIPELINE'S STATUS IS THE WRITER'S SIGNAL RATHER THAN THE READER'S
#      VERDICT. `grep -q` exits at its FIRST match; if `printf` is still writing it takes SIGPIPE
#      and the pipeline's status becomes 141, so the `if` takes the ELSE branch whatever the string
#      says. It is SIZE-DEPENDENT: below the 64 KiB pipe buffer `printf` finishes first and there is
#      no signal at all. `verify_upstream_world_state_reference_gate_green` was latent for eight
#      milestones and detonated the moment M20 grew `avm-wasm.yml` past 64 KiB.
#
#   3. Even where neither bites, the predicate forks two processes to answer a question bash can
#      answer with a `case`.
#
# `<<<` is NOT a fix for (2) — the shell becomes the writer and takes the signal instead.
# These five helpers are pure builtins: no pipeline, no subshell, no temporary file, no size
# dependence. `verify_no_pipeline_predicates.sh` asserts that no check-shell line in this tree uses
# the old shape, and exercises every helper here against a haystack larger than the pipe buffer.
#
# Each mirrors one `grep -q` spelling exactly:
#   str_has_line   <hay> <line>  = grep -qxF   (whole line, fixed string)
#   str_has_sub    <hay> <sub>   = grep -qF    (substring anywhere, fixed string)
#   str_has_word   <hay> <word>  = grep -qw    (fixed string on word boundaries)
#   str_has_re     <hay> <ere>   = an ERE over the WHOLE string (`^`/`$` are string ends)
#   str_has_line_re <hay> <ere>  = grep -qE    (an ERE tried against each LINE separately)
# The last distinction is load-bearing: bash's `=~` has no REG_NEWLINE, so `^` and `$` in
# `[[ $s =~ ^x$ ]]` anchor to the ends of the whole string and NOT to each line, and translating a
# `grep -qE '^foo$'` into `str_has_re` would silently stop matching.
# ---------------------------------------------------------------------------

str_has_line() { # <haystack> <line> -- whole-line fixed-string match; grep -qxF
  [ -n "$1" ] || return 1
  case $'\n'"$1"$'\n' in (*$'\n'"$2"$'\n'*) return 0 ;; esac
  return 1
}

str_has_sub() { # <haystack> <needle> -- fixed-string substring; grep -qF
  case "$1" in (*"$2"*) return 0 ;; esac
  return 1
}

_str_escape_ere() { # <literal> -> the same text as an ERE that matches only itself
  local s="$1" out="" i c
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      # Spelled as an alternation of single-character patterns rather than as one bracket
      # expression: inside a `case` glob a `]` closes the bracket and a `)` closes the pattern, so
      # `[\\.^$*+?()[\]{}|]` PARSES but escapes only `]` — measured, and it is exactly the
      # "the scanner around the needle counts too" failure this campaign keeps meeting.
      ( '\' | '.' | '^' | '$' | '*' | '+' | '?' | '(' | ')' | '[' | ']' | '{' | '}' | '|' )
        out="$out\\$c" ;;
      ( * ) out="$out$c" ;;
    esac
  done
  printf '%s' "$out"
}

str_has_word() { # <haystack> <word> -- fixed string on word boundaries; grep -qw
  # The word is ESCAPED into an ERE rather than interpolated, so a needle containing `.`, `+` or
  # `[` cannot silently widen the match — the campaign has been bitten fourteen times by a needle
  # that matched more than it named.
  # The boundary class `[^[:alnum:]_]` contains the newline, so a word at the start or end of a
  # LINE is bounded by it exactly as `grep -w` would have it, and `^`/`$` cover the two string ends.
  local w
  [ -n "$2" ] || return 1
  w="$(_str_escape_ere "$2")"
  [[ $1 =~ (^|[^[:alnum:]_])$w($|[^[:alnum:]_]) ]]
}

str_has_re() { # <haystack> <ere> -- ERE over the WHOLE string; `^`/`$` are the string's ends
  [[ $1 =~ $2 ]]
}

str_has_line_re() { # <haystack> <ere> -- ERE tried against each LINE; grep -qE
  local re="$2" line
  local -a _lines=()
  local _had_f=0
  [ -n "$1" ] || return 1
  # A pattern that matches the empty string matches EVERY line, which is what `grep -E ''` does,
  # so answer that case before splitting — it is also the one case in which dropping empty lines
  # below could change the answer.
  if [[ "" =~ $re ]]; then return 0; fi
  # Split on newlines with the shell's own field splitting: no pipeline, no subshell, no here-string
  # (which would make the SHELL the writer), and linear rather than the quadratic cost of peeling
  # one line at a time off the front of a large string — measured 8.1 s versus 0.01 s on 199 KB.
  case $- in (*f*) _had_f=1 ;; esac
  set -f
  local IFS=$'\n'
  _lines=($1)
  [ "$_had_f" = 1 ] || set +f
  for line in "${_lines[@]}"; do
    [[ $line =~ $re ]] && return 0
  done
  return 1
}

# ---------------------------------------------------------------------------
# TRANSCRIPT COMPLETENESS — ONE IMPLEMENTATION, BECAUSE THERE WERE THREE.
#
# The V8/WASI stdout truncation has TWO recorded sightings and no established trigger: M9's
# observation-hook transcript stopped inside `burn` at record 16,719 of 38,915, and M8's
# `revert-rerun.transcript` held 259 lines of 1,318 — in both cases the prefix was byte-identical
# to the reference and then simply stopped, stderr was complete, and the next run passed. It is a
# fact about the RUN. A check that compares transcripts without asking that question first turns it
# into dozens of red assertions with names like "oob recorded no steps", every one of which reads
# like a discovery about the interpreter and none of which is.
#
# Until the trigger is known, the DETECTION is what has to be uniform, and it was not: M9 had
# `m9_completeness`, M17 had `m17_completeness` — the same seven lines, independently written — and
# M8's `test_revert_program_does_not_trap_module` had a third spelling inlined as a pair of
# `tail -1` comparisons. Three implementations are three chances for the next transcript check to
# be written without one. Both milestone helpers now delegate here, and
# `verify_transcript_truncation_detection_uniform.sh` asserts that every check that compares a
# transcript reaches this function.
#
# `absent` and `truncated-…` are DIFFERENT ANSWERS on purpose: a missing file is a broken run, a
# truncated one is this flake, and collapsing them would hide which happened.
# ---------------------------------------------------------------------------
transcript_completeness() { # <file> <sentinel> -> complete | absent | empty | truncated-after-N-lines-last-key-K
  local file="$1" sentinel="$2" lines last
  [ -f "$file" ] || { printf 'absent\n'; return 0; }
  # EMPTY IS ITS OWN ANSWER, and it is not a nicety. A run that never started — a module that would
  # not resolve, a binary that is not there — leaves a zero-byte transcript, and reporting that as
  # `truncated-after-0-lines` makes the refusal below tell the reader about a V8/WASI stdout flake
  # that had nothing to do with it. Found by this happening: M21's first surface probe failed with
  # `ERR_MODULE_NOT_FOUND` and the refusal printed the truncation story over it. Misattributing a
  # failure is exactly what this whole mechanism exists to stop, so it must not do it itself.
  [ -s "$file" ] || { printf 'empty\n'; return 0; }
  if awk -v k="$sentinel" '$1 == k { found = 1; exit } END { exit found ? 0 : 1 }' "$file"; then
    printf 'complete\n'; return 0
  fi
  lines="$(wc -l <"$file" | tr -d '[:space:]')"
  last="$(awk 'NF { k = $1 } END { print k }' "$file")"
  printf 'truncated-after-%s-lines-last-key-%s\n' "${lines:-0}" "${last:-none}"
}

# require_complete_transcript <file> <sentinel-key> <role> [<reference-file>]
#
# The refusal. Dies naming the truncation, the line counts and where stderr will be, instead of
# letting the caller emit a diff. The role is the caller's word for which transcript this is
# ("the re-run", "the reference"), because "a transcript is incomplete" does not say which.
require_complete_transcript() {
  local file="$1" sentinel="$2" role="$3" ref="${4:-}" verdict refnote=""
  verdict="$(transcript_completeness "$file" "$sentinel")"
  [ "$verdict" = complete ] && return 0
  # THREE DIFFERENT FAILURES, THREE DIFFERENT MESSAGES. Collapsing them is how a check comes to
  # tell the reader about a flake that is not what happened.
  case "$verdict" in
    (absent)
      die "$role transcript $file DOES NOT EXIST (expected sentinel '$sentinel').
     The run that should have written it did not get that far. Look at the run's own stderr and at
     whatever was supposed to produce this file; this is not the truncation flake." ;;
    (empty)
      die "$role transcript $file is EMPTY (expected sentinel '$sentinel').
     The process produced no stdout at all, which means it did not start rather than that it
     stopped part way — a module that would not resolve, a binary that is not there, a shell that
     died before exec. Read the run's stderr. This is NOT the V8/WASI truncation, and saying so is
     the point: a zero-line transcript reported as a truncation sends the next reader after the
     wrong thing." ;;
  esac
  [ -z "$ref" ] || [ ! -f "$ref" ] || refnote="
     the reference $ref has $(wc -l <"$ref" | tr -d '[:space:]') line(s)."
  die "$role transcript $file is INCOMPLETE: $verdict (expected sentinel '$sentinel').$refnote
     This is the V8/WASI stdout truncation — two sightings, M9 and M8, trigger unestablished. The
     guest's stderr is normally COMPLETE, which is the signature; a short stdout with a complete
     stderr is a fact about the RUN and not about the module. The comparison is refused rather
     than reported as a divergence. Re-run this check."
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
    # A REFUSAL AND A LINGERING CHILD ARE DIFFERENT THINGS, AND CONFLATING THEM COST M17 A WHOLE
    # RUN. The lock fd is inherited by every child this check spawns, so a grandchild that outlives
    # the check — `nix develop`'s wrapper, a ninja job server, a ccache process — KEEPS THE LOCK
    # after the process that took it has exited. Reproduced: a shell that takes the lock, forks a
    # child and exits leaves the lock held until the child dies. In M17's first full run that made
    # the check after the failing one report "another run already holds this work directory", naming
    # a pid that was already gone, and the same thing cascaded through five more checks.
    #
    # So the two cases are separated by asking whether the recorded holder is still ALIVE. If it is,
    # this is the concurrent run M15's review found and it is refused at once, which is the property
    # that matters. If it is not, the lock is a leftover and is waited for, briefly and out loud,
    # rather than turned into six false failures.
    local owner_pid
    owner_pid="$(awk 'NR==1 { print $2 }' "$dir/.work-dir.owner" 2>/dev/null)"
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
      exec {fd}>&-
      return 1
    fi
    printf '  --   the work directory'"'"'s recorded holder (pid %s) has exited but a child of it still holds the lock; waiting up to %ss\n' \
      "${owner_pid:-unknown}" "${WORK_DIR_LOCK_WAIT:-90}"
    if ! flock -w "${WORK_DIR_LOCK_WAIT:-90}" "$fd"; then
      exec {fd}>&-
      return 1
    fi
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
