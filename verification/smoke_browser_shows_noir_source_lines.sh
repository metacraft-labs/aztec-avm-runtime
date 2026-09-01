#!/usr/bin/env bash
# smoke_browser_shows_noir_source_lines — L5 (Aztec-Live-Chain-Replay).
#
# "The deployed CodeTracer engine opens a source-level container in a real browser and reports REAL
#  NOIR SOURCE LINES where it reported Line(pc). Control: the same steps with no proved artifact,
#  through the same engine, still report program counters."
#
# ─────────────────────────────────────────────────────────────────────────────
# THE STANDARD IS THE ENGINE'S OWN DAP REPLIES, NOT THIS REPOSITORY'S READER.
#
# `e2e_resolved_contract_records_at_source_level` reads the containers back with `ct-print` and
# `ct-split-probe` — the reference reader, which is what a container is verified with — and that
# already proves the bytes carry Noir positions. **It does not prove a DEBUGGER shows them.** A
# container can be well-formed and still open into a pane a user cannot read, and the whole subject
# of this milestone is what somebody sees when they click a transaction.
#
# So this drives the REAL published engine — `blocktracer.org/replay-engine`, mirrored — in a real
# headless Chromium, over the Chrome DevTools Protocol, and asserts the `source.path` and `line` of
# each `stackTrace` reply. Trap 2's rule: a chain of `success: true` is not a result, and every
# assertion here is over what the engine PRODUCED.
#
# ─────────────────────────────────────────────────────────────────────────────
# THE CONTROL IS THE SAME ENGINE OVER THE SAME EXECUTION, AND IT IS WHAT MAKES THIS MEAN ANYTHING.
#
# Two containers, one variable — the `sources` argument to `buildSettledRecording`. Without the
# control, "the engine reported main.nr:203" is satisfied by an engine that reports a plausible file
# for anything. With it, the same engine over the same 64 steps reports `/aztec/l5.avm:130` —
# **and 130 is the program counter**, which is `Line(pc)` and is what the subject replaced.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THIS IS NOT, STATED SO NOBODY INFERS MORE THAN IT SHOWS.
#
# The step stream is SYNTHETIC — pcs drawn from the artifact's own mapped set. The artifact is real,
# proved off-chain against a class the chain really serves, and the container is written by the
# shipped path; what did not happen is an AVM executing a settled transaction. That needs a
# transaction inside the ~1-hour replayable window whose contracts resolve, and
# `just await-resolvable-tx` is what waits for one. See L5's Outstanding item 1.
#
# A NETWORK PRECONDITION, NOT A NETWORK DEPENDENCY: the engine must be mirrored once with
# `just mirror-replay-engine`. This check DIES with that remedy rather than fetching behind your
# back — `smoke_browser_opens_and_steps_l3_container`'s rule.

set -uo pipefail
TEST_NAME="smoke_browser_shows_noir_source_lines"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"
. "$VERIFY_DIR/lib_l5_artifacts.sh"

echo "== $TEST_NAME"
summary_on_abnormal_exit
l5_prepare
l3_prepare
l5_require_recording_arms

ENGINE="${L5_ENGINE_DIR:-/tmp/l5engine}"
for f in worker.js pkg/db_backend.js pkg/db_backend_bg.wasm; do
  [ -s "$ENGINE/$f" ] || die "no mirrored engine at $ENGINE/$f.
     A local page cannot construct a Worker from a CROSS-ORIGIN script URL — \`new Worker(url,
     { type: 'module' })\` throws SecurityError — so the engine has to be served from the same
     origin as the container and therefore has to be mirrored first.
     Remedy: just mirror-replay-engine $ENGINE
     This is a DEATH and not a skip: a check that skips reads as a smaller milestone."
done

SUB_JSON="$L5_WORK/engine-resolved.json"
CON_JSON="$L5_WORK/engine-control.json"
run_engine() { # <container> <out>
  timeout "${L5_ENGINE_TIMEOUT:-900}" node "$REPO_ROOT/tools/open_container_in_engine.mjs" \
    --container "$1" --engine "$ENGINE" --steps 64 --out "$2" >/dev/null 2>&1
  local rc=$?
  assert_eq "the engine driver exited 0 over $(basename "$1")" "0" "$rc"
  assert_file "…and wrote its report" "$2"
}
run_engine "$L5_CONTAINERS/resolved.ct" "$SUB_JSON"
run_engine "$L5_CONTAINERS/control.ct" "$CON_JSON"

eng() { # <file> <expr over d (the summary)>
  python3 - "$1" "$2" <<'PY' 2>/dev/null || printf 'MISSING\n'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))["summary"]
try:
    v = eval(sys.argv[2], {"d": d, "len": len, "set": set, "sorted": sorted, "str": str,
                           "any": any, "all": all})
except Exception:
    print("MISSING"); raise SystemExit(0)
if v is None: print("MISSING")
elif isinstance(v, bool): print("true" if v else "false")
elif isinstance(v, (list, tuple)): print(",".join(str(x) for x in v))
else: print(v)
PY
}

# ── §1 both containers OPENED and STEPPED, which is the precondition and not the claim ──────────
note "§1 the engine opened and stepped both — a page that loads and cannot step is a finding"
assert_eq "the subject reached the engine with no page error" "0" \
  "$(eng "$SUB_JSON" 'len(d["pageErrors"])')"
assert_eq "…and no engine error" "MISSING" "$(eng "$SUB_JSON" 'd["error"]')"
assert_eq "…and the engine took 64 steps in it" "64" "$(eng "$SUB_JSON" 'd["stepsTaken"]')"
assert_eq "the CONTROL also took 64" "64" "$(eng "$CON_JSON" 'd["stepsTaken"]')"
assert_eq "…with no page error either, so the comparison below is between two working runs" "0" \
  "$(eng "$CON_JSON" 'len(d["pageErrors"])')"

# ── §2 THE CLAIM: real Noir source, out of the engine's own stackTrace replies ──────────────────
note "§2 what the engine says the first step is IN"
assert_contains "the subject's first position is in a .nr file" ".nr" \
  "$(eng "$SUB_JSON" 'd["firstPositions"][0]["source"]')"
assert_contains "…specifically FeeJuice's own main.nr" "fee_juice_contract/src/main.nr" \
  "$(eng "$SUB_JSON" 'd["firstPositions"][0]["source"]')"
assert_eq "…at line 203, which is what the artifact's map gives for pc 130" "203" \
  "$(eng "$SUB_JSON" 'd["firstPositions"][0]["line"]')"
assert_eq "…and its second is line 223" "223" "$(eng "$SUB_JSON" 'd["firstPositions"][1]["line"]')"
# THE ENGINE WALKS INTO OTHER FILES, which a single-file answer would not. This is the inlining
# chain `locationsOf` recovers, arriving at a debugger.
assert_ge "the engine reaches more than one source FILE over 64 steps" 4 \
  "$(eng "$SUB_JSON" 'len(set(p["source"] for p in d["firstPositions"]))')"
assert_eq "…and every one of the first ten is a .nr file, not the session's own .avm path" "0" \
  "$(eng "$SUB_JSON" 'len([p for p in d["firstPositions"] if not str(p["source"]).endswith(".nr")])')"
assert_contains "…including the AVM oracle sublib it inlines through" "oracle/avm.nr" \
  "$(eng "$SUB_JSON" '[p["source"] for p in d["firstPositions"]]')"
assert_ge "…and the walk reaches at least 10 distinct lines, so it is not one line repeated" 10 \
  "$(eng "$SUB_JSON" 'd["distinctLines"]')"

# ── §3 THE CONTROL: the same engine, the same execution, Line(pc) ───────────────────────────────
note "§3 the control — Line(pc), which is what the subject replaced"
assert_contains "the control's first position is the session's own synthetic path" "/aztec/l5.avm" \
  "$(eng "$CON_JSON" 'd["firstPositions"][0]["source"]')"
assert_eq "…at line 130" "130" "$(eng "$CON_JSON" 'd["firstPositions"][0]["line"]')"
# **AND 130 IS THE PROGRAM COUNTER.** Asserted against the arms' own record of the artifact's first
# mapped pc, which is where the step stream's first pc came from — so this is a comparison between
# two independently-sourced numbers and not a restatement.
assert_eq "…and 130 is the artifact's FIRST MAPPED PC, so the control's 'line' is a pc" \
  "$(l5_rec 'd["artifact"]["firstMappedPc"]')" \
  "$(eng "$CON_JSON" 'd["firstPositions"][0]["line"]')"
assert_eq "the control reaches exactly ONE source file over all 64 steps" "1" \
  "$(eng "$CON_JSON" 'len(set(p["source"] for p in d["firstPositions"]))')"
assert_eq "…and no .nr file at all" "0" \
  "$(eng "$CON_JSON" 'len([p for p in d["firstPositions"] if str(p["source"]).endswith(".nr")])')"
# 64 DISTINCT "LINES" OVER 64 STEPS IS THE SIGNATURE OF A PC STREAM, and 13 over 64 is the
# signature of source: real source revisits lines and a monotonic pc does not.
assert_eq "the control reports 64 distinct lines over 64 steps — one per step, which is what a
  program-counter stream looks like" "64" "$(eng "$CON_JSON" 'd["distinctLines"]')"
assert_false "…while the subject does NOT, because real source revisits lines" \
  [ "$(eng "$SUB_JSON" 'd["distinctLines"]')" = "64" ]

finish
