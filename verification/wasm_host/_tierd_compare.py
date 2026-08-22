#!/usr/bin/env python3
"""Compare an `avm_differential` transcript against the Tier D world-state vectors.

M2 established a split that this script keeps, because the split is the whole reason the vectors
are worth anything:

    upstreamPublished  — values upstream itself checks in. They are read LIVE out of the
                         aztec-packages fork at the pinned anchor, by this script, on every run,
                         and the transcript is compared against THOSE. `world-state-vectors.json`
                         is not consulted for any of them: a comparison of our file against our
                         file is not evidence, and M2's own checker already ties that file to
                         upstream.

    captured           — the part upstream genuinely does not publish: the mutation sequence past
                         upstream's single published post-genesis step, the checkpoint/revert
                         cycle, the 42-level zero sibling path and the 256 genesis prefill leaf
                         preimages. These come from `world-state-vectors.json`, which M2's checker
                         requires to regenerate byte-identically from Aztec's REAL LMDB
                         `NativeWorldStateService` and requires to be ABSENT from the fork.

So the roots on the left are Aztec's production world state and the roots on the right are the
in-memory reference world state inside our wasm module. Agreement is agreement with Aztec's own
implementation, not native-versus-wasm self-consistency.

Usage:
    _tierd_compare.py <transcript> <vectors.json> <world_state.test.cpp> <constants.nr> <root.nr>

Prints one `PASS\\t<name>\\t<detail>` / `FAIL\\t<name>\\t<detail>` row per assertion.
Exits 2 if it cannot run at all, and 3 if an upstream file it was handed carries none of the
values it exists to supply — an empty haystack must never make a membership test vacuous.
"""

import json
import re
import sys

RESULTS = []

TREES = ("NOTE_HASH_TREE", "NULLIFIER_TREE", "PUBLIC_DATA_TREE", "L1_TO_L2_MESSAGE_TREE")


def check(name, ok, detail=""):
    RESULTS.append(("PASS" if ok else "FAIL", name, str(detail)))


def parse_transcript(path):
    """-> {key: value}. Duplicate keys are a defect in the driver, not something to resolve."""
    out = {}
    dups = []
    with open(path, encoding="utf-8") as fh:
        for ln in fh:
            ln = ln.rstrip("\n")
            if not ln or ln.startswith("diag "):
                continue
            key, _, value = ln.partition(" ")
            if key in out:
                dups.append(key)
            out[key] = value
    return out, dups


ROOT_SIZE_RE = re.compile(r"^(0x[0-9a-f]{64}) size=([0-9]+)$")


def transcript_snapshot(t, prefix, tree):
    """-> (root, size) from a `prefix.TREE  0x… size=N` line, or (None, None)."""
    v = t.get(f"{prefix}.{tree}")
    if v is None:
        return (None, None)
    m = ROOT_SIZE_RE.match(v)
    if not m:
        return (None, None)
    return (m.group(1), m.group(2))


# ---------------------------------------------------------------------------------------------
# Upstream extraction. These EXTRACT rather than test membership: a membership test against a file
# we also wrote the expected value into passes for free, and this campaign has met that shape.
# ---------------------------------------------------------------------------------------------
GENESIS_BLOCK_RE = re.compile(
    r"get_tree_info\(WorldStateRevision::committed\(\), MerkleTreeId::([A-Z_0-9]+)\);\s*"
    r"EXPECT_EQ\(info\.meta\.size, ([0-9]+)\);\s*"
    r"EXPECT_EQ\(info\.meta\.depth, [^;]+\);\s*"
    r"EXPECT_EQ\(info\.meta\.root, bb::fr\(\"(0x[0-9a-f]{64})\"\)\);",
    re.S,
)

# The post-genesis StateReference upstream publishes in WorldStateTest.SyncExternalBlockFromEmpty:
#     { MerkleTreeId::NULLIFIER_TREE,
#       { fr("0x…"), 129 } },
# Extracted PER TREE, so the comparison is "this tree's root, at this tree's size" rather than
# "this root appears somewhere in the file".
STATE_REF_RE = re.compile(
    r"MerkleTreeId::([A-Z_0-9]+)\s*,\s*\{\s*fr\(\s*\"(0x[0-9a-f]{64})\"\s*\)\s*,\s*([0-9]+)\s*\}",
)

# The inputs upstream's own sync_block is given, so the replay is asserted to be replaying THAT
# sequence and not merely landing on the same roots by some other route.
SYNC_BLOCK_RE = re.compile(
    r"ws\.sync_block\(\s*block_state_ref\s*,\s*fr\([0-9]+\)\s*,\s*\{\s*([0-9]+)\s*\}\s*,\s*"
    r"\{\s*([0-9]+)\s*\}\s*,\s*\{\s*NullifierLeafValue\(([0-9]+)\)\s*\}\s*,\s*"
    r"\{\s*\{\s*PublicDataLeafValue\(([0-9]+),\s*([0-9]+)\)\s*\}\s*\}\s*\)",
    re.S,
)

EMPTY_ROOT_RE = re.compile(
    r"compute_empty_tree_root::<([0-9]+)>\(\),\s*(0x[0-9a-f]{64}|0)\s*[,)]",
)

HEIGHT_RE = r"pub global {}: u32 = ([A-Za-z0-9_]+);"


def resolve_height(constants, const, depth=0):
    """constants.nr declares NULLIFIER_TREE_HEIGHT as an alias of NOTE_HASH_TREE_HEIGHT rather
    than as a literal. One level of aliasing is followed rather than the constant being restated
    here, because restating it is precisely what the upstreamPublished discipline forbids."""
    if depth > 3:
        return None
    m = re.search(HEIGHT_RE.format(const), constants)
    if m is None:
        return None
    v = m.group(1)
    if v.isdigit():
        return v
    return resolve_height(constants, v, depth + 1)


def main():
    if len(sys.argv) != 6:
        sys.stderr.write(__doc__)
        return 2
    transcript_p, vectors_p, ws_test_p, constants_p, root_nr_p = sys.argv[1:6]

    t, dups = parse_transcript(transcript_p)
    if not t:
        sys.stderr.write(f"_tierd_compare: no transcript lines in {transcript_p}\n")
        return 2
    check("no transcript key is emitted twice", not dups, ",".join(sorted(set(dups))))

    vectors = json.load(open(vectors_p, encoding="utf-8"))
    ws_test = open(ws_test_p, encoding="utf-8").read()
    constants = open(constants_p, encoding="utf-8").read()
    root_nr = open(root_nr_p, encoding="utf-8").read()

    # -----------------------------------------------------------------------------------------
    # 1. GENESIS — against upstream's own hardcoded roots, read live.
    # -----------------------------------------------------------------------------------------
    genesis_upstream = {m.group(1): (m.group(3), m.group(2)) for m in GENESIS_BLOCK_RE.finditer(ws_test)}
    if len(genesis_upstream) < 4:
        sys.stderr.write(
            "_tierd_compare: world_state.test.cpp yielded %d genesis roots, expected at least 4 — "
            "the upstream side is empty and every comparison below would be vacuous\n" % len(genesis_upstream)
        )
        return 3
    check("upstream's own genesis roots were extracted from world_state.test.cpp",
          len(genesis_upstream) >= 4, f"{len(genesis_upstream)} trees: {sorted(genesis_upstream)}")

    for tree in TREES:
        up_root, up_size = genesis_upstream.get(tree, (None, None))
        got_root, got_size = transcript_snapshot(t, "genesis", tree)
        check(f"genesis {tree} root equals upstream's published constant",
              up_root is not None and got_root == up_root, f"upstream={up_root} module={got_root}")
        check(f"genesis {tree} size equals upstream's published size",
              up_size is not None and got_size == up_size, f"upstream={up_size} module={got_size}")

    # The genesis roots must also be the four the JSON's upstreamPublished section names, or the
    # two sides of M2's split have drifted apart and one of the two checks is measuring nothing.
    jgen = vectors["upstreamPublished"]["genesisTrees"]
    for tree in TREES:
        check(f"the JSON and the live upstream read agree on genesis {tree}",
              jgen[tree]["root"] == genesis_upstream.get(tree, (None, None))[0],
              f"json={jgen[tree]['root']} upstream={genesis_upstream.get(tree, (None, None))[0]}")

    # -----------------------------------------------------------------------------------------
    # 2. STEP 1 — upstream's own SyncExternalBlockFromEmpty StateReference, read live.
    # -----------------------------------------------------------------------------------------
    check("the sync-block test that publishes the post-genesis StateReference is present",
          "SyncExternalBlockFromEmpty" in ws_test, "")
    # Scoped to that test's own body: the file declares other StateReferences and a value lifted
    # from one of them would be the wrong constant compared against the right name.
    sync_start = ws_test.find("TEST_F(WorldStateTest, SyncExternalBlockFromEmpty)")
    sync_body = ws_test[sync_start:sync_start + 2000] if sync_start >= 0 else ""
    check("the SyncExternalBlockFromEmpty body was located and is non-empty",
          len(sync_body) > 500, len(sync_body))
    state_ref = {m.group(1): (m.group(2), m.group(3)) for m in STATE_REF_RE.finditer(sync_body)}
    if len(state_ref) < 4:
        sys.stderr.write(
            "_tierd_compare: SyncExternalBlockFromEmpty yielded %d StateReference snapshots, "
            "expected at least 4\n" % len(state_ref)
        )
        return 3
    check("upstream's post-genesis StateReference snapshots were extracted, per tree",
          sorted(state_ref) == sorted(TREES), sorted(state_ref))
    for tree in TREES:
        up_root, up_size = state_ref.get(tree, (None, None))
        got_root, got_size = transcript_snapshot(t, "tierD.step1", tree)
        check(f"tierD step 1 {tree} root equals upstream's published StateReference root",
              up_root is not None and got_root == up_root, f"upstream={up_root} module={got_root}")
        check(f"tierD step 1 {tree} size equals upstream's published StateReference size",
              up_size is not None and got_size == up_size, f"upstream={up_size} module={got_size}")

    # The replay is asserted to be replaying UPSTREAM'S sequence: same note hash, same L1->L2
    # message, same nullifier, same public-data slot and value. Landing on the same roots from a
    # different sequence would be a coincidence worth knowing about, not a pass.
    sync = SYNC_BLOCK_RE.search(sync_body)
    check("upstream's own sync_block inputs were extracted", sync is not None, "")
    if sync:
        check("step 1 replays upstream's note hash 42, message 43, nullifier 144, data (145, 1)",
              sync.groups() == ("42", "43", "144", "145", "1"), str(sync.groups()))

    # -----------------------------------------------------------------------------------------
    # 3. STEPS 2..8 and the checkpoint cycle — against the CAPTURED vectors.
    # -----------------------------------------------------------------------------------------
    seq = vectors["captured"]["mutationSequence"]
    check("the captured mutation sequence carries the seven steps past upstream's published one",
          len(seq) == 7, len(seq))
    for step in seq:
        n = step["step"]
        for tree in TREES:
            want = step["trees"][tree]
            got_root, got_size = transcript_snapshot(t, f"tierD.step{n}", tree)
            check(f"tierD step {n} ({step['name']}) {tree} root matches the real WorldState",
                  got_root == want["root"], f"captured={want['root']} module={got_root}")
            check(f"tierD step {n} ({step['name']}) {tree} size matches the real WorldState",
                  got_size == want["size"], f"captured={want['size']} module={got_size}")

    cp = vectors["captured"]["checkpoint"]
    for phase, key in (("before", "beforeCheckpoint"), ("inside", "insideCheckpoint"),
                       ("afterRevert", "afterRevert")):
        for tree in TREES:
            want = cp[key][tree]
            got_root, got_size = transcript_snapshot(t, f"tierD.checkpoint.{phase}", tree)
            check(f"checkpoint {phase} {tree} root matches the real WorldState",
                  got_root == want["root"], f"captured={want['root']} module={got_root}")
            check(f"checkpoint {phase} {tree} size matches the real WorldState",
                  got_size == want["size"], f"captured={want['size']} module={got_size}")

    # The revert must RESTORE, and the checkpoint must have CHANGED something first — otherwise
    # "before equals after" is a statement about a cycle that did nothing.
    before = [transcript_snapshot(t, "tierD.checkpoint.before", x) for x in TREES]
    inside = [transcript_snapshot(t, "tierD.checkpoint.inside", x) for x in TREES]
    after = [transcript_snapshot(t, "tierD.checkpoint.afterRevert", x) for x in TREES]
    check("the checkpoint revert restores every root and size exactly", before == after, "")
    check("the mutation inside the checkpoint really changed the state", before != inside, "")
    check("checkpoint ids follow create/revert (0 -> 1 -> 0)",
          (t.get("tierD.checkpoint.id.before"), t.get("tierD.checkpoint.id.inside"),
           t.get("tierD.checkpoint.id.afterRevert")) == ("0", "1", "0"),
          f"{t.get('tierD.checkpoint.id.before')}/{t.get('tierD.checkpoint.id.inside')}/"
          f"{t.get('tierD.checkpoint.id.afterRevert')}")

    # -----------------------------------------------------------------------------------------
    # 4. THE 42-LEVEL GENESIS SIBLING PATH — captured, and independently anchored upstream.
    # -----------------------------------------------------------------------------------------
    captured_path = vectors["captured"]["noteHashZeroSiblingPath"]
    check("the captured zero sibling path is the full note-hash tree depth", len(captured_path) == 42,
          len(captured_path))
    check("the module reports a sibling path of the same depth",
          t.get("genesis.siblingPath.NOTE_HASH_TREE.0.depth") == str(len(captured_path)),
          t.get("genesis.siblingPath.NOTE_HASH_TREE.0.depth"))
    mismatched = []
    for i, want in enumerate(captured_path):
        got = t.get(f"genesis.siblingPath.NOTE_HASH_TREE.0.{i}")
        if got != want:
            mismatched.append(f"level {i}: captured={want} module={got}")
    check("every level of the genesis note-hash sibling path matches the real WorldState",
          not mismatched, "; ".join(mismatched[:3]))

    # The same path, checked at the four heights upstream publishes in root.nr. Two unrelated
    # upstream publications converging on our module's own output.
    empty_roots = {int(m.group(1)): (m.group(2) if m.group(2) != "0" else "0x" + "0" * 64)
                   for m in EMPTY_ROOT_RE.finditer(root_nr)}
    if len(empty_roots) < 4:
        sys.stderr.write("_tierd_compare: root.nr yielded %d empty-tree roots, expected at least 4\n"
                         % len(empty_roots))
        return 3
    check("upstream's published empty-tree roots were extracted from root.nr",
          len(empty_roots) >= 4, sorted(empty_roots))
    for h, want in sorted(empty_roots.items()):
        if h == 0:
            continue
        got = t.get(f"genesis.siblingPath.NOTE_HASH_TREE.0.{h}")
        check(f"the module's sibling path at level {h} is upstream's published empty-tree root",
              got == want, f"upstream={want} module={got}")

    # -----------------------------------------------------------------------------------------
    # 5. THE 256 GENESIS PREFILL PREIMAGES — captured.
    #
    # A tree whose ROOT is right can still have its low-leaf linkage wrong. The preimages are what
    # makes that unrepresentable, and upstream publishes none of them.
    # -----------------------------------------------------------------------------------------
    prefill = vectors["captured"]["genesisPrefill"]
    nullifier_bad, public_data_bad = [], []
    for i, leaf in enumerate(prefill["NULLIFIER_TREE"]):
        want = (f"nullifier={leaf['leaf']['nullifier']} nextKey={leaf['nextKey']} "
                f"nextIndex={leaf['nextIndex']}")
        got = t.get(f"genesis.prefill.NULLIFIER_TREE.{i}")
        if got != want:
            nullifier_bad.append(f"{i}: captured=[{want}] module=[{got}]")
    for i, leaf in enumerate(prefill["PUBLIC_DATA_TREE"]):
        want = (f"slot={leaf['leaf']['slot']} value={leaf['leaf']['value']} "
                f"nextKey={leaf['nextKey']} nextIndex={leaf['nextIndex']}")
        got = t.get(f"genesis.prefill.PUBLIC_DATA_TREE.{i}")
        if got != want:
            public_data_bad.append(f"{i}: captured=[{want}] module=[{got}]")
    check("all 128 genesis nullifier prefill preimages match the real WorldState, with their linkage",
          len(prefill["NULLIFIER_TREE"]) == 128 and not nullifier_bad,
          "; ".join(nullifier_bad[:3]))
    check("all 128 genesis public-data prefill preimages match the real WorldState, with their linkage",
          len(prefill["PUBLIC_DATA_TREE"]) == 128 and not public_data_bad,
          "; ".join(public_data_bad[:3]))

    # -----------------------------------------------------------------------------------------
    # 6. TREE HEIGHTS, from constants.nr, against the sibling-path depths the module reports.
    # -----------------------------------------------------------------------------------------
    for tree, const, sample in (("NOTE_HASH_TREE", "NOTE_HASH_TREE_HEIGHT", 0),
                                ("PUBLIC_DATA_TREE", "PUBLIC_DATA_TREE_HEIGHT", 0),
                                ("L1_TO_L2_MESSAGE_TREE", "L1_TO_L2_MSG_TREE_HEIGHT", 0),
                                ("NULLIFIER_TREE", "NULLIFIER_TREE_HEIGHT", 0)):
        height = resolve_height(constants, const)
        check(f"{const} is declared upstream and resolves to a literal", height is not None, height)
        if height:
            got = t.get(f"samples.siblingPath.{tree}.{sample}.depth")
            check(f"the module's {tree} sibling path is {const} = {height} levels deep",
                  got == height, f"upstream={height} module={got}")

    for status, name, detail in RESULTS:
        print(f"{status}\t{name}\t{detail}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
