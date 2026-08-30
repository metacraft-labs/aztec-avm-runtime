#!/usr/bin/env bash
# verify_hydrated_roots_match_state_reference — L2 (Aztec-Live-Chain-Replay).
#
# "A root check: after hydration, the tree roots equal the block's state reference. A wrong merkle
#  root is worse than a missing one, because everything downstream believes it."
#
# ─────────────────────────────────────────────────────────────────────────────
# THE NAME IS THE MILESTONE'S AND THE ANSWER IS "NO". THAT IS THE DELIVERABLE, NOT A FAILURE.
#
# The check is kept under its original name deliberately. Renaming it to something the measurement
# is comfortable with — `verify_hydrated_roots_declared` — would be this campaign's own defect in
# its documentation: the milestone asked a question, the answer is no, and a reader looking for the
# question must find it.
#
# ALL FOUR ROOTS DIFFER, BY CONSTRUCTION AND NOT BY ERROR. Route 3 seeds the leaves ONE transaction
# reads into a tree that starts at genesis with 128 prefilled indexed leaves; the chain's trees at
# the same block hold over a million. A root is a function of every leaf.
#
# ─────────────────────────────────────────────────────────────────────────────
# SO WHAT IS THIS CHECK ACTUALLY FOR, GIVEN THAT "THE ROOTS DIFFER" IS TRIVIALLY TRUE?
#
# Three things, and the second is the one that would otherwise sink it.
#
#   §1 THE DIVERGENCE IS DECLARED, AS A VALUE THAT TRAVELS WITH THE OUTCOME. The milestone's own
#      reason applies with the sign flipped: a recording carrying the chain's state reference beside
#      an execution that ran against a genesis-anchored tree would be exactly the wrong root that
#      everything downstream believes. L3 must render this. So `declareTreeRoots` produces a
#      per-tree declaration with both sides and an `agrees` flag, and the reason is a real sentence
#      rather than a token — asserted here, because a reason nobody reads rots into a placeholder.
#
#   §2 THE TREE WAS ACTUALLY SEEDED. **THIS IS THE ASSERTION THAT MAKES THE CHECK MEAN ANYTHING.**
#      An EMPTY tree also differs from the chain. A hydration that seeded nothing, or that silently
#      stopped seeding, would satisfy every assertion in §1 and read as green forever — the exact
#      "check that never exercises what it is named for" this campaign has shipped most often. So
#      the resident roots are compared against the GENESIS roots of a fresh, unseeded module, and
#      the two indexed trees' roots must have MOVED. The note-hash and L1-to-L2 trees must NOT have
#      moved, because route 3 cannot seed them — which is the same measurement from the other side
#      and is why `UNANSWERABLE_TREES` names them.
#
#   §3 THE CONTROL: THE COMPARISON CAN SAY "AGREES". `declareTreeRoots` is handed an instance whose
#      `treeRoots()` returns the CHAIN'S OWN four roots, through the same function, and every tree
#      must come back `agrees: true`. Without it, "all four differ" is satisfied by a comparison
#      that returns false for every input — a printed literal wearing a boolean's clothes.
#
# THE INTERESTING FAILURE IS THE OTHER DIRECTION. A root that suddenly AGREED would mean either that
# `MemoryMerkleDB` had grown a bulk import (route 2 reopened, and the milestone should say so) or,
# far more likely, that the comparison had degenerated into comparing something with itself.
#
# Run: just verify-l2-roots

set -uo pipefail
TEST_NAME="verify_hydrated_roots_match_state_reference"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_l2_replay.sh"

echo "== $TEST_NAME"
l2_prepare

PROBE="$(l2_imports)
$(cat <<'EOS'

const fixture = readL2Fixture();
const settled = await l2Settled(fixture);
const host = await createNodeAvmHost(L2_MODULE_PATH);

// ---- 0. THE GENESIS ROOTS, from a module that has never been seeded --------
// Taken FIRST and from a fresh instance, so §2's "the tree moved" is a comparison against a
// measured starting point rather than against a constant somebody wrote down.
const virgin = await host.freshInstance();
const genesis = virgin.treeRoots();
const rootOf = (roots, tree) => {
  const v = roots?.[tree];
  const r = (v && typeof v === 'object' && 'root' in v) ? v.root : v;
  return r instanceof Uint8Array ? `0x${Buffer.from(r).toString('hex')}` : String(r).toLowerCase();
};
for (const tree of STATE_REFERENCE_TREES) line(`genesis.${tree}`, rootOf(genesis, tree));
line('genesis.distinct', new Set(STATE_REFERENCE_TREES.map((t) => rootOf(genesis, t))).size);
line('genesis.anyZero',
     STATE_REFERENCE_TREES.some((t) => /^0x0+$/.test(rootOf(genesis, t))) ? 'yes' : 'no');

// ---- 1. THE REPLAY, and the declaration it carries -------------------------
const real = await replaySettledTransaction(host, l2Client(fixture), settled, encodeReplayInputs);
line('real.preStateBlock', real.preStateBlock);
line('real.reproduced', real.verdict.reproduced ? 'yes' : 'no');
line('real.seedNullifiers', real.seedSize.nullifiers);
line('real.seedPublicData', real.seedSize.publicData);

const decl = real.roots;
line('roots.declarations', decl.declarations.length);
line('roots.anyAgrees', decl.anyAgrees ? 'yes' : 'no');
line('roots.trees', decl.declarations.map((d) => d.tree).join(','));
line('roots.declaredTrees', STATE_REFERENCE_TREES.join(','));
line('roots.agreeCount', decl.declarations.filter((d) => d.agrees).length);
line('roots.reasonLength', decl.reason.length);
line('roots.reasonIsTheDeclaredOne', decl.reason === TREE_ROOTS_DIVERGE_REASON ? 'yes' : 'no');
line('roots.reasonSaysByConstruction',
     decl.reason.includes('BY CONSTRUCTION') ? 'yes' : 'no');
line('roots.reasonSaysValuesAreTheChains',
     decl.reason.includes("the chain's, fetched per-slot") ? 'yes' : 'no');
line('roots.reasonWarnsDownstream',
     decl.reason.includes('everything downstream believes') ? 'yes' : 'no');

for (const d of decl.declarations) {
  line(`resident.${d.tree}`, d.resident);
  line(`chain.${d.tree}`, d.chain);
  line(`agrees.${d.tree}`, d.agrees ? 'yes' : 'no');
}
// Both sides are real values, not empty strings that trivially differ.
line('roots.residentAllHex',
     decl.declarations.every((d) => /^0x[0-9a-f]{64}$/.test(d.resident)) ? 'yes' : 'no');
line('roots.chainAllHex',
     decl.declarations.every((d) => /^0x[0-9a-f]{64}$/.test(d.chain)) ? 'yes' : 'no');
line('roots.residentDistinct', new Set(decl.declarations.map((d) => d.resident)).size);
line('roots.chainDistinct', new Set(decl.declarations.map((d) => d.chain)).size);

// The chain side is the FIXTURE'S state reference, re-read off the block data rather than off the
// declaration, so the two readings can disagree.
const state = settled.blockData.header.state;
line('block.noteHashTree', state.partial.noteHashTree.root.toString().toLowerCase());
line('block.nullifierTree', state.partial.nullifierTree.root.toString().toLowerCase());
line('block.publicDataTree', state.partial.publicDataTree.root.toString().toLowerCase());
line('block.l1ToL2MessageTree', state.l1ToL2MessageTree.root.toString().toLowerCase());

// ---- 2. THE TREE ACTUALLY MOVED — the assertion that makes this mean anything
// An empty tree also differs from the chain. These four say the seeding HAPPENED.
for (const tree of STATE_REFERENCE_TREES) {
  const before = rootOf(genesis, tree);
  const after = decl.declarations.find((d) => d.tree === tree).resident;
  line(`moved.${tree}`, before === after ? 'no' : 'yes');
}

// ---- 3. THE CONTROL: the comparison CAN say "agrees" -----------------------
// The same `declareTreeRoots`, over an instance whose roots ARE the chain's. If this does not come
// back all-agreeing, then "all four differ" above was a function that returns false for everything.
const chainRoots = {
  noteHashTree: { root: state.partial.noteHashTree.root.toString() },
  nullifierTree: { root: state.partial.nullifierTree.root.toString() },
  publicDataTree: { root: state.partial.publicDataTree.root.toString() },
  l1ToL2MessageTree: { root: state.l1ToL2MessageTree.root.toString() },
};
const controlDecl = declareTreeRoots({ treeRoots: () => chainRoots }, settled);
line('control.declarations', controlDecl.declarations.length);
line('control.anyAgrees', controlDecl.anyAgrees ? 'yes' : 'no');
line('control.agreeCount', controlDecl.declarations.filter((d) => d.agrees).length);
line('control.reasonIsTheSame', controlDecl.reason === TREE_ROOTS_DIVERGE_REASON ? 'yes' : 'no');
for (const d of controlDecl.declarations) line(`controlAgrees.${d.tree}`, d.agrees ? 'yes' : 'no');

// AND A HALF-CONTROL, because "all four agree" and "all four differ" could both be produced by a
// comparison keyed on something other than the root. One tree's root is perturbed by a single
// nibble and that tree — and only that tree — must stop agreeing.
const perturbed = { ...chainRoots, publicDataTree: { root: `0x${'0'.repeat(63)}1` } };
const halfDecl = declareTreeRoots({ treeRoots: () => perturbed }, settled);
line('half.agreeCount', halfDecl.declarations.filter((d) => d.agrees).length);
line('half.publicDataAgrees',
     halfDecl.declarations.find((d) => d.tree === 'publicDataTree').agrees ? 'yes' : 'no');
line('half.nullifierAgrees',
     halfDecl.declarations.find((d) => d.tree === 'nullifierTree').agrees ? 'yes' : 'no');

// ---- 4. THE TREES ROUTE 3 CANNOT SEED, named rather than silent -------------
line('unanswerable.count', Object.keys(UNANSWERABLE_TREES).length);
line('unanswerable.allHaveReasons',
     Object.values(UNANSWERABLE_TREES).every((r) => typeof r === 'string' && r.length > 60)
       ? 'yes' : 'no');
line('answerable.count', ANSWERABLE_TREES.length);
line('answerable.ids', ANSWERABLE_TREES.join(','));
line('trees.disjoint',
     ANSWERABLE_TREES.some((id) => id in UNANSWERABLE_TREES) ? 'no' : 'yes');
line('trees.total', ANSWERABLE_TREES.length + Object.keys(UNANSWERABLE_TREES).length);

line('l2.done', 1);
EOS
)"

OUT="$L2_WORK/probes/l2roots.out"
L0_PROBE_TIMEOUT="${L0_PROBE_TIMEOUT:-600}" l0_run_probe l2roots "$PROBE" "$OUT" l2.done
f() { l0_field "$OUT" "$1"; }
j() { l1_json "$L2_FIXTURE" "$1"; }

# ---------------------------------------------------------------------------
echo "== 1. the answer is NO, and it is DECLARED rather than discovered"
# ---------------------------------------------------------------------------
assert_eq "all four state-reference trees are declared" "4" "$(f roots.declarations)"
assert_eq "…by the names the module declares, not names the check supplied" \
  "$(f roots.declaredTrees)" "$(f roots.trees)"

assert_eq "NO TREE'S ROOT AGREES WITH THE BLOCK'S STATE REFERENCE" "no" "$(f roots.anyAgrees)"
assert_eq "…which is zero of four" "0" "$(f roots.agreeCount)"
assert_eq "…the note hash tree" "no" "$(f agrees.noteHashTree)"
assert_eq "…the nullifier tree" "no" "$(f agrees.nullifierTree)"
assert_eq "…the public data tree" "no" "$(f agrees.publicDataTree)"
assert_eq "…and the L1-to-L2 message tree" "no" "$(f agrees.l1ToL2MessageTree)"

# BOTH SIDES ARE REAL. Two empty strings also "differ".
assert_eq "every resident root is a 32-byte hex field element" "yes" "$(f roots.residentAllHex)"
assert_eq "…and every chain root is too" "yes" "$(f roots.chainAllHex)"
assert_eq "the four resident roots are four DISTINCT values, not one repeated" "4" \
  "$(f roots.residentDistinct)"
assert_eq "…and so are the four chain roots" "4" "$(f roots.chainDistinct)"

# The chain side is read TWICE, once through the declaration and once off the block data.
assert_eq "the declared chain note-hash root is the block's" "$(f block.noteHashTree)" \
  "$(f chain.noteHashTree)"
assert_eq "…the nullifier root" "$(f block.nullifierTree)" "$(f chain.nullifierTree)"
assert_eq "…the public data root" "$(f block.publicDataTree)" "$(f chain.publicDataTree)"
assert_eq "…and the L1-to-L2 root" "$(f block.l1ToL2MessageTree)" "$(f chain.l1ToL2MessageTree)"
# …and a THIRD time, off the fixture's recorded provenance, which nothing in the probe touched.
assert_eq "…and the fixture's own provenance agrees about the public data root" \
  "$(j "d['provenance']['nodeReported']['stateReference']['publicDataTreeRoot']")" \
  "$(f chain.publicDataTree)"

# THE REASON IS CARRIED, because L3 has to render it.
assert_eq "the divergence carries the DECLARED reason and not one assembled on the spot" "yes" \
  "$(f roots.reasonIsTheDeclaredOne)"
assert_ge "…which is a real sentence rather than a token" 400 "$(f roots.reasonLength)"
assert_eq "…saying the divergence is BY CONSTRUCTION" "yes" "$(f roots.reasonSaysByConstruction)"
assert_eq "…saying what IS faithful: the values are the chain's, per-slot" "yes" \
  "$(f roots.reasonSaysValuesAreTheChains)"
assert_eq "…and warning the consumer, in the milestone's own words" "yes" \
  "$(f roots.reasonWarnsDownstream)"

# ---------------------------------------------------------------------------
echo "== 2. AND THE TREE WAS ACTUALLY SEEDED — an empty tree also differs"
#
# This is the section that makes the check mean anything. Every assertion in §1 is satisfied by a
# hydration that seeded nothing at all.
# ---------------------------------------------------------------------------
assert_eq "the genesis roots are four distinct values, so a fresh module is a real starting point" \
  "4" "$(f genesis.distinct)"
assert_eq "…and none of them is zero" "no" "$(f genesis.anyZero)"

assert_eq "THE NULLIFIER TREE MOVED, so nullifiers really were seeded into it" "yes" \
  "$(f moved.nullifierTree)"
assert_eq "…and the PUBLIC DATA TREE moved, so leaves really were seeded into it" "yes" \
  "$(f moved.publicDataTree)"
assert_ge "…four nullifiers' worth" 4 "$(f real.seedNullifiers)"
assert_ge "…and eleven leaves' worth" 11 "$(f real.seedPublicData)"

# The other half of the same measurement: route 3 CANNOT seed the append-only trees, so their roots
# must be exactly the genesis ones. A tree that moved here would mean the seeding reached somewhere
# `UNANSWERABLE_TREES` says it cannot.
assert_eq "the note hash tree did NOT move, because route 3 cannot seed an append-only tree" "no" \
  "$(f moved.noteHashTree)"
assert_eq "…nor did the L1-to-L2 message tree, for the same reason" "no" \
  "$(f moved.l1ToL2MessageTree)"
assert_eq "…so the note-hash root is still genesis's exactly" "$(f genesis.noteHashTree)" \
  "$(f resident.noteHashTree)"
assert_eq "…and the L1-to-L2 root is too" "$(f genesis.l1ToL2MessageTree)" \
  "$(f resident.l1ToL2MessageTree)"

# And the run this is measured over is the one that reproduced, not some other run.
assert_eq "the replay these roots came from is the one that reproduced the published effects" \
  "yes" "$(f real.reproduced)"
assert_eq "…reading its pre-state at the parent block" \
  "$(( $(j "d['provenance']['l2BlockNumber']") - 1 ))" "$(f real.preStateBlock)"

# ---------------------------------------------------------------------------
echo "== 3. THE CONTROL: the comparison CAN say 'agrees'"
#
# Without this, "all four differ" is satisfied by a function that returns false for every input.
# ---------------------------------------------------------------------------
assert_eq "handed the chain's OWN roots, the same function declares four trees" "4" \
  "$(f control.declarations)"
assert_eq "…and says they AGREE" "yes" "$(f control.anyAgrees)"
assert_eq "…all four of them" "4" "$(f control.agreeCount)"
assert_eq "…the note hash tree" "yes" "$(f controlAgrees.noteHashTree)"
assert_eq "…the nullifier tree" "yes" "$(f controlAgrees.nullifierTree)"
assert_eq "…the public data tree" "yes" "$(f controlAgrees.publicDataTree)"
assert_eq "…and the L1-to-L2 message tree" "yes" "$(f controlAgrees.l1ToL2MessageTree)"
assert_eq "…carrying the same reason, because the reason is about the ROUTE and not the outcome" \
  "yes" "$(f control.reasonIsTheSame)"

# THE HALF-CONTROL: one nibble changed in one tree moves that tree and nothing else.
assert_eq "perturbing ONE root by one nibble leaves exactly three agreeing" "3" \
  "$(f half.agreeCount)"
assert_eq "…the perturbed tree stops agreeing" "no" "$(f half.publicDataAgrees)"
assert_eq "…and its neighbour is untouched, so the comparison is per-tree and not global" "yes" \
  "$(f half.nullifierAgrees)"

# ---------------------------------------------------------------------------
echo "== 4. the trees route 3 cannot reach are NAMED, not silent"
# ---------------------------------------------------------------------------
assert_eq "two trees are answerable" "2" "$(f answerable.count)"
assert_eq "…the nullifier tree (0) and the public data tree (2)" "0,2" "$(f answerable.ids)"
assert_eq "three are not, each with a reason" "3" "$(f unanswerable.count)"
assert_eq "…and every reason is a real sentence rather than a placeholder" "yes" \
  "$(f unanswerable.allHaveReasons)"
assert_eq "the two sets are disjoint" "yes" "$(f trees.disjoint)"
assert_eq "…and together they are the five trees, exhaustively" "5" "$(f trees.total)"

finish
