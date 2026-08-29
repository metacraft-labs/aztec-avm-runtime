#!/usr/bin/env bash
# lib_m33_wallet.sh — shared machinery for the M33 (wallet protocol boundary) checks.
#
# Not to be executed directly: sourced after lib.sh and lib_m27_browser.sh.
#
# ===========================================================================================
# IT SITS ON M27'S MACHINERY, LIKE M32's, AND FOR THE SAME REASON
# ===========================================================================================
#
# The bundle build and its staleness predicate are M27's and are REUSED unchanged
# (`m27_require_bundle`). M33 builds the wallet entry into the SAME `browser/dist` out of the SAME
# esbuild pass, so a second bundle predicate would be a second answer to one question.
#
# WHAT M33 DOES NOT NEED IS A BROWSER. M32's arms had to be in Chromium because their subject was
# a Web Worker, CPU throttling and `Page.setWebLifecycleState`. M33's subject is a `MessagePort` and
# WebCrypto, both of which Node 24 implements to the same specifications, so the arms import the
# BUILT bundle and run the real handshake in-process. That is a smaller claim and it is stated as
# one: see `WALLET-BOUNDARY.md` §5, and `verify_provider_half_dd9_clean`, which is the check that
# says the artefact is browser-shaped.
#
# THE ARMS ARE MEASURED ONCE AND SHARED, which is M20's convention kept by every milestone since.

M33_WORK="${M33_WORK:-$HOME/.cache/aztec-m33-wallet}"
export M33_WORK

M33_ARMS="$M33_WORK/wallet.json"
export M33_ARMS

M33_DOC="$REPO_ROOT/WALLET-BOUNDARY.md"
M33_ENTRY_SRC="$BROWSER_SRC/entry_wallet.ts"
M33_PROVIDER_SRC="$BROWSER_SRC/wallet/port_wallet_provider.ts"
M33_HANDLER_SRC="$BROWSER_SRC/wallet/port_connection_handler.ts"
M33_NULL_SRC="$BROWSER_SRC/wallet/null_wallet.ts"
M33_VENDOR_DIR="$BROWSER_SRC/vendor/wallet_sdk"
export M33_DOC M33_ENTRY_SRC M33_PROVIDER_SRC M33_HANDLER_SRC M33_NULL_SRC M33_VENDOR_DIR

M33_ARMS_TIMEOUT="${M33_ARMS_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, for M21's review's reason: a check that dies before `finish` prints no summary
# and reads as a SMALLER milestone rather than a red one — which once took M1 from 151 to 141 with
# nothing reported as failing. M22 said a third milestone wanting it is when it moves into `lib.sh`;
# M23, M24, M27 and M32 each declined for M22's own reason, and M33 declines for the same one. The
# copies are independent by design.
# ---------------------------------------------------------------------------
_M33_FINISHED=0
m33_finish() {
  _M33_FINISHED=1
  finish
}
_m33_abnormal_exit() {
  local rc=$?
  [ "$_M33_FINISHED" = "1" ] && return 0
  printf '%s: %d assertion(s), %d failure(s)\n' "$TEST_NAME" "$_ASSERTIONS" "$((_FAILURES + 1))"
  printf '%s: FAIL — exited (status %d) before finish; the summary above counts that as a failure\n' \
    "$TEST_NAME" "$rc" >&2
}
m33_summary_on_abnormal_exit() {
  trap _m33_abnormal_exit EXIT
}

# Every subprocess is bounded, and exceeding the bound is a NAMED failure rather than a hang.
m33_bounded() { # <seconds> <what> <command...>
  local secs="$1" what="$2"
  shift 2
  mkdir -p "$M33_WORK"
  timeout -s KILL "$secs" "$@" > "$M33_WORK/bounded.log" 2>&1
  local rc=$?
  if [ "$rc" = "137" ] || [ "$rc" = "124" ]; then
    die "$what exceeded its ${secs}s bound (killed). Command: $*
             See $M33_WORK/bounded.log"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# The arm run. Produced once from the BUILT bundle; read by all four checks.
# ---------------------------------------------------------------------------
m33_arms_newer_inputs() {
  [ -s "$M33_ARMS" ] || { printf 'wallet.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_wallet_arms.mjs" -newer "$M33_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M33_ARMS" -print -quit 2>/dev/null || true
}

m33_require_arms() {
  m27_require_bundle
  mkdir -p "$M33_WORK"
  [ -s "$BROWSER_DIST/wallet.js" ] \
    || die "there is no built wallet entry at $BROWSER_DIST/wallet.js.
             Remedy: just browser-build"

  local stale=0 newer
  newer="$(m33_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M33_ARMS_REFRESH:-0}" = "1" ] && stale=1

  if [ "$stale" = "1" ]; then
    note "running the wallet arms against $BROWSER_DIST/wallet.js (timeout ${M33_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 BROWSER_DIST="$BROWSER_DIST" \
        timeout -s KILL "$M33_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_wallet_arms.mjs" "$M33_WORK" ) \
      > "$M33_ARMS.tmp" 2> "$M33_WORK/wallet.stderr"
    local rc=$?
    # THE FAILED RUN'S REPORT IS KEPT. A run that died is evidence; deleting it turns a diagnosable
    # failure into "the arms did not produce a file".
    if [ "$rc" != "0" ]; then
      mv -f "$M33_ARMS.tmp" "$M33_WORK/wallet.failed.json" 2>/dev/null || true
      die "the wallet arm run exited $rc. See $M33_WORK/wallet.stderr and $M33_WORK/wallet.failed.json"
    fi
    mv -f "$M33_ARMS.tmp" "$M33_ARMS"
  fi
  [ -s "$M33_ARMS" ] || die "there is no arm report at $M33_ARMS even after running"
}

# ---------------------------------------------------------------------------
# THE BROWSER ARM. One claim, and it is the one Node cannot make.
#
# M33 measured its handshake in Node — rightly, because a `MessagePort` and WebCrypto are the same
# thing in both engines — and asserted the BROWSER half on the esbuild metafile instead. M33's
# review measured how much weaker that is, and the answer is: a free identifier is not an import,
# and a metafile only records imports. With `const _nodeOnlyProbe = setImmediate;` planted at the
# top of `port_wallet_provider.ts` — not `Buffer`, not `process`, so no shim supplies it and no
# free-identifier scan names it — `just verify-m33` reported **224, 4/4, exit 0**, M28's
# `verify_browser_bundle_no_node_builtins` reported **64 / 0**, and the same `wallet.js` died in
# Chromium with `ReferenceError: setImmediate is not defined`. Nothing anywhere loaded it in a
# browser, because no page referenced it.
#
# So this arm loads it, and only that. The handshake stays in Node and `WALLET-BOUNDARY.md` §5 stays
# the boundary; what moves is that "the artefact is browser-shaped" is now an OBSERVATION with a
# control beside it rather than a property of a config file.
# ---------------------------------------------------------------------------
M33_BROWSER_ARM="$M33_WORK/browser.json"
export M33_BROWSER_ARM

m33_browser_arm_newer_inputs() {
  [ -s "$M33_BROWSER_ARM" ] || { printf 'browser.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_wallet_browser_arm.mjs" -newer "$M33_BROWSER_ARM" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/tools/browser_cdp.mjs" -newer "$M33_BROWSER_ARM" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M33_BROWSER_ARM" -print -quit 2>/dev/null || true
}

m33_require_browser_arm() {
  m27_require_chromium
  mkdir -p "$M33_WORK"
  local stale=0 newer rc
  newer="$(m33_browser_arm_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M33_ARMS_REFRESH:-0}" = "1" ] && stale=1
  if [ "$stale" = "1" ]; then
    note "loading $BROWSER_DIST/wallet.js in $M27_CHROMIUM_VERSION (timeout ${M33_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 BROWSER_DIST="$BROWSER_DIST" \
        M27_CHROMIUM="$M27_CHROMIUM" M27_CHROMIUM_VERSION="$M27_CHROMIUM_VERSION" \
        timeout -s KILL "$M33_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_wallet_browser_arm.mjs" "$M33_WORK" ) \
      > "$M33_BROWSER_ARM.tmp" 2> "$M33_WORK/browser.stderr"
    rc=$?
    if [ "$rc" != "0" ]; then
      mv -f "$M33_BROWSER_ARM.tmp" "$M33_WORK/browser.failed.json" 2>/dev/null || true
      die "the wallet browser arm exited $rc. See $M33_WORK/browser.stderr"
    fi
    mv -f "$M33_BROWSER_ARM.tmp" "$M33_BROWSER_ARM"
  fi
  [ -s "$M33_BROWSER_ARM" ] || die "there is no browser arm report at $M33_BROWSER_ARM"
}

# One value out of the BROWSER arm report, same MISSING discipline as `m33_arm`.
#
# The save/restore is explicit rather than a `VAR=val m33_arm …` prefix: bash leaves a variable
# assignment that precedes a FUNCTION call in place after the function returns, which would silently
# repoint every later `m33_arm` in the check at the browser report — two readers of two files
# agreeing because they had become one file.
m33_browser() { # <dotted path, rooted at the report's `arms` object>
  local saved="$M33_ARMS"
  M33_ARMS="$M33_BROWSER_ARM"
  m33_arm "$1"
  M33_ARMS="$saved"
}

# One value out of the arm report, by dotted path. Prints MISSING rather than empty, so a typo'd
# key FAILS instead of comparing two absences — M29's `arms.publicOnly.executed` defect, where two
# missing keys agreed and two assertions went green.
m33_arm() { # <dotted path, rooted at the report's `arms` object>
  python3 - "$M33_ARMS" "arms.$1" <<'PY'
import json, sys
cur = json.load(open(sys.argv[1]))
for part in sys.argv[2].split('.'):
    if isinstance(cur, list):
        try:
            cur = cur[int(part)]
            continue
        except (ValueError, IndexError):
            print('MISSING'); sys.exit(0)
    if not isinstance(cur, dict) or part not in cur:
        print('MISSING'); sys.exit(0)
    cur = cur[part]
if cur is None:
    print('MISSING')
elif isinstance(cur, bool):
    print('true' if cur else 'false')
elif isinstance(cur, (list, dict)):
    print(json.dumps(cur, separators=(',', ':'), sort_keys=True))
else:
    print(cur)
PY
}

# ONE assertion naming EVERY absent field, run before the first comparison, with a `die` behind it.
# M29's remedy: a report with no data in it is a failure and not a smaller check.
m33_absent() { # <name=value>...
  local bad="" pair
  for pair in "$@"; do
    case "$pair" in
      *=MISSING) bad="$bad ${pair%%=*}" ;;
    esac
  done
  assert_eq "every field this check reads is present in the arm report" "" "$bad"
  [ -z "$bad" ] || die "the arm report is missing:$bad
             A report with no data in it is a failure, not a smaller check. See $M33_ARMS."
}

# The built wallet bundle's own exports, read by IMPORTING the artefact.
m33_bundle_exports() { # (no args)
  ( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
console.log(Object.keys(m).sort().join('\n'));
" 2>&1 )
}

# One expression over the imported wallet bundle.
m33_bundle_value() { # <expression over the imported module `m`>
  ( cd "$BROWSER_DIST" && node --input-type=module -e "
const m = await import('./wallet.js');
const v = ($1);
console.log(typeof v === 'string' ? v : JSON.stringify(v));
" 2>&1 )
}

# The `cpp` anchor, READ FROM pins.json rather than typed here. `pins.json` is the single source of
# truth for every pin in this tree and `verify_pinned_nightly_single_source` enforces that nothing
# else declares one.
m33_cpp_anchor() {
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
    "$REPO_ROOT/pins.json"
}

# A file at the anchor, out of the OBJECT STORE rather than out of a worktree. M22's review's rule:
# vendor from the object store, not from a checkout somebody may have moved.
m33_anchor_show() { # <path under the aztec-packages tree>
  git -C "$FORK_ROOT" show "$(m33_cpp_anchor):$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# THE ANCHOR'S `yarn-project` TREE, materialised so the enumeration is a RE-DERIVATION.
#
# `CAMPAIGN-BRIEF.md`: "a figure nobody re-derives rots", and the enumeration is the number M33's
# whole decision rests on. So it is re-run on every check rather than quoted, out of the OBJECT
# STORE with `git archive` — 65 MB, a few seconds — into a directory STAMPED with the anchor commit,
# so a re-materialisation happens when and only when the anchor moves.
#
# `~/.cache`, never `$TMPDIR`: on this host `/tmp` is a 32 GB tmpfs shared with every build.
# ---------------------------------------------------------------------------
m33_require_anchor_tree() {
  M33_ANCHOR_TREE="${M33_ANCHOR_TREE:-$HOME/.cache/aztec-m33-anchor}"
  export M33_ANCHOR_TREE
  local anchor stamp
  anchor="$(m33_cpp_anchor)"
  stamp="$M33_ANCHOR_TREE/.anchor"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$anchor" ] \
     && [ -d "$M33_ANCHOR_TREE/yarn-project/wallet-sdk/src" ]; then
    return 0
  fi
  note "materialising yarn-project at $anchor into $M33_ANCHOR_TREE"
  rm -rf "$M33_ANCHOR_TREE"
  mkdir -p "$M33_ANCHOR_TREE"
  git -C "$FORK_ROOT" archive "$anchor" yarn-project \
    | tar -x -C "$M33_ANCHOR_TREE" \
    || die "could not materialise yarn-project at $anchor out of $FORK_ROOT's object store"
  [ -d "$M33_ANCHOR_TREE/yarn-project/wallet-sdk/src" ] \
    || die "the materialised tree has no yarn-project/wallet-sdk/src"
  printf '%s' "$anchor" > "$stamp"
}
