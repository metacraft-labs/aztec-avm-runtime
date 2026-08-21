// Tier D capture — the world-state root oracle.
//
// WHAT THIS SCRIPT MAY CAPTURE, AND WHAT IT MAY NOT.
//
// Upstream ships golden roots. It ships them in more places than this campaign originally
// believed, and a captured "vector" that merely restates a value already checked in upstream is
// worse than no vector at all: it looks like independent evidence and is not. So this script is
// deliberately split into two sections, and the split is enforced by
// `verification/test_world_state_golden_vectors_regenerate.sh`:
//
//   upstreamPublished  — every value here MUST also appear in the aztec-packages fork at the
//                        recorded anchor, at the recorded path. It is captured only so that the
//                        checker can compare our world state against upstream's own published
//                        constant. The checker re-reads the upstream side from `git show` on every
//                        run, so a re-pin that moves a constant fails loudly.
//
//   captured           — every root here MUST NOT appear anywhere in the fork at the anchor.
//                        This is the part upstream genuinely does not provide: the mutation
//                        sequence past its single published post-genesis step, the 42-level zero
//                        sibling path, the 256 genesis prefill leaf preimages, and the roots after
//                        a checkpoint/revert cycle.
//
// The oracle is Aztec's own production world state (`NativeWorldStateService`, the native LMDB
// service behind `@aztec/world-state`), not a reference implementation of ours. M8 and M14 assert
// the wasm `MemoryMerkleDB` against this file.
//
// Run:  cd drift && node capture_world_state.mjs > ../fixtures/trees/world-state-vectors.json
//
// It lives in `drift/` rather than beside its output because that is the tree pinned to
// `npm.current` — the nightly that corresponds to the `cpp` anchor whose published constants the
// checker compares this capture against. Running it against `npm.deletion_era` would compare a
// June world state with an August constant and call the agreement evidence.

import { NativeWorldStateService } from '@aztec/world-state';
import { MerkleTreeId, PublicDataTreeLeaf, merkleTreeIds } from '@aztec/stdlib/trees';
import { Fr } from '@aztec/foundation/curves/bn254';
import { poseidon2HashWithSeparator } from '@aztec/foundation/crypto/poseidon';

// DOM_SEP__MERKLE_HASH, `constants.nr`. Restated here ONLY as the input to the independent
// recurrence below; nothing in the captured state depends on it.
const DOM_SEP__MERKLE_HASH = 2982624097;

const hex = b => '0x' + Buffer.from(b).toString('hex');

const snapshot = async fork => {
  const out = {};
  for (const id of merkleTreeIds()) {
    const info = await fork.getTreeInfo(id);
    out[MerkleTreeId[id]] = { depth: info.depth, size: info.size.toString(), root: hex(info.root) };
  }
  return out;
};

const svc = await NativeWorldStateService.tmp();

// ---------------------------------------------------------------------------
// Section 1 — the genesis state, which upstream publishes.
// ---------------------------------------------------------------------------
const genesisFork = await svc.fork();
const genesis = await snapshot(genesisFork);

// ---------------------------------------------------------------------------
// Section 2 — the scripted mutation sequence.
//
// Step 1 is NOT ours. It is upstream's own `WorldStateTest.SyncExternalBlockFromEmpty`
// (`barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp`), whose expected
// `StateReference` — note hash 42, L1->L2 message 43, nullifier 144, public data write (145, 1) —
// is checked in upstream as four hardcoded roots at sizes 129/1/129/1. Reproducing it here is what
// anchors the whole sequence to something upstream asserts, rather than to our own capture. The
// checker requires step 1 to equal the constants it reads out of that C++ test.
//
// Steps 2..8 go past it. Nothing upstream publishes a root for any of them.
// ---------------------------------------------------------------------------
const NH = MerkleTreeId.NOTE_HASH_TREE;
const NF = MerkleTreeId.NULLIFIER_TREE;
const PD = MerkleTreeId.PUBLIC_DATA_TREE;
const L1 = MerkleTreeId.L1_TO_L2_MESSAGE_TREE;

const steps = [
  {
    n: 1,
    name: 'upstream SyncExternalBlockFromEmpty',
    upstreamAnchored: true,
    what: 'one leaf into each of the four trees, exactly as upstream WorldStateTest.SyncExternalBlockFromEmpty does',
    apply: async f => {
      await f.appendLeaves(NH, [new Fr(42n)]);
      await f.appendLeaves(L1, [new Fr(43n)]);
      await f.sequentialInsert(NF, [new Fr(144n).toBuffer()]);
      await f.sequentialInsert(PD, [new PublicDataTreeLeaf(new Fr(145n), new Fr(1n)).toBuffer()]);
    },
  },
  {
    n: 2,
    name: 'append-only batch',
    upstreamAnchored: false,
    what: 'three note hashes appended in one call — the append-only path with a non-unit batch',
    apply: async f => {
      await f.appendLeaves(NH, [new Fr(1n), new Fr(2n), new Fr(3n)]);
    },
  },
  {
    n: 3,
    name: 'indexed insert, ascending',
    upstreamAnchored: false,
    what: 'two nullifiers above every existing key — low-leaf linkage extends at the tail',
    apply: async f => {
      await f.sequentialInsert(NF, [new Fr(200n).toBuffer(), new Fr(201n).toBuffer()]);
    },
  },
  {
    n: 4,
    name: 'indexed insert, interleaved',
    upstreamAnchored: false,
    what: 'a nullifier BETWEEN two existing keys — the case that rewrites an existing low leaf rather than appending past it, and the one an implementation with correct hashing but wrong linkage gets wrong',
    apply: async f => {
      await f.sequentialInsert(NF, [new Fr(150n).toBuffer()]);
    },
  },
  {
    n: 5,
    name: 'public data update in place',
    upstreamAnchored: false,
    what: 'slot 145, written in step 1, rewritten from value 1 to value 999. Measured: the tree does NOT grow (129 leaves before and after) — the existing leaf is rewritten and only the path above it rehashes. This separates the update path from the insert path below, which is exactly the pair an implementation can get half right',
    apply: async f => {
      await f.sequentialInsert(PD, [new PublicDataTreeLeaf(new Fr(145n), new Fr(999n)).toBuffer()]);
    },
  },
  {
    n: 6,
    name: 'public data insert past the tail',
    upstreamAnchored: false,
    what: 'slot 500, above every key present (the genesis prefill occupies slots 0..127 and step 1 added 145). Measured: the tree grows. Insertion, not update',
    apply: async f => {
      await f.sequentialInsert(PD, [new PublicDataTreeLeaf(new Fr(500n), new Fr(1234n)).toBuffer()]);
    },
  },
  {
    n: 7,
    name: 'public data insert, interleaved',
    upstreamAnchored: false,
    what: 'slot 300, between 145 and 500 — the public-data mirror of step 4: the insert must rewrite an existing low leaf rather than append past the tail',
    apply: async f => {
      await f.sequentialInsert(PD, [new PublicDataTreeLeaf(new Fr(300n), new Fr(5678n)).toBuffer()]);
    },
  },
  {
    n: 8,
    name: 'l1-to-l2 batch',
    upstreamAnchored: false,
    what: 'two L1->L2 messages, so the fourth tree moves more than once in the sequence',
    apply: async f => {
      await f.appendLeaves(L1, [new Fr(50n), new Fr(51n)]);
    },
  },
];

// The ARCHIVE tree is deliberately NOT mutated here. Advancing it requires a full `BlockHeader`
// (`updateArchive(header)`), which is block-level rather than tree-level, and block-0 / archive
// semantics are M14's subject. Its genesis root is still asserted against upstream's
// GENESIS_ARCHIVE_ROOT, and the sequence records it unchanged at every step so a spurious archive
// mutation would show up rather than pass unnoticed.

const mutationFork = await svc.fork();
const mutationSequence = [];
for (const step of steps) {
  await step.apply(mutationFork);
  mutationSequence.push({
    step: step.n,
    name: step.name,
    what: step.what,
    upstreamAnchored: step.upstreamAnchored,
    trees: await snapshot(mutationFork),
  });
}

// ---------------------------------------------------------------------------
// Section 3 — checkpoint / revert.
//
// `ContractDBInterface` and `LowLevelMerkleDBInterface` each carry an independent
// create/commit/revert, and M13's whole risk is that they drift apart. The tree half of that is
// checkable here and now: a checkpoint, a mutation inside it, a revert, and the requirement that
// every root returns to exactly the value it had before the checkpoint. Upstream's own
// checkpoint tests (`public_processor.test.ts`) assert against a mock and therefore pin the call
// sequence but no root at all.
// ---------------------------------------------------------------------------
const beforeCheckpoint = await snapshot(mutationFork);
await mutationFork.createCheckpoint();
await mutationFork.appendLeaves(NH, [new Fr(0xdeadn)]);
await mutationFork.sequentialInsert(NF, [new Fr(0xbeefn).toBuffer()]);
const insideCheckpoint = await snapshot(mutationFork);
await mutationFork.revertCheckpoint();
const afterRevert = await snapshot(mutationFork);

// ---------------------------------------------------------------------------
// Section 4 — the structural detail no upstream vector covers: the zero sibling path and the
// genesis prefill leaf preimages with their indexed-tree linkage.
// ---------------------------------------------------------------------------
const noteHashZeroSiblingPath = (await genesisFork.getSiblingPath(NH, 0n)).toFields().map(f => f.toString());

const dumpLeaves = async (treeId, n) => {
  const leaves = [];
  for (let i = 0n; i < BigInt(n); i++) {
    const pre = await genesisFork.getLeafPreimage(treeId, i);
    leaves.push(
      pre === undefined
        ? null
        : JSON.parse(JSON.stringify(pre, (_k, v) => (typeof v === 'bigint' ? v.toString() : v))),
    );
  }
  return leaves;
};

// ---------------------------------------------------------------------------
// Section 5 — the empty-tree-root recurrence.
//
// Upstream publishes empty balanced-merkle roots at heights 1, 2, 6 and 10
// (`types/src/merkle_tree/root.nr::test_empty_tree_root`, generated from
// `foundation/src/trees/balanced_merkle_tree_root.test.ts`), and separately publishes the genesis
// note-hash root at height 42 and the genesis L1->L2 root at height 36
// (`world_state.test.cpp`). Those are two unrelated upstream publications. Iterating the single
// recurrence h(n) = poseidon2([h(n-1), h(n-1)], DOM_SEP__MERKLE_HASH) from zero links them: it must
// hit all four published small heights on the way and land exactly on the two published genesis
// roots. Captured at every height so the checker can compare both ends against upstream.
// ---------------------------------------------------------------------------
const emptyRootByHeight = {};
{
  let node = Fr.ZERO;
  for (let h = 1; h <= 42; h++) {
    node = await poseidon2HashWithSeparator([node, node], DOM_SEP__MERKLE_HASH);
    emptyRootByHeight[h] = node.toString();
  }
}

const out = {
  note:
    'Tier D world-state root vectors. Sections marked upstreamPublished MUST agree with the ' +
    'aztec-packages fork at anchor `cpp`; sections marked captured MUST NOT appear there. ' +
    'Regenerate with: cd drift && node capture_world_state.mjs > ../fixtures/trees/world-state-vectors.json',
  oracle: '@aztec/world-state NativeWorldStateService (the native LMDB production world state)',
  generator: 'drift/capture_world_state.mjs',
  licence: 'Apache-2.0 — output of upstream Apache-2.0 code; see fixtures/CORPUS.md',

  upstreamPublished: {
    note: 'Every value below is also checked in upstream. Recorded so the checker can compare, not as evidence of its own.',
    genesisTrees: genesis,
    genesisStateReference: JSON.parse(JSON.stringify(await genesisFork.getStateReference())),
    postGenesisStep1: mutationSequence[0].trees,
    emptyRootsAtPublishedHeights: {
      1: emptyRootByHeight[1],
      2: emptyRootByHeight[2],
      6: emptyRootByHeight[6],
      10: emptyRootByHeight[10],
    },
  },

  captured: {
    note: 'Upstream publishes no vector for any of this.',
    mutationSequence: mutationSequence.slice(1),
    checkpoint: {
      what: 'create a checkpoint, mutate the note-hash and nullifier trees inside it, revert, and require every root to return exactly',
      beforeCheckpoint,
      insideCheckpoint,
      afterRevert,
    },
    noteHashZeroSiblingPath,
    genesisPrefill: {
      NULLIFIER_TREE: await dumpLeaves(NF, 128),
      PUBLIC_DATA_TREE: await dumpLeaves(PD, 128),
    },
  },

  derived: {
    note: 'The empty-tree-root recurrence, captured at every height so both ends can be compared against two unrelated upstream publications.',
    domainSeparator: DOM_SEP__MERKLE_HASH,
    emptyRootByHeight,
  },
};

process.stdout.write(JSON.stringify(out, null, 2) + '\n');
await svc.close();
