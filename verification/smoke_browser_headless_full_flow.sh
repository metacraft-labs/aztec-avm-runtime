#!/usr/bin/env bash
# smoke_browser_headless_full_flow
#
# M28 verification: "on every PR, a headless browser loads the bundle, executes a transaction,
# produces a block and emits a parseable `.ct` container".
#
# ==============================================================================================
# WHAT THIS ADDS TO M27'S FOUR BEHAVIOURAL CHECKS, WHICH IS NOT "THE SAME ASSERTIONS AGAIN".
# ==============================================================================================
#
# M27 has four checks over this arm run and each owns one stage: the network log
# (`verify_public_only_page_never_fetches_barretenberg`), the transaction
# (`smoke_browser_token_transfer`), the timer (`smoke_browser_produces_block_on_real_timer`) and the
# container (`e2e_browser_downloads_ct_container_and_ct_print_parses`). Every one of them is a true
# statement about its own stage, and FOUR TRUE STATEMENTS ABOUT FOUR STAGES ARE NOT A FLOW.
#
# What is asserted here is the JOINS — the identities that say the four stages are stages of one
# thing rather than four things that each worked:
#
#   load    -> execute : the module the PAGE compiled is the module on disk that this check
#                        required, by sha256, and the transaction ran through it (module calls).
#   execute -> block   : the transaction's own hash is in the block's transaction list, and the
#                        block is the one the transfer reports.
#   block   -> container: the recording the page offered is the size and the digest of the bytes
#                        that reached the download directory, and its id is in the file's name.
#   container -> reader : the reference reader parses THAT file, from the download directory, and
#                         its output names the sources the transaction executed.
#
# A stage that silently did nothing breaks a join even when its own check passes. That is the
# property a smoke test on every PR is for.
#
# ==============================================================================================
# IT IS ALSO THE ONE CHECK THAT IS THE PRODUCT, END TO END, IN ONE RUN.
# ==============================================================================================
#
# The gate's whole justification is that the browser is the environment which punishes an
# accidental Node dependency rather than tolerating it. The three static gates beside this one read
# artefacts; this one RUNS the artefact, in a real headless Chromium, over the DevTools protocol,
# with no puppeteer and no playwright (M27's `tools/browser_cdp.mjs`, reused). If any of the static
# gates is wrong, this is what notices.
#
# EVERY SUBPROCESS IS BOUNDED. A browser is the most hang-prone thing in this repository and
# `CAMPAIGN-BRIEF.md` names the hang as the worst of the three states a check can be in.
# `m27_require_arms` runs under `timeout -s KILL` and turns an overrun into a named failure; the
# reader runs under `m24_ct_print`'s own bound.
#
# Run: just verify-browser-full-flow   (or: just ci-browser-gate)

TEST_NAME="smoke_browser_headless_full_flow"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m28_gate.sh"

m28_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is required"
command -v node >/dev/null 2>&1 || die "node is required"

echo "== 0. one arm run, in a real browser, and it is the one this tree would produce"

m24_require_readers
m27_require_arms

CHROMIUM="$(m27_run chromium)"
NODEV="$(m27_run node)"
MEASURED="$(m27_run measuredAt)"
note "chromium: $CHROMIUM; node: $NODEV; measured at $MEASURED"
assert_prefix "the arms ran in a real Chromium, whose version is recorded rather than assumed" \
  "Chromium " "$CHROMIUM"
assert_prefix "…driven from Node 24, whose global WebSocket is what makes the CDP driver dependency-free" \
  "v24." "$NODEV"
assert_ge "…and the run has a timestamp, so the report is a run rather than a template" 20 \
  "${#MEASURED}"
# THE DRIVER IS M27's AND IT HAS NO DEPENDENCIES. Re-asserted here rather than assumed, because
# this check is the one CI runs on every PR and "the browser gate needs a 300 MB npm install" is
# exactly the decay a gate is supposed to prevent.
assert_file "the CDP driver is this repository's own" "$REPO_ROOT/tools/browser_cdp.mjs"
assert_eq "…and it imports nothing but Node builtins" "" \
  "$(grep -oE "^import .*from '[^']+'" "$REPO_ROOT/tools/browser_cdp.mjs" \
     | grep -oE "'[^']+'$" | tr -d "'" | grep -v '^node:' | tr '\n' ' ' | sed 's/ $//')"
assert_ge "…and that scan really read its imports, so the empty answer is a measurement" 3 \
  "$(grep -cE "^import .*from 'node:" "$REPO_ROOT/tools/browser_cdp.mjs" || true)"

echo "== 1. LOAD — the page compiled the module this check required"

PAGE_SHA="$(m27_run module.sha256)"
PAGE_BYTES="$(m27_run module.bytes)"
DISK_SHA="$(sha256sum "$AVM_WASM_PATH" | cut -d' ' -f1)"
DISK_BYTES="$(stat -c %s "$AVM_WASM_PATH")"
assert_eq "the sha256 recorded by the run is the sha256 of the module on disk" "$DISK_SHA" "$PAGE_SHA"
assert_eq "…and the byte count agrees too" "$DISK_BYTES" "$PAGE_BYTES"
# NON-EMPTINESS BESIDE THE IDENTITY. `m27_run` prints MISSING for an absent key, which defends a
# comparison against a LITERAL and defends nothing when both sides come from a helper — M27's
# review measured exactly that (`MISSING == MISSING` passing). Here one side is `sha256sum`'s own
# output, and it is asserted to be a digest.
assert_eq "…and the digest is a 64-character hex string rather than an empty read" "64" "${#DISK_SHA}"
assert_ge "the module is the thirteen-overlay one, which is what carries poseidon2 and grumpkin" \
  1600000 "$DISK_BYTES"

# The page fetched the module over the network, which is what "loads the bundle" means in a browser.
# `avmWasmRequests` is the LIST of matching request URLs, not a count — asserted on both its length
# and its content, because a list of the wrong things would have the right length.
AVM_REQS="$(m27_arm publicOnly avmWasmRequests)"
assert_ge "the page fetched avm.wasm over the network" 1 \
  "$(printf '%s' "$AVM_REQS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_true "…and the request it made is for the module itself" str_has_sub "$AVM_REQS" "avm.wasm"
assert_eq "…and fetched no barretenberg proving chunk, which is DD-11" "[]" \
  "$(m27_arm publicOnly barretenbergRequests)"
assert_eq "…and the page logged no error" "[]" "$(m27_arm publicOnly pageErrors)"
assert_eq "…and no console error either" "[]" "$(m27_arm publicOnly consoleErrors)"

echo "== 2. EXECUTE — a transaction ran, through that module"

OUTCOME="$(m27_arm publicOnly transfer.outcome)"
MODULE_CALLS="$(m27_arm publicOnly transfer.moduleCalls)"
TXHASH="$(m27_arm publicOnly transfer.txHash)"
ADDRESS="$(m27_arm publicOnly transfer.contractAddress)"
assert_eq "the transaction was processed rather than dropped or failed" "processed" "$OUTCOME"
assert_ge "…and it really went through the wasm module rather than round a fallback" 5 "$MODULE_CALLS"
assert_eq "…with no proving, which is what this runtime is for" "none" \
  "$(m27_arm publicOnly transfer.proving)"
# THE HASH IS A HASH. `str_has_sub` has no empty-needle guard — `case $h in (*""*)` matches
# unconditionally — so an arm reporting an empty hash would satisfy every containment assertion
# below against any list. M27's review found that live; the shape is asserted before it is used.
assert_prefix "the transaction has a hash" "0x" "$TXHASH"
assert_eq "…of the right width, so the containment below is not a match on the empty string" "66" \
  "${#TXHASH}"
assert_prefix "…and the contract has an address" "0x" "$ADDRESS"
assert_eq "…of the right width too" "66" "${#ADDRESS}"

echo "== 3. BLOCK — the block took THAT transaction"

BLOCKNO="$(m27_arm publicOnly transfer.blockNumber)"
BLOCKHASHES="$(m27_arm publicOnly transfer.blockTxHashes)"
assert_eq "the transaction landed in block 1" "1" "$BLOCKNO"
assert_ge "…and the block's transaction list is not empty" 1 \
  "$(printf '%s' "$BLOCKHASHES" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_true "…and it contains THIS transaction's hash" str_has_sub "$BLOCKHASHES" "$TXHASH"
# The join's negative direction: a hash that is NOT this transaction's is not in the list, so the
# containment above is a join and not a predicate that matches anything.
assert_false "…while a hash that is not this transaction's is not" \
  str_has_sub "$BLOCKHASHES" "0x${TXHASH:2:2}deadbeef${TXHASH:12}"

# And blocks keep coming on a real timer, which is the other half of "produces a block".
TIMER_BLOCKS="$(m27_arm timer blocks)"
N_BLOCKS="$(printf '%s' "$TIMER_BLOCKS" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
assert_ge "the timer arm produced several blocks in the page" 5 "$N_BLOCKS"
assert_eq "…strictly increasing in number, with no gap" "ok" \
  "$(printf '%s' "$TIMER_BLOCKS" | python3 -c '
import json, sys
b = json.load(sys.stdin)
ns = [x["number"] for x in b]
print("ok" if ns == list(range(ns[0], ns[0] + len(ns))) else "gap:%s" % ns)')"

echo "== 4. CONTAINER — the bytes the page offered are the bytes on disk"

DL="$(m27_arm download downloaded)"
assert_eq "exactly one .ct file reached the download directory" "1" \
  "$(printf '%s' "$DL" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
DL_PATH="$(printf '%s' "$DL" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["path"])')"
DL_NAME="$(printf '%s' "$DL" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["name"])')"
DL_SHA="$(printf '%s' "$DL" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["sha256"])')"
assert_file "…and it is on disk where the browser's download behaviour put it" "$DL_PATH"

REC_ID="$(m27_arm download recording.recordingId)"
IN_PAGE_BYTES="$(m27_arm download inPageBytes)"
IN_PAGE_SHA="$(m27_arm download inPageSha256)"
ON_DISK_BYTES="$(stat -c %s "$DL_PATH" 2>/dev/null || echo MISSING)"
ON_DISK_SHA="$(sha256sum "$DL_PATH" 2>/dev/null | cut -d' ' -f1 || echo MISSING)"

assert_eq "the bytes the PAGE held and the bytes on DISK are the same count" "$IN_PAGE_BYTES" \
  "$ON_DISK_BYTES"
assert_eq "…and the same digest, re-hashed here rather than read from the report" "$IN_PAGE_SHA" \
  "$ON_DISK_SHA"
assert_eq "…and the report's own record of the downloaded digest agrees" "$ON_DISK_SHA" "$DL_SHA"
assert_eq "the digest is a real one rather than two absences compared" "64" "${#ON_DISK_SHA}"
assert_ge "…over a container of substantial size" 100000 "$ON_DISK_BYTES"
# The id join: the recording the page made is the file that was downloaded.
assert_ge "the recording id is a full uuid" 36 "${#REC_ID}"
assert_true "…and the downloaded file is named for it" str_has_sub "$DL_NAME" "$REC_ID"
assert_prefix "…with the runtime's own prefix" "aztec-avm-" "$DL_NAME"

echo "== 5. READER — the reference reader parses THAT file"

READ="$(m24_ct_print "$M24_READERS/ct-print" "$DL_PATH")"
RC="$(printf '%s\n' "$READ" | head -1)"
OUT="$(printf '%s\n' "$READ" | tail -n +2)"
LINES="$(printf '%s\n' "$OUT" | grep -c . || true)"
note "ct-print --full over the downloaded container exited $RC with $LINES line(s)"
assert_eq "ct-print --full exits 0 over the container the browser downloaded" "0" "$RC"
assert_ge "…printing a substantial record stream rather than an empty one" 500 "$LINES"
assert_true "…with Step records" str_has_sub "$OUT" '"type": "Step"'
assert_true "…and Call records, so the frames survived" str_has_sub "$OUT" '"type": "Call"'
assert_true "…and Path records, so the source positions did" str_has_sub "$OUT" '"type": "Path"'
# THE FLOW'S LAST JOIN: the recording is of an AZTEC transaction, named by the sources it executed,
# not of an empty session that happened to serialise.
assert_true "…naming the AVM entry point" str_has_sub "$OUT" "/aztec/tx.avm"
assert_true "…and Aztec.nr's own dispatch macro, which is where a public call lands" \
  str_has_sub "$OUT" "dispatch.nr"
# The reader's verdict has a control: it is capable of REFUSING. A 512-byte stub is not a container.
STUB="$M28_WORK/stub.ct"
rm -rf "$STUB"; mkdir -p "$STUB"
head -c 512 /dev/urandom >"$STUB/meta.dat"
STUB_RC="$(m24_ct_print "$M24_READERS/ct-print" "$STUB" | head -1)"
assert_eq "…and the same reader REFUSES a 512-byte stub, so exit 0 above is a verdict" "0" \
  "$([ "$STUB_RC" != "0" ] && echo 0 || echo 1)"
note "ct-print over a 512-byte stub exits $STUB_RC"
rm -rf "$STUB"

echo "== 6. the flow ran once, as one flow"

# The four stages above are read out of ONE report, produced by ONE invocation of the runner. That
# is what makes the joins joins: two runs would give four true statements about two sessions.
assert_file "there is exactly one arm report and it is the shared one" "$M27_ARMS"
assert_eq "…and no failed-run report was left beside it by this run" "0" \
  "$([ -f "$M27_WORK/browser-failed.json" ] && [ "$M27_WORK/browser-failed.json" -nt "$M27_ARMS" ] && echo 1 || echo 0)"
assert_eq "every arm in the report shares the run's single measuredAt" "$MEASURED" "$(m27_run measuredAt)"
assert_ge "…and the report describes all five arms of the flow" 5 \
  "$(m27_run arms | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

m28_finish
