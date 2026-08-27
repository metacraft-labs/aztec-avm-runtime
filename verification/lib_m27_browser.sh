#!/usr/bin/env bash
# lib_m27_browser.sh — shared machinery for the M27 (browser packaging and code splitting) checks.
#
# Not to be executed directly: sourced after lib.sh by verification/*.sh.
#
# M27 puts the runtime in a BROWSER. Its checks read four things: this repository's own sources and
# documents, the BUILT browser bundle (`browser/dist/`), ONE run of the browser arms — a real
# headless Chromium driven over the DevTools protocol — and the `.ct` container that run downloaded.
#
# THE ARMS ARE MEASURED ONCE AND SHARED, which is M20's convention kept by M22, M23, M24, M25 and
# M26. Seven checks each launching their own browser is seven chances for two of them to disagree
# about a number nothing changed, and it is also seven browsers.
#
# EVERY SUBPROCESS HERE IS BOUNDED. `CAMPAIGN-BRIEF.md` names the three states a check can be in —
# green, red, and HUNG — and says the third is worse than the second because it reports nothing at
# all and blocks the sweep behind it. A browser is the most hang-prone thing in this campaign: a
# page that never fires `load`, a promise that never settles, a renderer that never exits. So the
# bundle build, the browser run and the reader all run under `timeout -s KILL`, and exceeding the
# bound is a NAMED failure.

M27_WORK="${M27_WORK:-$HOME/.cache/aztec-m27-browser}"
export M27_WORK

M27_ARMS="$M27_WORK/browser.json"
export M27_ARMS

ORCH_DIR="${ORCH_DIR:-$REPO_ROOT/orchestration}"
ORCH_SRC="${ORCH_SRC:-$ORCH_DIR/src}"
BROWSER_DIR="${BROWSER_DIR:-$REPO_ROOT/browser}"
BROWSER_SRC="$BROWSER_DIR/src"
BROWSER_DIST="${BROWSER_DIST:-$BROWSER_DIR/dist}"
M27_DOC="$REPO_ROOT/BROWSER-PACKAGING.md"
M27_BUDGETS="$BROWSER_DIR/chunk-budgets.json"
M27_PATCH="$REPO_ROOT/verification/m27/0001-test-vm2-export-poseidon2-and-grumpkin-from-the-reac.patch"
export ORCH_DIR ORCH_SRC BROWSER_DIR BROWSER_SRC BROWSER_DIST M27_DOC M27_BUDGETS M27_PATCH

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, for M21's review's reason: a check that dies before `finish` prints no summary
# and reads as a SMALLER milestone rather than a red one, which once took M1 from 151 to 141 with
# nothing reported as failing. M22 said a third milestone wanting it is when it moves into
# `lib.sh`; M23 and M24 both declined to move it for M22's own reason (changing the abnormal-exit
# behaviour of a hundred and fifty checks does not belong in a commit about a chain loop, a writer,
# or a browser bundle), and M27 declines for the same reason. The copies are independent by design.
# ---------------------------------------------------------------------------
_M27_FINISHED=0
m27_finish() {
  _M27_FINISHED=1
  finish
}
_m27_abnormal_exit() {
  local rc=$?
  [ "$_M27_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m27_summary_on_abnormal_exit() {
  trap _m27_abnormal_exit EXIT
}

# A bounded subprocess whose overrun is a named failure rather than a hang.
# Usage: m27_bounded <seconds> <what> <command...>
m27_bounded() {
  local secs="$1" what="$2"; shift 2
  mkdir -p "$M27_WORK"
  timeout -s KILL "$secs" "$@" >"$M27_WORK/bounded.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
    die "$what did not finish within ${secs}s and was killed.
             That is the HANG state CAMPAIGN-BRIEF.md names, reported as a failure rather than as
             silence. Output: $M27_WORK/bounded.log"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# The module. M27's is the THIRTEENTH overlay and a different artefact from M23's twelve.
# ---------------------------------------------------------------------------
M27_CRYPTO_EXPORTS='avm_poseidon2_hash
avm_poseidon2_permutation
avm_grumpkin_mul
avm_grumpkin_add'
export M27_CRYPTO_EXPORTS

# M23's required set (a chain drives everything a block drives and then seals) plus the FOUR
# crypto exports. A browser page runs the same chain; what it additionally needs is the hash and the
# curve, because the alternative is downloading a second barretenberg for them.
M27_REQUIRED_EXPORTS="$M23_REQUIRED_EXPORTS
$M27_CRYPTO_EXPORTS"
export M27_REQUIRED_EXPORTS

m27_module_exports() { # <path>
  node -e '
const fs = require("fs");
const m = new WebAssembly.Module(fs.readFileSync(process.argv[1]));
for (const e of WebAssembly.Module.exports(m)) console.log(e.name);
' "$1"
}

m27_find_module() {
  if [ -n "${AVM_WASM_PATH:-}" ]; then
    printf '%s\n' "$AVM_WASM_PATH"
    return 0
  fi
  local candidate
  # DELIBERATELY SHORT, for M23's reason: every earlier milestone's module would be rejected here
  # for want of the poseidon2 exports, and a preference order whose every fallback is rejected only
  # makes the failure slower to read.
  for candidate in \
    "$M27_WORK/avm.wasm" \
    "$M27_WORK/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
  do
    [ -s "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

m27_require_module() {
  AVM_WASM_PATH="$(m27_find_module)" || die "no built avm.wasm with the crypto exports was found.
             Looked at \$AVM_WASM_PATH and $M27_WORK.
             Remedy: just avm-wasm-build-m27, then set AVM_WASM_PATH."
  export AVM_WASM_PATH
  local have missing want
  have="$(m27_module_exports "$AVM_WASM_PATH")"
  missing=""
  while IFS= read -r want; do
    [ -n "$want" ] || continue
    str_has_line "$have" "$want" || missing="$missing $want"
  done <<< "$M27_REQUIRED_EXPORTS"
  [ -z "$missing" ] || die "the module at $AVM_WASM_PATH is missing:$missing
             M27 executes in a browser, where the alternative to this module's own poseidon2 and
             grumpkin is downloading 7.9 MB of proving stack for a hash and a curve addition.
             Build one from M27's overlay stack: just avm-wasm-build-m27."
  M27_MODULE_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
  M27_MODULE_EXPORT_COUNT="$(printf '%s\n' "$have" | grep -c .)"
  M27_MODULE_BYTES="$(stat -c %s "$AVM_WASM_PATH")"
  export M27_MODULE_SHA M27_MODULE_EXPORT_COUNT M27_MODULE_BYTES
}

# THE BROWSER PACKAGE SHARES THE ORCHESTRATION'S INSTALLED TREE, BY SYMLINK.
#
# `browser/` declares no dependencies of its own. It packages the orchestration's, and the
# alternative — a second `package.json` carrying the pinned @aztec nightly — would put a second
# nightly literal in the repository, need a `pins.json` `npm_consumers` entry, move
# `verify_pinned_nightly_single_source` (and therefore M1), and install nine hundred packages twice,
# all to express "the same dependency set". The symlink is gitignored and is recreated here, so a
# fresh clone does not have to know about it.
m27_require_packages() {
  [ -d "$ORCH_DIR/node_modules/@aztec/stdlib" ] \
    || die "the orchestration's @aztec/* packages are not installed.
             Remedy: cd $ORCH_DIR && npm ci"
  if [ ! -e "$BROWSER_DIR/node_modules" ]; then
    ln -sfn ../orchestration/node_modules "$BROWSER_DIR/node_modules"
  fi
  [ -d "$BROWSER_DIR/node_modules/@aztec/stdlib" ] \
    || die "browser/node_modules does not reach the orchestration's packages.
             It is a symlink to ../orchestration/node_modules; remove it and re-run."
}

# esbuild. It is NOT installed under browser/ and that is deliberate: it already exists twice in
# this checkout, and the campaign's reuse discipline says to look in the parallel subdirectory
# before installing anything. `spike/` is preferred over `diffsim/` only because it is the tree
# the design document's own §8.5 browser measurement was taken in.
m27_esbuild() {
  local candidate
  for candidate in "$REPO_ROOT/spike/node_modules/.bin/esbuild" "$REPO_ROOT/diffsim/node_modules/.bin/esbuild"; do
    [ -x "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

m27_require_esbuild() {
  M27_ESBUILD="$(m27_esbuild)" \
    || die "esbuild is not installed. It ships in spike/node_modules and diffsim/node_modules.
             Remedy: cd $REPO_ROOT/spike && npm install"
  export M27_ESBUILD
}

# Chromium. It comes from the ambient system rather than from the nix dev shell, so it is PINNED BY
# MEASUREMENT rather than assumed: the check records the version it ran against, the way M19's
# review's PATH pin records which `wasm-opt` a compile saw.
m27_require_chromium() {
  M27_CHROMIUM="${M27_CHROMIUM:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)}"
  [ -n "$M27_CHROMIUM" ] || die "no chromium on PATH. The browser checks drive a real headless
             browser over the DevTools protocol; there is no substitute that would be evidence.
             Remedy: install chromium, or set M27_CHROMIUM."
  M27_CHROMIUM_VERSION="$("$M27_CHROMIUM" --version 2>/dev/null | head -1)"
  export M27_CHROMIUM M27_CHROMIUM_VERSION
}

# ---------------------------------------------------------------------------
# The bundle.
# ---------------------------------------------------------------------------
m27_bundle_newer_inputs() { # -> prints the first input newer than the metafile, or nothing
  local stamp="$BROWSER_DIST/meta.json"
  [ -s "$stamp" ] || { printf 'meta.json\n'; return 0; }
  find "$BROWSER_SRC" "$BROWSER_DIR/demo" -type f ! -name '.*' -newer "$stamp" -print -quit 2>/dev/null || true
  find "$ORCH_SRC" "$REPO_ROOT/ct-host/src" -type f ! -name '.*' -newer "$stamp" -print -quit 2>/dev/null || true
  find "$BROWSER_DIR/build.mjs" "$M27_BUDGETS" -newer "$stamp" -print -quit 2>/dev/null || true
}

M27_BUILD_TIMEOUT="${M27_BUILD_TIMEOUT:-300}"
m27_require_bundle() {
  m27_require_esbuild
  m27_require_packages
  local newer
  newer="$(m27_bundle_newer_inputs)"
  if [ -n "$newer" ] || [ "${M27_BUNDLE_REFRESH:-0}" = "1" ]; then
    note "building the browser bundle (input newer than the metafile: $newer)"
    m27_bounded "$M27_BUILD_TIMEOUT" "the browser bundle build" \
      node "$BROWSER_DIR/build.mjs" \
      || die "the browser bundle build failed; see $M27_WORK/bounded.log"
  fi
  [ -s "$BROWSER_DIST/meta.json" ] || die "there is no $BROWSER_DIST/meta.json even after building"
}

# One field out of the esbuild metafile, as compact JSON. Prints MISSING rather than empty, so a
# typo'd key FAILS instead of comparing two absences.
m27_meta() { # <python expression over `m`>
  python3 - "$BROWSER_DIST/meta.json" "$1" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
try:
    v = eval(sys.argv[2], {'m': m, 'json': json, 'sorted': sorted, 'len': len, 'sum': sum, 'set': set, 'any': any, 'all': all})
except Exception as e:
    print('MISSING'); sys.exit(0)
if v is None:
    print('MISSING')
elif isinstance(v, (list, dict, set)):
    print(json.dumps(sorted(v) if isinstance(v, set) else v, separators=(',', ':'), sort_keys=True))
else:
    print(v)
PY
}

# ---------------------------------------------------------------------------
# The browser arm run. Produced once; read by every behavioural M27 check.
# ---------------------------------------------------------------------------
m27_arms_newer_inputs() {
  [ -s "$M27_ARMS" ] || { printf 'browser.json\n'; return 0; }
  find "$AVM_WASM_PATH" "$REPO_ROOT/tools/run_browser_arms.mjs" "$REPO_ROOT/tools/browser_cdp.mjs" \
    -newer "$M27_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M27_ARMS" -print -quit 2>/dev/null || true
}

M27_ARMS_TIMEOUT="${M27_ARMS_TIMEOUT:-600}"
m27_require_arms() {
  m27_require_module
  m27_require_bundle
  m27_require_chromium
  mkdir -p "$M27_WORK"

  local stale=0 newer
  newer="$(m27_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M27_ARMS_REFRESH:-0}" = "1" ] && stale=1

  if [ "$stale" = "1" ]; then
    note "running the browser arms against $AVM_WASM_PATH in $M27_CHROMIUM_VERSION (timeout ${M27_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 \
        AVM_WASM_PATH="$AVM_WASM_PATH" M27_CHROMIUM="$M27_CHROMIUM" M27_WORK="$M27_WORK" \
        timeout -s KILL "$M27_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_browser_arms.mjs" "$M27_WORK" ) \
      > "$M27_ARMS.tmp" 2> "$M27_WORK/browser.stderr"
    local rc=$?
    # THE FAILED RUN'S OWN REPORT IS KEPT, and that is not tidiness. The runner catches an arm's
    # failure, records it as `arms.error` with the message and the stack, and writes the JSON — so
    # discarding `$M27_ARMS.tmp` on a non-zero exit throws away the ONLY diagnostic. Measured: the
    # deliberate HANG mutation produced an empty `browser.stderr` and a `die` that named it, which
    # is a check reporting a failure while pointing at nothing.
    if [ -s "$M27_ARMS.tmp" ]; then
      mv "$M27_ARMS.tmp" "$M27_WORK/browser-failed.json"
    fi
    if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
      die "the browser arm run did not finish within ${M27_ARMS_TIMEOUT}s and was killed.
             A page that never fires load, a promise that never settles or a renderer that never
             exits all look like this.
             See $M27_WORK/browser.stderr and $M27_WORK/browser-failed.json."
    fi
    if [ "$rc" -ne 0 ]; then
      local why
      why="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("(no readable report: %s)" % e); raise SystemExit(0)
err = d.get("arms", {}).get("error")
print(err.get("message", "(no message)") if err else "(the run failed with no recorded arm error)")
' "$M27_WORK/browser-failed.json" 2>/dev/null)"
      die "the browser arm run failed (exit $rc): ${why:-(no report)}
             Full report: $M27_WORK/browser-failed.json; stderr: $M27_WORK/browser.stderr"
    fi
    mv "$M27_ARMS.tmp" "$M27_ARMS"
  fi
  [ -s "$M27_ARMS" ] || die "the browser arm run produced no output"
}

# One field of one arm, from the shared JSON. Prints `MISSING` rather than empty, so an assertion
# against a typo'd arm name FAILS instead of comparing two absences.
m27_arm() { # <arm-name> <dotted path>
  python3 - "$M27_ARMS" "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1]))
node = data.get('arms', {}).get(sys.argv[2])
if node is None:
    print('MISSING'); sys.exit(0)
for part in sys.argv[3].split('.'):
    if part == '':
        continue
    if isinstance(node, dict) and part in node:
        node = node[part]
    elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
        node = node[int(part)]
    else:
        print('MISSING'); sys.exit(0)
if node is None:
    print('MISSING')
elif isinstance(node, (list, dict)):
    print(json.dumps(node, separators=(',', ':'), sort_keys=True))
elif isinstance(node, bool):
    print('true' if node else 'false')
else:
    print(node)
PY
}

# A top-level field of the arm run (not inside `arms`).
m27_run() { # <dotted path>
  python3 - "$M27_ARMS" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    if isinstance(node, dict) and part in node:
        node = node[part]
    else:
        print('MISSING'); sys.exit(0)
if node is None:
    print('MISSING')
elif isinstance(node, (list, dict)):
    print(json.dumps(node, separators=(',', ':'), sort_keys=True))
elif isinstance(node, bool):
    print('true' if node else 'false')
else:
    print(node)
PY
}
