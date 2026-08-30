#!/usr/bin/env bash
# smoke_browser_opens_and_steps_l3_container — L4 (Aztec-Live-Chain-Replay).
#
# An L3 container — a recording of a transaction that settled on a live Aztec chain — is opened in a
# REAL headless browser by the PUBLISHED replay engine, and STEPPED.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE ACCEPTANCE CRITERION IS "STEPS TAKEN AND POSITIONS REACHED", NOT "IT LOADED".
#
# A container that loads and cannot be stepped is a finding, not a pass. So the strong assertion here
# is not that the engine answered — it is that **the positions the engine reports are the container's
# own program counters, record for record**. That is a comparison between two things produced by
# different programs on different sides of a browser boundary: `replay/src/recording.ts` wrote the
# pcs into the container from the AVM's executed step stream, and a Rust/WASM DAP server read them
# back out and reported them as source lines. Nothing in this repository is on both ends.
#
# It is also the assertion that cannot be satisfied by a well-formed empty answer. An engine that
# opened the container, reported one frame and stepped nowhere would satisfy "it loaded"; it fails
# `positions == pcs`.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHY THE ENGINE IS MIRRORED, AND WHY THE MIRROR IS A NAMED PRECONDITION RATHER THAN A SKIP.
#
# `new Worker(url, { type: 'module' })` throws `SecurityError` on a cross-origin script URL — which
# is why BlockTracer vendors the engine into its own origin instead of fetching it, and why a local
# page cannot construct a worker from `https://blocktracer.org/replay-engine/worker.js`. The engine's
# three files are mirrored and served from the same local origin as the container.
#
# THE MIRROR IS A NETWORK ACT AND THIS CHECK SAYS SO. It fetches somebody else's deployment, so it
# is not an offline floor and must never be counted as one — see `verify-l4-net` in the Justfile for
# where it belongs and why. If the mirror is absent the check DIES with a remedy; it does not skip,
# because a skipped browser check reads as a smaller milestone rather than a red one.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THE FIRST TWO RUNS OF THE DRIVER FOUND, recorded because both were silent failures.
#
#   1. The worker's two halves speak DIFFERENT SHAPES. Before `start` the JS half posts OBJECTS;
#      after `wasm_start()` the Rust half posts JSON STRINGS. A handler reading only `m.type` saw a
#      string, matched nothing, and reported "DAP timeout: initialize" — over an engine that had in
#      fact answered `success: true` and gone on to emit `initialized`.
#   2. `launch` takes `traceFolder`, NOT `program`. With `{ program }` every DAP request still
#      answered `success: true` and only `next` failed, with the engine's own words: "no trace is
#      open: next arrived before the launch handshake completed (received launch=true,
#      configurationDone=true)". **A launch that reports success while opening nothing** is exactly
#      why this check asserts stepped positions instead of a chain of `success` flags.
#
# Run: just verify-browser-opens-and-steps

set -uo pipefail
TEST_NAME="smoke_browser_opens_and_steps_l3_container"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l3_prepare

ENGINE_DIR="${L4_ENGINE_DIR:-$HOME/.cache/aztec-l4-replay-engine}"
DRIVER="$REPO_ROOT/tools/open_container_in_engine.mjs"
CONTAINER="$L2_WORK/probes/l4-browser.ct"
REPORT="$L2_WORK/probes/l4-browser.json"
PCS="$L2_WORK/probes/l4-browser-pcs.txt"

assert_file "the browser driver is committed" "$DRIVER"
assert_true "…and TRACKED" git -C "$REPO_ROOT" ls-files --error-unmatch "tools/open_container_in_engine.mjs"

CHROME="${M27_CHROMIUM:-$(command -v chromium || command -v google-chrome || true)}"
[ -n "$CHROME" ] || CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[ -x "$CHROME" ] || die "no headless browser. This check drives a REAL browser over the DevTools
     protocol; there is no substitute that would be evidence.
     Remedy: install chromium, or set M27_CHROMIUM."
export M27_CHROMIUM="$CHROME"
assert_true "a real browser binary was found" test -x "$CHROME"

for f in worker.js pkg/db_backend.js pkg/db_backend_bg.wasm; do
  [ -s "$ENGINE_DIR/$f" ] || die "the replay engine is not mirrored at $ENGINE_DIR ($f missing).
     THIS CHECK REACHES THE NETWORK ONCE, TO MIRROR SOMEBODY ELSE'S DEPLOYMENT, and that is a
     deliberate act rather than something a check should do behind your back.
     Remedy: just mirror-replay-engine $ENGINE_DIR"
done
assert_file "the mirrored engine's worker" "$ENGINE_DIR/worker.js"
assert_file "…its wasm-bindgen package" "$ENGINE_DIR/pkg/db_backend.js"
assert_file "…and the engine wasm itself" "$ENGINE_DIR/pkg/db_backend_bg.wasm"
assert_ge "…which is a real engine rather than a stub" 10000000 \
  "$(wc -c <"$ENGINE_DIR/pkg/db_backend_bg.wasm" | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "== 1. an L3 container is produced, from the committed fixture, offline"
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
writeFileSync(process.env.CONTAINER, rec.container);
writeFileSync(process.env.PCS, pass.steps.map((s) => s.pc).join('\n') + '\n');

line('ct.bytes', rec.bytes);
line('ct.steps', rec.steps);
line('ct.callsOpened', rec.callsOpened);
line('ct.declaredRung', rec.declaredRung);
line('tx.hash', settled.txHash);
line('tx.block', settled.l2BlockNumber);
line('l2.done', 1);
EOS
)"
export CONTAINER PCS
OUT="$L2_WORK/probes/l4browser.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-900}" l0_run_probe l4browser "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }

assert_file "the container was written" "$CONTAINER"
assert_eq "…345 steps" "345" "$(f ct.steps)"
assert_eq "…at rung 3" "3" "$(f ct.declaredRung)"
assert_eq "…and its size on disk is what the writer reported" "$(f ct.bytes)" \
  "$(wc -c <"$CONTAINER" | tr -d ' ')"
assert_eq "the executed pcs were written out beside it" "345" "$(wc -l <"$PCS" | tr -d ' ')"

# ---------------------------------------------------------------------------
echo "== 2. A REAL HEADLESS BROWSER OPENS IT WITH THE PUBLISHED ENGINE"
# ---------------------------------------------------------------------------
if ! timeout "${L4_BROWSER_TIMEOUT:-900}" node "$DRIVER" \
      --container "$CONTAINER" --engine "$ENGINE_DIR" --steps 400 --out "$REPORT" \
      >"$L2_WORK/probes/l4browser.driver.log" 2>&1; then
  # A non-zero exit is the driver's own verdict — "loaded but could not step" exits 1 — so the log
  # is quoted rather than summarised.
  note "the browser driver exited non-zero; its output follows"
  tail -30 "$L2_WORK/probes/l4browser.driver.log" >&2
fi
assert_file "the driver produced a report" "$REPORT"

r() { python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["summary"]
cur = d
for k in sys.argv[2].split("."):
    cur = cur.get(k) if isinstance(cur, dict) else None
    if cur is None: break
print("" if cur is None else cur)
' "$REPORT" "$1"; }

assert_eq "the engine's wasm loaded in the page" "True" "$(r phases.wasmLoaded)"
assert_eq "…the container was accepted into its VFS" "True" "$(r phases.traceLoaded)"
assert_eq "…and the DAP dispatcher started" "True" "$(r phases.started)"
assert_eq "the bytes the engine took in are the container's own" "$(f ct.bytes)" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"]["traceLoadReply"]["files"][0]["bytes"])' "$REPORT")"
assert_eq "initialize succeeded" "True" "$(r initializeOk)"
assert_eq "…launch succeeded" "True" "$(r launchOk)"
assert_eq "…and configurationDone succeeded" "True" "$(r configurationDoneOk)"

# ---------------------------------------------------------------------------
echo "== 3. AND IT STEPS — which is the claim, and the one a loaded-but-dead container fails"
# ---------------------------------------------------------------------------
STEPS="$(r stepsTaken)"
DISTINCT="$(r distinctLines)"
assert_ge "the engine took steps" 340 "$STEPS"
assert_eq "…and reached 345 distinct positions, one per record in the container" "345" "$DISTINCT"
assert_eq "…which is the container's own step count" "$(f ct.steps)" "$DISTINCT"
assert_eq "the engine reported a thread to step" "1" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["summary"]["threads"] or []))' "$REPORT")"
assert_eq "…and TWO stack frames, which are the writer's toplevel and L3's enqueued call" "2" \
  "$(r stackFramesAtStart)"
assert_eq "nothing stopped the stepping early" "" "$(r stepStoppedBecause)"
assert_eq "…and the driver reported no error" "" "$(r error)"
assert_eq "the page threw nothing" "0" \
  "$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))["summary"]["pageErrors"] or []))' "$REPORT")"

# ---------------------------------------------------------------------------
echo "== 4. THE STRONG ONE: the positions the engine reports ARE the container's program counters"
#
# Two programs, two languages, either side of a browser boundary: `recording.ts` wrote these pcs
# from the AVM's executed step stream, and a Rust/WASM DAP server read them back out. Nothing in
# this repository is on both ends of this comparison.
# ---------------------------------------------------------------------------
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))["full"]
open(sys.argv[2], "w").write("\n".join(str(p["line"]) for p in d["positions"][:345]) + "\n")
' "$REPORT" "$L2_WORK/probes/l4-browser-engine-lines.txt"

assert_eq "the engine's first 345 positions are the container's 345 pcs, record for record" \
  "$(shasum -a 256 <"$PCS" | cut -c1-64)" \
  "$(shasum -a 256 <"$L2_WORK/probes/l4-browser-engine-lines.txt" | cut -c1-64)"
assert_eq "…which is 345 lines on both sides" "345" \
  "$(wc -l <"$L2_WORK/probes/l4-browser-engine-lines.txt" | tr -d ' ')"

# NON-DEGENERACY: a walk would also compare equal to a walked file.
assert_eq "the pcs are NOT a walk — the first five are the AVM's own" "0
5
12
17
65" "$(head -5 "$PCS")"
assert_ge "…and they reach a real program's depth" 10000 "$(sort -n "$PCS" | tail -1)"

# The frame is the one L3 named, and the source path is the transaction.
FRAME="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"]["lastPosition"]["name"])' "$REPORT")"
SRC="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"]["lastPosition"]["source"])' "$REPORT")"
assert_eq "the frame the engine shows is the one recording.ts named" "enqueued-call-0" "$FRAME"
assert_contains "…and the source path it shows is the settled transaction's hash" \
  "$(f tx.hash)" "$SRC"

finish
