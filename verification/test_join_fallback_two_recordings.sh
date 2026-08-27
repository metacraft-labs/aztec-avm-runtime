#!/usr/bin/env bash
# M26 verification: the fallback. Two recordings, with the join RECORDED rather than inferred.
#
#   verification/test_join_fallback_two_recordings.sh        (or: just verify-join-fallback)
#
# ---------------------------------------------------------------------------
# THE DELIVERABLE'S OWN WORDING IS "with the join recorded explicitly rather than inferred", AND
# THE WORD THAT MATTERS IS "RATHER THAN". A check that only asserted a record exists would be
# satisfied by a runtime that ALSO infers — writes the record, ignores it, and joins whatever two
# files it is handed. So this check asserts both halves:
#
#   RECORDED    the record is IN both containers, read back through the pinned reader, with the
#               same join identity, the two half labels, and a `halves` count.
#   NOT INFERRED  `joinRecordings` REFUSES on every ground a filename-based joiner would sail past
#               — a missing record, two identities, a miscount, a duplicate half, a mixed arm — and
#               each refusal is named rather than being one generic throw.
#
# THE ACCEPTANCE ARM IS WHY THE REFUSALS MEAN ANYTHING. Seven refusals are satisfied by a function
# that refuses everything, so the well-formed pair is joined in the same run and its ORDER — the
# private half first, because it is the outer one — is asserted.
#
# AND THE GRAMMAR IS PRODUCED IN TWO LANGUAGES, WHICH IS A HAZARD RATHER THAN A DETAIL. The Rust
# probe renders the record with a `format!` and `orchestration/src/trace_join.ts` renders it with a
# template literal. Two literals that match today diverge tomorrow, so the TypeScript rendering is
# compared BYTE FOR BYTE against what the Rust side actually wrote into the container — not against
# a copy of itself.
#
# THE FALLBACK'S PUBLIC HALF IS WRITTEN BY THE SHIPPED MODULE, and that is the whole reason
# `ct_log_event` exists. A fallback whose containers were both written by a probe would be a
# demonstration that a probe can produce one.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=test_join_fallback_two_recordings
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m26_join.sh"

m24_summary_on_abnormal_exit

m24_require_module
m24_require_readers
m26_require_arms

PRIV_CT="$M26_WORK/oq7-split.private.ct"
PUB_CT="$M26_WORK/oq7-split.public.ct"
SHARED_CT="$M26_WORK/oq7-shared.ct"

# ===========================================================================
# PART 1 — TWO recordings, and they really are two.
# ===========================================================================
assert_file "the fallback's private half exists" "$PRIV_CT"
assert_file "the fallback's public half exists" "$PUB_CT"
assert_false "…and they are not the same file" test "$PRIV_CT" = "$PUB_CT"
assert_false "…nor the same bytes" \
  cmp -s "$PRIV_CT" "$PUB_CT"

PRIV="$(m26_frames "$PRIV_CT")"
PUB="$(m26_frames "$PUB_CT")"
assert_false "the pinned reader reads the private half" str_has_sub "$PRIV" 'ERR:'
assert_false "…and the public half" str_has_sub "$PUB" 'ERR:'
assert_ge "the private half decoded steps" 1 "$(m26_row "$PRIV" STEPS)"
assert_ge "the public half decoded steps" 1 "$(m26_row "$PUB" STEPS)"
# EACH HALF HOLDS ITS OWN HALF AND NOT THE OTHER'S, which is what makes them two RECORDINGS rather
# than one recording written twice.
assert_true "the private half carries the Noir program's frames" \
  str_has_sub "$(m26_rows "$PRIV" FRAME 4)" 'main,foo,bar'
assert_false "…and NOT the contract's" \
  str_has_sub "$(m26_rows "$PRIV" FRAME 4)" 'Token.'
assert_true "the public half carries the contract's frames" \
  str_has_sub "$(m26_rows "$PUB" FRAME 4)" 'Token.'
assert_false "…and NOT the Noir program's" \
  str_has_sub "$(m26_rows "$PUB" FRAME 4)" ',main,'

# ===========================================================================
# PART 2 — RECORDED. The join record is in both containers, read back by the reader.
# ===========================================================================
JOIN_ID="$(m26_arm 'd["config"]["joinId"]')"
assert_ge "the arms declare a join identity" 8 "${#JOIN_ID}"
PRIV_REC="$(printf '%s\n' "$PRIV" | awk -F'\t' -v k="$M26_JOIN_METADATA" '$1=="EVENT" && $2==k {print $3; exit}')"
PUB_REC="$(printf '%s\n' "$PUB" | awk -F'\t' -v k="$M26_JOIN_METADATA" '$1=="EVENT" && $2==k {print $3; exit}')"
assert_ge "the private half carries a $M26_JOIN_METADATA record" 20 "${#PRIV_REC}"
assert_ge "the public half carries a $M26_JOIN_METADATA record" 20 "${#PUB_REC}"
assert_eq "the private half's record is the private half's" \
  "join=$JOIN_ID half=private halves=2 arm=split reason=recorded-by-the-producer-not-inferred-by-a-reader" \
  "$PRIV_REC"
assert_eq "the public half's record is the public half's" \
  "join=$JOIN_ID half=public halves=2 arm=split reason=recorded-by-the-producer-not-inferred-by-a-reader" \
  "$PUB_REC"
assert_false "…and the two records are not identical, so `half` really distinguishes them" \
  test "$PRIV_REC" = "$PUB_REC"
# THE PUBLIC HALF'S RECORD WAS WRITTEN BY THE SHIPPED MODULE, counted by the module itself.
assert_eq "the public half's record came from the shipped module's ct_log_event" "1" \
  "$(m26_arm 'd["split"]["public"]["logEvents"]')"
# The rung declaration sits beside it, so `ct_log_event` has not displaced `ct_declare_rung`.
PUB_RUNG="$(printf '%s\n' "$PUB" | awk -F'\t' '$1=="EVENT" && $2=="ct.mapping-rung" {print $3; exit}')"
assert_ge "…beside the contract's rung declaration, in the same container" 10 "${#PUB_RUNG}"
assert_true "…which names the contract the public half is about" \
  str_has_sub "$PUB_RUNG" "$(m26_arm 'd["tx"]["contractAddress"]')"
assert_true "…and the rung the source map resolved for it" \
  str_has_sub "$PUB_RUNG" "rung=$(m26_arm 'd["sourceMap"]["rung"]')"

# ===========================================================================
# PART 3 — THE GRAMMAR IS ONE GRAMMAR, IN TWO LANGUAGES.
#
# The TypeScript rendering is compared against what the RUST side wrote into the container. Both
# are produced in this run; neither is a copy of the other.
# ===========================================================================
TS_RENDERED="$(m26_arm 'd["join"]["rendered"]')"
assert_eq "the TypeScript renderer and the Rust probe produce the SAME bytes for the same record" \
  "$PRIV_REC" "$TS_RENDERED"
assert_ge "…and that rendering is not the empty string" 40 "${#TS_RENDERED}"
assert_eq "the metadata key is one key, and both sides use it" "$M26_JOIN_METADATA" \
  "$(m26_arm 'd["join"]["metadataKey"]')"
assert_eq "…and the reason clause is the constant, not free text" \
  "recorded-by-the-producer-not-inferred-by-a-reader" "$(m26_arm 'd["join"]["reason"]')"
assert_eq "the TypeScript parser is the renderer's inverse" "true" \
  "$(m26_arm 'd["join"]["reparsedMatches"]')"
# A PARSER THAT ACCEPTED ANYTHING WOULD SATISFY THE LINE ABOVE. Five malformed inputs, each
# rejected for a DIFFERENT missing or wrong field.
for bad in parseRejectsGarbage parseRejectsMissingField parseRejectsBadHalf parseRejectsBadArm \
           parseRejectsBadCount; do
  assert_eq "…and rejects $bad rather than filling in a default" "true" \
    "$(m26_arm "d[\"join\"][\"$bad\"]")"
done

# ===========================================================================
# PART 4 — NOT INFERRED. Every refusal, by name.
# ===========================================================================
assert_eq "a set with no records at all is refused as unrecorded" "unrecorded" \
  "$(m26_arm 'd["join"]["refusals"]["empty"]')"
assert_eq "a half whose container carries no record is refused as unrecorded" "unrecorded" \
  "$(m26_arm 'd["join"]["refusals"]["unrecorded"]')"
assert_eq "two halves declaring different joins are refused as identity-mismatch" "identity-mismatch" \
  "$(m26_arm 'd["join"]["refusals"]["identityMismatch"]')"
assert_eq "one half of a two-half join is refused as count-mismatch" "count-mismatch" \
  "$(m26_arm 'd["join"]["refusals"]["countMismatch"]')"
assert_eq "two halves declaring a THREE-half join are refused as count-mismatch" "count-mismatch" \
  "$(m26_arm 'd["join"]["refusals"]["declaredCountMismatch"]')"
assert_eq "two containers claiming the same half are refused as duplicate-half" "duplicate-half" \
  "$(m26_arm 'd["join"]["refusals"]["duplicateHalf"]')"
assert_eq "halves disagreeing about the arm are refused as arm-mismatch" "arm-mismatch" \
  "$(m26_arm 'd["join"]["refusals"]["armMismatch"]')"
# THE FIVE GROUNDS ARE FIVE, not one generic refusal wearing five names.
assert_eq "…and the seven refusals name five DISTINCT grounds" "5" \
  "$(printf '%s\n' \
      "$(m26_arm 'd["join"]["refusals"]["empty"]')" \
      "$(m26_arm 'd["join"]["refusals"]["identityMismatch"]')" \
      "$(m26_arm 'd["join"]["refusals"]["countMismatch"]')" \
      "$(m26_arm 'd["join"]["refusals"]["duplicateHalf"]')" \
      "$(m26_arm 'd["join"]["refusals"]["armMismatch"]')" | sort -u | grep -c . || true)"

# ===========================================================================
# PART 5 — THE ACCEPTANCE ARM, without which every refusal above is free.
# ===========================================================================
assert_eq "a well-formed two-half pair IS joined" "private,public" \
  "$(m26_arm 'd["join"]["acceptedOrder"]')"
assert_eq "…private first, because the private half is the outer one" "private" \
  "$(printf '%s\n' "$(m26_arm 'd["join"]["acceptedOrder"]')" | cut -d, -f1)"
# The `shared` arm's one-container recording is joined too, with `half=both`, so "no join record"
# never has to mean two different things.
assert_eq "…and a one-container shared recording is joined as a single half labelled both" "both" \
  "$(m26_arm 'd["join"]["sharedOrder"]')"
SHARED_REPORT="$(m26_frames "$SHARED_CT")"
SHARED_REC="$(printf '%s\n' "$SHARED_REPORT" | awk -F'\t' -v k="$M26_JOIN_METADATA" '$1=="EVENT" && $2==k {print $3; exit}')"
assert_eq "…and the shared container carries that record in its bytes" \
  "join=$JOIN_ID half=both halves=1 arm=shared reason=recorded-by-the-producer-not-inferred-by-a-reader" \
  "$SHARED_REC"

# ===========================================================================
# PART 6 — the two halves of the fallback carry THE SAME join, and the shared arm a different shape.
# ===========================================================================
assert_true "the private half names the join" str_has_sub "$PRIV_REC" "join=$JOIN_ID "
assert_true "the public half names the SAME join" str_has_sub "$PUB_REC" "join=$JOIN_ID "
assert_true "both declare a TWO-half join, so one alone is detectably incomplete" \
  str_has_sub "$PRIV_REC$PUB_REC" 'halves=2'
assert_false "…and neither declares the shared arm's one-half shape" \
  str_has_sub "$PRIV_REC$PUB_REC" 'halves=1'

# ===========================================================================
# PART 7 — the module and the host agree about the key, and the SOURCE agrees with both.
#
# Three literals in three languages. Compared against each other rather than each against a copy of
# itself, because that is the shape that drifts.
# ===========================================================================
RUST_LIB="$(cat "$REPO_ROOT/ct-writer/src/lib.rs" 2>/dev/null)"
TS_JOIN="$(cat "$REPO_ROOT/orchestration/src/trace_join.ts" 2>/dev/null)"
PROBE_RS="$(cat "$VERIFY_DIR/oq7_shared_writer_probe.rs" 2>/dev/null)"
assert_ge "the join module reads back" 100 "$(printf '%s\n' "$TS_JOIN" | grep -c . || true)"
assert_ge "the probe source reads back" 100 "$(printf '%s\n' "$PROBE_RS" | grep -c . || true)"
assert_true "the TypeScript side declares the key as a constant" \
  str_has_sub "$TS_JOIN" "export const JOIN_EVENT_METADATA = '$M26_JOIN_METADATA';"
# AND THE JOIN GRAMMAR IMPORTS NOTHING, which `JOIN-SHAPE.md` §7 states as a consequence for M27 and
# M28 — no npm package and no Node module, so a browser host gets the grammar unchanged. It was TRUE
# and unguarded until M26's review: a document stating a property nothing re-derives is this
# campaign's oldest form of rot, and this one is load-bearing for two milestones that have not
# started. The control is the file beside it, which imports plenty.
assert_eq "…and the join grammar imports NOTHING, which is what makes it a browser module" "0" \
  "$(printf '%s\n' "$TS_JOIN" | grep -cE '^[[:space:]]*(import|export[[:space:]]+.*[[:space:]]from)[[:space:]]' || true)"
assert_ge "…while the driver beside it does import, so that zero is a measurement" 1 \
  "$(grep -cE '^[[:space:]]*import[[:space:]]' "$REPO_ROOT/orchestration/src/join_e2e_driver.ts" || true)"
JOIN_DOC="$(tr '\n' ' ' < "$REPO_ROOT/JOIN-SHAPE.md" 2>/dev/null)"
assert_ge "JOIN-SHAPE.md reads back" 100 "${#JOIN_DOC}"
assert_true "…and JOIN-SHAPE.md states that consequence for the browser host" \
  str_has_sub "$JOIN_DOC" 'imports nothing'
assert_true "the Rust probe declares the same key as a constant" \
  str_has_sub "$PROBE_RS" "const JOIN_EVENT_METADATA: &str = \"$M26_JOIN_METADATA\";"
# The MODULE declares NO CONSTANT for the join key, and that is deliberate: `ct_log_event` is
# generic, so a third record kind needs no third export. Asserted over the module's CODE with its
# `#[cfg(test)]` block excluded — the native test naturally uses the string as an argument, and a
# whole-file needle would count that as a hardcoding, which is this campaign's "a citation counted
# as a call" in an absence assertion.
RUST_CODE="$(printf '%s\n' "$RUST_LIB" | sed -n '1,/^mod tests {$/p')"
assert_ge "the module's non-test code extracts" 500 "$(printf '%s\n' "$RUST_CODE" | grep -c . || true)"
assert_false "…and declares no constant for the join key, because ct_log_event is generic" \
  str_has_sub "$RUST_CODE" "\"$M26_JOIN_METADATA\""
assert_true "…while it DOES declare one for M25's rung key, so the absence above is a difference" \
  str_has_sub "$RUST_CODE" 'pub const CT_RUNG_EVENT_METADATA: &str = "ct.mapping-rung";'
# And the frame ABI the fallback's public half is written through is the SHIPPED module's.
assert_true "the module exports the frame ABI M26 added" \
  str_has_sub "$RUST_CODE" 'pub unsafe extern "C" fn ct_call('
assert_true "…and its closing half" str_has_sub "$RUST_CODE" 'pub extern "C" fn ct_return()'
assert_eq "…which the fallback's public half opened once per enqueued call" \
  "$(m26_arm 'd["tx"]["enqueuedPublicCalls"]')" "$(m26_arm 'd["split"]["public"]["callsOpened"]')"
assert_eq "…and closed every one of them" "0" \
  "$(m26_arm 'd["split"]["public"]["callDepthAtClose"]')"
assert_eq "…with the steps split between them rather than all in one" "6,6" \
  "$(m26_arm 'd["split"]["public"]["stepsPerFrame"]')"
PUB_FRAMES="$(printf '%s\n' "$PUB" | awk -F'\t' '$1=="FRAME" && $4 ~ /^Token\./ {printf "%s%s", sep, $4; sep=","} END {print ""}')"
assert_eq "…and the frames the READER sees are the ones the transaction enqueued, in order" \
  "$(m26_arm 'd["tx"]["enqueuedNames"]')" "$PUB_FRAMES"

# ===========================================================================
# PART 8 — `TxProvenance.privateTrace` CARRIES THE HANDLE THAT JOINS THEM.
#
# M21 declared the field and left its shape to M26; this is where the two meet. What is asserted is
# that the handle names the SAME join the containers carry — read out of the container's bytes on
# one side and off the provenance on the other — because a handle assembled beside a recording
# rather than derived from it is a second source of truth about which join this is.
#
# AND THE TWO CONTROLS ARE M21's OWN. M20's discriminant-only local constructor and an external
# transaction must carry NO handle, or "the field is there" would be a property of the type rather
# than of the path that produced it.
# ===========================================================================
assert_eq "the joined transaction's provenance is local" "local" \
  "$(m26_arm 'd["provenance"]["split"]["kind"]')"
assert_eq "…and carries a private-trace handle" "true" \
  "$(m26_arm 'd["provenance"]["split"]["hasTrace"]')"
assert_eq "…whose join is the identity the CONTAINERS carry" "$JOIN_ID" \
  "$(m26_arm 'd["provenance"]["split"]["join"]')"
assert_eq "…which is also M21's opaque id, so a consumer that knows only M21's type still works" \
  "$JOIN_ID" "$(m26_arm 'd["provenance"]["split"]["id"]')"
assert_eq "…and says how many halves that join has, so an incomplete one is detectable" "2" \
  "$(m26_arm 'd["provenance"]["split"]["halves"]')"
assert_eq "…and which arm produced it" "split" "$(m26_arm 'd["provenance"]["split"]["arm"]')"
# The shared arm's handle says ONE half, which is the same field doing the same work.
assert_eq "the shared arm's handle declares a one-half join" "1" \
  "$(m26_arm 'd["provenance"]["shared"]["halves"]')"
assert_eq "…and names the shared arm" "shared" "$(m26_arm 'd["provenance"]["shared"]["arm"]')"
# M21's summary is filled in from what was traced rather than from a placeholder.
assert_eq "the private-execution summary names the contract the transaction calls" \
  "$(m26_arm 'd["tx"]["contractAddress"]')" "$(m26_arm 'd["provenance"]["split"]["summaryContract"]')"
assert_eq "…and the number of enqueued public calls it produced" \
  "$(m26_arm 'd["tx"]["enqueuedPublicCalls"]')" \
  "$(m26_arm 'd["provenance"]["split"]["summaryPublicCalls"]')"
assert_eq "…and which simulator ran the private half" "noir-tracer" \
  "$(m26_arm 'd["provenance"]["split"]["summarySimulator"]')"
# THE TWO CONTROLS.
assert_eq "M20's discriminant-only local transaction carries NO handle" "false" \
  "$(m26_arm 'd["provenance"]["discriminantOnly"]["hasTrace"]')"
assert_eq "…and neither does an externally-settled one" "false" \
  "$(m26_arm 'd["provenance"]["external"]["hasTrace"]')"
assert_eq "…which is still recognisably external, so the control is about the handle" "external" \
  "$(m26_arm 'd["provenance"]["external"]["kind"]')"

m24_finish
