#!/usr/bin/env bash
# smoke_browser_replays_settled_transaction — L4 (Aztec-Live-Chain-Replay).
#
# "A headless browser fetches a settled transaction and produces a container the reference reader
#  parses."
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# THE PRODUCE SIDE. THE OPEN SIDE IS `smoke_browser_opens_and_steps_l3_container` — DO NOT CONFLATE.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# Together they close the demo: a transaction that settled on a live Aztec chain is fetched,
# hydrated, re-executed and recorded IN A PAGE, and the container that comes out is opened and
# stepped IN A PAGE. Browser-resident, not merely browser-replayable.
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# THE STRONG ASSERTION IS BYTE-IDENTITY WITH THE NODE PATH, NOT "A CONTAINER WAS PRODUCED".
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# The page and the Node path run THE SAME `replay/src` over THE SAME committed recording, differing
# in exactly two substitutions — the AVM host and where the writer's bytes come from. So their
# containers must be **identical to the byte**, and §3 asserts that by digest.
#
# That is a far stronger claim than "the browser produced something a reader accepts". It means the
# hydration loop discovered the same reads, the AVM executed the same 345 instructions, the writer
# interned the same paths and the recording carried the same metadata — through a different WASI
# implementation, a different wasm loader and a different clock. **A page that got any of it subtly
# wrong would still produce a parseable container.** `ReplayAvmHost` and `RecordingWriter` being
# structural is what makes the two paths comparable at all, and this is the check that says the two
# declarations were worth making.
#
# ════════════════════════════════════════════════════════════════════════════════════════════════
# §5 ASSERTS A GAP RATHER THAN HIDING IT.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# The page FETCHES 4,139,020 BYTES OF BARRETENBERG, and DD-11's demand is "a page which only
# executes a public transaction never fetches the barretenberg wasm at all". So this page does not
# yet meet DD-11, and the check says so **as an assertion on the exact current state** rather than
# as a sentence in a comment:
#
#   * `barretenberg-*.js` IS fetched — exactly one of the two.
#   * `barretenberg-threads-*.js` is NOT.
#
# Pinned both ways, so a regression that fetched both reddens AND a fix that removes the fetch
# reddens too — forcing the number to move by a deliberate edit rather than drifting.
#
# WHY, AND WHAT THE FIX IS, so the next reader does not re-derive it: the replay path computes
# poseidon hashes — `computePublicBytecodeCommitment` over the contract bytecode,
# `siloNullifier` for the deployment nullifier, `computeFeePayerBalanceStorageSlot` — and
# `@aztec/foundation`'s default poseidon backend initialises `BarretenbergSync`. The reference
# bundle solves exactly this by REDIRECTING `foundation/dest/crypto/poseidon/index.js` to
# `browser/src/foundation_poseidon.ts`, which hashes through `avm.wasm`'s own poseidon instead —
# and this page already has `avm.wasm` loaded, so the hash is free. It is not applied here: the
# shim resolves its own `@aztec/foundation` imports from `browser/`, which has no `node_modules`,
# so wiring it needs the same alias work `buffer` needed plus a Reactor handed to the backend.
# **Named, quantified, not half-built.**

set -uo pipefail
TEST_NAME="smoke_browser_replays_settled_transaction"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l3_prepare

DRIVER="$REPO_ROOT/tools/produce_container_in_page.mjs"
PAGE_ENTRY="$REPO_ROOT/replay/browser-demo/replay_in_page.ts"
HOST="$REPO_ROOT/replay/tools/browser_avm_host.ts"
PAGE_CT="$L2_WORK/probes/l4-page.ct"
NODE_CT="$L2_WORK/probes/l4-page-node.ct"
REPORT="$L2_WORK/probes/l4-page.json"
DECODE="$L2_WORK/probes/l4-page.decode.json"

assert_file "the page entry is committed" "$PAGE_ENTRY"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "replay/browser-demo/replay_in_page.ts"
assert_file "the browser AVM host is committed" "$HOST"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "replay/tools/browser_avm_host.ts"
assert_file "the driver is committed" "$DRIVER"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "tools/produce_container_in_page.mjs"

CHROME="${M27_CHROMIUM:-$(command -v chromium || command -v google-chrome || true)}"
[ -n "$CHROME" ] || CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || die "no headless browser. This check drives a REAL browser; there is no
     substitute that would be evidence. Remedy: install chromium, or set M27_CHROMIUM."
export M27_CHROMIUM="$CHROME"

CT_WRITER="$REPO_ROOT/ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
[ -s "$CT_WRITER" ] || die "no ct_writer.wasm at $CT_WRITER. Remedy: just ct-writer-build"

# ---------------------------------------------------------------------------
echo "== 1. the bundle is BUILT here, so the page runs the tree as it stands"
# ---------------------------------------------------------------------------
BUILD_LOG="$L2_WORK/probes/l4-page-build.log"
mkdir -p "$(dirname "$BUILD_LOG")"
if ! timeout "${L4_BUILD_TIMEOUT:-600}" node "$REPO_ROOT/replay/tools/build_browser_bundle.mjs" \
     >"$BUILD_LOG" 2>&1; then
  die "the browser bundle failed to build; the builder's output is in $BUILD_LOG:
$(tail -20 "$BUILD_LOG")"
fi
assert_file "the page entry was emitted" "$REPO_ROOT/replay/dist-browser/browser-demo/replay_in_page.js"
assert_file "…and the library entry beside it" "$REPO_ROOT/replay/dist-browser/src/index.js"

# ---------------------------------------------------------------------------
echo "== 2. A REAL HEADLESS BROWSER RUNS THE WHOLE REPLAY AND EMITS A CONTAINER"
# ---------------------------------------------------------------------------
if ! timeout "${L4_PAGE_TIMEOUT:-900}" node "$DRIVER" \
      --avm "$L2_MODULE" --ct-writer "$CT_WRITER" \
      --fixture "$L2_FIXTURE" --out "$PAGE_CT" --report "$REPORT" \
      >"$L2_WORK/probes/l4-page.driver.log" 2>&1; then
  note "the page driver exited non-zero; its output follows"
  tail -30 "$L2_WORK/probes/l4-page.driver.log" >&2
fi
assert_file "the page produced a report" "$REPORT"
assert_file "…and a container on disk" "$PAGE_CT"

r() { python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(d.get(sys.argv[2], ""))
' "$REPORT" "$1"; }

assert_eq "the page replayed the fixture's transaction" \
  "$(l1_json "$L2_FIXTURE" "d['provenance']['txHash']")" "$(r txHash)"
assert_eq "…at its settling block" "$(l1_json "$L2_FIXTURE" "d['provenance']['l2BlockNumber']")" \
  "$(r l2BlockNumber)"
assert_eq "…reading its pre-state at the parent" \
  "$(( $(l1_json "$L2_FIXTURE" "d['provenance']['l2BlockNumber']") - 1 ))" "$(r preStateBlock)"
assert_eq "the hydration loop ran IN THE PAGE and converged in six rounds" "6" "$(r hydrationRounds)"
assert_eq "…seeding the same tree the Node path seeds" "4N/11P" "$(r seeded)"
assert_eq "the AVM executed 345 instructions in the browser" "345" "$(r instructionsExecuted)"
assert_eq "…and the published effects were reproduced" "True" "$(r reproduced)"
assert_eq "…over all 23 comparisons" "23/23" "$(r comparisons)"
assert_eq "the chain's revert code and the page's agree" "$(r publishedRevertCode)" \
  "$(r replayedRevertCode)"
assert_eq "the recording declares rung 3" "3" "$(r declaredRung)"
assert_eq "…and reports the roots do NOT agree, which is L2's handoff surviving into the page" \
  "False" "$(r rootsAgree)"
assert_eq "…with all five metadata records" "5" "$(r logEvents)"
assert_eq "the bytes that left the page are the bytes it reported" "$(r containerBytes)" \
  "$(wc -c <"$PAGE_CT" | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "== 3. THE STRONG ONE: byte-identical to the container the NODE path produces"
#
# Same `replay/src`, same recording, two substitutions — the AVM host and the writer's bytes. A page
# that got the hydration, the execution or the metadata subtly wrong would still produce a
# PARSEABLE container; only identity catches that.
# ---------------------------------------------------------------------------
PROBE="$(l2_imports)
$(cat <<'EOS'

import { writeFileSync } from 'node:fs';

const fixture = readL2Fixture();
const settled = await l2Settled(fixture);
const host = await createNodeAvmHost(L2_MODULE_PATH);
const hydrated = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs);
const pass = await recordingPass(host, settled, hydrated, encodeRecordingInputs);
const rec = buildSettledRecording(
  await l3Writer(settled), settled, { ...hydrated, steps: pass.steps }, pass.steps);
writeFileSync(process.env.NODE_CT, rec.container);
line('node.bytes', rec.bytes);
line('node.steps', rec.steps);
line('l2.done', 1);
EOS
)"
export NODE_CT
OUT="$L2_WORK/probes/l4page.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-900}" l0_run_probe l4page "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }

assert_file "the Node path produced its container too" "$NODE_CT"
assert_eq "…of the same size" "$(f node.bytes)" "$(wc -c <"$PAGE_CT" | tr -d ' ')"
assert_eq "THE TWO CONTAINERS ARE BYTE-IDENTICAL" \
  "$(shasum -a 256 <"$NODE_CT" | cut -c1-64)" "$(shasum -a 256 <"$PAGE_CT" | cut -c1-64)"
# NON-DEGENERACY: two empty files are also identical.
assert_ge "…over a real container rather than two stubs" 150000 "$(wc -c <"$PAGE_CT" | tr -d ' ')"
assert_eq "…carrying 345 steps" "345" "$(f node.steps)"

# ---------------------------------------------------------------------------
echo "== 4. and the REFERENCE READER parses what the page produced"
# ---------------------------------------------------------------------------
l3_read_container "$PAGE_CT" "$DECODE"
assert_eq "the reader finds 345 Step events in the PAGE's container" "345" \
  "$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(sum(1 for e in d["events"] if e["type"]=="Step"))' "$DECODE")"
assert_true "…and the chain provenance record is in it" \
  grep -q 'ct.chain-provenance' "$DECODE"
assert_true "…and the root divergence, which a page must not drop" \
  grep -q 'ct.merkle-root-divergence' "$DECODE"

# ---------------------------------------------------------------------------
echo "== 5. THE MEASURED GAP: this page does NOT yet meet DD-11, and the number is pinned"
#
# DD-11: "a page which only executes a public transaction never fetches the barretenberg wasm at
# all". This one fetches 4,139,020 bytes of it, because the replay computes poseidon hashes through
# @aztec/foundation's default backend. Asserted BOTH WAYS so neither a regression nor a fix can
# drift past unnoticed — see this file's header for the known remedy.
# ---------------------------------------------------------------------------
BB_REQS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
bb = [u for u in d["requests"] if "barretenberg-" in u and "threads" not in u]
th = [u for u in d["requests"] if "barretenberg-threads" in u]
off = [u for u in d["requests"] if u.startswith("http") and "127.0.0.1" not in u]
print(len(bb)); print(len(th)); print(len(off))
' "$REPORT")"
assert_eq "exactly ONE barretenberg chunk is fetched — the gap, pinned" "1" \
  "$(printf '%s\n' "$BB_REQS" | sed -n 1p)"
assert_eq "…and barretenberg-threads is NOT, so half the split is already paying" "0" \
  "$(printf '%s\n' "$BB_REQS" | sed -n 2p)"
assert_ge "…and the chunk it fetches is the 4.1 MB one" 4000000 \
  "$(wc -c <"$REPO_ROOT/replay/dist-browser/$(cd "$REPO_ROOT/replay/dist-browser" && ls barretenberg-*.js | grep -v threads | head -1)" | tr -d ' ')"

# THE PAGE REACHES NO NETWORK. Everything is same-origin; the fixture is L1's recording.
assert_eq "the page made NO off-origin request, so this measures the browser and not a node" "0" \
  "$(printf '%s\n' "$BB_REQS" | sed -n 3p)"

finish
