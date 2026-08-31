#!/usr/bin/env bash
# lib_m30_vfs.sh — shared machinery for the M30 (compiling Noir from a virtual filesystem) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M30 asserts that a tree of Noir sources held in a browser compiles in-page, honouring
# `Nargo.toml`, resolving local `path` dependencies inside the tree, refusing `git`
# dependencies by name, reporting compile errors at real positions against the caller's own
# paths, and producing a `.ct` that changes when the tree changes. Its checks read ONE thing:
#
#   the VFS arm report — `tools/run_vfs_arms.mjs`, a headless-Chromium run over
#   `verification/m30/page/`, measured once and shared. M20's convention, kept by M22
#   through M29: four checks each launching their own browser is four browsers and two
#   numbers that disagree about something nothing changed.
#
# TWO MODULES GO INTO IT AND THEY COME FROM DIFFERENT PLACES, DELIBERATELY:
#
#   `noir_wasm.wasm`        M30's own work, built from `../noir` (branch `blocktracer`) by
#                           `build_noir_vfs_wasm.sh`. Its `nv_*` C ABI is what the page calls.
#   `noir_tracer_wasm.wasm` M24's and M26's, built READ-ONLY from `../noir-wt4-webpage` by
#                           `build_noir_tracer_wasm.sh`, which refuses to build from a
#                           worktree carrying any edit but M26's one tolerated file. That
#                           branch is unpublished and OQ-7's verdict rests on its being so.
#
# EVERY SUBPROCESS IS BOUNDED, for M27's reason and M23's review's: a check that hangs
# reports nothing at all and blocks the sweep behind it, which is worse than one that fails.

M30_WORK="${M30_WORK:-$HOME/.cache/aztec-m30-vfs}"
export M30_WORK

M30_ARMS="$M30_WORK/vfs.json"
export M30_ARMS

M30_NOIR_ROOT="${M30_NOIR_ROOT:-$WORKSPACE_ROOT/noir}"
M30_TRACER_ROOT="${M30_TRACER_ROOT:-$WORKSPACE_ROOT/noir-wt4-webpage}"
M30_VFS_SRC="$M30_NOIR_ROOT/compiler/wasm/src"
M30_TREES="$REPO_ROOT/tools/m30_vfs_trees.mjs"
M30_PAGE_DIR="$REPO_ROOT/verification/m30/page"
export M30_NOIR_ROOT M30_TRACER_ROOT M30_VFS_SRC M30_TREES M30_PAGE_DIR

M30_BUILD_TIMEOUT="${M30_BUILD_TIMEOUT:-1800}"
M30_ARMS_TIMEOUT="${M30_ARMS_TIMEOUT:-1800}"

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, carried the way `lib_m27_browser.sh`, `lib_m28_gate.sh` and
# `lib_m29_steps.sh` carry it and for the same reason: a check that dies before `finish`
# prints no summary and reads as a SMALLER milestone rather than a red one — which is how
# `verify-m9` once came out 283 assertions short with nothing reported. M22 said a third
# milestone wanting it is when it moves into `lib.sh`; M23, M24, M27, M28 and M29 each
# declined for M22's own reason (the trap names the milestone in its own diagnostic, and a
# shared one would have to be armed by every check that does not want it), and M30 — the
# sixth copy — declines for it too.
# ---------------------------------------------------------------------------
# DELEGATED TO `lib.sh` ON 2026-08-31. These eight lines were copied into FOURTEEN
# milestone libraries, m22..m37. M22 wrote them and said the third milestone wanting
# them is when they move into `lib.sh`; M24 declined for M22's own reason and recorded
# it as owed. The fifteenth caller turned out to be M9 — not a new milestone but the
# campaign's oldest open item — so the move is made and these are wrappers. The public
# names are unchanged, so no check needed editing, and the behaviour is identical: one
# implementation instead of fourteen, verified by the sweep.
m30_finish() { finish; }
m30_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# ---------------------------------------------------------------------------
# m30_bounded <seconds> <what> <command...>
#
# Returns the command's status, or DIES naming the command and the bound. A `die` here is
# correct — a build or an arms run that never finishes is a precondition failure, not an
# assertion — but note that this function must NEVER be called inside `$( … )`, because a
# `die` in a subshell exits only the subshell and the caller carries on with an empty string.
# That family has now appeared six times in this campaign.
# ---------------------------------------------------------------------------
m30_bounded() { # <seconds> <what> <command...>
  local secs="$1" what="$2"; shift 2
  mkdir -p "$M30_WORK"
  timeout -s KILL "$secs" "$@" >"$M30_WORK/bounded.log" 2>&1
  local rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    die "$what did not finish within ${secs}s and was killed. That is the HANG state reported as a
     failure rather than as silence. Command: $*  Output: $M30_WORK/bounded.log"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# m30_require_modules — both wasm modules, built here.
#
# "Never depend on state you did not produce": each build script carries its own
# content stamp and rebuilds when its sources move, so a module built before an edit cannot
# be measured as though it were built after one.
# ---------------------------------------------------------------------------
m30_require_modules() {
  mkdir -p "$M30_WORK"

  M30_NOIR_WASM="$M30_NOIR_ROOT/target/wasm32-unknown-unknown/release/noir_wasm.wasm"
  m30_bounded "$M30_BUILD_TIMEOUT" "the noir_wasm VFS module build" \
    "$VERIFY_DIR/build_noir_vfs_wasm.sh" \
    || die "build_noir_vfs_wasm.sh failed; see $M30_WORK/bounded.log"
  [ -s "$M30_NOIR_WASM" ] || die "build_noir_vfs_wasm.sh reported success and $M30_NOIR_WASM is not there"

  M30_TRACER_WASM="$M30_WORK/noir_tracer_wasm.wasm"
  m30_bounded "$M30_BUILD_TIMEOUT" "the noir_tracer_wasm module build" \
    "$VERIFY_DIR/build_noir_tracer_wasm.sh" \
    || die "build_noir_tracer_wasm.sh failed; see $M30_WORK/bounded.log"
  [ -s "$M30_TRACER_WASM" ] || die "build_noir_tracer_wasm.sh reported success and $M30_TRACER_WASM is not there"

  export M30_NOIR_WASM M30_TRACER_WASM
}

# ---------------------------------------------------------------------------
# m30_arms_newer_inputs — the staleness predicate.
#
# Prints the first input newer than the arm report, or nothing.
#
# IT TAKES FILES, NEVER DIRECTORIES. `find -newer <dir>` compares the DIRECTORY's own mtime,
# which changes when a file is added and not when one is edited — M20's review's finding, and
# `lib_m27_browser.sh` carries the same warning.
# ---------------------------------------------------------------------------
m30_arms_newer_inputs() {
  local stamp="$M30_ARMS"
  [ -s "$stamp" ] || { printf 'vfs.json\n'; return 0; }
  find "$M30_PAGE_DIR" -type f ! -name '.*' -newer "$stamp" -print -quit 2>/dev/null || true
  find "$M30_TREES" "$REPO_ROOT/tools/run_vfs_arms.mjs" "$REPO_ROOT/tools/browser_cdp.mjs" \
    -newer "$stamp" -print -quit 2>/dev/null || true
  [ -n "${M30_NOIR_WASM:-}" ] && [ "$M30_NOIR_WASM" -nt "$stamp" ] && printf '%s\n' "$M30_NOIR_WASM"
  [ -n "${M30_TRACER_WASM:-}" ] && [ "$M30_TRACER_WASM" -nt "$stamp" ] && printf '%s\n' "$M30_TRACER_WASM"
  return 0
}

# ---------------------------------------------------------------------------
# m30_require_arms — the browser arm report, produced here.
# ---------------------------------------------------------------------------
m30_require_arms() {
  m30_require_modules

  local chromium="${M30_CHROMIUM:-/usr/bin/chromium}"
  [ -x "$chromium" ] || die "no chromium at $chromium (set M30_CHROMIUM)"
  command -v node >/dev/null 2>&1 || die "node is required"

  local stale
  stale="$(m30_arms_newer_inputs | head -1)"
  if [ -z "$stale" ] && [ "${M30_ARMS_REFRESH:-0}" != "1" ]; then
    return 0
  fi

  note "re-measuring the VFS arms (${stale:-forced}); this compiles two wasm modules in a browser"
  M30_NOIR_WASM="$M30_NOIR_WASM" M30_TRACER_WASM="$M30_TRACER_WASM" M30_CHROMIUM="$chromium" \
    timeout -s KILL "$M30_ARMS_TIMEOUT" \
    node "$REPO_ROOT/tools/run_vfs_arms.mjs" "$M30_WORK" >"$M30_ARMS.tmp" 2>"$M30_WORK/arms.err"
  local rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    die "the VFS arms run did not finish within ${M30_ARMS_TIMEOUT}s and was killed. That is the
     HANG state reported as a failure. stderr: $M30_WORK/arms.err"
  fi
  if [ "$rc" -ne 0 ]; then
    # KEPT, NOT DELETED, and the guard is the point: the runner writes its report even when an
    # arm threw, and that report is the only thing that says WHICH arm threw. Overwriting the
    # good one with it would destroy the previous measurement as well.
    mv -f "$M30_ARMS.tmp" "$M30_WORK/vfs-failed.json" 2>/dev/null || true
    die "the VFS arms run exited $rc. The report it did write is at $M30_WORK/vfs-failed.json and
     its stderr at $M30_WORK/arms.err"
  fi
  mv -f "$M30_ARMS.tmp" "$M30_ARMS" || die "could not install $M30_ARMS"

  # AND THE REFRESH IS CHECKED. A run that wrote a report and left it stale would otherwise be
  # indistinguishable from one that did not run.
  stale="$(m30_arms_newer_inputs | head -1)"
  [ -z "$stale" ] || die "the arm report is still stale after a refresh; $stale is newer than it"
}

# ---------------------------------------------------------------------------
# m30_arm <dotted path> — one field out of the arm report.
#
# Prints `MISSING` rather than nothing for a path that is not there, because two empty
# strings compare equal and that is how five assertions in M29 went green over absent
# fields. Booleans print `true`/`false`; lists and dicts print compact sorted JSON.
# ---------------------------------------------------------------------------
m30_arm() { # <dotted path>
  python3 - "$M30_ARMS" "$1" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        node = json.load(fh)
except Exception:
    print("MISSING"); raise SystemExit(0)
for key in sys.argv[2].split("."):
    if isinstance(node, dict) and key in node:
        node = node[key]
    elif isinstance(node, list) and key.isdigit() and int(key) < len(node):
        node = node[int(key)]
    else:
        print("MISSING"); raise SystemExit(0)
if isinstance(node, bool):
    print("true" if node else "false")
elif node is None:
    print("None")
elif isinstance(node, (list, dict)):
    print(json.dumps(node, sort_keys=True, separators=(",", ":")))
else:
    print(node)
PY
}

# ---------------------------------------------------------------------------
# m30_absent name=value … — ONE assertion that names every absent field.
#
# M29's remedy, carried. A comparison whose two sides could both be `MISSING` is a
# comparison that passes for the wrong reason, and `test 5 -eq MISSING` is a bash ERROR that
# `assert_false` reads as the false it wanted. Run this BEFORE the first comparison, with a
# `die` behind it: a report with no data in it is a failure, not a smaller check.
# ---------------------------------------------------------------------------
m30_absent() { # <name=value> …
  local out="" pair name value
  for pair in "$@"; do
    name="${pair%%=*}"
    value="${pair#*=}"
    case "$value" in
      ""|MISSING|None) out="$out $name" ;;
    esac
  done
  printf '%s\n' "${out# }"
}

# ---------------------------------------------------------------------------
# m30_native_tests — the Rust test suite for the resolver, run HERE.
#
# The page proves the module does it; this proves the SOURCE does it, in the same run, so a
# page measurement over a stale module cannot stand in for either. Bounded, and it needs the
# sibling `codetracer-trace-format` dev shell because `noir`'s workspace resolves
# `codetracer_trace_writer` to the Nim FFI crate whose `build.rs` wants `nim` on PATH — a
# misdiagnosis of exactly that once hid six failing tests for a whole milestone
# (`CAMPAIGN-BRIEF.md`, "IT DOES NOT BUILD HERE IS A CLAIM").
# ---------------------------------------------------------------------------
M30_CARGO_TIMEOUT="${M30_CARGO_TIMEOUT:-1200}"
# Sets `M30_CARGO_LOG` and `M30_CARGO_RC` rather than PRINTING the log path, so no caller is
# tempted to write `m30_native_tests foo` inside `$( … )` — where the `die` below would exit
# the subshell and leave the caller carrying on with an empty string. That family has now
# appeared six times in this campaign and `lib_m28_gate.sh:95-102` is its write-up.
M30_CARGO_LOG=""
M30_CARGO_RC=""
m30_native_tests() { # <package>
  local pkg="$1"
  M30_CARGO_LOG="$M30_WORK/cargo-$pkg.log"
  mkdir -p "$M30_WORK"
  TMPDIR="$M30_WORK" timeout -s KILL "$M30_CARGO_TIMEOUT" \
    direnv exec "$WORKSPACE_ROOT/codetracer-trace-format" \
    bash -c "cd '$M30_NOIR_ROOT' && cargo test -p $pkg" >"$M30_CARGO_LOG" 2>&1
  M30_CARGO_RC=$?
  if [ "$M30_CARGO_RC" = 124 ] || [ "$M30_CARGO_RC" = 137 ]; then
    die "cargo test -p $pkg did not finish within ${M30_CARGO_TIMEOUT}s and was killed. Log: $M30_CARGO_LOG"
  fi
  return 0
}
