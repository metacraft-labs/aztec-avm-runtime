#!/usr/bin/env bash
# test_worker_transferable_container_not_copied
#
# M32 verification: "the container crosses as a transferable — MEASURED by the source buffer being
# detached afterwards, not asserted from the call site."
#
# ===========================================================================================
# THE DIFFERENCE BETWEEN THIS AND A CALL-SITE ASSERTION
# ===========================================================================================
#
# "We passed a transfer list" is a statement about the code that called `postMessage`. It is true of
# a transfer list the platform ignored, true of a payload whose buffer was not in the list, and true
# of a build in which the whole call was replaced by a structured clone. `CAMPAIGN-BRIEF.md`'s
# purest defect is an assertion that cannot fail; this one is one step past it — an assertion about
# the CALLER rather than about what happened.
#
# What happened is observable, in one place: the SENDER's `ArrayBuffer`. A transfer moves ownership,
# so afterwards the sender's buffer has `byteLength` 0 and `ArrayBuffer.prototype.detached` true. A
# structured clone leaves both alone. So the worker takes four readings OF ITS OWN MEMORY, across one
# buffer, and hands them back on the schema channel:
#
#   1. before any take          present, byteLength N, detached false
#   2. after a COPY             present, byteLength N, detached false   <- the control
#   3. after a TRANSFER         present, byteLength 0, detached TRUE    <- the measurement
#   4. a second TRANSFER        refused BY NAME, because the bytes are gone
#
# THE CONTROL IS THE COPY AND IT GOES THROUGH THE SAME CODE. `takeContainer(false)` is the same
# method, the same payload, the same client, with `Comlink.transfer` not applied — so the pair
# differs in exactly one thing. A control in a test file beside the code would differ in more.
#
# AND THE TRANSFER MUST NOT HAVE LOST ANYTHING. A faster wrong answer is worse than a copy: the
# page's SHA-256 of what it received either way is compared, and both are compared against the file
# the browser's own download machinery wrote to disk.
#
# Run: just verify-m32-transferable

TEST_NAME="test_worker_transferable_container_not_copied"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m32_worker.sh"

m32_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"
m32_require_arms

echo "== 0. the arm report carries what this check reads"

BEFORE="$(m32_arm transferable before)"
AFTER_COPY="$(m32_arm transferable afterCopy)"
AFTER_XFER="$(m32_arm transferable afterTransfer)"
SECOND="$(m32_arm transferable secondTransfer)"
COPIED_SHA="$(m32_arm transferable copiedSha256)"
MOVED_SHA="$(m32_arm transferable movedSha256)"
META_BYTES="$(m32_arm transferable meta.bytes)"
m32_absent \
  "transferable.before=$BEFORE" "transferable.afterCopy=$AFTER_COPY" \
  "transferable.afterTransfer=$AFTER_XFER" "transferable.secondTransfer=$SECOND" \
  "transferable.copiedSha256=$COPIED_SHA" "transferable.movedSha256=$MOVED_SHA" \
  "transferable.meta.bytes=$META_BYTES"

echo "== 1. the container was produced IN THE WORKER"

assert_eq "the page spawned exactly one worker target" "1" "$(m32_arm transferable workerTargetCount)"
assert_true "…and the worker fetched the .ct writer module itself" \
  str_has_sub "$(m32_arm transferable workerCtWriterRequests)" '/assets/ct_writer.wasm'
assert_eq "…while the page did not" "[]" "$(m32_arm transferable ctWriterRequests)"
assert_eq "no page error while it ran" "[]" "$(m32_arm transferable pageErrors)"
assert_eq "…and no console error" "[]" "$(m32_arm transferable consoleErrors)"

# THE THREAD IS ASKED WHAT IT IS, rather than inferred from the file it was built into.
GLOBALS="$(m32_arm transferable workerGlobals.0)"
note "the worker's own global scope: $GLOBALS"
assert_true "the worker says it is a DedicatedWorkerGlobalScope" str_has_sub "$GLOBALS" '"isDedicatedWorker":true'
assert_true "…with NO document" str_has_sub "$GLOBALS" '"hasDocument":false'
assert_true "…and no window" str_has_sub "$GLOBALS" '"hasWindow":false'
assert_true "…which is why the download stayed on the page, where there IS one" \
  str_has_sub "$(m32_arm boot pageHasDocument)" 'true'

echo "== 2. what the recording is"

note "$META_BYTES bytes, $(m32_arm transferable meta.events) events, $(m32_arm transferable meta.executedSteps) executed step(s)"
assert_ge "the container is a real one, not a stub" 10000 "$META_BYTES"
assert_eq "…and its byte count is what the writer reported" "$META_BYTES" \
  "$(m32_arm transferable movedBytes)"
assert_ge "…carrying the steps the AVM executed" 100 "$(m32_arm transferable meta.executedSteps)"
assert_eq "…which equals the module's own instruction statistic" \
  "$(m32_arm transferable meta.instructionsExecuted)" "$(m32_arm transferable meta.executedSteps)"
assert_eq "…written by the step producer M29 installed" "avm-execution-observer" \
  "$(m32_arm transferable meta.stepProducer)"
assert_ge "…over more than one AVM context" 2 "$(m32_arm transferable meta.contexts)"

echo "== 3. THE MEASUREMENT: three readings of one buffer, taken by the WORKER"

note "before        $BEFORE"
note "after a COPY  $AFTER_COPY"
note "after a MOVE  $AFTER_XFER"

B_LEN="$(m32_arm transferable before.byteLength)"
assert_true "before any take the worker holds the buffer" str_has_sub "$BEFORE" '"present":true'
assert_eq "…at its full length" "$META_BYTES" "$B_LEN"
assert_true "…and it is NOT detached" str_has_sub "$BEFORE" '"detached":false'
assert_eq "…with no take recorded yet" "0" "$(m32_arm transferable before.takes)"

echo "== 4. THE CONTROL: a structured clone does not detach it"

assert_eq "after a COPY the worker's buffer still has every byte" "$META_BYTES" \
  "$(m32_arm transferable afterCopy.byteLength)"
assert_true "…and is still not detached" str_has_sub "$AFTER_COPY" '"detached":false'
assert_eq "…and the worker counted the take" "1" "$(m32_arm transferable afterCopy.takes)"
assert_eq "…but counted no transfer" "0" "$(m32_arm transferable afterCopy.transfers)"

echo "== 5. THE ASSERTION: a transfer DOES detach it"

assert_eq "after a TRANSFER the worker's buffer has no bytes left" "0" \
  "$(m32_arm transferable afterTransfer.byteLength)"
# `ArrayBuffer.prototype.detached` and not an inference from a zero length — AND THAT SENTENCE IS
# EXERCISED RATHER THAN WRITTEN DOWN, WHICH IT WAS NOT UNTIL M32'S REVIEW. The only zero-length
# buffer in the sequence above is the transferred one, so an implementation computing
# `detached = byteLength === 0` agrees with the platform everywhere this check looks — and the worker
# SHIPPED that inference for the container while the control beside it read the real property, in a
# second expression nothing tied to the first. `containerBufferState` has ONE reader now and both
# readings go through it, so `zeroLengthControl` — a buffer of length 0 that was never transferred —
# controls the instrument rather than a copy of it: `{byteLength: 0, detached: false}` is the one
# combination an inference cannot produce, and one edit to that reader moves both readings.
assert_true "…and the platform itself reports it DETACHED" str_has_sub "$AFTER_XFER" '"detached":true'
ZERO="$(m32_arm transferable afterTransfer.zeroLengthControl)"
note "the zero-length control reads $ZERO"
assert_eq "…where a zero-length buffer that was NEVER transferred reads length 0" "0" \
  "$(m32_arm transferable afterTransfer.zeroLengthControl.byteLength)"
assert_true "…and NOT detached, so 'detached' is not a length test" str_has_sub "$ZERO" '"detached":false'
assert_eq "…and the worker counted a second take" "2" "$(m32_arm transferable afterTransfer.takes)"
assert_eq "…of which exactly one was a transfer" "1" "$(m32_arm transferable afterTransfer.transfers)"
# THE PAIR, READ TOGETHER. The copy and the transfer differ in exactly one thing, and the difference
# in the reading is what says the transfer list was honoured.
assert_true "the copy left the length where the transfer took it to zero" \
  test "$(m32_arm transferable afterCopy.byteLength)" -gt "$(m32_arm transferable afterTransfer.byteLength)"

echo "== 6. a second transfer is REFUSED BY NAME rather than answered with something plausible"

note "$SECOND"
assert_false "the second transfer was not accepted" str_has_sub "$SECOND" 'ACCEPTED'
assert_true "…and the refusal says the buffer is detached" str_has_sub "$SECOND" 'detached'
assert_true "…and says why a second take cannot be served" str_has_sub "$SECOND" 'transfer moves ownership'

echo "== 7. AND THE PAGE GOT THE SAME BYTES EITHER WAY"

note "copied sha256 $COPIED_SHA"
note "moved  sha256 $MOVED_SHA"
assert_eq "the copied container and the transferred one are byte-identical" "$COPIED_SHA" "$MOVED_SHA"
assert_eq "…both of them the full length" "$META_BYTES" "$(m32_arm transferable copiedLength)"
assert_eq "…on the transferred side too" "$META_BYTES" "$(m32_arm transferable movedLength)"
# NON-DEGENERACY BESIDE THE EQUALITY. Two empty containers would also be equal.
assert_ge "…and the digest is a real one" 64 "${#MOVED_SHA}"

echo "== 8. …and the BROWSER wrote that same container to disk"

DOWNLOADED="$(m32_arm transferable downloaded)"
assert_ge "the browser's own download machinery produced a file" 1 \
  "$(python3 -c '
import json, sys
print(len(json.loads(sys.argv[1])))' "$DOWNLOADED")"
DL_SHA="$(m32_arm transferable downloaded.0.sha256)"
DL_BYTES="$(m32_arm transferable downloaded.0.bytes)"
assert_eq "…of the same length as the container that crossed" "$META_BYTES" "$DL_BYTES"
assert_eq "…and byte-identical to it" "$MOVED_SHA" "$DL_SHA"
assert_true "…under a name that says which page produced it" \
  str_has_sub "$(m32_arm transferable downloaded.0.name)" 'aztec-avm-worker-'

echo "== 9. the protocol calls this arm actually made, in order"

CALLS="$(m32_arm transferable callsMade)"
note "$CALLS"
for needed in 'takeContainer:copy' 'takeContainer:transfer' 'recordContainer' 'containerBufferState'; do
  assert_true "the arm called $needed" str_has_sub "$CALLS" "$needed"
done
assert_eq "…and it took the container exactly three times" "3" \
  "$(python3 -c '
import json, sys
print(len([c for c in json.loads(sys.argv[1]) if c.startswith("takeContainer")]))' "$CALLS")"

echo "== 10. WORKER-NODE.md §5's packaging figures, re-derived from the build's own report"

assert_file "the write-up exists" "$M32_DOC"
DOC="$(cat "$M32_DOC")"
row_for() { printf '%s\n' "$DOC" | grep -F "$1" | head -1; }
# ===========================================================================================
# THE EAGER TOTALS ARE DERIVED, SO THEY ARE ASSERTED — anchored to the row that names the entry.
# ===========================================================================================
# `CAMPAIGN-BRIEF.md` records an OQ-6 check that matched each figure as `| <number> |` anywhere in
# the file: swapping two rows left the document stating the reverse of the data and the check
# reported 91 assertions and 0 failures. So each figure is looked for on ITS OWN ROW.
CHUNKS="$BROWSER_DIST/chunks.json"
assert_file "the build's own chunk report exists" "$CHUNKS"
for entry in browser.js testing.js demo.js node/node.js worker.js worker-demo.js; do
  KB="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
row = next((r for r in c["eager"] if r["entry"] == sys.argv[2]), None)
print("MISSING" if row is None else "%.2f" % round(row["gzipBytes"] / 1024, 2))' "$CHUNKS" "$entry")"
  N="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
row = next((r for r in c["eager"] if r["entry"] == sys.argv[2]), None)
print("MISSING" if row is None else len(row["files"]))' "$CHUNKS" "$entry")"
  ROW="$(row_for "\`$entry\` |")"
  assert_true "§5 has a row for $entry" test -n "$ROW"
  # THE SIZE AND THE COUNT ARE MATCHED TOGETHER, AND ON THE AFTER SIDE. Each row carries a BEFORE
  # column too — "| 255.79 KB, 7 files | **255.87 KB, 8 files** |" — so a needle that only has to
  # appear somewhere in the row is satisfied by the pre-M32 figures the row records for contrast.
  assert_true "…stating its measured eager size and file count together ($KB KB, $N files)" \
    str_has_sub "$ROW" "$KB KB, $N files"
  assert_true "…in the AFTER column rather than the before one" \
    str_has_sub "$ROW" "**$KB KB, $N files**"
done
# THE WORKER'S EAGER SET MUST NOT CARRY WHAT DD-11 FORBIDS. Measured out of the closure the build
# computed, not out of a name.
WORKER_EAGER="$(python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
row = next((r for r in c["eager"] if r["entry"] == "worker.js"), None)
print("\n".join(row["files"]) if row else "")' "$CHUNKS")"
assert_ge "the worker entry's eager file list was read" 3 \
  "$(printf '%s\n' "$WORKER_EAGER" | grep -c . || true)"
assert_false "…and the proving stack is not in it" str_has_sub "$WORKER_EAGER" 'barretenberg'
assert_false "…nor any protocol-contract registry artifact" str_has_sub "$WORKER_EAGER" 'Registry'
assert_false "…nor FeeJuice" str_has_sub "$WORKER_EAGER" 'FeeJuice'

m32_finish
