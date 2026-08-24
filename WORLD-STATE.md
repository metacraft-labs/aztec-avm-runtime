# Block-Level World-State Coverage

What `world_state_reference` covers of what block production needs, what it does not, and what was
decided about each gap. Every number here is re-derived on every run by
`verification/verify_block_level_gap_audit_complete.sh` and the five checks beside it; nothing in
this file is the source of a figure a check then agrees with.

M13's review found `REACTOR-ABI.md` still asserting, in the very section naming M13 as owner, a
claim M13 had disproved — because no check asserted that prose. So the claims below that could
drift silently are bound: the audit check requires this file to name every implementation the
enumeration found, to classify all thirteen operations, to work the four dispositions in the
milestone's order, and to state the one taken.

---

## 1. The reuse question, answered first and by enumeration

One regular expression over the **whole fork** at the pinned anchor `233d8e0993`, not a walk of
`vm2/`, because this campaign has now been wrong six times about whether something needed building
and the most recent one — M13's `FuzzerContractDB` under `avm_fuzzer/common/interfaces/` — was
missed by exactly that walk.

```
class [A-Za-z0-9_]+ (final )?: public ([A-Za-z0-9_]+::)*LowLevelMerkleDBInterface\b
```

`[A-Za-z0-9_]` and not `[A-Za-z_]`: M13's review measured that the second finds seven
implementations of `ContractDBInterface` where the first finds eight, because `avm2` has a digit in
it.

It finds **five implementations**, asserted as an identity — six would fail the check and so would
four:

| # | class | path |
|---|---|---|
| 1 | `HintedRawMerkleDB` | `vm2/simulation/lib/raw_data_dbs.hpp` |
| 2 | `HintingRawDB` | `vm2/simulation/lib/hinting_dbs.hpp` |
| 3 | `MemoryMerkleDB` | `vm2/simulation/lib/memory_merkle_db.hpp` — the vm2 adapter over the reference |
| 4 | `MockLowLevelMerkleDB` | `vm2/simulation/testing/mock_dbs.hpp` |
| 5 | `WsdbIpcMerkleDB` | **`vm2_wsdb/wsdb_ipc_merkle_db.hpp`** |

The fifth is under `vm2_wsdb/`, a barretenberg subdirectory **parallel to** `vm2/`. Same shape as
M13's find, one directory over.

The interface itself is declared once, in `vm2/simulation/interfaces/db.hpp`, with **fourteen**
pure-virtual methods. **None of them takes a `WorldStateRevision`.**

### The M13 analogy breaks here, and that is the section's most useful finding

M13 established that upstream's shippable raw contract DB is not C++: `cdb` is a transport adapter
and `yarn-project/simulator/src/public/cdb_ipc_server.ts` serves all eight methods out of the
TypeScript `PublicContractsDB`.

`wsdb` has the same shape and the **opposite** answer. `wsdb/CMakeLists.txt` builds the
`aztec-wsdb` executable from `main.cpp cli.cpp wsdb_handlers.cpp wsdb_ipc_server.cpp` and links
exactly `barretenberg env ipc_runtime world_state` — extracted as the `target_link_libraries` block
and matched as whole lines, because M13's review found `"barretenberg"` matching a path component
of every include directory CMakeLists names. There is no `wsdb_ipc_server.ts` beside cdb's.

So: **cdb, store in TypeScript. wsdb, store in C++.** For the world state there is no store on the
other side of the boundary to reach for, and upstream's C++ store — `world_state::WorldState` —
is the one implementation that cannot reach wasm: `world_state_stores.hpp` includes
`crypto/merkle_tree/lmdb_store/lmdb_tree_store.hpp` and holds five `LMDBTreeStore::SharedPtr`
members (one of them `archiveStore`), and `world_state.hpp` includes `common/thread_pool.hpp` with
every constructor taking a `thread_pool_size`.

---

## 2. What block production does to the world state, and where each operation stands

The operation list is upstream's, taken from its own two block builders — the production one,
`prover-client/src/light/lightweight_checkpoint_builder.ts` (`addBlock`), and TXE's,
`txe/src/utils/block_creation.ts` (`makeTXEBlock`) — which agree.

Each row is classified **present**, **absent** or **unnecessary**, and each classification is
established by execution rather than by reading a header.

| # | operation | verdict | how it was established |
|---|---|---|---|
| 1 | append note hashes, padded to `MAX_NOTE_HASHES_PER_TX` | present | `append_leaves(NOTE_HASH_TREE, …)`, run in the probe and in upstream's own gate |
| 2 | insert nullifiers | present | `insert_indexed_leaves_nullifier_tree`, ditto |
| 3 | write public data | present | `insert_indexed_leaves_public_data_tree`, ditto |
| 4 | pad note-hash and nullifier trees | present | `pad_tree`, and `PureMerkleDB::pad_trees` pads exactly those two |
| 5 | append L1->L2 messages | present | `append_leaves(L1_TO_L2_MESSAGE_TREE, …)` |
| 6 | pad the L1->L2 tree | **unnecessary** | upstream never does it — see below |
| 7 | read the state reference | present | `get_tree_roots()`, four snapshots |
| 8 | read the archive snapshot as `lastArchive` | **absent** at the anchor | the probe's `archive_in_tree_roots=0`, a compile-time answer from a source that was not told which tree it was compiled against |
| 9 | `updateArchive(header)` | **absent** at the anchor | the probe: `append_leaves(ARCHIVE, …)` throws `append_leaves is only supported for NOTE_HASH_TREE and L1_TO_L2_MESSAGE_TREE` |
| 10 | genesis archive seed | **absent** at the anchor | the probe reports four genesis roots where Tier D has five |
| 11 | block-pinned reads | **unnecessary** | no method of the reference or of the interface takes a `WorldStateRevision`, confirmed against the compiled symbol table as well as the declarations |
| 12 | checkpoint across a block | present | create / commit / revert, exercised in lockstep with a real `WorldState` |
| 13 | commit, rollback, unwind, forks, finalisation | **unnecessary** | block-chain persistence, not simulation; the reference holds one uncommitted view by design |

### Row 6 looked like a gap and is not

`pad_tree` throws for `L1_TO_L2_MESSAGE_TREE`, which reads like a shortfall. It is not:
`stdlib/src/messaging/append_l1_to_l2_messages.ts` is a bare `appendLeaves` with no padding
anywhere in it, and the checkpoint builder's own comment says bundles are "appended compactly
(unpadded, at the tree's current next-available index)". `PureMerkleDB::pad_trees` pads exactly
`NOTE_HASH_TREE` and `NULLIFIER_TREE` and says "The public data tree is not padded."

So the reference supporting exactly those two is **correct and complete**. Recorded because a check
written from the milestone's phrasing rather than from upstream's behaviour would have reported a
gap that does not exist.

### The AVM never reads the archive, and its snapshot type could not carry one

`MerkleTreeId::ARCHIVE` appears in `vm2/` **once** outside tests, at
`vm2/simulation/lib/raw_data_dbs.cpp:44` — a `case` in a tree-**name** switch, `return "ARCHIVE";`.

`vm2/common/aztec_types.hpp`'s `TreeSnapshots` — the type
`LowLevelMerkleDBInterface::get_tree_roots()` returns — has **four** members and is serialised over
exactly those four by `MSGPACK_CAMEL_CASE_FIELDS`, as well as being written into the AVM's trace
columns. Adding a fifth would be an AVM ABI and circuit change.

That is not an argument against extending the reference. It is the constraint on **where** the
extension may go: on the reference's own surface, and not on the AVM's.

---

## 3. The dispositions, in the milestone's order

### Gap A — the archive tree

**does upstream already cover it elsewhere** — Yes, in `world_state::WorldState`, and that
implementation links lmdb and takes a thread pool, so it cannot reach `wasm32-wasip1`. Unlike M13's
contract DB, there is no TypeScript store behind the IPC boundary to use instead: `aztec-wsdb` is
C++ and links `world_state`. *Not available.*

**can M15's boundary shape avoid needing it** — Not by moving it into the AVM's interface: the
four-tree `TreeSnapshots` forecloses that in both the chatty and the resident shape. Not by moving
it to TypeScript either, and this is the measured part rather than the argued part: upstream's only
TypeScript merkle tree is `foundation/src/trees/merkle_tree.ts`, whose constructor **enforces**
`2 ** (height + 1) - 1` nodes. At `ARCHIVE_HEIGHT` 30 that is **2,147,483,647** nodes.
`MerkleTreeCalculator` builds exactly that array. It is a subtree calculator, not a full-height
tree. So "put it on the TypeScript side" is not a disposition that avoids work; it is M16, the
fallback this campaign has repeatedly found to be the expensive wrong answer. *Does not avoid it.*

**is a named notImplemented throw sufficient** — It is what the anchor already does, and the
messages already name the tree id (`unsupported tree id 4`, `Padding not supported for tree 4`).
Sufficient only if nothing needs the answer. M22 needs an archive root for every block header and
M20/M21 need `lastArchive`, so a throw defers the work rather than disposing of it. *Not
sufficient.*

**does it need an extension** — Yes. **DECISION: extend.**

The extension is one more `MemoryAppendOnlyTree<aztec::AztecMerkleHashPolicy>` at `ARCHIVE_HEIGHT`:
the same template the class already instantiates twice, with the same hash policy, because
`world_state/fork.hpp` already records that the note-hash, L1->L2 and archive trees share the
baseline separator. It goes in `TreeRoots` (last, and outside the four, because the four **are** the
block header's `StateReference`) and in the checkpointed `State`. It is **not** surfaced through
`LowLevelMerkleDBInterface`, for the reason in section 2.

Its genesis is one leaf. `WorldState` seeds its archive with the block-0 header hash computed from
the genesis state reference, so the reference computes the same hash from its own four genesis
snapshots — twenty-three fields, kept beside `WorldState::compute_initial_block_header_hash` field
for field. It is **derived, not stored**: the check asserts the patched source contains neither
`GENESIS_ARCHIVE_ROOT` nor `GENESIS_BLOCK_HEADER_HASH`, and mutating the genesis timestamp from 0 to
1 fails all twelve cases of upstream's gate.

`update_archive(block_state_ref, block_header_hash)` comes with it, carrying
`WorldState::update_archive`'s check and its message — a header whose four-tree state reference is
not the world state's current one is refused with `Can't update archive tree: Block state does not
match world state`. `TreeRoots::state_reference_equals()` is that comparison, kept separate from
`operator==` because a block header carries the four trees and not the fifth.

**The independent-merit argument, which is upstream's rather than ours.**
`world_state/memory_merkle_db.test.cpp` is the canonical-fidelity gate for this class: it drives an
ephemeral, file-backed `WorldState` and a `MemoryMerkleDB` through the same operations and requires
them to agree after every step. It constructs the WorldState with **five** trees and compared
**four**. A fidelity gate that omits a tree the real implementation has is a weaker gate, and the
patch closes that: `expect_roots_equal()` compares five snapshots, which puts the archive under the
seven cases that already existed as well as under the five it adds.

### Gap B — block-pinned reads

**does upstream already cover it elsewhere** — Yes: `world_state::WorldState` takes a
`WorldStateRevision` on fourteen methods, and upstream's own `world_state_tests` has three cases in
which a view taken at block 0 does not follow the canonical tip. Those three are run by name.

**can M15's boundary shape avoid needing it** — Yes, and this is the disposition. The AVM's host
interface has no revision parameter at all, so there is nothing to pass one through in either shape.
The only block-pinned archive read in the whole block pipeline is an archive membership witness for
a historical block hash, in
`prover-client/src/orchestrator/block-building-helpers.ts` — the private-kernel side. Public
execution never takes one.

**DECISION: not needed.** The reference holds exactly one view, so the regression the `LATEST`
sentinel exists to prevent is not reachable in it: it cannot return the tip for a genesis-anchored
read because it cannot be asked for a genesis-anchored read. What would change this is a consumer
that needs to simulate a transaction against a historical state — M20's externally-settled
transactions are the first place that could arise, and if it does, the disposition to revisit is
this one and not the archive tree's.

The sentinel's own contract is nonetheless executed rather than read, because the vocabulary is
defined in this component even though this component does not consume it: `LATEST` is 4,294,967,295
and not 0, a default revision is not historical, and a revision pinned to block 0 is.

### The other four `absent`/`unnecessary` rows

Rows 6, 13 need nothing. Rows 8 and 10 are Gap A's, and are closed by it.

---

## 4. Genesis, settled by comparison

The milestone asks whether `DEFAULT_NULLIFIER_TREE_PREFILL` and `DEFAULT_PUBLIC_DATA_TREE_PREFILL`
being 128 is the fuzzer's configuration — the source comment at the anchor says they "match the
values the WorldState is initialized with **in the fuzzer**" — and whether the resulting roots agree
with the real world state's.

**Three independent witnesses**, because agreement between two of them could be one value copied
twice: the reference, executed; upstream's own hardcoded expectations, read live out of the fork
with `git show`; and Tier D, captured from `@aztec/world-state`'s `NativeWorldStateService`, the
production LMDB world state, driven from TypeScript.

**The four StateReference trees agree, all three ways.** Nullifier `0x18935581…cee0454` at 128, note
hash `0x2590f2aa…9202e4c6` at 0, public data `0x1bef38b6…56b9d084` at 128, L1->L2
`0x0fef6d80…64c11f7a` at 0. That half was already M8's; it is re-derived here rather than quoted,
and the patched tree is required to produce the identical four.

**The fifth agrees too, once the extension is present.** Archive `0x177a4955…15cfbdf5` at size 1 —
Tier D's capture, upstream's `GENESIS_ARCHIVE_ROOT`, and the reference's own computed value. At the
anchor there is nothing on the reference's side to compare.

**And the 128 is not the fuzzer's.** `@aztec/world-state`'s `merkle_tree_db.ts` defines
`INITIAL_NULLIFIER_TREE_SIZE = 2 * MAX_NULLIFIERS_PER_TX` and
`INITIAL_PUBLIC_DATA_TREE_SIZE = 2 * MAX_TOTAL_PUBLIC_DATA_UPDATE_REQUESTS_PER_TX`, and both
protocol constants are 64. The fuzzer passes `128, 128` because that is what the protocol says, not
because it chose it. The anchor's comment is narrower than the truth — recorded as **DRIFT D13** —
and the patch restates the constants in the form they are derived in, so a change to either protocol
constant moves the reference's genesis together with the production world state's.

**`pad_tree` pads with empty leaves, and so does the real one.** The milestone flags this as a
possible divergence. It is not: upstream's own gate pads the WorldState side by appending zero
leaves and requires the roots to match. No protocol-contract leaf is inserted by either
implementation.

---

## 5. What the extension cost, measured

- **Three files**, all in the two components: `world_state_reference/memory_merkle_db.{hpp,cpp}` and
  `world_state/memory_merkle_db.test.cpp`. Nothing under `vm2/` and nothing under `avm_fuzzer/`.
- **One new include**, `barretenberg/aztec/aztec_constants.hpp`, which the header already reached
  transitively through the hash policy. No lmdb, no thread pool, no vm2, no ipc. The module
  declaration `barretenberg_module(world_state_reference crypto_merkle_tree aztec crypto_poseidon2)`
  is untouched, so it is still the vm2-free, single-threaded component that reaches wasm.
- **Upstream's own gate goes from seven cases to twelve**, measured as the difference of two name
  sets rather than as a constant. Every other suite in `world_state_tests` is unchanged by name, and
  `vm2_tests` declares the same **1,803** tests with an identical name set and an identical set of
  passes.
- The vm2 adapter reads **four** named fields out of `TreeRoots` and none of them the archive, so
  adding a fifth is additive for the only consumer that maps the type.

### Mutation controls

A gate that passes under every mutation is a description. Seven mutations, each changing what the
code does:

| mutation | cases that failed |
|---|---|
| genesis timestamp 0 -> 1 | 12 of 12 |
| `update_archive` stops checking the block state reference | exactly 1, `UpdateArchiveRejectsMismatchedStateReference` |
| appending to ARCHIVE becomes a no-op | 12 of 12 |
| the archive is restored separately on revert, i.e. not at all | exactly 1, `ArchiveParticipatesInCheckpoints` |
| `state_reference_equals` drops the note-hash conjunct | exactly 1, `UpdateArchiveRejectsMismatchedStateReference` |
| ... drops the public-data conjunct | exactly 1, same case |
| ... drops the L1->L2 conjunct | exactly 1, same case |

**The first round found a hole in this milestone's own gate.** With eleven cases, the no-op mutation
passed all eleven: `update_archive` wrote to `state_.archive_tree` directly, so the
`case MerkleTreeId::ARCHIVE` arms of `append_leaves`, `get_leaf_value` and `get_sibling_path` were
never executed by any test. Fixed in two places — every archive write now goes through
`append_leaves(MerkleTreeId::ARCHIVE, …)`, so there is one write path, and a twelfth case,
`ArchiveThroughTreeIdDispatch`, drives the archive through the tree-id dispatch and additionally
requires `pad_tree(ARCHIVE, …)` and `get_low_indexed_leaf(ARCHIVE, …)` to keep throwing.

The second mutation's first form (`if (false)`) did not compile under `-Werror
-Wunused-parameter`, so it was measuring nothing; re-formed as `if (… && false)`.

**Review found a SECOND hole, of the same shape, and the last three rows are the mutations that
close it.** `TreeRoots::state_reference_equals()` is a conjunction over four trees, and the only
case that exercised its negative path built the mismatch out of a NULLIFIER insertion; the suite's
other use of the comparator is positive, and a weakened comparator only makes a positive assertion
more likely to hold. So dropping `note_hash_tree ==`, `public_data_tree ==` or
`l1_to_l2_message_tree ==` from it passed all twelve cases — measured, not argued.
`UpdateArchiveRejectsMismatchedStateReference` now drives the mismatch through each of the four
trees in turn, and each of the three dropped conjuncts fails it. The first hole was "an arm no test
reaches"; this one was "a conjunct no test discriminates", and both are the same lesson: a case
that passes is not evidence about the code it did not have to exercise.

---

## 6. Downstream carry, and what it is priced at

The contribution is prepared in full — the `git format-patch` file, a `PR.md` written for an
upstream audience with a `Kind:` line and a dated prior-art search, and a `verify.sh` with a
meaningful exit status and no skip path — in `verification/m14/`, beside the checks.

**It is deliberately NOT in `codetracer-specs/upstream-bugs/`, and that is a correction to the
milestone rather than a shortfall.** The milestone's fourth deliverable asks for the directory
directly. That directory is not a drop box: it is ENUMERATED. `verify_carry_set_complete` does
`ls -d aztec-*/` over it and requires every entry to appear in `carry/series.json`, and
`verify_pr_branches_match_patches` then requires every carry-set entry to equal a branch **published
on our fork's origin**, asserting six branch identities as a count. So creating a sixth entry there
is a claim that a sixth branch is published — and this milestone opens no pull requests and pushes
nothing. Creating it would turn a green M11 red, on a check that is right to be red.

M13 hit the same wall with `MemoryContractDB` and left it as an Outstanding Task. This does the
same, with the difference that the three files a promotion needs already exist and are verified:
promoting them is `git mv`, a sixth `carry/series.json` entry, a published branch and a
`submit/pr6-*.sh`. **A person with push rights does that.**

**The fallback is to carry it, and the exposure is small and priced — measured, not estimated.**
The patch is 352 insertions and 10 deletions across three files. Of the three, exactly one is
touched by any other prepared patch: `world_state_reference/memory_merkle_db.hpp`, by patch 5
(`aztec-avm-wasm-cmake`), which is M6's narrowing correction. The other two —
`world_state_reference/memory_merkle_db.cpp` and `world_state/memory_merkle_db.test.cpp`, the
latter carrying 216 of the 352 insertions — are touched by **no** other patch in the series and by
none of the five downstream overlays.

And on the one shared file the hunks do not meet: patch 5's three hunks are at lines 105, 128 and
149, all inside `MemoryIndexedTree`; M14's seven are at 6, 42, 199, 207, 217, 241 and 252 — the
includes, `TreeRoots`, and `MemoryMerkleDB` itself. Forty-three lines of clearance at the nearest
approach, against three lines of diff context.

Worth stating for contrast, because a coarser measurement would have reported it as a collision:
patch 1 (`aztec-merkle-tree-lmdb-split`) touches **six** files whose paths begin
`world_state`, and not one of them is M14's — they are `world_state/`'s CMakeLists, `fork.hpp`,
`types.hpp`, `world_state.{hpp,cpp}` and `world_state_stores.hpp`. Rebase exposure is therefore one
file shared with one sibling patch at non-adjacent lines, against a component that received one
upstream commit (`94d004c56b`) in the two weeks before the anchor.

---

## 7. What this milestone did NOT establish

- **The archive is not exercised inside `avm.wasm`.** The extension is native-verified against the
  real `WorldState`, which cannot run in wasm, and the AVM does not read the archive, so there is
  nothing in M12's reactor that would exercise it. Whether the reactor should export archive
  operations at all is M15's boundary decision, and this milestone deliberately forecloses neither
  arm.
- **No block was produced.** Rows 1-13 are the operation set; assembling them into a block is M22.
  What is established here is that the world state can perform every one of them.
- **Checkpoint cost is still unmeasured**, and the archive makes the deep copy one tree larger.
  M15's `test_checkpoint_cost_characterised` owns that; this milestone did not measure it and does
  not claim the addition is free.
- **The wasm LINK was not re-run with the patch applied.** Two things are asserted and one is not:
  the module declaration is unchanged and the added code introduces no lmdb, thread-pool, vm2 or ipc
  dependency — both measured — but `avm.wasm` was not rebuilt on a stack carrying this patch, so
  "still wasm-capable" rests on those two properties rather than on a link. M15 is where the wasm
  build of it belongs, because M15 decides whether the reactor exports archive operations at all.
- **The header hash used past genesis is a stand-in.** `GenesisArchiveMatchesPublishedConstants`
  computes the real block-0 header hash from twenty-three fields and checks it against the value
  upstream publishes. The three blocks in `UpdateArchiveMatchesWorldState` append
  `0xB10C0001`-style values instead: what is under test there is the TREE, and upstream publishes no
  golden header hash past block 0 to check a real one against. Constructing a full `BlockHeader` is
  M22's.
- **Only `x86_64-linux` was exercised**, as in M6 through M13.
