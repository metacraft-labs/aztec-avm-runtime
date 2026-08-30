#!/usr/bin/env bash
# verify_local_history_boundary_declared
#
# M36's third verification entry: **the docs AND the runtime both state that these queries serve a
# self-produced chain rather than a synced one, and the claim is ASSERTED rather than only written.**
#
# ===========================================================================================
# WHY THIS IS THREE CLAIMS AND NOT ONE
# ===========================================================================================
#
# The milestone's own wording is the interesting part: *"the docs and the runtime both state ... and
# the claim is asserted rather than only written."* A check that grepped a document for a sentence
# would satisfy the first half and nothing else, and this campaign has a rule for exactly that — a
# citation is the opposite of a dependency. So:
#
#   1. THE SENTENCE HAS ONE HOME. It is `LOCAL_HISTORY_BOUNDARY` in
#      `browser/src/wallet/local_history.ts`; `LOCAL-HISTORY.md` QUOTES it; and this check compares
#      the two as STRINGS. A sentence copied into a document, a refusal message and a check is three
#      things to keep in step — `CAMPAIGN-BRIEF.md`'s "a correction filed in a neighbouring file is
#      not a correction", whose worst case is the copy inside a thrown message, because that is the
#      one with a user.
#   2. THE BUILT BUNDLE CARRIES IT. Read out of `browser/dist/wallet.js`'s own bytes and out of the
#      module graph, not out of the source — because the source is not what a page loads.
#   3. THE RUNTIME PRODUCES THE REFUSAL. `LocalHistoryOnly` is raised, in Chromium, over a query
#      past the produced history, and the message carries the sentence. **A boundary nothing
#      enforces is a paragraph**, and the arm's own control is what turns this from a grep into a
#      measurement.
#
# AND THE FOURTH, WHICH IS THE ONE A DOCUMENT ALONE CANNOT MAKE: the refusal is asked of a query
# that COULD have been answered — the same tag, one block lower, returns a log. An absence measured
# over a needle nobody emits is this campaign's most-repeated defect, and a boundary check is exactly
# where it would hide.
#
# Run: just verify-m36-boundary

TEST_NAME="verify_local_history_boundary_declared"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m36_notes.sh"

m36_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

echo "== 1. THE SENTENCE HAS ONE HOME, AND THE MODULE IS IT"

[ -s "$M36_BOUNDARY_SRC" ] || die "there is no $M36_BOUNDARY_SRC"
[ -s "$M36_DOC" ] || die "there is no $M36_DOC"

# READ OUT OF THE SOURCE BY PARSING THE DECLARATION, not by grepping for the words — a grep for the
# words would be satisfied by the comment that explains them.
SENTENCE="$(python3 - "$M36_BOUNDARY_SRC" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"export const LOCAL_HISTORY_BOUNDARY\s*=\s*(.*?);\n", src, re.S)
if not m:
    print("UNPARSEABLE"); raise SystemExit(0)
parts = re.findall(r"'((?:[^'\\]|\\.)*)'", m.group(1))
print("".join(p.replace("\\'", "'") for p in parts) if parts else "UNPARSEABLE")
PY
)"
assert_true "the boundary constant parses out of its own declaration" test "$SENTENCE" != "UNPARSEABLE"
assert_ge "and it is a sentence rather than a word" 80 "${#SENTENCE}"
assert_true "it names what the chain IS" str_has_sub "$SENTENCE" "PRODUCED"
assert_true "and what it is NOT" str_has_sub "$SENTENCE" "SYNCED"
assert_true "and what is missing that a synced chain would need" str_has_sub "$SENTENCE" "archiver"

echo "== 2. THE DOCUMENT QUOTES THAT EXACT STRING"

DOC_TEXT="$(cat "$M36_DOC")"
# THE DOCUMENT WRAPS AT 100 COLUMNS AND THE CONSTANT DOES NOT, so the comparison is over the
# document with its line breaks and blockquote markers collapsed. Matching a SENTENCE against a
# wrapped file is the needle-that-spans-a-line-break family; collapsing first is the remedy, and the
# collapse itself is asserted to have left text behind.
COLLAPSED="$(printf '%s' "$DOC_TEXT" | python3 -c '
import re, sys
text = sys.stdin.read()
text = re.sub(r"\n>\s*", " ", text)
text = re.sub(r"\s+", " ", text)
sys.stdout.write(text)')"
assert_ge "the collapsed document is not empty" 2000 "${#COLLAPSED}"
assert_true "LOCAL-HISTORY.md quotes the module's sentence verbatim" \
  str_has_sub "$COLLAPSED" "$SENTENCE"
# THE CONTROL, AND IT IS A NEAR MISS RATHER THAN A LONGER STRING. A control that appends to the
# sentence constrains the matcher only against a string that is longer than anything in the file; a
# control that changes ONE WORD INSIDE it is the case that actually distinguishes "the document
# quotes the constant" from "the document says something like it". `PRODUCED` -> `SYNCED` is the one
# substitution that inverts the sentence's meaning, so a document carrying the inverted claim fails
# here — and it runs through `str_has_sub`, the same function the assertion above uses, rather than
# beside it.
NEAR_MISS="${SENTENCE//PRODUCED, not a chain it SYNCED/SYNCED, not a chain it PRODUCED}"
assert_true "the near-miss control is a DIFFERENT string from the sentence" \
  test "$NEAR_MISS" != "$SENTENCE"
assert_false "and the document does NOT carry the inverted claim" \
  str_has_sub "$COLLAPSED" "$NEAR_MISS"

echo "== 3. THE BUILT BUNDLE CARRIES IT — READ OUT OF THE ARTEFACT, NOT THE SOURCE"

m27_require_bundle
WALLET_BYTES="$(cat "$BROWSER_DIST"/wallet.js "$BROWSER_DIST"/chunks/*.js 2>/dev/null)"
assert_ge "the wallet bundle's bytes were read" 100000 "${#WALLET_BYTES}"
assert_true "the built bundle carries the boundary sentence" str_has_sub "$WALLET_BYTES" "$SENTENCE"
assert_true "and the refusal class that carries it" str_has_sub "$WALLET_BYTES" "LocalHistoryOnly"
# THE PAIRED POSITIVE CONTROL FOR THE SCANNER ITSELF. M33's review's finding: a needle asked of a
# MINIFIED bundle can stop matching for reasons that have nothing to do with the subject, and the
# only thing that notices is a needle known to be there.
assert_true "the scanner can find a string this bundle certainly has" \
  str_has_sub "$WALLET_BYTES" "OracleUnimplemented"

echo "== 4. THE RUNTIME PRODUCES THE REFUSAL, IN CHROMIUM"

m36_require_arms
B_REFUSAL="$(m36_arm discovery.report.controls.boundaryRefusal)"
BOUNDARY_IN_REPORT="$(m36_arm discovery.report.boundary)"
MYLOGS="$(m36_arm discovery.report.tags.myLogs)"
m36_absent "controls.boundaryRefusal=$B_REFUSAL" "report.boundary=$BOUNDARY_IN_REPORT" \
  "tags.myLogs=$MYLOGS"

assert_true "a query past the produced history was refused rather than answered" \
  test "$B_REFUSAL" != "null"
assert_true "the refusal NAMES itself" str_has_sub "$B_REFUSAL" "LocalHistoryOnly"
assert_true "and CARRIES the sentence, so the copy with a user says the same thing" \
  str_has_sub "$B_REFUSAL" "$SENTENCE"
assert_true "and says what the block source actually holds instead" \
  str_has_sub "$B_REFUSAL" "this wallet's block source holds"
assert_true "and points at the milestone that would close it" \
  str_has_sub "$B_REFUSAL" "archiver client"
assert_eq "the page's own report carries the same sentence" "$SENTENCE" "$BOUNDARY_IN_REPORT"

echo "== 5. THE REFUSAL IS OVER A QUERY THAT COULD HAVE BEEN ANSWERED"

# WITHOUT THIS, §4 IS AN ABSENCE MEASURED OVER A NEEDLE NOBODY EMITS. The refused query is the SAME
# tag that, inside the produced range, returns a log — so `LocalHistoryOnly` is a fact about the
# RANGE and not about the tag being unknown.
assert_eq "the same tag returns a log inside the produced range" "1" "$MYLOGS"
assert_true "and the refusal was raised for the RANGE, naming the bound it exceeded" \
  str_has_sub "$B_REFUSAL" "blocks up to"

echo "== 6. THE DOCUMENT SAYS WHAT THE BOUNDARY MEANS, NOT ONLY THAT THERE IS ONE"

for needle in \
  "there is no client" \
  "unexercised here" \
  "nothing about sync" \
  "separate L0/L1 live-chain-replay track" \
  ; do
  assert_true "LOCAL-HISTORY.md states: $needle" str_has_sub "$COLLAPSED" "$needle"
done
# AND THE RUNTIME'S OWN MODULE SAYS THE SAME FOUR THINGS, because a document nobody opens and a
# module everybody reads are two audiences and the milestone names both.
MODULE_TEXT="$(cat "$M36_BOUNDARY_SRC")"
for needle in \
  "NO REORGS" \
  "NO FOREIGN LOGS" \
  "NO ARCHIVER CLIENT" \
  "separate L0/L1" \
  ; do
  assert_true "local_history.ts states: $needle" str_has_sub "$MODULE_TEXT" "$needle"
done

echo "== 7. AND THE NOTE DATABASE REFUSES RATHER THAN ANSWERING EMPTY, IN ITS OWN SOURCE"

[ -s "$M36_NOTEDB_SRC" ] || die "there is no $M36_NOTEDB_SRC"
NOTEDB="$(cat "$M36_NOTEDB_SRC")"
assert_true "the note database raises the refusal rather than importing a message" \
  str_has_sub "$NOTEDB" "throw new LocalHistoryOnly"
# STRIPPED OF COMMENTS, so a paragraph explaining the refusal cannot stand in for the refusal.
# `dev_keys.ts`'s own header caused exactly this failure one milestone ago: the prose that says a
# file uses no random source contains every spelling of one.
# `_import_closure.py`'s own string-aware stripper, imported rather than re-written: its NAIVE
# predecessor let a `//` inside a string literal eat the rest of a line and made a reached package
# look unreached, which is why this campaign has exactly one of these.
CODE_ONLY="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
from _import_closure import strip_comments
sys.stdout.write(strip_comments(open(sys.argv[2], encoding="utf-8").read()))' "$VERIFY_DIR" "$M36_NOTEDB_SRC" 2>/dev/null || true)"
# A PRECONDITION AND NOT A SKIP, AND THE ORIGINAL SHAPE IS THIS CAMPAIGN'S MOST-REPEATED DEFECT.
#
# This was `else note "the comment stripper is unavailable; …"`. Measured by M36's review, by moving
# `verification/_import_closure.py` aside and running the check: it reports
# **31 assertions, 0 failures, PASS** — a silent three-assertion shrink with NO failure attributable
# to it, which is *"a missing check reads as a smaller milestone, not as a red one"* exactly, and the
# three it loses are §7's strongest (that the refusal is in stripped CODE and that the stripper
# removed the prose). `note` is indented, so no summary line ever mentions it.
#
# `_import_closure.py` is a file in this repository, not an environment condition, so its absence is
# a DEFECT and the right response is to refuse. `die` runs under `m36_summary_on_abnormal_exit`, so
# the milestone reads RED rather than SMALLER. The green-path count is unchanged at 34.
[ -n "$CODE_ONLY" ] || die "the comment stripper (verification/_import_closure.py, strip_comments)
             produced nothing over $M36_NOTEDB_SRC. Section 7's stripped-source assertions cannot run,
             and skipping them silently would report a smaller milestone rather than a red one.
             Remedy: restore verification/_import_closure.py."
assert_ge "the comment stripper left code behind" 2000 "${#CODE_ONLY}"
assert_true "and the refusal is in the CODE rather than in the prose" \
  str_has_sub "$CODE_ONLY" "LocalHistoryOnly"
assert_false "while the prose that explains it is gone" \
  str_has_sub "$CODE_ONLY" "chain we produced, not a chain we synced"

m36_finish
