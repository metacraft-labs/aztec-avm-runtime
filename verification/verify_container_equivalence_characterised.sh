#!/usr/bin/env bash
# verify_container_equivalence_characterised
#
# M41 verification: the same input through both writers, compared stream by stream, with EVERY
# difference named and explained rather than excluded.
#
# THE DELIVERABLE IS NOT "THE CONTAINERS MATCH". The milestone says so explicitly — "characterised,
# NOT assumed byte-identical" — and the two writers are known in advance to differ on at least one
# stream. What is owed is an enumeration: which streams differ, and why each one does.
#
# SO THE CHECK IS A CATALOGUE, AND IT FAILS IN BOTH DIRECTIONS.
# `verification/_m41_container_diff.py` compares every comparable fact about the two containers and
# then:
#   * a difference with NO catalogued reason is a FAILURE — the direction a reviewer expects;
#   * a catalogued reason for a difference that is NO LONGER THERE is ALSO a failure — the
#     direction a catalogue rots in. A reason written for a difference that has since gone away
#     reads as current, and the next reader believes it.
#   * and NO differences at all is a failure too, because this milestone measured several: a
#     comparison that suddenly finds none is not reading what it thinks it is.
#
# THE KNOWN DIFFERENCE IS ASSERTED AS EXACTLY WHAT IT IS. The milestone names one in advance: "the
# Rust writer prefixes `events.log` with an 8-byte CodeTracer header the Nim writer omits". Measured
# here, it is LARGER than that: the Nim multi-stream writer writes no `events.log` at all, and the
# consequence is that `ct-print` sends the two containers down two different code paths in the same
# binary. The catalogue says so rather than repeating the smaller claim.
#
# BOTH CONTAINERS ARE READ BY THE READER THAT CAN READ THEM, and the asymmetry is itself catalogued:
# the pinned READER anchor reads Path A and not Path B, and the reader at the WRITER anchor reads
# Path B and refuses Path A. Comparing a complete decode against a broken one and calling the
# difference the writer's is the mistake this arrangement exists to avoid.
#
# Run: just verify-container-equivalence

TEST_NAME="verify_container_equivalence_characterised"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

TAB=$'\t'

m41_require_path_a
m41_require_path_b
m41_require_readers
# The two probes must be two BINARIES, or every "read by whichever can read it" below is one
# reader agreeing with itself. They coincide exactly when the reader anchor has caught up with the
# writer anchor, which is a real state and a legitimate one — but it is not one this comparison can
# run in, so it is named rather than absorbed.
assert_false "the two probes are different builds, so the comparison has two readers" \
  test "$M41_PROBE_OLD" = "$M41_PROBE_NEW"

m41_drive "$M41_PATH_A" path-a
m41_drive "$M41_PATH_B" path-b

# ---------------------------------------------------------------------------
# 1. Both containers, read by both readers, with the outcome of each recorded.
# ---------------------------------------------------------------------------
for arm in path-a path-b; do
  CT="$M41_WORK/$arm/container.ct"
  assert_file "the $arm arm produced a container" "$CT"
  # `reader`/`writer` in these file names are the OLDER and NEWER readers, resolved by role in
  # `m41_require_readers`. Which revision holds which role depends on where the reader anchor sits,
  # and that anchor moves; the roles do not.
  m41_probe "$M41_PROBE_OLD" "$CT" >"$M41_WORK/$arm/probe-reader.tsv"
  m41_probe "$M41_PROBE_NEW" "$CT" >"$M41_WORK/$arm/probe-writer.tsv"
  m41_bounded "$M41_READER_TIMEOUT" "the older ct-print over $arm" \
    "$M41_PRINT_OLD" --full "$CT" || true
  cp "$M41_LAST_LOG" "$M41_WORK/$arm/full-reader.json"
  m41_bounded "$M41_READER_TIMEOUT" "the newer ct-print over $arm" \
    "$M41_PRINT_NEW" --full "$CT" || true
  cp "$M41_LAST_LOG" "$M41_WORK/$arm/full-writer.json"
done

# The asymmetry, asserted before it is catalogued, so the catalogue is describing something this
# check has itself seen.
A_BY_READER="$(grep -c '^OPEN'$'\t''ok' "$M41_WORK/path-a/probe-reader.tsv" || true)"
B_BY_WRITER="$(grep -c '^OPEN'$'\t''ok' "$M41_WORK/path-b/probe-writer.tsv" || true)"
assert_eq "the reader anchor OPENS the Path A container" "1" "$A_BY_READER"
assert_eq "the writer anchor OPENS the Path B container" "1" "$B_BY_WRITER"
assert_true "and the writer anchor REFUSES the Path A container, naming the schema version" \
  grep -q 'schema version 3' "$M41_WORK/path-a/probe-writer.tsv"
assert_true "while the reader anchor reads Path B's streams only partially, and says which" \
  grep -q 'ERR:steps.dat' "$M41_WORK/path-b/probe-reader.tsv"

# ---------------------------------------------------------------------------
# 2. The comparison itself.
# ---------------------------------------------------------------------------
DIFF_OUT="$M41_WORK/container-diff.tsv"
DIFF_ERR="$M41_WORK/container-diff.err"
if python3 "$REPO_ROOT/verification/_m41_container_diff.py" "$M41_WORK" \
     >"$DIFF_OUT" 2>"$DIFF_ERR"; then
  pass "every difference between the two containers has a recorded reason"
else
  fail "the container comparison reported an unexplained or stale difference:
$(cat "$DIFF_ERR")"
fi

SAME="$(grep -c '^SAME' "$DIFF_OUT" || true)"
DIFFN="$(grep -c '^DIFF' "$DIFF_OUT" || true)"
WHY="$(grep -c '^WHY' "$DIFF_OUT" || true)"
m41_say "$SAME facts agree, $DIFFN differ, $WHY of the differing ones carry a reason"
assert_ge "the comparison compared a substantial number of facts, not a handful" 30 "$SAME"
assert_ge "and it FOUND differences, so it is not comparing something with itself" 1 "$DIFFN"
assert_eq "and every difference carries its reason" "$DIFFN" "$WHY"
assert_contains "the comparison's own verdict is ok" "VERDICT${TAB}ok" "$(cat "$DIFF_OUT")"

# ---------------------------------------------------------------------------
# 3. The differences the milestone named in advance, asserted individually.
# ---------------------------------------------------------------------------
# `$TAB` and not `\t`: `grep -E` is a POSIX ERE, in which `\t` matches a literal `t`. The pattern
# would then match nothing and every assertion below would go red over output that plainly
# contains the lines it is looking for. `lib_m24_ct_writer.sh` records the same trap.
assert_true "the events.log difference is catalogued as a stream, not as an 8-byte header" \
  grep -qE "^WHY${TAB}internal\.events_log${TAB}.*writes no .events\.log. at all" "$DIFF_OUT"
assert_true "the meta.dat schema version difference is catalogued" \
  grep -qE "^WHY${TAB}meta\.schema_version${TAB}" "$DIFF_OUT"
assert_true "and the two readers' asymmetry is catalogued rather than worked around" \
  grep -qE "^WHY${TAB}reads\.reader_anchor${TAB}" "$DIFF_OUT"
assert_true "and the events.log row says which container carries one" \
  grep -qE "^DIFF${TAB}internal\.events_log${TAB}present" "$DIFF_OUT"

# ---------------------------------------------------------------------------
# 4. The facts that must AGREE, asserted by name. A catalogue of differences says nothing about
#    what stayed the same, and "the two writers recorded the same trace" is the claim that matters.
# ---------------------------------------------------------------------------
for key in report.eventsWritten report.sourceStepsWritten report.stepsPositioned \
           report.stepsUnpositioned report.pathCount report.rungCount report.logEvents \
           report.callsOpened report.callDepth report.positionsPending \
           report.columnsRequested report.droppedColumnAwareness report.rungViolations \
           header.magic header.encryption meta.program meta.workdir \
           probe.PATH_COUNT probe.PATH0 probe.VARNAME_COUNT probe.COLUMN_AWARE \
           probe.STEPLAST_GLI probe.IOEVENT_COUNT probe.CALL0_ENTRY_STEP probe.CALL0_DEPTH; do
  assert_true "the two containers AGREE on $key" \
    grep -qE "^SAME${TAB}${key}${TAB}" "$DIFF_OUT"
done

# ---------------------------------------------------------------------------
# 5. THE CATALOGUE'S OWN MUTATION ARM. A catalogue that has never rejected anything has never been
#    shown to be able to.
# ---------------------------------------------------------------------------
MUTANT="$M41_WORK/mutant"
rm -rf "$MUTANT"
mkdir -p "$MUTANT/path-a" "$MUTANT/path-b"
for arm in path-a path-b; do
  cp -a "$M41_WORK/$arm/." "$MUTANT/$arm/"
done
# One fabricated difference, on a key nothing catalogues: the driver's own record size. It is
# something both containers genuinely agree on, so making them disagree is a difference the
# comparison MUST reject rather than absorb.
python3 - "$MUTANT/path-b/report.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p, encoding="utf-8"))
d["recordSize"] = 999
json.dump(d, open(p, "w", encoding="utf-8"))
PY
MUT_ERR="$M41_WORK/mutant.err"
if python3 "$REPO_ROOT/verification/_m41_container_diff.py" "$MUTANT" >/dev/null 2>"$MUT_ERR"; then
  fail "THE MUTATION ARM PASSED: an uncatalogued difference in report.recordSize was accepted,
     so the catalogue cannot reject anything and every green above is unearned"
else
  pass "an uncatalogued difference is REJECTED, so the catalogue discriminates"
fi
assert_true "and the rejection names the key it could not explain" \
  grep -q 'UNCATALOGUED.*report.recordSize' "$MUT_ERR"

# The second mutation arm, in the STALE direction: remove a real difference and the catalogue's
# entry for it must be reported as explaining nothing.
STALE="$M41_WORK/stale"
rm -rf "$STALE"
mkdir -p "$STALE/path-a" "$STALE/path-b"
for arm in path-a path-b; do
  cp -a "$M41_WORK/$arm/." "$STALE/$arm/"
done
python3 - "$STALE/path-b/report.json" "$STALE/path-a/report.json" <<'PY'
import json, sys
b = json.load(open(sys.argv[1], encoding="utf-8"))
a = json.load(open(sys.argv[2], encoding="utf-8"))
# Make the two agree on a key the catalogue explains a difference for.
b["writerKind"] = a["writerKind"]
b["containerBytes"] = a["containerBytes"]
json.dump(b, open(sys.argv[1], "w", encoding="utf-8"))
PY
STALE_ERR="$M41_WORK/stale.err"
if python3 "$REPO_ROOT/verification/_m41_container_diff.py" "$STALE" >/dev/null 2>"$STALE_ERR"; then
  fail "THE STALE ARM PASSED: a catalogue entry for a difference that is no longer there was
     accepted, so the catalogue can rot into a set of wrong statements without going red"
else
  pass "a catalogue entry that explains nothing is REJECTED, so the catalogue cannot rot silently"
fi
assert_true "and the rejection names the entry that went stale" \
  grep -q 'STALE.*report.writerKind' "$STALE_ERR"

finish
