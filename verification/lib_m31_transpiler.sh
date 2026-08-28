#!/usr/bin/env bash
# lib_m31_transpiler.sh — shared machinery for the M31 (`avm-transpiler` to WebAssembly) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M31 asserts that compiled Noir contract bytecode becomes AVM bytecode IN THE BROWSER, that the
# result is byte-identical to the native transpiler's, and that the debug map survives the trip
# still keyed by AVM byte offset — which is what M25's OQ-5 verdict, and therefore rung-1 source
# mapping, rests on. Its checks read ONE thing:
#
#   the transpiler arm report — `tools/run_transpiler_arms.mjs`, which runs the NATIVE binary,
#   the module in NODE and the module in CHROMIUM over the same fixtures, measured once and
#   shared. M20's convention, kept by M22 through M30.
#
# WHAT GOES INTO IT, AND WHERE EACH PIECE COMES FROM:
#
#   avm-transpiler        `aztec-packages` at the campaign anchor `233d8e0993`, from the OBJECT
#                         STORE, with the prepared upstream patch applied during materialisation
#                         so the patch is exercised rather than merely filed
#   noir                  the commit that anchor's `noir/noir-repo` SUBMODULE pins,
#                         `40d6574f…` (1.0.0-beta.26) — which in this workspace is an EMPTY
#                         DIRECTORY and had to be materialised before anything could build
#   avm-transpiler-wasm   this repository's shim crate: an allocator and a flat return over
#                         upstream's own `avm_transpile_bytecode`
#   the fixtures          `fixtures/transpiler-contracts/`, six Noir contracts, COMPILED by the
#                         nargo built from that same noir. Never committed as JSON: an artifact
#                         nobody re-derives is a constant that rots.
#
# EVERY SUBPROCESS IS BOUNDED, for M23's review's reason: a check that hangs reports nothing at
# all and blocks the sweep behind it, which is worse than one that fails.

M31_WORK="${M31_WORK:-$HOME/.cache/aztec-m31-arms}"
export M31_WORK

M31_ARMS="$M31_WORK/transpiler.json"
export M31_ARMS

# The BUILD tree, which is a different directory from the arm report's and is deliberately
# spelled with a different variable — see `build_avm_transpiler_wasm.sh`'s note on the name
# collision that made a mutation arm go green.
M31_BUILD_WORK="${M31_BUILD_WORK:-$HOME/.cache/aztec-m31-transpiler}"
M31_BUILD_DIR="$M31_BUILD_WORK"
export M31_BUILD_WORK
M31_PAGE_DIR="$REPO_ROOT/verification/m31/page"
M31_SHIM="$REPO_ROOT/avm-transpiler-wasm"
M31_FIXTURES="$REPO_ROOT/fixtures/transpiler-contracts"
M31_PATCH_DIR="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs/aztec-transpiler-core-ffi"
export M31_BUILD_DIR M31_PAGE_DIR M31_SHIM M31_FIXTURES M31_PATCH_DIR

M31_BUILD_TIMEOUT="${M31_BUILD_TIMEOUT:-3600}"
M31_ARMS_TIMEOUT="${M31_ARMS_TIMEOUT:-1800}"

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, carried the way `lib_m27_browser.sh`, `lib_m28_gate.sh`, `lib_m29_steps.sh`
# and `lib_m30_vfs.sh` carry it and for the same reason: a check that dies before `finish`
# prints no summary and reads as a SMALLER milestone rather than a red one — which is how
# `verify-m9` once came out 283 assertions short with nothing reported. The seventh copy;
# it declines to move into `lib.sh` for M22's own reason (the trap names its milestone in its
# own diagnostic, and a shared one would have to be disarmed by every check that does not want
# it).
# ---------------------------------------------------------------------------
_M31_FINISHED=0
m31_finish() {
  _M31_FINISHED=1
  finish
}
_m31_abnormal_exit() {
  local rc=$?
  [ "$_M31_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m31_summary_on_abnormal_exit() {
  trap _m31_abnormal_exit EXIT
}

# ---------------------------------------------------------------------------
# m31_bounded <seconds> <what> <command...>
#
# Returns the command's status, or DIES naming the command and the bound. NEVER call inside
# `$( … )`: a `die` in a subshell exits only the subshell and the caller carries on with an
# empty string. That family has now appeared seven times in this campaign.
# ---------------------------------------------------------------------------
m31_bounded() { # <seconds> <what> <command...>
  local secs="$1" what="$2"; shift 2
  mkdir -p "$M31_WORK"
  timeout -s KILL "$secs" "$@" >"$M31_WORK/bounded.log" 2>&1
  local rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    die "$what did not finish within ${secs}s and was killed. That is the HANG state reported as a
     failure rather than as silence. Command: $*  Output: $M31_WORK/bounded.log"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# m31_require_build — the module, the native binary and the fixture artifacts.
#
# Sets M31_MODULE / M31_NATIVE / M31_ARTIFACTS / M31_TREE from the build script's own output
# rather than recomputing the paths here, so the two cannot drift.
# ---------------------------------------------------------------------------
M31_MODULE=""
M31_NATIVE=""
M31_ARTIFACTS=""
M31_TREE=""
M31_AZTEC_REV=""
M31_NOIR_REV=""
m31_require_build() {
  mkdir -p "$M31_WORK"
  m31_bounded "$M31_BUILD_TIMEOUT" "the avm-transpiler wasm build" \
    "$VERIFY_DIR/build_avm_transpiler_wasm.sh" \
    || die "build_avm_transpiler_wasm.sh failed; see $M31_WORK/bounded.log"

  local line key value
  while IFS= read -r line; do
    key="${line%%=*}"; value="${line#*=}"
    case "$key" in
      TREE) M31_TREE="$value" ;;
      ARTIFACTS) M31_ARTIFACTS="$value" ;;
      NATIVE) M31_NATIVE="$value" ;;
      MODULE) M31_MODULE="$value" ;;
      AZTEC_REV) M31_AZTEC_REV="$value" ;;
      NOIR_REV) M31_NOIR_REV="$value" ;;
    esac
  done <"$M31_WORK/bounded.log"

  [ -n "$M31_MODULE" ] && [ -s "$M31_MODULE" ] || \
    die "the build reported success and no MODULE= line named an existing file (see $M31_WORK/bounded.log)"
  [ -n "$M31_NATIVE" ] && [ -x "$M31_NATIVE" ] || \
    die "the build reported success and no NATIVE= line named an executable"
  [ -n "$M31_ARTIFACTS" ] && [ -d "$M31_ARTIFACTS" ] || \
    die "the build reported success and no ARTIFACTS= line named a directory"
  export M31_MODULE M31_NATIVE M31_ARTIFACTS M31_TREE M31_AZTEC_REV M31_NOIR_REV
}

# ---------------------------------------------------------------------------
# m31_arms_newer_inputs — the staleness predicate.
#
# Prints the first input newer than the arm report, or nothing. TAKES FILES, NEVER
# DIRECTORIES: `find -newer <dir>` compares the DIRECTORY's own mtime, which changes when a
# file is added and not when one is edited (M20's review's finding).
# ---------------------------------------------------------------------------
m31_arms_newer_inputs() {
  local stamp="$M31_ARMS" f
  [ -s "$stamp" ] || { printf 'transpiler.json\n'; return 0; }
  find "$M31_PAGE_DIR" -type f ! -name '.*' -newer "$stamp" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/tools/run_transpiler_arms.mjs" "$REPO_ROOT/tools/browser_cdp.mjs" \
       "$REPO_ROOT/verification/m30/page/wasm_host.mjs" "$REPO_ROOT/ct-host/src/source_map.ts" \
    -newer "$stamp" -print -quit 2>/dev/null || true
  [ -n "${M31_MODULE:-}" ] && [ "$M31_MODULE" -nt "$stamp" ] && printf '%s\n' "$M31_MODULE"
  [ -n "${M31_NATIVE:-}" ] && [ "$M31_NATIVE" -nt "$stamp" ] && printf '%s\n' "$M31_NATIVE"
  if [ -n "${M31_ARTIFACTS:-}" ]; then
    for f in "$M31_ARTIFACTS"/*.json; do
      [ -f "$f" ] || continue
      [ "$f" -nt "$stamp" ] && printf '%s\n' "$f"
    done
  fi
  return 0
}

# ---------------------------------------------------------------------------
# m31_require_arms — the arm report, produced here.
# ---------------------------------------------------------------------------
m31_require_arms() {
  m31_require_build

  local chromium="${M31_CHROMIUM:-/usr/bin/chromium}"
  [ -x "$chromium" ] || die "no chromium at $chromium (set M31_CHROMIUM)"
  command -v node >/dev/null 2>&1 || die "node is required"

  local stale
  stale="$(m31_arms_newer_inputs | head -1)"
  if [ -z "$stale" ] && [ "${M31_ARMS_REFRESH:-0}" != "1" ]; then
    return 0
  fi

  # PID-UNIQUE TMP. Two concurrent runs shared `$M31_ARMS.tmp` once during development and one
  # `mv`d the other's file away; the loser reported "could not install" for a reason that had
  # nothing to do with its subject.
  note "re-measuring the transpiler arms (${stale:-forced}); this runs the native binary, the module in node and the module in a browser"
  M31_MODULE="$M31_MODULE" M31_NATIVE="$M31_NATIVE" M31_ARTIFACTS="$M31_ARTIFACTS" \
    M31_CHROMIUM="$chromium" \
    timeout -s KILL "$M31_ARMS_TIMEOUT" \
    node --experimental-strip-types "$REPO_ROOT/tools/run_transpiler_arms.mjs" "$M31_WORK" \
      >"$M31_ARMS.tmp.$$" 2>"$M31_WORK/arms.err.$$"
  local rc=$?
  if [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
    die "the transpiler arms run did not finish within ${M31_ARMS_TIMEOUT}s and was killed. That is
     the HANG state reported as a failure. stderr: $M31_WORK/arms.err.$$"
  fi
  if [ "$rc" -ne 0 ]; then
    # KEPT, NOT DELETED: the runner writes its report even when an arm threw, and that report is
    # the only thing that says WHICH arm threw. Overwriting the good one would destroy the
    # previous measurement too.
    mv -f "$M31_ARMS.tmp.$$" "$M31_WORK/transpiler-failed.json" 2>/dev/null || true
    die "the transpiler arms run exited $rc. The report it did write is at
     $M31_WORK/transpiler-failed.json and its stderr at $M31_WORK/arms.err.$$"
  fi
  mv -f "$M31_ARMS.tmp.$$" "$M31_ARMS" || die "could not install $M31_ARMS"

  stale="$(m31_arms_newer_inputs | head -1)"
  [ -z "$stale" ] || die "the arm report is still stale after a refresh; $stale is newer than it"
}

# ---------------------------------------------------------------------------
# m31_arm <dotted path> — one field out of the arm report.
#
# Prints `MISSING` rather than nothing for a path that is not there: two empty strings compare
# equal, and that is how five assertions in M29 went green over absent fields.
# ---------------------------------------------------------------------------
m31_arm() { # <dotted path>
  python3 - "$M31_ARMS" "$1" <<'PY'
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
# m31_absent name=value … — ONE assertion that names every absent field.
#
# M29's remedy, carried. Run BEFORE the first comparison with a `die` behind it: a report with
# no data in it is a failure, not a smaller check.
# ---------------------------------------------------------------------------
m31_absent() { # <name=value> …
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
# m31_wasm_imports <module> — the module's import section, one `module.name` per line.
#
# An INDEPENDENT leb128 walker rather than `wasm-tools` or `wasm-objdump`, deliberately: the
# claim "this module imports nothing that can read a clock" is worth a second reading taken by
# something other than the toolchain that produced it. Same instrument M30's review used.
# ---------------------------------------------------------------------------
m31_wasm_imports() { # <module>
  python3 - "$1" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
if b[:4] != b'\0asm':
    print('NOT-A-WASM-MODULE'); raise SystemExit(0)
i = 8
def u32(i):
    r = 0; s = 0
    while True:
        c = b[i]; i += 1; r |= (c & 0x7f) << s
        if not c & 0x80: return r, i
        s += 7
out = []
while i < len(b):
    sid = b[i]; i += 1
    size, i = u32(i)
    end = i + size
    if sid == 2:
        n, j = u32(i)
        for _ in range(n):
            ml, j = u32(j); mod = b[j:j+ml].decode(); j += ml
            nl, j = u32(j); nm = b[j:j+nl].decode(); j += nl
            k = b[j]; j += 1
            if k == 0: _, j = u32(j)
            elif k == 1:
                j += 1; lim = b[j]; j += 1; _, j = u32(j)
                if lim: _, j = u32(j)
            elif k == 2:
                lim = b[j]; j += 1; _, j = u32(j)
                if lim: _, j = u32(j)
            elif k == 3: j += 2
            out.append(f'{mod}.{nm}')
    i = end
for o in out:
    print(o)
PY
}

# ---------------------------------------------------------------------------
# m31_wasm_exports <module> — the module's export section, one name per line.
# ---------------------------------------------------------------------------
m31_wasm_exports() { # <module>
  python3 - "$1" <<'PY'
import sys
b = open(sys.argv[1], 'rb').read()
if b[:4] != b'\0asm':
    print('NOT-A-WASM-MODULE'); raise SystemExit(0)
i = 8
def u32(i):
    r = 0; s = 0
    while True:
        c = b[i]; i += 1; r |= (c & 0x7f) << s
        if not c & 0x80: return r, i
        s += 7
out = []
while i < len(b):
    sid = b[i]; i += 1
    size, i = u32(i)
    end = i + size
    if sid == 7:
        n, j = u32(i)
        for _ in range(n):
            nl, j = u32(j); nm = b[j:j+nl].decode(); j += nl
            j += 1; _, j = u32(j)
            out.append(nm)
    i = end
for o in out:
    print(o)
PY
}
