#!/usr/bin/env bash
# verify_declared_writer_path_matches_module
#
# M41 verification: the host REFUSES a writer module whose `ct_writer_kind()` disagrees with the
# writer path the tracing configuration declares, at the point the two meet — `new CtWriter(...)`
# — and the refusal names both.
#
# WHY. The declared path is a LABEL: the browser, the replay tools and every driver record it as
# `writerPath` beside the container, and a reader of that record believes it. The module's kind is
# the FACT. Until this check, `writerKindMatchesPath` was exported and called by nothing, so a host
# that declared `path-a-pure-rust` over the Nim writer recorded that label without complaint — and
# M41's flip found several places doing exactly that. A recording that names the wrong writer is
# the silent shape DD-7 exists to refuse.
#
# ---------------------------------------------------------------------------
# THE MISMATCHED PAIRS ARE THE SUBJECT, AND NOTHING HERE IS A MOCK.
#
# Both modules are the real ones `lib_m41_writer.sh` builds — Path A by `--path-a`, Path B by
# `--path-b` — and the host is the real `ct-host`, imported from its source. The probe pairs every
# module with every declared path ON PURPOSE: the two matching pairs are the control (a host that
# refused everything would satisfy every refusal assertion), and the two crossed pairs are what the
# check is about. No test-only switch exists to let a crossed pair through, and none is used; the
# mutation arm below disables the comparison by editing a COPY of the host, never the host.
#
# THE MUTATION ARM IS WHAT MAKES THE REFUSAL LOAD-BEARING. A refusal could be produced by something
# else that happens to throw — an export check, a record-size check — and every assertion on the
# crossed pairs would still pass. So the comparison alone is removed from a copy of `ct-host/src`,
# the SAME probe is run against it, and the crossed pairs must then be ALLOWED and must record the
# wrong label: that is the defect this check exists for, reproduced, and it is what proves the
# assertions above are asserting the comparison and nothing adjacent to it.
#
# Run: just verify-declared-writer-path

TEST_NAME="verify_declared_writer_path_matches_module"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

TAB=$'\t'
PROBE="$REPO_ROOT/verification/_writer_kind_probe.mjs"
[ -f "$PROBE" ] || die "the probe $PROBE is missing"

m41_require_path_a
m41_require_path_b

# run_probe <ct-host dir> <out file> — the probe, bounded, its output kept for the assertions.
run_probe() {
  local host="$1" out="$2"
  m41_bounded "$M41_DRIVE_TIMEOUT" "the writer-kind probe over $host" \
    node --experimental-strip-types "$PROBE" "$host/src/index.ts" "$M41_PATH_A" "$M41_PATH_B" \
    || die "the writer-kind probe failed over $host; its output is in $M41_LAST_LOG:
$(tail -20 "$M41_LAST_LOG" 2>/dev/null)"
  cp "$M41_LAST_LOG" "$out"
  grep -q '^PROBEDONE$' "$out" || die "the writer-kind probe over $host did not finish; see $out"
}

OUT="$M41_WORK/kind-probe.out"
run_probe "$M41_HOST" "$OUT"
PROBE_OUT="$(cat "$OUT")"

# ---------------------------------------------------------------------------
# 1. The two modules really are the two writers, read off the modules themselves.
# ---------------------------------------------------------------------------
assert_true "the Path A module reports ct_writer_kind() = 1" \
  str_has_line "$PROBE_OUT" "KIND${TAB}path-a-module${TAB}1"
assert_true "the Path B module reports ct_writer_kind() = 2" \
  str_has_line "$PROBE_OUT" "KIND${TAB}path-b-module${TAB}2"

# ---------------------------------------------------------------------------
# 2. THE CONTROL: a declaration that matches its module records, and records the right label.
# ---------------------------------------------------------------------------
assert_true "Path A declared over the Path A module is ALLOWED, and records all seven events" \
  str_has_line "$PROBE_OUT" "ALLOWED${TAB}path-a-module${TAB}path-a-pure-rust${TAB}7${TAB}1${TAB}path-a-pure-rust"
assert_true "Path B declared over the Path B module is ALLOWED, and records all seven events" \
  str_has_line "$PROBE_OUT" "ALLOWED${TAB}path-b-module${TAB}path-b-nim${TAB}7${TAB}2${TAB}path-b-nim"

# ---------------------------------------------------------------------------
# 3. THE SUBJECT: a declaration that contradicts its module is REFUSED, by name, naming both.
# ---------------------------------------------------------------------------
assert_true "Path A declared over the Path B module is REFUSED as WriterKindMismatch, declared path-a-pure-rust, reported kind 2" \
  str_has_line_re "$PROBE_OUT" "^REFUSED${TAB}path-b-module${TAB}path-a-pure-rust${TAB}WriterKindMismatch${TAB}path-a-pure-rust${TAB}2${TAB}"
assert_true "Path B declared over the Path A module is REFUSED as WriterKindMismatch, declared path-b-nim, reported kind 1" \
  str_has_line_re "$PROBE_OUT" "^REFUSED${TAB}path-a-module${TAB}path-b-nim${TAB}WriterKindMismatch${TAB}path-b-nim${TAB}1${TAB}"
MSG_BA="$(printf '%s\n' "$PROBE_OUT" | awk -F'\t' '$1=="REFUSED" && $2=="path-b-module" {print $7}')"
MSG_AB="$(printf '%s\n' "$PROBE_OUT" | awk -F'\t' '$1=="REFUSED" && $2=="path-a-module" {print $7}')"
assert_true "the first refusal's message names the declared path" \
  str_has_sub "$MSG_BA" "declares the 'path-a-pure-rust' writer path (ct_writer_kind() = 1)"
assert_true "and the kind the module reported, with the path that kind belongs to" \
  str_has_sub "$MSG_BA" "reports ct_writer_kind() = 2, the 'path-b-nim' writer"
assert_true "the second refusal's message names the declared path" \
  str_has_sub "$MSG_AB" "declares the 'path-b-nim' writer path (ct_writer_kind() = 2)"
assert_true "and the kind the module reported, with the path that kind belongs to" \
  str_has_sub "$MSG_AB" "reports ct_writer_kind() = 1, the 'path-a-pure-rust' writer"
assert_eq "exactly two pairs are refused — the two crossed ones, and neither control" "2" \
  "$(printf '%s\n' "$PROBE_OUT" | grep -c "^REFUSED${TAB}" || true)"

# The refusal comes BEFORE the session opens: the same instance, declared correctly, still records.
assert_true "after refusing, the SAME Path B instance declared as Path B records all seven events" \
  str_has_line "$PROBE_OUT" "REUSE${TAB}path-b-module${TAB}path-b-nim${TAB}ALLOWED${TAB}7"
assert_true "after refusing, the SAME Path A instance declared as Path A records all seven events" \
  str_has_line "$PROBE_OUT" "REUSE${TAB}path-a-module${TAB}path-a-pure-rust${TAB}ALLOWED${TAB}7"

# ---------------------------------------------------------------------------
# 4. ONE ENFORCEMENT SITE, AND IT IS THE FUNCTION THAT WAS EXPORTED AND CALLED BY NOTHING.
#    Counted over CODE, not text: a citation of the name in a comment is not a call.
# ---------------------------------------------------------------------------
HOST_CODE="$(python3 "$REPO_ROOT/verification/_strip_ts_comments.py" "$M41_HOST/src")" \
  || die "the comment stripper failed over $M41_HOST/src"
assert_true "the stripped host code still contains the definition, so the count below is not vacuous" \
  str_has_sub "$HOST_CODE" 'export function writerKindMatchesPath('
assert_eq "writerKindMatchesPath appears exactly twice in ct-host CODE: its definition and the one call in the CtWriter constructor" \
  "2" "$(printf '%s\n' "$HOST_CODE" | grep -c 'writerKindMatchesPath(' || true)"
assert_true "and that call is the constructor's refusal" \
  str_has_sub "$HOST_CODE" 'if (!writerKindMatchesPath(reportedKind, config.writerPath))'

# ---------------------------------------------------------------------------
# 5. THE MUTATION ARM: the comparison removed from a COPY of the host, the same probe re-run.
# ---------------------------------------------------------------------------
MUTANT="$M41_WORK/kind-mutant"
rm -rf "$MUTANT"
mkdir -p "$MUTANT"
cp -a "$M41_HOST/src" "$MUTANT/src"
cp -a "$M41_HOST/package.json" "$MUTANT/package.json"
REPLACED="$(python3 - "$MUTANT/src/writer.ts" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
needle = "if (!writerKindMatchesPath(reportedKind, config.writerPath))"
n = s.count(needle)
open(p, "w", encoding="utf-8").write(s.replace(needle, "if (false)"))
print(n)
PY
)"
assert_eq "the mutation found the comparison exactly once, so the arm below mutates what it claims to" \
  "1" "$REPLACED"
MUT_OUT_FILE="$M41_WORK/kind-mutant.out"
run_probe "$MUTANT" "$MUT_OUT_FILE"
MUT_OUT="$(cat "$MUT_OUT_FILE")"
if str_has_line_re "$MUT_OUT" "^REFUSED${TAB}"; then
  fail "THE MUTATION ARM PASSED: with the comparison removed a crossed pair was STILL refused, so
     something other than the comparison produces the refusal and §3 does not assert it"
else
  pass "with the comparison removed, NOTHING is refused — the refusal in §3 is the comparison's"
fi
assert_true "and the mutant records Path B's module under the Path A label: the defect, reproduced" \
  str_has_line "$MUT_OUT" "ALLOWED${TAB}path-b-module${TAB}path-a-pure-rust${TAB}7${TAB}2${TAB}path-a-pure-rust"
assert_true "and Path A's module under the Path B label" \
  str_has_line "$MUT_OUT" "ALLOWED${TAB}path-a-module${TAB}path-b-nim${TAB}7${TAB}1${TAB}path-b-nim"

finish
