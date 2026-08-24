# The TypeScript in-memory merkle trees, priced and not taken

**M16's fallback, evaluated against what M14 and M15 actually found, and priced whether or not it
is taken.**

M16 is the plan's held-ready second choice for the world state: revive the deleted
`@aztec/merkle-tree` package and implement `LowLevelMerkleDBInterface` in TypeScript instead of
using Aztec's own C++ `world_state_reference` compiled to wasm.

Its triggers were narrowed and written down **before the fact**, in the milestone, so that the
decision not to execute it could be evidenced rather than assumed. This file is that evidence, and
it is also the price, so that a future reader who has to reopen the question does not have to redo
the analysis.

Every number below is re-derived on every run by `just verify-m16`. The pricing and the hazard are
measured out of the installed package under `probe-mt/node_modules/` — not quoted from the
milestone text, which is what they would otherwise agree with forever. The trigger evaluations bind
to the documents whose own checks re-derive them: `BOUNDARY-SHAPE.md` (`just verify-m15`) and
`WORLD-STATE.md` (`just verify-m14`).

---

## 0. The verdict, first

**NOT REQUIRED.** No trigger fired. Five of the seven conjuncts across the three triggers are
measured **false**, one is measured **true**, and one is **unresolved and cannot be true today**.

**Doubt about the trees' correctness is explicitly not a trigger**, and this evaluation does not
treat it as one. That question is closed by M7 — upstream's own 391-test simulation suite passing
under wasm on two runtimes — and by M8 — native-versus-wasm tree roots identical.

**The analysis is retained anyway.** Sections 2 through 5 are the price, the hazard, the
counterweight and the staged plan, recorded because "not required today" is not "never", and
because a trigger evaluation that discards its own working is not evidence.

---

## 1. The triggers, evaluated

The three triggers are the milestone's, quoted rather than paraphrased. Each is a **conjunction**,
so each conjunct is evaluated on its own and a conjunction fires only if every conjunct is `true`.
The machine-readable block below is what `verify_fallback_triggers_recorded_and_evaluated` parses;
the prose after it is what a reader needs.

<!-- BEGIN:triggers -->

### T-1 — the boundary shape is unworkable
- trigger: 1
- clause: M15 concludes the boundary shape is unworkable — the resident shape is incompatible with the tracing or facade requirements and the chatty shape's crossing cost is unacceptable at developer scale
- conjunct: the resident shape is incompatible with the tracing or facade requirements
- verdict: false
- evidence: BOUNDARY-SHAPE.md :: Step events reach the tracing layer through the result, not through per-event crossings.
- reason: M15 decided RESIDENT and then recorded what resident constrains, for both dependents, in section 8. M23's facade holds module handles rather than trees, and the checkpoint stacks are owned inside wasm by M13's CheckpointCoordinator. M25 observes side effects inside wasm through the CodeTracerSideEffectTrace decorator over the real SideEffectTrace, and the whole step stream arrives in TxSimulationResult.execution_steps after ONE crossing — 38,903 records for burn — with avm_steps_batch available for a host that would rather stream. Function names come from ContractDBInterface::get_debug_function_name, inside wasm. Neither dependent is refused anything; both are constrained, and the constraints are written down.
- conjunct: the chatty shape's crossing cost is unacceptable at developer scale
- verdict: false
- evidence: BOUNDARY-SHAPE.md :: null crossing (`avm_abi_version` x 200,000, median of 3) | **19 ns** per crossing
- reason: A crossing costs 19 ns, measured on the cheapest export the module has, and a transaction makes eighteen to twenty-two DB crossings, so its entire pure-boundary cost is about 0.4 us against roughly 4.8 ms of DB work and 63 ms of simulation — a part in ten thousand of the work it carries. A seven-transaction block is 137 crossings, the sum of its transactions rather than a new order of magnitude. The crossing count is a measured LOWER BOUND, being the sum of the hint arrays' lengths, and the conclusion survives the bound being short by a factor of three: sixty crossings is about a microsecond.
- conjunction: not-fired

### T-2 — block-level coverage, a declined extension, and an unaffordable carry
- trigger: 2
- clause: M14 finds block-level coverage insufficient, upstream declines the extension, and the downstream carry proves too expensive to maintain
- conjunct: M14 finds block-level coverage insufficient
- verdict: true
- evidence: WORLD-STATE.md :: read the archive snapshot as `lastArchive`
- reason: This one is TRUE and saying so is the point of evaluating conjuncts separately. Three of the thirteen block-level operations are classified absent at the anchor — reading the archive snapshot as lastArchive, updateArchive(header), and the genesis archive seed — and each was established by execution rather than by reading a header: M14's probe answers archive_in_tree_roots=0 because the compiler said so, append_leaves(ARCHIVE, ...) throws its own message, and the probe reports four genesis roots where Tier D has five. M14's disposition was DECISION: extend, and the extension exists.
- conjunct: upstream declines the extension
- verdict: unresolved
- evidence: carry/series.json :: x5 :: "status": "prepared"
- reason: A patch that has not been offered has not been declined. The extension is prepared in full — the format-patch file, a PR.md written for an upstream audience with a Kind: line and a dated prior-art search, and a verify.sh with no skip path, all three in verification/m14/ — and nothing has been submitted. All five entries in carry/series.json read status prepared, codetracer-specs/upstream-bugs/ holds exactly five aztec-* directories and none of them is the world-state one, and M11 is partially_completed precisely because submission is a manual step that needs a person with push rights. So this conjunct is not false-because-they-accepted; it is unaskable, and it is recorded as unresolved rather than as a convenient false.
- conjunct: the downstream carry proves too expensive to maintain
- verdict: false
- evidence: WORLD-STATE.md :: Forty-three lines of clearance at the nearest approach, against three lines of diff context.
- reason: Measured rather than estimated. The patch is 352 insertions and 10 deletions across three files, of which 216 insertions are test cases in a file no other patch in the series and none of the five downstream overlays touches. Exactly one of the three files is touched by exactly one sibling patch — memory_merkle_db.hpp, by patch 5 — and there the hunks do not meet: patch 5's three are at lines 105, 128 and 149 and M14's seven are at 6, 42, 199, 207, 217, 241 and 252, forty-three lines apart at the nearest approach against three lines of diff context. The component received one upstream commit in the two weeks before the anchor. This is the conjunct that makes the conjunction fail even in the world where the second one resolves to true, which is why it is measured now rather than deferred to that world.
- conjunction: not-fired

### T-3 — O(state) checkpoints with no upstream optimisation
- trigger: 3
- clause: M15's characterisation shows the O(state) checkpoints unacceptable at developer scale and no upstream optimisation is available
- conjunct: the O(state) checkpoints unacceptable at developer scale
- verdict: false
- evidence: BOUNDARY-SHAPE.md :: At developer scale that is affordable
- reason: The first half of this predicate is TRUE and the second is false, which is why the conjunct is evaluated as a whole. It IS O(state): a ten-fold population costs 11.7x more per create_checkpoint in the five-tree arm, 4133 us at 10,000 leaves against 352 us at 1,000, and 6.2x in the decade below, 352 us against 57 us at 100; the four-tree arm shows 12.8x and 7.4x over the same two decades, so it is a property of the design and not of M14's patch. O(changes) predicts 1.0x at each and the data refuses it four times over. But the question asked is whether that is unacceptable AT DEVELOPER SCALE, and it is not: a block of n transactions with d nested calls each pays n(1+d) deep copies of the whole world state, one of which is about 0.4 ms at 1,000 leaves and about 6 ms at 10,000, and BOUNDARY-SHAPE.md's own consequence for M23 records it as affordable there and as the thing to watch as the state grows.
- conjunct: no upstream optimisation is available
- verdict: false
- evidence: BOUNDARY-SHAPE.md :: An upstream optimisation with independent merit, not a rewrite
- reason: Two are available and both are O(1) on create, and neither changes a caller. Copy-on-write puts SparseMemoryTree's nodes_ behind a shared_ptr cloned on first write after a checkpoint, so create_checkpoint becomes a pointer copy and the cost moves to the writes, which is where O(changes) puts it. An undo journal records (key, previous value) per write since the last checkpoint and replays it backwards on revert; commit discards it. The independent-merit argument is upstream's own rather than ours: MemoryMerkleDB is what the AVM fuzzer and PublicTxSimulationTester both run against, and both take a checkpoint per nested call, so anything that makes their inner loop cheaper is a benefit to upstream whether or not it is one to us. Preparing the patch is M15's outstanding item and needs a person with push rights, which is a different sentence from "none is available".
- conjunction: not-fired

### Not a trigger
- not-a-trigger: doubt about the trees' correctness
- closed-by: M7 M8
- reason: The trees are Aztec's, they are compiled to wasm, and they are running. M7 ran upstream's own simulation-side vm2 suite under wasm — 391 tests from 60 suites, passing on wasmtime and on V8, name for name against the native run — and the reference DB is genuinely in that path, with 164 calls into it measured under gdb. M8 compared tree ROOTS native against wasm and they are identical, which is the only line that catches a wrong merkle hash, a wrong domain separator or a wrong indexed-leaf linkage. The milestone says this is not a trigger; this evaluation records why it is entitled to say so.

### Outcome
- outcome: not-required
- reason: No conjunction fired. Trigger 1 fails on both of its conjuncts, so it fails twice over. Trigger 2 has one conjunct true, one unresolved and one measured false, and the measured false is the one that would still hold in the world where the unresolved one resolves against us. Trigger 3 fails on both of its conjuncts. The milestone's sixth deliverable is therefore the one that applies: the milestone closes as not-required, with the analysis retained.

<!-- END:triggers -->

### What review changed about the evidence, and what it did not change

M15's review refuted three of the claims that supported the resident decision — `pad_tree` **is**
called, twice per transaction; `get_checkpoint_id` **is** called, once per nested call; and the
crossing count is a measured **lower bound** rather than a total. **The verdict survived and the
evidence changed.** None of the three bears on T-1's first conjunct, which is about tracing and the
facade; all three are about the crossing count, which is T-1's second conjunct, and that conjunct is
false by three orders of magnitude rather than by a margin three refutations could close.

The checkpoint numbers in T-3 are the **corrected** ones. The reading they replace was a null
result that was noise: its check asserted "at least one has it FASTER, which a fifth tree cannot
cause", i.e. it required an impossible observation as its passing condition, and it was measured
with one run per arm and the base arm always launched first, so arm was confounded with launch
order — on this host the order effect at 10,000 leaves is thousands of microseconds. What replaces
it is an ABBA design that makes a claim about M14's fifth tree only where the instrument can
resolve one: **+6 us at population 0 and +5 us at 100**, positive in both independent halves of the
pair. **At 1,000 and 10,000 leaves no claim is made and none is asserted.** The resolution limit
sits between 100 and 1,000: at 1,000 leaves the FIVE-tree arm reads **faster** than the four-tree
arm — `BOUNDARY-SHAPE.md` §6 records the pair as 383 us against 352 us at 1,000 — which is a
between-arm difference in a direction a fifth tree cannot cause, and several times larger than the
fifth tree costs where it is resolvable.

---

## 2. What the switch would cost, measured

§2.0 is read out of the **fork at the pinned anchor**, with `git grep` and `git show`. Every figure
from §2.1 onward is read out of `@aztec/merkle-tree@5.0.0-nightly.20260316` as
installed under `probe-mt/node_modules/`. That is the **last published nightly that ships the
package at all** — upstream removed it in `e264dd4893` on 2026-03-16 — which is why `pins.json`
carries it as a declared `npm_exceptions` entry with the reason that pinning it forward is
impossible rather than merely undesirable.

### 2.0 The reuse question, answered first and by enumeration

The campaign's standing question before any construction, and it is asked here because the answer
decides whether §2.1's line count is a *price* or a *starting point*: **does upstream still ship a
browser-capable TypeScript world state, anywhere?**

One regular expression over the **whole fork** at the pinned anchor — every `*.ts` in the tree, not
a walk of `yarn-project/foundation/src/trees/`, because this campaign has now been wrong seven
times about whether something needed building and every one of those misses was a directory
parallel to the one being searched:

```
class [A-Za-z0-9_]+ (extends [A-Za-z0-9_.<>, ]+ )?implements ([A-Za-z0-9_.]+, )*MerkleTree(Write|Read)Operations
```

`[A-Za-z0-9_]` and not `[A-Za-z_]`, for the reason M13's review measured: a digit in a class name
is enough to hide it. It finds **three implementations, in two subdirectories** — and **not one of
them is a tree**:

| # | class | path | what it actually is |
|---|---|---|---|
| 1 | `GuardedMerkleTreeOperations` | `yarn-project/simulator/src/public/public_processor/guarded_merkle_tree.ts` | a **decorator** over a `target`, which the sequencer uses to freeze the world state at a block deadline; every method forwards |
| 2 | `MerkleTreesFacade` | `yarn-project/world-state/src/native/merkle_trees_facade.ts` | a client of a **running `aztec-wsdb` process**, reached over an IPC path |
| 3 | `MerkleTreesForkFacade` | same file | the same facade, extended for writes |

`NativeWorldStateInstance` — what 2 and 3 hold — describes itself as a "backend-agnostic handle to
a running `aztec-wsdb` world state" and exposes `getIpcPath()`. `WORLD-STATE.md` §1 established
what is on the far side of that boundary: `aztec-wsdb` is **C++** and links `world_state`, which is
lmdb-backed and takes a thread pool, so it is the one implementation that cannot reach
`wasm32-wasip1`. **There is no TypeScript store behind that IPC boundary to reach for** — the
opposite of M13's contract-DB finding, and the reason M16 exists as a fallback at all.

**And the deleted package's own interfaces went with it.** Zero classes anywhere in the fork
implement `AppendOnlyTree`, `IndexedTree` or `UpdateOnlyTree`, and `yarn-project/` contains no
merkle-tree package at the anchor.

**What tree-shaped TypeScript does remain is `yarn-project/foundation/src/trees/`, thirteen
non-test files, and it is all built on the full node array.** `merkle_tree_calculator.ts` builds
exactly `2 ** (height + 1) - 1` buffers, and — the part a reader who checked only `merkle_tree.ts`
would have missed — **`indexed_merkle_tree.ts` `extends MerkleTree`** and therefore inherits that
constructor check unchanged. So it is not an unexamined candidate for §5's indexed-tree stage; it
is the same limitation one file over. `unbalanced_tree_store.ts` is genuinely sparse — a `Map`
keyed by `(level, index)` — but it is bounded by a leaf count in its constructor and exists for the
rollup's *unbalanced* trees, not for a fixed-height protocol tree.

**So the fallback is a build, and there is nothing to lift.** That is what makes the rest of this
section a price.

### 2.1 The package, by the line

The tarball publishes its TypeScript sources as well as the compiled output, so this is a count of
source lines rather than of transpiled ones.

| component | file | lines |
|---|---|---|
| `tree_base` | `src/tree_base.ts` | 359 |
| `StandardTree` | `src/standard_tree/standard_tree.ts` | 59 |
| `StandardIndexedTree` | `src/standard_indexed_tree/standard_indexed_tree.ts` | 641 |
| `SparseTree` | `src/sparse_tree/sparse_tree.ts` | 57 |
| the snapshot layer | `src/snapshots/` (5 files) | 747 |
| **the five M16 names** | | **1863** |
| everything shippable | 21 files less 2 test-support files | **2450** |
| everything published | 21 `.ts` files | 2756 |

**The milestone's "~2,000 non-test LOC" is right about what it names** and short of the whole
package: the five named components are 1,863 lines and the shippable package is 2,450. The
difference is the interfaces (188 lines), the four small entry points (`index`, `new_tree`,
`load_tree`, `poseidon`, `hasher_with_stats`, 160 lines together) and `unbalanced_tree.ts` (239
lines), which the milestone does not name and which the world state does not need. **The tarball
contains no `*.test.ts` at all**, so "non-test LOC" is the whole of it; what is subtracted above is
the two files that exist to support somebody *else's* tests —
`src/snapshots/snapshot_builder_test_suite.ts` and
`src/standard_indexed_tree/test/standard_indexed_tree_with_append.ts`, 306 lines together.

### 2.2 What it depends on, and the three corrections the measurement forces

The milestone prices it as "depending only on `@aztec/{foundation,kv-store,stdlib}` with no native
code". Both halves are refined by measurement, and the refinement runs in our favour.

- The declared dependencies are **five**, not three: `@aztec/foundation`, `@aztec/kv-store`,
  `@aztec/stdlib`, plus `sha256` and `tslib`. **`sha256` is declared and never used** — zero
  word-boundary occurrences in the whole source tree — so it is a stale dependency and not a cost.
- **The runtime closure is one `@aztec` package, not three.** Every import of `@aztec/kv-store` and
  `@aztec/stdlib` in the compiled output appears in a `.d.ts` file and in **no** `.js` file: they
  are `import type` and are erased. The compiled `dest/*.js` imports `@aztec/foundation` and
  nothing else under the scope. The store arrives as an injected object satisfying `AztecKVStore`,
  which is why §2.3 is an *adapter* refresh rather than a dependency bump.
- **The package itself contains no native code and no wasm.** Its transitive closure does, through
  `@aztec/stdlib` reaching `@aztec/bb.js`, which ships `nodejs_module.node` for four platforms —
  but `@aztec/stdlib` is type-only, so nothing on the runtime path reaches it. Recorded because a
  price that said "no native code" without saying which closure it meant would be wrong in exactly
  the direction that flatters the fallback.

### 2.3 The kv-store adapter refresh, reproduced and localised

The milestone records that the March-2026 package fails
`TypeError: this.nodes.get is not a function` against the June-2026 store. It does, today, and
`probe-mt/m16_adapter_probe.mjs` reproduces it with the failure localised:

```
imported=1
constructed=1
empty_root=0x2ac5dda169f6bb3b9ca09bbac34e14c94d1654597db740153a1288d859a8a30a
read_attempted=1
TypeError: this.nodes.get is not a function
    at StandardTree.dbGet (.../@aztec/merkle-tree/dest/tree_base.js:230:27)
```

**The store went synchronous to asynchronous between the two nightlies, and only the read half
broke.** `TreeBase.dbGet` calls `this.nodes.get(key)` — the synchronous `AztecMap.get` of the store
the package was written against. The June-2026 `@aztec/kv-store` lmdb-v2 map implements `getAsync`
and no `get`: it satisfies `AztecAsyncMap`, which is a different interface in the same package.
Construction survives, because the write path is `void this.meta.set(...)` and `set` still exists;
the tree even reports its empty root correctly, which is why the hazard in §3 is observable at all
against a store the package cannot otherwise use.

The size of the refresh, measured rather than guessed: **10 store handles** (nine `openMap`, one
`openSingleton`) and **20 synchronous accessor call sites** on them, spread across `tree_base.ts`,
`standard_indexed_tree.ts` and three of the five snapshot files. The call sites are derived from
the handle assignments rather than from a hand-typed member list, so a renamed member changes the
count instead of escaping it. Every one of them sits under a method that is already `async`, so the
refresh is mechanical — but it is the whole read path and not one line.

### 2.4 The checkpoint stack the package does not have

**Zero.** `checkpoint` and `revert` occur **no times at all**, on a word-boundary match, in the
package's 2,756 published source lines. `snapshot` occurs 78 times. That contrast is the price:
what the package offers is *snapshots* — O(state), immutable, addressed by block number, outliving
their creator, 747 lines of them — and what execution needs is *checkpoints*: nesting, O(changes),
strictly LIFO, created and discarded inside one transaction. The snapshot layer is not a partial
implementation of the thing that is missing; it is a different thing that would have to be kept as
well.

### 2.5 Block 0 and the archive

**Also zero.** `genesis` and `archive` occur no times in the package's sources. A revival would have
to add: the genesis prefill of 128 nullifier leaves and 128 public-data leaves with their
`nextKey`/`nextIndex` linkage (Tier D FX-18 captures all 256 preimages, so the target exists); the
archive tree at `ARCHIVE_HEIGHT` 30 seeded with the block-0 header hash computed from
twenty-three fields; and `update_archive`'s refusal of a header whose four-tree state reference is
not the current one.

**And one thing goes the other way, which is worth recording because it is the only respect in
which this fallback is stronger than the reason M15 rejected the chatty shape.**
`BOUNDARY-SHAPE.md` §4 rejects a host-held world state because upstream's only TypeScript merkle
tree, `foundation/src/trees/merkle_tree.ts`, enforces `2 ** (height + 1) - 1` nodes in its
constructor — **2,147,483,647** at `ARCHIVE_HEIGHT`. **The deleted package does not share that
limitation.** `TreeBase` is key-value backed and falls back to a per-level zero hash for any node
it has never written, so a `StandardTree` at height 30 constructs, and this file's own measurement
constructs one and reads its empty root. So `BOUNDARY-SHAPE.md` §4's argument is an argument about
`foundation/src/trees/merkle_tree.ts` specifically, and M16 is the answer to it rather than another
instance of it. That does not make M16 required — nothing in §1 fired — but a price that left it
out would misstate what the fallback is.

### 2.6 The domain-separated hasher

The three separators are exported by `@aztec/constants` at the pinned nightly and can therefore be
**read rather than restated**, which is the property the milestone asks for:

| separator | value |
|---|---|
| `DomainSeparator.MERKLE_HASH` | 2982624097 |
| `DomainSeparator.NULLIFIER_MERKLE` | 1157584160 |
| `DomainSeparator.PUBLIC_DATA_MERKLE` | 3756303423 |

The milestone names them `DOM_SEP__*`, which is the **C++ spelling**: the same generator emits
`#define DOM_SEP__<KEY>` for C++ and `enum DomainSeparator` for TypeScript, from one table. A
TypeScript revival reads `DomainSeparator`; the two names are the same constants and a future
reader should not go looking for a `DOM_SEP__` identifier in a `.ts` file.

`src/poseidon.ts` is 30 lines, hashes as `poseidon2Hash([lhs, rhs])`, and mentions no separator
anywhere — measured as zero occurrences of `DOM_SEP`, `DomainSeparator` or the word `separator` in
that file. Replacing it is the smallest item on this list and the one whose absence would be most
expensive, which is §3.

---

## 3. The known hazard, with its target values

**The package as shipped produces wrong roots.** Recorded here with the values a switch must hit,
so the switch does not rediscover it.

| quantity | value |
|---|---|
| empty `NOTE_HASH_TREE` at depth 42, natively | `0x2590f2aab19dd791700b4a43d3f52bb88ef2409a3731da8e848663559202e4c6` |
| empty `NOTE_HASH_TREE` at depth 42, from the undomained package | `0x2ac5dda169f6bb3b9ca09bbac34e14c94d1654597db740153a1288d859a8a30a` |
| first level at which the two disagree | **1** |
| levels at or above 1 at which they agree again | **0** |

**Both values are re-derived, and neither is copied forward.** The undomained one is asked of the
package itself: `probe-mt/m16_hazard.mjs` constructs a `StandardTree` at `NOTE_HASH_TREE_HEIGHT`
over the real store and reads its root, and separately iterates the undomained recurrence
`h(n) = poseidon2([h(n-1), h(n-1)])` from zero — the two agree, so the package's answer is
explained rather than merely observed. The native one is produced by the domained recurrence
`h(n) = poseidon2([MERKLE_HASH, h(n-1), h(n-1)])` with the separator read out of `@aztec/constants`,
and it is then checked against **two independent fixture witnesses**: Tier D's
`upstreamPublished.genesisTrees.NOTE_HASH_TREE.root`, which is upstream's own hardcoded expectation
read live out of the fork, and Tier D's `derived.emptyRootByHeight["42"]`, which is the capture
harness's recurrence. The same recurrence lands on `0x0fef6d80…64c11f7a` at height 36, upstream's
genesis L1→L2 root, which is FX-19's point: an implementation hashing internal nodes without the
separator cannot satisfy both ends at once.

**The sibling paths diverge from level 1 upward**, and the level-0 agreement is the control that
makes that a real statement: both chains are zero at the leaf, differ at level 1
(`0x19f1a0c0…` domained against `0x0b63a537…` undomained, and the domained value is Tier D's
captured `noteHashZeroSiblingPath[1]`), and **never agree again at any of the 41 levels above it**.
A revival that got the separator wrong would therefore fail at the first internal node, which is
the cheap place to catch it — and is why §5's first stage is the hasher and the empty roots.

**Why this is a hazard and not a defect report.** The package is not wrong about its own protocol;
it predates the domain separator. What makes it a hazard is that it is a plausible-looking,
still-installable component that produces confident wrong answers, and the wrongness does not
surface as an error — it surfaces as a root that does not match, forty-two levels later.

---

## 4. The honest counterweight

Recorded because the case against the fallback is easy to overstate and this campaign's standing
correction runs the other way.

**Tree code rarely changes.** A TypeScript revival would very probably be correct and
low-maintenance: the algorithms are fixed by the protocol, the target values exist (Tier D), the
hazard in §3 is a thirty-line file, and the adapter refresh in §2.3 is twenty mechanical call
sites. Nothing measured here says it would not work.

**It is the second choice because it is *ours to maintain*.** `world_state_reference` is Aztec's:
they keep it correct, they gate it against their own production LMDB world state on every commit,
and M14's extension made that gate stronger rather than forking it. A revived
`@aztec/merkle-tree` is a component whose drift we own forever, against a protocol whose constants
move without asking us. That is the whole of the argument, and it is an argument about ownership
rather than about capability.

---

## 5. If it is ever triggered: the staged plan

Staged so that each stage is useful on its own and fails at the cheapest point, with the Tier D
vectors as the assertion target at every stage.

| stage | what it delivers | the Tier D target it is asserted against |
|---|---|---|
| 1 | the domain-separated `Hasher` and the empty roots | FX-19: the recurrence hits heights 1, 2, 6, 10 that Noir publishes, then 36 and 42 that the C++ world-state test publishes |
| 2 | genesis and block 0 | FX-14 (five genesis roots and sizes) and FX-18 (all 256 prefill preimages with their linkage, plus the 42-level zero sibling path) |
| 3 | the append-only trees | FX-15: upstream's own `SyncExternalBlockFromEmpty` state reference at sizes 129/1/129/1 |
| 4 | the indexed trees | FX-16: the seven scripted mutation steps, including the two an implementation with correct hashing and wrong indexed-leaf linkage gets wrong — an insert landing between two existing keys, and an update rewriting a leaf without growing the tree |
| 5 | the checkpoint stack | FX-17: create, mutate two trees, revert, and require every root to return exactly, with the inside-checkpoint state differing from both so the comparison is not between two copies of one value |

Stage 1 is first because §3 is the failure this whole file exists to prevent, and because it is the
one stage that needs no store, no genesis and no linkage: it is a recurrence and two published
constants. A revival that cannot pass stage 1 has learned that in minutes rather than after the
other four stages are written.

**Stage 5 is the one with no upstream starting point.** Stages 1 to 4 adapt code that exists;
stage 5 is written from nothing, because §2.4 measured zero occurrences of `checkpoint` and
`revert` in the package. It is also the stage that would have to be *better* than the C++ one it
replaces — `MemoryMerkleDB`'s stack is O(state) (§1, T-3) and a TypeScript revival built on the
snapshot layer would inherit exactly that, so the undo journal in T-3's second conjunct is not
optional here; it is the design.

---

## 6. What this evaluation does NOT establish

- **Nothing was built.** No TypeScript tree was written, no revival was attempted, and every figure
  in §2 and §3 is measured against the *published package* rather than against an adaptation of it.
  The price is a price, not a spike.
- **T-2's second conjunct is unresolved by construction, and it stays unresolved until somebody
  pushes.** Nothing in this campaign has been submitted upstream; all five carry entries read
  `prepared`. If the archive-tree extension is offered and declined, T-2 must be re-evaluated — and
  it would still not fire, because T-2's third conjunct is measured false today. That is the reason
  the third conjunct was measured now instead of being deferred to that world.
- **T-2's third conjunct measures today's conflict, not tomorrow's churn, and the component it
  measures is two weeks old.** The 43 lines of clearance against three lines of diff context is a
  statement about whether the two patches collide *at this anchor*, and it is exact. The
  forward-looking half is thinner: the one upstream commit the shared component received is
  `94d004c56b`, which is the commit that **created** `world_state_reference/`, 14 days before the
  anchor. Its twelve-month churn is therefore also 1 — the same commit — so the stricter window the
  sibling patches in `carry/series.json` are measured on does not change the number, but a
  fourteen-day-old component's quiet history is weak evidence that it will stay quiet. "Too
  expensive to maintain" was never given a numeric threshold before the fact, so this conjunct's
  `false` is a judgement supported by measurements rather than a threshold test like T-1's and
  T-3's. It is the conjunct the whole conclusion rests on, and it is the softest of the three.
- **The trigger evaluations are bound to documents, not re-measured here.** T-1 and T-3 rest on
  `BOUNDARY-SHAPE.md` and T-2 on `WORLD-STATE.md`, both of which their own milestones' checks
  re-derive on every run. M16 asserts that the evidence it cites is present in those documents; it
  does not rebuild the wasm module or re-run the checkpoint benchmark, and a reader who wants those
  numbers defended should run `just verify-m15` and `just verify-m14`.
- **The browser was not measured.** §2.2's "the runtime closure is `@aztec/foundation`" is a
  measurement of the package's compiled imports, not of a bundle. What a bundler actually pulls in
  is M27's and M28's, and RI-29 records that this closure has surprised us before.
- **§2.0's enumeration is over the monorepo at the anchor, and that is not the same as "over
  everything Aztec publishes".** It searches `*.ts` in the fork; a package deleted from the tree but
  still resolvable on npm would not appear — which is not hypothetical, because
  `@aztec/merkle-tree` is exactly such a package and is the subject of this whole file. What the
  enumeration establishes is that *nothing in the maintained tree* implements a browser-capable
  world state, which is the question that matters: a package upstream has deleted is not a
  component they keep correct for us, and taking one is the definition of this fallback rather than
  an alternative to it.
- **"Measured rather than quoted" is contingent on npm still serving a package upstream deleted.**
  Nothing in this repository carries a copy of `@aztec/merkle-tree@5.0.0-nightly.20260316`:
  `probe-mt/node_modules/` is gitignored, and the only durable record is `package-lock.json`'s
  resolved URL and its `sha512` integrity hash. Upstream removed the package on 2026-03-16, so if
  the registry ever stops serving that nightly, `just verify-m16` cannot run and every figure in §2
  and §3 becomes exactly the unverifiable prose this file was written to avoid. The integrity hash
  means a copy found elsewhere can still be validated; keeping one is not done and would be the
  cheap remedy.
- **Only `x86_64-linux` was exercised**, as in M6 through M15, and no browser engine was measured.
  The runtime is not a free variable in the hazard, though, and that was checked rather than
  assumed: §3's four values come out identical under the dev shell's node 24 — which is what the CI
  job would use — and under the host's node 25. What is *not* established is anything about a
  browser engine, which is M28's.

---

## 7. Where this leaves M16

`:status: completed`, and the completion is the milestone's **sixth** deliverable rather than its
fifth: *"If not triggered: the milestone closes as not-required, with the analysis retained."* The
fifth deliverable — the staged implementation — is conditional on a trigger that did not fire, and
four of the six verification entries are guarded by the same condition and stay `pending`, because
an implementation that must not be written cannot have a passing test. The milestone's own
Deliverables section records that, in those terms, rather than leaving a reader to infer it from an
unticked box.
