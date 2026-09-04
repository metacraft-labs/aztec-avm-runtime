#!/usr/bin/env bash
# e2e_resolved_contract_records_at_source_level — L5 (Aztec-Live-Chain-Replay).
#
# "A contract whose off-chain artifact was PROVED records at the rung its execution earns, and the
#  reference reader shows real Noir source lines where it showed Line(pc). Control: the same steps
#  with no proved artifact still show Line(pc), and every unresolved contract still says rung 3."
#
# ─────────────────────────────────────────────────────────────────────────────
# THE STANDARD IS THE REFERENCE READER, NOT THE WRITER'S RETURN VALUE.
#
# `l3_read_container` exists because L3's writer produced BYTES for three containers `ct-print`
# then refused. So §4 and §5 do not assert what `buildSettledRecording` said about itself — they
# assert what the reader found INSIDE the container: which paths it interned, and which line each
# step landed on. The subject's first step must land on a line in `fee_juice_contract/src/main.nr`;
# the control's must land on the program counter.
#
# ─────────────────────────────────────────────────────────────────────────────
# FOUR ARMS, ONE VARIABLE, AND THE FOURTH IS THE HONESTY ONE.
#
#   resolved  proved artifact, every step at a mapped pc   -> rung 1, sourceLevel true
#   control   THE SAME STEPS, `sources` omitted            -> rung 3, sourceLevel false, Line(pc)
#   partial   one step at a pc the map does not key        -> rung 2, sourceLevel false
#   mixed     two contracts, one proved and one NOT        -> rungs 1 AND 3 in ONE container, and
#                                                             the TRANSACTION is not source level
#
# **`mixed` IS THE ARM THE MILESTONE'S CONSTRAINT NAMES**: "do not let a partial rollout make
# unresolved transactions look source-level, and do not let a resolved one under-claim". Without it,
# every assertion here is satisfied by a recording that declares whatever the session was opened at.
#
# ─────────────────────────────────────────────────────────────────────────────
# WHAT THE STEP STREAM IS, SAID PLAINLY, BECAUSE IT BOUNDS THE CLAIM.
#
# **SYNTHETIC.** The pcs are drawn from the artifact's own mapped set, which makes "every step
# resolved" true by construction — `SOURCE-MAPPING.md` §6 records that exact trap, and M29 was the
# milestone that broke it by recording what the AVM executed. This check's subject is the WIRING,
# and the `partial` arm is what keeps the by-construction property from being the whole story: it
# plants a pc the map does not key and requires the declaration to fall to rung 2 rather than be
# rounded up.
#
# The evidence that a REAL chain execution reaches rung 1 needs a settled transaction whose
# contracts resolve, inside the ~1-hour replayable window.
# `replay/tools/await_resolvable_transaction.mjs` waits for one, and the reason it has to wait is
# measured: the only class any of this campaign's captures resolves is FeeJuice at `0x…03`, and the
# container that executed it — `0x12525d6d…`, testnet block 63670 — has been pruned from the tx
# pool, so its subject no longer exists to replay.

set -uo pipefail
TEST_NAME="e2e_resolved_contract_records_at_source_level"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"
. "$VERIFY_DIR/lib_l5_artifacts.sh"

echo "== $TEST_NAME"
summary_on_abnormal_exit
l5_prepare
l3_prepare
l5_require_recording_arms

# ── §1 the arms ran, over a proved artifact ─────────────────────────────────────────────────────
note "§1 the arms run and the artifact behind it"
assert_eq "the arms resolved the installed protocol-contracts FeeJuice" \
  "npm:@aztec/protocol-contracts@5.3.0-nightly.20260819 FeeJuice" \
  "$(l5_rec 'd["artifact"]["origin"]')"
assert_eq "…proved to the class's own artifact hash" \
  "0x1a57ff2a8e653094229bd15c028683e08b2086dfeadecac4c6b950c383b3ae1d" \
  "$(l5_rec 'd["artifact"]["artifactHash"]')"
assert_eq "…with 314 mapped pcs to draw a step stream from" "314" \
  "$(l5_rec 'd["artifact"]["mappedPcs"]')"
# THE `partial` ARM NEEDS A PC THE MAP DOES NOT KEY, AND IT IS FOUND RATHER THAN ASSUMED. A map
# that keyed every byte would leave that arm nothing to plant and every assertion under it would be
# about the arm it did not run.
assert_eq "…and an UNMAPPED pc exists to plant, so the partial arm has a subject" "0" \
  "$(l5_rec 'd["artifact"]["unmappedPcFound"]')"
assert_eq "…which is not one of the mapped ones, whose lowest is 130" "130" \
  "$(l5_rec 'd["artifact"]["firstMappedPc"]')"

# ── §2 the four arms, as the recording reports itself ───────────────────────────────────────────
note "§2 the four arms — one variable between the first two, and it is the sources argument"
assert_eq "resolved: no throw" "MISSING" "$(l5_rec 'd["arms"]["resolved"]["threw"]')"
assert_eq "control:  no throw" "MISSING" "$(l5_rec 'd["arms"]["control"]["threw"]')"
assert_eq "partial:  no throw" "MISSING" "$(l5_rec 'd["arms"]["partial"]["threw"]')"
assert_eq "mixed:    no throw" "MISSING" "$(l5_rec 'd["arms"]["mixed"]["threw"]')"

assert_eq "resolved declares rung 1" "1" "$(l5_rec 'd["arms"]["resolved"]["declaredRung"]')"
assert_eq "…and says so as sourceLevel" "true" "$(l5_rec 'd["arms"]["resolved"]["sourceLevel"]')"
assert_eq "…with every one of its 64 steps positioned" "64" \
  "$(l5_rec 'd["arms"]["resolved"]["stepsPositioned"]')"
assert_eq "…and none unpositioned" "0" "$(l5_rec 'd["arms"]["resolved"]["stepsUnpositioned"]')"
assert_eq "…over exactly one contract" "1" \
  "$(l5_rec 'len(d["arms"]["resolved"]["contractRungs"])')"
assert_eq "…which is FeeJuice at 0x…03" \
  "0x0000000000000000000000000000000000000000000000000000000000000003" \
  "$(l5_rec 'd["arms"]["resolved"]["contractRungs"][0]["address"]')"
assert_eq "…declared rung 1 because its execution resolved, not because its artifact did" "1" \
  "$(l5_rec 'd["arms"]["resolved"]["contractRungs"][0]["rung"]')"
assert_true "…and the reason says so in those terms" \
  str_has_sub "$(l5_rec 'd["arms"]["resolved"]["contractRungs"][0]["reasonHead"]')" \
  "all 64 executed step(s) of this contract resolved"

note "§2b the CONTROL — the same 64 steps, `sources` omitted"
assert_eq "control declares rung 3" "3" "$(l5_rec 'd["arms"]["control"]["declaredRung"]')"
assert_eq "…and is NOT source level" "false" "$(l5_rec 'd["arms"]["control"]["sourceLevel"]')"
assert_eq "…with ZERO steps positioned" "0" \
  "$(l5_rec 'd["arms"]["control"]["stepsPositioned"]')"
assert_eq "…and all 64 unpositioned" "64" \
  "$(l5_rec 'd["arms"]["control"]["stepsUnpositioned"]')"
assert_eq "…and it carries the SAME step count as the subject, so the difference is the mapping
  and not the stream" "$(l5_rec 'd["arms"]["resolved"]["steps"]')" \
  "$(l5_rec 'd["arms"]["control"]["steps"]')"
assert_true "…and its declaration is the unchanged chain-ceiling reason, verbatim" \
  str_has_sub "$(l5_rec 'd["arms"]["control"]["contractRungs"][0]["reasonHead"]')" \
  "RUNG 3 (BYTECODE) IS THE CEILING FOR A CHAIN-FETCHED CONTRACT"
assert_eq "…and no path was interned at all" "0" \
  "$(l5_rec 'd["arms"]["control"]["pathsInterned"]')"

note "§2c the PARTIAL arm — one unmapped pc, and the declaration is NOT rounded up"
assert_eq "partial declares rung 2" "2" "$(l5_rec 'd["arms"]["partial"]["declaredRung"]')"
assert_eq "…and is NOT source level, because rung 2 is not rung 1" "false" \
  "$(l5_rec 'd["arms"]["partial"]["sourceLevel"]')"
assert_eq "…with 63 of 64 positioned" "63" \
  "$(l5_rec 'd["arms"]["partial"]["stepsPositioned"]')"
assert_eq "…and exactly one not" "1" "$(l5_rec 'd["arms"]["partial"]["stepsUnpositioned"]')"
assert_true "…and the reason carries the split and cites the transpiler's procedure regions" \
  str_has_sub "$(l5_rec 'd["arms"]["partial"]["contractRungs"][0]["reasonHead"]')" \
  "63 of 64 executed step(s) of this contract resolve"

note "§2d the MIXED arm — the constraint the milestone states in words"
assert_eq "mixed declares TWO contracts" "2" \
  "$(l5_rec 'len(d["arms"]["mixed"]["contractRungs"])')"
assert_eq "…the proved one at rung 1" "1" \
  "$(l5_rec 'd["arms"]["mixed"]["contractRungs"][0]["rung"]')"
assert_eq "…the unproved one at rung 3, IN THE SAME CONTAINER" "3" \
  "$(l5_rec 'd["arms"]["mixed"]["contractRungs"][1]["rung"]')"
assert_eq "…and the unproved one is the third-party token" \
  "0x2a9a1d0e8f1974267536abefa565e7a7351f92ddbe95ec13c57c79b70664f7c8" \
  "$(l5_rec 'd["arms"]["mixed"]["contractRungs"][1]["address"]')"
assert_eq "…so the TRANSACTION is NOT source level, however well one contract did" "false" \
  "$(l5_rec 'd["arms"]["mixed"]["sourceLevel"]')"
assert_eq "…and the recording's own rung is the WORST of the two, not the best" "3" \
  "$(l5_rec 'd["arms"]["mixed"]["declaredRung"]')"
assert_eq "…with the split visible: 32 positioned" "32" \
  "$(l5_rec 'd["arms"]["mixed"]["stepsPositioned"]')"
assert_eq "…and 32 not" "32" "$(l5_rec 'd["arms"]["mixed"]["stepsUnpositioned"]')"

# ── §3 the provenance key is written by EVERY arm, including the ones with nothing to say ───────
note "§3 ct.source-provenance is unconditional, so its absence is never ambiguous"
for a in resolved control partial mixed; do
  assert_eq "$a writes exactly the six declared metadata keys" "6" \
    "$(l5_rec "len(d[\"arms\"][\"$a\"][\"metadataKeys\"])")"
  assert_eq "…including ct.source-provenance" "true" \
    "$(l5_rec "\"ct.source-provenance\" in d[\"arms\"][\"$a\"][\"metadataKeys\"]")"
  assert_eq "…and the container really carries that many log events" \
    "$(l5_rec "len(d[\"arms\"][\"$a\"][\"metadataKeys\"])")" \
    "$(l5_rec "d[\"arms\"][\"$a\"][\"logEvents\"]")"
done

# ── §4 THE REFERENCE READER, over the subject and the control ───────────────────────────────────
note "§4 what the reference reader finds inside the containers"
SUB_CT="$L5_CONTAINERS/resolved.ct"
CON_CT="$L5_CONTAINERS/control.ct"
assert_file "the subject container was written" "$SUB_CT"
assert_file "the control container was written" "$CON_CT"
SUB_OUT="$L5_WORK/resolved.read"
CON_OUT="$L5_WORK/control.read"
l3_read_container "$SUB_CT" "$SUB_OUT"
l3_read_container "$CON_CT" "$CON_OUT"

# THE PATHS. Read out of the reader's own decode, not out of the arms report.
SUB_PATHS="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["paths"]))' "$SUB_OUT" 2>/dev/null)"
CON_PATHS="$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["paths"]))' "$CON_OUT" 2>/dev/null)"
# A NON-EMPTY SCAN BEFORE ANYTHING IS ASSERTED ABOUT ITS CONTENTS (trap 4).
assert_ge "the reader reported at least one path for the subject" 1 \
  "$(printf '%s\n' "$SUB_PATHS" | grep -c . || true)"
# FIFTEEN, AND IT WAS TEN UNTIL THE RECORDER STARTED OPENING NOIR FRAMES.
#
# The number is not arbitrary and the change in it is the point, so it is recorded here rather than
# quietly re-baselined. Until frames were derived from the artifact's inline call-stack chains, the
# only source files a container could name were the ones the STEPS landed in — the INNERMOST
# location of each pc, which is what `positionFor` returns. A frame is opened at the CALL SITE, and
# a call site lives in the CALLER's file, so the tree reaches files no step's innermost position
# ever pointed at: `storage/map.nr`, `types/src/hash.nr`, `serde/src/serialization.nr` and the
# vendored `poseidon2.nr` among them.
#
# So a rise here is the expected shape of the change and a FALL back to ten would mean the frames
# stopped being written. `test_noir_frames_open_at_function_boundaries` is what asserts the tree
# itself; this asserts that the container's path table grew to hold it.
assert_eq "the subject's container carries FIFTEEN paths — the session's own plus fourteen Noir files, the extra five reached by CALL SITES rather than by steps" \
  "15" "$(printf '%s\n' "$SUB_PATHS" | grep -c . || true)"
assert_true "…including a file only a frame's call site can reach" \
  str_has_sub "$SUB_PATHS" "poseidon2.nr"
assert_eq "the CONTROL's carries ONE — the session's own, and nothing else" "1" \
  "$(printf '%s\n' "$CON_PATHS" | grep -c . || true)"
assert_true "the subject's paths include FeeJuice's main.nr" \
  str_has_sub "$SUB_PATHS" "fee_juice_contract/src/main.nr"
assert_false "…and the control's do NOT — the positive twin above is what makes this mean anything" \
  str_has_sub "$CON_PATHS" "fee_juice_contract/src/main.nr"
assert_true "the subject's paths include the AVM oracle sublib it inlines through" \
  str_has_sub "$SUB_PATHS" "aztec_sublib/src/oracle/avm.nr"

# THE STEP LINES. This is the claim: real Noir lines where there were program counters.
SUB_STEPS="$(python3 - "$SUB_OUT" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for e in d["events"]:
    if e.get("type") == "Step":
        print(f'{e["path_id"]}:{e["line"]}')
PY
)"
CON_STEPS="$(python3 - "$CON_OUT" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
for e in d["events"]:
    if e.get("type") == "Step":
        print(f'{e["path_id"]}:{e["line"]}')
PY
)"
assert_eq "the reader found 64 steps in the subject" "64" \
  "$(printf '%s\n' "$SUB_STEPS" | grep -c . || true)"
assert_eq "…and 64 in the control" "64" "$(printf '%s\n' "$CON_STEPS" | grep -c . || true)"
assert_eq "the subject's FIRST step is on path 1 — a Noir file, not the session's own path 0" \
  "1:203" "$(printf '%s\n' "$SUB_STEPS" | head -1)"
assert_eq "…and 203 is the line the artifact's own map gives for pc 130" "203" \
  "$(printf '%s\n' "$SUB_STEPS" | head -1 | cut -d: -f2)"
assert_eq "the CONTROL's first step is on path 0 — the session's own — at line 130, WHICH IS THE
  PROGRAM COUNTER. That is Line(pc), and it is what the subject replaced" "0:130" \
  "$(printf '%s\n' "$CON_STEPS" | head -1)"
assert_eq "…and its second is 135, which is the next mapped pc and not the next line" "0:135" \
  "$(printf '%s\n' "$CON_STEPS" | sed -n 2p)"
# NO STEP OF THE SUBJECT MAY SIT ON PATH 0. A container that positioned some steps and left others
# on the session path would render as source for part of a function and as nothing for the rest.
assert_eq "no step of the subject is left on the session's own path" "0" \
  "$(printf '%s\n' "$SUB_STEPS" | grep -c '^0:' || true)"
assert_eq "…and EVERY step of the control is" "64" \
  "$(printf '%s\n' "$CON_STEPS" | grep -c '^0:' || true)"
# THE LINES ARE NOT THE PCS. Without this, a container whose "source lines" happened to equal its
# program counters would satisfy everything above.
assert_false "the subject's step lines are not its program counters — 203 is not 130" \
  [ "$(printf '%s\n' "$SUB_STEPS" | head -1 | cut -d: -f2)" = "130" ]
assert_ge "…and the subject reaches more than one distinct line, so it is not one line repeated" 2 \
  "$(printf '%s\n' "$SUB_STEPS" | cut -d: -f2 | sort -u | grep -c . || true)"

# ── §4b THE POSITIONS, RECORD FOR RECORD, AGAINST WHAT THE RESOLVER COMPUTED ────────────────────
#
# **THIS IS THE STRONG ASSERTION AND EVERYTHING ABOVE IT IS A SUMMARY.** `smoke_browser_opens_and_
# steps_l3_container`'s precedent: the claim there is that the engine's reported positions are the
# container's own program counters, record for record, over 345 records — not that the counts agree.
# The claim here is the same shape: the line the reader decodes for step i is the line the
# `ContractSourceMap` answers for step i's pc, for every i.
#
# WHAT IT PINS IS THE WRITER PATH AND NOT THE RESOLVER, and saying so is the point: both sides come
# from the same map. What it can catch is everything BETWEEN them — a position staged for the wrong
# step, a slot skipped so every later record slides onto its predecessor's line, a batch boundary
# that drops the side channel. Those are invisible to every count in §2, because a shifted stream
# has exactly as many positioned steps as an unshifted one.
note "§4b the container's positions ARE the resolver's, step for step"
SUB_EXPECT="$(l5_rec 'd["arms"]["resolved"]["expectedPositions"]' | tr ',' '\n')"
assert_eq "the arms published one expectation per step" "64" \
  "$(printf '%s\n' "$SUB_EXPECT" | grep -c . || true)"
assert_eq "…and none of them is the unpositionable marker, for the resolved arm" "0" \
  "$(printf '%s\n' "$SUB_EXPECT" | grep -cx '\-' || true)"
# Decode `basename:line:column` out of the container by joining each step's `path_id` to the
# reader's own `paths` array. Column comes from the split probe's territory, so the comparison here
# is over `basename:line` and §5 asserts the column awareness separately.
SUB_ACTUAL="$(python3 - "$SUB_OUT" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
paths = d["paths"]
for e in d["events"]:
    if e.get("type") == "Step":
        print(f'{paths[e["path_id"]].split("/")[-1]}:{e["line"]}')
PY
)"
SUB_EXPECT_NOCOL="$(printf '%s\n' "$SUB_EXPECT" | sed 's/:[0-9]*$//')"
assert_eq "the reader decoded one position per step" "64" \
  "$(printf '%s\n' "$SUB_ACTUAL" | grep -c . || true)"
assert_eq "…and the two sequences are identical, record for record" \
  "$(printf '%s\n' "$SUB_EXPECT_NOCOL" | cksum)" "$(printf '%s\n' "$SUB_ACTUAL" | cksum)"
# NON-DEGENERATE ON BOTH COUNTS: two empty sequences are also identical, and one line repeated 64
# times would satisfy a digest comparison against itself.
assert_ge "…over more than one distinct position, so the comparison is not of a constant" 5 \
  "$(printf '%s\n' "$SUB_ACTUAL" | sort -u | grep -c . || true)"

note "§4c the PARTIAL arm's gap is in the MIDDLE, which is what makes the shift observable"
assert_eq "the unpositionable step is at index 31, not at the tail" "31" \
  "$(l5_rec 'd["partialGapIndex"]')"
PAR_EXPECT="$(l5_rec 'd["arms"]["partial"]["expectedPositions"]' | tr ',' '\n')"
assert_eq "…and the arm's expectation marks exactly one step unpositionable" "1" \
  "$(printf '%s\n' "$PAR_EXPECT" | grep -cx '\-' || true)"
assert_eq "…at index 32 counting from one, i.e. index 31 from zero" "32" \
  "$(printf '%s\n' "$PAR_EXPECT" | grep -nx '\-' | cut -d: -f1)"
PAR_CT="$L5_CONTAINERS/partial.ct"
PAR_OUT="$L5_WORK/partial.read"
assert_file "the partial container was written" "$PAR_CT"
l3_read_container "$PAR_CT" "$PAR_OUT"
PAR_ACTUAL="$(python3 - "$PAR_OUT" <<'PY' 2>/dev/null
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
paths = d["paths"]
for e in d["events"]:
    if e.get("type") == "Step":
        print(f'{paths[e["path_id"]].split("/")[-1]}:{e["line"]}')
PY
)"
# The unpositioned step reads back on the SESSION's own path at line 0 — the placeholder slot the
# writer stages rather than skipping. Its NEIGHBOURS are what the shift would move.
assert_eq "the partial container decodes 64 steps" "64" \
  "$(printf '%s\n' "$PAR_ACTUAL" | grep -c . || true)"
PAR_EXPECT_FULL="$(printf '%s\n' "$PAR_EXPECT" | sed 's/:[0-9]*$//' | sed 's/^-$/l5.avm:0/')"
assert_eq "…and every one of them matches the resolver's answer, with the unpositioned step's slot
  occupied by a line-0 placeholder rather than skipped — which is what stops the 32 steps AFTER it
  taking the lines of the 32 before" \
  "$(printf '%s\n' "$PAR_EXPECT_FULL" | cksum)" "$(printf '%s\n' "$PAR_ACTUAL" | cksum)"

# ── §5 COLUMN AWARENESS, which only rung 1 has ──────────────────────────────────────────────────
note "§5 columns — M25 section 3.1's rule, applied"
SUB_PROBE="$L5_WORK/resolved.probe"
CON_PROBE="$L5_WORK/control.probe"
if [ -x "$L3_CTPRINT_WORK/ct-split-probe" ]; then
  "$L3_CTPRINT_WORK/ct-split-probe" "$SUB_CT" >"$SUB_PROBE" 2>&1 || true
  "$L3_CTPRINT_WORK/ct-split-probe" "$CON_CT" >"$CON_PROBE" 2>&1 || true
  assert_true "the split-stream reader opens the subject" \
    str_has_line "$(cat "$SUB_PROBE")" "OPEN	ok"
  assert_true "…and reports it COLUMN_AWARE, which resolveTracingConfig refuses below rung 1" \
    str_has_line "$(cat "$SUB_PROBE")" "COLUMN_AWARE	true"
  assert_true "…while the control is NOT column aware" \
    str_has_line "$(cat "$CON_PROBE")" "COLUMN_AWARE	false"
  # THE GLOBAL POSITION INDEX IS THE M25 SIGNATURE: at rung 3 the first step's index IS the pc.
  assert_true "the control's first step index is 130 — the program counter itself" \
    str_has_line "$(cat "$CON_PROBE")" "STEP0_GLI	130"
  assert_false "…and the subject's is not, because it is an address in a line/column space" \
    str_has_line "$(cat "$SUB_PROBE")" "STEP0_GLI	130"
else
  die "no ct-split-probe at $L3_CTPRINT_WORK/ct-split-probe. Column awareness is half of what rung 1
     buys and ct-print does not report it, so this check will not claim it from the writer's own
     configuration. Remedy: just ct-print-build."
fi

finish
