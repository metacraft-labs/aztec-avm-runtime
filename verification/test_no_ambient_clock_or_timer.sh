#!/usr/bin/env bash
# test_no_ambient_clock_or_timer — DD-4, asserted structurally, with a planted control.
#
# The verification entry: "No source file in the runtime references Date.now, setInterval or
# setTimeout outside the injected Clock implementation."
#
# THE ENTRY SAYS "OUTSIDE THE INJECTED CLOCK IMPLEMENTATION" AND THE ANSWER HERE IS STRONGER:
# there is no such call ANYWHERE in the shipped source, including in the clock, because the clock
# is not ours. `DateProvider` lives in `@aztec/foundation/timer` and `RunningPromise` in
# `@aztec/foundation/running-promise`; both are in `node_modules`, which is the point — the timer
# is a dependency the runtime NAMES rather than a call the runtime MAKES.
#
# THE SCANNED ROOTS ARE WHAT SHIPS. `orchestration/src` and `node-host/src`. `tools/` and
# `verification/` are excluded deliberately and not by accident: this check plants a `Date.now()`
# as its own control, and a scan that covered the probe would catch its own probe.
#
# AN ABSENCE CHECK NEEDS A CONTROL AND THIS ONE HAS TWO. Twenty-something files with no matches is
# also what a broken scanner produces, so: the scan must SEE a substantial number of files, and a
# planted call in a file inside a scanned root must be REPORTED — for each needle
# separately, because a scanner that caught `Date.now` and missed `setInterval` would pass a
# single-needle control.
#
# THE NEEDLE IS CALL-SHAPED, not the bare name. `Date.now` appears in this repository's own prose —
# including in the header of the file that explains why it is not called — and this campaign has a
# recorded defect for a bare-text needle satisfied by a citation. So the needle carries the open
# parenthesis and whole-line comments are stripped first, with the stripping shown to be
# load-bearing rather than merely present.
#
# Run: just verify-chain-no-ambient-clock

TEST_NAME="test_no_ambient_clock_or_timer"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"

# The scanner. Strips block comments, line comments and string literals, then looks for the three
# call shapes. It PRINTS what it finds rather than counting, which is the shape a scanner should
# have — a class that is too narrow becomes a red line instead of a silent undercount.
SCAN_PY="$M23_WORK/scan_clock.py"
mkdir -p "$M23_WORK"
cat > "$SCAN_PY" <<'PY'
import os, re, sys

NEEDLES = (
    ("Date.now(", re.compile(r"\bDate\.now\s*\(")),
    ("new Date()", re.compile(r"\bnew\s+Date\s*\(\s*\)")),
    ("performance.now(", re.compile(r"\bperformance\.now\s*\(")),
    ("process.hrtime", re.compile(r"\bprocess\.hrtime\b")),
    ("setInterval(", re.compile(r"\bsetInterval\s*\(")),
    ("setTimeout(", re.compile(r"\bsetTimeout\s*\(")),
    ("setImmediate(", re.compile(r"\bsetImmediate\s*\(")),
)

def strip(text):
    # Block comments first, then line comments, then string literals. Order matters: a `//` inside
    # a string literal must not start a comment, which is a defect this campaign has recorded in
    # its own import-graph walker. A template literal's `${ ... }` is CODE and is kept: `interp`
    # records, for each open interpolation, the brace depth at which it closes back into its
    # template literal.
    out = []
    i = 0
    n = len(text)
    state = None  # None | 'block' | 'line' | quote char
    interp = []
    depth = 0
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ''
        if state is None:
            if c == '/' and nxt == '*':
                state = 'block'; i += 2; continue
            if c == '/' and nxt == '/':
                state = 'line'; i += 2; continue
            if c in ('"', "'", '`'):
                state = c; i += 1; continue
            if c == '{':
                depth += 1
            elif c == '}':
                if interp and interp[-1] == depth:
                    interp.pop(); state = '`'; out.append(' '); i += 1; continue
                depth -= 1
            out.append(c); i += 1; continue
        if state == 'block':
            if c == '\n':
                out.append(c)
            if c == '*' and nxt == '/':
                state = None; i += 2; continue
            i += 1; continue
        if state == 'line':
            if c == '\n':
                state = None; out.append(c)
            i += 1; continue
        # inside a string literal; newlines are kept so line numbers stay true
        if c == '\\':
            i += 2; continue
        if c == '\n':
            out.append(c)
        if state == '`' and c == '$' and nxt == '{':
            interp.append(depth); state = None; out.append(' '); i += 2; continue
        if c == state:
            state = None
        i += 1
    return ''.join(out)

roots = sys.argv[1:]
files = 0
hits = []
for root in roots:
    if not root or not os.path.isdir(root):
        continue
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d != 'node_modules']
        for f in sorted(filenames):
            if not f.endswith(('.ts', '.mts', '.mjs', '.js')):
                continue
            path = os.path.join(dirpath, f)
            files += 1
            try:
                code = strip(open(path, encoding='utf-8').read())
            except (UnicodeDecodeError, OSError):
                print('UNREADABLE %s' % path)
                continue
            for lineno, line in enumerate(code.split('\n'), 1):
                for name, rx in NEEDLES:
                    if rx.search(line):
                        hits.append('%s:%d:%s' % (path, lineno, name))
print('FILES %d' % files)
for h in hits:
    print('HIT %s' % h)
PY

scan() { python3 "$SCAN_PY" "$@"; }

# ---------------------------------------------------------------------------
# PART 1 — the shipped source, scanned
# ---------------------------------------------------------------------------
echo "== no ambient clock or timer in the shipped source"

MAIN="$(scan "$ORCH_SRC" "$REPO_ROOT/node-host/src")"
FILES="$(printf '%s\n' "$MAIN" | sed -n 's/^FILES //p')"
HITS="$(printf '%s\n' "$MAIN" | sed -n 's/^HIT //p')"

assert_ge "the scan saw a substantial number of shipped source files" 25 "$FILES"
assert_eq "…and read every one of them" "" "$(printf '%s\n' "$MAIN" | sed -n 's/^UNREADABLE //p')"

# THE TWO PLACES THE TREE DOES READ A CLOCK, each with its reason, by file, needle and count. The
# hits are compared with this list EXACTLY: a new call anywhere is a hit the list does not have, and
# a listed call that disappears leaves an exception the tree no longer needs.
#
#   chain_e2e_driver.ts  performance.now(  x4  The e2e HARNESS times its own arms (`elapsedMs`) to
#                        show the fake-clock chain does not wait. Nothing it measures reaches a
#                        block, and index.ts does not export it (asserted below).
#   vendor/public_processor/public_processor.ts  process.hrtime  x2  UPSTREAM'S tree-insertion
#                        duration metric, vendored as upstream has it; it feeds a histogram and
#                        never a timestamp.
ALLOWED_CLOCK_READS="orchestration/src/chain_e2e_driver.ts performance.now( 4
orchestration/src/vendor/public_processor/public_processor.ts process.hrtime 2"
SEEN_CLOCK_READS="$(printf '%s\n' "$HITS" | sed -n "s|^$REPO_ROOT/||p" \
  | awk -F: 'NF { n[$1 " " $3]++ } END { for (k in n) print k, n[k] }' | LC_ALL=C sort)"
assert_eq "…and every clock read or timer in them is one of the two enumerated exceptions, no more" \
  "$(printf '%s\n' "$ALLOWED_CLOCK_READS" | LC_ALL=C sort)" "$SEEN_CLOCK_READS"
assert_false "…and the harness that reads performance.now is not part of the exported surface" \
  str_has_sub "$(cat "$ORCH_SRC/index.ts")" "chain_e2e_driver"

# ---------------------------------------------------------------------------
# PART 2 — THE CONTROLS: a planted call of each kind is reported
# ---------------------------------------------------------------------------
echo "== the controls: a planted call of each kind is caught"

# `~/.cache`, never `$TMPDIR`: on this host `/tmp` is a shared 32 GB tmpfs and `df` reporting free
# gigabytes is not evidence that a write will succeed. `lib.sh` repoints `$TMPDIR` anyway; this
# check owns its own directory so the probe cannot collide with another agent's.
PROBE_ROOT="$HOME/.cache/aztec-m23-clock-probe"
mkdir -p "$PROBE_ROOT" || die "could not create $PROBE_ROOT"
PROBE="$(mktemp -d "$PROBE_ROOT/probe.XXXXXX")" || die "no scratch under $PROBE_ROOT"
trap 'rm -rf "$PROBE"' EXIT INT TERM HUP

mkdir -p "$PROBE/src"
# A file with a REAL call of each kind, one per file so each control is independent.
printf 'export const t = Date.now();\n' > "$PROBE/src/a.ts"
printf 'export const h = setInterval(() => {}, 1000);\n' > "$PROBE/src/b.ts"
printf 'export const g = setTimeout(() => {}, 1);\n' > "$PROBE/src/c.ts"
# And a file that only MENTIONS them — in a comment and in a string — which must NOT be reported.
cat > "$PROBE/src/d.ts" <<'EOF'
// DD-4 forbids Date.now() and setInterval() here.
/* setTimeout( is also forbidden. */
export const why = 'we do not call Date.now() or setInterval(';
export const url = 'http://example.invalid/setTimeout(';
export const tpl = `neither performance.now() nor new Date() ${'is called'} here`;
export const fixed = new Date(1700000000000);
EOF
# …and one call of each needle the entry does not name, plus a call INSIDE a template interpolation.
printf 'export const s = `stamp-${Date.now()}`;\n' > "$PROBE/src/e.ts"
printf 'export const p = performance.now();\n' > "$PROBE/src/f.ts"
printf 'export const w = new Date();\n' > "$PROBE/src/g.ts"
printf 'export const i = setImmediate(() => {});\n' > "$PROBE/src/h.ts"
printf 'export const r = process.hrtime.bigint();\n' > "$PROBE/src/i.ts"

CONTROL="$(scan "$PROBE/src")"
C_FILES="$(printf '%s\n' "$CONTROL" | sed -n 's/^FILES //p')"
C_HITS="$(printf '%s\n' "$CONTROL" | sed -n 's/^HIT //p')"
assert_eq "the control scan saw nine probe files" "9" "$C_FILES"

for pair in "a.ts Date.now(" "b.ts setInterval(" "c.ts setTimeout(" "e.ts Date.now(" \
            "f.ts performance.now(" "g.ts new Date()" "h.ts setImmediate(" "i.ts process.hrtime"; do
  f="${pair%% *}"; needle="${pair#* }"
  assert_true "a planted $needle in $f is REPORTED" \
    str_has_line_re "$C_HITS" "/$f:[0-9]+:$(printf '%s' "$needle" | sed 's/[.()]/\\&/g')\$"
done
assert_eq "the probe reports exactly eight hits, one per planted call, e.ts's inside a template interpolation" \
  "8" "$(printf '%s\n' "$C_HITS" | grep -c . || true)"
assert_false "…and the file that only MENTIONS them in comments and strings is not reported" \
  str_has_sub "$C_HITS" "/d.ts:"

# THE STRIPPER IS SHOWN TO BE LOAD-BEARING: without stripping, d.ts WOULD match. Measured with a
# plain grep over the same file, so the difference is attributable to the stripping and not to the
# file being empty.
RAW="$(grep -c -e 'Date\.now(' -e 'setInterval(' -e 'setTimeout(' "$PROBE/src/d.ts" || true)"
assert_ge "an unstripped grep DOES match that file, so the stripping is what excludes it" 3 "$RAW"

# ---------------------------------------------------------------------------
# PART 3 — the clock and the ticker are injected, and that is structural too
# ---------------------------------------------------------------------------
echo "== the clock and the ticker arrive as arguments"

CHAIN="$(cat "$ORCH_SRC/chain.ts")"
assert_true "ChainDeps declares an injected clock" str_has_sub "$CHAIN" "readonly clock?: DateProvider;"
assert_true "…and an injected ticker" str_has_sub "$CHAIN" "readonly ticker?: BlockTicker;"
assert_true "the chain's clock is the dependency's or upstream's DateProvider" \
  str_has_sub "$CHAIN" "this.clock = deps.clock ?? new DateProvider();"
# `new DateProvider()` is upstream's class, imported. That it is imported rather than declared is
# what makes the whole file free of a wall-clock call.
assert_true "DateProvider is re-exported from chain_clock.ts, not declared there" \
  str_has_sub "$(cat "$ORCH_SRC/chain_clock.ts")" "import { DateProvider, ManualDateProvider, TestDateProvider } from '@aztec/foundation/timer';"

echo "== and no Clock interface of ours is declared anywhere"
# The parallel-type rule, applied to the clock. `verify_named_checks_exist`'s shape: a declaration
# is `interface Clock` or `class Clock`, and the needle is required to find upstream's family so it
# is not matching nothing.
OURS_CLOCK="$(grep -rn -E '^\s*(export )?(interface|class|type) Clock\b' "$ORCH_SRC" "$REPO_ROOT/node-host/src" || true)"
assert_eq "no Clock interface, class or type of ours is declared" "" "$OURS_CLOCK"
assert_true "…and the needle DOES find our BlockTicker declaration, so it works" \
  test -n "$(grep -rn -E '^\s*export interface BlockTicker\b' "$ORCH_SRC" || true)"

m23_finish
