#!/usr/bin/env bash
# e2e_browser_downloads_ct_container_and_ct_print_parses
#
# M27's own words for this check: "the container downloaded from the demo page parses under
# `ct-print --full` — THE ONLY TEST THAT PROVES THE ACTUAL PRODUCT CLAIM".
#
# ===========================================================================================
# WHAT THE PRODUCT CLAIM IS, AND WHY EVERY LINK HAS TO BE ASSERTED SEPARATELY.
# ===========================================================================================
#
# The claim is: a person opens a page, executes an Aztec public transaction, and gets a CodeTracer
# recording they can step through at Aztec.nr source level. Four links, and a check that asserted
# only "ct-print exited 0" would pass over a container full of nothing.
#
#   1. THE BROWSER DOWNLOADED IT. Not "the page could have produced bytes" — the file is read off
#      DISK, from the directory `Browser.setDownloadBehavior` pointed the browser at, and its
#      sha256 is compared against the bytes the page held. Those are two independent readings of
#      the same object and they must agree.
#   2. IT IS A REAL RECORDING. Events, frames, interned paths, and steps that are POSITIONED.
#
#      **THIS CLAUSE CHANGED IN M29 AND THE REASON IS WORTH KEEPING.** It used to read "64 of 64,
#      with zero unpositioned, which is what rung 1 means" — and that was true BY CONSTRUCTION and
#      therefore said nothing: the 64 steps WERE the artifact's own first 64 mapped program
#      counters, so every one of them had a position because every one of them had been chosen for
#      having one. M29 replaced them with what the AVM executed, and an executed stream walks
#      through regions the artifact's `brillig_locations` does not key — `SOURCE-MAPPING.md` §2.4's
#      residual hole 2, compiled procedures appended after the main body. So the assertion is now
#      the INVARIANT (positioned + unpositioned accounts for every event, and the positioned count
#      is non-zero) plus the rule that ties the DECLARED rung to the coverage, which is a property
#      that can fail in both directions rather than one that cannot fail at all.
#   3. THE REFERENCE READER READS IT. `ct-print --full`, the pinned reader M24 builds, exit 0.
#   4. IT SAYS SOMETHING. The reader's output names real Aztec.nr source files from the Token
#      contract's own `file_map`, so the recording is at SOURCE level and not at pc level.
#
# THE READER IS THE ONE M24 PINS, built by `build_ct_print.sh` from a published commit, with the
# `.rev` stamp checked — "never depend on state you did not produce". This check reuses
# `lib_m24_ct_writer.sh` for it rather than finding a binary by name.
#
# AND THE READER'S VERDICT HAS A CONTROL. `ct-print` exiting 0 over a container is only evidence if
# ct-print can exit non-zero; `CAMPAIGN-BRIEF.md` records a probe that "read a reader-refused
# container green". So the same reader is run over a TRUNCATED copy of the same container and is
# required to refuse it.
#
# Run: just verify-browser-ct-container

TEST_NAME="e2e_browser_downloads_ct_container_and_ct_print_parses"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

m27_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m27_require_arms
m24_require_readers

echo "== 1. the BROWSER downloaded a container, and it is the one the page held"

N_FILES="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1]))["arms"]["download"]["downloaded"]))' "$M27_ARMS")"
assert_eq "exactly one .ct file reached the download directory" "1" "$N_FILES"

DL_PATH="$(m27_arm download downloaded.0.path)"
DL_BYTES="$(m27_arm download downloaded.0.bytes)"
DL_SHA="$(m27_arm download downloaded.0.sha256)"
DL_NAME="$(m27_arm download downloaded.0.name)"
IN_PAGE_BYTES="$(m27_arm download inPageBytes)"
IN_PAGE_SHA="$(m27_arm download inPageSha256)"
note "downloaded $DL_NAME — $DL_BYTES bytes, sha256 ${DL_SHA:0:16}…"

assert_file "the downloaded container is on disk" "$DL_PATH"
assert_eq "…and its size equals what the page held" "$IN_PAGE_BYTES" "$DL_BYTES"
assert_eq "…and its sha256 equals what the page held, to the byte" "$IN_PAGE_SHA" "$DL_SHA"
assert_ge "…and it is a substantial container rather than a stub" 50000 "$DL_BYTES"
# THE FILE ON DISK IS RE-HASHED HERE rather than trusted from the arm, so the two readings are
# genuinely independent: one was taken by the arm runner, this one by this check.
assert_eq "…re-hashed by this check, independently" "$DL_SHA" "$(sha256sum "$DL_PATH" | cut -d' ' -f1)"
assert_true "…and the filename carries the recording id" str_has_sub "$DL_NAME" "$(m27_arm download recording.recordingId)"

echo "== 2. it is a real recording: frames, paths, and POSITIONED steps"

EVENTS="$(m27_arm download recording.events)"
FRAMES="$(m27_arm download recording.callsOpened)"
PATHS="$(m27_arm download recording.pathsInterned)"
POS="$(m27_arm download recording.stepsPositioned)"
UNPOS="$(m27_arm download recording.stepsUnpositioned)"
RUNG="$(m27_arm download recording.rung)"
DECLARED="$(m27_arm download recording.declaredRung)"
KIND="$(m27_arm download recording.writerKind)"
note "$EVENTS event(s), $FRAMES frame(s), $PATHS path(s), $POS positioned / $UNPOS unpositioned, \
artifact rung $RUNG, declared rung $DECLARED"

assert_ge "the recording carries a real number of steps" 32 "$EVENTS"
# `callsOpened` IS NOW TWO SIGNALS AND THE ASSERTION SUBTRACTS ONE TO KEEP MEASURING THE OTHER.
#
# It used to be exactly the AVM context frames — one per enqueued call — because that was the only
# signal the recorder had. It now also counts a frame per NOIR FUNCTION entered, derived from the
# artifact's inline call-stack chains. Re-baselining this to the new total would silently stop
# asserting the thing it was written to assert, so the Noir frames are subtracted back out and the
# original claim survives unchanged: the AVM-context frames are one per enqueued call, still two.
NOIRF="$(m27_arm download recording.noirFramesOpened)"
# NAMED BEFORE IT IS USED IN ARITHMETIC. `m27_arm` answers `MISSING` for a field the recording does
# not carry, and `$((FRAMES - MISSING))` is a bash abort under `set -u` — which is a FAILURE, but an
# unreadable one. A recorder that stopped deriving Noir frames should say so in a sentence.
assert_true "the recording reports how many of its frames are Noir functions" \
  test "$NOIRF" != "MISSING"
[ "$NOIRF" != "MISSING" ] || NOIRF=0
note "…of which $NOIRF are Noir function frames, $((FRAMES - NOIRF)) AVM context frames"
assert_eq "…the AVM-context frames split across the transaction's two enqueued calls" \
  "2" "$((FRAMES - NOIRF))"
assert_ge "…and the Noir call tree is present rather than collapsed to the contexts" 1 "$NOIRF"
assert_ge "…referring to several source files" 2 "$PATHS"
assert_eq "…with positioned and unpositioned accounting for every event" "$EVENTS" "$((POS + UNPOS))"
assert_ge "…and a non-zero number of them at a resolved SOURCE position" 1 "$POS"
assert_eq "…the artifact itself earning rung 1, the source rung" "1" "$RUNG"
# THE DECLARED RUNG FOLLOWS THE COVERAGE, and the implication is asserted in the direction that can
# fail: rung 1 exactly when nothing was left unpositioned. A rung-1 declaration over an unpositioned
# step is what `CtWriter.close()` throws `MappingRungDegraded` on, so a producer that got this wrong
# would not have produced a container at all — which is the enforcement, and this is the reading.
assert_eq "…and the DECLARED rung is 1 exactly when every step of the contract was positioned" \
  "$([ "$UNPOS" -eq 0 ] && echo 1 || echo 2)" "$DECLARED"
# DD-7: which writer path produced this, read off the module rather than declared by the host.
assert_eq "…written by Path A, the pure-Rust writer, per ct_writer_kind()" "1" "$KIND"
assert_true "…and the rung verdict names the mechanism it rests on" \
  str_has_sub "$(m27_arm download recording.rungReason)" 'brillig_locations'
# M29: the declared rung's reason carries the SPLIT, not just the number. A rung with no reason is
# what M25's ladder exists to refuse, and "389 of 516" is a different fact from "rung 2".
assert_true "…and the declared rung's reason carries the positioned/unpositioned split" \
  str_has_sub "$(m27_arm download recording.declaredRungReason)" "$POS of $EVENTS executed step(s)"

echo "== 3. THE PRODUCT CLAIM: ct-print --full parses it"

READ="$(m24_ct_print "$M24_READERS/ct-print" "$DL_PATH")"
RC="$(printf '%s\n' "$READ" | head -1)"
OUT="$(printf '%s\n' "$READ" | tail -n +2)"
LINES="$(printf '%s\n' "$OUT" | grep -c .)"
note "ct-print --full exited $RC with $LINES line(s) of output"

assert_eq "ct-print --full exits 0 over the container the browser downloaded" "0" "$RC"
assert_ge "…producing a substantial rendering rather than a stub" 500 "$LINES"

echo "== 4. …and what it printed is an Aztec.nr recording, at SOURCE level"

assert_true "the reader read the metadata back" str_has_sub "$OUT" '"program": "aztec-avm"'
assert_true "…and the working directory" str_has_sub "$OUT" '"workdir": "/aztec"'
assert_true "…and the path table" str_has_sub "$OUT" '"paths"'
# THE SOURCE PATHS. These come from the Token artifact's own `file_map` — the reader is naming
# Aztec.nr files, which is what "steppable at Aztec.nr source level" means.
assert_true "…naming the AVM dispatch macro's source" str_has_sub "$OUT" 'macros/dispatch.nr'
assert_true "…and the AVM oracle's" str_has_sub "$OUT" 'oracle/avm.nr'
assert_true "…and a protocol-circuits serde source" str_has_sub "$OUT" 'crates/serde/src'
# Steps and frames survived the round trip.
assert_true "…and the reader emitted Step records" str_has_sub "$OUT" '"type": "Step"'
assert_true "…and Call records for the frames" str_has_sub "$OUT" '"type": "Call"'
STEP_COUNT="$(printf '%s\n' "$OUT" | grep -c '"type": "Step"')"
note "the reader emitted $STEP_COUNT Step record(s)"
assert_eq "…as many Step records as the writer wrote events" "$EVENTS" "$STEP_COUNT"

echo "== 5. THE CONTROL: the same reader REFUSES a container it cannot read"

CTL_DIR="$M27_WORK/ctprint-control"
rm -rf "$CTL_DIR"; mkdir -p "$CTL_DIR"

# HALVING THE FILE IS NOT ENOUGH, AND THAT WAS MEASURED RATHER THAN ASSUMED. A `.ct` container is a
# DIRECTORY of independent streams; `ct-print --full` over a copy whose second half is missing still
# exits 0, because the streams it did read are well formed. That is a fact about the format rather
# than a defect in the reader, and it is exactly the shape `CAMPAIGN-BRIEF.md` warns about: a
# control that does not control anything looks identical to one that does. The halved copy is kept
# and its exit status is REPORTED, because a reader who assumes truncation is refused should see
# the number.
#
# The controls that DO discriminate corrupt something every reader must parse: `meta.dat`'s
# `recording_id` is a UUID and the reader refuses a value that is not exactly 36 characters (M26
# measured that refusal by name), and a 512-byte stub is not a container at all.
HALVED="$CTL_DIR/halved.ct"
head -c "$((DL_BYTES / 2))" "$DL_PATH" > "$HALVED"
assert_eq "the halved copy is half the container" "$((DL_BYTES / 2))" "$(stat -c %s "$HALVED")"
HALVED_RC="$(m24_ct_print "$M24_READERS/ct-print" "$HALVED" | head -1)"
note "ct-print over a HALVED copy exits $HALVED_RC — recorded because it is not what one expects"

STUB="$CTL_DIR/stub.ct"
head -c 512 "$DL_PATH" > "$STUB"
STUB_RC="$(m24_ct_print "$M24_READERS/ct-print" "$STUB" | head -1)"
note "ct-print over a 512-byte stub exits $STUB_RC"
assert_false "the reader REFUSES a 512-byte stub" test "$STUB_RC" -eq 0

CORRUPT="$CTL_DIR/corrupt.ct"
RECID="$(m27_arm download recording.recordingId)"
python3 "$VERIFY_DIR/_m27_shorten_recording_id.py" "$DL_PATH" "$CORRUPT" "$RECID"
PATCH_RC=$?
assert_eq "the recording id was found in the container and shortened to 35 characters" "0" "$PATCH_RC"
CORRUPT_READ="$(m24_ct_print "$M24_READERS/ct-print" "$CORRUPT")"
CORRUPT_RC="$(printf '%s\n' "$CORRUPT_READ" | head -1)"
CORRUPT_OUT="$(printf '%s\n' "$CORRUPT_READ" | tail -n +2)"
note "ct-print over a container whose recording id is 35 characters exits $CORRUPT_RC"
assert_false "…and the reader REFUSES it, so exit 0 above is a verdict rather than a habit" \
  test "$CORRUPT_RC" -eq 0
# THE REASON IT GIVES IS `meta.dat present but corrupt`, and it is quoted rather than predicted.
# The expectation was `recording_id: expected 36 chars`, which is the refusal M26 measured when the
# id was made LONGER by editing the source. Shortening it inside a finished container moves the
# stream's own framing, so the reader stops at the magic bytes first and never gets as far as the
# field. Same stream, same refusal, earlier line — and the assertion says what happened rather than
# what was expected.
assert_true "…naming meta.dat as the stream it refused" \
  str_has_sub "$CORRUPT_OUT" 'meta.dat present but corrupt'

echo "== 6. the page that produced it fetched no proving stack"

# The product claim and DD-11 in one sentence: the container came out of a page that downloaded
# avm.wasm, the contract artifact and ct_writer.wasm, and nothing else large.
assert_eq "the recording page fetched ct_writer.wasm" '["/assets/ct_writer.wasm"]' \
  "$(m27_arm download ctWriterRequests)"
assert_eq "…and no barretenberg chunk" "[]" "$(m27_arm download barretenbergRequests)"
assert_eq "…with no page error" "[]" "$(m27_arm download pageErrors)"

m27_finish
