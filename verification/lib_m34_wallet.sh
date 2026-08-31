#!/usr/bin/env bash
# lib_m34_wallet.sh — shared machinery for the M34 (CodeTracer dev wallet) checks.
#
# Not to be executed directly: sourced after lib.sh, lib_m24_ct_writer.sh, lib_m27_browser.sh and
# lib_m33_wallet.sh.
#
# ===========================================================================================
# IT SITS ON M27'S HARNESS AND M33'S SEAM, AND REUSES BOTH UNCHANGED
# ===========================================================================================
#
# The bundle build and its staleness predicate are M27's (`m27_require_bundle`), the module and the
# Chromium discovery are M27's (`m27_require_module`, `m27_require_chromium`), the reference reader
# is M24's (`m24_require_readers`, `m24_ct_print`), and the wallet protocol, the transport and the
# handshake are M33's, byte for byte. What M34 adds is a wallet behind M33's `getWallet` callback
# and a page that drives it.
#
# ===========================================================================================
# WHY THE ARMS ARE IN A BROWSER WHERE M33'S WERE IN NODE, AND IT IS NOT A PREFERENCE
# ===========================================================================================
#
# M33's arms ran in Node, correctly: its subject was a `MessagePort` and WebCrypto, which Node 24
# and a browser implement to the same specifications. M33's REVIEW then measured what that cannot
# say — *a metafile records IMPORTS, and a free identifier is not one* — by planting
# `const _nodeOnlyProbe = setImmediate;` in a module the wallet entry reaches: the rebuilt bundle
# imported cleanly in Node, died in Chromium with `ReferenceError`, and `just verify-m33` reported
# 224 assertions, 4/4, exit 0 with every browser-shape check green, because nothing in the
# repository had ever loaded `wallet.js` in a page.
#
# The remedy M33's review shipped is a probe that IMPORTS the bundle in a page. **M34 owes more,
# because M34 ships a wallet rather than a protocol: the wallet has to be LOADED AND EXERCISED in a
# browser, not asserted to be browser-shaped.** So every arm here runs in Chromium, and the
# handshake, the ECDH, the AES-256-GCM session, the deterministic key derivation through
# `avm.wasm`'s own grumpkin, the vendored transaction builder, the AVM and the `.ct` writer all
# execute there.
#
# THE ARMS ARE MEASURED ONCE into $M34_WORK/wallet-transfer.json and shared by all four checks,
# which is M20's convention kept by every milestone since.

M34_WORK="${M34_WORK:-$HOME/.cache/aztec-m34-wallet}"
export M34_WORK

M34_ARMS="$M34_WORK/wallet-transfer.json"
export M34_ARMS

M34_DOC="$REPO_ROOT/DEV-WALLET.md"
M34_WALLET_SRC="$BROWSER_SRC/wallet/dev_wallet.ts"
M34_KEYS_SRC="$BROWSER_SRC/wallet/dev_keys.ts"
M34_DEMO_SRC="$REPO_ROOT/browser/demo/wallet_main.ts"
export M34_DOC M34_WALLET_SRC M34_KEYS_SRC M34_DEMO_SRC

M34_ARMS_TIMEOUT="${M34_ARMS_TIMEOUT:-1800}"

# ---------------------------------------------------------------------------
# A SUMMARY LINE EVEN ON AN ABNORMAL EXIT.
#
# M22's machinery, for M21's review's reason: a check that dies before `finish` prints no summary
# and reads as a SMALLER milestone rather than a red one — which once took M1 from 151 to 141 with
# nothing reported as failing. M22 said a third milestone wanting it is when it moves into `lib.sh`;
# M23, M24, M27, M32 and M33 each declined for M22's own reason, and M34 declines for the same one.
# ---------------------------------------------------------------------------
# DELEGATED TO `lib.sh` ON 2026-08-31. These eight lines were copied into FOURTEEN
# milestone libraries, m22..m37. M22 wrote them and said the third milestone wanting
# them is when they move into `lib.sh`; M24 declined for M22's own reason and recorded
# it as owed. The fifteenth caller turned out to be M9 — not a new milestone but the
# campaign's oldest open item — so the move is made and these are wrappers. The public
# names are unchanged, so no check needed editing, and the behaviour is identical: one
# implementation instead of fourteen, verified by the sweep.
m34_finish() { finish; }
m34_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# ---------------------------------------------------------------------------
# The arm run. Produced once, in a real browser, from the BUILT bundle; read by all four checks.
# ---------------------------------------------------------------------------
m34_arms_newer_inputs() {
  [ -s "$M34_ARMS" ] || { printf 'wallet-transfer.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_wallet_transfer_arms.mjs" -newer "$M34_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/tools/browser_cdp.mjs" -newer "$M34_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M34_ARMS" -print -quit 2>/dev/null || true
}

m34_require_arms() {
  m27_require_bundle
  m27_require_module
  m27_require_chromium
  mkdir -p "$M34_WORK"
  [ -s "$BROWSER_DIST/wallet-demo.js" ] \
    || die "there is no built wallet-demo entry at $BROWSER_DIST/wallet-demo.js.
             Remedy: just browser-build"
  [ -s "$BROWSER_DIST/wallet.html" ] \
    || die "there is no wallet demo page at $BROWSER_DIST/wallet.html.
             Remedy: just browser-build"

  local stale=0 newer rc
  newer="$(m34_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M34_ARMS_REFRESH:-0}" = "1" ] && stale=1

  if [ "$stale" = "1" ]; then
    note "running the wallet transfer arms in $M27_CHROMIUM_VERSION (timeout ${M34_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 BROWSER_DIST="$BROWSER_DIST" \
        AVM_WASM_PATH="$AVM_WASM_PATH" M27_CHROMIUM="$M27_CHROMIUM" \
        M27_CHROMIUM_VERSION="$M27_CHROMIUM_VERSION" \
        timeout -s KILL "$M34_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_wallet_transfer_arms.mjs" "$M34_WORK" ) \
      > "$M34_ARMS.tmp" 2> "$M34_WORK/arms.stderr"
    rc=$?
    # THE FAILED RUN'S REPORT IS KEPT. A run that died is evidence; deleting it turns a diagnosable
    # failure into "the arms did not produce a file".
    if [ "$rc" != "0" ]; then
      mv -f "$M34_ARMS.tmp" "$M34_WORK/arms.failed.json" 2>/dev/null || true
      die "the wallet transfer arm run exited $rc.
             See $M34_WORK/arms.stderr and $M34_WORK/arms.failed.json"
    fi
    mv -f "$M34_ARMS.tmp" "$M34_ARMS"
  fi
  [ -s "$M34_ARMS" ] || die "there is no arm report at $M34_ARMS even after running"
}

# One value out of the arm report, by dotted path. Prints MISSING rather than empty, so a typo'd
# key FAILS instead of comparing two absences — M29's `arms.publicOnly.executed` defect, where two
# missing keys agreed and two assertions went green.
m34_arm() { # <dotted path, rooted at the report's `arms` object>
  python3 - "$M34_ARMS" "arms.$1" <<'PY'
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
    # `ensure_ascii=False`, and it is not cosmetic: the disclosure line contains an EM DASH, and
    # with the default escaping the value a check compares is `\u2014` while the value it reads out
    # of `disclosure.ts` is the character. Two readings of one string that can never agree is the
    # vacuity family with the sign flipped — an assertion that can only FAIL.
    print(json.dumps(cur, separators=(',', ':'), sort_keys=True, ensure_ascii=False))
else:
    print(cur)
PY
}

# ONE assertion naming EVERY absent field, run before the first comparison, with a `die` behind it.
# M29's remedy: a report with no data in it is a failure and not a smaller check.
m34_absent() { # <name=value>...
  local bad="" pair
  for pair in "$@"; do
    case "$pair" in
      *=MISSING) bad="$bad ${pair%%=*}" ;;
    esac
  done
  assert_eq "every field this check reads is present in the arm report" "" "$bad"
  [ -z "$bad" ] || die "the arm report is missing:$bad
             A report with no data in it is a failure, not a smaller check. See $M34_ARMS."
}

# ---------------------------------------------------------------------------
# READING THE CONTAINER BACK, THROUGH THE PINNED READER.
#
# `CAMPAIGN-BRIEF.md`: *"a producer's report about itself is not its output"* — M29's review found
# a check reading an opcode histogram out of the RECORDER rather than out of the container, over a
# container full of fabricated opcodes. M34's whole fifth deliverable is that the wallet's decisions
# are IN the trace, so they are read out of the `.ct` the browser downloaded, through
# `ct-print --full` at the pinned revision, and never out of the page's own report.
# ---------------------------------------------------------------------------

# m34_log_events <container> — every `elkTraceLogEvent`, one `<metadata><TAB><content>` row each.
# Prints `ERR:<what>` on any failure, because an empty answer from a crashed reader is
# indistinguishable from an empty answer from a working one.
m34_log_events() { # <container>
  local out rc json
  json="$M34_WORK/$(basename "$1" .ct).ct-print.json"
  out="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$1")"
  rc="$(printf '%s\n' "$out" | head -1)"
  if [ "$rc" != "0" ]; then
    printf 'ERR:ct-print-exit-%s\n' "$rc"
    return 0
  fi
  printf '%s\n' "$out" | tail -n +2 > "$json"
  timeout --signal=TERM --kill-after=10 "${M34_READER_TIMEOUT:-120}" python3 - "$json" <<'PY'
import json, sys
doc = json.load(open(sys.argv[1]))
for e in doc.get('events', []):
    if e.get('type') == 'Event' and e.get('event_kind') == 'elkTraceLogEvent':
        print('%s\t%s' % (e.get('metadata', ''), e.get('content', '').replace('\t', ' ')))
PY
  rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf 'ERR:log-event-reader-timed-out\n'
  elif [ "$rc" -ne 0 ]; then
    printf 'ERR:log-event-reader-exit-%s\n' "$rc"
  fi
}

# m34_count_meta <rows> <metadata key> — how many log events carry that key.
m34_count_meta() { # <rows> <key>
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {n++} END {print n+0}'
}

# m34_contents <rows> <metadata key> — every content for that key, newline separated.
m34_contents() { # <rows> <key>
  printf '%s\n' "$1" | awk -F'\t' -v k="$2" '$1==k {print $2}'
}

# The container each downloading arm produced, as an absolute path. `MISSING` when the arm recorded
# none, so a check FAILS rather than reading a path that is the empty string.
m34_container() { # <arm name>
  local rel
  rel="$(m34_arm "$1.downloadedFile")"
  if [ "$rel" = "MISSING" ]; then
    printf 'MISSING\n'
  else
    printf '%s/%s\n' "$M34_WORK" "$rel"
  fi
}
