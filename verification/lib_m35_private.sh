#!/usr/bin/env bash
# lib_m35_private.sh — M35's shared machinery. Sourced after lib.sh and lib_m27_browser.sh.
#
# Everything here is M34's `lib_m34_wallet.sh` with the subject changed, deliberately: the arms
# runner, the staleness rule, the `MISSING`-rather-than-empty reader, the one-assertion absence
# guard and the abnormal-exit trap are all machinery this campaign has already paid for, and a
# second implementation of any of them would be a second answer to one question.
#
# The four properties worth restating, because each is a defect that shipped:
#
#   1. THE ARM SUBPROCESS IS BOUNDED. `timeout -s KILL` — a check that hangs reports nothing at all
#      and blocks the sweep behind it, which no exit trap can reach (M23's review).
#   2. THE FAILED RUN'S REPORT IS KEPT. The runner catches an arm failure, records it as
#      `arms.error` with the message and the stack, and still writes JSON; discarding it on a
#      non-zero exit throws away the only diagnostic (M27's finding).
#   3. THE READER PRINTS `MISSING`, NOT EMPTY. Two absent keys comparing equal is how two of M29's
#      assertions went green over a report with no data in it.
#   4. A CHECK THAT DIES STILL PRINTS A SUMMARY LINE. Without the trap a `die` reads as a SMALLER
#      milestone rather than a red one, which is a 283-assertion silent shrink in the case that
#      taught it.

M35_WORK="${M35_WORK:-$HOME/.cache/aztec-m35-private}"
export M35_WORK
M35_ARMS="$M35_WORK/private-execution.json"
export M35_ARMS
M35_DOC="$REPO_ROOT/PRIVATE-EXECUTION.md"
M35_ORACLES_SRC="$BROWSER_SRC/wallet/private_oracles.ts"
M35_EXEC_SRC="$BROWSER_SRC/wallet/private_execution.ts"
M35_DEMO_SRC="$REPO_ROOT/browser/demo/wallet_main.ts"
M35_VENDOR_PXE="$BROWSER_SRC/vendor/pxe"
M35_VENDOR_SIM="$BROWSER_SRC/vendor/simulator"
export M35_DOC M35_ORACLES_SRC M35_EXEC_SRC M35_DEMO_SRC M35_VENDOR_PXE M35_VENDOR_SIM
M35_ARMS_TIMEOUT="${M35_ARMS_TIMEOUT:-1800}"

# ---------------------------------------------------------------------------
# The abnormal-exit trap.
# ---------------------------------------------------------------------------
_M35_FINISHED=0
m35_finish() {
  _M35_FINISHED=1
  finish
}
_m35_abnormal_exit() {
  local rc=$?
  [ "$_M35_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m35_summary_on_abnormal_exit() {
  trap _m35_abnormal_exit EXIT
}

# ---------------------------------------------------------------------------
# The arms.
# ---------------------------------------------------------------------------
m35_arms_newer_inputs() {
  [ -s "$M35_ARMS" ] || { printf 'private-execution.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_private_execution_arms.mjs" -newer "$M35_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/tools/browser_cdp.mjs" -newer "$M35_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M35_ARMS" -print -quit 2>/dev/null || true
}

m35_require_arms() {
  m27_require_bundle
  m27_require_module
  m27_require_chromium
  mkdir -p "$M35_WORK"
  [ -s "$BROWSER_DIST/wallet-demo.js" ] \
    || die "there is no built wallet-demo entry at $BROWSER_DIST/wallet-demo.js.
             Remedy: just browser-build"
  [ -s "$BROWSER_DIST/wallet.html" ] \
    || die "there is no wallet demo page at $BROWSER_DIST/wallet.html.
             Remedy: just browser-build"

  local stale=0 newer rc
  newer="$(m35_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M35_ARMS_REFRESH:-0}" = "1" ] && stale=1

  if [ "$stale" = "1" ]; then
    note "running the private-execution arms in $M27_CHROMIUM_VERSION (timeout ${M35_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 BROWSER_DIST="$BROWSER_DIST" \
        AVM_WASM_PATH="$AVM_WASM_PATH" M27_CHROMIUM="$M27_CHROMIUM" \
        M27_CHROMIUM_VERSION="$M27_CHROMIUM_VERSION" \
        timeout -s KILL "$M35_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_private_execution_arms.mjs" "$M35_WORK" ) \
      > "$M35_ARMS.tmp" 2> "$M35_WORK/arms.stderr"
    rc=$?
    if [ "$rc" != "0" ]; then
      mv -f "$M35_ARMS.tmp" "$M35_WORK/arms.failed.json" 2>/dev/null || true
      # A TIMEOUT IS NAMED AS A TIMEOUT, WITH ITS BOUND. `timeout` exits 124, or 128+9 = 137 when it
      # escalates to SIGKILL. Reporting either as "exited 137" is a check pointing at nothing: a
      # process that never finishes and a process that failed are different findings and the remedy
      # differs. M34's own hang arm earned this sentence one milestone ago; M35's earned it again,
      # because the first version of that arm produced a fast 404 and read as a hang until the log
      # was opened.
      case "$rc" in
        124|137)
          die "the private-execution arm run did not finish within ${M35_ARMS_TIMEOUT}s and was killed
             (timeout exit $rc). That is a HANG rather than a failure: a page waited on something that
             never arrived. Raise M35_ARMS_TIMEOUT only after reading $M35_WORK/arms.stderr." ;;
      esac
      # THE KEPT REPORT'S OWN MESSAGE IS PUT IN THE DIAGNOSTIC RATHER THAN LEFT IN A FILE. The runner
      # catches every arm failure and records `arms.error.message`; a `die` that says only "exited 1"
      # is a check pointing at a path, and M34's first browser run is the record of what that costs.
      # Measured on M35's own hang arm: the message reads *"Runtime.evaluate did not complete within
      # 60000 ms. That is the HANG state reported as a failure"* — the bound and the state, from
      # M27's CDP client — and the `die` said "exited 1".
      local why
      why="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("(the kept report is not readable: %s)" % e); raise SystemExit(0)
print(str(d.get("arms", {}).get("error", {}).get("message", "(the report records no error)"))[:400])' \
        "$M35_WORK/arms.failed.json" 2>/dev/null || echo "(no kept report)")"
      die "the private-execution arm run exited $rc: $why
             See $M35_WORK/arms.stderr and $M35_WORK/arms.failed.json"
    fi
    mv -f "$M35_ARMS.tmp" "$M35_ARMS"
  fi
  [ -s "$M35_ARMS" ] || die "there is no arm report at $M35_ARMS even after running"
}

# m35_arm <dotted path under the report's `arms` object>
#
# Prints `MISSING` for an absent key rather than the empty string, so two absent values cannot
# compare equal. Lists and objects render as compact sorted JSON; booleans as true/false.
m35_arm() {
  python3 - "$M35_ARMS" "$1" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
node = doc.get('arms', {})
for part in sys.argv[2].split('.'):
    if isinstance(node, list):
        try:
            node = node[int(part)]
            continue
        except (ValueError, IndexError):
            print('MISSING'); raise SystemExit(0)
    if not isinstance(node, dict) or part not in node:
        print('MISSING'); raise SystemExit(0)
    node = node[part]
if isinstance(node, bool):
    print('true' if node else 'false')
elif node is None:
    print('null')
elif isinstance(node, (list, dict)):
    print(json.dumps(node, separators=(',', ':'), sort_keys=True, ensure_ascii=False))
else:
    print(node)
PY
}

# m35_top <dotted path from the report ROOT> — for `assets`, `module`, `chromium`.
m35_top() {
  python3 - "$M35_ARMS" "$1" <<'PY'
import json, sys
node = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    if not isinstance(node, dict) or part not in node:
        print('MISSING'); raise SystemExit(0)
    node = node[part]
print(json.dumps(node, separators=(',', ':'), sort_keys=True, ensure_ascii=False)
      if isinstance(node, (list, dict)) else node)
PY
}

# m35_absent <name=value>... — ONE assertion naming every absent field, then a die.
m35_absent() {
  local bad="" pair
  for pair in "$@"; do
    case "$pair" in
      *=MISSING) bad="$bad ${pair%%=*}" ;;
    esac
  done
  assert_eq "every field this check reads is present in the arm report" "" "$bad"
  [ -z "$bad" ] || die "the arm report is missing:$bad
             A report with no data in it is a failure, not a smaller check. See $M35_ARMS."
}

# The oracle registry, re-derived from a given `oracle_registry.ts`. Prints KEY<TAB>VALUE lines.
m35_registry() { # <oracle_registry.ts> [<legacy_oracle_registry.ts>]
  python3 "$VERIFY_DIR/_m35_oracles.py" "$@"
}

# The `cpp` anchor's commit, read from pins.json rather than typed. M33's helper, reused.
m35_cpp_anchor() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
    "$REPO_ROOT/pins.json"
}

# A file at the anchor, out of the fork's OBJECT STORE rather than out of a worktree — which is the
# whole of RI-65's warning: the checked-out `upstream/tsavm` copy of the registry is fifteen entries
# short of the anchor's.
m35_anchor_show() { # <path under the aztec-packages tree>
  git -C "$FORK_ROOT" show "$(m35_cpp_anchor):$1" 2>/dev/null
}
