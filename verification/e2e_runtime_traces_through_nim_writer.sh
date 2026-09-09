#!/usr/bin/env bash
# e2e_runtime_traces_through_nim_writer
#
# M41 end to end: a trace driven through the NIM writer, INSIDE A REAL BROWSER, produces a container
# whose every step is at the position the driver asked for.
#
# ---------------------------------------------------------------------------
# WHY A BROWSER AND NOT NODE WITH A NOTE SAYING IT WOULD ALSO WORK IN ONE
# ---------------------------------------------------------------------------
#
# The whole of DD-7's browser argument is about what a PAGE can do, and node differs from a page in
# the two places this module lives: node satisfies imports from its own globals, and node has a
# filesystem. So the module is fetched over HTTP, compiled by Chrome's own
# `WebAssembly.instantiateStreaming`, instantiated against a LITERAL `{}`, and driven by the SAME
# `ct_writer_drive_core.mjs` the node arm imports — served to the page as an ES module rather than
# reimplemented in a string, so the browser arm cannot drift from the node one.
#
# ---------------------------------------------------------------------------
# THE PREDICATE IS PER-STEP POSITIONS, NOT A COUNT, AND THAT IS WHY IT FOUND SOMETHING
# ---------------------------------------------------------------------------
#
# A step COUNT is satisfied by a container with the right number of wrong steps. The first Path B
# build produced exactly the right number of steps with EVERY COLUMN ONE TOO HIGH — the Nim ABI
# takes a column DELTA from a step that already sits at column 1, and the backend passed the column
# itself. Nothing refused it: a column one to the right is a real position in a real line, so no
# reader could object. It was found by comparing the positions read back against the positions the
# driver asked for, and by nothing else.
#
# ---------------------------------------------------------------------------
# THE CONTROL: A SYNTHESISED STREAM FAILS THE SAME PREDICATE
# ---------------------------------------------------------------------------
#
# The comparison is run a second time against an expectation with ONE position moved. It must fail,
# and must name the step it failed on. Without that arm the equality above is one nobody has seen
# move — and this campaign has found checks asserting a value nothing could produce, passing.
#
# THE READER IS THE ONE AT THE WRITER ANCHOR, deliberately, and the milestone's word "pinned" is
# honoured by pinning it rather than by using the older of the two: the reader anchor
# (`trace_format_nim`, 2026-08-20) CANNOT read a Path B container — measured, and catalogued by
# `verify_container_equivalence_characterised`. Using it here would produce a red that says nothing
# about the writer.
#
# Run: just e2e-runtime-traces-through-nim-writer

TEST_NAME="e2e_runtime_traces_through_nim_writer"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

TAB=$'\t'

CHROMIUM="${M41_CHROMIUM:-${M27_CHROMIUM:-$(command -v chromium || command -v chromium-browser || command -v google-chrome || true)}}"
[ -n "$CHROMIUM" ] || die "no chromium on PATH. This check drives a REAL headless browser over the
     DevTools protocol; a node run is not a substitute, because node satisfies imports from its own
     globals and has a filesystem, which are the two things the browser claim is about.
     Remedy: install chromium, or set M41_CHROMIUM."
m41_say "browser: $("$CHROMIUM" --version 2>/dev/null | head -1)"

m41_require_path_b
m41_require_readers

# ---------------------------------------------------------------------------
# 1. The browser run.
# ---------------------------------------------------------------------------
BROWSER_DIR="$M41_WORK/browser"
rm -rf "$BROWSER_DIR"
M41_CHROMIUM="$CHROMIUM" m41_bounded 600 "the browser writer run" \
  node "$REPO_ROOT/tools/m41_browser_writer.mjs" "$M41_PATH_B" "$BROWSER_DIR" \
  || die "the browser run failed; its output is in $M41_LAST_LOG:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"

assert_file "the browser produced a container" "$BROWSER_DIR/container.ct"
assert_file "and a report" "$BROWSER_DIR/report.json"

BR_HOST="$(m41_report browser host)"
BR_KIND="$(m41_report browser writerKind)"
BR_BYTES="$(m41_report browser containerBytes)"
BR_UA="$(m41_report browser userAgent)"
assert_eq "the run happened in a browser and says so" "browser" "$BR_HOST"
assert_eq "and the container was written by the NIM writer" "2" "$BR_KIND"
assert_ge "and it is a real container" 1024 "$BR_BYTES"
assert_contains "and the user agent is a real headless Chrome" "HeadlessChrome" "$BR_UA"
assert_eq "the page threw nothing" "[]" "$(m41_report browser pageErrors)"
m41_say "$BR_BYTES container bytes from $BR_UA"

# The page fetched the module and the driver over HTTP and nothing else. A 404 in the server's own
# log would mean the page reached for something the check did not give it.
REQS="$(m41_report browser pageRequests)"
assert_contains "the page fetched the module over HTTP" '"ct_writer.wasm 200"' "$REQS"
assert_contains "and the shared driver, as a module" '"drive.mjs 200"' "$REQS"
# Every 404 is enumerated rather than forbidden outright: the browser asks for `favicon.ico` on
# its own, and a blanket "no 404s" would fail on the browser's habit rather than on anything the
# page did. The exception is named exactly, so a page reaching for a SECOND missing thing fails.
UNEXPECTED_404="$(printf '%s' "$REQS" | python3 -c "
import json, sys
reqs = json.load(sys.stdin)
print(' '.join(r for r in reqs if r.endswith(' 404') and r != 'favicon.ico 404'))
")"
assert_eq "the only 404 is the browser's own favicon probe, which the page did not ask for" \
  "" "$UNEXPECTED_404"

# ---------------------------------------------------------------------------
# 2. The node arm, so "in a browser" is a claim about the browser rather than about the writer.
# ---------------------------------------------------------------------------
m41_drive "$M41_PATH_B" node-arm
NODE_BYTES="$(m41_report node-arm containerBytes)"
assert_eq "the browser and node containers are the same length" "$NODE_BYTES" "$BR_BYTES"
assert_true "and the same bytes" \
  cmp -s "$BROWSER_DIR/container.ct" "$M41_WORK/node-arm/container.ct"

# ---------------------------------------------------------------------------
# 3. THE PREDICATE. Every step is where the driver asked for it.
# ---------------------------------------------------------------------------
FULL="$M41_WORK/browser-full.json"
m41_bounded "$M41_READER_TIMEOUT" "ct-print at the writer anchor" \
  "$M41_READERS/ct-print-writer" --full "$BROWSER_DIR/container.ct" \
  || die "the reader at the writer anchor could not decode the browser's container:
$(tail -5 "$M41_LAST_LOG" 2>/dev/null)"
cp "$M41_LAST_LOG" "$FULL"

EXPECTED="$M41_WORK/expected-steps.json"
python3 -c "
import json, sys
d = json.load(open('$BROWSER_DIR/report.json', encoding='utf-8'))
json.dump(d['expectedSteps'], open('$EXPECTED', 'w', encoding='utf-8'))
" || die "the browser's report carries no expectedSteps"

POS_OUT="$M41_WORK/step-positions.tsv"
if python3 "$REPO_ROOT/verification/_m41_step_positions.py" "$FULL" "$EXPECTED" >"$POS_OUT" 2>&1; then
  pass "every step in the browser's container is at the position the driver asked for"
else
  fail "the browser's container has steps the driver did not ask for:
$(grep '^MISMATCH' "$POS_OUT" || cat "$POS_OUT")"
fi
m41_say "$(grep '^STEPS' "$POS_OUT")"
sed -n 's/^STEP\t/    step /p' "$POS_OUT" | while IFS= read -r l; do m41_say "$l"; done

# The count is asserted too, and against the DRIVER's own figure rather than a literal: the driver
# makes seven step-producing calls and the Nim writer emits one more of its own at the entry line.
DRIVEN="$(m41_report browser drivenStepCount)"
READ_STEPS="$(sed -n 's/^STEPS\t//p' "$POS_OUT")"
assert_eq "the container carries the driven steps plus the writer's own entry step" \
  "$((DRIVEN + 1))" "$READ_STEPS"

# And against the MODULE's own statistic, which is a third independent count.
assert_eq "and the module's own event counter agrees with what was driven" \
  "$DRIVEN" "$(m41_report browser eventsWritten)"

# ---------------------------------------------------------------------------
# 4. THE CONTROL. A synthesised stream fails the same predicate, and says where.
# ---------------------------------------------------------------------------
SYNTH="$M41_WORK/synthesised-steps.json"
python3 -c "
import json
e = json.load(open('$EXPECTED', encoding='utf-8'))
# ONE position moved, by ONE column, on a step that has one. Not a wholesale replacement: a
# comparison that only rejects garbage has not been shown to reject the failure this check exists
# for, which was every column off by exactly one.
for s in e:
    if s['column'] is not None:
        s['column'] += 1
        break
json.dump(e, open('$SYNTH', 'w', encoding='utf-8'))
"
SYNTH_OUT="$M41_WORK/synthesised.tsv"
if python3 "$REPO_ROOT/verification/_m41_step_positions.py" "$FULL" "$SYNTH" >"$SYNTH_OUT" 2>&1; then
  fail "THE CONTROL PASSED: a stream with a column moved by one was accepted, so the comparison
     above cannot see the defect it was written for and every green in section 3 is unearned"
else
  pass "a synthesised stream FAILS the same predicate, so the comparison discriminates"
fi
assert_true "and the failure names the step it disagreed on" \
  grep -qE "^MISMATCH${TAB}1${TAB}" "$SYNTH_OUT"
assert_contains "and reports the comparison as failed rather than silently" \
  "MATCH${TAB}failed" "$(cat "$SYNTH_OUT")"

# The second control, in the other direction: a stream with a step REMOVED must also fail, on the
# count rather than on a position. The two failures are different shapes and a check that had shown
# only one would be claiming the other.
SHORT="$M41_WORK/short-steps.json"
python3 -c "
import json
e = json.load(open('$EXPECTED', encoding='utf-8'))
json.dump(e[:-1], open('$SHORT', 'w', encoding='utf-8'))
"
SHORT_OUT="$M41_WORK/short.tsv"
if python3 "$REPO_ROOT/verification/_m41_step_positions.py" "$FULL" "$SHORT" >"$SHORT_OUT" 2>&1; then
  fail "THE SECOND CONTROL PASSED: an expectation one step short was accepted, so the comparison
     is a prefix test and a container with extra steps would pass it"
else
  pass "an expectation one step short FAILS, so the comparison is not a prefix test"
fi
assert_true "and the failure names the count" \
  grep -qE "^MISMATCH${TAB}count${TAB}" "$SHORT_OUT"

finish
