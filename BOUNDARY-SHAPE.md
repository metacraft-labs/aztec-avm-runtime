# The integration shape across the wasm boundary

**How much of the transaction and block loop lives inside wasm, decided on measurement.**

This is a design decision, not an implementation detail: it constrains the facade (M23) and
step-level tracing (M25). Both candidate shapes were built far enough to measure, both were
measured, and **the rejected shape's numbers are kept here** so the decision can be revisited
without redoing the work.

Every number below is re-derived on every run by `just verify-m15`. Nothing in this file is the
source of a figure a check then agrees with — the checks read the artefacts and this file is
required to carry what they measured.

---

## 0. The verdict, first

**RESIDENT.** The DBs stay inside wasm; the boundary carries a transaction in and a result plus a
step stream out.

And the reason is **not** the one the milestone expected. The milestone's note says "the likely
answer is resident, because boundary crossings are the known trap". The crossings are not the
trap. They were counted, and there are eighteen to twenty-two of them per transaction.

**How small.** A crossing costs **19 ns** (§5), so a transaction's entire pure-boundary cost in
the chatty shape is 21 x 19 ns = **about 0.4 us** — against roughly 4.8 ms of DB work and 63 ms of
simulation for the same transaction. The boundary is a part in ten thousand of the work it carries.
The AVM's host surface is not read per instruction: `PureMerkleDB` inside vm2 satisfies the
high-level surface itself and only the low-level misses reach the boundary.

The decision turns on two other things, both measured:

1. **The chatty shape's payload, not its crossing count.** To answer the AVM's reads from outside,
   the host must either hold the world state (which it cannot — see §4) or ship it: the hinted
   input blob is 186,712–191,807 bytes against the resident arm's 1,951, per transaction, and
   1,314,876 against 13,657 for a seven-transaction block.
2. **The host cannot hold the trees.** Upstream's only TypeScript merkle tree,
   `foundation/src/trees/merkle_tree.ts`, enforces `2 ** (height + 1) - 1` nodes in its
   constructor — **2,147,483,647** at `ARCHIVE_HEIGHT`. A host-implemented
   `LowLevelMerkleDBInterface` in the browser is M16, the fallback this campaign has repeatedly
   found to be the expensive wrong answer.

So the chatty shape is rejected on *what it would have to carry or build*, not on its crossing
count — and that distinction is the reason this milestone measured instead of reasoning. **If the
crossing count had been the deciding factor, the answer would have been chatty.**

---

## 1. What was built, and what was not

Nothing new had to be built for the decision, and that is the milestone's first finding.

M12 built **both entry points into the same module** and recorded, in `REACTOR-ABI.md`, that "the
choice between them is M15's". M13 completed the module's DB surface. So both shapes were already
in `avm.wasm` when M15 opened:

| shape | entry point | where the DBs are | boundary payload in |
|---|---|---|---|
| resident | `avm_simulate(inputs, contractDb, merkleDb)` | in the module | 1,951 B |
| chatty, batched | `avm_simulate_with_hinted_dbs(inputs)` | outside; every answer pre-supplied | 186,712–191,807 B |
| chatty, interactive | the 22 exported interface methods, one per operation | outside; answers fetched on demand | ~30–200 B each |

**A fully fused chatty arm is prepared and is not measured.** `verification/m15/avm_chatty_dbs.hpp`
and `.cpp` implement `ContractDBInterface` (eight methods) and `LowLevelMerkleDBInterface`
(fourteen) over a single wasm import, `env.avm_host_db_call`, so the AVM would call out
mid-execution rather than being pre-supplied;
`verification/m15/avm_reactor_chatty_exports.inc` carries the four exports that would drive it. It
is written against **`WsdbIpcMerkleDB`** — see §2 — and it is not needed for the decision, because
what the decision turns on is measured without it.

**It has not been compiled**, and saying so is the point of recording it at all. It is a reviewable
design and a starting point, not a tested artefact: what it would take to land it is a CMake option
beside `AVM_REACTOR`, a build, and a host that implements `env.avm_host_db_call`. Calling it
"prepared" without that sentence would be the kind of claim this campaign has had to walk back
before.

---

## 2. The reuse question, answered first — and upstream already ships the chatty shape

The campaign's standing question before any construction: does upstream already do this?

**Yes.** `WsdbIpcMerkleDB`, in `barretenberg/vm2_wsdb/wsdb_ipc_merkle_db.hpp`, is a `final`
implementation of all fourteen `LowLevelMerkleDBInterface` methods that translates each one into a
WSDB IPC command over a Unix domain socket, holding a `WsdbIpcClient&` and a `WorldStateRevision`.
That *is* the chatty shape, maintained by Aztec.

It cannot reach `wasm32-wasip1` — it links `wsdb` and `ipc_runtime` — so it is not a `depend`. But
it is the shape to copy rather than to invent, and M15's prepared `ImportedMerkleDB` is written
against it: the same per-method translate-and-cross, minus the revision (the AVM's interface has no
parameter to carry one, which is M14's "block-pinned reads: not needed"), with a wasm import in
place of the socket.

`vm2_wsdb/` is a barretenberg subdirectory **parallel to** `vm2/` — the same directory shape that
hid `automine/` under `sequencer-client/`, `FuzzerContractDB` under `avm_fuzzer/`, and
`WsdbIpcMerkleDB` itself from M14's first pass. It is the seventh instance.

The second reuse find is what makes §3 possible: **`HintingRawDB`**
(`vm2/simulation/lib/hinting_dbs.hpp`) is upstream's own recording decorator over both DBs. It
forwards every call and records it, which is why the hint record is a per-method tally of exactly
the calls a chatty host would have had to answer.

---

## 3. How many times a transaction crosses the boundary — a count, not an estimate

`AvmProvingInputs.hints` is what `simulate_with_hinted_dbs` consumes. It exists so a hinted replay
can answer every DB call the original simulation made, so it *is* a per-method tally of those
calls. Eighteen of its categories map one-to-one onto methods of the two host interfaces, and
`startingTreeRoots` is the one `get_tree_roots`. The mapping lives in
`verification/wasm_host/_hint_crossings.mjs`.

| program | hinted bytes | DB crossings |
|---|---|---|
| add | 186712 | 18 |
| revert | 187561 | 22 |
| loop | 187353 | 18 |
| sha256 | 186931 | 18 |
| poseidon2 | 186861 | 18 |
| storage | 191807 | 21 |
| burn | 187651 | 22 |

**`burn` executes 38,903 instructions and consults the host DBs twenty-two times.** The AVM's host
surface is not read per instruction or per memory access. `PureMerkleDB` inside vm2 satisfies the
*high-level* surface itself — storage reads and writes, siloing, note-hash uniqueness, L1-to-L2
checks — and only the low-level misses reach the boundary.

The recorded **per-transaction DB crossing budget is 32**: the measured maximum of 22 plus the room
one more nested call would need. It is a ceiling a regression crosses, not a target. A shape change
that made the AVM consult the host per memory access would go through it by three orders of
magnitude.

Three of the twenty-two interface methods have no hint category, and each absence is a statement
rather than a gap:

- `pad_tree` — the AVM never pads. Padding is the block builder's operation, and M14 established
  that upstream appends the L1-to-L2 bundle unpadded and pads exactly two trees.
- `add_contracts` — a write, performed when a transaction publishes a class. A replay does not need
  a hint for it, so the count above is a count of the *reads and the stack moves*, and a lower
  bound on `add_contracts`-heavy transactions.
- `get_checkpoint_id` — an accessor the AVM does not call.

### The other side of the boundary is the step stream, and it is already solved

38,903 records for `burn`. M12 measured it: 38,903 crossings at batch size 1, 76 at 512, 10 at
4,096, and **zero further crossings at all** if the host decodes `TxSimulationResult`, because
upstream's own `execution_steps` field already carries the whole stream. That is true in *either*
shape, so it does not discriminate between them — but it is the number M25 depends on and it is
recorded here beside the DB counts so the two are not confused.

---

## 4. Why the host cannot simply hold the trees

The chatty shape's crossing count is small. What is not small is what the host would have to be.

- **In the browser, upstream has no usable merkle tree.** `foundation/src/trees/merkle_tree.ts`
  enforces `2 ** (height + 1) - 1` nodes in its constructor. At `ARCHIVE_HEIGHT` 30 that is
  2,147,483,647 nodes. `MerkleTreeCalculator` builds exactly that array. It is a subtree
  calculator, not a full-height tree.
- **Upstream's C++ store cannot reach wasm.** `world_state::WorldState` holds five
  `LMDBTreeStore::SharedPtr` members and takes a `thread_pool_size` on every constructor.
- **And unlike the contract DB, there is nothing on the far side of the IPC boundary to reach for.**
  M13 established that `cdb`'s server is TypeScript; `wsdb/CMakeLists.txt` builds `aztec-wsdb` from
  C++ sources and links exactly `barretenberg env ipc_runtime world_state`.

So a host-implemented `LowLevelMerkleDBInterface` in the browser means writing the trees, which is
M16 — and M16's own trigger list says it is executed only if the boundary shape is unworkable.
It is not.

---

## 5. What it costs — measured

Measured on the pinned anchor plus M13's ten patches, in V8 (node 24, `node:wasi`), interleaved
round by round so a machine that slows during the run penalises all arms equally, medians over the
rounds.

### The representative transaction

`storage` is the representative one for a stated reason: of the seven it touches the world state
hardest — the largest hinted blob at 191,807 bytes, three sibling paths where the others take two,
two public-data preimages where the others take one.

| quantity | resident | chatty, batched | chatty, interactive |
|---|---|---|---|
| entry point | `avm_simulate` | `avm_simulate_with_hinted_dbs` | 21 exported interface calls |
| input payload | 1,951 B | 191,807 B | 463 B total |
| result payload | 174,613 B | 567 B | 13,976 B total |
| public inputs collected | yes | **no** | n/a |
| wall time (median of 3) | 63,409 us | 1,605 us | 4,845 us |

**The three wall times are not comparable to each other, and refusing to compare them is the
finding.** `AvmSimAPI::simulate_with_hinted_dbs` constructs `const PublicSimulatorConfig config =
{}` for its simulation — upstream's own code, asserted rather than worked around — so the hinted
arm collects neither public inputs nor statistics. Its result blob is 567 bytes against the
resident arm's 174,613, and most of the resident arm's wall time is producing the thing the other
arm was told not to produce. Anybody quoting "the chatty arm is forty times faster" would be
quoting the absence of public inputs.

**What is comparable is the extra cost the chatty shape pays**, and it is the number the decision
turns on. The same DB operations happen in both shapes; in the chatty one each of them
additionally crosses the boundary. The interactive drive is 4,845 us over 21 operations — about
**231 us per DB operation** — and a crossing on its own is **19 ns** (§5, the null crossing). So
the boundary is about **0.4 us per transaction** against roughly 4.8 ms of DB work and 63 ms of
simulation: a part in ten thousand of the work it carries.

That is why the crossing count, which the milestone expected to decide this, does not.

### A full block

The **seven corpus programs as seven transactions** against one world state and one contract DB,
with a checkpoint opened and committed around each.

| quantity | resident | chatty, batched |
|---|---|---|
| wall time, seven transactions | 477,088 us | 63,825 us |
| input payload, whole block | 13,657 B | 1,314,876 B |
| DB crossings, whole block | 2 per tx (in + out) | **137** |
| peak linear memory | 201 pages | 201 pages |

**The corpus cannot commit seven transactions to one world state**, and that is a finding about the
corpus rather than a limitation of the harness: all seven hand-assembled programs emit the *same*
nullifier, `0x…deadbeef`, so committing one makes the next fail upstream's own
`[NR_NULLIFIER_INSERTION] UNRECOVERABLE ERROR! Nullifier collision`. Every transaction therefore
runs inside its own checkpoint pair and is reverted, and what is asserted is what that shape
supports: the world state MOVED inside a transaction, came BACK on revert, and the checkpoint stack
ends where it started. **M20 and M22 need a corpus with distinct nullifiers** before a block's
effects can accumulate; this is where that requirement was found.

The block-level crossing count is the sum of the transactions' — 137, not a new order of magnitude
— which is the property M23's facade needs.

### The encode/decode half, separated from execution

Three quantities, none inferred from another. A crossing costs a fixed amount plus something per
byte, and the two shapes differ in both, so one number would hide the term the decision turns on.

- **The null crossing** — `avm_abi_version()` in a loop; it returns a constant, so what is left is
  the call.
- **The transport** — `avm_alloc` / copy / `avm_free` of a real blob at the two sizes the two
  shapes carry.
- **The decode** — the host decoding the result blob, with no module call in it.

| quantity | measured |
|---|---|
| null crossing (`avm_abi_version` x 50,000, median of 3) | **19 ns** per crossing |
| transport of 50 x 1,951 B (alloc / copy / free) | 23 us |
| transport of 50 x 191,807 B | 235 us |
| host decode of a 174,613 B result (median of 3) | 824 us |

Composed: `storage` makes 21 DB crossings, so its whole pure-boundary cost is **21 x 19 ns = about
0.4 us**. The decode of one result blob costs two thousand times that. A crossing is not the
expensive part of a crossing.

---

## 6. The reference world state's own performance, which was unmeasured

This is the deliverable that produced the most.

`world_state_reference::MemoryMerkleDB`'s own header says it:

> Checkpoints deep-copy the whole tree state onto a stack and restore on revert

and §6.4's design constraint asked for O(changes). Checkpoints are taken **per nested call, per
phase and per transaction**.

**Nobody had measured it.** At the pinned anchor there is no benchmark anywhere in the fork that
names `world_state_reference`, `MemoryMerkleDB` or `memory_merkle_db`, and the one file that
exercises checkpoints at all — `world_state/memory_merkle_db.test.cpp` — asserts equivalence and
contains no clock.

### The mechanism

`std::stack<State> checkpoints_`, and `create_checkpoint()` is `checkpoints_.push(state_)`. `State`
is four whole trees by value (five with M14's patch). Each tree is a `SparseMemoryTree` over an
`std::unordered_map<uint64_t, FF>`, so a push is a node-by-node rehash and re-allocation of every
map, and a pop is a node-by-node destruction of them.

### What it costs

Measured by `verification/m15/world_state_checkpoint_bench.cpp`, one source compiled and run
against BOTH trees — the pinned anchor's four trees and the anchor plus M14's archive patch,
five — detecting which it has with a `requires`-expression rather than an `#ifdef`, so neither
arm is told which one it is. Medians over 9 repetitions; microseconds.

The population is built the way execution builds it: nullifiers through
`insert_indexed_leaves_nullifier_tree`, public-data writes through
`insert_indexed_leaves_public_data_tree`, note hashes through `append_leaves`.

| leaves inserted | create (5 trees) | commit | revert | create (4 trees) |
|---|---|---|---|---|
| 0 (genesis prefill only) | 26 us | 6 us | 10 us | 20 us |
| 100 | 60 us | 14 us | 24 us | 52 us |
| 1000 | 367 us | 67 us | 144 us | 391 us |
| 10000 | 6086 us | 664 us | 2605 us | 10183 us |

**It is O(state).** A ten-fold population costs **16.6x** more per `create_checkpoint`
(6086 us at 10,000 leaves against 367 us at 1,000), and the decade below shows the same
growth at **6.1x** (367 us against 60 us at 100). The four-tree arm shows it too — **26.0x** and
**7.5x** over the same two decades — so this is a property of the design and not of M14's patch.
O(changes) predicts a ratio of 1.0x at both, and the data refuses it four times over.

**And there is a floor.** A freshly constructed database has already written the two indexed
trees' genesis prefill — 128 leaves each, at heights 42 and 40 — so the FIRST checkpoint of a
transaction that has done nothing at all costs **26 us**. An empty transaction is not free.

`commit` copies nothing — it pops — but popping a `State` destroys four or five hash maps node
by node, so it is not free either: **67 us** at 1,000 leaves against **367 us** to create. They
are timed apart for that reason; reporting one 'checkpoint cost' would merge a copy with a
destructor.

**The nested-call shape**, which is how a transaction actually pays this — `ContextProvider`
opens a checkpoint per nested external call and `Execution::handle_exit_call` closes it:

| depth | open + close, at 1,000 leaves |
|---|---|
| 1 | 423 us |
| 4 | 1756 us |
| 16 | 7650 us |

**M14's fifth tree costs less than this measurement can resolve, and that is the answer.**
The archive tree holds ONE leaf at genesis, so it contributes a handful of nodes to a copy of
hundreds of thousands. `create_checkpoint` with five trees against four is 1.2x at 100 leaves,
0.9x at 1,000 and 0.6x at 10,000 — **the sign is not stable**, and a fifth tree cannot make a copy
cheaper. What the data supports is that the fifth tree does not change the COMPLEXITY; what it
does not support is a figure for its cost.

The two arms' ABSOLUTE times at 10,000 leaves disagree by more than the tree count could explain
and in the wrong direction — 10183 us for four trees against 6086 us for five — so no claim is made
on their ratio at that population. The growth claim above survives it because a ratio taken
WITHIN one arm shares that arm's conditions; a ratio across the arms does not.

### The disposition

**An upstream optimisation with independent merit, not a rewrite.** The class is Aztec's, it is
correct, and the cost is a data-structure choice inside it rather than a design error above it. The
two shapes that would fix it without changing any caller:

1. **Copy-on-write on the node map.** `SparseMemoryTree`'s `nodes_` behind a `shared_ptr`, cloned
   on first write after a checkpoint. `create_checkpoint` becomes a pointer copy; the cost moves to
   the writes, which is where O(changes) puts it.
2. **An undo journal.** Record `(key, previous value)` per write since the last checkpoint and
   replay it backwards on revert. `commit` discards the journal, `revert` applies it — both
   O(changes).

The independent-merit argument is upstream's own: `MemoryMerkleDB` is what the AVM fuzzer and
`PublicTxSimulationTester` run against, and both take a checkpoint per nested call. Anything that
makes their inner loop cheaper is a benefit to upstream whether or not it is a benefit to us.

**M14 made the copy larger**, and by how much is measured above rather than argued: the archive
tree is a fifth `MemoryAppendOnlyTree` inside the same checkpointed `State`, holding one leaf at
genesis.

---

## 7. State export and import across the boundary

**The two shapes do not answer this equally, and the asymmetry is the finding.**

**Resident: there is no carrier.** `MemoryMerkleDB` keeps its `State` private and its only accessor
is `get_tree_roots()`, which returns a summary — `{root, nextAvailableLeafIndex}` per tree, the
protocol's `AppendOnlyTreeSnapshot` shape. That is the right vocabulary for a *state reference* and
it cannot carry a *state*: nothing can be reconstructed from it. Established three ways — against
the header, against the module's export list, and against the compiled symbol table of
`libworld_state_reference.a`, because a method that exists and is not exported and a method that
does not exist are different findings. M23 already records the distinction; this is where it bites.

Closing it in the resident shape is an **upstream extension** to `MemoryMerkleDB` — a serialisation
of the four (five) trees — prepared the way the other five patches were, not improvised.

**Chatty: the carrier is free.** The host owns the DB, so it already holds every operation that
built the state. An export is the ordered journal of those operations; an import is replaying it
into a fresh instance. It is O(changes) rather than O(state) — the property §6.4 asked of
checkpoints and did not get.

What was measured is the chatty half end to end: a world state built from the corpus's own
upstream-packed operations, the journal replayed into a fresh DB handle, every tree root and
next-available index matching, and the fresh instance asserted to have differed *before* the import
so the match is a statement about the import rather than about two genesis states agreeing.

**The honest limit**: the journal demonstrated here is of **host-applied state**. The operations the
AVM performs *inside* a simulation are visible to a host only in the fully fused chatty arm, which
is prepared and not measured. So the chatty carrier is measured for host-applied state and argued
for AVM-applied state.

---

## 8. What this constrains, for the milestones that depend on it

### M23 — the facade

- **The chain loop is TypeScript; the DBs are not.** `AvmRuntime` holds module handles, not trees.
- **The checkpoint stacks are owned inside wasm**, by M13's `CheckpointCoordinator` — one
  coordinator per (contract DB, merkle DB) pair, the only thing that moves either stack. The
  facade's `produceBlock` opens and closes a coordinator checkpoint per transaction and per block;
  it never touches either DB's own stack, because a host driving them separately can put them out
  of step and a revert then leaves contract state and tree state describing different histories.
- **Snapshot export and import needs the upstream extension in §7**, or the facade's snapshot is
  limited to what the host applied. This is the one place where the resident decision costs
  something, and it is the item M23 should carry.
- **The checkpoint cost in §6 lands on the facade's per-block budget**, not on the AVM's. A block
  of *n* transactions with *d* nested calls each pays *n*(1 + *d*) deep copies of the whole world
  state, and §6 prices one: about 0.4 ms at 1,000 leaves and about 6 ms at 10,000, growing
  superlinearly. At developer scale that is affordable; the optimisation is what makes it stay
  affordable as the state grows, and it is what M23 should watch rather than the boundary.
- **The corpus M20 and M22 will build on needs distinct nullifiers.** The seven hand-assembled
  programs all emit `0x…deadbeef`, so no two of them can be committed to one world state — found
  by trying, in §5's block measurement, which works around it by reverting every transaction. A
  block builder cannot.

### M25 — step-level tracing

- **Side effects are observed inside wasm**, through the `CodeTracerSideEffectTrace` decorator over
  the real `SideEffectTrace`, because that is where the DBs and the state manager are. A host-side
  observer would have to reconstruct the call tree; the decorator's `fork()`/`merge()` happen in
  lockstep with the state manager's own.
- **Step events reach the tracing layer through the result, not through per-event crossings.**
  `TxSimulationResult.execution_steps` already carries the whole stream: 38,903 records for `burn`
  after one crossing. `avm_steps_batch(from, count)` exists for a host that streams into a writer
  as it goes, at `ceil(N / B)` crossings. The resident decision does not change either; it is
  recorded here because M25's OQ-6 is a measurement against exactly these numbers.
- **Function names come from `ContractDBInterface::get_debug_function_name`, inside wasm**, which
  is why M13 wired a raw contract DB that implements it rather than one that returns `nullopt`.

---

## 9. The rejected shape's numbers, retained

Kept so the decision can be revisited without redoing the work. The chatty shape would be
reconsidered if any of these changed:

| quantity | measured | where |
|---|---|---|
| DB crossings per transaction | 18–22 | §3 |
| DB crossings per seven-transaction block | 137 | §3 |
| hinted input payload per transaction | 186,712–191,807 B | §3 |
| resident input payload per transaction | 1,951 B | §1 |
| step records for `burn` | 38,903 | §3 |
| TypeScript tree nodes required at `ARCHIVE_HEIGHT` | 2,147,483,647 | §4 |

The trigger that would flip the decision is **not** the crossing count. It is a host that can
implement `LowLevelMerkleDBInterface` without writing merkle trees — an upstream browser-capable
tree, or a wasm store the host can drive per-operation — at which point the payload asymmetry in
§5 disappears and the shape becomes a preference rather than a cost.
