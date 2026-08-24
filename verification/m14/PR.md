# Give the in-memory reference world state its archive tree

**Upstream project:** Aztec (AztecProtocol/aztec-packages)
**Kind:** feature / test coverage — not a defect report. Offered on its own merits.
**Status:** READY TO REVIEW — not filed, no upstream PR URL yet. Filing needs a published
branch and a person's command; see "Filing" below.
**Base commit:** `233d8e0993` (v5.2.0 era, 2026-08).
**Patch:** `0001-feat-world_state_reference-archive-tree-so-the-in-me.patch` — 3 files,
+352 / −10. Applies cleanly to `233d8e0993` with `git am`.
**Order in the series:** sixth, and independent of the other five. It touches
`world_state_reference/memory_merkle_db.{hpp,cpp}` and `world_state/memory_merkle_db.test.cpp`;
the only overlap with any other prepared patch is patch 5's narrowing correction in
`world_state_reference/memory_merkle_db.hpp`, at different lines.

Suggested PR title:

> `feat(world_state_reference): archive tree, so the in-memory reference covers every tree the WorldState has`

The commit message in the patch is written for an upstream audience and works as the PR body
unchanged.

## The gap, in one line of a test file

`barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp` is the
canonical-fidelity gate for `world_state::MemoryMerkleDB`. Its own header comment says so:

> It drives an ephemeral, file-backed `world_state::WorldState` and an in-memory
> `MemoryMerkleDB` through an identical sequence of operations … and asserts, after every
> step, that the two agree … WorldState is the source of truth for the AVM trees;
> MemoryMerkleDB exists to reproduce it in memory for the differential fuzzer, so any
> divergence here is a MemoryMerkleDB bug.

It builds the WorldState with five trees:

```cpp
std::unordered_map<MerkleTreeId, uint32_t> tree_heights{
    { MerkleTreeId::NULLIFIER_TREE, NULLIFIER_TREE_HEIGHT },
    { MerkleTreeId::NOTE_HASH_TREE, NOTE_HASH_TREE_HEIGHT },
    { MerkleTreeId::PUBLIC_DATA_TREE, PUBLIC_DATA_TREE_HEIGHT },
    { MerkleTreeId::L1_TO_L2_MESSAGE_TREE, L1_TO_L2_MSG_TREE_HEIGHT },
    { MerkleTreeId::ARCHIVE, ARCHIVE_HEIGHT },
};
```

and compares four of them. `expect_roots_equal()` calls `check_snapshot` four times.

The archive is not an oversight in the comparison so much as an absence in the class:
`MemoryMerkleDB::State` holds four trees, `TreeRoots` has four members, and every method that
takes a `MerkleTreeId` throws for `ARCHIVE`. So the gate cannot compare a fifth tree, and a
fidelity gate that omits a tree the real implementation has is a weaker gate than it looks.

## What the archive needs turns out to be what the class already has

The archive is the append-only tree of block-header hashes. Three facts make it a small
addition rather than a new tree implementation:

1. **It shares its hash policy with the trees already there.** `world_state/fork.hpp` records
   it in a comment — "Append-only trees (note-hash, L1->L2 message, archive) share the
   baseline merkle separator" — and `AppendOnlyHashPolicy` is `aztec::AztecMerkleHashPolicy`.
   So the archive is one more
   `MemoryAppendOnlyTree<aztec::AztecMerkleHashPolicy>` at `ARCHIVE_HEIGHT`, the same template
   the class already instantiates for the note-hash and L1->L2 trees.

2. **Its genesis is one leaf, and it is computable.** `WorldState`'s canonical fork seeds the
   archive with `compute_initial_block_header_hash(get_state_reference(...), generator_point,
   genesis_timestamp)`, a twenty-three field Poseidon2 hash over the four other trees'
   snapshots. `MemoryMerkleDB` has those four snapshots the moment its constructor's
   initialiser list has run, so it computes the same value rather than storing it. The new
   test asserts that it reproduces `GENESIS_BLOCK_HEADER_HASH` and that the resulting root is
   `GENESIS_ARCHIVE_ROOT` — derived, so a change to any of the four trees moves it instead of
   silently agreeing with a copied constant.

3. **Checkpointing is free if it goes in the right place.** `create_checkpoint` pushes a copy
   of `State` and `revert_checkpoint` assigns it back, so putting the archive in `State` makes
   a reverted block put the archive back with the trees. The alternative — an archive beside
   `State` — would leave a reverted block's header hash in the archive, certifying a state
   that was rolled back, while every root involved still looked well-formed.

`update_archive(block_state_ref, block_header_hash)` comes with it, carrying
`WorldState::update_archive`'s check and its exact message. `TreeRoots::state_reference_equals()`
is that comparison, kept separate from `operator==` because a block header carries the four
`StateReference` trees and not the fifth.

## The AVM is untouched, deliberately

`MerkleTreeId::ARCHIVE` appears under `vm2/` exactly once outside tests, in a tree-name switch
in `simulation/lib/raw_data_dbs.cpp`. And `vm2/common/aztec_types.hpp`'s `TreeSnapshots` — what
`LowLevelMerkleDBInterface::get_tree_roots()` returns, what `MSGPACK_CAMEL_CASE_FIELDS`
serialises, and what `set_snapshot_in_cols` writes into the trace — has four members.

So the archive is deliberately **not** part of the vm2 adapter's `LowLevelMerkleDBInterface`
surface. Adding it there would be an ABI and circuit change; adding it here is not. The adapter
reads four named fields out of `TreeRoots` and continues to.

## The prefill constants, stated in the form they are derived in

A second, smaller change in the same patch. At the base commit:

```cpp
// Genesis prefill counts for the indexed trees. These match the values the WorldState is
// initialized with in the fuzzer.
static constexpr size_t DEFAULT_NULLIFIER_TREE_PREFILL = 128;
static constexpr size_t DEFAULT_PUBLIC_DATA_TREE_PREFILL = 128;
```

They match more than the fuzzer. `yarn-project/world-state/src/world-state-db/merkle_tree_db.ts`
defines `INITIAL_NULLIFIER_TREE_SIZE = 2 * MAX_NULLIFIERS_PER_TX` and
`INITIAL_PUBLIC_DATA_TREE_SIZE = 2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX`, and both
protocol constants are 64. The fuzzer passes 128 because the protocol says 128.

Written as `2 * MAX_NULLIFIERS_PER_TX`, a change to either protocol constant moves the
reference's genesis together with the production world state's, instead of leaving a literal to
be noticed later.

## Verification performed

`./verify.sh`, with `AZTEC` pointing at a patched checkout and `AZTEC_REF` at an unpatched one.

**Part A — the gate itself.** `world_state_tests` is built and
`MemoryMerkleDBEquivalenceTest.*` is run. Seven cases at the base commit, twelve with the
patch, compared as **name sets** rather than as counts so a rename is visible. All twelve pass;
the seven that existed before pass on both sides. The five added are:

- `GenesisArchiveMatchesPublishedConstants` — the archive genesis against `GENESIS_ARCHIVE_ROOT`,
  against `GENESIS_BLOCK_HEADER_HASH`, and against the real `WorldState`, plus the recomputation
  from the four snapshots
- `UpdateArchiveMatchesWorldState` — three blocks, each after real mutations to the other four
  trees, compared on root, size, sibling path and leaf value, with the archive size required to
  land on block number + 1 (the invariant `lightweight_checkpoint_builder.ts` checks after every
  `updateArchive`)
- `UpdateArchiveRejectsMismatchedStateReference` — the refusal, and then the same call with the
  current state reference accepted, so the refusal is about the argument
- `ArchiveThroughTreeIdDispatch` — the archive reached through `append_leaves(ARCHIVE, …)`, with
  `pad_tree` and `get_low_indexed_leaf` still refusing it
- `ArchiveParticipatesInCheckpoints` — create, mutate, revert, and create, mutate, commit, with
  the inside state required to DIFFER so the restore is not a comparison of two copies of one
  value

And `expect_roots_equal()` now compares five snapshots, which puts the archive under the seven
pre-existing cases as well.

**Part B — nothing else moves.** `vm2_tests` declares **1,803** tests at this commit, with and
without the patch, with an **identical name set** (md5 of the sorted list) and an identical set
of passes. Every other suite in `world_state_tests` is unchanged by name; the only difference in
that binary's case list is the five above, taken as the difference of two sorted name sets.
Neither `vm2/` nor `avm_fuzzer/` is touched by the patch.

**Part C — it is still the dependency-free component.** The module declaration
`barretenberg_module(world_state_reference crypto_merkle_tree aztec crypto_poseidon2)` is
untouched, and the patch adds exactly one include — `barretenberg/aztec/aztec_constants.hpp`,
already reached transitively through the hash policy. No lmdb, no thread pool, no vm2, no ipc.

**Mutation controls.** Four mutations, each changing behaviour: moving the genesis timestamp
from 0 to 1 fails all twelve cases; removing `update_archive`'s state-reference check fails
exactly `UpdateArchiveRejectsMismatchedStateReference`; making the archive append a no-op fails
all twelve; restoring the archive outside the checkpointed `State` fails exactly
`ArchiveParticipatesInCheckpoints`. Recorded because the first round of them found a hole in
this patch's own tests — with eleven cases, the no-op mutation passed all eleven, because
`update_archive` was writing to the tree directly and the `ARCHIVE` dispatch arms were dead. The
patch routes every archive write through one path and adds the twelfth case for it.

## Prior art searched

Searched on 2026-08-24, `AztecProtocol/aztec-packages`, for open and closed issues and pull
requests mentioning `world_state_reference`, `MemoryMerkleDB`, `memory_merkle_db`, and
"reference world state" together with "archive". Nothing found proposing this. The component
itself is recent — `94d004c56b` (2026-08-04) introduced it, two weeks before the base commit —
so its coverage gaps are more likely to be unfinished than deliberate. Worth re-running this
search before filing.

## Cost, stated plainly

Constructing a `MemoryMerkleDB` now also builds a depth-30 sparse tree and computes one
twenty-three-input Poseidon2 hash plus the thirty pair-hashes up to the root. Every checkpoint
deep-copies one more tree. For the fuzzer that is a per-input cost, and it is real; the
alternative is a reference that does not reproduce the world state it is checked against.

If the deep copy is a concern, it is a concern the class already has — checkpoints copy the
whole state today — and it is worth its own change rather than a reason to leave a tree out.

## Why we care

We are compiling the AVM and this reference world state to WebAssembly for a browser-capable
Aztec execution runtime, and block production needs an archive root for every block header.
`world_state::WorldState` has the archive and links LMDB and a thread pool, so it cannot come
with us; this component can. That is our reason for writing the patch. It is not the reason to
take it — the reason to take it is that the fidelity gate stops omitting a tree.

## Filing

Not filed, and these three files are deliberately NOT in
`codetracer-specs/upstream-bugs/` yet. That directory is the carry set, and it is enumerated:
`verify_carry_set_complete` requires every `aztec-*` entry in it to appear in `carry/series.json`,
and `verify_pr_branches_match_patches` then requires every carry-set entry to equal a branch
**published on our fork's origin**, asserting six branch identities as a count. Moving these files
there before a branch exists would turn a green check red, on a check that is right to be red.

So promoting this to the sixth prepared contribution is four steps, and all four belong to a person
with push rights: `git mv` this directory's three files into
`codetracer-specs/upstream-bugs/aztec-world-state-reference-block-coverage/`, add a sixth entry to
`carry/series.json`, publish the branch, and add a `submit/pr6-*.sh`. Then `--dry-run` first, in
the same one-command-per-pull-request shape as patches 1 through 5.
