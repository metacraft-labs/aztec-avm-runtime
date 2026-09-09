#!/usr/bin/env bash
# lib_m41_writer.sh — shared machinery for the M41 (Path A / Path B writer seam) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# ---------------------------------------------------------------------------
# TWO MODULES, ONE DRIVER, AND THAT IS THE ENTIRE DESIGN.
#
# M41's question is "which writer produced this container", and every check here answers some part
# of it by comparing two artefacts that differ in ONE thing. So both modules are built here and
# cached here, and both are driven by `verification/ct_writer_drive.mjs` — one script, so a
# difference a check finds is the writer's and cannot be the driver's.
#
# The Path A module is the one the runtime ships and is built by `build_ct_writer_wasm.sh`
# unchanged. The Path B module is the same crate with `--no-default-features --features path-b`,
# built into its OWN target directory: sharing one would make each build clobber the other's
# artefact, and a check that read the wrong one would compare a module with itself.
#
# ---------------------------------------------------------------------------
# EVERY SUBPROCESS HAS A BOUND, FOR M23'S REASON.
#
# A check that HANGS prints no summary, never exits, and blocks the sweep behind it. A trap fires
# on exit; a process that never exits has none. `m41_bounded` wraps every driver and a timeout is a
# `die` naming the command and the bound. `verify_writer_path_is_selectable` proves the mechanism
# works by running a deliberate sleep against a one-second bound, and proves the TRAP works by
# dying before its own summary in a second arm — the two failure shapes are different and a check
# that demonstrated only one would be claiming the other.
# ---------------------------------------------------------------------------

M41_WORK="${M41_WORK:-$HOME/.cache/aztec-m41-writer}"
export M41_WORK

export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

M41_CRATE="$REPO_ROOT/ct-writer"
M41_HOST="$REPO_ROOT/ct-host"
M41_DRIVER="$REPO_ROOT/verification/ct_writer_drive.mjs"
M41_PATH_A="$M41_CRATE/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
M41_PATH_B_TARGET="$M41_WORK/target-path-b"
M41_PATH_B="$M41_PATH_B_TARGET/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
export M41_CRATE M41_HOST M41_DRIVER M41_PATH_A M41_PATH_B M41_PATH_B_TARGET

M41_BUILD_TIMEOUT="${M41_BUILD_TIMEOUT:-3600}"
M41_DRIVE_TIMEOUT="${M41_DRIVE_TIMEOUT:-300}"
M41_READER_TIMEOUT="${M41_READER_TIMEOUT:-600}"
export M41_BUILD_TIMEOUT M41_DRIVE_TIMEOUT M41_READER_TIMEOUT

# `lib.sh` has no `say`: it has `pass`/`fail`, which COUNT, and a note is not an assertion.
# `m41_say` prints a measured figure without adding to the tally, so a check can report the two
# module sizes without either of them looking like something that passed.
m41_say() { printf '  --   %s\n' "$*"; }

m41_finish() { finish; }
m41_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# m41_bounded <seconds> <label> <command...> — run with a hard bound; a timeout is a named death.
# The redirection, when a caller wants one, goes on THIS function's subprocess and not on the call,
# for the reason `lib_m24_ct_writer.sh` records at length: a redirection on the call is still in
# effect when `die` runs `exit`, and the EXIT trap's summary line goes wherever the caller sent it.
m41_bounded() {
  local secs="$1" label="$2"; shift 2
  local log rc
  mkdir -p "$M41_WORK"
  log="$M41_WORK/bounded.log"
  timeout --signal=TERM --kill-after=30 "$secs" "$@" >"$log" 2>&1
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    die "$label EXCEEDED its ${secs}s bound and was killed (status $rc).
     This is the state a trap cannot reach: a process that never exits has no exit, so without
     this bound the check would have printed nothing at all and blocked the sweep behind it.
     Its output, as far as it got, is in $log
     Command: $*"
  fi
  M41_LAST_LOG="$log"
  return "$rc"
}
M41_LAST_LOG=""
export M41_LAST_LOG

# ---------------------------------------------------------------------------
# The two modules.
#
# THESE SET GLOBALS AND PRINT NOTHING, for `lib_m24_ct_writer.sh`'s reason: a `die` inside
# `X="$(m41_require_path_b)"` kills only the subshell, and the caller then carries on to print a
# screenful of red assertions about a module that was never built.
# ---------------------------------------------------------------------------

m41_require_path_a() {
  if [ -n "${CT_WRITER_WASM:-}" ]; then
    M41_PATH_A="$CT_WRITER_WASM"
    return 0
  fi
  m41_bounded "$M41_BUILD_TIMEOUT" "the Path A build" \
    "$REPO_ROOT/verification/build_ct_writer_wasm.sh" \
    || die "the Path A module could not be built; its output is in $M41_LAST_LOG"
  [ -f "$M41_PATH_A" ] || die "the Path A build reported success but $M41_PATH_A is not there"
}

m41_require_path_b() {
  if [ -n "${CT_WRITER_WASM_PATH_B:-}" ]; then
    M41_PATH_B="$CT_WRITER_WASM_PATH_B"
    return 0
  fi
  m41_bounded "$M41_BUILD_TIMEOUT" "the Path B build" \
    "$REPO_ROOT/verification/build_ct_writer_wasm.sh" --path-b \
    || die "the Path B module could not be built; its output is in $M41_LAST_LOG"
  [ -f "$M41_PATH_B" ] || die "the Path B build reported success but $M41_PATH_B is not there"
}

# m41_drive <module> <label> — drive a module and leave `container.ct` and `report.json` in
# `$M41_WORK/<label>`. Sets `M41_DRIVE_DIR`.
M41_DRIVE_DIR=""
export M41_DRIVE_DIR
m41_drive() {
  local module="$1" label="$2" dir
  dir="$M41_WORK/$label"
  rm -rf "$dir"
  m41_bounded "$M41_DRIVE_TIMEOUT" "driving $label" node "$M41_DRIVER" "$module" "$dir" \
    || die "driving $label failed; its output is in $M41_LAST_LOG:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"
  [ -f "$dir/container.ct" ] || die "driving $label produced no container in $dir"
  [ -f "$dir/report.json" ] || die "driving $label produced no report in $dir"
  M41_DRIVE_DIR="$dir"
}

# m41_report <label> <json-path-expression> — one field out of a drive's report.
m41_report() {
  python3 - "$M41_WORK/$1/report.json" "$2" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d.get(sys.argv[2])
print("" if v is None else (json.dumps(v) if isinstance(v, (list, dict)) else v))
PY
}

# ---------------------------------------------------------------------------
# The readers.
# ---------------------------------------------------------------------------

M41_READERS=""
export M41_READERS
m41_require_readers() {
  local work
  work="${M24_CTPRINT_WORK:-$HOME/.cache/aztec-m24-ctprint}"
  m41_bounded 3600 "building the ct-print readers" "$REPO_ROOT/verification/build_ct_print.sh" \
    || die "the ct-print readers could not be built; its output is in $M41_LAST_LOG"
  local b
  for b in ct-print ct-split-probe ct-print-writer ct-split-probe-writer; do
    [ -x "$work/$b" ] || die "build_ct_print.sh reported success but $work/$b is not there"
  done
  M41_READERS="$work"
}

# m41_probe <reader> <container> — one probe run, output on stdout, bounded.
m41_probe() {
  local reader="$1" container="$2"
  m41_bounded "$M41_READER_TIMEOUT" "$(basename "$reader")" "$reader" "$container" || true
  cat "$M41_LAST_LOG"
}
