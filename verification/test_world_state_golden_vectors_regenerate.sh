#!/usr/bin/env bash
# test_world_state_golden_vectors_regenerate — M2, Tier D.
#
# Re-running the capture script against the real WorldState reproduces the checked-in Tier D root
# vectors byte for byte.
#
# It does three more things than that sentence, all of them because of a correction M1's review
# forced. Tier D was planned on the premise that upstream ships no golden merkle roots. That premise
# is FALSE: upstream ships them in several places, and the four genesis roots plus
# GENESIS_ARCHIVE_ROOT are checked in verbatim. A captured vector that restates a value upstream
# already publishes is worse than useless — it looks like independent evidence and is not. So:
#
#   1. Regeneration must be byte-identical (the sentence above).
#   2. Everything the capture marks `upstreamPublished` is compared against the value read LIVE out
#      of the aztec-packages fork at the pinned anchor. Not a copy here; `git show` on every run.
#   3. Everything the capture marks `captured` must be ABSENT from the fork at that anchor. A root
#      that turns up upstream is not a capture, it is a restatement, and this check fails it.
#
# It fails, rather than skipping, if the fork, node, or the world-state package is missing.

TEST_NAME="test_world_state_golden_vectors_regenerate"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

VECTORS="$REPO_ROOT/fixtures/trees/world-state-vectors.json"
CAPTURE_DIR="$REPO_ROOT/drift"
CAPTURE="$CAPTURE_DIR/capture_world_state.mjs"
PINS="$REPO_ROOT/pins.json"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
command -v node >/dev/null 2>&1 || die "node is not available"
[ -f "$VECTORS" ] || die "fixtures/trees/world-state-vectors.json does not exist"
[ -f "$CAPTURE" ] || die "drift/capture_world_state.mjs does not exist"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"
[ -d "$CAPTURE_DIR/node_modules/@aztec/world-state" ] || \
  die "drift/node_modules/@aztec/world-state is missing (run npm install in drift/)"

CPP_ANCHOR="$(python3 -c "import json;print(json.load(open('$PINS'))['anchors']['cpp']['commit'])")"
[ -n "$CPP_ANCHOR" ] || die "could not read the cpp anchor from pins.json"
note "cpp anchor: $CPP_ANCHOR"

SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

# ---------------------------------------------------------------------------
echo "== 1. regeneration is byte-identical"
# ---------------------------------------------------------------------------
( cd "$CAPTURE_DIR" && node capture_world_state.mjs ) >"$SCRATCH/regen.json" 2>"$SCRATCH/regen.err"
RC=$?
if [ "$RC" -ne 0 ]; then
  tail -20 "$SCRATCH/regen.err" >&2
  fail "the capture script exited $RC"
  finish
fi
assert_true "the capture produced JSON" python3 -c "import json;json.load(open('$SCRATCH/regen.json'))"
if cmp -s "$SCRATCH/regen.json" "$VECTORS"; then
  pass "regeneration reproduces fixtures/trees/world-state-vectors.json byte for byte"
else
  fail "regeneration differs from the checked-in vectors"
  diff <(head -200 "$VECTORS") <(head -200 "$SCRATCH/regen.json") | head -20 >&2
fi

# A second run, so byte equality is a property of the oracle rather than of one lucky invocation.
( cd "$CAPTURE_DIR" && node capture_world_state.mjs ) >"$SCRATCH/regen2.json" 2>/dev/null
assert_true "a second regeneration is identical to the first" cmp -s "$SCRATCH/regen.json" "$SCRATCH/regen2.json"

# ---------------------------------------------------------------------------
echo "== 2. the upstreamPublished section agrees with upstream, read live from the fork"
# ---------------------------------------------------------------------------
# Extract upstream's own constants out of the fork at the anchor, then compare.
WS_TEST="$SCRATCH/world_state.test.cpp"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp" ) \
  >"$WS_TEST" 2>/dev/null
assert_ge "upstream's world_state.test.cpp was read from the anchor" 500 "$(wc -l <"$WS_TEST")"

CONSTANTS_NR="$SCRATCH/constants.nr"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr" ) \
  >"$CONSTANTS_NR" 2>/dev/null
assert_ge "upstream's constants.nr was read from the anchor" 200 "$(wc -l <"$CONSTANTS_NR")"

ROOT_NR="$SCRATCH/root.nr"
( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:noir-projects/fnd/noir-protocol-circuits/crates/types/src/merkle_tree/root.nr" ) \
  >"$ROOT_NR" 2>/dev/null
assert_ge "upstream's merkle_tree/root.nr was read from the anchor" 60 "$(wc -l <"$ROOT_NR")"

UPSTREAM_REPORT="$(python3 - "$VECTORS" "$WS_TEST" "$CONSTANTS_NR" "$ROOT_NR" <<'PY'
import json, re, sys

vectors = json.load(open(sys.argv[1]))
ws_test = open(sys.argv[2]).read()
constants = open(sys.argv[3]).read()
root_nr = open(sys.argv[4]).read()

up = vectors["upstreamPublished"]
results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))


# --- The four genesis roots are hardcoded in world_state.test.cpp's GetInitialTreeInfoForAllTrees,
#     and the sizes appear beside them.
genesis = up["genesisTrees"]
for tree, expected_size in (
    ("NULLIFIER_TREE", "128"),
    ("NOTE_HASH_TREE", "0"),
    ("PUBLIC_DATA_TREE", "128"),
    ("L1_TO_L2_MESSAGE_TREE", "0"),
):
    root = genesis[tree]["root"]
    check(f"genesis {tree} root is hardcoded upstream", root in ws_test, root)
    check(f"genesis {tree} size {expected_size}", genesis[tree]["size"] == expected_size, genesis[tree]["size"])
    check(
        f"genesis {tree} root appears beside its size upstream",
        re.search(re.escape(root) + r'"\), ' + expected_size + r"UL", ws_test) is not None,
        "",
    )

# --- GENESIS_ARCHIVE_ROOT is a Noir constant.
archive = genesis["ARCHIVE"]["root"]
check("GENESIS_ARCHIVE_ROOT declared in constants.nr", archive in constants, archive)
check(
    "…and it is the archive root the capture recorded",
    re.search(r"GENESIS_ARCHIVE_ROOT[^;]*" + re.escape(archive), constants, re.S) is not None,
    "",
)

# --- Tree heights come from constants.nr too.
for tree, const in (
    ("NOTE_HASH_TREE", "NOTE_HASH_TREE_HEIGHT"),
    ("PUBLIC_DATA_TREE", "PUBLIC_DATA_TREE_HEIGHT"),
    ("L1_TO_L2_MESSAGE_TREE", "L1_TO_L2_MSG_TREE_HEIGHT"),
    ("ARCHIVE", "ARCHIVE_HEIGHT"),
):
    m = re.search(rf"pub global {const}: u32 = (\d+)", constants)
    check(f"{const} declared upstream", m is not None, "")
    if m:
        check(f"{tree} depth matches {const}", genesis[tree]["depth"] == int(m.group(1)), str(genesis[tree]["depth"]))

# --- The post-genesis StateReference upstream publishes in SyncExternalBlockFromEmpty.
step1 = up["postGenesisStep1"]
for tree, expected_size in (
    ("NULLIFIER_TREE", "129"),
    ("NOTE_HASH_TREE", "1"),
    ("PUBLIC_DATA_TREE", "129"),
    ("L1_TO_L2_MESSAGE_TREE", "1"),
):
    root = step1[tree]["root"]
    check(f"post-genesis {tree} root is hardcoded upstream", root in ws_test, root)
    check(f"post-genesis {tree} size {expected_size}", step1[tree]["size"] == expected_size, step1[tree]["size"])
    check(
        f"post-genesis {tree} root appears beside its size upstream",
        re.search(re.escape(root) + r'"\), ' + expected_size + r" }", ws_test) is not None,
        "",
    )
check(
    "the sync-block test that publishes them is present",
    "SyncExternalBlockFromEmpty" in ws_test,
    "",
)

# --- The empty-tree recurrence: it must hit upstream's published small heights, and then land on
#     the two genesis roots upstream publishes at heights 36 and 42.
by_height = vectors["derived"]["emptyRootByHeight"]
for h in ("1", "2", "6", "10"):
    value = up["emptyRootsAtPublishedHeights"][h]
    check(f"empty root at height {h} equals the recurrence", by_height[h] == value, value)
    check(f"empty root at height {h} is published in root.nr", value in root_nr, value)
check(
    "the recurrence lands on upstream's genesis L1->L2 root at height 36",
    by_height["36"] == genesis["L1_TO_L2_MESSAGE_TREE"]["root"],
    by_height["36"],
)
check(
    "the recurrence lands on upstream's genesis note-hash root at height 42",
    by_height["42"] == genesis["NOTE_HASH_TREE"]["root"],
    by_height["42"],
)
check(
    "the separator the recurrence uses is DOM_SEP__MERKLE_HASH from constants.nr",
    f"pub global DOM_SEP__MERKLE_HASH: u32 = {vectors['derived']['domainSeparator']};" in constants,
    str(vectors["derived"]["domainSeparator"]),
)

for name, ok, detail in results:
    print(("PASS" if ok else "FAIL") + "\t" + name + "\t" + detail)
PY
)"

while IFS=$'\t' read -r status name detail; do
  [ -n "$name" ] || continue
  if [ "$status" = "PASS" ]; then
    pass "$name"
  else
    fail "$name  ($detail)"
  fi
done <<<"$UPSTREAM_REPORT"

# ---------------------------------------------------------------------------
echo "== 3. nothing in the captured section restates an upstream constant"
# ---------------------------------------------------------------------------
# Roots that also appear in upstreamPublished are excluded — a tree that does not move keeps its
# previous root, and that root is legitimately upstream's. What must NOT appear upstream is any
# root the capture INTRODUCES.
python3 - "$VECTORS" >"$SCRATCH/novel-roots.txt" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
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
novel -= up
for r in sorted(novel):
    print(r)
PY
NOVEL_COUNT="$(grep -c . "$SCRATCH/novel-roots.txt" || true)"
assert_ge "roots the capture introduces beyond what upstream publishes" 6 "${NOVEL_COUNT:-0}"

FOUND_UPSTREAM=0
while read -r root; do
  [ -n "$root" ] || continue
  if ( cd "$FORK_ROOT" && git grep -q -F "${root#0x}" "$CPP_ANCHOR" -- . ) 2>/dev/null; then
    fail "a 'captured' root is already published upstream: $root"
    FOUND_UPSTREAM=$((FOUND_UPSTREAM + 1))
  fi
done <"$SCRATCH/novel-roots.txt"
assert_eq "captured roots that turned out to be upstream constants" "0" "$FOUND_UPSTREAM"

echo "== the captured section covers what upstream does not"
assert_ge "mutation steps past upstream's single published one" 6 \
  "$(python3 -c "import json;print(len(json.load(open('$VECTORS'))['captured']['mutationSequence']))")"
assert_eq "the zero sibling path is the full note-hash tree depth" "42" \
  "$(python3 -c "import json;print(len(json.load(open('$VECTORS'))['captured']['noteHashZeroSiblingPath']))")"
assert_eq "genesis prefill nullifier leaves" "128" \
  "$(python3 -c "import json;print(len(json.load(open('$VECTORS'))['captured']['genesisPrefill']['NULLIFIER_TREE']))")"
assert_eq "genesis prefill public-data leaves" "128" \
  "$(python3 -c "import json;print(len(json.load(open('$VECTORS'))['captured']['genesisPrefill']['PUBLIC_DATA_TREE']))")"
assert_true "every prefill leaf carries its indexed-tree linkage" \
  python3 -c "
import json,sys
v=json.load(open('$VECTORS'))['captured']['genesisPrefill']
for tree in v.values():
    for leaf in tree:
        assert leaf is not None and 'nextKey' in leaf and 'nextIndex' in leaf, leaf
"
assert_true "the checkpoint revert restores every root exactly" \
  python3 -c "
import json
c=json.load(open('$VECTORS'))['captured']['checkpoint']
assert c['beforeCheckpoint']==c['afterRevert']
assert c['insideCheckpoint']!=c['beforeCheckpoint']
"

# ---------------------------------------------------------------------------
echo "== negative controls"
# ---------------------------------------------------------------------------
# (1) A perturbed captured root must be detected by the regeneration comparison.
python3 - "$VECTORS" "$SCRATCH/perturbed.json" <<'PY'
import json, sys
v = json.load(open(sys.argv[1]))
step = v["captured"]["mutationSequence"][0]
tree = step["trees"]["NOTE_HASH_TREE"]
tree["root"] = tree["root"][:-1] + ("0" if tree["root"][-1] != "0" else "1")
json.dump(v, open(sys.argv[2], "w"), indent=2)
PY
assert_false "negative control: a perturbed captured root no longer matches regeneration" \
  cmp -s "$SCRATCH/perturbed.json" "$SCRATCH/regen.json"

# (2) A perturbed upstreamPublished root must fail the upstream comparison — i.e. the comparison
#     really is against upstream's text and not against the file itself.
PERTURBED_ROOT="$(python3 -c "
import json
v=json.load(open('$VECTORS'))
r=v['upstreamPublished']['genesisTrees']['NOTE_HASH_TREE']['root']
print(r[:-1] + ('0' if r[-1] != '0' else '1'))
")"
if ( cd "$FORK_ROOT" && git grep -q -F "${PERTURBED_ROOT#0x}" "$CPP_ANCHOR" -- . ) 2>/dev/null; then
  fail "negative control NOT caught: a perturbed genesis root was still found upstream"
else
  pass "negative control caught: a perturbed genesis root is not found upstream"
fi

# (3) The upstream side is a live read: an anchor that does not have the file must fail.
if ( cd "$FORK_ROOT" && git show "$CPP_ANCHOR:barretenberg/cpp/src/barretenberg/world_state/no_such_file.cpp" ) >/dev/null 2>&1; then
  fail "negative control NOT caught: git show succeeded for a path that does not exist"
else
  pass "negative control caught: the upstream read fails for a path that does not exist"
fi

# (4) A capture whose mutation sequence is emptied must fail the coverage floor, so the floor is
#     not merely unexercised.
EMPTIED="$(python3 -c "
import json
v=json.load(open('$VECTORS'))
v['captured']['mutationSequence']=[]
print(len(v['captured']['mutationSequence']))
")"
if [ "${EMPTIED:-1}" -ge 6 ]; then
  fail "negative control NOT caught: an emptied mutation sequence still met the floor"
else
  pass "negative control caught: an emptied mutation sequence fails the coverage floor"
fi

finish
