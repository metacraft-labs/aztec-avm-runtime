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
M41_PATH_A_TARGET="$M41_WORK/target-path-a"
M41_PATH_A="$M41_PATH_A_TARGET/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
# The DEFAULT arm — whichever writer `ct-writer/Cargo.toml` ships. Built and asserted separately
# from the two explicit arms, because "the runtime writes through the Nim writer" is a claim about
# THIS module and not about the one a check asked for by name.
M41_DEFAULT="$M41_CRATE/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
M41_PATH_B_TARGET="$M41_WORK/target-path-b"
M41_PATH_B="$M41_PATH_B_TARGET/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
export M41_CRATE M41_HOST M41_DRIVER M41_PATH_A M41_PATH_A_TARGET M41_PATH_B M41_PATH_B_TARGET M41_DEFAULT

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
  M41_PATH_A_TARGET="$M41_PATH_A_TARGET" m41_bounded "$M41_BUILD_TIMEOUT" "the Path A build" \
    "$REPO_ROOT/verification/build_ct_writer_wasm.sh" --path-a \
    || die "the Path A module could not be built; its output is in $M41_LAST_LOG"
  [ -f "$M41_PATH_A" ] || die "the Path A build reported success but $M41_PATH_A is not there"
}

# The DEFAULT module: whichever writer the crate ships, with no feature flag named.
m41_require_default() {
  m41_bounded "$M41_BUILD_TIMEOUT" "the default build" \
    "$REPO_ROOT/verification/build_ct_writer_wasm.sh" \
    || die "the default module could not be built; its output is in $M41_LAST_LOG"
  [ -f "$M41_DEFAULT" ] || die "the default build reported success but $M41_DEFAULT is not there"
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

# m41_drive <module> <label> [compact-threshold] — drive a module and leave `container.ct` and
# `report.json` in `$M41_WORK/<label>`. Sets `M41_DRIVE_DIR`.
#
# THE THIRD ARGUMENT IS OMITTED BY EVERY CALLER BUT ONE, AND OMITTING IT IS NOT THE SAME AS
# PASSING ZERO BY ACCIDENT. `ct_writer_drive.mjs` treats an absent threshold as `0`, which is what
# both writers construct themselves with and what makes the container the full profile — so every
# call written before CCP-6 drives exactly the container it drove before. The one caller that passes
# a value is `verify_compact_profile_emission_is_opt_in`, whose subject it is: a non-zero threshold
# asks for container version 6 / profile 1, which the replay engine pinned by content in
# BlockTracer's `client/hydrate/engine-pin.txt` cannot read.
M41_DRIVE_DIR=""
export M41_DRIVE_DIR
m41_drive() {
  local module="$1" label="$2" threshold="${3:-}" dir
  dir="$M41_WORK/$label"
  rm -rf "$dir"
  # `$threshold` is deliberately UNQUOTED: empty must expand to NO argument at all, where `""`
  # would pass an empty string the driver would then have to interpret. Absent and `0` mean the
  # same thing to the driver, but they are different calls, and this is the one that is absent.
  # shellcheck disable=SC2086
  m41_bounded "$M41_DRIVE_TIMEOUT" "driving $label" node "$M41_DRIVER" "$module" "$dir" $threshold \
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
M41_PROBE_NEW=""
M41_PROBE_OLD=""
M41_PRINT_NEW=""
M41_PRINT_OLD=""
export M41_READERS M41_PROBE_NEW M41_PROBE_OLD M41_PRINT_NEW M41_PRINT_OLD
m41_require_readers() {
  local work
  work="${M24_CTPRINT_WORK:-$HOME/.cache/aztec-m24-ctprint}"
  # ---------------------------------------------------------------------------
  # `M41_READERS_DIR` — readers built elsewhere, admitted ONLY against their own revision stamp.
  #
  # `build_ct_print.sh` cannot run on a host that is not Linux: it reaches `lib_toolchain.sh`,
  # whose health check asks `ldd` whether a binary still loads, and `ldd` does not exist on
  # macOS — so the readers are built and then declared unusable, by an instrument that cannot
  # measure them rather than by anything about them. `CT_WRITER_WASM` and `CT_WRITER_WASM_PATH_B`
  # already let a caller hand in a module built another way; this is the same door for the
  # readers, and it is the narrower one: the caller's directory must carry the SAME `.rev` stamps
  # `build_ct_print.sh` writes, and they must name `pins.json`'s anchor. "A prebuilt binary in a
  # sibling worktree" is what that script refuses, and a stamp this check reads out of
  # `pins.json` is what keeps this from being that.
  # ---------------------------------------------------------------------------
  if [ -n "${M41_READERS_DIR:-}" ]; then
    work="$M41_READERS_DIR"
    local want_rev b
    want_rev="$(python3 - "$REPO_ROOT/pins.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
print(p["anchors"]["trace_format_nim"]["commit"])
PY
)" || die "pins.json could not be read for the reader anchor"
    for b in ct-print ct-split-probe; do
      [ -x "$work/$b" ] || die "M41_READERS_DIR=$work has no executable $b"
      [ "$(cat "$work/$b.rev" 2>/dev/null)" = "$want_rev" ] \
        || die "$work/$b.rev does not name pins.json's trace_format_nim anchor $want_rev
     (it says [$(cat "$work/$b.rev" 2>/dev/null)]) — a reader at another revision is a different
     reader, and a check that used it would attribute its answer to this anchor."
    done
    M41_READERS="$work"
    M41_PROBE_OLD="$work/ct-split-probe"
    M41_PRINT_OLD="$work/ct-print"
    M41_PROBE_NEW="$work/ct-split-probe"
    M41_PRINT_NEW="$work/ct-print"
    return 0
  fi
  m41_bounded 3600 "building the ct-print readers" "$REPO_ROOT/verification/build_ct_print.sh" \
    || die "the ct-print readers could not be built; its output is in $M41_LAST_LOG"
  local b
  for b in ct-print ct-print-pre ct-split-probe ct-split-probe-pre; do
    [ -x "$work/$b" ] || die "build_ct_print.sh reported success but $work/$b is not there"
  done
  M41_READERS="$work"
  # THE TWO PROBES ARE RESOLVED BY ROLE, NOT BY FILE NAME.
  #
  # M41's checks need an OLDER reader and a NEWER one, because the two writers produce containers
  # under different `meta.dat` schema versions and each is readable by one of them. Which build
  # holds which role depends on where `pins.json`'s reader anchor sits, and that anchor is expected
  # to move — so the roles are looked up rather than spelled. `ct-split-probe` is always the
  # anchor's own revision and `ct-split-probe-pre` is always its control, which is by construction
  # the older of the two.
  # OLDER is the READER anchor's build; NEWER is the WRITER anchor's when the two anchors differ,
  # and the reader anchor's own when they coincide. `build_ct_print.sh` does not build a second
  # copy of one tree, so the fallback is not laziness — it is the only correct answer when there is
  # only one revision to have. A check that then compares a reader with itself would be reading
  # agreement as evidence, so `verify_container_equivalence_characterised` asserts the two probes
  # are DIFFERENT FILES before it uses them.
  M41_PROBE_OLD="$work/ct-split-probe"
  M41_PRINT_OLD="$work/ct-print"
  if [ -x "$work/ct-split-probe-writer" ]; then
    M41_PROBE_NEW="$work/ct-split-probe-writer"
    M41_PRINT_NEW="$work/ct-print-writer"
  else
    M41_PROBE_NEW="$work/ct-split-probe"
    M41_PRINT_NEW="$work/ct-print"
  fi
}

# m41_probe <reader> <container> — one probe run, output on stdout, bounded.
m41_probe() {
  local reader="$1" container="$2"
  m41_bounded "$M41_READER_TIMEOUT" "$(basename "$reader")" "$reader" "$container" || true
  cat "$M41_LAST_LOG"
}
