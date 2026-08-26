#!/usr/bin/env bash
# lib_m24_ct_writer.sh — shared machinery for the M24 (`.ct` writer binding, trace event ABI) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M24's checks read four things: the BUILT `ct_writer.wasm`, ONE run of the functional arms, ONE
# run of the OQ-6 benchmark, and the two `ct-print` readers. Every one of them is produced here
# and shared, for M20's reason and M22's and M23's: three checks each deriving "the container
# after 5,000 events" from their own run is how two checks come to disagree about a number
# nothing changed.
#
# STALENESS TAKES FILES AND NOT DIRECTORIES, which is M20's review's correction: `find -newer`
# compares a directory's own mtime like any other path, and a directory's mtime does not move when
# a file inside it is edited.
#
# ---------------------------------------------------------------------------
# EVERY SUBPROCESS THIS LIBRARY WAITS ON HAS A BOUND, AND EXCEEDING IT IS A NAMED FAILURE.
#
# M23's review established the state a trap cannot reach: a check that HANGS prints no summary,
# never exits, and blocks the sweep behind it — `m23_require_arms` ran its driver with no timeout
# and a one-character defect in the chain made a hundred-block arm wait forever on a subscription.
# A trap fires on exit; a process that never exits has none.
#
# So `m24_run_bounded` wraps every driver, and a timeout is a `die` naming the command and the
# bound rather than a silence. `verify_ct_writer_wasm_zero_imports` proves the mechanism works by
# running a deliberate sleep against a one-second bound.
# ---------------------------------------------------------------------------

M24_WORK="${M24_WORK:-$HOME/.cache/aztec-m24-ct-writer}"
M24_OQ6_WORK="${M24_OQ6_WORK:-$HOME/.cache/aztec-m24-oq6}"
M24_CTPRINT_WORK="${M24_CTPRINT_WORK:-$HOME/.cache/aztec-m24-ctprint}"
export M24_WORK M24_OQ6_WORK M24_CTPRINT_WORK

M24_ARMS="$M24_WORK/ct.json"
M24_OQ6_TSV="$M24_OQ6_WORK/arms.tsv"
export M24_ARMS M24_OQ6_TSV

# THE RUST TOOLCHAIN IS NOT IN EITHER DEV SHELL, so every cargo invocation in this milestone runs
# under `nix shell nixpkgs#rustup nixpkgs#capnproto` and needs these two. They are EXPORTED here
# rather than set per call: a `bash -c` under `nix shell` inherits the environment but runs with
# `set -u` in these checks, and an unset `$CARGO_HOME` there dies with `unbound variable` — which
# is what happened, and which made `cargo tree --duplicates` produce an EMPTY output that
# "names no codetracer crate" then passed on. That is this campaign's vacuous-pass shape exactly,
# and it was caught only because the non-emptiness assertion beside it went red.
#
# Both under ~/.cache and never `$TMPDIR`: a cargo registry in RAM is how `/tmp` filled twice
# during M22's sweep.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

M24_CRATE="$REPO_ROOT/ct-writer"
M24_HOST="$REPO_ROOT/ct-host"
M24_MODULE_DEFAULT="$M24_CRATE/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
export M24_CRATE M24_HOST M24_MODULE_DEFAULT

# Bounds. Generous, because they exist to turn a HANG into a failure and not to police a slow box.
M24_BUILD_TIMEOUT="${M24_BUILD_TIMEOUT:-1800}"
M24_ARMS_TIMEOUT="${M24_ARMS_TIMEOUT:-900}"
M24_OQ6_TIMEOUT="${M24_OQ6_TIMEOUT:-3600}"
M24_READER_TIMEOUT="${M24_READER_TIMEOUT:-600}"
export M24_BUILD_TIMEOUT M24_ARMS_TIMEOUT M24_OQ6_TIMEOUT M24_READER_TIMEOUT

# The margin the OQ-6 verdict is taken at, in percent. Declared HERE, in one place, because two
# checks read it and a number restated is a number that drifts.
M24_OQ6_MARGIN="${M24_OQ6_MARGIN:-3.0}"
export M24_OQ6_MARGIN

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT — M22's machinery, third copy.
#
# M22 wrote it and said a third milestone wanting it is the point at which it moves into `lib.sh`.
# It is NOT moved here, deliberately, and the reason is M22's own: changing the abnormal-exit
# behaviour of a hundred and fifty checks does not belong in a commit about a trace writer. It is
# recorded as owed instead — see the M24 section's outstanding tasks — so the decision is on the
# record rather than re-taken from scratch by a fourth milestone.
# ---------------------------------------------------------------------------
_M24_FINISHED=0
m24_finish() {
  _M24_FINISHED=1
  finish
}
_m24_abnormal_exit() {
  local rc=$?
  [ "$_M24_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m24_summary_on_abnormal_exit() {
  trap _m24_abnormal_exit EXIT
}

# ---------------------------------------------------------------------------
# The bounded runner.
# ---------------------------------------------------------------------------

# m24_run_bounded <seconds> <label> <command...>
# Runs the command with a hard bound. Prints its output. Returns the command's status, EXCEPT
# that a timeout is status 124 and the caller is expected to `die` on it — `m24_require_bounded`
# does. Kept separate from the `die` so `verify_ct_writer_wasm_zero_imports` can exercise the
# timeout path without killing itself.
m24_run_bounded() { # <seconds> <label> <command...>
  local secs="$1" label="$2"; shift 2
  timeout --signal=TERM --kill-after=30 "$secs" "$@"
}

# m24_require_bounded_logged <seconds> <label> <command...>
#
# THE REDIRECTION GOES ON `timeout`, NOT ON THIS FUNCTION, AND THAT IS THE ENTIRE POINT.
#
# THIRD INSTANCE OF ONE FAMILY IN ONE MILESTONE. A `die` inside a command substitution kills only
# the subshell (found by the M5 hang mutation). A `die` inside `m24_require_arms >/dev/null` sends
# the EXIT trap's summary line to `/dev/null` (found by fixing the first). And a `die` inside
# `m24_require_bounded … >/dev/null || die` does the SAME THING one level deeper, because the
# redirection is on the FUNCTION CALL and is therefore still in effect when `exit` runs — which is
# why the M6 wasm-spin mutation printed
#
#     test_ct_container_roundtrip_ct_print: FAIL — exited (status 1) before finish
#
# with its `N assertion(s), M failure(s)` line missing: the stderr half of the trap survived and
# the stdout half did not. A check with no summary line reads as a SMALLER milestone rather than a
# red one, which is the exact silent death M22 built the trap for.
#
# So a bounded run that does not want its subprocess's chatter sends THE SUBPROCESS's output to a
# log — `timeout … "$@" >"$log" 2>&1` binds the redirection to `timeout` — and the caller's own
# stdout is never touched. The log is kept and named in the diagnostic, which is strictly better
# than `/dev/null`: a driver that failed for a reason now has somewhere to have said so.
m24_require_bounded_logged() {
  local secs="$1" label="$2"; shift 2
  local log rc
  mkdir -p "$M24_WORK" 2>/dev/null
  log="$M24_WORK/bounded-run.log"
  timeout --signal=TERM --kill-after=30 "$secs" "$@" >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    die "$label EXCEEDED its ${secs}s bound and was killed (status $rc).
     This is the state a trap cannot reach: a process that never exits has no exit, so without
     this bound the check would have printed nothing at all and blocked the sweep behind it.
     Its output, as far as it got, is in $log
     Command: $*"
  fi
  return "$rc"
}

# m24_require_bounded <seconds> <label> <command...> — the same, with a timeout as a named death.
# Use this one only where the caller WANTS the subprocess's output on its own stdout.
m24_require_bounded() {
  local secs="$1" label="$2"; shift 2
  local rc
  m24_run_bounded "$secs" "$label" "$@"
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    die "$label EXCEEDED its ${secs}s bound and was killed (status $rc).
     This is the state a trap cannot reach: a process that never exits has no exit, so without
     this bound the check would have printed nothing at all and blocked the sweep behind it.
     Command: $*"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# A `die` INSIDE `$( … )` KILLS THE SUBSHELL AND NOTHING ELSE, WHICH IS WHY THESE SET GLOBALS.
#
# Found by M24's own hang mutation, and it is the M9 shape exactly. `ARMS="$(m24_require_arms)"`
# runs the function in a COMMAND SUBSTITUTION: when the bounded arms run exceeded its timeout, the
# `die` inside it exited the subshell, `$ARMS` came back EMPTY, and the check carried on to print
# **27 red assertions** whose names were "the roundtrip arm wrote a container — missing file" and
# "ct-print at the pinned revision reads the container — expected 0, got 1". Every one of those
# reads like a discovery about the writer and none of them is; the run TIMED OUT.
#
# Misattributing a failure is exactly what a precondition exists to stop, so a precondition must
# not be able to do it itself. Each `m24_require_*` sets a GLOBAL and the callers read that, so
# the `die` runs in the check's own shell and the check dies naming the timeout, once.
#
# AND THEY PRINT NOTHING, WHICH IS THE SECOND HALF OF THE SAME LESSON. The first fix kept the
# `printf` and had callers write `m24_require_arms >/dev/null`. That redirection is still in
# effect when `die` calls `exit`, so the EXIT trap's summary line went to `/dev/null` too and the
# check reported **no summary line at all** — the exact silent-death shape the trap exists to
# prevent, reintroduced by the fix for the defect above. A precondition that prints nothing cannot
# be redirected into silence. `m24_module` (no `die` in it) still prints, and is still used in a
# command substitution.
# ---------------------------------------------------------------------------
M24_MODULE=""
M24_READERS=""
export M24_MODULE M24_READERS

# ---------------------------------------------------------------------------
# The module.
# ---------------------------------------------------------------------------

m24_module() {
  if [ -n "${CT_WRITER_WASM:-}" ]; then
    printf '%s\n' "$CT_WRITER_WASM"
    return 0
  fi
  printf '%s\n' "$M24_MODULE_DEFAULT"
}

# Rebuilds when the module is missing or older than any source that could move it. A directory is
# never one of those inputs; only files are.
m24_require_module() {
  local mod stale=0 src
  mod="$(m24_module)"
  if [ ! -f "$mod" ]; then
    stale=1
  else
    for src in "$M24_CRATE/src/lib.rs" "$M24_CRATE/Cargo.toml" "$REPO_ROOT/pins.json" \
               "$REPO_ROOT/verification/build_ct_writer_wasm.sh"; do
      [ -f "$src" ] || continue
      [ "$src" -nt "$mod" ] && stale=1
    done
  fi
  if [ "$stale" = 1 ]; then
    m24_require_bounded_logged "$M24_BUILD_TIMEOUT" "the ct_writer.wasm build" \
      "$REPO_ROOT/verification/build_ct_writer_wasm.sh" \
      || die "verification/build_ct_writer_wasm.sh failed; see $M24_WORK/bounded-run.log"
  fi
  [ -f "$mod" ] || die "there is no ct_writer.wasm at $mod even after building"
  M24_MODULE="$mod"
}

# ---------------------------------------------------------------------------
# The functional arms — measured once, shared, and refused rather than reported stale.
# ---------------------------------------------------------------------------
m24_require_arms() {
  local mod stale=0 src
  m24_require_module
  mod="$M24_MODULE"
  if [ ! -f "$M24_ARMS" ]; then
    stale=1
  else
    for src in "$mod" "$REPO_ROOT/tools/run_ct_writer_arms.mjs" \
               "$M24_HOST/src/index.ts" "$M24_HOST/src/abi.ts" \
               "$M24_HOST/src/config.ts" "$M24_HOST/src/writer.ts"; do
      [ -f "$src" ] || continue
      [ "$src" -nt "$M24_ARMS" ] && stale=1
    done
  fi
  if [ "$stale" = 1 ]; then
    mkdir -p "$M24_WORK" || die "could not create $M24_WORK"
    m24_require_bounded_logged "$M24_ARMS_TIMEOUT" "the ct-writer arms run" \
      node --experimental-strip-types "$REPO_ROOT/tools/run_ct_writer_arms.mjs" \
        --module "$mod" --work "$M24_WORK" \
      || die "tools/run_ct_writer_arms.mjs failed; see $M24_WORK/bounded-run.log"
  fi
  [ -s "$M24_ARMS" ] || die "the arms run produced no $M24_ARMS"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$M24_ARMS" >/dev/null 2>&1 \
    || die "$M24_ARMS is not valid JSON — the arms run was interrupted; delete it and re-run"
}

# m24_arm <python-expression-over-`d`> — one value out of ct.json, or `MISSING`.
# A MISSING is a loud string rather than an empty one, because `assert_eq "" ""` is the campaign's
# oldest defect and an empty haystack turns every comparison beneath it into an assertion about
# nothing.
m24_arm() { # <expr>
  python3 - "$M24_ARMS" "$1" <<'PY' 2>/dev/null || printf 'MISSING\n'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
try:
    v = eval(sys.argv[2], {"d": d, "len": len, "sorted": sorted, "sum": sum, "abs": abs})
except Exception:
    print("MISSING"); raise SystemExit(0)
if v is None:
    print("MISSING")
elif isinstance(v, bool):
    print("true" if v else "false")
else:
    print(v)
PY
}

# ---------------------------------------------------------------------------
# The OQ-6 benchmark.
# ---------------------------------------------------------------------------
M24_OQ6_EVENTS="${M24_OQ6_EVENTS:-100000}"
M24_OQ6_BATCH="${M24_OQ6_BATCH:-4096}"
M24_OQ6_REPS="${M24_OQ6_REPS:-6}"
M24_OQ6_SESSIONS="${M24_OQ6_SESSIONS:-12}"
export M24_OQ6_EVENTS M24_OQ6_BATCH M24_OQ6_REPS M24_OQ6_SESSIONS

# STALENESS BY CONTENT, NOT BY MTIME — AND HERE THAT IS NOT A REFINEMENT.
#
# The benchmark takes twelve minutes and its OUTPUT IS A MEASUREMENT: re-running it produces
# different numbers, and `TRACE-ABI.md` is asserted to quote them. So an mtime test re-measures on
# every rebuild — including a rebuild that produced BYTE-IDENTICAL output — and the document goes
# stale for a reason that has nothing to do with the tree. Measured: three consecutive rebuilds of
# an unchanged crate cost three twelve-minute re-measurements and three different verdicts.
#
# The inputs are hashed instead. A rebuild that changes nothing changes no hash, and the recorded
# measurement stands; a change to the module, the driver or the host is a new measurement and the
# document must follow it, which is the property that matters.
_m24_oq6_stamp() {
  local mod="$1" src
  {
    sha256sum "$mod" 2>/dev/null
    for src in "$REPO_ROOT/tools/run_oq6_arms.mjs" "$M24_HOST/src/writer.ts" \
               "$M24_HOST/src/abi.ts" "$M24_HOST/src/config.ts"; do
      sha256sum "$src" 2>/dev/null
    done
    printf 'events=%s batch=%s reps=%s sessions=%s\n' \
      "$M24_OQ6_EVENTS" "$M24_OQ6_BATCH" "$M24_OQ6_REPS" "$M24_OQ6_SESSIONS"
  } | sha256sum | cut -d' ' -f1
}

m24_require_oq6() {
  local mod stale=0 want
  m24_require_module
  mod="$M24_MODULE"
  want="$(_m24_oq6_stamp "$mod")"
  if [ ! -s "$M24_OQ6_TSV" ]; then
    stale=1
  elif [ "$(cat "$M24_OQ6_TSV.stamp" 2>/dev/null | tr -d '[:space:]')" != "$want" ]; then
    stale=1
  fi
  if [ "$stale" = 1 ]; then
    mkdir -p "$M24_OQ6_WORK" || die "could not create $M24_OQ6_WORK"
    m24_require_bounded_logged "$M24_OQ6_TIMEOUT" "the OQ-6 benchmark" \
      node --experimental-strip-types "$REPO_ROOT/tools/run_oq6_arms.mjs" \
        --module "$mod" --events "$M24_OQ6_EVENTS" --batch "$M24_OQ6_BATCH" \
        --reps "$M24_OQ6_REPS" --sessions "$M24_OQ6_SESSIONS" --out "$M24_OQ6_TSV" \
      || die "tools/run_oq6_arms.mjs failed; see $M24_WORK/bounded-run.log"
  fi
  [ -s "$M24_OQ6_TSV" ] || die "the OQ-6 run produced no $M24_OQ6_TSV"
  printf '%s\n' "$want" >"$M24_OQ6_TSV.stamp"
}

# ---------------------------------------------------------------------------
# The readers.
# ---------------------------------------------------------------------------
# THE STAMP IS CHECKED, NOT JUST THE BINARY. "Never depend on state you did not produce": an
# executable left here by an earlier session, or by somebody building the same name by hand, is
# indistinguishable from one this script built — and it was, once, during M24's own development,
# which is how this branch of the condition came to exist. The `.rev` file is written only by
# `build_ct_print.sh` and only after a successful build.
m24_require_readers() {
  local want_fix want_ctl
  want_fix="$(m24_pin trace_format_nim commit)"
  want_ctl="$(m24_pin trace_format_nim control_commit)"
  if [ ! -x "$M24_CTPRINT_WORK/ct-print" ] || [ ! -x "$M24_CTPRINT_WORK/ct-print-pre" ] \
     || [ ! -x "$M24_CTPRINT_WORK/ct-split-probe" ] \
     || [ "$(cat "$M24_CTPRINT_WORK/ct-print.rev" 2>/dev/null | tr -d '[:space:]')" != "$want_fix" ] \
     || [ "$(cat "$M24_CTPRINT_WORK/ct-print-pre.rev" 2>/dev/null | tr -d '[:space:]')" != "$want_ctl" ] \
     || [ "$(cat "$M24_CTPRINT_WORK/ct-split-probe.rev" 2>/dev/null | tr -d '[:space:]')" != "$want_fix" ] \
     || [ "$REPO_ROOT/verification/ct_split_probe.nim" -nt "$M24_CTPRINT_WORK/ct-split-probe" ]; then
    m24_require_bounded_logged "$M24_BUILD_TIMEOUT" "the ct-print build" \
      "$REPO_ROOT/verification/build_ct_print.sh" \
      || die "verification/build_ct_print.sh failed; see $M24_WORK/bounded-run.log"
  fi
  for b in ct-print ct-print-pre ct-split-probe; do
    [ -x "$M24_CTPRINT_WORK/$b" ] || die "no $b at $M24_CTPRINT_WORK after building"
  done
  M24_READERS="$M24_CTPRINT_WORK"
}

# m24_split_probe <container> — the SPLIT-STREAM reader's answers, one `KEY<TAB>VALUE` per line.
#
# The probe never exits non-zero: a stream it cannot read is reported as `KEY<TAB>ERR:…` so the
# caller names the STREAM rather than reporting that the instrument died. It is still bounded,
# because a reader given a corrupt container is exactly the shape that spins.
m24_split_probe() { # <container>
  m24_run_bounded "$M24_READER_TIMEOUT" "ct-split-probe" \
    "$M24_CTPRINT_WORK/ct-split-probe" "$1" 2>&1
}

# m24_ct_print <binary> <container> — runs a reader, printing `<rc>` on the first line and its
# output after. Bounded, because a reader given a corrupt container is exactly the shape that
# spins.
m24_ct_print() { # <binary> <container>
  local out rc
  out="$(m24_run_bounded "$M24_READER_TIMEOUT" "ct-print" "$1" --full "$2" 2>&1)"
  rc=$?
  printf '%s\n' "$rc"
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# A PINNED COMMIT THAT IS NOT PUBLISHED IS NOT A PIN, IT IS A LOCAL FILE.
#
# Found by M24's review. Both of this milestone's anchors — `trace_format` and `trace_format_nim`
# — were pinned to commits that existed ONLY on a local branch in a worktree on this host. There
# was no `origin/wasm/ctfs-writer` and no `origin/wasm/nim-to-wasm`, and `pins.json` said so, but
# said it as the REASON A COMMIT IS PINNED RATHER THAN A BRANCH FOLLOWED, which is not the
# consequence. The consequence is that `build_ct_writer_wasm.sh` and `build_ct_print.sh` do
# `git archive <rev>` out of an object store nobody else has: they succeed here and fail
# everywhere else, including CI, and **every check in the milestone is green either way**. A pin
# whose whole purpose is reproducibility, that cannot be resolved by anybody but its author, is
# the campaign's "prose drifts from measurement" defect one level down — in the build inputs.
#
# So publication is a CHECKED property now rather than a habit. The predicate is offline: a
# commit is published when some `refs/remotes/*` ref contains it, which is exactly what a fresh
# clone or a CI checkout would have. It fails loudly the day somebody adds a fourth anchor off a
# branch they never pushed.
#
# m24_published_refcount <repo-dir> <sha> [ref-namespace] — how many remote refs contain it.
m24_published_refcount() { # <repo> <sha> [namespace]
  local repo="$1" sha="$2" ns="${3:-refs/remotes}"
  [ -e "$repo/.git" ] || { printf '0\n'; return 0; }
  # `grep -c .` prints 0 AND exits 1 on no match, so a `|| printf 0` fallback beside it emits the
  # count twice. The count is captured and printed once instead.
  local n
  n="$(git -C "$repo" for-each-ref --contains "$sha" --format='%(refname)' "$ns" 2>/dev/null \
       | grep -c . || true)"
  printf '%s\n' "${n:-0}"
}

# The pins, read out of pins.json rather than restated. PINS ARE NOT DECLARED IN CHECKS.
m24_pin() { # <anchor> <field>
  python3 - "$REPO_ROOT/pins.json" "$1" "$2" <<'PY' 2>/dev/null || printf 'MISSING\n'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["anchors"].get(sys.argv[2]) or {}
print(a.get(sys.argv[3], "MISSING"))
PY
}
