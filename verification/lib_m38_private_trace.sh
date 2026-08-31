#!/usr/bin/env bash
# lib_m38_private_trace.sh — M38's shared machinery. Sourced after `lib.sh`.
#
# It is `lib_m35_private.sh` with the subject changed, deliberately: the bounded arm subprocess,
# the staleness rule, the `MISSING`-rather-than-empty reader, the one-assertion absence guard and
# the abnormal-exit trap are machinery this campaign has already paid for, and a second
# implementation of any of them would be a second answer to one question.
#
# WHAT IS DIFFERENT FROM M35'S. M38's arms are a NATIVE binary rather than a headless browser, so
# there is no chromium, no bundle and no module to require — but there IS an M35 arm report, which
# is where the oracle answers come from. That report is a hard input, not an optional one: without
# it there is no tape, and a tape this milestone invented would be exactly the fabrication its whole
# refusal discipline exists to prevent.

M38_WORK="${M38_WORK:-$HOME/.cache/aztec-m38-private-trace}"
export M38_WORK
M38_ARMS="$M38_WORK/trace-arms.json"
export M38_ARMS
M38_TAPE_SOURCE="${M38_TAPE_SOURCE:-${M35_WORK:-$HOME/.cache/aztec-m35-private}/private-execution.json}"
export M38_TAPE_SOURCE
M38_DOC="$REPO_ROOT/PRIVATE-TRACE.md"
M38_PROBE_SRC="$VERIFY_DIR/m38_private_trace_probe.rs"
M38_NOIR_ROOT="${M38_NOIR_ROOT:-$(cd "$REPO_ROOT/.." && pwd)/noir}"
export M38_DOC M38_PROBE_SRC M38_NOIR_ROOT
M38_ARMS_TIMEOUT="${M38_ARMS_TIMEOUT:-1800}"

m38_finish() { finish; }
m38_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# ---------------------------------------------------------------------------
# The arms.
# ---------------------------------------------------------------------------
m38_arms_newer_inputs() {
  [ -s "$M38_ARMS" ] || { printf 'trace-arms.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_m38_trace_arms.mjs" -newer "$M38_ARMS" -print -quit 2>/dev/null || true
  find "$M38_PROBE_SRC" -newer "$M38_ARMS" -print -quit 2>/dev/null || true
  find "$VERIFY_DIR/build_m38_private_trace_probe.sh" -newer "$M38_ARMS" -print -quit 2>/dev/null || true
  # THE TAPE IS AN INPUT AND THE PROBE BINARY IS AN OUTPUT OF THE NOIR TREE, SO BOTH ARE WATCHED.
  # `m31_arms_newer_inputs` watched the page and four tools and not `orchestration/src`, and a field
  # added to a driver was still absent from the report after a full check run. A staleness predicate
  # that does not watch its own producer is that defect.
  find "$M38_TAPE_SOURCE" -newer "$M38_ARMS" -print -quit 2>/dev/null || true
  find "$M38_WORK/probe/bin/m38probe" -newer "$M38_ARMS" -print -quit 2>/dev/null || true
}

m38_require_arms() {
  mkdir -p "$M38_WORK"
  [ -s "$M38_TAPE_SOURCE" ] || die "there is no M35 arm report at $M38_TAPE_SOURCE.
             M38 replays the oracle answers M35's own handler recorded; without that report there is
             no tape, and a tape this milestone invented would be the fabrication its whole refusal
             discipline exists to prevent.
             Remedy: just m35-arms"

  # THE PROBE IS BUILT BEFORE THE STALENESS PREDICATE READS ITS MTIME, which is the remedy M30's
  # review generalises: bring the cache's producer current BEFORE deciding whether the cache is
  # stale, or the first check to rebuild it invalidates the decision the second one made.
  local built
  built="$("$VERIFY_DIR/build_m38_private_trace_probe.sh" 2>&1)" \
    || die "the M38 probe could not be built:
$built"

  local stale=0 newer rc
  newer="$(m38_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M38_ARMS_REFRESH:-0}" = "1" ] && stale=1

  if [ "$stale" = "1" ]; then
    note "running the M38 trace arms (timeout ${M38_ARMS_TIMEOUT}s)"
    ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 \
        M38_TAPE_SOURCE="$M38_TAPE_SOURCE" \
        timeout -s KILL "$M38_ARMS_TIMEOUT" \
        node "$REPO_ROOT/tools/run_m38_trace_arms.mjs" "$M38_WORK" ) \
      > "$M38_ARMS.tmp" 2> "$M38_WORK/arms.stderr"
    rc=$?
    if [ "$rc" != "0" ]; then
      mv -f "$M38_ARMS.tmp" "$M38_WORK/arms.failed.json" 2>/dev/null || true
      case "$rc" in
        124|137)
          die "the M38 trace arm run did not finish within ${M38_ARMS_TIMEOUT}s and was killed
             (timeout exit $rc). That is a HANG rather than a failure. Raise M38_ARMS_TIMEOUT only
             after reading $M38_WORK/arms.stderr." ;;
      esac
      die "the M38 trace arm run exited $rc: $(tail -3 "$M38_WORK/arms.stderr" 2>/dev/null)
             See $M38_WORK/arms.stderr"
    fi
    mv -f "$M38_ARMS.tmp" "$M38_ARMS"
  fi
  [ -s "$M38_ARMS" ] || die "there is no arm report at $M38_ARMS even after running"
}

# m38_arm <dotted path under the report's `arms` object>
#
# Prints `MISSING` for an absent key rather than the empty string, so two absent values cannot
# compare equal.
m38_arm() {
  python3 - "$M38_ARMS" "$1" <<'PY'
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

# m38_top <dotted path from the report ROOT>
m38_top() {
  python3 - "$M38_ARMS" "$1" <<'PY'
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

# m38_absent <name=value>... — ONE assertion naming every absent field, then a die.
m38_absent() {
  local bad="" pair
  for pair in "$@"; do
    case "$pair" in
      *=MISSING) bad="$bad ${pair%%=*}" ;;
    esac
  done
  assert_eq "every field this check reads is present in the arm report" "" "$bad"
  [ -z "$bad" ] || die "the arm report is missing:$bad
             A report with no data in it is a failure, not a smaller check. See $M38_ARMS."
}

# m38_num <value> <what> — a numeric guard for every `$(( ))` over a reading.
#
# `lib.sh` runs with `set -u` and bash's `$(( ))` treats a bare word as a VARIABLE, so
# `$(( 1000 + MISSING ))` is an unbound-variable error that KILLS the check rather than failing it.
# The final-four pass found nine of these across four checks, each one absent field away from a
# silent shrink. Every arithmetic site here goes through this.
m38_num() { # <value> <what>
  case "${1:-}" in
    ''|*[!0-9-]*) die "$2 is not a number: [${1:-}]. See $M38_ARMS." ;;
  esac
  printf '%s' "$1"
}

# The oracle synchrony classification, derived from the handler SOURCE and an M35 arm report.
m38_synchrony() { # <report.json> <frame path>...
  python3 "$VERIFY_DIR/_m38_oracle_synchrony.py" \
    "${M35_ORACLES_SRC:-$REPO_ROOT/browser/src/wallet/private_oracles.ts}" "$@"
}

# The pinned `ct-print`, built by `build_ct_print.sh`.
m38_ct_print() {
  printf "%s" "${M24_CTPRINT_WORK:-$HOME/.cache/aztec-m24-ctprint}/ct-print"
}
