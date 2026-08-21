# The fixture manifest

**One entry per fixture family, naming its upstream source, its capture procedure, its licence,
and — in two fields, not one — what a skeptic should conclude from it passing and what they must
not.**

Checked by `just verify-fixture-manifest` (`verification/verify_fixture_corpus_manifest_complete.sh`),
which parses every entry through `verification/_manifest_parser.py`.

## Why the second half of every entry exists

Every headline number in this corpus has been quoted in an overstated form at least once. 756
"differential tests" were 74 comparisons. An `opcode_spam` arm described as comparing revert
reasons compared none. A "golden root vector" was described as filling a gap upstream had already
filled in three separate places. In each case the claim was not a lie, it was a *number without its
caveat*, and the caveat was in someone's head rather than in the file.

So `skeptic-cannot-conclude` is a required field with a length floor, and the checker rejects an
entry where it is missing, trivial, or a copy of `skeptic-concludes`. An entry that cannot say what
it fails to prove has not been thought about.

## Tiers

The tiers A–E are **the milestone's**, from `Aztec-AVM-Runtime.milestones.org` M2. `fixtures/CORPUS.md`
uses an older, wider spike-era lettering (A–J) for the same material and the two do **not** line up;
the mapping is at the end of this file so neither document has to be read through the other.

| tier | what it is |
|---|---|
| A | the TypeScript↔C++ differential oracle, and the byte-level cross-language golden |
| B | semantic unit fixtures — opcode semantics, memory tags, gas, serialization |
| C | contract-level app fixtures over real compiled Noir contracts |
| D | the world-state tree oracle |
| E | authored, with no upstream source. **Deliberately the smallest tier**, and the checker enforces that: Tier E must have strictly fewer entries than every other tier |
| H | the harness and the programs the families run on, rather than fixture families themselves |

## Licensing, per tier

There is one answer and it is in `fixtures/CORPUS.md`'s licence table: everything sourced from
`aztec-packages` is **Apache-2.0** (root `LICENSE` and `barretenberg/LICENSE`, Copyright 2023
Spilsbury Holdings Ltd, no `NOTICE` file), `avm-transpiler/` is **MIT OR Apache-2.0**, and
`@aztec/bb.js`'s npm package declares **MIT**. The obligation is to retain the licence text and
attribution and to state changes: the licence copy is at
`reference/LICENSE.aztec-packages.Apache-2.0`, per-file attribution is the generated
`BEGIN VENDORED-PROVENANCE` header, and the changes are `PROVENANCE.md`'s edit ledger.

The per-tier subtlety this manifest adds is the distinction the corpus mixes: a fixture that is
**upstream source** carries upstream's licence, while a fixture that is a **capture of upstream
behaviour** (Tier D's root vectors, Tier H's transcripts) is an output of Apache-2.0 code rather
than a copy of it — recorded as `Apache-2.0 (output of Apache-2.0 code)` so the two are never
conflated. Tier E is authored here.

`AztecProtocol/protocol-specs-pdf` and `AztecProtocol/engineering-designs` carry **no licence** and
are not vendored and not redistributed.

## How to read an entry

```
### FX-nn — name
- tier: A | B | C | D | E | H
- family: what this family is
- where: the paths in this repo
- upstream-source: the upstream path, package or anchor — or `none — authored` for Tier E
- capture: the command that produces or runs it
- licence: from the closed vocabulary above
- measured: the numbers, with the date they were measured
- skeptic-concludes: what passing genuinely establishes
- skeptic-cannot-conclude: what passing does NOT establish
- no-upstream-equivalent: Tier E only; tagged `does-not-exist:` / `does-not-cover:` / `cannot-reach-target:`
- inventory: the REUSE-INVENTORY.md entries this rests on
```

---

<!-- BEGIN:manifest -->

## Tier A — the differential oracle

### FX-01 — TypeScript-versus-C++ differential, default suite
- tier: A
- family: Per-transaction differential comparison of the vendored TypeScript AVM against the C++ AVM, over the seven app-test suites that run in a default `npm test`
- where: diffsim/src/public/public_tx_simulator/cpp_vs_ts_public_tx_simulator.ts, diffsim/src/public/public_tx_simulator/apps_tests, diffsim/src/public/public_processor/apps_tests
- upstream-source: `yarn-project/simulator/src/public/public_tx_simulator/cpp_vs_ts_public_tx_simulator.ts` @ anchor `ts`, with the C++ side the prebuilt in-process NAPI AVM from `@aztec/bb.js` at pin `npm.deletion_era`
- capture: `cd diffsim && npm test` inside `nix develop`; comparison counts via `python3 tools/measure_differential.py`
- licence: Apache-2.0
- measured: 2026-08-21 — **74 differential comparisons**, not 757 tests and not 77. Per file: avm_gadgets 27, custom_bc 13, public_processor/token 12, public_tx_simulator/token 8, amm 8, deployments 5, avm_test 1. All 74 had the revert reason genuinely compared, 0 exemptions. 77 tests carry the `(TS Simulator)` label but 30 of them (bench.test.ts) contribute zero comparisons.
- skeptic-concludes: Two independent AVM implementations, one C++ and one TypeScript, agree on 74 real transactions across revert code, all four gas dimensions, the entire `publicTxEffect`, the AVM circuit public-inputs buffer byte for byte, the app-logic return values, the structured revert reason, and the resulting world-state tree roots. This is the strongest single artefact in the corpus.
- skeptic-cannot-conclude: Nothing about code paths none of the 74 transactions reach, nothing about a defect both implementations share, and nothing about agreement with *current* upstream — the C++ side is a snapshot of the 5.0.0 npm line and upstream moved to an out-of-process simulator on 2026-07-16 (DRIFT.md D6).
- inventory: RI-25, RI-19, RI-32

### FX-02 — The opcode-spam differential arm
- tier: A
- family: 142 hand-built bytecode transactions, one per opcode-and-tag variant, driven through the same differential comparison
- where: diffsim/src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts, diffsim/src/public/fixtures/opcode_spammer.ts
- upstream-source: `yarn-project/simulator/src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts` and `fixtures/opcode_spammer.ts` @ anchor `ts` — 39 labelled configs over ~30 opcodes; upstream ships the arm commented out and the whole suite gated on `RUN_AVM_OPCODE_SPAM`
- capture: `cd diffsim && RUN_AVM_OPCODE_SPAM=1 node --experimental-vm-modules ./node_modules/.bin/jest src/public/public_tx_simulator/apps_tests/opcode_spam.test.ts`
- licence: Apache-2.0
- measured: 2026-08-21 — opcode_spam 142 comparisons, 142 revert-reason comparisons, **0 exemptions**, 142 s. Before M2 flipped `COLLECT_META_CHECK_RET` this arm produced 142 comparisons and **0** revert-reason comparisons, with the exemption firing 142 of 142 times (DRIFT.md D7).
- skeptic-concludes: The differential surface is 216 transactions rather than 74, covering ADD through TORADIXBE with per-tag variants, and — since M2's flip — every one of the 216 has its revert reason asserted, which means the one assertion-relaxing local deviation in the oracle now fires nowhere in the corpus at all.
- skeptic-cannot-conclude: That these 142 are as strong as the other 74. They are structurally blind to gas divergence: every spam transaction runs until it exhausts its gas limit, so both simulators report the same saturated total whatever the per-opcode cost is (DRIFT.md D2, mutation-tested). Never quote 216 as 216 equally strong comparisons.
- inventory: RI-25

### FX-03 — The measured per-arm comparison counts
- tier: A
- family: The machine-readable record of what the differential suite actually compares, regenerated by instrumentation rather than by reading the suite
- where: fixtures/differential-arm-counts.json, tools/measure_differential.py, diffsim/src/public/public_tx_simulator/differential_counters.ts
- upstream-source: `yarn-project/simulator/src/public/` @ anchor `ts` is the suite being measured; the counter and the aggregator are ours, and there is no upstream counterpart because upstream has never needed to distinguish its test count from its comparison count
- capture: `python3 tools/measure_differential.py --out fixtures/differential-arm-counts.json`
- licence: Apache-2.0
- measured: 2026-08-21 — totals 216 comparisons, 216 revert-reason comparisons, 0 exemptions. Test buckets in the default suite: 77 labelled `(TS Simulator)`, 78 labelled `(Cpp Simulator)`, 602 unlabelled — upstream's own three figures, unchanged — plus 1 added here (the corpus test), 758 passed, 153 skipped. Tests we added are bucketed separately so they can never be folded into a number quoted as upstream coverage.
- skeptic-concludes: The headline number and the comparison number are now separately measured and separately recorded, and the check re-measures on every run, so the two can no longer drift apart silently the way they did twice before. It also records the label inversion as a number: the suites labelled `(TS Simulator)` are the differential ones and the `(Cpp Simulator)` ones compare nothing.
- skeptic-cannot-conclude: That a comparison is a *good* comparison. The counter records that an assertion ran, not that it was capable of failing — D2's gas blindness is invisible to it, which is why D2 is a ledger entry rather than a number here.
- inventory: RI-25

### FX-04 — The cross-language msgpack golden
- tier: A
- family: A single byte-comparison pinning the widest serialization surface in the system — `AvmCircuitInputs(hints, publicInputs)` encoded in TypeScript against the file the C++ tests consume
- where: diffsim/src/public/public_tx_simulator/apps_tests/avm_minimal.test.ts
- upstream-source: `barretenberg/cpp/src/barretenberg/vm2/testing/minimal_tx.testdata.bin` — the contemporaneous file from anchor `ts`
- capture: `cd diffsim && npm test -- avm_minimal` with the golden and a `CODEOWNERS` sentinel placed under `node_modules/barretenberg/cpp/src/barretenberg/vm2/testing/`, since `getPathToFile()` resolves five directories up from its own module
- licence: Apache-2.0
- measured: 2026-08-21 — passes against the 188,945-byte golden from anchor `ts` (md5 `e1f17c71a3917a913de63dedf2f71a11`); FAILS against the 190,671-byte file at anchor `cpp` (md5 `369ae621886f3d0f0d4867bcbe7419f3`), a 1,726-byte drift over eight weeks.
- skeptic-concludes: The TypeScript and C++ sides agree byte for byte on the msgpack encoding of the full AVM input struct — inputs, hints, tree responses, globals — which is the contract M12's msgpack reuse rests on, and it is a drift detector with a date on it.
- skeptic-cannot-conclude: That the golden is still a contract. It is a **one-way pin**: nothing in the C++ tree reads `minimal_tx.testdata.bin` by name at anchor `cpp` any more, so the TypeScript test is now the producer and the C++ side has moved on (DRIFT.md D5).
- inventory: RI-06, RI-25

## Tier B — semantic unit fixtures

### FX-05 — Opcode semantics
- tier: B
- family: Per-opcode unit tests over the TypeScript interpreter — arithmetic, bitwise, comparators, control flow, conversion, memory, storage, contract, hashing, EC add, misc, accrued substate, environment getters, external calls, addressing modes
- where: diffsim/src/public/avm/opcodes
- upstream-source: `yarn-project/simulator/src/public/avm/opcodes/` @ anchor `ts`, 15 test files
- capture: `cd diffsim && npm test -- src/public/avm/opcodes`
- licence: Apache-2.0
- measured: 2026-08-21 — 259 passing tests across 15 files: arithmetic 67, memory 35, accrued_substate 24, conversion 18, control_flow 15, hashing 15, environment_getters 14, external_calls 13, comparators 12, bitwise 11, contract 10, ec_add 9, storage 7, misc 5, addressing_mode 4.
- skeptic-concludes: Each opcode's semantics are pinned against the original authors' intent at the commit the interpreter was deleted, which is exactly what protects a refactor of the interpreter. Addressing modes and tag handling — the two places a silent numeric bug hides — are covered per opcode rather than only end to end.
- skeptic-cannot-conclude: That the TypeScript interpreter agrees with the C++ one. These are hand-written expectations with no cross-implementation check at all; they establish self-consistency with a snapshot of upstream's intent, not agreement with production.
- inventory: RI-24

### FX-06 — Memory tags and conversions
- tier: B
- family: Tagged-memory semantics — tag checks, wrapping, truncation, conversions between all seven tags
- where: diffsim/src/public/avm/avm_memory_types.test.ts
- upstream-source: `yarn-project/simulator/src/public/avm/avm_memory_types.test.ts` @ anchor `ts`
- capture: `cd diffsim && npm test -- avm_memory_types`
- licence: Apache-2.0
- measured: 2026-08-21 — 99 passing tests, the single largest unit file in the corpus.
- skeptic-concludes: The tag lattice — U1, U8, U16, U32, U64, U128, FF — behaves as specified on construction, truncation and comparison. This is the cheapest fixture in the corpus per class of bug caught, because tag confusion produces wrong values that no structural test notices.
- skeptic-cannot-conclude: That the C++ AVM's `TaggedValue` agrees. C++ has its own `TaggedValueTest` (13 tests, and it passes under wasm), but nothing compares the two directly at unit level.
- inventory: RI-24

### FX-07 — The gas unit suite
- tier: B
- family: Per-instruction gas cost unit tests
- where: diffsim/src/public/avm/avm_gas.test.ts
- upstream-source: `yarn-project/simulator/src/public/avm/avm_gas.test.ts` @ anchor `ts`
- capture: `cd diffsim && npm test -- avm_gas`
- licence: Apache-2.0
- measured: 2026-08-21 — **2 passed, 10 skipped**. Upstream skips the dynamic-gas cases itself; this is the weakest entry in Tier B and is recorded as such rather than counted at face value.
- skeptic-concludes: Only that the two unskipped cases hold. The load-bearing gas evidence in this corpus is Tier A's four gas dimensions on 74 transactions, not this file.
- skeptic-cannot-conclude: Anything about dynamic gas, which is where the one live divergence lives: AND/OR/XOR lost their dynamic L2 gas upstream while the published `@aztec/constants` still ships `AVM_BITWISE_DYN_L2_GAS = 3`, and every test in this tree passes anyway (DRIFT.md D1).
- inventory: RI-24

### FX-08 — Bytecode and instruction serialization
- tier: B
- family: The AVM wire format — decoding a bytecode buffer into instructions and re-encoding it
- where: diffsim/src/public/avm/serialization
- upstream-source: `yarn-project/simulator/src/public/avm/serialization/` @ anchor `ts`
- capture: `cd diffsim && npm test -- src/public/avm/serialization`
- licence: Apache-2.0
- measured: 2026-08-21 — 12 passing tests: bytecode_serialization 10, instruction_serialization 2.
- skeptic-concludes: The per-opcode `wireFormat` tables round-trip, which is what makes them usable as an independent encoder — and FX-23 uses exactly that to reproduce upstream's C++ `BytecodeBuilder` output byte for byte without a barretenberg build.
- skeptic-cannot-conclude: That the wire format matches the C++ `serialization.hpp` tables. Twelve round-trip tests prove self-consistency; the cross-implementation evidence is FX-23's address equality, not this.
- inventory: RI-24

## Tier C — contract-level app fixtures

### FX-09 — Token and AMM application flows
- tier: C
- family: Whole application transactions on real compiled contracts — token constructor, mint, transfer, burn, balance reads; AMM add-liquidity, swap, remove-liquidity
- where: diffsim/src/public/public_tx_simulator/apps_tests/token.test.ts, diffsim/src/public/public_tx_simulator/apps_tests/amm.test.ts, diffsim/src/public/fixtures/token_test.ts
- upstream-source: `yarn-project/simulator/src/public/public_tx_simulator/apps_tests/{token,amm}.test.ts` @ anchor `ts`
- capture: `cd diffsim && npm test -- apps_tests/token apps_tests/amm`
- licence: Apache-2.0
- measured: 2026-08-21 — 4 jest tests driving 16 differential comparisons (token 8, AMM 8), each a full three-phase public transaction.
- skeptic-concludes: The interpreter executes production Aztec contracts end to end — nested calls, public storage, note hashes, nullifiers, authwit paths — and the C++ and TypeScript simulators agree on every effect and on the resulting tree roots for all 16.
- skeptic-cannot-conclude: That the contracts themselves are correct, or that flows these two contracts do not exercise are covered. Sixteen transactions over two contracts is integration evidence, not breadth.
- inventory: RI-33, RI-25

### FX-10 — AvmTest bulk and the AVM gadgets
- tier: C
- family: The bulk-testing contract and the gadget matrix — sha256 at 16 lengths, keccak, keccak-f1600, poseidon2, pedersen
- where: diffsim/src/public/public_tx_simulator/apps_tests/avm_test.test.ts, diffsim/src/public/public_tx_simulator/apps_tests/avm_gadgets.test.ts
- upstream-source: `yarn-project/simulator/src/public/public_tx_simulator/apps_tests/{avm_test,avm_gadgets}.test.ts` @ anchor `ts`
- capture: `cd diffsim && npm test -- apps_tests/avm_test apps_tests/avm_gadgets`
- licence: Apache-2.0
- measured: 2026-08-21 — 28 differential comparisons (avm_gadgets 27, avm_test 1) out of 56 jest tests; the other 28 are the `(Cpp Simulator)` arm and compare nothing.
- skeptic-concludes: The crypto gadgets agree between the two implementations across a range of input lengths rather than at one size, which is where padding and block-boundary bugs live. `AvmTest`'s bulk function reaches 62 distinct public entry points in one contract.
- skeptic-cannot-conclude: That gadget *implementations* are correct against their specifications — both sides could share a wrong constant. These compare two implementations, and the independent check on the hash side is Tier D's domain-separator work, not this.
- inventory: RI-33, RI-25

### FX-11 — Hand-built bytecode unhappy paths
- tier: C
- family: Malformed and hostile bytecode — uninitialised relative base, bad indirect tag, relative overflow, PC out of range, invalid opcode, invalid byte, invalid tag, truncated instruction, SET/CAST truncation
- where: diffsim/src/public/public_tx_simulator/apps_tests/custom_bc.test.ts
- upstream-source: `yarn-project/simulator/src/public/public_tx_simulator/apps_tests/custom_bc.test.ts` @ anchor `ts`; upstream has since ported this corpus to C++ as `vm2/integration_tests/custom_bytecode`
- capture: `cd diffsim && npm test -- apps_tests/custom_bc`
- licence: Apache-2.0
- measured: 2026-08-21 — 13 differential comparisons out of 26 jest tests. The exemption fires 0 times here, and three injected C++/TypeScript revert-reason divergences produce 12, 12 and 7 failures respectively.
- skeptic-concludes: The two implementations agree on how execution *fails*, not just on how it succeeds — including the structured revert reason, which is the part the oracle was previously excusing in the opcode-spam arm. This is the suite that proved the exemption is narrow where it can fire at all.
- skeptic-cannot-conclude: That every malformed input is covered. Thirteen hand-built cases are a curated set, and the systematic version of this is the AVM↔Brillig fuzzer (RI-34), which is vendored and not yet stood up.
- inventory: RI-25

### FX-12 — Block-level processing and deployments
- tier: C
- family: The block processor rather than a single transaction — many transfers in one block, deploy-then-call within a transaction, deploy in private and call later in the block, block-cache poisoning
- where: diffsim/src/public/public_processor/apps_tests, diffsim/src/public/public_processor/public_processor.test.ts
- upstream-source: `yarn-project/simulator/src/public/public_processor/` @ anchor `ts`
- capture: `cd diffsim && npm test -- src/public/public_processor`
- licence: Apache-2.0
- measured: 2026-08-21 — 17 differential comparisons (public_processor/token 12, deployments 5), plus 16 passing and 1 skipped unit tests in `public_processor.test.ts`.
- skeptic-concludes: The layer above the transaction simulator agrees between implementations, including contract-deployment visibility rules across a block, which is where a cache that outlives its checkpoint would show up.
- skeptic-cannot-conclude: That block *limits* are enforced. `maxTransactions` and `maxBlobFields` have tests; `maxBlockGas` has none in this file, and the deadline test is `it.skip` at line 269 at both anchors. Checkpoint depth is covered only against a mock, so the call sequence is pinned and the resulting state is not — which is why Tier D captures checkpoint/revert roots directly.
- inventory: RI-21, RI-25

### FX-13 — Compiled Noir contract artifacts
- tier: C
- family: The six real compiled contracts the app tests run — Token, AMM, AvmTest, AvmGadgetsTest, StorageProofTest, PublicFnsWithEmitRepro — consumed from npm with no `nargo` and no compilation
- where: fixtures/contracts/artifacts.json, diffsim/check_contract_artifacts.mjs
- upstream-source: npm `@aztec/noir-contracts.js` and `@aztec/noir-test-contracts.js` at pin `npm.deletion_era`, rebuilt by upstream every nightly
- capture: `cd diffsim && node check_contract_artifacts.mjs > ../fixtures/contracts/artifacts.json`
- licence: Apache-2.0
- measured: 2026-08-21 — 6 artifacts, 149 declared public functions, 99 of them referenced by the corpus: AvmTest 62 of 85, AvmGadgetsTest 24 of 24, Token 7 of 19, AMM 4 of 5, StorageProofTest 1 of 1, PublicFnsWithEmitRepro 1 of 15. Dispatcher bytecode 4,227 to 50,939 bytes.
- skeptic-concludes: The corpus runs against genuine current-compiler AVM bytecode rather than hand-assembled toys, and the list of exercised functions is *derived from the sources* rather than declared, so it cannot be trimmed until the check passes. All six load and all six expose a `public_dispatch` entry point with non-empty transpiled bytecode.
- skeptic-cannot-conclude: That the whole public surface is exercised. Fifty of the 149 public functions are never called by any test in this tree, and `PublicFnsWithEmitRepro` contributes one of fifteen.
- inventory: RI-33

## Tier D — the world-state tree oracle

### FX-14 — Genesis roots, asserted against upstream's own constants
- tier: D
- family: The block-0 root and size of all five trees, compared against the values upstream itself checks in
- where: fixtures/trees/world-state-vectors.json, fixtures/trees/native-genesis-state.json, drift/capture_world_state.mjs
- upstream-source: `barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp` (`GetInitialTreeInfoForAllTrees`, four roots with sizes 128/0/128/0), `noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr` (`GENESIS_ARCHIVE_ROOT`) and `.../types/src/abis/block_header.nr` — all read live from the fork at anchor `cpp` on every run
- capture: `cd drift && node capture_world_state.mjs > ../fixtures/trees/world-state-vectors.json`; the expectations are extracted from the fork with `git show <anchor>:<path>`
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — 5 roots and 5 sizes agree: nullifier `0x18935581…cee0454` at 128, note hash `0x2590f2aa…9202e4c6` at 0, public data `0x1bef38b6…56b9d084` at 128, L1→L2 `0x0fef6d80…64c11f7a` at 0, archive `0x177a4955…15cfbdf5` at 1.
- skeptic-concludes: Aztec's own production world state, driven from TypeScript, reproduces exactly the genesis roots Aztec's C++ tests and Noir constants hardcode. Because the expectations are read out of the fork at the anchor rather than copied here, a re-pin that moves any of them fails this check instead of silently agreeing with a stale copy.
- skeptic-cannot-conclude: That this is *our* evidence. It is upstream's constant compared with upstream's implementation; it proves the capture harness is wired to the right thing, and it is deliberately marked as the section a captured vector may **not** claim credit for.
- inventory: RI-45, RI-02, RI-27

### FX-15 — The one post-genesis state reference upstream publishes
- tier: D
- family: The four tree roots after exactly one leaf is written to each tree, anchored on upstream's own `SyncExternalBlockFromEmpty` expectation
- where: fixtures/trees/world-state-vectors.json, drift/capture_world_state.mjs
- upstream-source: `barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp` — `WorldStateTest.SyncExternalBlockFromEmpty`'s checked-in `StateReference`, four hardcoded roots at sizes 129/1/129/1
- capture: `cd drift && node capture_world_state.mjs`; step 1 of the mutation sequence replays note hash 42, L1→L2 message 43, nullifier 144 and public-data write (145, 1), the same four operations upstream's test performs
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — all four match: nullifier `0x2e2e2d8b…bef9e311` at 129, note hash `0x25c4ef02…c2a9952d` at 1, public data `0x1e2d8d1c…ef56ca3df` at 129, L1→L2 `0x22c6f787…0e3c7c0c` at 1.
- skeptic-concludes: Upstream ships golden roots **past** genesis as well, and the TypeScript world state reproduces them. This is the anchor for the whole mutation sequence: step 1 is upstream's, so steps 2 onward are extensions of something upstream asserts rather than of a capture of our own.
- skeptic-cannot-conclude: That the capture is independent evidence here either. This entry exists precisely to correct the campaign's earlier belief that upstream published nothing past genesis — an entry contradicted by measurement, which is why it is stated separately instead of folded into the captured section.
- inventory: RI-45, RI-02

### FX-16 — The scripted mutation sequence past what upstream publishes
- tier: D
- family: Seven further steps beyond upstream's published one, recording all five roots and sizes after each — append-only batch, indexed insert at the tail, indexed insert interleaved, public-data update in place, public-data insert past the tail, public-data insert interleaved, L1→L2 batch
- where: fixtures/trees/world-state-vectors.json, drift/capture_world_state.mjs
- upstream-source: `@aztec/world-state`'s `NativeWorldStateService` at pin `npm.current` — Aztec's production LMDB world state, which is the oracle; the *sequence* is scripted here because upstream publishes no vector for any of these states
- capture: `cd drift && node capture_world_state.mjs > ../fixtures/trees/world-state-vectors.json`, then `just verify-tree-vectors` regenerates and requires byte equality
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — 7 steps, 35 root readings, regeneration byte-identical across runs. Every root introduced by these steps is asserted **absent** from the entire fork at anchor `cpp`, so none of them restates an upstream constant.
- skeptic-concludes: M8 and M14 can assert the wasm `MemoryMerkleDB` against real post-genesis states produced by Aztec's production implementation, including the two cases an implementation with correct hashing but wrong indexed-leaf linkage gets wrong: an insert that lands between two existing keys, and an update that rewrites a leaf without growing the tree.
- skeptic-cannot-conclude: That the archive tree is covered. It is deliberately not mutated — advancing it needs a full `BlockHeader`, which is block-level and M14's subject — and the sequence records it unchanged at every step rather than pretending otherwise.
- inventory: RI-45, RI-02

### FX-17 — Checkpoint and revert, asserted on roots
- tier: D
- family: Create a checkpoint, mutate two trees inside it, revert, and require every root to return exactly
- where: fixtures/trees/world-state-vectors.json, drift/capture_world_state.mjs
- upstream-source: `@aztec/world-state`'s fork checkpoint API (`createCheckpoint`, `revertCheckpoint`) at pin `npm.current`
- capture: `cd drift && node capture_world_state.mjs`; the `captured.checkpoint` section records the roots before, inside and after
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — 5 roots restored exactly on revert, and the inside-checkpoint state differs from both, so the comparison is not between two copies of one value.
- skeptic-concludes: The tree half of M13's checkpoint-coordination risk is covered by a fixture that asserts *state* rather than call sequence. Upstream's own checkpoint tests assert against a mock, so they pin which calls were made and cannot tell whether the trees actually came back.
- skeptic-cannot-conclude: That contract-DB and merkle checkpoints stay in lockstep. `ContractDBInterface` and `LowLevelMerkleDBInterface` have independent create/commit/revert, and only the merkle half is exercised here; the joint case is M13.
- inventory: RI-02, RI-07, RI-26

### FX-18 — Genesis prefill leaves and the zero sibling path
- tier: D
- family: All 256 genesis prefill leaf preimages with their `nextKey`/`nextIndex` linkage, plus the 42-level zero sibling path for note-hash leaf 0
- where: fixtures/trees/world-state-vectors.json, fixtures/trees/native-genesis-state.json
- upstream-source: `@aztec/world-state`'s `NativeWorldStateService` at pin `npm.current`; upstream publishes the resulting genesis *roots* in several places but no preimage and no sibling path anywhere
- capture: `cd drift && node capture_world_state.mjs`; leaves via `getLeafPreimage`, path via `getSiblingPath`
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — 128 nullifier leaves, 128 public-data leaves (slots 0..127), 42 sibling-path levels.
- skeptic-concludes: An implementation that has the right hash but the wrong genesis state is caught. The prefill linkage is the half a root comparison alone cannot localise: a root mismatch says something is wrong, and the 256 preimages say which leaf.
- skeptic-cannot-conclude: That the prefill is *correct*, only that it is reproduced. Its correctness rests on the roots it produces, which is FX-14's job.
- inventory: RI-45, RI-02

### FX-19 — The empty-tree-root recurrence
- tier: D
- family: One recurrence linking two unrelated upstream publications — the empty balanced-merkle roots Noir publishes at small heights, and the genesis roots the C++ world-state test publishes at heights 36 and 42
- where: fixtures/trees/world-state-vectors.json, drift/capture_world_state.mjs
- upstream-source: `noir-projects/fnd/noir-protocol-circuits/crates/types/src/merkle_tree/root.nr` (`test_empty_tree_root`, heights 1, 2, 6, 10, themselves generated from `yarn-project/foundation/src/trees/balanced_merkle_tree_root.test.ts`) and `barretenberg/cpp/src/barretenberg/world_state/world_state.test.cpp`
- capture: `cd drift && node capture_world_state.mjs`; iterate `h(n) = poseidon2([h(n-1), h(n-1)], DOM_SEP__MERKLE_HASH)` from zero, capturing every height to 42
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — the recurrence hits all four published small heights exactly, then lands on `0x0fef6d80…64c11f7a` at height 36 (upstream's genesis L1→L2 root) and `0x2590f2aa…9202e4c6` at height 42 (upstream's genesis note-hash root).
- skeptic-concludes: The domain separator and the hash are pinned by two upstream publications that were produced by different toolchains for different purposes, joined by a single recurrence. An implementation hashing internal nodes as `poseidon2([lhs, rhs])` instead of `poseidon2([SEP, lhs, rhs])` cannot satisfy both ends at once.
- skeptic-cannot-conclude: Anything about the two indexed trees. The nullifier and public-data trees use different separators and are not empty at genesis, so this recurrence says nothing about them; their evidence is FX-14 through FX-16.
- inventory: RI-03, RI-45

## Tier E — authored, with no upstream source

### FX-20 — Timer-driven block loop
- tier: E
- family: A block per tick, monotonically increasing block timestamps across a sequence, an empty block when nothing is pending, and a deadline that truncates a block with a clean rollback — each asserting world-state roots
- where: fixtures/authored/block-loop/README.md
- upstream-source: none — authored under M23. The primitives are reused (`ManualDateProvider`, `RunningPromise`, `AutomineSequencer`); what is authored is the fixture that asserts the loop's behaviour over a sequence.
- capture: authored under M23; the justification is re-derived from the pinned fork on every run by `verification/verify_tier_e_authored_fixtures_justified.sh`, which re-checks four claims against `git ls-tree` and `git show`
- licence: Apache-2.0
- measured: 2026-08-21 — 4 fixtures to author, 4 upstream claims re-verified mechanically, 0 upstream test files in the automining sequencer's directory.
- skeptic-concludes: The gap is real and it is narrow, and it is stated in a form that goes red if upstream closes it. What is authored is four assertions over a sequence of blocks; every primitive underneath them — the frozen clock, the poll loop, empty-block issuance, the warp operations — is upstream's and is named.
- skeptic-cannot-conclude: That upstream has nothing block-shaped. It has a great deal, including end-to-end tests that produce many blocks; what it has no test for is the four specific properties above, and the claims say exactly which those are.
- no-upstream-equivalent: does-not-cover: four measured claims about the pinned fork, each re-checked on every run rather than restated. (1) `yarn-project/sequencer-client/src/sequencer/automine/` is exactly `README.md`, `automine_factory.ts`, `automine_sequencer.ts` and `index.ts` at anchor `cpp` — **zero** test files — so `buildEmptyBlock()` and the slot-boundary clamp are untested upstream. (2) `yarn-project/simulator/src/public/public_processor/public_processor.test.ts` line 269 is `it.skip('does not go past the deadline', …)` at BOTH anchors, with upstream's own comment calling it flakey, so there is no passing upstream test that a block deadline is honoured. (3) `yarn-project/stdlib/src/rollup/checkpoint_header.ts`'s `CheckpointHeader.random()` hardcodes `timestamp: BigInt(Math.floor(Date.now() / 1000))`, so the standard block test double emits a CONSTANT timestamp and cannot produce a monotonic sequence to assert against. (4) `yarn-project/txe/src/oracle/txe_oracle_top_level_context.ts`'s `advanceBlocksBy(n)` is a bare loop over `mineBlock()` and `nextBlockTimestamp` is mutated in exactly one place, `advanceTimestampBy`, so it mines n blocks all sharing one timestamp. The nearest upstream assertion of "the next block's timestamp exceeds the previous one" is `yarn-project/end-to-end/src/composed/e2e_cheat_codes.test.ts`, which covers exactly one block pair and needs a live docker network.
- inventory: RI-41, RI-21

### FX-21 — CodeTracer trace output
- tier: E
- family: Golden `.ct` recordings for a pinned set of transactions, checked by reader round-trip, `ct-print` comparison, step count against the engine's own instruction tally, and side-effect agreement with `publicTxEffect`
- where: fixtures/authored/trace-output/README.md
- upstream-source: none — authored under M24 and M25. Trace output is the one thing this runtime produces that no Aztec component produces.
- capture: authored under M24 and M25; the justification is re-derived from the pinned fork on every run by `verification/verify_tier_e_authored_fixtures_justified.sh`, which re-checks three claims with `git ls-tree`, `git grep` and `git cat-file`
- licence: Apache-2.0
- measured: 2026-08-21 — 3 upstream claims re-verified mechanically, 0 files with a `.ct` extension anywhere in aztec-packages at anchor `cpp`, 6 upstream instruction-observing seams enumerated and each dismissed with its reason.
- skeptic-concludes: Nothing upstream serialises a step-level artefact in any stable format, so there is no golden to compare against and the fixtures must be authored — and the four checks are chosen so that an empty or padded trace fails, in particular the step count, which is cross-checked against a number the engine computes independently.
- skeptic-cannot-conclude: That upstream observes nothing per instruction. It observes a great deal — `ExecutionEvent` is a genuine per-instruction record — but it is drained into tracegen in memory and never written, which is a different thing from a trace artefact.
- no-upstream-equivalent: does-not-exist: three measured claims, each re-checked on every run. (1) `git ls-tree -r --name-only` over the whole fork at anchor `cpp` finds **zero** files with a `.ct` extension, so there is no producer and therefore no golden. (2) The only per-instruction TypeScript seam is `yarn-project/simulator/src/public/avm/avm_simulator.ts`, whose hook is declared at line 41 as `private tallyInstructionFunction = (_b: string, _c: Gas) => {}` — a class name and a gas delta, with no program counter, no operands and no memory, so it cannot carry a trace however it is wired. (3) The per-instruction C++ observer the spike drives, `barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp`, does **not** exist at anchor `cpp` — `git cat-file -e` on it fails — so it is our fork's addition and M9 prepares it as an upstream contribution. Upstream's other candidate seams were read and each is something else: `barretenberg/cpp/src/barretenberg/vm2/simulation/events/execution_event.hpp` is a real per-instruction record but is in-memory only and drained into tracegen, `barretenberg/cpp/src/barretenberg/vm2/tooling/debugger.cpp` is an `#ifndef NDEBUG` interactive REPL over circuit rows, `yarn-project/simulator/src/public/side_effect_trace.ts` is transaction-level side effects for limit enforcement, and the one artefact upstream does write per transaction is `avm-circuit-inputs-tx-<hash>.bin` (see `yarn-project/end-to-end/bootstrap.sh`), which is msgpack prover input rather than a record of what executed.
- inventory: RI-44, RI-42

## Tier H — the harness and the programs

### FX-22 — Upstream's own AVM test harness, reused
- tier: H
- family: `PublicTxSimulationTester`, `BytecodeBuilder` and `InstructionBuilder` — the harness that drives `AvmSimAPI` over `simulation::MemoryMerkleDB` and a contract DB, with no mock anywhere in the executed path
- where: fixtures/wasm-parity/vm2_spike-sources/avm_run.cpp, fixtures/wasm-parity/vm2_spike-sources/spike_fixtures.cpp
- upstream-source: `barretenberg/cpp/src/barretenberg/vm2/testing/` @ anchor `cpp` — `public_tx_simulation_tester.{hpp,cpp}`, `bytecode_builder.{hpp,cpp}`, `instruction_builder.{hpp,cpp}`, `fixtures.cpp`
- capture: `cmake --build build-native-avm-spike --target avm_spike_runner` in the spike tree; the driver is ~290 lines over upstream's harness, and every simulation primitive under it is upstream's
- licence: Apache-2.0
- measured: 2026-08-21 — 1 authored driver file over 4 upstream harness files; `spike_fixtures.cpp` is upstream's `fixtures.cpp` with exactly 2 tracegen-bound definitions removed so it links without the proving stack.
- skeptic-concludes: The transcripts in FX-24 were produced by the harness Aztec uses to convince themselves, not by one we wrote. The world state in those runs is `simulation::MemoryMerkleDB` — Aztec's own in-memory trees — and the contract DB is upstream's `TestContractDB`; nothing in the executed path is a stub.
- skeptic-cannot-conclude: That the shippable contract DB is exercised. `TestContractDB` is a test implementation, and upstream's shippable raw contract DB is the native IPC-backed `cdb`; that gap is M13's.
- inventory: RI-14, RI-16, RI-18

### FX-23 — The seven AVM corpus programs
- tier: H
- family: `add`, `revert`, `loop`, `sha256`, `poseidon2`, `storage`, `burn` — promoted from the spike to a checked-in corpus, each carrying a recorded intent, each re-assembled and its derived contract address re-checked against upstream's C++ output
- where: diffsim/src/corpus/avm_corpus_programs.ts, diffsim/src/corpus/avm_corpus_programs.test.ts, fixtures/avm-programs/programs.json, fixtures/wasm-parity/vm2_spike-sources/avm_run.cpp
- upstream-source: assembled through upstream's own `vm2/testing/BytecodeBuilder` and `InstructionBuilder` @ anchor `cpp`; every instruction in all seven is emitted by upstream's encoders
- capture: `cd diffsim && npm test -- src/corpus`; regenerate the summary with `UPDATE_AVM_PROGRAM_FIXTURE=1`
- licence: Apache-2.0
- measured: 2026-08-21 — 7 programs, 199 instructions, 1,292 bytes total, 7 distinct bytecode digests and 7 distinct derived addresses. Byte lengths 21, 9, 661, 240, 170, 96, 95, each equal to the `bytes=` line the native C++ runner printed, and all 7 addresses equal to the C++-derived ones.
- skeptic-concludes: Upstream's TypeScript encoder and upstream's C++ `BytecodeBuilder` produce byte-identical bytecode for all seven programs — proved by the derived contract address, which is a hash over the entire bytecode, so agreement on it is agreement on every byte. And it is proved without a barretenberg build, which is what makes it runnable in ordinary CI.
- skeptic-cannot-conclude: That seven programs are broad coverage. They are integration evidence and a native-versus-wasm diff target; the breadth argument is upstream's own suite under wasm (FX-25), which is why that sits near the front of the plan rather than behind these.
- inventory: RI-46, RI-14

### FX-24 — Native-versus-wasm transcripts, including tree roots
- tier: H
- family: The same C++ AVM built for x86-64 and for `wasm32-wasip1`, run over the seven programs, and diffed line for line
- where: fixtures/wasm-parity/native-with-roots.results, fixtures/wasm-parity/wasm-with-roots.results, fixtures/tools/run_wasm.mjs
- upstream-source: `barretenberg/cpp/src/barretenberg/vm2/` @ anchor `cpp` built twice; the transcripts are outputs of upstream code, not copies of it
- capture: build `avm_spike_runner` in both trees, then run the native binary and `node fixtures/tools/run_wasm.mjs <module>` for the wasm one
- licence: Apache-2.0 (output of Apache-2.0 code)
- measured: 2026-08-21 — the whole-transcript diff is exactly 2 lines, the pointer-width banner and the wasm-only `peakLinearMemoryPages`. All 56 tree-root lines identical, with 7 distinct end-nullifier roots and 7 distinct end-public-data roots across the programs.
- skeptic-concludes: The AVM produces identical results under wasm and native across revert codes, all gas dimensions, fees, nullifiers, note hashes, data writes, public logs, call frames, instruction counts and — the part the earlier transcript did not cover — the world-state roots, which is the only line that catches a wrong merkle hash, a wrong domain separator or a wrong indexed-leaf linkage.
- skeptic-cannot-conclude: That the wasm build is correct, only that it agrees with the native one. A defect present in both compiles identically; the independent checks are Tier D against Aztec's production world state and Tier A against a second implementation.
- inventory: RI-01, RI-02, RI-18

### FX-25 — Upstream's own vm2 simulation suite under wasm
- tier: H
- family: 99 upstream translation units of `vm2/simulation/**/*.test.cpp` and `vm2/common/*.test.cpp`, built for `wasm32-wasip1` by an additive target
- where: fixtures/wasm-parity/vm2-sim-tests-native.txt, fixtures/wasm-parity/vm2-sim-tests-under-wasm.txt, fixtures/wasm-parity/vm2-sim-tests-under-wasm-raw.txt, fixtures/wasm-parity/vm2_spike-sources/CMakeLists.txt
- upstream-source: `barretenberg/cpp/src/barretenberg/vm2/**/*.test.cpp` @ anchor `cpp` — 174 test files, of which 99 translation units are in scope
- capture: `cmake --build build-wasm-avm --target vm2_sim_tests`, then `node fixtures/tools/run_wasm.mjs … --gtest_filter='<OneSuite>.*'`, one gtest suite per process
- licence: Apache-2.0
- measured: 2026-08-21 — native 59 suites / 387 tests passed; under wasm 24 of 59 suites pass, 141 tests. The 35 failing suites correlate exactly with gmock use, and rebuilding gtest with `GTEST_HAS_PTHREAD=0` was tried and changed nothing (identical 24 of 59).
- skeptic-concludes: The parts of upstream's own semantics suite that can run under wasm do run and do pass, including everything load-bearing for the tree question — `MerkleCheckSimulationTest`, `IndexedMemoryTree`, `HintingDBs*`, `SerializationTest`, `InstructionSpecTest` and the pure hash suites. This is upstream's breadth, not ours.
- skeptic-cannot-conclude: That 141 of 387 is a statement about the AVM. The 246 that do not run are blocked by gtest's threading layer compiling against wasi-libc's pthread stubs, which corrupts gmock's global expectation registry — a test-framework limitation, recorded as the largest unclaimed coverage win in the corpus.
- inventory: RI-15, RI-16, RI-17

<!-- END:manifest -->

---

## Mapping to `fixtures/CORPUS.md`'s lettering

`CORPUS.md` predates this manifest and letters the same material differently. Neither is renamed,
because both are cited elsewhere; the mapping is here so a reader can move between them.

| this manifest | CORPUS.md |
|---|---|
| FX-01, FX-02, FX-03 (Tier A) | Tier A, and Tier H for the opcode-spam arm |
| FX-04 (Tier A) | Tier B — the cross-language golden binary |
| FX-05 … FX-08 (Tier B) | Tier C — semantic unit fixtures |
| FX-09 … FX-13 (Tier C) | Tier A's app suites, and Tier E for the contract artifacts |
| FX-14 … FX-19 (Tier D) | Tier D — the tree oracle |
| FX-20, FX-21 (Tier E) | Gaps 2 and 3 |
| FX-22, FX-23 (Tier H) | Tier F and the spike programs |
| FX-24 (Tier H) | Tier I |
| FX-25 (Tier H) | Tier J |

The gaps `CORPUS.md` records that have no manifest entry — the Brillig fuzzer (Gap 4), gmock under
wasm (Gap 5) and browser execution (Gap 6) — are absent here deliberately: a gap is not a fixture
family, and giving it an entry would let the manifest count coverage it does not have.
