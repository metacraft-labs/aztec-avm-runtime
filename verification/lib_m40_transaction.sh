#!/usr/bin/env bash
# lib_m40_transaction.sh — M40's shared machinery. Sourced after lib.sh, lib_m23_chain.sh,
# lib_m27_browser.sh, lib_m38_private_trace.sh and lib_m39_nested.sh.
#
# ===========================================================================================
# WHY THIS SOURCES M38's AND M39's LIBRARIES INSTEAD OF REPEATING THEM
# ===========================================================================================
#
# `m38_absent`, `m38_num`, `m38_require_num`, `m38_assert_doc` and `m38_ct_print` are guards this
# campaign paid for one at a time — three spellings of absence, a numeric sentinel that does not
# `die` inside a command substitution, a document comparer that anchors to a ROW, and the pinned
# reader's path. A second implementation of any of them would be a second answer to one question,
# and this campaign's record is that the second answer is the one that stops being maintained. They
# are used under their own names rather than aliased: an alias would make a reader wonder which of
# the two is running.
#
# What is here is what M40 has that neither has: a browser arm report in which BOTH HALVES of one
# transaction executed, a native trace arm over the same transaction's private half, and a reader
# for the two containers a single page downloaded.

M40_WORK="${M40_WORK:-$HOME/.cache/aztec-m40-transaction}"
export M40_WORK
M40_ARMS="$M40_WORK/transaction.json"
export M40_ARMS
M40_TRACE_WORK="${M40_TRACE_WORK:-$HOME/.cache/aztec-m40-trace}"
export M40_TRACE_WORK
M40_TRACE_ARMS="$M40_TRACE_WORK/joined-transaction.json"
export M40_TRACE_ARMS
M40_TRACER_WORK="${M40_TRACER_WORK:-$HOME/.cache/aztec-m40-tracer}"
export M40_TRACER_WORK
M40_TRACER_WASM="$M40_TRACER_WORK/m40_private_trace.wasm"
export M40_TRACER_WASM
M40_DOC="$REPO_ROOT/BOTH-HALVES.md"
export M40_DOC
M40_ARMS_TIMEOUT="${M40_ARMS_TIMEOUT:-3600}"
M40_TRACE_TIMEOUT="${M40_TRACE_TIMEOUT:-1800}"

# The abnormal-exit trap, delegated to `lib.sh` exactly as M35's, M38's and M39's are. A check that
# dies with no summary line reads to a sweep as a check that is not there.
m40_finish() { finish; }
m40_summary_on_abnormal_exit() { summary_on_abnormal_exit; }

# m40_doc_prefixes <doc> <needle|index|measured>... — the abbreviated-value comparer.
#
# `m38_assert_doc` closes a write-up's BOLD NUMBERS. This closes the other half: the
# `0x124ef545…` and `d53fc677…` tokens a document quotes because the whole value is unreadable.
# M38's second sweep abort found thirteen figures "stated and compared by NOTHING, under a header
# claiming all of them were re-derived on every run", and an abbreviation is a measurement with its
# tail cut off rather than a decoration.
m40_doc_prefixes() { # <doc> <needle|index|measured>...
  local doc="$1"; shift
  python3 "$VERIFY_DIR/_m40_doc_prefixes.py" "$doc" "$@"
}

# m40_assert_prefixes <label> <doc> <needle|index|measured>... — three assertions, as
# `m38_assert_doc` makes three: nothing BAD, nothing MISSING, and the comparison covered every
# token it was given. The third is what stops a comparer that silently checked nothing.
m40_assert_prefixes() { # <label> <doc> <spec>...
  local label="$1" doc="$2"; shift 2
  local out bad missing ok
  out="$(m40_doc_prefixes "$doc" "$@")"
  bad="$(printf '%s\n' "$out" | grep '^BAD ' | tr '\n' ' ' | xargs -r echo)"
  missing="$(printf '%s\n' "$out" | grep '^MISSING ' | tr '\n' ' ' | xargs -r echo)"
  ok="$(printf '%s\n' "$out" | sed -n 's/^OK //p' | tail -1)"
  assert_eq "$label: no quoted value disagrees with the artefacts" "" "$bad"
  assert_eq "$label: every needle names exactly one row and every token is an abbreviation" "" "$missing"
  assert_eq "$label: and the comparison covered every value it was given" "$#" "$ok"
}

# ---------------------------------------------------------------------------
# The tracer module the page steps the private half with.
# ---------------------------------------------------------------------------
m40_require_tracer() {
  # THE BUILD SCRIPT IS RUN, NOT MERELY THE BINARY CHECKED. M39's own log records the arm that
  # printed a faithful measurement of UNMUTATED code because its precondition asserted the probe
  # EXISTED and never rebuilt it — M32's fourth state, "a mutation that never applied, printed as
  # the arm's result". The build script's own content stamp makes this a no-op when nothing moved.
  "$VERIFY_DIR/build_m40_private_trace_wasm.sh" >/dev/null \
    || die "the M40 private-trace wasm module failed to build.
             Remedy: verification/build_m40_private_trace_wasm.sh"
  [ -s "$M40_TRACER_WASM" ] \
    || die "the build reported success but there is no module at $M40_TRACER_WASM"
}

# ---------------------------------------------------------------------------
# The browser arms — both halves of one transaction, in Chromium.
# ---------------------------------------------------------------------------
m40_arms_newer_inputs() {
  [ -s "$M40_ARMS" ] || { printf 'transaction.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_m40_transaction_arms.mjs" -newer "$M40_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/tools/browser_cdp.mjs" -newer "$M40_ARMS" -print -quit 2>/dev/null || true
  find "$BROWSER_DIST" -type f ! -name '.*' -newer "$M40_ARMS" -print -quit 2>/dev/null || true
  # THE TRACER MODULE IS AN INPUT. The page fetches it, so a module that moved under a report is
  # a report about a different module — M30's "a mutation silently undone and printed as the arm's
  # result", one level out.
  find "$M40_TRACER_WASM" -newer "$M40_ARMS" -print -quit 2>/dev/null || true
  # AND SO IS THE WRITER. `ct_source_step` is M40's own export and the page writes the private
  # half's container with it.
  find "$REPO_ROOT/ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm" \
    -newer "$M40_ARMS" -print -quit 2>/dev/null || true
}

_m40_run_bounded() { # <label> <timeout> <report> <script> <workdir>
  local label="$1" bound="$2" report="$3" script="$4" workdir="$5"
  local rc why
  ( cd "$REPO_ROOT" && env NODE_NO_WARNINGS=1 BROWSER_DIST="$BROWSER_DIST" \
      AVM_WASM_PATH="${AVM_WASM_PATH:-}" M27_CHROMIUM="${M27_CHROMIUM:-}" \
      M27_CHROMIUM_VERSION="${M27_CHROMIUM_VERSION:-}" \
      M40_TRACER_WASM="$M40_TRACER_WASM" M40_TAPE_SOURCE="$M40_ARMS" \
      timeout -s KILL "$bound" node "$REPO_ROOT/tools/$script" "$workdir" ) \
    > "$report.tmp" 2> "$workdir/arms.stderr"
  rc=$?
  if [ "$rc" != "0" ]; then
    mv -f "$report.tmp" "$workdir/arms.failed.json" 2>/dev/null || true
    case "$rc" in
      124|137)
        # A HANG, NAMED AS ONE. `timeout` answers 124, or 137 when it escalates to SIGKILL, and
        # reporting either as "exited 137" is a check pointing at nothing: a process that never
        # finishes and one that failed need different remedies.
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

m40_require_arms() {
  m27_require_bundle
  m27_require_module
  m27_require_chromium
  m40_require_tracer
  mkdir -p "$M40_WORK"
  [ -s "$BROWSER_DIST/wallet-demo.js" ] \
    || die "there is no built wallet-demo entry at $BROWSER_DIST/wallet-demo.js.
             Remedy: just browser-build"
  [ -s "$REPO_ROOT/ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm" ] \
    || die "there is no built ct_writer.wasm.
             Remedy: verification/build_ct_writer_wasm.sh"

  local stale=0 newer
  newer="$(m40_arms_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M40_ARMS_REFRESH:-0}" = "1" ] && stale=1
  if [ "$stale" = "1" ]; then
    note "running the both-halves arms in $M27_CHROMIUM_VERSION (timeout ${M40_ARMS_TIMEOUT}s)"
    _m40_run_bounded "both-halves" "$M40_ARMS_TIMEOUT" "$M40_ARMS" run_m40_transaction_arms.mjs "$M40_WORK"
  fi
  [ -s "$M40_ARMS" ] || die "there is no arm report at $M40_ARMS even after running"
}

# ---------------------------------------------------------------------------
# The native trace arm — the SAME transaction's private half, stepped natively.
# ---------------------------------------------------------------------------
m40_trace_newer_inputs() {
  [ -s "$M40_TRACE_ARMS" ] || { printf 'joined-transaction.json\n'; return 0; }
  find "$REPO_ROOT/tools/run_m40_trace_arms.mjs" -newer "$M40_TRACE_ARMS" -print -quit 2>/dev/null || true
  find "$REPO_ROOT/verification/m38_private_trace_probe.rs" -newer "$M40_TRACE_ARMS" -print -quit 2>/dev/null || true
  find "$M40_ARMS" -newer "$M40_TRACE_ARMS" -print -quit 2>/dev/null || true
}

m40_require_trace_arms() {
  m40_require_arms
  mkdir -p "$M40_TRACE_WORK"
  # THE PROBE IS BUILT, for `m40_require_tracer`'s reason one level over: M39's log records the
  # arm that reported a faithful measurement of unmutated code because its precondition checked
  # that the probe EXISTED and never rebuilt it.
  "$VERIFY_DIR/build_m38_private_trace_probe.sh" >/dev/null \
    || die "the M38 private-trace probe failed to build.
             Remedy: verification/build_m38_private_trace_probe.sh"

  local stale=0 newer
  newer="$(m40_trace_newer_inputs)"
  [ -n "$newer" ] && stale=1
  [ "${M40_TRACE_REFRESH:-0}" = "1" ] && stale=1
  if [ "$stale" = "1" ]; then
    note "running the native private-half trace arm (timeout ${M40_TRACE_TIMEOUT}s)"
    _m40_run_bounded "private-half trace" "$M40_TRACE_TIMEOUT" "$M40_TRACE_ARMS" \
      run_m40_trace_arms.mjs "$M40_TRACE_WORK"
  fi
  [ -s "$M40_TRACE_ARMS" ] || die "there is no trace arm report at $M40_TRACE_ARMS even after running"
}

# ---------------------------------------------------------------------------
# Readers. `MISSING` for an absent node, `UNREADABLE` for a report that will not parse — the two
# spellings `m38_absent` knows about, so a field nobody wrote and a report nobody can read are
# different failures rather than one empty string.
# ---------------------------------------------------------------------------
_m40_read() { # <report> <dotted.path>
  python3 -c '
import json, sys
try:
    doc = json.load(open(sys.argv[1]))
except Exception:
    print("UNREADABLE"); raise SystemExit(0)
cur = doc
for part in sys.argv[2].split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    elif isinstance(cur, list) and part.isdigit() and int(part) < len(cur):
        cur = cur[int(part)]
    else:
        print("MISSING"); raise SystemExit(0)
if cur is None:
    print("MISSING")
elif isinstance(cur, bool):
    print("true" if cur else "false")
elif isinstance(cur, (dict, list)):
    print(json.dumps(cur, sort_keys=True))
else:
    print(cur)
' "$1" "$2"
}

m40_arm() { _m40_read "$M40_ARMS" "arms.$1"; }
m40_top() { _m40_read "$M40_ARMS" "$1"; }
m40_trace() { _m40_read "$M40_TRACE_ARMS" "$1"; }

# m40_container <ct path> <field> — through the PINNED READER and not through a producer's report.
#
# M29's rule, which it earned by finding a check that read an opcode histogram out of the producer's
# own report while the writer wrote fabricated opcodes: a producer's report about itself is not its
# output.
#
# **THE TWO HALVES ARE READ BY TWO DIFFERENT RENDERINGS OF ONE READER, AND THAT IS A FACT ABOUT THE
# READER.** `ct-print` chooses its decoder by what the container carries: the Nim writer's split
# streams decode to `kind: "step"` records with a `column`, and the Path A writer's single stream
# decodes to low-level `type: "Step"` events, which have no column field at all. So this projection
# handles both shapes and a caller asking for withColumn gets NOCOLUMNS — not `0` — from the
# rendering that cannot answer, because a zero there would be an absence measured by an instrument
# that cannot see the subject, which is this campaign's second-most-repeated defect.
m40_container() { # <ct path> <field>
  "$(m38_ct_print)" --full "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("UNREADABLE"); raise SystemExit(0)
events = doc.get("events", [])
decoded = [e for e in events if e.get("kind") == "step"]
lowlevel = [e for e in events if e.get("type") == "Step"]
paths = doc.get("paths", [])
# THE DISCRIMINATOR IS THE READER OWN OUTPUT SHAPE. ct-print emits a `counts` object only from
# its split-stream decoder; the legacy events.log one emits metadata/paths/events and nothing
# else. The first draft asked whether ANY event carried a `kind`, and a Type event carries
# `kind: "tkNone"` -- so a Path A container read as split, and `withColumn` answered 0 where it
# should have refused to answer at all. An instrument that cannot see the subject must SAY so.
#
# (And this comment carried an apostrophe on its first attempt, which CLOSED the single-quoted
# python program bash is passing to `-c`. Every field then answered the empty string and sixteen
# assertions compared it against real values -- loudly, which is the cheap direction, but a
# comment that terminates the program it documents is worth the sentence.)
split = isinstance(doc.get("counts"), dict)
steps = decoded if split else lowlevel
field = sys.argv[1]

def position(e):
    if split:
        return (e.get("path"), e.get("line"))
    idx = e.get("path_id")
    return (paths[idx] if isinstance(idx, int) and idx < len(paths) else "?", e.get("line"))

if field == "rendering":
    print("split" if split else "lowlevel")
elif field == "steps":
    print(len(steps))
elif field == "withColumn":
    print(sum(1 for e in steps if e.get("column")) if split else "NOCOLUMNS")
elif field == "distinctLines":
    print(len({position(e) for e in steps}))
elif field == "distinctPaths":
    print(len({position(e)[0] for e in steps}))
elif field == "positions":
    print("\n".join("%s:%s:%s" % (position(e)[0], position(e)[1],
                                  e.get("column") if split and e.get("column") else "-")
                    for e in steps))
elif field == "paths":
    print(len(paths))
elif field == "callEntries":
    print(sum(1 for e in events if e.get("kind") == "call_entry")
          if split else sum(1 for e in events if e.get("type") == "Call"))
elif field == "callNames":
    if split:
        names = [e.get("function", "?") for e in events if e.get("kind") == "call_entry"]
    else:
        fns = [e.get("name", "?") for e in events if e.get("type") == "Function"]
        names = []
        for e in events:
            if e.get("type") == "Call":
                i = e.get("function_id")
                names.append(fns[i] if isinstance(i, int) and i < len(fns) else "?")
    print(",".join(sorted(names)) or "NONE")
elif field == "join":
    rec = [e for e in events if e.get("metadata") == "ct.trace-join"]
    if not rec:
        print("NONE")
    else:
        print(rec[0].get("text") or rec[0].get("content") or "MISSING")
elif field == "joinCount":
    print(sum(1 for e in events if e.get("metadata") == "ct.trace-join"))
elif field == "logEventKeys":
    print(",".join(sorted(e["metadata"] for e in events if e.get("metadata"))) or "NONE")
else:
    print("MISSING")
' "$2"
}
