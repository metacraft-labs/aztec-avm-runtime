#!/usr/bin/env bash
# verify_fallback_triggers_recorded_and_evaluated — M16.
#
# M16 is executed if and only if one of three narrowed triggers fires. None of them does, and this
# check exists so that "none of them does" is EVIDENCED rather than asserted.
#
# The thing being defended against is a document that reads like an evaluation. Three headings,
# three confident "not triggered" verdicts, and nothing underneath any of them would look exactly
# like a real evaluation to a reader and would be worth nothing. So:
#
#   * Each of M16's three triggers is a CONJUNCTION, and each conjunct is evaluated on its own,
#     with its own verdict, its own evidence and its own reason. A trigger judged as a whole is
#     refused, because that is how a conjunction gets dismissed on its weakest limb while the
#     others are never looked at.
#   * THE SEVEN CONJUNCT TEXTS ARE THE MILESTONE'S OWN, matched verbatim against
#     Aztec-AVM-Runtime.milestones.org. The milestone is the authority for what the triggers say;
#     FALLBACK.md is the derived copy, and a drift between them fails here rather than passing
#     quietly. A fabricated eighth conjunct is searched for too, so the search is known to be
#     capable of returning nothing.
#   * EVERY PIECE OF EVIDENCE RESOLVES: `<path> :: <needle>`, the file must exist and the needle
#     must occur in it. The evidence lives in BOUNDARY-SHAPE.md, WORLD-STATE.md and
#     carry/series.json — documents whose own milestones' checks re-derive their numbers on every
#     run — so this check binds the evaluation to them instead of restating their figures.
#   * A NEGATIVE CASE PER CONJUNCT. Each of the seven is individually shown to be load-bearing:
#     its evidence needle is fabricated in a scratch copy and the parser must reject that copy,
#     naming that conjunct. A conjunct whose corruption changes nothing was never evidence.
#   * AND BOTH DIRECTIONS OF THE CONJUNCTION RULE, per trigger: all-conjuncts-true with
#     `not-fired` must be rejected, and `fired` with a conjunct that is not true must be rejected.
#   * EVERY FIGURE M16 QUOTES FROM ANOTHER MILESTONE IS ASSERTED ON BOTH SIDES. M16 re-measures
#     nothing about the boundary or the carry; it binds to BOUNDARY-SHAPE.md and WORLD-STATE.md,
#     which their own milestones' checks re-derive. A one-sided assertion would pass on a document
#     that had drifted, and an agreement between two absences would pass on nothing at all — so the
#     comparator returns one of four states and is exercised against a needle known to be in each.
#
# It also checks the one claim the milestone makes about what is NOT a trigger: doubt about the
# trees' correctness, closed by M7 and M8. Those two milestones are required to be `completed` in
# the milestone file, so the claim is checkable rather than decorative.
#
# Run: just verify-fallback-triggers

TEST_NAME="verify_fallback_triggers_recorded_and_evaluated"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m16_fallback.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
[ -f "$M16_DOC" ] || die "FALLBACK.md does not exist at $M16_DOC"
[ -f "$M16_PARSER" ] || die "the trigger parser is missing at $M16_PARSER"

MILESTONES="$WORKSPACE_ROOT/codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org"
[ -f "$MILESTONES" ] || die "the milestone file is not at $MILESTONES"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
echo "== 1. the trigger block parses, and every claim in it resolves"
# ---------------------------------------------------------------------------
REPORT="$SCRATCH/report.txt"
python3 "$M16_PARSER" "$REPO_ROOT" >"$REPORT" 2>&1 || die "the trigger parser failed to run"

PROBLEMS="$(sed -n 's/^PROBLEM //p' "$REPORT")"
if [ -z "$PROBLEMS" ]; then
  pass "every trigger has conjuncts, verdicts, resolving evidence and a reason"
else
  while IFS= read -r p; do
    [ -n "$p" ] && fail "$p"
  done <<EOF
$PROBLEMS
EOF
fi

k() { sed -n "s/^OK $1=//p" "$REPORT" | head -n1; }

assert_eq "M16 states three triggers and all three are evaluated" "3" "$(k triggers.total)"
assert_eq "the three conjunctions decompose into seven conjuncts" "7" "$(k conjuncts.total)"
assert_eq "trigger 1 is a two-part conjunction"   "2" "$(k trigger.1.conjuncts)"
assert_eq "trigger 2 is a three-part conjunction" "3" "$(k trigger.2.conjuncts)"
assert_eq "trigger 3 is a two-part conjunction"   "2" "$(k trigger.3.conjuncts)"

# ---------------------------------------------------------------------------
echo "== 2. the verdicts, and the vocabulary actually being exercised"
# ---------------------------------------------------------------------------
for n in 1 2 3; do
  assert_eq "trigger $n did not fire" "not-fired" "$(k "trigger.$n.conjunction")"
done
assert_eq "the milestone's outcome is not-required" "not-required" "$(k outcome)"

# A wall of `false` would satisfy every rule above and would mean the conjuncts were never really
# looked at. The evaluation is required to contain at least one conjunct that is TRUE and at least
# one that is UNRESOLVED — which is what the evidence actually says: M14 DID find block-level
# coverage insufficient, and upstream has not declined anything because nothing was submitted.
ALL_VERDICTS="$(sed -n 's/^OK trigger\.[0-9]\.verdict\.[0-9]=//p' "$REPORT" | sort | uniq -c | tr -s ' ' | tr '\n' ';')"
note "verdicts across the seven conjuncts: $ALL_VERDICTS"
assert_contains "at least one conjunct is measured TRUE, so 'not triggered' is not a wall of no" \
  "true" "$(sed -n 's/^OK trigger\.[0-9]\.verdict\.[0-9]=//p' "$REPORT" | sort -u | tr '\n' ' ')"
assert_contains "at least one conjunct is UNRESOLVED rather than conveniently false" \
  "unresolved" "$(sed -n 's/^OK trigger\.[0-9]\.verdict\.[0-9]=//p' "$REPORT" | sort -u | tr '\n' ' ')"
assert_eq "trigger 2's first conjunct — block-level coverage WAS insufficient — is recorded as true" \
  "true" "$(k trigger.2.verdict.1)"
assert_eq "trigger 2's second conjunct is unresolved: an unsubmitted patch has not been declined" \
  "unresolved" "$(k trigger.2.verdict.2)"
assert_eq "trigger 2's third conjunct — the carry is affordable — is measured false" \
  "false" "$(k trigger.2.verdict.3)"

# ---------------------------------------------------------------------------
echo "== 3. the seven conjunct texts are the MILESTONE's, verbatim"
# ---------------------------------------------------------------------------
# Needles are taken from FALLBACK.md itself and searched in the milestone, so the direction of the
# check is "the document does not invent triggers" rather than "the document restates a list we
# typed here twice".
CONJUNCTS="$SCRATCH/conjuncts.txt"
sed -n 's/^- conjunct: //p' "$M16_DOC" >"$CONJUNCTS"
assert_eq "seven conjunct texts were extracted from FALLBACK.md" "7" "$(wc -l <"$CONJUNCTS")"

while IFS= read -r c; do
  [ -n "$c" ] || continue
  if grep -qF -- "$c" "$MILESTONES"; then
    pass "the milestone states this conjunct verbatim  [${c:0:64}…]"
  else
    fail "FALLBACK.md evaluates a conjunct the milestone does not state  [$c]"
  fi
done <"$CONJUNCTS"

# The search must be capable of returning nothing. Without this, a grep that matched everything
# would have passed all seven above.
if grep -qF -- "the fallback is required because the trees are doubtful" "$MILESTONES"; then
  fail "the negative control found a fabricated conjunct in the milestone file"
else
  pass "a fabricated conjunct is NOT found in the milestone file, so the search can return nothing"
fi

# ---------------------------------------------------------------------------
echo "== 4. what is explicitly NOT a trigger, and the two milestones that close it"
# ---------------------------------------------------------------------------
assert_eq "the not-a-trigger record names M7 and M8" "M7,M8" "$(k not_a_trigger.closed_by)"
m16_assert_doc_records "that doubt about the trees is not a trigger" \
  "Doubt about the trees' correctness is explicitly not a trigger"

# M7 and M8 are only a defence if they are green. Read out of the milestone file rather than
# assumed: each milestone's :status: is the line following its own heading's :PROPERTIES:.
for m in M7 M8; do
  ST="$(awk -v want="^\\\\*\\\\* $m:" '
    $0 ~ want { inm=1; next }
    inm && /^\*\* M/ { inm=0 }
    inm && /^ *:status:/ { gsub(/^ *:status: */, ""); print; exit }
  ' "$MILESTONES")"
  assert_eq "$m — which closes the correctness question — is completed" "completed" "$ST"
done

# The awk above must be capable of reporting something other than `completed`, or the two
# assertions are decorative. M11 is partially_completed at the same anchor and is read the same way.
ST11="$(awk -v want="^\\\\*\\\\* M11:" '
  $0 ~ want { inm=1; next }
  inm && /^\*\* M/ { inm=0 }
  inm && /^ *:status:/ { gsub(/^ *:status: */, ""); print; exit }
' "$MILESTONES")"
assert_eq "the status reader returns something OTHER than completed where that is the truth (M11)" \
  "partially_completed" "$ST11"

# ---------------------------------------------------------------------------
echo "== 5. a negative case per conjunct: each one is individually load-bearing"
# ---------------------------------------------------------------------------
# For each of the seven conjuncts in turn, its evidence needle is replaced with a fabricated one in
# a scratch copy of the whole repo's FALLBACK.md, and the parser must reject THAT COPY. A conjunct
# whose corruption changes nothing was never evidence, and a conjunction with six real limbs and
# one decorative one is exactly the failure this whole check exists for.
mut_dir() { # <n> -> a repo-shaped scratch dir with a mutated FALLBACK.md
  local d="$SCRATCH/mut$1"
  mkdir -p "$d"
  # The parser resolves evidence paths relative to the root it is given, so the real documents are
  # linked in rather than copied: the mutation must be the only difference.
  for f in BOUNDARY-SHAPE.md WORLD-STATE.md; do ln -sf "$REPO_ROOT/$f" "$d/$f"; done
  mkdir -p "$d/carry"; ln -sf "$REPO_ROOT/carry/series.json" "$d/carry/series.json"
  printf '%s' "$d"
}

EVIDENCE_LINES="$(grep -n '^- evidence: ' "$M16_DOC" | wc -l)"
assert_eq "seven evidence lines were found to corrupt, one per conjunct" "7" "$EVIDENCE_LINES"

i=0
while [ "$i" -lt 7 ]; do
  i=$((i + 1))
  d="$(mut_dir "$i")"
  # Replace the i-th `- evidence:` line with one whose needle cannot occur anywhere.
  awk -v n="$i" '
    /^- evidence: / { c++; if (c == n) { print "- evidence: BOUNDARY-SHAPE.md :: this sentence appears in no document in this repository at all"; next } }
    { print }
  ' "$M16_DOC" >"$d/FALLBACK.md"
  if cmp -s "$d/FALLBACK.md" "$M16_DOC"; then
    fail "conjunct $i: the mutation changed nothing, so the control is vacuous"
    continue
  fi
  OUT="$(python3 "$M16_PARSER" "$d" 2>&1)"
  if str_has_line_re "$OUT" '^PROBLEM .*evidence needle is absent'; then
    pass "conjunct $i: fabricating its evidence is REJECTED, so that conjunct is load-bearing"
  else
    fail "conjunct $i: fabricating its evidence was ACCEPTED — that conjunct's evidence is decorative"
  fi
done

# ---------------------------------------------------------------------------
echo "== 6. the conjunction rule, in BOTH directions, per trigger"
# ---------------------------------------------------------------------------
# Direction A: every conjunct of a trigger set to `true` while the conjunction still reads
# `not-fired`. That is the shape in which a real trigger gets talked out of firing, and it must be
# refused.
for t in 1 2 3; do
  d="$(mut_dir "a$t")"
  python3 - "$M16_DOC" "$t" >"$d/FALLBACK.md" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines(True)
want = int(sys.argv[2])
cur = None
for ln in lines:
    m = re.match(r"^- trigger: (\d)", ln)
    if m:
        cur = int(m.group(1))
    if cur == want and ln.startswith("- verdict: "):
        ln = "- verdict: true\n"
    sys.stdout.write(ln)
PY
  if cmp -s "$d/FALLBACK.md" "$M16_DOC"; then
    fail "trigger $t, direction A: the mutation changed nothing"
    continue
  fi
  OUT="$(python3 "$M16_PARSER" "$d" 2>&1)"
  if str_has_line_re "$OUT" "^PROBLEM trigger $t records every conjunct as true"; then
    pass "trigger $t: all-conjuncts-true with 'not-fired' is REJECTED"
  else
    fail "trigger $t: all-conjuncts-true with 'not-fired' was ACCEPTED"
  fi
done

# Direction B: the conjunction marked `fired` while the conjuncts are as they really are. A
# document that fires a trigger it has not established must be refused just as hard, or the rule is
# only ever enforced in the direction that suits this milestone's answer.
for t in 1 2 3; do
  d="$(mut_dir "b$t")"
  python3 - "$M16_DOC" "$t" >"$d/FALLBACK.md" <<'PY'
import re, sys
lines = open(sys.argv[1], encoding="utf-8").read().splitlines(True)
want = int(sys.argv[2])
cur = None
for ln in lines:
    m = re.match(r"^- trigger: (\d)", ln)
    if m:
        cur = int(m.group(1))
    if cur == want and ln.startswith("- conjunction: "):
        ln = "- conjunction: fired\n"
    sys.stdout.write(ln)
PY
  if cmp -s "$d/FALLBACK.md" "$M16_DOC"; then
    fail "trigger $t, direction B: the mutation changed nothing"
    continue
  fi
  OUT="$(python3 "$M16_PARSER" "$d" 2>&1)"
  if str_has_line_re "$OUT" "^PROBLEM trigger $t records the conjunction as fired"; then
    pass "trigger $t: 'fired' on conjuncts that are not all true is REJECTED"
  else
    fail "trigger $t: 'fired' on conjuncts that are not all true was ACCEPTED"
  fi
done

# ---------------------------------------------------------------------------
echo "== 7. the rest of the parser's rules, each shown to reject something"
# ---------------------------------------------------------------------------
neg() { # <description> <python-mutation-on-stdin-name> <expected PROBLEM substring>
  local desc="$1" script="$2" expect="$3" d out
  d="$(mut_dir "n$(printf '%s' "$desc" | cksum | cut -d' ' -f1)")"
  python3 -c "$script" "$M16_DOC" >"$d/FALLBACK.md"
  if cmp -s "$d/FALLBACK.md" "$M16_DOC"; then
    fail "$desc — the mutation changed nothing, so the control is vacuous"
    return
  fi
  out="$(python3 "$M16_PARSER" "$d" 2>&1)"
  if str_has_sub "$out" "$expect"; then
    pass "$desc — rejected"
  else
    fail "$desc — ACCEPTED; the parser is too weak. Got: $(printf '%s' "$out" | grep '^PROBLEM' | head -3 | tr '\n' ' ')"
  fi
}

neg "a trigger deleted entirely" \
  'import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(re.sub(r"### T-3 —.*?(?=### Not a trigger)", "", t, flags=re.S))' \
  "trigger 3 is missing"

neg "a verdict outside the vocabulary" \
  'import sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(t.replace("- verdict: unresolved", "- verdict: probably-fine", 1))' \
  "outside the vocabulary"

neg "an evidence file that does not exist" \
  'import sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(t.replace("- evidence: WORLD-STATE.md ::", "- evidence: NO-SUCH-DOCUMENT.md ::", 1))' \
  "which does not exist"

neg "an evidence needle short enough to resolve against anything" \
  'import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(re.sub(r"^- evidence: BOUNDARY-SHAPE\.md :: .*$", "- evidence: BOUNDARY-SHAPE.md :: the", t, count=1, flags=re.M))' \
  "resolves against anything"

neg "a conjunct with no reason under it" \
  'import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(re.sub(r"^- reason: .*$", "- reason: no.", t, count=1, flags=re.M))' \
  "too short to be an evaluation"

neg "a conjunct stripped down to a single limb" \
  'import re,sys
t=open(sys.argv[1],encoding="utf-8").read()
m=re.search(r"(### T-1 —.*?)(?=### T-2)", t, re.S)
sec=m.group(1)
# drop the SECOND conjunct and its three following lines, leaving trigger 1 with one limb
lines=sec.splitlines(True); out=[]; seen=0; skip=0
for ln in lines:
    if skip: skip-=1; continue
    if ln.startswith("- conjunct: "):
        seen+=1
        if seen==2: skip=3; continue
    out.append(ln)
sys.stdout.write(t.replace(sec,"".join(out),1))' \
  "must be evaluated conjunct by conjunct"

# ---------------------------------------------------------------------------
# THE T-2b DEFECT, REPRODUCED AND CLOSED.
#
# T-2b's needle used to be `carry/series.json :: "status": "prepared"`, resolved as a plain
# SUBSTRING. Its reason says "All five entries in carry/series.json read status prepared" — a claim
# about all five — and a substring needle is satisfied by one. That mattered rather than being
# pedantry: `verify_accepted_patches_dropped_from_carry` mutates the tracked manifest to
# `"status": "accepted"` with a `https://example.invalid/1` URL as a negative control, and when
# M11's run aborted between the mutation and the restore the file was LEFT that way. T-2b kept
# passing against it.
#
# The needle now carries a multiplicity — `:: x5 ::` — and the three assertions below are the two
# directions plus the syntax itself, because a needle that quietly lost its `x5` would be back to
# the substring match with nothing to say so.
assert_contains "T-2b's evidence is multiplicity-bearing, so one entry cannot stand for five" \
  'carry/series.json :: x5 :: ' "$(cat "$M16_DOC")"

t2b_dir() { # <name> <status-for-entry-0> -> a repo-shaped dir whose carry manifest is a real FILE
  local d="$SCRATCH/t2b$1"
  mkdir -p "$d/carry"
  for f in BOUNDARY-SHAPE.md WORLD-STATE.md; do ln -sf "$REPO_ROOT/$f" "$d/$f"; done
  cp "$M16_DOC" "$d/FALLBACK.md"
  python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[3] != "prepared":
    d["patches"][0]["ledger"].update(status=sys.argv[3], url="https://example.invalid/1")
open(sys.argv[2], "w").write(json.dumps(d, indent=2, ensure_ascii=False) + "\n")' \
    "$REPO_ROOT/carry/series.json" "$d/carry/series.json" "$2"
  printf '%s' "$d"
}

T2B_CORRUPT="$(t2b_dir corrupt accepted)"
T2B_CLEAN="$(t2b_dir clean prepared)"
if cmp -s "$T2B_CORRUPT/carry/series.json" "$T2B_CLEAN/carry/series.json"; then
  fail "the T-2b corruption changed nothing, so both controls below are vacuous"
else
  OUT="$(python3 "$M16_PARSER" "$T2B_CORRUPT" 2>&1)"
  assert_contains "a manifest an aborted run left with one entry 'accepted' no longer satisfies T-2b" \
    "the evidence needle occurs 4 time(s)" "$OUT"
  OUT="$(python3 "$M16_PARSER" "$T2B_CLEAN" 2>&1)"
  if str_has_line_re "$OUT" '^PROBLEM'; then
    fail "the clean control ALSO fails, so the corrupt one proves nothing: $(printf '%s' "$OUT" | grep '^PROBLEM' | head -1)"
  else
    pass "…and the same directory with an uncorrupted manifest resolves, so that is a discrimination"
  fi
fi

neg "an evidence multiplicity that the file does not satisfy" \
  'import sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(t.replace("carry/series.json :: x5 ::", "carry/series.json :: x4 ::", 1))' \
  "the evidence requires exactly 4"

neg "the outcome claiming not-required while a trigger fired" \
  'import sys
t=open(sys.argv[1],encoding="utf-8").read()
t=t.replace("- verdict: false","- verdict: true").replace("- verdict: unresolved","- verdict: true")
t=t.replace("- conjunction: not-fired","- conjunction: fired")
sys.stdout.write(t)' \
  "a conjunction fired and the outcome is"

neg "the not-a-trigger record naming the wrong milestones" \
  'import sys
t=open(sys.argv[1],encoding="utf-8").read()
sys.stdout.write(t.replace("- closed-by: M7 M8", "- closed-by: M14 M15", 1))' \
  "must name M7 and M8"

# ---------------------------------------------------------------------------
echo "== 8. the prose a reader depends on, held to the block"
# ---------------------------------------------------------------------------
m16_assert_doc_records "the verdict in one word" "**NOT REQUIRED.** No trigger fired."
m16_assert_doc_records "that the analysis is retained anyway" "The analysis is retained anyway"
m16_assert_doc_records "which of M15's supporting claims review refuted" \
  "The verdict survived and the evidence changed."
m16_assert_doc_records "that no fifth-tree claim is made at the two large populations" \
  "At 1,000 and 10,000 leaves no claim is made and none is asserted."
m16_assert_doc_records "where the checkpoint measurement's resolution limit sits" \
  "The resolution limit sits between 100 and 1,000"
m16_assert_doc_records "that trigger 2 would still not fire if the unresolved conjunct resolved against us" \
  "it would still not fire, because T-2's third conjunct is measured false today"

# ---------------------------------------------------------------------------
echo "== 9. every figure M16 quotes from another milestone is present in that milestone's document"
# ---------------------------------------------------------------------------
# M16 measures nothing about the boundary or the carry itself: it BINDS to BOUNDARY-SHAPE.md and
# WORLD-STATE.md, whose own checks (`just verify-m15`, `just verify-m14`) re-derive every number in
# them on every run. That binding is only worth anything if the figures agree, so each is asserted
# present on BOTH sides. A one-sided assertion here would pass on a document that had drifted.
in_file() { # <path> <needle>
  python3 - "$1" "$2" <<'PY'
import re, sys
body = re.sub(r"\s+", " ", open(sys.argv[1], encoding="utf-8", errors="replace").read())
sys.exit(0 if re.sub(r"\s+", " ", sys.argv[2]) in body else 1)
PY
}

# bound_mode: which of the four states a (needle, source-document) pair is in. Returned as a word
# rather than folded into pass/fail, so the comparator itself can be exercised below against
# needles whose state is known — including the two one-sided states, which is the whole reason a
# figure is asserted on both sides rather than only in the document that quotes it.
bound_mode() { # <source-document> <needle> -> both | neither | doc-only | src-only
  local in_doc=0 in_src=0
  in_file "$M16_DOC" "$2" && in_doc=1
  in_file "$REPO_ROOT/$1" "$2" && in_src=1
  if   [ "$in_doc" -eq 1 ] && [ "$in_src" -eq 1 ]; then printf 'both'
  elif [ "$in_doc" -eq 0 ] && [ "$in_src" -eq 0 ]; then printf 'neither'
  elif [ "$in_doc" -eq 1 ];                        then printf 'doc-only'
  else                                                  printf 'src-only'
  fi
}

bound() { # <description> <source-document> <needle>
  local desc="$1" src="$2" needle="$3" mode
  mode="$(bound_mode "$src" "$needle")"
  case "$mode" in
    both)     pass "$desc — present in FALLBACK.md and in $src  [$needle]" ;;
    neither)  fail "$desc — present in NEITHER FALLBACK.md nor $src; the agreement is vacuous  [$needle]" ;;
    doc-only) fail "$desc — in FALLBACK.md but NOT in $src, so M16 has drifted from it  [$needle]" ;;
    src-only) fail "$desc — in $src but NOT in FALLBACK.md  [$needle]" ;;
  esac
}

bound "the crossing count"                    BOUNDARY-SHAPE.md "eighteen to twenty-two"
bound "the boundary's share of the work"      BOUNDARY-SHAPE.md "a part in ten thousand"
bound "burn's step-record count"              BOUNDARY-SHAPE.md "38,903 records for"
bound "the top checkpoint decade"             BOUNDARY-SHAPE.md "4133 us at 10,000 leaves against 352 us at 1,000"
bound "the decade below it"                   BOUNDARY-SHAPE.md "352 us against 57 us at 100"
bound "the same growth in the four-tree arm"  BOUNDARY-SHAPE.md "12.8x"
bound "…and its lower decade"                 BOUNDARY-SHAPE.md "7.4x"
bound "the fifth tree where it is resolvable" BOUNDARY-SHAPE.md "+6 us at population 0"
bound "the pair at 1,000 leaves"              BOUNDARY-SHAPE.md "383 us against 352 us at 1,000"
bound "what a block's checkpoints cost"       BOUNDARY-SHAPE.md "0.4 ms at 1,000 leaves and about 6 ms at 10,000"
bound "the carry's size"                      WORLD-STATE.md    "352 insertions and 10 deletions across three files"
bound "patch 5's hunk positions"              WORLD-STATE.md    "at lines 105, 128 and 149"
bound "M14's hunk positions"                  WORLD-STATE.md    "6, 42, 199, 207, 217, 241 and 252"

# The comparator must be able to report each of its FOUR states, or every green row above says
# nothing about which side it actually looked at. One needle per state, each chosen so its state is
# known independently of the comparator.
assert_eq "the comparator reports 'neither' for a figure in no document" \
  "neither" "$(bound_mode BOUNDARY-SHAPE.md "this figure appears in neither document and never has")"
assert_eq "the comparator reports 'src-only' for a sentence only BOUNDARY-SHAPE.md has" \
  "src-only" "$(bound_mode BOUNDARY-SHAPE.md "Kept so the decision can be revisited without redoing the work")"
assert_eq "the comparator reports 'doc-only' for a sentence only FALLBACK.md has" \
  "doc-only" "$(bound_mode BOUNDARY-SHAPE.md "The analysis is retained anyway")"
assert_eq "the comparator reports 'both' for a sentence both have" \
  "both" "$(bound_mode BOUNDARY-SHAPE.md "a part in ten thousand")"

finish
