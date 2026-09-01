#!/usr/bin/env bash
# lib_m39_nested.sh — M39's shared machinery. Sourced after lib.sh, lib_m27_browser.sh and
# lib_m38_private_trace.sh.
#
# ===========================================================================================
# WHY THIS SOURCES M38's LIBRARY INSTEAD OF REPEATING IT
# ===========================================================================================
#
# `m38_absent`, `m38_num`, `m38_require_num` and `m38_ct_print` are four guards this campaign paid
# for one at a time — three spellings of absence, a numeric sentinel that does not `die` inside a
# command substitution, and the pinned reader's path. A second implementation of any of them would
# be a second answer to one question, and the campaign's own record is that the second answer is the
# one that stops being maintained. So M39 uses them under their own names rather than aliasing them:
# an alias would make a reader wonder which of the two is running.
#
# What is here is the two things M39 has that M38 does not: a browser arm report for a nested
# TRANSACTION, and a trace arm report for the container that transaction's private half becomes.

M39_WORK="${M39_WORK:-$HOME/.cache/aztec-m39-nested}"
export M39_WORK
M39_ARMS="$M39_WORK/nested.json"
export M39_ARMS
M39_TRACE_WORK="${M39_TRACE_WORK:-$HOME/.cache/aztec-m39-trace}"
export M39_TRACE_WORK
M39_TRACE_ARMS="$M39_TRACE_WORK/transaction-trace.json"
export M39_TRACE_ARMS
M39_DOC="$REPO_ROOT/NESTED-CALLS.md"
export M39_DOC
M39_ARMS_TIMEOUT="${M39_ARMS_TIMEOUT:-1800}"
M39_TRACE_TIMEOUT="${M39_TRACE_TIMEOUT:-1800}"

# The abnormal-exit trap, delegated to `lib.sh` exactly as M35's and M38's are.
m39_finish() { finish; }
m39_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# ---------------------------------------------------------------------------
# The browser arms.
# ---------------------------------------------------------------------------
m39_arms_newer_inputs() {
  [ -s "$M39_ARMS" ] || { printf 'nested.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_m39_nested_arms.mjs" -newer "$M39_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/tools/browser_cdp.mjs" -newer "$M39_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M39_ARMS" -print -quit 2>/dev/null || true
}

# _m39_run_bounded <label> <timeout> <report path> <script> <work dir> [env pairs...]
#
# ONE RUNNER FOR BOTH ARM SETS, and the three properties it exists for are M35's, each of them a
# defect that shipped somewhere in this campaign:
#
#   1. THE SUBPROCESS IS BOUNDED and a bound exceeded is named as a HANG rather than as a failure.
#      `timeout` answers 124, or 137 when it escalates to SIGKILL; reporting either as "exited 137"
#      is a check pointing at nothing, because a process that never finishes and one that failed
#      need different remedies.
#   2. THE FAILED RUN'S REPORT IS KEPT. Both runners catch an arm failure, record it and still write
#      JSON; discarding it on a non-zero exit throws away the only diagnostic.
#   3. THE KEPT REPORT'S OWN MESSAGE GOES INTO THE DIAGNOSTIC. A `die` that says only "exited 1" is
#      a check pointing at a path.
_m39_run_bounded() { # <label> <timeout> <report> <script> <workdir>
  local label="$1" bound="$2" report="$3" script="$4" workdir="$5"
  local rc why
  ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 BROWSER_DIST="$BROWSER_DIST" \
      AVM_WASM_PATH="${AVM_WASM_PATH:-}" M27_CHROMIUM="${M27_CHROMIUM:-}" \
      M27_CHROMIUM_VERSION="${M27_CHROMIUM_VERSION:-}" \
      M39_TAPE_SOURCE="$M39_ARMS" \
      timeout -s KILL "$bound" node "$REPO_ROOT/tools/$script" "$workdir" ) \
    > "$report.tmp" 2> "$workdir/arms.stderr"
  rc=$?
  if [ "$rc" != "0" ]; then
    mv -f "$report.tmp" "$workdir/arms.failed.json" 2>/dev/null || true
    case "$rc" in
      124|137)
        die "the $label arm run did not finish within ${bound}s and was killed (timeout exit $rc).
             That is a HANG rather than a failure: something waited on what never arrived. Raise the
             bound only after reading $workdir/arms.stderr." ;;
    esac
    why="$(python3 -c '
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception as e:
    print("(the kept report is not readable: %s)" % e); raise SystemExit(0)
arms = d.get("arms", {})
if isinstance(arms, dict) and "error" in arms:
    print(str(arms["error"].get("message", "(no message)"))[:400]); raise SystemExit(0)
for name, arm in (arms.items() if isinstance(arms, dict) else []):
    if isinstance(arm, dict) and "error" in arm:
        print("%s: %s" % (name, str(arm["error"])[:360])); raise SystemExit(0)
print("(the report records no error)")' "$workdir/arms.failed.json" 2>/dev/null || echo "(no kept report)")"
    die "the $label arm run exited $rc: $why
             See $workdir/arms.stderr and $workdir/arms.failed.json"
  fi
  mv -f "$report.tmp" "$report"
}

m39_require_arms() {
  m27_require_bundle
  m27_require_module
  m27_require_chromium
  mkdir -p "$M39_WORK"
  [ -s "$BROWSER_DIST/wallet-demo.js" ] \
    || die "there is no built wallet-demo entry at $BROWSER_DIST/wallet-demo.js.
             Remedy: just browser-build"

  local stale=0 newer
  newer="$(m39_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M39_ARMS_REFRESH:-0}" = "1" ] && stale=1
  if [ "$stale" = "1" ]; then
    note "running the nested-call arms in $M27_CHROMIUM_VERSION (timeout ${M39_ARMS_TIMEOUT}s)"
    _m39_run_bounded "nested-call" "$M39_ARMS_TIMEOUT" "$M39_ARMS" run_m39_nested_arms.mjs "$M39_WORK"
  fi
  [ -s "$M39_ARMS" ] || die "there is no arm report at $M39_ARMS even after running"
}

# ---------------------------------------------------------------------------
# The trace arms — the container the transaction's private half becomes.
# ---------------------------------------------------------------------------
m39_trace_newer_inputs() {
  [ -s "$M39_TRACE_ARMS" ] || { printf 'transaction-trace.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_m39_trace_arms.mjs" -newer "$M39_TRACE_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/verification/m38_private_trace_probe.rs" -newer "$M39_TRACE_ARMS" -print -quit 2>/dev/null || true
  # THE TAPE IS AN INPUT AND THE FIRST DRAFT OF THIS FUNCTION DID NOT WATCH IT. The container is a
  # replay OF the browser report; a report that moved under a container is exactly M30's
  # "a mutation silently undone and printed as the arm's result", one level out.
  find "$M39_ARMS" -newer "$M39_TRACE_ARMS" -print -quit 2>/dev/null || true
}

m39_require_trace_arms() {
  m39_require_arms
  mkdir -p "$M39_TRACE_WORK"
  # THE PROBE IS BUILT, NOT MERELY REQUIRED TO EXIST, AND THE MUTATION MATRIX IS WHAT SAID SO.
  #
  # The first version of this function checked that the BINARY was there and left it alone, while
  # `m39_trace_newer_inputs` watches the probe's SOURCE. So mutating `m38_private_trace_probe.rs`
  # marked the arms stale, the arms re-ran — with the OLD binary — and the report was a faithful
  # measurement of unmutated code, PRINTED AS THE ARM'S RESULT. That is M32's fourth and worst
  # state: not a mutation that crashed, not one silently undone, but one that never applied. Two
  # arms reported `82 assertion(s), 0 failure(s)` over code that had been changed under them.
  #
  # `m38_require_arms` builds it (`lib_m38_private_trace.sh:58`) and this is the one line of that
  # library this one did not carry over, in the library whose header says it sources M38's rather
  # than repeating it. The build script has its own content stamp, so this is a no-op when nothing
  # moved and twelve seconds when the source did.
  local built
  built="$("$VERIFY_DIR/build_m38_private_trace_probe.sh" 2>&1)" \
    || die "the probe did not build:
$built
             It needs the sibling codetracer-trace-format dev shell for nim."
  local probe="${M39_PROBE:-$HOME/.cache/aztec-m38-private-trace/probe/bin/m38probe}"
  [ -x "$probe" ] || die "the probe build reported success but there is no binary at $probe"

  local stale=0 newer
  newer="$(m39_trace_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M39_TRACE_REFRESH:-0}" = "1" ] && stale=1
  if [ "$stale" = "1" ]; then
    note "stepping the transaction's private half (timeout ${M39_TRACE_TIMEOUT}s)"
    _m39_run_bounded "transaction-trace" "$M39_TRACE_TIMEOUT" "$M39_TRACE_ARMS" \
      run_m39_trace_arms.mjs "$M39_TRACE_WORK"
  fi
  [ -s "$M39_TRACE_ARMS" ] || die "there is no trace arm report at $M39_TRACE_ARMS even after running"
}

# _m39_read <report> <dotted path> — `MISSING` for an absent key, `UNREADABLE` for a broken report.
#
# A NUMERIC SEGMENT INDEXES AN ARRAY, because a transaction's report is a TREE: a frame's children
# hang off `nested`, so naming the second frame means walking through a list. Object keys are tried
# first, so a document whose object really has a key `"0"` is unaffected.
_m39_read() {
  python3 - "$1" "$2" <<'PY'
import json, sys
try:
    node = json.load(open(sys.argv[1]))
except Exception:
    print('UNREADABLE'); raise SystemExit(0)
for part in sys.argv[2].split('.'):
    if isinstance(node, dict) and part in node:
        node = node[part]
    elif isinstance(node, list) and part.isdigit() and int(part) < len(node):
        node = node[int(part)]
    else:
        print('MISSING'); raise SystemExit(0)
if node is None:
    print('null')
elif isinstance(node, bool):
    print('true' if node else 'false')
elif isinstance(node, (list, dict)):
    print(json.dumps(node, separators=(',', ':'), sort_keys=True, ensure_ascii=False))
else:
    print(node)
PY
}

# m39_arm <dotted path under the browser report's `arms`>
m39_arm() { _m39_read "$M39_ARMS" "arms.$1"; }
# m39_top <dotted path from the browser report's root>
m39_top() { _m39_read "$M39_ARMS" "$1"; }
# m39_trace <dotted path under the trace report's `arms`>
m39_trace() { _m39_read "$M39_TRACE_ARMS" "arms.$1"; }
# m39_trace_top <dotted path from the trace report's root>
m39_trace_top() { _m39_read "$M39_TRACE_ARMS" "$1"; }

# m39_container <container path> <field> — every container figure a check asserts comes through here.
#
# THROUGH THE PINNED READER AND NOT THROUGH THE PROBE'S REPORT. M29's rule, which it earned by
# finding a check that read an opcode histogram out of the producer's own report while the writer
# wrote fabricated opcodes: a producer's report about itself is not its output.
m39_container() { # <ct path> <field>
  "$(m38_ct_print)" --full "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("UNREADABLE"); raise SystemExit(0)
events = doc.get("events", [])
steps = [e for e in events if e.get("kind") == "step"]
field = sys.argv[1]
if field == "steps":
    print(len(steps))
elif field == "withColumn":
    print(sum(1 for e in steps if e.get("column")))
elif field == "distinctLines":
    print(len({(e["path"], e["line"]) for e in steps}))
elif field == "distinctPaths":
    print(len({e["path"] for e in steps}))
elif field == "calls":
    print(doc.get("counts", {}).get("calls", "MISSING"))
elif field == "callEntries":
    print(sum(1 for e in events if e.get("kind") == "call_entry"))
elif field == "callExits":
    print(sum(1 for e in events if e.get("kind") == "call_exit"))
elif field == "callNames":
    print(",".join(sorted(e.get("function", "?") for e in events if e.get("kind") == "call_entry")) or "NONE")
elif field == "callArgs":
    out = []
    for e in events:
        if e.get("kind") != "call_entry":
            continue
        for a in e.get("args", []):
            v = a.get("value", {})
            out.append("%s=%s" % (a.get("varname", "?"), v.get("text", v.get("kind", "?"))))
    print(",".join(out) or "NONE")
elif field == "callEntryStep":
    entries = [e for e in events if e.get("kind") == "call_entry"]
    print(entries[0].get("entry_step", "MISSING") if entries else "MISSING")
elif field == "callExitStep":
    entries = [e for e in events if e.get("kind") == "call_entry"]
    print(entries[0].get("exit_step", "MISSING") if entries else "MISSING")
elif field == "paths":
    print(len(doc.get("paths", [])))
elif field == "sourceViews":
    print(doc.get("counts", {}).get("source_views", "MISSING"))
elif field == "columnAware":
    print("true" if doc.get("metadata", {}).get("flags", {}).get("has_column_aware_steps") else "false")
elif field == "firstPath":
    print(steps[0]["path"] if steps else "MISSING")
elif field == "join":
    rec = [e for e in events if e.get("metadata") == "ct.trace-join"]
    print(rec[0].get("text", "MISSING") if rec else "NONE")
elif field == "joinCount":
    print(sum(1 for e in events if e.get("metadata") == "ct.trace-join"))
else:
    print("MISSING")
' "$2"
}
