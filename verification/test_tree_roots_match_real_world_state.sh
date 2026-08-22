#!/usr/bin/env bash
# test_tree_roots_match_real_world_state — M8.
#
# The roots the in-memory world state produces INSIDE THE WASM MODULE, compared against Tier D's
# vectors, which were captured from Aztec's REAL production world state
# (`@aztec/world-state`'s `NativeWorldStateService`, LMDB-backed).
#
# Without this the whole differential would be self-consistency: two builds of one implementation
# agreeing with each other says nothing about whether the implementation is right. Here the left
# side is Aztec's and the right side is ours-compiled-from-Aztec's.
#
# M2 ESTABLISHED A SPLIT AND THIS CHECK KEEPS IT, because the split is the reason the vectors are
# worth anything:
#
#   upstreamPublished — read LIVE out of the fork at the pinned anchor, on every run, and the
#                       module compared against THAT. `world-state-vectors.json` is not consulted
#                       for any of them. (It is compared against the live read as well, so a drift
#                       between M2's file and upstream surfaces here rather than being absorbed.)
#   captured          — from `world-state-vectors.json`, which M2's own check requires to
#                       regenerate byte-identically from the real WorldState and requires to be
#                       ABSENT from the fork. This check re-asserts that absence for exactly the
#                       roots it relies on, so its own premise is not taken on trust.
#
# COVERAGE. This is one scripted mutation sequence — eight steps, a checkpoint cycle, one sibling
# path and 256 prefill preimages — not a fuzz campaign. It is the comparison the campaign has never
# made, not a breadth claim.

TEST_NAME="test_tree_roots_match_real_world_state"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
assert_file "the Tier D vectors are present" "$M8_VECTORS"
assert_file "the Tier D comparator is present" "$M8_TIERD_COMPARE"
[ -f "$M8_VECTORS" ] || die "fixtures/trees/world-state-vectors.json does not exist"

m8_measured

ANCHOR="$(m8_anchor)"
note "cpp anchor: $ANCHOR"
assert_eq "the anchor is the base commit the tree was prepared from" \
  "$M6_BASE_REV" "${ANCHOR:0:${#M6_BASE_REV}}"

UP="$M8_WORK/upstream"
mkdir -p "$UP"
m8_upstream_file "barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp" "$UP/world_state.test.cpp"
m8_upstream_file "noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr" "$UP/constants.nr"
m8_upstream_file "noir-projects/fnd/noir-protocol-circuits/crates/types/src/merkle_tree/root.nr" "$UP/root.nr"
assert_ge "upstream's world_state.test.cpp was read from the anchor" 500 "$(wc -l <"$UP/world_state.test.cpp")"
assert_ge "upstream's constants.nr was read from the anchor" 200 "$(wc -l <"$UP/constants.nr")"
assert_ge "upstream's merkle_tree/root.nr was read from the anchor" 60 "$(wc -l <"$UP/root.nr")"

V8_T="$(m8_v8_transcript)"
NATIVE_T="$(m8_native_transcript)"
m8_require_artifacts "$V8_T" "$NATIVE_T"

# ---------------------------------------------------------------------------
echo "== 1. the wasm module against Tier D and against upstream, read live"
# ---------------------------------------------------------------------------
python3 "$M8_TIERD_COMPARE" "$V8_T" "$M8_VECTORS" \
  "$UP/world_state.test.cpp" "$UP/constants.nr" "$UP/root.nr" >"$M8_WORK/tierd-wasm.report" 2>"$M8_WORK/tierd-wasm.err"
TIERD_RC=$?
assert_eq "the Tier D comparator ran (a refusal exit would mean an input was empty)" "0" "$TIERD_RC"
[ "$TIERD_RC" -eq 0 ] || { cat "$M8_WORK/tierd-wasm.err" >&2; finish; }
m8_report "$M8_WORK/tierd-wasm.report"

# ---------------------------------------------------------------------------
echo "== 2. and the native side, so the agreement is not a property of one target"
# ---------------------------------------------------------------------------
python3 "$M8_TIERD_COMPARE" "$NATIVE_T" "$M8_VECTORS" \
  "$UP/world_state.test.cpp" "$UP/constants.nr" "$UP/root.nr" >"$M8_WORK/tierd-native.report" 2>/dev/null
assert_eq "the Tier D comparator ran against the native transcript too" "0" "$?"
assert_true "the two sides produce the same Tier D report, row for row" \
  cmp -s "$M8_WORK/tierd-wasm.report" "$M8_WORK/tierd-native.report"
assert_ge "the Tier D comparison is not a handful of assertions" 100 \
  "$(grep -c . "$M8_WORK/tierd-wasm.report" || true)"

# ---------------------------------------------------------------------------
echo "== 3. M2's split, re-asserted for exactly the roots this check relies on"
# ---------------------------------------------------------------------------
# Every root the CAPTURED section contributes must be absent from the fork at the anchor. A
# "captured" value that turns out to be an upstream constant is a restatement wearing the clothes
# of independent evidence.
python3 - "$M8_VECTORS" >"$M8_WORK/novel-roots.txt" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
up = set()
for section in (v["upstreamPublished"]["genesisTrees"], v["upstreamPublished"]["postGenesisStep1"]):
    for t in section.values():
        up.add(t["root"])
up.update(v["upstreamPublished"]["emptyRootsAtPublishedHeights"].values())
novel = set()
for step in v["captured"]["mutationSequence"]:
    for t in step["trees"].values():
        novel.add(t["root"])
cp = v["captured"]["checkpoint"]
for key in ("beforeCheckpoint", "insideCheckpoint", "afterRevert"):
    for t in cp[key].values():
        novel.add(t["root"])
for r in sorted(novel - up):
    print(r)
PY
NOVEL_COUNT="$(grep -c . "$M8_WORK/novel-roots.txt" || true)"
assert_ge "the captured section introduces roots upstream does not publish" 6 "${NOVEL_COUNT:-0}"
# One `git grep` pass over the whole tree at the anchor rather than one per root.
GREP_ARGS=()
while read -r root; do
  [ -n "$root" ] || continue
  GREP_ARGS+=(-e "${root#0x}")
done <"$M8_WORK/novel-roots.txt"
if [ "${#GREP_ARGS[@]}" -gt 0 ]; then
  FOUND="$( ( cd "$FORK_ROOT" && git grep -F "${GREP_ARGS[@]}" "$ANCHOR" -- . ) 2>/dev/null | head -5 )"
  assert_eq "no captured root this check relies on appears anywhere in the fork at the anchor" "" "$FOUND"
fi
# …and the search really can find things, or the assertion above is a statement about a broken grep.
CONTROL_ROOT="$(python3 -c "
import json;v=json.load(open('$M8_VECTORS'))
print(v['upstreamPublished']['genesisTrees']['NOTE_HASH_TREE']['root'][2:])")"
assert_true "control: the same search DOES find an upstreamPublished root, so it is not inert" \
  bash -c "cd '$FORK_ROOT' && git grep -q -F '$CONTROL_ROOT' '$ANCHOR' -- ."

# ---------------------------------------------------------------------------
echo "== 4. what the module reproduces, named rather than counted"
# ---------------------------------------------------------------------------
for k in genesis.NOTE_HASH_TREE genesis.NULLIFIER_TREE genesis.PUBLIC_DATA_TREE \
         genesis.L1_TO_L2_MESSAGE_TREE tierD.step1.NULLIFIER_TREE tierD.step8.L1_TO_L2_MESSAGE_TREE \
         tierD.checkpoint.afterRevert.NOTE_HASH_TREE; do
  assert_true "the wasm transcript carries $k" grep -q "^$k " "$V8_T"
done
assert_eq "the module reproduces upstream's genesis nullifier root at size 128" \
  "0x18935581a8ed73d08ffd00386fba55ba6c89f3ab848a76b8fedfa9034cee0454 size=128" \
  "$(sed -n 's/^genesis\.NULLIFIER_TREE //p' "$V8_T")"

# ---------------------------------------------------------------------------
echo "== 5. negative controls"
# ---------------------------------------------------------------------------
# (1) A perturbed CAPTURED root in the vectors must be caught — so the comparison is against the
#     file rather than against itself.
PERT_VECTORS="$M8_WORK/vectors.perturbed.json"
python3 - "$M8_VECTORS" "$PERT_VECTORS" <<'PY'
import json, sys
v = json.load(open(sys.argv[1], encoding="utf-8"))
t = v["captured"]["mutationSequence"][2]["trees"]["NULLIFIER_TREE"]
t["root"] = t["root"][:-1] + ("0" if t["root"][-1] != "0" else "1")
json.dump(v, open(sys.argv[2], "w", encoding="utf-8"), indent=2)
PY
python3 "$M8_TIERD_COMPARE" "$V8_T" "$PERT_VECTORS" \
  "$UP/world_state.test.cpp" "$UP/constants.nr" "$UP/root.nr" >"$M8_WORK/tierd-pert.report" 2>/dev/null
PERT_FAILS="$(grep -c '^FAIL' "$M8_WORK/tierd-pert.report" || true)"
assert_eq "control: a single perturbed captured root is rejected, and by exactly one row" "1" "$PERT_FAILS"
assert_contains "control: and the rejected row names the step it belongs to" \
  "tierD step 4" "$(grep '^FAIL' "$M8_WORK/tierd-pert.report")"

# (2) A perturbed TRANSCRIPT genesis root must be caught by the LIVE upstream comparison, not by
#     the vectors — the two halves of M2's split are separately load-bearing.
PERT_T="$M8_WORK/wasm.transcript.perturbed"
python3 - "$V8_T" "$PERT_T" <<'PY'
import sys
out = []
for ln in open(sys.argv[1], encoding="utf-8"):
    if ln.startswith("genesis.NOTE_HASH_TREE "):
        ln = ln.replace("0x2590f2aa", "0x2590f2ab")
    out.append(ln)
open(sys.argv[2], "w", encoding="utf-8").writelines(out)
PY
python3 "$M8_TIERD_COMPARE" "$PERT_T" "$M8_VECTORS" \
  "$UP/world_state.test.cpp" "$UP/constants.nr" "$UP/root.nr" >"$M8_WORK/tierd-pert2.report" 2>/dev/null
assert_contains "control: a perturbed genesis root is rejected by the live upstream comparison" \
  "genesis NOTE_HASH_TREE root equals upstream's published constant" \
  "$(grep '^FAIL' "$M8_WORK/tierd-pert2.report")"

# (3) An EMPTY upstream file must make the comparator REFUSE rather than pass vacuously. This is
#     the shape that has bitten this campaign more than once: a membership test over an empty
#     haystack is not a failure, it is a silent success.
: >"$M8_WORK/empty.cpp"
python3 "$M8_TIERD_COMPARE" "$V8_T" "$M8_VECTORS" \
  "$M8_WORK/empty.cpp" "$UP/constants.nr" "$UP/root.nr" >"$M8_WORK/tierd-empty.report" 2>/dev/null
assert_eq "control: an empty upstream file makes the comparator exit 3 rather than pass" "3" "$?"
assert_eq "control: …and it emits no PASS rows at all" "0" \
  "$(grep -c '^PASS' "$M8_WORK/tierd-empty.report" || true)"

# (4) A transcript with no lines must be a refusal, not an empty green comparison.
: >"$M8_WORK/empty.transcript"
python3 "$M8_TIERD_COMPARE" "$M8_WORK/empty.transcript" "$M8_VECTORS" \
  "$UP/world_state.test.cpp" "$UP/constants.nr" "$UP/root.nr" >/dev/null 2>&1
assert_eq "control: an empty transcript makes the comparator exit 2" "2" "$?"

finish
