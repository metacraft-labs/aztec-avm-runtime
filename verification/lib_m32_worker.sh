#!/usr/bin/env bash
# lib_m32_worker.sh — shared machinery for the M32 (worker-hosted dev node) checks.
#
# Not to be executed directly: sourced after lib.sh, lib_m23_chain.sh and lib_m27_browser.sh.
#
# ===========================================================================================
# IT SITS ON M27'S MACHINERY RATHER THAN BESIDE IT
# ===========================================================================================
#
# The module search, the module's required export set, the bundle build and its staleness predicate,
# and the chromium discovery are all M27's and are REUSED here unchanged — `m27_require_module`,
# `m27_require_bundle`, `m27_require_chromium`. M32 builds the worker into the SAME `browser/dist`
# out of the SAME esbuild pass, so a second bundle predicate would be a second answer to one
# question. What M32 adds is its own arm run.
#
# THE ARMS ARE MEASURED ONCE AND SHARED, which is M20's convention kept by every milestone since.
# Four checks each launching a browser is four browsers and four chances to disagree about a number
# nothing changed.
#
# EVERY SUBPROCESS IS BOUNDED, and a worker adds a way to hang that a page does not have: a
# `terminate()` under an outstanding request leaves a promise nothing can settle. The client bounds
# its own calls; this file bounds the run.

M32_WORK="${M32_WORK:-$HOME/.cache/aztec-m32-worker}"
export M32_WORK

M32_ARMS="$M32_WORK/worker.json"
export M32_ARMS

M32_DOC="$REPO_ROOT/WORKER-NODE.md"
M32_PROTOCOL_SRC="$BROWSER_SRC/worker_protocol.ts"
M32_WORKER_SRC="$BROWSER_SRC/entry_worker.ts"
M32_CLIENT_SRC="$BROWSER_SRC/worker_client.ts"
M32_DEMO_SRC="$BROWSER_DIR/demo/worker_main.ts"
export M32_DOC M32_PROTOCOL_SRC M32_WORKER_SRC M32_CLIENT_SRC M32_DEMO_SRC

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, for M21's review's reason: a check that dies before `finish` prints no summary
# and reads as a SMALLER milestone rather than a red one — which once took M1 from 151 to 141 with
# nothing reported as failing. M22 said a third milestone wanting it is when it moves into `lib.sh`;
# M23, M24 and M27 each declined for M22's own reason, and M32 declines for the same one. The copies
# are independent by design.
# ---------------------------------------------------------------------------
# DELEGATED TO `lib.sh` ON 2026-08-31. These eight lines were copied into FOURTEEN
# milestone libraries, m22..m37. M22 wrote them and said the third milestone wanting
# them is when they move into `lib.sh`; M24 declined for M22's own reason and recorded
# it as owed. The fifteenth caller turned out to be M9 — not a new milestone but the
# campaign's oldest open item — so the move is made and these are wrappers. The public
# names are unchanged, so no check needed editing, and the behaviour is identical: one
# implementation instead of fourteen, verified by the sweep.
m32_finish() { finish; }
m32_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# A bounded subprocess whose overrun is a named failure rather than a hang.
m32_bounded() { # <seconds> <what> <command...>
  local secs="$1" what="$2"; shift 2
  mkdir -p "$M32_WORK"
  timeout -s KILL "$secs" "$@" >"$M32_WORK/bounded.log" 2>&1
  local rc=$?
  if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
    die "$what did not finish within ${secs}s and was killed.
             That is the HANG state CAMPAIGN-BRIEF.md names, reported as a failure rather than as
             silence. Output: $M32_WORK/bounded.log"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# The arm run.
# ---------------------------------------------------------------------------
m32_arms_newer_inputs() {
  [ -s "$M32_ARMS" ] || { printf 'worker.json\n'; return 0; }
  find "$AVM_WASM_PATH" "$REPO_ROOT/tools/run_worker_arms.mjs" "$REPO_ROOT/tools/browser_cdp.mjs" \
    -newer "$M32_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M32_ARMS" -print -quit 2>/dev/null || true
}

M32_ARMS_TIMEOUT="${M32_ARMS_TIMEOUT:-900}"
m32_require_arms() {
  m27_require_module
  m27_require_bundle
  m27_require_chromium
  mkdir -p "$M32_WORK"

  # THE WORKER ENTRY MUST BE IN THE BUILT BUNDLE BEFORE ANYTHING ELSE. A check that ran the arms
  # against a `browser/dist` from before M32 would get a page that cannot find `./worker.js`, and
  # the failure would read as a browser problem rather than as a stale build.
  local missing=""
  local f
  for f in worker.js worker-demo.js worker.html; do
    [ -s "$BROWSER_DIST/$f" ] || missing="$missing $f"
  done
  [ -z "$missing" ] || die "the built bundle is missing:$missing
             Remedy: node browser/build.mjs (or just browser-build)."

  local stale=0 newer
  newer="$(m32_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M32_ARMS_REFRESH:-0}" = "1" ] && stale=1

  if [ "$stale" = "1" ]; then
    note "running the worker arms against $AVM_WASM_PATH in $M27_CHROMIUM_VERSION (timeout ${M32_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 \
        AVM_WASM_PATH="$AVM_WASM_PATH" M32_CHROMIUM="$M27_CHROMIUM" M32_WORK="$M32_WORK" \
        timeout -s KILL "$M32_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_worker_arms.mjs" "$M32_WORK" ) \
      > "$M32_ARMS.tmp" 2> "$M32_WORK/worker.stderr"
    local rc=$?
    # THE FAILED RUN'S OWN REPORT IS KEPT, which is M27's lesson: the runner catches an arm's failure,
    # records it as `arms.error` with the message and the stack, and writes the JSON — so discarding
    # the temporary file on a non-zero exit throws away the ONLY diagnostic.
    if [ "$rc" -ne 0 ] && [ -s "$M32_ARMS.tmp" ]; then
      mv "$M32_ARMS.tmp" "$M32_WORK/worker-failed.json"
    fi
    if [ "$rc" -eq 137 ] || [ "$rc" -eq 124 ]; then
      die "the worker arm run did not finish within ${M32_ARMS_TIMEOUT}s and was killed.
             A worker that never announces readiness, a call whose reply never arrives, or a
             renderer that never exits all look like this.
             See $M32_WORK/worker.stderr and $M32_WORK/worker-failed.json."
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
' "$M32_WORK/worker-failed.json" 2>/dev/null)"
      die "the worker arm run failed (exit $rc): ${why:-(no report)}
             Full report: $M32_WORK/worker-failed.json; stderr: $M32_WORK/worker.stderr"
    fi
    mv "$M32_ARMS.tmp" "$M32_ARMS" \
      || die "the worker arm run succeeded but its report could not be installed at $M32_ARMS"
  fi
  [ -s "$M32_ARMS" ] || die "the worker arm run produced no output"
  # M27's rule: an arm report that outlives the tree it was measured on is the defect
  # CAMPAIGN-BRIEF.md calls "a mutated artefact outlived its restored source".
  if [ "$stale" = "1" ]; then
    local still
    still="$(m32_arms_newer_inputs)"
    [ -z "$still" ] || die "the worker arm run did not refresh $M32_ARMS: '$still' is still newer than it."
  fi
}

# One field of one arm. Prints `MISSING` rather than empty, so an assertion against a typo'd path
# FAILS instead of comparing two absences.
m32_arm() { # <arm-name> <dotted path>
  python3 - "$M32_ARMS" "$1" "$2" <<'PY'
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
m32_run() { # <dotted path>
  python3 - "$M32_ARMS" "$1" <<'PY'
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

# ---------------------------------------------------------------------------
# M29'S REMEDY, KEPT: ONE assertion naming every absent field, with a `die` behind it.
#
# M29 pointed five assertions at a path that does not exist; `m29_arm` printed `MISSING` and two of
# the five went GREEN, and a third made a CONTROL pass on a bash syntax error (`test 516 -eq
# MISSING`). The remedy that generalises is not another `!= MISSING` per value — it is this: run it
# BEFORE the first comparison, and treat a report with no data in it as a failure rather than as a
# smaller check.
# ---------------------------------------------------------------------------
m32_absent() { # <name=value>...
  local bad="" pair
  for pair in "$@"; do
    case "$pair" in
      *=MISSING) bad="$bad ${pair%%=*}" ;;
    esac
  done
  assert_eq "every field this check reads is present in the arm report" "" "$bad"
  [ -z "$bad" ] || die "the arm report is missing:$bad
             A report with no data in it is a failure, not a smaller check. See $M32_ARMS."
}

# The built worker bundle's own exported declarations, read by IMPORTING the artefact.
#
# M27's rule for `NODE_CONVENIENCES`: a comment cannot be compared with a bundle, so the protocol
# declarations are exported from `entry_worker.ts` and read back out of `browser/dist/worker.js`.
# The module's `Comlink.expose` is guarded by `isWorkerScope()` — `DedicatedWorkerGlobalScope` does
# not exist in Node — so importing it here evaluates the declarations and exposes nothing.
m32_worker_bundle_value() { # <expression over the imported module `m`>
  ( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./worker.js');
const v = ($1);
console.log(typeof v === 'string' ? v : JSON.stringify(v));
" 2>&1 )
}

m32_bundle_exports() { # <file relative to BROWSER_DIST>
  ( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./$1');
console.log(Object.keys(m).sort().join('\n'));
" 2>&1 )
}
