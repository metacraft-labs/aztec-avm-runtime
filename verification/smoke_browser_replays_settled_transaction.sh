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
# §5: DD-11 IS CLOSED, AND THE NEW STATE IS PINNED AS TIGHTLY AS THE OLD GAP WAS.
# ════════════════════════════════════════════════════════════════════════════════════════════════
#
# DD-11: "a page which only executes a public transaction never fetches the barretenberg wasm at
# all". **This page fetches ZERO bytes of it.** It fetched 4,139,020 before the poseidon
# substitution landed, and §5 pinned that number both ways so the fix would have to redden the check
# rather than slip past it. It did, and the assertion now pins the new state instead of relaxing
# into "less than some number":
#
#   * NO request whose path contains `barretenberg` — asserted as an exact zero.
#   * The page's ENTIRE request list is asserted as a SET, so a new fetch of anything is a failure
#     rather than something under a threshold.
#   * Both barretenberg chunks are still asserted LAZY in the graph, because "not fetched" and "not
#     in the lazy set" are different facts and losing either would matter.
#
# WHY IT WORKS, so nobody re-derives it: the replay hashes — `computePublicBytecodeCommitment`,
# `siloNullifier`, `computeFeePayerBalanceStorageSlot` — and `@aztec/foundation`'s poseidon
# initialises `BarretenbergSync`. The build now redirects `@aztec/foundation/crypto/poseidon` to
# `browser/src/foundation_poseidon.ts`, and `browser_avm_host.ts` installs `avm.wasm`'s OWN
# poseidon2 as the backend — a module the page has compiled anyway, so the hash is free.
#
# AND THE INSTALL IS EARLIER THAN IT LOOKS. It happens at HOST CREATION, before the fixture is even
# fetched, because upstream's `TxSchema` computes a transaction hash while PARSING the recorded
# response — so the run's first poseidon2 is inside `zod`, before the replay has an AVM instance.
# Installing it in `freshInstance()` failed with `Poseidon2NotInstalled` four frames deep.

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
# SIX SINCE L5, AND THE SIXTH IS `ct.source-provenance` — written unconditionally, including on
# this recording, whose contract has no provable off-chain artifact. That is the point of the key:
# a record that appeared only on source-level recordings would make its own absence ambiguous.
# `test_recording_declares_its_provenance` asserts the SET; this asserts the COUNT the page reported,
# so a page that wrote a different number of records than the Node path would be caught here rather
# than only in §3's byte comparison.
assert_eq "…with all six metadata records" "6" "$(r logEvents)"
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
echo "== 5. DD-11 IS CLOSED — the page fetches NO barretenberg, pinned as an exact set"
#
# This section pinned a 4,139,020-byte GAP both ways before the fix, precisely so the fix would have
# to redden it. It did. It now pins the new state just as tightly: an exact zero and an exact
# request set, not a threshold.
# ---------------------------------------------------------------------------
REQS="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
reqs = [u for u in d["requests"] if u != "/favicon.ico"]
print(len([u for u in reqs if "barretenberg" in u]))
print(len([u for u in reqs if u.startswith("http") and "127.0.0.1" not in u]))
print(" ".join(sorted(set(u.split("-")[0] if u.startswith("/bundle/chunk") else u for u in reqs))))
' "$REPORT")"
BB="$(printf '%s\n' "$REQS" | sed -n 1p)"
OFFORIGIN="$(printf '%s\n' "$REQS" | sed -n 2p)"
REQSET="$(printf '%s\n' "$REQS" | sed -n 3p)"

assert_eq "THE PAGE FETCHES NO BARRETENBERG AT ALL — DD-11's own words, met" "0" "$BB"
assert_eq "…and reaches no off-origin URL, so this measures the browser and not a node" "0" \
  "$OFFORIGIN"

# THE WHOLE REQUEST SET, as a set. A threshold would let a new fetch in under it; this will not.
assert_eq "the page's entire request set is exactly what a replay needs and nothing else" \
  "/avm.wasm /bundle/browser-demo/replay_in_page.js /bundle/chunk /ct_writer.wasm /fixture.json /index.html" \
  "$REQSET"

# AND THE CHUNKS ARE STILL LAZY IN THE GRAPH. "Not fetched" and "not in the eager closure" are
# different facts: a page could fail to fetch one because a code path did not run this time, while
# the module sat eagerly imported and would be fetched by the next caller.
LAZY_NAMES="$(python3 -c '
import json, os, sys
m = json.load(open(sys.argv[1])); outs = m["outputs"]
entry = next(k for k, v in outs.items() if (v.get("entryPoint") or "").endswith("browser-demo/replay_in_page.ts"))
eager = {entry}; stack = [entry]
while stack:
    cur = stack.pop()
    for imp in outs[cur].get("imports", []):
        if imp.get("kind") == "import-statement" and imp["path"] in outs and imp["path"] not in eager:
            eager.add(imp["path"]); stack.append(imp["path"])
print(" ".join(sorted(os.path.basename(k) for k in set(outs) - eager)))
' "$REPO_ROOT/replay/dist-browser/meta.json")"
assert_contains "barretenberg is still a LAZY chunk of the PAGE entry" "barretenberg-" "$LAZY_NAMES"
assert_contains "…and so is barretenberg-threads" "barretenberg-threads-" "$LAZY_NAMES"

finish
