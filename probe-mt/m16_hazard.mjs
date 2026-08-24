// _fallback_hazard.mjs — re-derive M16's recorded hazard rather than quote it.
//
// M16's third deliverable records "the known hazard ... with its target values so the switch does
// not rediscover it": the deleted `@aztec/merkle-tree` package hashes internal nodes as
// `poseidon2([lhs, rhs])` where the protocol hashes them as `poseidon2([SEP, lhs, rhs])`, so the
// empty NOTE_HASH_TREE at depth 42 comes out `0x2ac5dda1…` from the package and `0x2590f2aa…`
// natively.
//
// Two of those values could be copied forward from the milestone text and would then agree with
// themselves forever. Neither is. This script produces:
//
//   * the package's OWN empty root, by constructing a `StandardTree` at NOTE_HASH_TREE_HEIGHT and
//     asking it — not by re-implementing its hash, which would only prove the re-implementation
//     matches the milestone;
//   * the undomained recurrence, so the package's answer is explained rather than merely observed;
//   * the domained recurrence, with the separator READ OUT OF `@aztec/constants` rather than
//     typed here;
//   * both chains at level 0 and level 1, which is where "sibling paths diverge from level 1
//     upward" is decided. Level 0 is the control: the two chains MUST agree there, or the
//     divergence claim is about something else.
//
// It prints `key=value` on stdout and asserts nothing. Exits non-zero only if it could not
// measure.

import { poseidon2Hash } from '@aztec/foundation/crypto/sync';
import { Fr } from '@aztec/foundation/curves/bn254';
import { NOTE_HASH_TREE_HEIGHT, L1_TO_L2_MSG_TREE_HEIGHT, ARCHIVE_HEIGHT, DomainSeparator } from '@aztec/constants';
import { openTmpStore } from '@aztec/kv-store/lmdb-v2';
import { Poseidon, StandardTree, newTree } from '@aztec/merkle-tree';

const out = [];
const emit = (k, v) => out.push(`${k}=${v}`);

// The separators, read from the package rather than restated. `DomainSeparator` is the TypeScript
// spelling of the same generated table whose C++ arm emits `#define DOM_SEP__<KEY>`; M16's
// deliverable names the C++ spelling.
emit('sep.MERKLE_HASH', DomainSeparator.MERKLE_HASH);
emit('sep.NULLIFIER_MERKLE', DomainSeparator.NULLIFIER_MERKLE);
emit('sep.PUBLIC_DATA_MERKLE', DomainSeparator.PUBLIC_DATA_MERKLE);
emit('height.NOTE_HASH_TREE', NOTE_HASH_TREE_HEIGHT);
emit('height.L1_TO_L2_MSG_TREE', L1_TO_L2_MSG_TREE_HEIGHT);
emit('height.ARCHIVE', ARCHIVE_HEIGHT);

// --- the two recurrences ----------------------------------------------------
const undomainedChain = (depth) => {
  const levels = [Fr.ZERO];
  let cur = Fr.ZERO;
  for (let i = 0; i < depth; i++) {
    cur = poseidon2Hash([cur, cur]);
    levels.push(cur);
  }
  return levels;
};
const domainedChain = (sep, depth) => {
  const levels = [Fr.ZERO];
  let cur = Fr.ZERO;
  for (let i = 0; i < depth; i++) {
    cur = poseidon2Hash([new Fr(BigInt(sep)), cur, cur]);
    levels.push(cur);
  }
  return levels;
};

const und = undomainedChain(NOTE_HASH_TREE_HEIGHT);
const dom = domainedChain(DomainSeparator.MERKLE_HASH, NOTE_HASH_TREE_HEIGHT);

emit('chain.undomained.level0', und[0].toString());
emit('chain.undomained.level1', und[1].toString());
emit('chain.undomained.d42', und[NOTE_HASH_TREE_HEIGHT].toString());
emit('chain.domained.level0', dom[0].toString());
emit('chain.domained.level1', dom[1].toString());
emit('chain.domained.d42', dom[NOTE_HASH_TREE_HEIGHT].toString());
emit('chain.domained.d36', domainedChain(DomainSeparator.MERKLE_HASH, L1_TO_L2_MSG_TREE_HEIGHT)[L1_TO_L2_MSG_TREE_HEIGHT].toString());

// The first level at which the two chains differ. Computed rather than asserted, so "from level 1
// upward" is a reading and not a restatement.
let firstDivergence = -1;
for (let i = 0; i <= NOTE_HASH_TREE_HEIGHT; i++) {
  if (und[i].toString() !== dom[i].toString()) { firstDivergence = i; break; }
}
emit('chain.first_divergence_level', firstDivergence);
let agreeAbove = 0;
for (let i = firstDivergence; i <= NOTE_HASH_TREE_HEIGHT && firstDivergence >= 0; i++) {
  if (und[i].toString() === dom[i].toString()) agreeAbove++;
}
emit('chain.levels_agreeing_at_or_above_divergence', agreeAbove);

// --- the package's own answer ----------------------------------------------
const store = await openTmpStore('m16-fallback-hazard');
try {
  const hasher = new Poseidon();
  const tree = await newTree(StandardTree, store, hasher, 'note_hash', Fr, NOTE_HASH_TREE_HEIGHT);
  emit('package.empty_note_hash_root', '0x' + tree.getRoot(true).toString('hex'));
  const l1 = await newTree(StandardTree, store, hasher, 'l1tol2', Fr, L1_TO_L2_MSG_TREE_HEIGHT);
  emit('package.empty_l1_to_l2_root', '0x' + l1.getRoot(true).toString('hex'));
  // The package at ARCHIVE_HEIGHT, which is the height `foundation/src/trees/merkle_tree.ts`
  // cannot reach: it enforces 2 ** (height + 1) - 1 nodes in its constructor. This one is
  // key-value backed, so it constructs. Measured because it is the one respect in which the
  // fallback is stronger than the thing BOUNDARY-SHAPE.md §4 rejects, and a price that omitted it
  // would be wrong in our favour.
  const archive = await newTree(StandardTree, store, hasher, 'archive', Fr, ARCHIVE_HEIGHT);
  emit('package.empty_archive_root', '0x' + archive.getRoot(true).toString('hex'));
  emit('package.constructs_at_archive_height', 1);
} finally {
  await store.close();
}

process.stdout.write(out.join('\n') + '\n');
process.exitCode = 0;
