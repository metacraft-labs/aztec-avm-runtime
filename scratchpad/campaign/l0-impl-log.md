# L0 — The Node Client, and What It Is Allowed to Reach — implementation log

Campaign: `codetracer-specs/Planned-Work/Aztec-Live-Chain-Replay.milestones.org`, milestone **L0**.
Branch: `l0/node-client`, off `dev` at `d3c8228`. **Nothing is committed** — the review agent commits.

---

## 1. THE ENUMERATION, WHICH IS THE FIRST DELIVERABLE

**`AztecNode` declares FIFTY-FIVE methods at `anchors.cpp` (233d8e0993), not the fifty-one the
milestone file states.** The milestone says "fifty-one" twice and nothing had ever re-derived it —
the campaign's own "a figure nobody re-derives rots" family. Corrected by measurement, and the
measurement is re-taken on every run by `verify_node_client_surface_narrow`.

Three independent derivations, all agreeing on 55:

| derivation | source | count |
|---|---|---|
| the interface body | `git show 233d8e0993:yarn-project/stdlib/src/interfaces/aztec-node.ts`, `export interface AztecNode` | 55 |
| the JSON-RPC schema at the same commit | the same file's `export const AztecNodeApiSchema: ApiSchemaFor<AztecNode>` | 55 |
| the published nightly, at run time | `Object.keys(AztecNodeApiSchema)` from `@aztec/stdlib@5.3.0-nightly.20260819` (`npm.current`) | 55 |

The first two are **identical as sets**. The third differs from them **by exactly one name**: the
nightly spells it `getL1ToL2MessageCheckpoint` where the anchor spells it `getL1ToL2MessageIndex`.
Nothing in this repository had ever measured that the published nightly and the `cpp` anchor are
not the same tree; they are not, by one method. Declared as `ANCHOR_ONLY_METHODS` /
`PACKAGE_ONLY_METHODS` and asserted by name in both directions.

**A replay needs FOURTEEN of the fifty-five.** Forty-one are refused, in six groups, and the
partition is exact: 14 + 41 = 55, no overlap, no duplicate, nothing unclassified.

### The fourteen, and what each is for

| method | the datum | consumed by |
|---|---|---|
| `getNodeInfo` | node version, l1 chain id, rollup version, protocol contract addresses | L0 (version check), L3 (provenance) |
| `getBlockNumber` | the tip — *what "recent" is* | the demo |
| `getBlock` | ONE block's body: which transactions a recent block contains | the demo, L4 |
| `getBlockData` | `header.globalVariables` (the AVM's `GlobalVariables`) and `header.state` (the `StateReference` L2's root check compares against) | L1, L2 |
| `getTxByHash` | the `Tx` `AvmTxHint.fromTx` consumes | L1 |
| `getTxsByHash` | the batch form of the same | L1, L4 |
| `getTxEffect` | `IndexedTxEffect`: settling block number/hash, index in block, slot, and the published `TxEffect` | L1, L2, L3 |
| `getContract` | `ContractInstanceWithAddress` | L1 |
| `getContractClass` | `ContractClassPublic` — the packed bytecode | L1 |
| `getPublicDataWitness` | `SLOAD` | L2 route 1 |
| `getNoteHashMembershipWitness` | `NOTEHASHEXISTS` | L2 route 1 |
| `getNullifierMembershipWitness` | `NULLIFIEREXISTS`, present | L2 route 1 |
| `getLowNullifierMembershipWitness` | `NULLIFIEREXISTS`, absent (non-membership needs the low leaf) | L2 route 1 |
| `getL1ToL2MessageMembershipWitness` | `L1TOL2MSGEXISTS` | L2 route 1 |

### The split the coordinator asked for

- **A demo of recent settled transactions needs 14.** Every one of them is a fetch of a bounded
  thing about one transaction or one block, on demand.
- **A full ingestion engine would additionally need the 10 in `CONTINUOUS_FOLLOWING`** —
  `getBlocks`, `getCheckpoint`, `getCheckpoints`, `getCheckpointsData`, `getCheckpointNumber`,
  `getChainTips`, `getWorldStateSyncStatus`, `getSyncedL1Timestamp`, `getSyncedL2EpochNumber`,
  `getSyncedL2SlotNumber`. That group is named, so the widening BlockTracer's M6 would want is one
  edit with a reason rather than a surface that grew while nobody was counting.
- The other 31 refusals are not about streaming at all: submission and mempool (9), consensus and
  p2p (6), private-log discovery (2), L1 plumbing (5), and nine that this campaign has a nearer or
  stricter source for.

Two deliberate calls at the line: `getBlockNumber` is permitted so the client can find out what
"recent" is without being handed a hash; the SINGULAR `getBlock` is permitted so it can read that
block's transactions, while the RANGE `getBlocks` is refused. Singular vs range is where the line
sits.

### Two places the enumeration disagreed with the milestone file, and why

1. **`getBlockHashMembershipWitness` is REFUSED** though L2's route-1 list names it. The AVM never
   reads the archive. `barretenberg/cpp/src/barretenberg/vm2/common/opcodes.hpp` at the anchor has
   exactly these world-state opcodes: `SLOAD`, `SSTORE`, `NOTEHASHEXISTS`, `EMITNOTEHASH`,
   `NULLIFIEREXISTS`, `EMITNULLIFIER`, `L1TOL2MSGEXISTS`, `GETCONTRACTINSTANCE`. No archive read.
   This repository's own `REACTOR-ABI.md` already says `MerkleTreeId::ARCHIVE` occurs in `vm2/`
   once outside tests, in a tree-NAME switch, and that `TreeSnapshots` has four members.
2. **`getL1ToL2MessageMembershipWitness` is PERMITTED** though that list does not name it, because
   `L1TOL2MSGEXISTS` is in the same opcode list. A route-1 replay without it would fail on any
   transaction that used the opcode.

Both are asserted from the opcode file by name, so reversing either is a red line.

### And a needle defect, met live, in the enumeration written to prevent guessing

A scratch script written while deriving this used `'([a-zA-Z]+)'` to pull the permitted list out of
the TypeScript and reported **thirteen**, because `getL1ToL2MessageMembershipWitness` has a `1` and
a `2` in it. That is `avm2` and `warpL2TimeAtLeastTo` for the third time in this campaign's history.
The check's scanners use `[A-Za-z_$][A-Za-z0-9_$]*` and print their residue; the comment in
`verify_node_client_surface_narrow` records the sighting.

---

## 2. WHAT WAS BUILT

```
replay/package.json               a new npm consumer, on npm.current (NOT deletion_era)
replay/tsconfig.json              type-check only, erasableSyntaxOnly, like orchestration/
replay/src/node_surface.ts        the enumeration: 14 permitted, 41 refused in 6 groups, reasons
replay/src/strict_surface.ts      M21's guard, re-implemented; traps get AND has
replay/src/node_client.ts         the client, the three refusals, the version check
replay/src/pinned_protocol_version.ts   the pin as a browser-readable witness
replay/src/membership_witness_source.ts the seam L2 and the sibling campaign's M35 share
replay/src/index.ts
verification/lib_l0_node_client.sh      work dir, probe runner, anchor scanners
verification/_l0_fake_node.mjs          a node built out of UPSTREAM's own JSON-RPC server
verification/verify_node_client_surface_narrow.sh          74 assertions
verification/test_node_client_refusals_distinguishable.sh  52 assertions
verification/verify_client_uses_upstream_schema.sh         62 assertions
Justfile                          verify-l0-{surface,refusals,schema}, typecheck-replay, verify-l0
pins.json                         live_chain block; npm_consumers.replay = current; history entry
REUSE-INVENTORY.md                RI-86 (depend on upstream's client) and RI-87 (the guard)
scratchpad/campaign/l0-mutations.sh     eleven arms, including a hang and a die-before-summary
```

**Everything on the wire is upstream's.** `createAztecNodeClient(url, expected, fetch)` →
`createSafeJsonRpcClient(url, AztecNodeApiSchema, { namespaceMethods: 'aztec', onResponse:
getVersioningResponseHandler(versions) })`. Nothing in `replay/src` declares a schema; the check
asserts that with a scanner shown to be able to find a planted one.

**The version check is upstream's mechanism.** `getVersioningResponseHandler` compares the
`x-aztec-*` response headers against a `Partial<ComponentsVersions>` on every call. The pin is the
two protocol-level fields, which is what upstream's own `yarn-project/aztec/src/cli/versioning.ts`
produces when it has no chain config, and both are re-derived on every run from
`protocolContractsHash` and `getVKTreeRoot()`.

**The three refusals are three classes with three `kind` discriminants** — `NodeUnreachable`,
`SettledTransactionNotFound`, `ProtocolVersionMismatch` — plus `ReplayNodeSurfaceExceeded` for a
caller reaching out of bounds. The unreachable case is detected by IDENTITY, not by message
matching: upstream's `sendBatch` puts the original error into the JSON-RPC error's `data`, so the
instance the fetch wrapper constructed comes back as `err.cause.data`.

---

## 3. THE THREE CHECKS AND THEIR CONTROLS

`just verify-l0` — **188 assertions, 0 failures** (74 / 52 / 62).

| check | the control, and what it proves |
|---|---|
| `verify_node_client_surface_narrow` | `createUnguardedNodeClientForControls` — upstream's own client over all 55 schema methods, same url, same process — **answers for 40 of the 41 refused names, on read and on `in`**. So the guard is measured, not an absence. Plus: a fabricated name is ABSENT from that control object, so the control is not "an object that answers for anything". Plus: the anchor scanner finds 56 when one member is planted and 0 on a file with no `AztecNode` in it. |
| `test_node_client_refusals_distinguishable` | a successful `fetchSettledTx` returns a `Tx` through the SAME helper that produces the not-found refusal, and the version headers are OBSERVED (so the mismatch arm is not measuring a mechanism that never runs). Plus a 3x3: each arm throws its own class and **neither of the other two**. |
| `verify_client_uses_upstream_schema` | a fabricated method name is rejected at three layers — the guard, upstream's client object, and the node on the wire — with the SAME wire request shape carrying a REAL name answered, so it is the name being refused and not the request. Plus a schema-invalid response refused with the same raw server answering correctly as the control. |

---

## 4. MUTATION RESULTS — eleven arms, every one red, each on the assertions written for it

`scratchpad/campaign/l0-mutations.sh`

| arm | what it breaks | result |
|---|---|---|
| M1 | the guard stops trapping `has` | 74 / **2 red**, both the `in` assertions |
| M2 | the guard stops trapping `get` | 74 / **4 red**, the read assertions plus `Reflect.get` and the throwaway-guard control |
| M3 | `SettledTransactionNotFound extends NodeUnreachable` | 52 / **5 red**, including the 3x3's off-diagonal |
| M4 | `getBlocks` quietly permitted | 74 / **6 red**, partition and control-set sizes |
| M5 | `sendTx` loses its refusal group | 74 / **3 red**, `partition.unclassified` names `sendTx` |
| M6 | the pinned vk tree root drifts one digit | 62 / **1 red**, the re-derivation |
| M7 | the version expectation never reaches upstream's client | 52 / **11 red** |
| M8 | the version mismatch is rethrown unnamed | 52 / **11 red**, `foreign:ComponentsVersionsError` |
| M9 | **HANG**: the node accepts and never answers | rc 124, **no summary line**, the check's own `die` names the bound |
| M10 | **DIE BEFORE SUMMARY**: the probe throws at start-up | rc 1, no summary line, the check dies with the probe's stderr |
| M11 | the node emits no version headers | rc 1, no summary line — **recorded as a COARSE arm**: it reddens by refusing the run (`assertProtocolVersion` is strict about silence) rather than by exercising the mismatch assertions. M8 is the arm that makes that statement. |

The harness aborts on a MUTATION MISS, verifies after each arm that the mutation was still present,
wipes and re-takes its backup every run, leaves an in-progress marker, and verifies the restore by
sha256 of all five files.

---

## 5. REPO-WIDE CHECKS AFTER THE CHANGE

Run in this repository's own dev shell (`direnv exec`, node v24.19.0):

| check | result | reference |
|---|---|---|
| `verify_pinned_nightly_single_source` | **28 / 0** | 28 — unmoved by the new `replay` consumer |
| `verify_no_pipeline_predicates` | **69 / 0** | 69 — unmoved |
| `verify_named_checks_exist` | **9 / 0** | 9 — unmoved |
| `verify_reuse_inventory_complete` | **19 / 0** | 19 — unmoved (the entry count assertion is `>= 20`) |
| `verify_provenance_complete` | 62 / **1** | 64 — see below, environment |
| `just check-repo-hygiene` | 26 / **10** | 28 — see below, environment |

**Both reds are the workspace, not L0.** `~/m/dev/aztec-packages` did not exist in this workspace;
`lib.sh` requires it as a sibling and every enumeration here re-derives from its object store. A
**blobless partial clone** of `AztecProtocol/aztec-packages` was made (`--filter=blob:none
--no-checkout --single-branch --branch next`, 64 MB, anchor `233d8e0993` present and resolvable).
`git show <anchor>:<path>` works, which is all the L0 checks need. What it is NOT is the metacraft
fork with its own `.envrc`, `flake.nix`, `nix/wasi-sdk.nix` and `upstream/tsavm` worktree, which is
what `check_repo_hygiene` and `verify_provenance_complete` require — hence those two reds, both of
which name missing fork files and neither of which mentions anything L0 touched.

**A note on `git add -N`.** The new files are intent-to-added so that the repo-wide checks, which
scan `git ls-files`, can see them; without that `verify_pinned_nightly_single_source` fails because
its sandbox stages tracked files only and `pins.json` now names `replay` as a consumer. Nothing is
committed.

---

## 6. OPEN, AND FOR WHOM

- **The network is not established, and that is a measurement.** Five candidate endpoints were
  probed on 2026-08-29 with a real `aztec_getNodeInfo` POST; every one failed (two Cloudflare 522,
  one Netlify 404, two no-response). The transcript is in `pins.json` →
  `live_chain.probed_endpoints`. So `network` is `UNESTABLISHED`, `rpc_url` is `null`, and the
  three NETWORK-level version fields (`l1ChainId`, `l1RollupAddress`, `rollupVersion`) are absent
  rather than guessed. **Consequence, stated rather than left to be found: a node on the wrong L1
  chain would not be caught by today's pin; a node running a different protocol would be.**
- **L1 needs a live chain or committed fixtures.** L1's own deliverable already says "fixtures
  captured from a live chain and committed, so the suite runs without a network, with the capture
  script committed beside them" — which cannot be done until an endpoint exists.
- **The milestone file was NOT edited.** `codetracer-specs` has live agents in it and the brief
  says not to modify other repositories. L0's three verification entries still read
  `status: pending` and carry no `file:`. Whoever updates it should record: the three files above,
  the 74/52/62 split, and the **fifty-one → fifty-five** correction in the Overview and in L0's
  "Why the surface is the deliverable" (both say fifty-one).
- **`getBlockHashMembershipWitness` should come out of L2's route-1 list** and
  `getL1ToL2MessageMembershipWitness` should go in. See §1.
- **The seam is decided and declared, not built.** `replay/src/membership_witness_source.ts` says
  the shared shape is `Pick<AztecNode, …>` over the five witness queries — upstream's own
  signatures, so neither side owns the vocabulary — and `node_client.ts` ends with a type-level
  assertion that a replay client satisfies it. M35's resident adapters satisfy the same type by
  implementing signatures they would have had to match anyway.
- **`strictSurface` is duplicated** (RI-87). Hoisting it into a dependency-free shared package is
  the obvious third option and is deferred with a reason rather than taken silently; L1–L4 may show
  the two guards want different allow-list semantics.

---

# L0 REVIEW — 2026-08-29

Every headline claim above was re-derived independently. Three things changed.

## 7. WHAT THE REVIEW RE-DERIVED, AND IT ALL HELD

- **Fifty-five, three ways, taken again from scratch.** A brace-depth parser over
  `git show 233d8e0993:yarn-project/stdlib/src/interfaces/aztec-node.ts` — not the check's scanner —
  splits the `export interface AztecNode` body on top-level `;` into **55** members with **zero**
  unparsed residue, and the `AztecNodeApiSchema` object literal on top-level `,` into **55** keys.
  The two sets are identical. `Object.keys(AztecNodeApiSchema)` out of the installed
  `@aztec/stdlib@5.3.0-nightly.20260819` is **55** and differs by exactly `getL1ToL2MessageIndex`
  (anchor) vs `getL1ToL2MessageCheckpoint` (nightly). The milestone file's "fifty-one" is wrong and
  fifty-five is right.
- **The partition is exhaustive and disjoint**, re-computed from the source text against the
  anchor's set: 14 permitted, 41 refused across 6 groups, no duplicate, no overlap, nothing
  unclassified, nothing classified that the anchor does not declare.
- **The two opcode-derived corrections hold, and the archive one holds harder than claimed.**
  `vm2/common/opcodes.hpp` at the anchor has exactly the eight world-state opcodes named, and
  `L1TOL2MSGEXISTS` is one of them. Two further measurements the log did not have:
  `EnvironmentVariable` in `vm2/common/aztec_types.hpp` has twelve members and none of them is a
  block hash or an archive root, and `struct TreeSnapshots` in the same file carries exactly
  `l1_to_l2_message_tree`, `note_hash_tree`, `nullifier_tree`, `public_data_tree`. There is no
  archive read anywhere in the AVM's interface with the world.
- **`just verify-l0` re-run: 188 assertions, 0 failures, 74 / 52 / 62**, in this repository's own
  dev shell (node v24.19.0). 188 `ok` lines, three summary lines, no hole.
- **All eleven mutation arms reproduced**, each with the failure set the log records, including
  M9 at rc 124 with no summary line, M10 and M11 at rc 1 with no summary line, and
  `restore verified by digest` at the end. **The MUTATION-MISS abort was exercised**: an arm's
  needle was deliberately broken, and the harness printed `MUTATION MISS … ABORTING`, restored,
  left no in-progress marker, and printed **no arm result** — which is the M32 defect it was
  written for.
- **The fifty-sixth was planted, upstream, at the anchor.** A `git replace` of `233d8e0993` with a
  commit whose `aztec-node.ts` declares one extra member in BOTH the interface and the schema makes
  `verify_node_client_surface_narrow` report **74 assertions, 8 failures** — the count unchanged,
  so it reddens rather than shrinking — and `partition.unclassified` NAMES it:
  `every AztecNode method at the anchor is classified — nothing is left over  expected [none], got
  [getFabricatedFiftySixth]`. The replace ref was removed and the anchor's blob re-checksummed.
- **The "40 of 41" is explained by the check itself and asserted by name.** The control object is
  built from the INSTALLED package's schema, which does not carry `getL1ToL2MessageIndex`;
  `control.notInPackageCount` is asserted `1` and `control.notInPackage` is asserted to be that
  name. 41 − 1 = 40. The discrepancy is the second headline finding, not a tolerance.

## 8. THE BLOCKER WAS FALSE. TWO LIVE AZTEC NODES ANSWER, AND THE CLIENT WORKS AGAINST THEM

`https://aztec.drpc.org` and `https://aztec-testnet.drpc.org` both answer a real
`aztec_getNodeInfo`, both run `nodeVersion 5.2.0`, and **both advertise
`x-aztec-l2circuitsvktreeroot` and `x-aztec-l2protocolcontractshash` equal to the two values
`pins.json` pins.** So the protocol pin is validated against a live chain, and the campaign's open
question "Mainnet has not been verified to exist for Aztec" is answered: it exists, `l1ChainId 1`,
rollup `0x91ff8bbd8ebb07893010d50a48a1609e5ebd8e34`.

Driven against the testnet endpoint, the L0 client did every read L1 needs:

| call | answer |
|---|---|
| `getNodeInfo` | 5.2.0, l1ChainId 11155111, rollupVersion 1821665230 |
| `getBlockNumber` | 60594 |
| `getBlock(n, { includeTransactions: true })` | one `txEffect` |
| `fetchSettledTx(hash)` | upstream's `Tx` |
| `fetchSettledTxEffect(hash)` | `l2BlockNumber 60594`, `txIndexInBlock 0`, `revertCode 0` |
| `getBlockData(n)` | real `GlobalVariables` and `StateReference` |
| `guarded.sendTx`, `'getBlocks' in guarded` | `replay-node-surface-exceeded`, both |
| `fetchSettledTx(<fabricated hash>)` | `SettledTransactionNotFound`, against a real node |

**And one thing genuinely does not work, measured rather than inferred.** `assertProtocolVersion`
REFUSES both endpoints with `field=absent`. The cause is not the client: dRPC's proxy returns the
`x-aztec-*` headers on a single-object JSON-RPC POST and **strips them on a batch (array) POST**,
demonstrated with two `curl`s differing only in the body's shape — and upstream's
`createAztecNodeClient` always batches. The refusal is therefore CORRECT (an unverifiable version is
not a verified one, and it is loud and named) but it means **a pinned `rpc_url` pointing at a proxy
is an endpoint this repository's own version check cannot verify.** Pinning the network needs a
direct node endpoint or a deliberately un-batched version probe. `network` stays `UNESTABLISHED`
and `rpc_url` stays `null` for that reason and no longer for the old one; `pins.json` records both
halves. **L1 is no longer blocked on finding a chain.**

**The stated consequence is now a measurement.** Mainnet and testnet have IDENTICAL
`l2CircuitsVkTreeRoot` and `l2ProtocolContractsHash` and DIFFERENT `l1ChainId`, `l1RollupAddress`
and `rollupVersion`. So "a node on the wrong L1 chain would not be caught by today's pin" is
demonstrated rather than argued — `pins.json` → `live_chain.pin_discrimination_measured`.

## 9. THE REPOSITORY HYGIENE WAS REPAIRED, AND BOTH REDS WERE THE WORKSPACE

Verified first, in the state the implementation left: `just check-repo-hygiene` **26 / 10** and
every one of the ten names a fork-level file (`flake.nix`, `nix/wasi-sdk.nix`, `flake.lock`,
`.envrc`, the artefact directions) on the SIBLING repository; `verify_provenance_complete` **62 / 1**
and the one names `upstream/tsavm`. None names anything L0 touched. The count drops (28 → 26,
64 → 62) are the assertions that are conditional on the missing files, not assertions that vanished.
The four checks the log calls unmoved were re-taken at their reference values to the assertion:
`verify_pinned_nightly_single_source` **28**, `verify_no_pipeline_predicates` **69**,
`verify_named_checks_exist` **9**, `verify_reuse_inventory_complete` **19**.

Then repaired: `../aztec-packages` now IS the metacraft fork — `origin` set to
`https://github.com/metacraft-labs/aztec-packages`, branch `aztec-avm-runtime` checked out (the
`cpp` anchor is an ancestor of it), the `upstream/tsavm` worktree added at the `ts` anchor, and the
fork's dev shell activated so `.direnv` exists and is ignored. After that:
`just check-repo-hygiene` **28 / 0**, `verify_provenance_complete` **64 / 0** — both at their
CAMPAIGN-BRIEF reference values — and `just verify-l0` still **188 / 0**, re-derived from the
fork's object store instead of the partial clone's.

## 10. WHAT THE REVIEW CHANGED IN THE TREE

- **A prose-versus-measurement drift, the campaign's own family.**
  `membership_witness_source.ts` said "Four queries, not five" and "The four correspond one-for-one
  to the AVM's four world-state READS" while `MEMBERSHIP_WITNESS_QUERIES` has **five** entries and
  the check asserts five. There are four world-state READ opcodes and five queries, because
  `NULLIFIEREXISTS` needs both the membership and the low-leaf non-membership form. Corrected in
  four places in that file plus `node_client.ts`, `verify_client_uses_upstream_schema.sh` and the
  `Justfile`.
- `pins.json` and `pinned_protocol_version.ts`, for §8 above.

## 11. STILL OPEN, FOR L1

- **Pin a DIRECT node endpoint**, or send the version probe un-batched. Until then
  `assertProtocolVersion` cannot succeed through a proxy, and that is the one L0 capability a live
  chain does not currently exercise.
- `verify_node_client_surface_narrow`'s probe calls `getBlockData(1)` and `getBlock(n)` without
  `{ includeTransactions: true }`; the live run is what showed that the option is what makes
  `getBlock` answer the question the enumeration permits it for. A fixture-backed L1 check should
  exercise the option, because a `getBlock` without it returns a body-less response and a caller
  that did not notice would see an empty block rather than an error.
