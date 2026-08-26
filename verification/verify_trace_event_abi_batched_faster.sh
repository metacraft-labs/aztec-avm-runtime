#!/usr/bin/env bash
# verify_trace_event_abi_batched_faster
#
# ---------------------------------------------------------------------------
# THIS CHECK'S NAME IS OLDER THAN ITS MEASUREMENT, AND THE MEASUREMENT WON.
#
# The name comes from the M24 verification entry, which was written before OQ-6 was run and which
# assumed the answer: "The batched ABI outperforms per-event crossings on the 100k-event benchmark
# by a margin large enough to justify the encoder."
#
# **THE DIFFERENCE DOES NOT HAVE A STABLE SIGN.** Three runs of this benchmark — one in the system
# engine, two in this repository's dev shell — gave `perEvent - batched` = +0.20%, +1.09% and
# -0.58%. All three are inside the 3% margin the entry's own wording set, and the last two are the
# SAME engine, the same module and the same binary, with 95% intervals that do not overlap and
# point opposite ways. So the batched ABI is not measurably faster in any durable sense, and the
# decision rests on §4's secondary criterion: the number is what removed speed from the argument
# rather than what settled it.
#
# The name is kept because it is the DECLARED name and renaming a verification entry mid-milestone
# is how a status file and a check set drift apart. What the check asserts is what was actually
# established, and the milestone entry says so in those words:
#
#   1. OQ-6 was measured to this campaign's standard — interleaved arms, sessions as the unit of
#      replication, a negative control that reports no difference, min AND median, and a bound on
#      every arm run so a hang is a failure rather than a silence.
#   2. The RECORDED verdict in `TRACE-ABI.md` equals the MEASURED verdict, number for number.
#   3. The shipped ABI follows the recorded decision, in the code rather than in the prose.
#   4. The rejected arm is still there and still exercised.
#
# A check that asserted "batched is faster" would now be a check that fails on a correct
# implementation, and a check that quietly asserted nothing would be worse. This one asserts that
# the decision and the number agree — in either direction.
#
# THE DOCUMENT IS COMPARED AGAINST THE DATA, NOT READ. `CARRY-LEDGER.md` drifted from its own
# measurement because a number was rendered out of a sentence; here every figure quoted in
# `TRACE-ABI.md` §2 is re-derived from `arms.tsv` on every run and compared.
#
# Run: just verify-oq6
# ---------------------------------------------------------------------------

TEST_NAME="verify_trace_event_abi_batched_faster"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m24_ct_writer.sh"
m24_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v node >/dev/null 2>&1 || die "node is required"

DOC="$REPO_ROOT/TRACE-ABI.md"
assert_file "the verdict is recorded in a document" "$DOC"
DOCTEXT="$(cat "$DOC")"

# ---------------------------------------------------------------------------
# TWO VIEWS OF THE DOCUMENT, AND THE SECOND IS THE CURE FOR A RECURRING DEFECT.
#
# `$DOCTEXT` is the file. `$DOCFLAT` is the file with every run of whitespace collapsed to one
# space, and PROSE needles are matched against it.
#
# Three of M23's document assertions matched a SENTENCE against a file that wraps at 100 columns
# and therefore matched nothing — a red for a reason with nothing to do with the subject, and a
# needle that will be deleted rather than fixed the day somebody reflows a paragraph. M24 met the
# same thing FOUR more times while the document was being rewritten. Shortening each needle until
# it fits on one line is the fix that keeps having to be re-applied; flattening the haystack once
# is the fix that does not, and it costs one `tr`.
#
# TABLE ROWS AND ANCHORED PATTERNS STILL USE `$DOCTEXT`, because a row is a line and flattening
# would destroy exactly the structure they are asserting.
# ---------------------------------------------------------------------------
DOCFLAT="$(printf '%s' "$DOCTEXT" | tr -s '[:space:]' ' ')"
assert_ge "the flattened view of the document is not empty" "2000" "${#DOCFLAT}"
assert_true "and flattening did not destroy the document's own title" \
  str_has_sub "$DOCFLAT" "# The trace event ABI"

m24_require_oq6
TSV="$M24_OQ6_TSV"
assert_file "the OQ-6 benchmark produced its table" "$TSV"

# A run that timed out or died leaves an explicit incident line. A HANG is the state a trap cannot
# reach, so the driver writes the incident and the comparator turns it into a FAIL row; here the
# table is asserted to carry none, before anything is derived from it.
assert_eq "no session timed out" "0" "$(grep -c '^#TIMEOUT' "$TSV" || true)"
assert_eq "and none failed" "0" "$(grep -c '^#FAILED' "$TSV" || true)"

# ---------------------------------------------------------------------------
# The comparator.
# ---------------------------------------------------------------------------
REPORT="$(m24_run_bounded 600 "the OQ-6 comparator" \
  python3 "$VERIFY_DIR/_oq6_compare.py" "$TSV" "$M24_OQ6_MARGIN")"
cmp_rc=$?
# Exit 0 = resolved, 4 = within-noise. BOTH are measurements; 3 is a precondition failure and 2 is
# a usage error, and neither is acceptable here.
assert_true "the comparator ran to a verdict (exit 0 or 4, not a precondition failure)" \
  test "$cmp_rc" = 0 -o "$cmp_rc" = 4
[ -n "$REPORT" ] || die "the comparator printed nothing at all — a report with no rows must never read as clean"

TAB=$'\t'
n_rows="$(printf '%s\n' "$REPORT" | grep -cE "^(PASS|FAIL)${TAB}" || true)"
assert_ge "the comparator emitted a substantial number of assertions of its own" "12" "$n_rows"
n_fail="$(printf '%s\n' "$REPORT" | grep -cE "^FAIL${TAB}" || true)"
if [ "$n_fail" -eq 0 ]; then
  pass "every one of the comparator's own $n_rows assertions passed"
else
  while IFS= read -r r; do
    [ -n "$r" ] && fail "comparator: $r"
  done <<EOF
$(printf '%s\n' "$REPORT" | grep -E "^FAIL${TAB}")
EOF
fi

num() { printf '%s\n' "$REPORT" | awk -F"$TAB" -v k="$1" '$1=="NUMBER" && $2==k {print $3}'; }

VERDICT="$(num verdict)"
assert_true "the comparator produced a verdict" \
  test "$VERDICT" = within-noise -o "$VERDICT" = batched-faster -o "$VERDICT" = per-event-faster
note "OQ-6 verdict: $VERDICT at a ${M24_OQ6_MARGIN}% margin"

# ---------------------------------------------------------------------------
# 1. THE MEASUREMENT MET THE STANDARD.
# ---------------------------------------------------------------------------
assert_ge "the measurement is at least eight independent sessions" "8" "$(num sessions)"
assert_eq "it drove the 100,000 events the milestone specifies" "100000" "$(num events)"
assert_ge "at a batch size large enough for the arms to differ in crossings" "256" "$(num batch)"
assert_eq "the batched arm crossed ceil(events / batch) times" \
  "$(python3 -c 'import sys,math; print(math.ceil(int(sys.argv[1])/int(sys.argv[2])))' "$(num events)" "$(num batch)")" \
  "$(num crossings.batched)"
assert_eq "and the per-event arm crossed once per event" "$(num events)" "$(num crossings.perEvent)"
assert_true "the engine is named, so the number is attributable" \
  str_has_re "$(num v8)" '^[0-9]+\.'
note "engine: node $(num node), V8 $(num v8)"

# THE ARMS ARE INTERLEAVED. Read from the table rather than from the driver's comment: within a
# session, the arm order must not be the same in every block.
INTERLEAVE="$(python3 - "$TSV" <<'PY'
import sys
from collections import defaultdict
seq = defaultdict(list)
for ln in open(sys.argv[1], encoding="utf-8"):
    p = ln.rstrip("\n").split("\t")
    if len(p) == 3 and p[2].isdigit():
        seq[p[0]].append(p[1])
sess = sorted(seq, key=lambda s: int(s) if s.isdigit() else s)
if not sess:
    print("PROBLEM\tno samples"); raise SystemExit(0)
first = seq[sess[0]]
arms = sorted(set(first))
n = len(arms)
blocks = [tuple(first[i:i + n]) for i in range(0, len(first) - n + 1, n)]
print("ARMS\t%d" % n)
print("BLOCKS\t%d" % len(blocks))
print("DISTINCTORDERS\t%d" % len(set(blocks)))
# Mean position of each arm across the session. An ABBA design equalises them.
pos = defaultdict(list)
for i, a in enumerate(first):
    pos[a].append(i % n)
spread = max(sum(v) / len(v) for v in pos.values()) - min(sum(v) / len(v) for v in pos.values())
print("POSITIONSPREAD\t%.3f" % spread)
PY
)"
assert_not_contains "the interleaving could be read out of the table" "PROBLEM" "$INTERLEAVE"
assert_eq "five arms were measured" "5" "$(printf '%s\n' "$INTERLEAVE" | sed -n "s/^ARMS${TAB}//p")"
assert_ge "over several blocks" "4" "$(printf '%s\n' "$INTERLEAVE" | sed -n "s/^BLOCKS${TAB}//p")"
assert_ge "the arm ORDER varies between blocks — the arms are interleaved, not run A-then-B" "2" \
  "$(printf '%s\n' "$INTERLEAVE" | sed -n "s/^DISTINCTORDERS${TAB}//p")"
assert_true "and every arm's mean position within a block is the same, which is what ABBA buys" \
  test "$(printf '%s\n' "$INTERLEAVE" | sed -n "s/^POSITIONSPREAD${TAB}//p")" = "0.000"

# THE NEGATIVE CONTROL. An instrument that has never reported "no difference" where there is none
# is not calibrated, and this campaign's timing comparator uses exactly this shape.
CTL_PCT="$(num control_vs_batched.median_pct)"
assert_true "the negative control — a byte-for-byte duplicate export — reports no difference" \
  test "$(python3 -c 'import sys; print(1 if abs(float(sys.argv[1])) <= float(sys.argv[2]) else 0)' "$CTL_PCT" "$M24_OQ6_MARGIN")" = 1
note "control - batched = ${CTL_PCT}%  CI $(num control_vs_batched.ci)"
assert_true "and the control's own interval is quoted rather than a point estimate alone" \
  str_has_re "$(num control_vs_batched.ci)" '^\[[+-][0-9.]+,[+-][0-9.]+\]$'

# MIN AND MEDIAN, BOTH.
for arm in batched perEvent control nopBatched nopPerEvent; do
  assert_ge "arm \`$arm\` reports a median" "1" "$(num "median_us.$arm")"
  assert_ge "arm \`$arm\` reports a minimum" "1" "$(num "min_us.$arm")"
  assert_true "and its minimum is not greater than its median" \
    test "$(num "min_us.$arm")" -le "$(num "median_us.$arm")"
done

# THE CROSSING, PRICED ALONE. This is the number that makes the null interpretable rather than
# merely reported: it says the arms cannot be told apart because the crossing is cheap, not
# because the instrument is blunt.
NOP_PCT="$(num nopPerEvent_vs_nopBatched.median_pct)"
assert_true "the crossing-only pair DOES separate, so the instrument can see a difference at all" \
  test "$(python3 -c 'import sys; print(1 if abs(float(sys.argv[1])) > float(sys.argv[2]) else 0)' "$NOP_PCT" "$M24_OQ6_MARGIN")" = 1
note "nopPerEvent - nopBatched = ${NOP_PCT}%  CI $(num nopPerEvent_vs_nopBatched.ci)"

# ---------------------------------------------------------------------------
# 2. THE DOCUMENT AGREES WITH THE DATA.
# ---------------------------------------------------------------------------
# Every figure `TRACE-ABI.md` quotes for the arms is re-derived here and matched against the file.
# Matched as a FRAGMENT OF ONE LINE, never as a sentence: the file wraps at 100 columns and a
# needle spanning a line break matches nothing the day somebody reflows a paragraph.
#
# AND THE NUMBER IS MATCHED IN ITS OWN ROW, NOT ANYWHERE IN THE FILE. The first spelling of this
# searched for `| <number> |`, which says the figure is in the document and says nothing about
# WHICH ARM it belongs to. Measured by M24's review: swapping `batched`'s and `perEvent`'s median
# and minimum between the two rows of §2 — so the document states that the per-event arm is the
# faster one when the data says the opposite — passed this check **91 assertions, 0 failures**.
# Every figure was still present, every figure was still re-derived, and the table said the
# reverse of the measurement. A value without its attribution is not a measurement.
for arm in batched perEvent control nopBatched nopPerEvent; do
  med="$(python3 -c 'print(f"{int(float(__import__("sys").argv[1])):,}")' "$(num "median_us.$arm")")"
  mn="$(python3 -c 'print(f"{int(float(__import__("sys").argv[1])):,}")' "$(num "min_us.$arm")")"
  cr="$(python3 -c 'print(f"{int(float(__import__("sys").argv[1])):,}")' "$(num "crossings.$arm")")"
  cb="$(python3 -c 'print(f"{int(float(__import__("sys").argv[1])):,}")' "$(num "containerBytes.$arm")")"
  assert_true "TRACE-ABI.md's \`$arm\` ROW carries \`$arm\`'s measured median ($med)" \
    str_has_sub "$DOCTEXT" "| \`$arm\` | $med |"
  # THE WHOLE ROW, so every cell of §2's arm table is re-derived and none of them can drift on its
  # own: median, minimum, crossings and container bytes, in that order, on the row that names the
  # arm they belong to.
  assert_true "and the WHOLE row is the measurement — min $mn, crossings $cr, container $cb" \
    str_has_sub "$DOCTEXT" "| \`$arm\` | $med | $mn | $cr | $cb |"
done
assert_true "TRACE-ABI.md quotes the measured perEvent-vs-batched median" \
  str_has_sub "$DOCTEXT" "$(num perEvent_vs_batched.median_pct) %"
assert_true "and its measured interval" \
  str_has_sub "$DOCTEXT" "[$(printf '%s' "$(num perEvent_vs_batched.ci)" | tr -d '[]' | cut -d, -f1), $(printf '%s' "$(num perEvent_vs_batched.ci)" | tr -d '[]' | cut -d, -f2)] %"
assert_true "and the control's measured median" \
  str_has_sub "$DOCTEXT" "$(num control_vs_batched.median_pct) %"
assert_true "and the crossing-only pair's measured median" \
  str_has_sub "$DOCTEXT" "$(num nopPerEvent_vs_nopBatched.median_pct) %"
assert_true "and the declared margin" str_has_sub "$DOCFLAT" "margin of ${M24_OQ6_MARGIN%.0} %"
assert_true "and the session count" str_has_sub "$DOCFLAT" "**$(num sessions) sessions"
assert_true "and the engine it was measured on" str_has_sub "$DOCFLAT" "V8 $(num v8)"
# A NEEDLE THAT IS SATISFIED BY PROSE IS NO NEEDLE. The verdict is asserted as the verdict word in
# the sentence that declares it, and the OTHER two verdict words must be absent as declarations.
assert_true "TRACE-ABI.md declares the verdict the comparator computed" \
  str_has_sub "$DOCTEXT" "**Verdict: \`$VERDICT\`.**"
for other in within-noise batched-faster per-event-faster; do
  [ "$other" = "$VERDICT" ] && continue
  assert_false "and does not also declare \`$other\`" \
    str_has_sub "$DOCTEXT" "**Verdict: \`$other\`.**"
done

# The correction to §9.3's stated expectation is recorded rather than left implicit.
assert_true "the document records that §9.3's ~33 ns prior was the comparison" \
  str_has_sub "$DOCFLAT" '33 ns prior'
# THE CLAIM CHANGED WHEN THE MEASUREMENT DID, AND SO DID THIS NEEDLE. §9.3 called per-event
# crossing "the obvious performance trap"; the first measurement (in the other engine) could not
# distinguish the arms at all and the document said the trap was "not one". The dev-shell
# measurement CAN distinguish them — +1.09%, interval excluding zero — so the document now says
# the trap is real and an order of magnitude smaller than the bar set for acting on it, and this
# needle follows it rather than the other way round.
assert_true "and states what the measurement did to §9.3's expectation, in its own words" \
  str_has_sub "$DOCFLAT" '"obvious performance trap" is, at this writer'"'"'s cost per event, **worth less than a tenth of a per cent**'
assert_true "and says what that leaves the per-event arm actually paying for" \
  str_has_sub "$DOCFLAT" 'dominated by host-side work'
# A FRAGMENT OF ONE LINE, NEVER A SENTENCE. An earlier spelling of the needle below spanned a line
# break and matched nothing, because the file wraps at 100 columns. Three of M23's document
# assertions died the same way; a needle that stops matching the day somebody reflows a paragraph
# gets deleted rather than fixed.
#
# WHAT IS ASSERTED HERE IS THE INSTABILITY, because that is what three runs established and it is
# the claim §4's decision rests on. A document that quoted one run's narrow interval as the
# precision of the quantity would be making exactly the error `_timing_compare.py`'s header
# records, and this check would not have caught it — so the SIGN INSTABILITY is pinned by name.
assert_true "the document records that the difference has no stable SIGN across runs" \
  str_has_sub "$DOCFLAT" 'THE MEASUREMENT DOES NOT HAVE A STABLE SIGN'
assert_true "and says the repeated runs were the same engine and the same binary" \
  str_has_sub "$DOCFLAT" 'the same engine, the same module and the same'
assert_true "and states the consequence: the difference is under the instrument's own spread" \
  str_has_sub "$DOCFLAT" 'the difference is smaller than the run-to-run'

# THE INSTABILITY IS COMPUTED FROM §8's TABLE, NOT MATCHED AS A SENTENCE.
#
# The first spelling of this pinned the three point estimates as one literal string, and a fourth
# run broke it — which is the right direction to fail, but it is also a needle that has to be
# rewritten every time the evidence GROWS. What matters is the property: the retained table holds
# several independent runs and their signs are NOT all the same. Both halves are read out of the
# table, so a document that quietly dropped the run that disagreed would fail here.
RETAINED="$(printf '%s\n' "$DOCTEXT" | grep -E '^\| [0-9]+ \| node v[0-9]')"
n_retained="$(printf '%s\n' "$RETAINED" | grep -c . || true)"
assert_ge "§8 retains at least three independent runs, so the claim is replicated" "3" "$n_retained"
signs="$(printf '%s\n' "$RETAINED" | sed -E 's/^\| [0-9]+ \| [^|]*\| \**([+-])[0-9.]+ %.*/\1/' | sort -u | tr -d '\n')"
assert_eq "and their signs are BOTH — the difference is not consistently in one direction" \
  "+-" "$signs"
assert_true "the run §2 tabulates is among the retained ones, at its measured value" \
  str_has_sub "$RETAINED" "**$(num perEvent_vs_batched.median_pct) %**"
assert_true "with the one §2 tabulates named, so a reader knows which is which" \
  str_has_sub "$DOCFLAT" 'is the one §2 tabulates'

# ---------------------------------------------------------------------------
# 3. THE SHIPPED ABI FOLLOWS THE RECORDED DECISION — IN THE CODE.
# ---------------------------------------------------------------------------
WRITER_SRC="$(cat "$M24_HOST/src/writer.ts")"
assert_true "the host's DEFAULT ingest export is ct_ingest, which is what §4 decided" \
  str_has_sub "$WRITER_SRC" "this.ingestName = opts.ingestExport ?? 'ct_ingest';"
assert_true "the document names ct_ingest as the shipped ABI" \
  str_has_sub "$DOCFLAT" '**`ct_ingest` — the batched binary buffer — is the shipped ABI.**'
# The secondary criterion must be STATED, because "chosen on a secondary criterion" without one is
# an unfalsifiable claim.
assert_true "and states the secondary criterion the choice rests on" \
  str_has_sub "$DOCFLAT" 'linear in an engine constant this project has not measured'
assert_true "with what would reopen it" str_has_sub "$DOCFLAT" '### What would reopen this'

# ---------------------------------------------------------------------------
# 4. THE REJECTED ARM IS STILL THERE AND STILL EXERCISED.
# ---------------------------------------------------------------------------
m24_require_module
MODULE="$M24_MODULE"
EXPORTS="$(m24_require_bounded 120 "the export probe" node -e '
const b = require("node:fs").readFileSync(process.argv[1]);
for (const e of WebAssembly.Module.exports(new WebAssembly.Module(b))) console.log(e.name);
' "$MODULE")"
for e in ct_step ct_ingest ct_ingest_control ct_nop_step ct_nop_ingest; do
  assert_true "the shipped module still exports \`$e\`" str_has_line_re "$EXPORTS" "^$e\$"
done
assert_true "the host still offers the per-event path" \
  str_has_sub "$WRITER_SRC" 'writeStepPerCall(e: StepEvent): void'
# EXERCISED, not merely present: the equivalence arm drives it on every arms run.
m24_require_arms
ARMS_JSON="$M24_ARMS"
assert_file "the arms report exists" "$ARMS_JSON"
assert_eq "and the per-event path really ran, once per event" \
  "$(m24_arm 'd["equivalence"]["events"]')" "$(m24_arm 'd["equivalence"]["perEventCrossings"]')"
assert_eq "producing a container identical to the batched one" "true" \
  "$(m24_arm 'd["equivalence"]["identical"]')"

# ---------------------------------------------------------------------------
# 5. THE COMPARATOR IS A THING UNDER TEST TOO.
#
# It is the piece that decides the verdict, so a fabricated table with a real difference in it
# must produce the OTHER verdict. Without this, `within-noise` is indistinguishable from a
# comparator that only ever says `within-noise`.
# ---------------------------------------------------------------------------
FAKE="$M24_OQ6_WORK/fabricated-arms.tsv"
mkdir -p "$M24_OQ6_WORK" || die "could not create $M24_OQ6_WORK"
python3 - "$FAKE" <<'PY' || die "could not fabricate the control table"
import sys
# Twelve sessions, six samples per arm, with `perEvent` a flat 30% slower than `batched` and every
# other arm equal to it. A comparator that cannot see THIS cannot see anything.
rows = ["#CONFIG\tevents=100000\tbatch=4096\treps=6\tsessions=12\tnode=vfake\tv8=0.0.0"]
for s in range(1, 13):
    for r in range(6):
        base = 500000 + s * 137 + r * 11
        rows.append("%d\tbatched\t%d" % (s, base))
        rows.append("%d\tperEvent\t%d" % (s, int(base * 1.30)))
        rows.append("%d\tcontrol\t%d" % (s, base + 3))
        rows.append("%d\tnopBatched\t%d" % (s, 3800 + r))
        rows.append("%d\tnopPerEvent\t%d" % (s, 4400 + r))
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY
FAKE_REPORT="$(m24_run_bounded 600 "the comparator on a fabricated table" \
  python3 "$VERIFY_DIR/_oq6_compare.py" "$FAKE" "$M24_OQ6_MARGIN")"
fake_rc=$?
fake_verdict="$(printf '%s\n' "$FAKE_REPORT" | awk -F"$TAB" '$1=="NUMBER" && $2=="verdict" {print $3}')"
assert_eq "given a table with a REAL 30% difference, the comparator says batched-faster" \
  "batched-faster" "$fake_verdict"
assert_eq "and exits 0 rather than 4, so the two outcomes are distinguishable" "0" "$fake_rc"
assert_eq "while the real table's verdict is what the document records" "$VERDICT" "$(num verdict)"
assert_false "the fabricated run's failures, if any, are its own and not the real run's" \
  test "$FAKE" -ef "$TSV"

# The other direction: a fabricated table where `perEvent` is FASTER must not be reported as
# batched-faster. A one-sided comparator is this campaign's M9 defect, which passed by 0.05pp in
# the wrong direction for two milestones.
FAKE2="$M24_OQ6_WORK/fabricated-arms-reversed.tsv"
python3 - "$FAKE2" <<'PY' || die "could not fabricate the reversed table"
import sys
rows = ["#CONFIG\tevents=100000\tbatch=4096\treps=6\tsessions=12\tnode=vfake\tv8=0.0.0"]
for s in range(1, 13):
    for r in range(6):
        base = 500000 + s * 137 + r * 11
        rows.append("%d\tbatched\t%d" % (s, base))
        rows.append("%d\tperEvent\t%d" % (s, int(base * 0.70)))
        rows.append("%d\tcontrol\t%d" % (s, base + 3))
        rows.append("%d\tnopBatched\t%d" % (s, 3800 + r))
        rows.append("%d\tnopPerEvent\t%d" % (s, 4400 + r))
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY
FAKE2_REPORT="$(m24_run_bounded 600 "the comparator on the reversed table" \
  python3 "$VERIFY_DIR/_oq6_compare.py" "$FAKE2" "$M24_OQ6_MARGIN")"
assert_eq "and a table where per-event is faster is reported as per-event-faster, not as its opposite" \
  "per-event-faster" \
  "$(printf '%s\n' "$FAKE2_REPORT" | awk -F"$TAB" '$1=="NUMBER" && $2=="verdict" {print $3}')"

# A scattered CONTROL must be reported even when the arms resolve — the "a recorded FAIL outranks
# a precondition" rule, which this campaign's own comparator had wrong once.
FAKE3="$M24_OQ6_WORK/fabricated-arms-bad-control.tsv"
python3 - "$FAKE3" <<'PY' || die "could not fabricate the bad-control table"
import sys
rows = ["#CONFIG\tevents=100000\tbatch=4096\treps=6\tsessions=12\tnode=vfake\tv8=0.0.0"]
for s in range(1, 13):
    for r in range(6):
        base = 500000 + s * 137 + r * 11
        rows.append("%d\tbatched\t%d" % (s, base))
        rows.append("%d\tperEvent\t%d" % (s, int(base * 1.30)))
        rows.append("%d\tcontrol\t%d" % (s, int(base * 1.25)))   # the instrument moved
        rows.append("%d\tnopBatched\t%d" % (s, 3800 + r))
        rows.append("%d\tnopPerEvent\t%d" % (s, 4400 + r))
open(sys.argv[1], "w", encoding="utf-8").write("\n".join(rows) + "\n")
PY
FAKE3_REPORT="$(m24_run_bounded 600 "the comparator on a scattered control" \
  python3 "$VERIFY_DIR/_oq6_compare.py" "$FAKE3" "$M24_OQ6_MARGIN")"
assert_ge "a scattered CONTROL is reported as a failure even while the arms resolve" "1" \
  "$(printf '%s\n' "$FAKE3_REPORT" | grep -cE "^FAIL${TAB}.*negative control" || true)"
assert_eq "and the verdict is still computed and printed rather than swallowed" "batched-faster" \
  "$(printf '%s\n' "$FAKE3_REPORT" | awk -F"$TAB" '$1=="NUMBER" && $2=="verdict" {print $3}')"

# And a table too short to compare must be a PRECONDITION failure with rows, not a silent pass.
FAKE4="$M24_OQ6_WORK/fabricated-arms-too-short.tsv"
head -25 "$TSV" >"$FAKE4"
m24_run_bounded 600 "the comparator on a too-short table" \
  python3 "$VERIFY_DIR/_oq6_compare.py" "$FAKE4" "$M24_OQ6_MARGIN" >"$FAKE4.out" 2>&1
short_rc=$?
assert_eq "a table with too few sessions is exit 3, a precondition failure" "3" "$short_rc"
assert_ge "and it prints the reason rather than nothing" "1" \
  "$(grep -cE "^FAIL${TAB}enough complete sessions" "$FAKE4.out" || true)"

m24_finish
