# M36 — Note Discovery and Tagging — IMPLEMENTATION log

Written as I go.

## Step 0 — the state I inherited

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `dc7a1963` | clean |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | one pre-existing edit — NOT to be committed |

`git fetch origin` taken at start: **`HEAD == origin/dev == dc7a19632cbb32b19fbc471bbe8c53b2bbfc444e`,
zero ahead, zero behind.** No rebase needed; the parallel L0/L1 track has not moved since M35's review
pushed.

No sweep was running when I started: `ps -eo pid,etime,cmd | grep -Ei 'verify-m|verify-l'` returns
nothing.

`REUSE-INVENTORY.md`'s last used id is **RI-97** (re-derived from the file, not remembered), so the
next free id is RI-98.

Reference numbers to account for in both directions at the end: sweep M0–M35 = **11,744**, 36
milestones, `delta +0`, 34 of 36 exit 0. M35 = 212 (64/95/53), M28 = 357, M33 = 248, M1 = 181,
`check-drift` 24, `verify_provenance_complete` 68 (**note: M35's log says 70 — to be re-derived, not
quoted**), `check-repo-hygiene` 28, `verify_named_checks_exist` 9,
`verify_reuse_inventory_complete` 19, `verify_pinned_nightly_single_source` 28.

---

## Step 1 — THE ENUMERATION, BEFORE A LINE WAS WRITTEN

Upstream's own implementations of the eight oracles, read at the `cpp` anchor
(`233d8e099336c1773b89e939100af047ed9c4f71`) through the object store, by subdirectory, before
concluding anything is ours to write. **The plan's own vocabulary is stale**, and that is the first
finding:

`computeAppTaggingSecret`, `computeTaggingSecretPoint`, `IndexedTaggingSecret`,
`getIndexedTaggingSecretAsSender`, `deriveTaggingSecret`, `computeSiloedTagFromSecret` and
`computeTagFromSecret` — **zero hits anywhere at the anchor**. They were replaced by an
`AppTaggingSecret` / `Tag` / `SiloedTag` / `TaggingIndexRange` family that lives in
**`@aztec/stdlib/logs`** — a package `orchestration/package.json` already declares. There is also no
`NoteDataProvider`, no `TaggingDataProvider` and no `PXEOracleInterface`; the current shape is
`NoteService` / `LogService` / `EventService` over kv-store-backed stores.

| upstream artefact | at anchor | lines | decision |
|---|---|---|---|
| `UtilityExecutionOracle.getNotes` | `pxe/src/contract_function_simulator/oracle/utility_execution_oracle.ts:471` | 37 | the SHAPE; the body needs `NoteStore` |
| `pick_notes.ts` — `pickNotes`, `selectNotes`, `sortNotes`, `selectPropertyFromPackedNoteContent`, `SortOrder` | `pxe/src/contract_function_simulator/pick_notes.ts` | 160 | **VENDOR** — pure, imports only `Fr` and `Comparator`/`Note` from `@aztec/stdlib/note` |
| `NoteStore.getNotes` (status/owner/slot/scope filtering, block ordering) | `pxe/src/storage/note_store/note_store.ts:155` | 97 of 457 | `cannot-reach-target` — `constructor(store: AztecAsyncKVStore)` |
| `LogService` (10 ctor args, three kv-store stores + a `KeyStore`) | `pxe/src/logs/log_service.ts:42` | 294 | `cannot-reach-target` |
| `syncTaggedPrivateLogs`, `syncSenderTaggingIndexes` | `pxe/src/tagging/{recipient,sender}_sync/` | 356 + 104 | `cannot-reach-target` — both take a store |
| `ExecutionTaggingIndexCache` | `pxe/src/contract_function_simulator/execution_tagging_index_cache.ts` | 33 | **VENDOR** — plain `Map`, no store |
| `resolved_tagging_strategy.ts` (`resolvedTaggingStrategy{To,From}Fields`, the three discriminants) | `pxe/src/contract_function_simulator/noir-structs/` | 66 | **ALREADY VENDORED** by M35 (RI-97) |
| `AppTaggingSecret`, `AppTaggingSecretKind`, `Tag`, `SiloedTag`, `PreTag`, `TaggingIndexRange` | `stdlib/src/logs/` | — | **DEPEND** — `@aztec/stdlib/logs`, already installed |
| `Comparator` (EQ=1…GTE=6), `NoteStatus` (ACTIVE=1, ACTIVE_OR_NULLIFIED=2) | `stdlib/src/note/` | 11 + 8 | **DEPEND** — `@aztec/stdlib/note` |

**There is NO in-memory note or tagging provider anywhere in `yarn-project/` at the anchor.** Every
persistent collaborator is a concrete class taking an `AztecAsyncKVStore` with no interface to
substitute, and every PXE test opens an **LMDB** `openTmpStore`. So the note database itself is
ours — with a stated reason (`cannot-reach-target`) rather than "we didn't find one".

### THE INSTALLED PIN IS THE AUTHORITY, AND IT DISAGREES WITH THE ANCHOR A FOURTH TIME

`CAMPAIGN-BRIEF.md` records this family three times (M23's `AztecNodeDebug`, M34's two zod schemas,
M35's three symbols). Measured here on `@aztec/stdlib/logs`:

| symbol | `cpp` anchor | installed `deletion_era` pin (`5.0.0-nightly.20260626`) |
|---|---|---|
| `AppTaggingSecret` statics | `computeDirectional`, `computeAppSiloed`, `computeViaEcdh` | **`computeUnconstrained` and nothing else** |
| the ECDH helper | `computeSharedTaggingSecret(recipientCompleteAddress, ivsk, sender)` | **absent**; the pin has `deriveAppSiloedSharedSecret(secretKey, publicKey, contractAddress)` |

Three missing STATICS again — the shape M35 measured on `AztecAddress.fromFieldUnsafe`, which is not
a missing export and therefore not a build failure. **The vendored WIRE is unaffected**: it imports
only `AppTaggingSecretKind` (type), `appTaggingSecretKindFromDeliveryMode` and `Tag` from
`@aztec/stdlib/logs`, and all three exist at the pin — verified by reading the pin's own
`index.d.ts` and `app_tagging_secret_kind.d.ts`. So no new shim is owed for the wire; what is owed
is that M36's own derivation is written against the PIN.

---

## Step 2 — THE TIER-2 DECISION, AND THE NUMBER THAT DECIDED IT: **17**

The brief asks whether M36 should close tier 2's `aztec_utl_getContractInstance` so that `transfer`
actually runs, and asks for the number **before** the decision. So the ladder was re-run three ways
in Node against the BUILT bundle (`scratchpad/campaign/m36-ladder-spike.mjs`), and the instrument was
**calibrated against the unmutated bundle first** — it must reproduce M35's shipped ladder before its
answer about a mutated one is worth anything.

### Run 0 — the calibration, and it reproduces M35's figures TO THE BYTE

| program | bytes | outcome | stops at | served |
|---|---|---|---|---|
| `Token.transfer` | **76,875** | refused | `aztec_utl_getContractInstance` | 2 |
| `Token.mint_to_private` | **17,582** | refused | `aztec_utl_getContractInstance` | 2 |
| `PrivateVoting.cast_vote` | **9,507** | refused | `aztec_utl_getContractInstance` | 2 |
| `OracleVersionCheck.private_function` | **6,306** | executed | — | 4, witness **897** |

Every figure equals `PRIVATE-EXECUTION.md` §4's and M35's review's, and the served prefix is the same
two oracles each time: `assertCompatibleOracleVersion`, then `isExecutionInRevertiblePhase`.

### Run 1 — a FABRICATED instance, and the CIRCUIT is the control

`getContractInstance` served with a well-formed `ContractInstancePreimage` (salt 1, deployer 0,
class 2, init hash 3, immutables 4, `PublicKeys.default()`) at the demo's `0x777`:

| program | outcome | stops at | served | error |
|---|---|---|---|---|
| all three | **failed** | **null** | 3 | `Cannot satisfy constraint` |

**Not one further oracle call.** `aztec-nr`'s `get_contract_instance` CONSTRAINS the preimage against
the address it was asked about, so a fabricated instance does not carry `transfer` a single
instruction further — it converts a refusal that names its cause into an unsatisfiable constraint
that names nothing. That is this campaign's own rule (*a missing oracle must never return a plausible
value*) measured from the other side: **here the circuit itself is the instrument that refuses.**

### Run 2 — a REAL instance, at its own DERIVED address, and this is the number

The instance built by upstream's own `createContractClassAndInstance` (class seed 27, deployer
`0x333`, constructor `[deployer, 'Tok', 'TOK', 18]`), executed at the address DERIVED from it —
`0x001e7cb55c8b273c4270f336c1bc48336192fa2e0041be8b2a4bc1e2a34c41cb`:

| program | outcome | **stops at** | served before |
|---|---|---|---|
| `Token.transfer` | refused | **`aztec_utl_getNotes`** — M36's own | 4 |
| `Token.mint_to_private` | refused | **`aztec_prv_getSenderForTags`** — M36's own | **17** |
| `PrivateVoting.cast_vote` | refused | `aztec_utl_getPublicKeysAndPartialAddress` — tier 2's SECOND rung | 4 |
| `OracleVersionCheck.private_function` | executed | — | 4 |

`mint_to_private`'s ledger goes from two oracles to **seventeen** — `getContractInstance`,
`isNullifierPending`, then eleven `getRandomField` draws and a `misc_log` — and stops **inside M36's
tagging family**. `transfer` stops **on M36's first note oracle**.

### THE DECISION: M36 CLOSES `getContractInstance`, AND THE MEASUREMENT IS WHY

**Without it, not one of M36's eight oracles is reachable by any real contract.** Every real private
function stops one rung earlier, so an M36 that stayed strictly inside its eight could only ever
exercise them through synthetic handler calls — the shape M35's own `armOracleSurface` exists for,
and the shape that cannot say anything about a contract. With it, the boundary moves ONTO M36's own
subject for two of the three programs.

It is also small and it is not a fabrication: the wallet ALREADY holds the instances it registered
(`dev_wallet.ts`'s `instances` map, the same one `getContractMetadata` reads), so the oracle is a
lookup with a refusal by name for an address the wallet has never registered — and Run 1 is the
control that says the value has to be real.

**And the stop set is no longer a singleton, which retires M35's strongest sentence by making it
true of a state that no longer exists.** `PRIVATE-EXECUTION.md` §3/§4 and
`test_unimplemented_oracle_refuses_by_name` §5b assert the stops are the singleton
`{aztec_utl_getContractInstance}`. After M36 the set is three distinct oracles, and §5b has to assert
the NEW set with the same strength — otherwise a check that was a measurement becomes a fossil.

**What this does NOT claim: `transfer` still does not complete.** It reaches `getNotes` and stops
there; what lies past `getNotes` has not been measured and is not asserted. `cast_vote` needs a
SECOND tier-2 rung (`getPublicKeysAndPartialAddress`) that M36 does not own.

---

## Step 3 — WHAT WAS VENDORED AND WHAT WAS WRITTEN

| what | where | decision |
|---|---|---|
| `pick_notes.ts` (160) + `execution_tagging_index_cache.ts` (33) | `browser/src/vendor/pxe_notes/` — `PROVENANCE.md` **V12**, RI-98 | vendor |
| `AppTaggingSecret`, `AppTaggingSecretKind`, `Tag`, `SiloedTag`, `computeLogTag`, `Comparator`, `NoteStatus`, `siloNoteHash`, `siloNullifier`, `computeUniqueNoteHash`, `computeNoteHashNonce`, `computeSiloedPrivateLogFirstField` | `@aztec/stdlib`, already installed | depend |
| every note/tagging STORE (`NoteStore`, `LogService`, `SenderTaggingStore`, …) | RI-99 | `cannot-reach-target` |
| `browser/src/wallet/local_history.ts` | the boundary sentence + `LocalHistoryOnly` | write |
| `browser/src/wallet/note_database.ts` | the note table, the tag index, the nullifier set, the sync cache, the offchain sink, upstream's four validations, and `sealPrivateFrame` | write |
| `browser/src/wallet/dev_tagging.ts` | `DevTagging` + `DeterministicEphemeralArrayService` | write |
| the nine oracles | `private_oracles.ts` | write |

`check-drift` **24 -> 25** (one new tree row at one `tracked file count matches` assertion), and its
byte-identical count 631 -> **633**.

### The surface is a FUNCTION of what the handler was given, and that is not bookkeeping

M35 established that *"implemented" means "observed to answer"* — served and exercised are asserted
equal in both directions. M36's nine cannot answer without a note database, so a handler built
without one would carry nine methods declared served that refuse: **the plausible-default shape
wearing a table of contents**, which is M34's own `DEV_WALLET_SERVED` finding. So there are two
partitions — 33/35 without a discovery source and **42/26** with one — both asserted disjoint and
summing at construction, plus two guards the sums cannot see (a `ORACLE_DISCOVERY` name the registry
does not declare, and an overlap with the always-served set).

### `setContractSyncCacheInvalid` and `emitOffchainEffect` — HONOURED, and the ledger says which

M35 served both and both were sinks: the first invalidated nothing because there was no cache, the
second pushed into an array nobody read. With a discovery source attached the invalidation reaches
the cache the note oracles consult and the effect is DELIVERED, and **the ledger detail carries
`honoured=yes|no`** — so "honoured rather than stubbed" is a fact a check reads out of the run rather
than a word in a document.

---

## Step 4 — THE FIXTURE WAS CHOSEN BY MEASUREMENT, AND THAT IS THE STEP THAT MADE THE e2e POSSIBLE

"A note created in block N is discovered and spent in N+2" needs a private function that actually
creates a note. Rather than assume one, every `abi_private` function in both contract packages whose
parameters are fields or integers was enumerated and the promising ones were EXECUTED against this
handler with their oracle ledgers read:

| candidate | note hashes | private logs | tagging oracles it calls | verdict |
|---|---|---|---|---|
| `NoteGetter.insert_note` | **1** | **1** | `getSenderForTags`, `getAppTaggingSecret`, `getNextTaggingIndex` — **all three** | THE FIXTURE |
| `Token.mint_to_private` | 0 | 1 | two of three | no note hash, so nothing to validate |
| `TestLog.emit_raw_private_log` | 0 | 1 | none | the tag would be one the page chose |
| `OracleVersionCheck.private_function` | 0 | 0 | none | M35's fixture; no side effects at all |

**`NoteGetter.insert_note` derives its OWN tag through M36's three tagging oracles.** The wallet
never hands it one — it answers `getSenderForTags`, then `getAppTaggingSecret`, then
`getNextTaggingIndex`, and the contract emits its log at a tag it computed from those answers. So the
discovery is a comparison between two producers rather than a lookup of a value the page placed, and
that is the difference between this and a fixture built from `emit_raw_private_log`.

## Step 5 — FOUR DEFECTS THE FIRST BROWSER RUNS FOUND, EACH OF THEM A SHAPE

1. **A STRUCT STRINGIFIED WHERE A FIELD BELONGED.** The report rendered a claimed note hash as
   `String(entry)`, and upstream's `NoteHash` is a struct whose `toString()` is
   `value=0x… counter=1`. `Fr.fromString` refused it four layers later, in a page. Reading `.value`
   is the only correct thing and a missing one is a named error now rather than `String(undefined)` —
   which would have produced the literal string `undefined` as a note hash.
2. **AN EMPTY SCOPE LIST THAT MEANT "NOTHING" WHERE IT SHOULD MEAN "THE DEFAULT".** With
   `scopes: []`, `getNotes` returned **0** over a note that WAS stored — because upstream's scope
   filter is a set intersection and an empty set intersects nothing. It is the most dangerous shape
   in this milestone: a query that answers "no notes" for a reason that has nothing to do with the
   chain. The frame's own contract scope is now the explicit default, spelled at the one place that
   knows what it is.
3. **A CONTROL WHOSE NEEDLE NOBODY EMITS.** The second wallet's tag was recomputed as
   `(theirs[0] -> theirs[0])` while the contract had derived `(theirs[0] -> msgSender)`. The control
   "did not find" the log — for the wrong reason. It is the absence-over-an-excluded-subject family
   in a control rather than in a subject, and it would have passed. Recomputed for the pair the
   contract actually asked about, so the control now says BOTH halves: the second wallet finds its
   own log, and the first does not.
4. **A CONSTANT THE PAGE NEVER IMPORTED.** `CLASS_ARTIFACT_HASH_SEED` was used and not imported;
   esbuild emitted it as a free identifier and the page died with `ReferenceError` out of Chromium's
   own error list — which is M33's review's finding (a metafile records imports, and a free
   identifier is not one) arriving in a demo. The arm run exited 1 and named it, which is the
   machinery working.

---

## Step 6 — THE THREE CHECKS: M36 = 122 (60 / 29 / 33)

| check | assertions | what it is about |
|---|---|---|
| `e2e_note_discovery_across_blocks` | **60** | a note created in block 1 by a real Noir circuit, discovered by an independently computed siloed tag, validated against the block's own note hashes, and spent in block 3 — with four controls |
| `test_tagging_index_advances` | **29** | the index is RESERVED rather than read, three indexes give three distinct tags, a replayed tag does not double-count, and the deterministic ephemeral stream is the one the oracles actually issued from |
| `verify_local_history_boundary_declared` | **33** | the sentence has one home, the document quotes it, the BUILT bundle carries it, and the runtime PRODUCES the refusal — over a query that could have been answered |

### The measurement, from the browser arm

| | derived |
|---|---|
| `NoteGetter.insert_note` bytecode | **48,754** bytes |
| its solved witness | **3,588** entries |
| oracle calls, all served | **17** |
| the served set with a discovery source | **42**; without one | **33** |
| notes stored after block 1 | **1** |
| `getNotes(ACTIVE)` after creation / after the spend | **1** / **0** |
| `getNotes(ACTIVE_OR_NULLIFIED)` after the spend | **1** |
| the wallet's tag vs the log's first field in the block | **equal**, and the control wallet's differ |
| deterministic ephemeral slots the oracles issued | **3**, and they are the stream's first three |

**The two-producer identity is the one that matters.** `tags.mine` is what the WALLET computed from
its own keys; `sealedFirstFields[0]` is the first field of the log the BLOCK carries, which the
CONTRACT emitted at a tag it derived from M36's three tagging oracles and the sealer then siloed the
way a kernel would. Neither was handed to the other, and they are equal. The control wallet's pair is
equal too — and the two tags are asserted DIFFERENT, so the comparison is not one value twice.

---

## Step 7 — THE MUTATION MATRIX: TEN ARMS, AND EVERY ONE REDDENED ON THE ASSERTIONS WRITTEN FOR IT

`scratchpad/campaign/m36-mutations.sh`. M35's harness, subject changed: the abort-on-miss `sub`, the
wiped-and-re-taken backup with its sha256 manifest, the in-progress marker, and `still_there`
restoring, verifying and **exiting 5** on an undone mutation. Six subjects in the backup set —
M36 adds `note_database.ts`, `dev_tagging.ts`, `local_history.ts` and `LOCAL-HISTORY.md`.

| arm | mutation | result | the failures, READ |
|---|---|---|---|
| M1 | a note the chain never recorded is STORED instead of refused | **60 / 7** | the table holds 2 where 1 belongs, ACTIVE and ACTIVE_OR_NULLIFIED both read 2, and all three fabricated-note control assertions go `null` — the security property of the whole database |
| M2 | the siloed tag drops its app-siloing | **60 / 5** | both two-producer identities (the wallet's tag vs the block's first field), and both wallets stop finding their own log |
| M3 | `getNextTaggingIndex` becomes a getter | **29 / 4** | the deltas read `0 0`, the first index is 0, THREE indexes give ONE distinct tag, and the used-range count is 0 |
| M4 | the deterministic slot allocator reads ambient entropy | **29 / 3** | the same-seed identity, and both stream identities on the slots the ORACLES issued |
| M5 | the boundary answers instead of refusing | **33 / 6** | every assertion in §4 — the refusal is `null`, so it names nothing, carries nothing and bounds nothing |
| M6 | `getContractInstance` returns a fabricated preimage | **60 / 4** | the unregistered-address control's three, and nothing else in the run — which is the arm's point: the partition, the sums and the exercised set are all unchanged |
| M7 | **THE HANG** — the renderer never returns | **0 / 1 with a summary line** | bounded and NAMED: *"the note-discovery arm run exited 1: Runtime.evaluate did not complete within 60000 ms. That is the HANG state reported as a failure."* |
| M8 | **DIE BEFORE THE SUMMARY** — the arm report is hollowed | **1 / 2 with a summary line**, and **M8 held** | `m36_absent` names every absent field in ONE assertion and dies; the hollow survived the run |
| M9 | a figure in `LOCAL-HISTORY.md` is made stale | **60 / 1** | §9 names the figure AND the row |
| M10 | a SPENT note keeps coming back as ACTIVE | **60 / 2** | `getNotes(ACTIVE)` reads 1 where 0 belongs — and the ACTIVE_OR_NULLIFIED reading is still right, which is why the PAIR exists |

**No `MUTATION MISS`, no `ABORTED`, no `DID NOT HOLD`.** The final restore re-verified the sha256
manifest and the tree rebuilt to its pre-run state.

**M6 IS THE ARM WORTH THE SENTENCE.** Four failures, three of them the control and one of them a
document figure the bundle size moved — and *nothing else in the run changed*. The declared
partition, the two sums, the disjointness, the exercised set and the note-discovery path are all
untouched, because the mutation only affects an address the wallet was never asked about in the happy
path. That is the shape M35's review had to write a tenth arm for: a check whose green comes from the
subject doing its job cannot see a refusal that stopped refusing.

---

## Step 8 — WHAT M36 MOVED ELSEWHERE, DECLARED BEFORE THE SWEEP

- **M36's own 122** = 60 / 29 / 33.
- **`check-drift` 24 -> 25** — one new tree row (V12) at one `tracked file count matches` assertion;
  its byte-identical count 631 -> **633**.
- **`verify_provenance_complete` 70 -> 71** — a tree row adds no per-file assertion, and the +1 is
  the one inventory id no row had cited before (RI-98). RI-99 is an inventory entry that no row
  cites, so it adds nothing, which is the check's own rule working.
- **`verify_reuse_inventory_complete` stays 19** — its entry count is a `>=`. It went to 20 with two
  failures first, and both were the check doing its job: RI-99's `rejection-reason` did not begin
  with the admissible tag `cannot-reach-target:` (a colon, not a dash), and its `why` quoted the very
  phrase `_inventory_parser.py`'s WEASEL needle refuses — *"we didn't find one"*, written as the
  thing being avoided. **A needle that cannot tell a citation from a claim** is this campaign's own
  family, and the cheap remedy is to write the sentence differently rather than widen the needle.
- **Packaging figures moved in FIVE documents and every one was found by the check that re-derives
  it going red.** `browser.js` 265.37 -> **265.76**, `testing.js` 290.65 -> **291.05**, `demo.js`
  291.87 -> **292.27**, `worker.js` 293.15 -> **293.54**, `worker-demo.js` 294.23 -> **294.62**,
  `wallet.js` 296.39 -> **303.09** (own module 0.96 -> **1.19 KB**), `wallet-demo.js` 332.94 ->
  **341.56**, the all-chunk total 8,219.32 -> **8,228.17 KB**. `node/node.js` is unmoved for the
  FOURTH time running, because the Node pass is a separate one. Corrected in `BROWSER-PACKAGING.md`,
  `WORKER-NODE.md` §5, `DEV-WALLET.md` §6, `PRIVATE-EXECUTION.md` §2 and §6, `WALLET-BOUNDARY.md` §6
  and `LOCAL-HISTORY.md` §6. **No budget was bumped**: every entry stayed inside the budget M35 set.
- **`verify_pinned_nightly_single_source` 28, `verify_no_pipeline_predicates` 69,
  `verify_named_checks_exist` 9, `just check-repo-hygiene` 28 — all unmoved.** M36 installs no
  package (`@aztec/stdlib/logs` was already a dependency), declares no pin, and adds no
  `| grep -q` predicate.
- **`verify_orchestration_reuse_enumerated` (M18) should be unmoved** — that check pins the
  orchestration's dependency list EXACTLY and M36 adds no dependency at all.

### The two neighbours whose DOCUMENTS moved, measured rather than predicted

- **`BROWSER-GATE.md`'s browser input count 1188 -> 1197** — three new modules of ours (the note
  database, the tagging half, the boundary), two vendored files, and four `@aztec/stdlib` subpath
  modules the tagging derivation reaches for the first time. `just ci-browser-gate` back at **104**.
- **`WORKER-NODE.md` §5's `current` column, every row.** The check re-derives that column and only
  that column, so a moved figure is one cell per row; the historical columns are a record.
  `test_worker_transferable_container_not_copied` back at **74**.

**M28 stays 357 with ONE failing assertion and it is still L0's** — `verify_npm_pack_no_optional_native`
pins the tracked `package.json` list and `replay/package.json` is a fifth tree. Recorded, not fixed,
for the fourth milestone running.

---

## Step 9 — THE REFERENCE TABLE, NAMED BEFORE THE SWEEP RAN

Every milestone M36 could plausibly have moved was run individually first, so the sweep is checked
against a prediction rather than explained afterwards:

| milestone | reference | measured before the sweep | why |
|---|---|---|---|
| M1 | 181 | **182** | `verify_provenance_complete` 70 -> 71 — one inventory id (RI-98) no row had cited |
| M18 | 283 | **283** | M36 adds no dependency, and that check pins the list exactly |
| M27 | 345 | **345** | |
| M28 | 357 | **357**, one failing assertion and it is L0's | `BROWSER-GATE.md`'s input count 1188 -> 1197 was corrected first; the gate is back at 104 |
| M32 | 237 | **237** | `WORKER-NODE.md` §5's `current` column corrected first |
| M33 | 248 | **248** | |
| M34 | 217 | **217** | |
| M35 | 212 | **212** | the ladder still stops at `aztec_utl_getContractInstance`, because M35's own arms attach NO discovery source |
| **M36** | — | **122** | 60 / 29 / 33 |

**Predicted total: 11,744 + 1 + 122 = 11,867.**

`check-drift` is not inside any `verify-m<N>` recipe, so its 24 -> 25 is not part of the total; M1's
+1 is the whole of the campaign-total move outside M36 itself.

---

## Step 10 — THE SWEEP WAS ABORTED ON PURPOSE, AND IT BOUGHT FOUR VALIDATIONS THAT ARE UPSTREAM'S

Killed ten minutes in, three milestones deep. Not a finding about the sweep — *"run your sweep after
your last edit"* — and the abort bought exactly what M35's three aborts bought, by exactly the same
method: **reading upstream's own handler bodies against this one, which is the only work available
while a sweep runs and is the work a check cannot do.**

Four validations, and in every one of them the permissive version is not visibly wrong afterwards:

| what | upstream | what mine did | why it matters |
|---|---|---|---|
| a log retrieval request for another CONTRACT | `fetchLogsByTag`'s first lines THROW | siloed with the REQUEST's address and answered | a contract reads another contract's tagged logs, and the answer is well-formed either way. **This handler's own comment documented the permissive behaviour as though it were the design**, which is worse than leaving it undocumented |
| a scope outside the execution's | `assertAllowedScope` in THREE places (`fetchTaggedLogs`, `getAppTaggingSecret`, `NoteService.getNotes`) | no scope guard at all | a contract derives another account's tagging secret and reads its tagged logs |
| the combined secret set | DEDUPLICATED, with upstream's own comment saying the sources overlap | concatenated | a secret appearing twice scans the same tags twice and returns THE SAME LOG TWICE — the double-count `test_tagging_index_advances`' control is about, arriving from the secret side instead of the index side |
| a transaction with no nullifiers | `#toRetrievedTaggedLog` THROWS | (already present) | a zero `firstNullifierInTx` is a nonce seed the note-hash derivation then uses |

All four are implemented and **two of them have their own control arm** — a cross-contract log
request and an out-of-scope tagging secret, each refused by name, each naming both subjects.
`e2e_note_discovery_across_blocks` **60 -> 66**; **M36 = 128 (66 / 29 / 33)**.

**AND THE SCOPE FIX CORRECTED SOMETHING ELSE THAT WAS ONLY ACCIDENTALLY RIGHT.** `scopes` had been an
optional list defaulting to `[contract]` — a CONTRACT address standing in for an ACCOUNT scope, which
happened to work because the arm stored its note under the contract too. Upstream's `scopes` is one
list of account addresses consulted by all three guards, so it is now required, non-empty, and the
wallet's own accounts; notes are stored under an account scope; and the empty list is refused BY NAME
rather than silently intersecting nothing.

**And upstream's split between a REFUSAL and a `None` was worth getting right.** Its own doc:
*"the only expected `None` case is an invalid recipient address; missing sender data fails while
deriving."* So an out-of-scope SENDER now fails and an invalid RECIPIENT returns `None` — two
statements, kept apart, and the check asks each of them separately.

---

## Step 11 — A FIFTH VALIDATION, FOUND THE SAME WAY, AND IT IS THE STORAGE SIDE OF THE DOUBLE-COUNT

Reading `note_store.ts` against this one after the four above:

**`NoteStore.addNotes` reads the existing note BY ITS SILOED NULLIFIER and calls
`StoredNote.addScope` on it; `NoteStore.getNotes` collects into a `Map` keyed by the same value.**
Mine pushed a row. A note validated a second time under a second scope was TWO rows, `getNotes`
returned it TWICE, and a contract would have tried to spend one note twice — the double-count
`test_tagging_index_advances`' own control is about, arriving from the storage side instead of the
index side.

The table is keyed by siloed nullifier now and a stored note carries a scope SET, which is upstream's
own model. **The control needs the scope set to be non-degenerate**: "one row after a second
validation" is also what a second validation that did NOTHING AT ALL would produce, so the check
asserts the note carries **2** scopes as well as **1** row.

`e2e_note_discovery_across_blocks` **66 -> 69**; **M36 = 131 (69 / 29 / 33)**.

*Every one of the five was found by reading upstream's own handler bodies against this one. None of
them could have been found by a coverage check: the partition was disjoint, summing and fully
exercised, and all nine oracles were already answering.*

---

## Step 12 — THE MUTATION MATRIX, RE-TAKEN AFTER THE LAST EDIT: THIRTEEN ARMS

Re-taken twice, which is the rule rather than an incident: once after the four upstream validations
landed, once after the fifth. **M36 = 131 (69 / 29 / 33).**

| arm | mutation | result | the failures, READ |
|---|---|---|---|
| M1 | a note the chain never recorded is STORED | **69 / 4** | the three fabricated-note control assertions go `null`, plus a document figure. *(It was 7 before the dedup fix: M1's fabricated request moves the note HASH and not the nullifier, so with the table keyed by siloed nullifier it now UNIONS into the existing row instead of adding a second. Smaller blast radius, and the CONTROL is what still catches it — which is what the control is for.)* |
| M2 | the siloed tag drops its app-siloing | **69 / 5** | both two-producer identities, and both wallets stop finding their own log |
| M3 | `getNextTaggingIndex` becomes a getter | **29 / 4** | deltas `0 0`, first index 0, three indexes give ONE tag, used-range count 0 |
| M4 | the deterministic slot allocator reads ambient entropy | **29 / 3** | the same-seed identity and both oracle-slot stream identities |
| M5 | the boundary answers instead of refusing | **33 / 6** | all six of §4 — the refusal is `null`, so it names, carries and bounds nothing |
| M6 | `getContractInstance` returns a fabricated preimage | **69 / 4** | the unregistered-address control's three, and nothing else in the run |
| M7 | **THE HANG** | **0 / 1 with a summary line** | *"the note-discovery arm run exited 1: Runtime.evaluate did not complete within 60000 ms. That is the HANG state reported as a failure."* |
| M8 | **DIE BEFORE THE SUMMARY** | **1 / 2 with a summary line**, **M8 held** | `m36_absent` names every absent field in ONE assertion and dies |
| M9 | a `LOCAL-HISTORY.md` figure is made stale | **69 / 1** | §9 names the figure AND the row |
| M10 | a SPENT note keeps coming back as ACTIVE | **69 / 2** | `getNotes(ACTIVE)` reads 1 where 0 belongs, with the ACTIVE_OR_NULLIFIED reading still right |
| M11 | a contract reads ANOTHER contract's tagged logs | **69 / 4** | the cross-contract control's three |
| M12 | a contract derives ANOTHER account's tagging secret | **69 / 4** | the out-of-scope control's three |
| M13 | a note validated twice becomes TWO notes | **69 / 6** | the table holds 2, `getNotes` returns 2, the scope set is 1, and `stored` is 2 |

**No `MUTATION MISS`, no `ABORTED`, no `DID NOT HOLD`.** `still_there` exits **5** on an undone
mutation — M35's harness, kept. The final restore re-verified the sha256 manifest and the rebuild
reproduced the shipped figures (`wallet.js` 303.48, `wallet-demo.js` 342.08, total 8,228.72).

### AND M13 REDDENED FOR THE WRONG REASON FIRST, WHICH IS M24'S FAMILY IN MY OWN MATRIX

Its first version made `existing` always `undefined` — which removes the scope UNION and leaves the
KEYING, so the second validation overwrote the same map entry. The row count stayed 1, `getNotes`
still returned 1, and **the only assertion that moved was the scope-set non-degeneracy**: one
failure, the arm "detected", and the two-row failure mode it was written for never happened.
*"The check failed" and "the check saw what I broke" are different statements*, and only reading
WHICH assertions went red said so. Keying by `(nullifier, scope)` is the mutation that actually
produces two rows for one note, and it gives six.

---

## Step 13 — THE SWEEP WAS ABORTED A SECOND TIME, AND THIS ONE IS A COLLISION RATHER THAN A FINDING

`git fetch` at sweep launch: **`origin/dev` had moved, `dc7a196..ab779d9`.** One commit, and it is
not L0/L1:

> `m35: tier 2's first rung — the contract instance directory, and the ladder it moved`

**A parallel agent closed `aztec_utl_getContractInstance` while M36 was being written**, touching
`private_oracles.ts`, `private_execution.ts`, `wallet_main.ts`, four documents and M35's own
`test_unimplemented_oracle_refuses_by_name.sh`. The sweep was killed thirty-seven seconds in — a run
whose first milestones measure a different tree from its last is not a measurement — and the tree was
rebased.

### THE TWO MEASUREMENTS AGREE TO THE NUMBER, WHICH IS CORROBORATION THIS CAMPAIGN ALMOST NEVER GETS

Its commit message states the same ladder M36's Step 2 states, taken by a different agent with a
different instrument:

| program | its stop / served | M36's stop / served |
|---|---|---|
| `Token.transfer` | `aztec_utl_getNotes`, 4 | `aztec_utl_getNotes`, 4 |
| `Token.mint_to_private` | `aztec_prv_getSenderForTags`, 17 | `aztec_prv_getSenderForTags`, 17 |
| `PrivateVoting.cast_vote` | `aztec_utl_getPublicKeysAndPartialAddress`, 4 | `aztec_utl_getPublicKeysAndPartialAddress`, 4 |

And both independently found the same safety property: a fabricated instance produces
`Cannot satisfy constraint` because `aztec-nr`'s `get_contract_instance` asserts
`instance.to_address() == address` — **the circuit is the instrument that refuses.**

### AND ITS MODEL IS THE BETTER ONE, SO M36 KEEPS IT AND DROPS ITS OWN

M36 had put `getContractInstance` in its SECOND partition — served only with a discovery source —
and recorded **`refused`** for an address the wallet does not hold. **That writes a fact about the
DATA as a fact about the PARTITION**, which is the confusion the landed version's third ledger
outcome (`unavailable`) exists to prevent, and its own commit message says it tried the collapse
first and watched "the served and refusing sets are disjoint" start failing because of a directory
lookup. It also validates every held instance's address against its own preimage at construction,
with upstream's own `computeContractAddressFromInstance` — which M36 did not.

So the resolution is: **its rung, M36's eight.** `ORACLE_IMPLEMENTED` is **34**, `ORACLE_DISCOVERY`
is **8**, together **42**, and the check asserts the difference is eight AND that
`aztec_utl_getContractInstance` is NOT in the discovery set, so the reconciliation cannot silently
come apart. The unregistered-address control now asserts `ContractInstanceNotHeld` and asserts it is
**NOT** `OracleUnimplemented`, because the two say different things about what to build next.

### THE MERGE

Six conflicted files, all resolved by hand with **diff3's four markers** checked for afterwards
(`<<<<<<<`, `|||||||`, `=======`, `>>>>>>>` — the hazard `origin/dev`'s own history records). Three
of the six were pure additions on both sides and kept both; the three documents' conflicts were all
packaging FIGURES, and every one was re-derived from the merged build rather than merged textually.
`browser/demo/wallet_main.ts` merged without conflict and M36's arm was repointed at the landed
instance directory by hand.

---

## Step 14 — THE REFERENCE TABLE, RE-DECLARED AFTER THE MERGE

| milestone | M35's review's reference | expected now | whose move |
|---|---|---|---|
| M1 | 181 | **182** | M36's — `verify_provenance_complete` 70 -> 71, one inventory id (RI-98) no row had cited |
| M35 | 212 | **226** | **the parallel `m35:` commit's** — `test_unimplemented_oracle_refuses_by_name` 95 -> 109 |
| **M36** | — | **134** | 72 / 29 / 33 |
| M18, M27, M28, M32, M33, M34 | 283 / 345 / 357 / 237 / 248 / 217 | unmoved | |

**Predicted total: 11,744 + 1 + 14 + 134 = 11,893.**

`check-drift` 24 -> **25** and `verify_reuse_inventory_complete` **19** are outside any
`verify-m<N>` recipe or unmoved, so neither is part of the total.

**M28's one failing assertion stays L0's** — `verify_npm_pack_no_optional_native` pins the tracked
`package.json` list and `replay/package.json` is a fifth tree. Recorded, not fixed, for the fourth
milestone running.

---

## Step 15 — A THIRD ABORT, AND IT WAS A SELF-REVIEW OF MY OWN CHECKS

Killed three milestones in. The instrument was the campaign's own: asking of each green assertion
what input would make it red. Two answers, both in M36's own checks, both before the milestone
closed:

1. **A NEEDLE THAT ENUMERATED THE FAILURES INSTEAD OF THE COMPLEMENT, OVER A VALUE SOMEBODY ELSE HAD
   JUST ADDED.** §2b asserts the creation ledger has no refusals, counted as entries beginning
   `refused:`. **The landed tier-2 rung added a THIRD outcome** — `unavailable`, a served oracle with
   no answer for that argument — so the count reads zero over a ledger carrying one. It is the
   "an absence is only as wide as the spellings you enumerated" family arriving through a value
   another agent introduced, which is the way it will keep arriving on a shared branch. It counts
   entries that are NOT `served:` now: the complement, which cannot go stale.
2. **A CONTROL THAT APPENDED TO THE SENTENCE RATHER THAN CHANGING A WORD INSIDE IT.** §2's control
   searched the document for `SENTENCE + " and it also syncs from L1"`. That runs through the same
   `str_has_sub` the real assertion uses — so it is not the second form on this campaign's list — but
   it only ever constrains the matcher against a string LONGER than anything in the file. The case
   that actually distinguishes *"the document quotes the constant"* from *"the document says
   something like it"* is a NEAR MISS, so the control is now the same sentence with `PRODUCED` and
   `SYNCED` swapped — the one substitution that inverts its meaning. **Calibrated both ways**: with
   the inverted claim planted in `LOCAL-HISTORY.md` the check reports **34 / 1**, and without it
   **34 / 0**.

`verify_local_history_boundary_declared` 33 -> **34**; **M36 = 135 (72 / 29 / 34)**.

---

## Step 16 — THE MUTATION MATRIX, FINAL, ON THE MERGED TREE: THIRTEEN ARMS, ALL FIRING

Taken **after the last edit**, on the tree that ships. **M36 = 135 (72 / 29 / 34).**

| arm | result | the failures, READ |
|---|---|---|
| M1 | 72 / 4 | the three fabricated-note control assertions, plus a document figure |
| M2 | 72 / 5 | both two-producer tag identities, and both wallets stop finding their own log |
| M3 | 29 / 4 | deltas `0 0`, first index 0, three indexes give ONE tag, used-range 0 |
| M4 | 29 / 3 | the same-seed identity and both oracle-slot stream identities |
| M5 | 34 / 6 | all six of the boundary check's §4 |
| M6 | 72 / 5 | the unregistered-address control's four, including `ContractInstanceNotHeld` and the not-`OracleUnimplemented` assertion |
| M7 | 0 / 1 with a summary line | the HANG, bounded and NAMED |
| M8 | 1 / 2 with a summary line, **M8 held** | `m36_absent` names every absent field in ONE assertion and dies |
| M9 | 72 / 1 | the figure comparer names the figure AND the row |
| M10 | 72 / 2 | `getNotes(ACTIVE)` reads 1 where 0 belongs |
| M11 | 72 / 4 | the cross-contract control's three |
| M12 | 72 / 4 | the out-of-scope control's three |
| M13 | 72 / 6 | two rows, `getNotes` returns 2, one scope, `stored` 2 |

**No `MUTATION MISS`, no `ABORTED`, no `DID NOT HOLD`, exit 0.**

### AND ONE ARM ABORTED THE WHOLE RUN FIRST, WHICH IS THE GUARD WORKING ON A SHARED BRANCH

M6's substitution was written against M36's OWN `getContractInstance`, and the merge replaced that
method with the landed one. `sub` printed `MUTATION MISS`, restored the tree, verified the manifest
and **exited 3** — it did not rebuild and did not print the result it predicted. That is M32's defect
(*"a mutation that never applied, printed as the arm's result"*) prevented, and it is worth recording
that the way it arose here is new: **on a shared branch the SUBJECT of an arm can be replaced by
somebody else between one matrix run and the next.** Rewritten against the landed
`instanceDirectory`, M6 gives five.

---

## Step 17 — WHAT M36 REUSED, VENDORED AND WROTE

### Reused (depended on, no vendoring)

| artefact | from | why it is a dependency and not a copy |
|---|---|---|
| `AppTaggingSecret`, `AppTaggingSecretKind`, `appTaggingSecretKindFromDeliveryMode`, `Tag`, `SiloedTag`, `PreTag`, `TaggingIndexRange` | `@aztec/stdlib/logs` | already an `orchestration/package.json` dependency; the vendored WIRE already imports three of them |
| `computeLogTag` | `@aztec/stdlib/hash` | the domain separation between `Tag` and `SiloedTag` |
| `siloNoteHash`, `siloNullifier`, `computeUniqueNoteHash`, `computeNoteHashNonce`, `computeSiloedPrivateLogFirstField` | `@aztec/stdlib/hash` | the note validation and the kernel's siloing, upstream's own functions |
| `Comparator` (EQ=1…GTE=6), `NoteStatus` (ACTIVE=1, ACTIVE_OR_NULLIFIED=2), `Note` | `@aztec/stdlib/note` | `pickNotes`' own vocabulary |
| `CompleteAddress`, `deriveKeys` | `@aztec/stdlib/contract`, `/keys` | the ECDH the tagging secret is |
| `EphemeralArray`, `EphemeralArrayService`, `Option`, `BoundedVec`, `NoteValidationRequest`, `LogRetrievalRequest/Response`, `PendingTaggedLog`, `ProvidedSecret`, `ResolvedTx`, `resolved_tagging_strategy.ts` | M35's vendored RI-97 tree | already here; M36 adds none of them |
| M35's executor, ledger, refusal machinery, and `notifyCreatedNote` | M35 | extended (randomness + content) rather than replaced |

**Dependencies added: ZERO.** `verify_orchestration_reuse_enumerated` (M18) is unmoved at 66.

### Vendored — `PROVENANCE.md` **V12**, `browser/src/vendor/pxe_notes`, anchor `cpp` `233d8e0993`, RI-98

| file | upstream path | lines |
|---|---|---|
| `contract_function_simulator/pick_notes.ts` | `yarn-project/pxe/src/…` | 160 |
| `contract_function_simulator/execution_tagging_index_cache.ts` | `yarn-project/pxe/src/…` | 33 |

Both `local-edits: none`. `check-drift` 24 -> **25**, byte-identical 631 -> **633**.
Their dependency lists: `Fr` + `@aztec/stdlib/note` and `@aztec/stdlib/logs` — **all four symbols
present at the INSTALLED pin**, checked in the pin's own `.d.ts` rather than at the anchor.

### Written

| file | lines | its dependencies |
|---|---|---|
| `browser/src/wallet/note_database.ts` | **578** | `@aztec/stdlib/hash`, `@aztec/stdlib/note`, RI-98's `pickNotes`, M35's `NoteData` type, `local_history.ts` |
| `browser/src/wallet/dev_tagging.ts` | **369** | `@aztec/constants`, `@aztec/foundation/crypto/poseidon`, `@aztec/stdlib/{hash,logs,contract}`, M35's `EphemeralArrayService`, RI-98's cache, M34's `separatorFromLabel` |
| `browser/src/wallet/local_history.ts` | **63** | none |
| the nine oracles in `private_oracles.ts` | ~330 added | the three above, plus M35's vendored codecs |
| `tools/run_note_discovery_arms.mjs` | **212** | M35's arms runner, M27's CDP harness |
| `verification/lib_m36_notes.sh`, `_m36_doc_figures.py`, three checks | **200 + 142 + 695** | `lib.sh`, `lib_m27_browser.sh`, M33's `_import_closure.py` stripper |
| `LOCAL-HISTORY.md` | **345** | — |
| `scratchpad/campaign/m36-{mutations,sweep,sweep-sum,ladder-spike,discovery-spike}` | — | M35's harnesses, subject changed |

**RI-99** records the note/tagging STORES as `cannot-reach-target`, with the measurement rather than
an unsuccessful search.

---

## Step 18 — WHAT IS DELIBERATELY NOT DONE, AND THE THREE ENTRIES' HONESTY

All three of M36's planned verification entries are `passed`, each with a `file:` that exists and
contains the named check. Nothing was added and nothing was substituted for a lesser subject.

**But `Token.transfer` still does not complete, and the milestone says so where a reader arrives
first** — in `LOCAL-HISTORY.md` §7's first bullet, in the milestone's Outstanding Tasks, and in the
document header's `:next_steps:`. With tier 2's first rung closed it reaches `aztec_utl_getNotes`, is
SERVED, finds no note for that account and fails the circuit's own balance assertion. **What lies
past `getNotes` for `transfer` has not been measured and is not claimed.**

The rest, stated rather than implied:

- `PrivateVoting.cast_vote` needs tier 2's SECOND rung, `getPublicKeysAndPartialAddress` — a
  directory of other people's keys. It refuses by name.
- Private EVENTS are refused by name; only NOTES are stored.
- No handshake registry, so `resolveTaggingStrategy` serves the `unconstrained-secret` strategy and
  refuses a CONSTRAINED delivery mode by name.
- No reorgs, no archiver, no L1 — `LOCAL-HISTORY.md` §1's whole subject.
- `sealPrivateFrame` is a labelled DEV SHORTCUT across ONE layer. There is no private kernel and no
  proof; the frame below it and the block above it are real and the kernel is not. §8.4's disclosure
  still crosses this seam.
- The four `fact` oracles M35 refused for the ambient-randomness reason are now UNBLOCKED by
  `DeterministicEphemeralArrayService` and are **not served**. That is a later milestone's work, and
  their refusal reasons still name the measurement rather than the remedy — which is now slightly
  stale in one direction and is recorded here rather than silently rewritten.

### And the campaign's own out-of-scope note still applies

Nothing here has verified that anything steps correctly in the actual CodeTracer debugger.
`OUT-OF-SCOPE.md` owns that distinction and M36 does not narrow it: *"the file parses"* and
*"the recording is useful"* remain different claims, and M36 establishes neither about a `.ct` —
it writes no container at all.

---

## Step 19 — A FOURTH ABORT, AND IT IS "FIX A FALSE SENTENCE WHERE IT IS WRITTEN"

Killed two minutes and forty-one seconds in, three milestones deep.

`aztec_utl_recordFact`'s refusal reason says the fact store is not served **because** its collection
type round-trips through an `EphemeralArray` whose slot allocation calls `Fr.random()`. That was
true when M35 wrote it. **M36 answered exactly that measurement** with
`DeterministicEphemeralArrayService`, so the stated cause has been removed and the refusal is now
simply unbuilt — and the sentence is not in a document, it is **in the message the program emits**,
which `CAMPAIGN-BRIEF.md` names as the copy with a user.

*"A refusal whose stated cause has been removed is a refusal a reader will act on wrongly"*: someone
reading it would go and solve the entropy problem that is already solved. Corrected at the source,
with the correction dated rather than the sentence silently rewritten — and the sweep restarted,
because a string in a bundled module is an edit and moves every packaging figure with it
(`wallet.js` 303.79 -> **303.95**, `wallet-demo.js` 342.98 -> **343.14**, the all-chunk total
8,229.62 -> **8,229.78 KB**; all six documents corrected and all three figure checks re-run green).

*This is the fourth deliberate abort of M36's sweep. None of the four was a finding about the sweep;
the first bought four upstream validations, the second was the collision, the third two of my own
checks, and this one a message a reader would have acted on.*

---

## Step 20 — A SECOND COLLISION, AND THE TREADMILL IS THE FINDING

`git fetch` at the fourth sweep launch: **`origin/dev` had moved four more commits.** Three are the
L2 live-chain-replay track (`replay/`, untouched by M36 and untouchable by it). The fourth is

> `m35: tier 2's second rung, and a wire-shape gap the version check cannot see`

— the parallel agent closing **`aztec_utl_getPublicKeysAndPartialAddress`**, which is exactly where
M36's own ladder measured `PrivateVoting.cast_vote` stopping. Rebased again: six conflicted files,
four of them documents whose conflicts were packaging FIGURES and were re-derived from the merged
build rather than merged textually; the two TypeScript conflicts were pure additions on both sides
except one import line, kept in full.

### AND THIS IS WHY THE SERVED-SET FIGURES ARE NO LONGER TYPED INTO THE CHECK

`e2e_note_discovery_across_blocks` §2 asserted the handle reports a served set of **42**. The first
`m35:` commit made it 42; the second made it **43**. A literal would have had to move twice in one
milestone, on a branch where somebody else is closing rungs — *"a constant you have just typed into a
check looks like a measurement to the person typing it"*, with a new way of going stale.

It is four RELATIONS now and not one number: the difference between the two partitions is **eight**,
`aztec_utl_getContractInstance` is **not** in the discovery set, each partition sums to the
re-derived registry count, and the served figure the HANDLE reports equals the one the SURFACE report
does — two producers out of one run. Plus two non-degeneracy floors, so "35 + 33" and "43 + 25" are
partitions of something rather than a set and its empty complement.

`e2e_note_discovery_across_blocks` 72 -> **74**; **M36 = 137 (74 / 29 / 34)**.
**M35 is 239** after the two parallel commits (`test_unimplemented_oracle_refuses_by_name`
95 -> 109 -> 122); none of that is M36's.

---

## Step 21 — THE REFERENCE TABLE, THIRD AND FINAL DECLARATION

Measured individually on the twice-rebased tree at `origin/dev` `0937c72`, before the sweep:

| milestone | M35's review's reference | measured now | whose move |
|---|---|---|---|
| M1 | 181 | **182** | M36's — `verify_provenance_complete` 70 -> 71 (RI-98, an id no row had cited) |
| M18 | 283 | **283** | unmoved — M36 adds no dependency |
| M28 | 357 | **357**, one failing assertion and it is **L0's** | unmoved |
| M35 | 212 | **239** | **the two parallel `m35:` commits'** — `test_unimplemented_oracle_refuses_by_name` 95 -> 109 -> 122 |
| **M36** | — | **137** | 74 / 29 / 34 |

**Predicted total: 11,744 + 1 + 27 + 137 = 11,909.**

---

## Step 22 — A DEFECT IN THE MUTATION HARNESS, FOUND BY LAUNCHING IT TWICE BY ACCIDENT

Two matrix runs were started within a second of each other. Both wrote to one log, and the second's
`rm -rf "$BACKUP"` + re-take ran **while the first still had mutations live** — so the backup was
taken OF A MUTATED TREE, and `--restore-previous` later restored the HANG mutation because that is
what the backup contained.

**The in-progress marker did not prevent it, and the reason is an ordering defect this harness has
shipped since M32 built it:** the refusal reads the marker at startup, and the marker was first
written by the ARM LOOP. Two runs launched in the same second both pass the refusal. That is M32's
own stale-backup family with a cause it did not have — not a session that died mid-mutation, but a
**second run of the same harness**.

`still_there` did its job throughout: it reported `M7 DID NOT HOLD`, restored, and exited 5 rather
than printing a result beside a diagnosis. What it could not do is undo a backup that was already
wrong. The marker is written **before the backup** now, so the second launch refuses before touching
anything, and the recovery was: revert the one live mutation by hand, wipe the corrupted backup
directory entirely, rebuild, and re-verify — `verify-m36` back at **137**.

*(And the recovery met one more thing worth writing down: a killed Chromium leaves a `SingletonLock`
in its profile directory, and the next arm run dies with `exited with 21 before announcing a DevTools
endpoint`. The harness's own diagnostic named it exactly — the kept report was unreadable and the
`die` said so — but the remedy is to remove the lock, not to re-run.)*

---

## Step 23 — THE FINAL STATE OF THE TREE, AND WHAT A REVIEWER SHOULD RE-TAKE FIRST

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `0937c72` (== `origin/dev` at the last fetch) | M36's work, **uncommitted** |
| `codetracer-specs` | `latest` | — | `Planned-Work/Aztec-AVM-Runtime.milestones.org` modified, **uncommitted** |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | its one pre-existing edit, **untouched** |

**No commits, no pushes.** `carry/` is at its pre-run digests and `git status carry/` is clean.
Nothing under `replay/` is in the diff — grepped, zero paths.

### The three things most worth re-deriving

1. **The ladder.** `scratchpad/campaign/m36-ladder-spike.mjs` reproduces M35's published figures to
   the byte before it says anything about a mutated bundle; `m36-discovery-spike.mjs` is the same
   instrument with a discovery source attached. Both are scratchpad and ship nothing.
2. **The two-producer tag identity**, which is what makes the discovery a discovery:
   `tags.mine == sealedFirstFields[0]` with the two tags asserted DIFFERENT.
3. **The sweep**, below, and every unit of every move in both directions.

---

## Step 24 — THE MUTATION MATRIX, THIRTEEN ARMS, ON THE TWICE-REBASED TREE

Re-taken after the second rebase and after the last edit. **M36 = 137 (74 / 29 / 34).**

| arm | failures | what went red |
|---|---|---|
| M1 a fabricated note is stored | 4 | the three fabricated-note control assertions, plus a document figure |
| M2 the tag drops its app-siloing | 5 | both two-producer identities, both wallets stop finding their log |
| M3 `getNextTaggingIndex` becomes a getter | 4 | the deltas, the non-zero start, three-indexes-one-tag, the used range |
| M4 the slot allocator reads entropy | 3 | the same-seed identity and both oracle-slot stream identities |
| M5 the boundary answers | 6 | every assertion in the boundary check's §4 |
| M6 `getContractInstance` fabricates | 5 | the unregistered-address control's four, including not-`OracleUnimplemented` |
| M7 **THE HANG** | 0 assertions, 1 failure, with a summary line | bounded and NAMED at 60,000 ms |
| M8 **DIE BEFORE THE SUMMARY** | 1 assertion, 2 failures, **held** | `m36_absent` names every absent field in one assertion |
| M9 a stale document figure | 1 | §9 names the figure AND the row |
| M10 a spent note stays ACTIVE | 2 | the ACTIVE reading, with ACTIVE_OR_NULLIFIED still right |
| M11 a cross-contract log read | 4 | the cross-contract control's three |
| M12 an out-of-scope tagging secret | 4 | the out-of-scope control's three |
| M13 a note validated twice becomes two | 6 | two rows, two returned, one scope, `stored` 2 |

**No `MUTATION MISS`, no `ABORTED`, no `DID NOT HOLD`, exit 0**, and `still_there` exits 5 on an
undone mutation — demonstrated for real this milestone rather than in a sandbox, when a concurrent
launch left one live.

---

## Step 25 — A THIRD REBASE, AND THIS ONE WAS CLEAN

`origin/dev` moved once more — `0937c72..cd954d8`, *"L2's verification: 282 assertions, and the arm
that tests the control"*. It touches `replay/`, `Justfile`, `pins.json` and L2's own verification
files and **not one of M36's**, so the fast-forward produced zero conflicts.

**The branch moved three times during this milestone**: two `m35:` commits closing tier 2's first and
second rungs on M36's own files, and four L2 commits on `replay/`. The sweep below is taken at
`cd954d8` and is a measurement of that commit.

*(One flake worth recording, because it is a machine fact rather than a finding:
`test_worker_transferable_container_not_copied` reported **0 assertions, 1 failure** —
`the worker node's 'readiness' message did not arrive within 20000 ms. That is the HANG state
reported as a failure` — while three other checks and a Chromium were running. That is M23's review's
bound working exactly as designed, on a loaded box. Re-run on a quiet one it is 74/0.)*

---

## Step 26 — THE SUMMARISER'S REFERENCE TABLE, SET BEFORE THE SWEEP FINISHED

`scratchpad/campaign/m36-sweep-sum.py` carries M35's table with three entries changed, each with its
attribution written beside it in the file rather than only here:

```
m1  181 -> 182   verify_provenance_complete 70 -> 71 — one inventory id (RI-98). M36's.
m35 212 -> 239   test_unimplemented_oracle_refuses_by_name 95 -> 109 -> 122. NOT M36's:
                 two parallel `m35:` commits, rebased onto.
m36  —  -> 137   74 / 29 / 34.
```

Summed independently: **11,909 over 37 milestones.** That is the prediction the sweep is checked
against, and it was written down before the sweep reached m2 — which is what makes `delta +0` a
prediction that held rather than a total that agrees with itself.

---

## Step 27 — A FIFTH ABORT, AND IT IS THE ONE MY OWN INVENTORY BROKE

Killed at m2, two milestones in, on a RED assertion:

```
FAIL negative control NOT caught: FX-23 citing an inventory id that does not exist
```

`verify_fixture_corpus_manifest_complete` — a check M36 does not own and never touched — plants a
fake inventory id in a manifest entry and requires the parser to reject it. The id it planted was
**`RI-99`**, and **M36 created RI-98 and RI-99**. The id existed, the parser accepted it, and a
control that had been catching a real defect since M2 silently stopped controlling. *An inventory
that grows turns a typed absent id into a present one* — this campaign's "an absence is only as wide
as the spellings you enumerated" with the INVENTORY moving instead of the needle.

**And the fix found a second defect underneath it, which is the more serious of the two.** The id is
derived now — one past the highest the inventory declares, so growth moves the needle — and the
derived id is `RI-100`. It still passed. `_manifest_parser.py` matched an inventory id as
`re.findall(r"RI-\d{2}", …)`, so **`RI-100` is read as `RI-10`**, an id that exists, and *a manifest
citing a non-existent three-digit id validates cleanly*. That is a live correctness bug in a shipped
check, reachable the moment this repository's inventory passes 99 — which M36 is what made it do.
`\d{2,}` with a right anchor in both places now.

**The census is closed rather than assumed**: `_inventory_parser.py` uses `\bRI-\d+\b` and is
correct; `tools/provenance.py` has no such pattern; the two-digit form existed in exactly one file.

`verify_fixture_corpus_manifest_complete` 37 -> **38** (the derived id's own non-emptiness
assertion), so **M2 292 -> 293**, and M2's own section in the milestone file records both halves —
because *"a milestone that moves another milestone's count must update that milestone's section"*.

**Expected total: 11,910.**

---

## Step 28 — A SIXTH ABORT, AND THIS ONE IS THE INSTRUMENT REFUSING A STALE CHECKOUT

The fifth sweep died at **m0, thirty-six seconds in**:

```
FAIL aztec-avm-runtime: the workspace checkout shares history with the fresh clone
     (command failed: git cat-file -e 4b627dc9^{commit})
```

`origin/dev` had moved again — `cd954d8..4b627dc`, *"L3: a settled Aztec transaction becomes a .ct
the reference reader parses"* — **while the sweep was running.** That is
`verify_workspace_repos_registered` doing exactly the job M34's log records it for, and it is the
fifth move of this branch during this milestone. Rebased (clean; the commit is L3's and touches
`replay/`, `Justfile` and `verification/build_ct_print.sh`, none of M36's), rebuilt, restarted.

**The count so far, and it is a fact about the branch rather than about M36:** two `m35:` commits on
M36's own files, four L2 commits and one L3 commit on `replay/`, across the writing of one milestone.
Every rebase was clean or hand-resolved with all four diff3 markers grepped for afterwards; the two
that conflicted are recorded in Steps 13 and 20.

---

## Step 29 — A THIRD NON-ZERO EXIT IN THE SWEEP, AND IT IS L2's

**M20 reads 237 with ONE failing assertion, and the count is unchanged** — which is what says a
pinned expectation moved and not a structure:

```
FAIL every check this repository names in its own sources exists
     expected [], got [UNRESOLVED verify_hydrated_roots_declared
                       verification/verify_hydrated_roots_match_state_reference.sh]
```

`verify_named_checks_exist` is 9 assertions with 1 failure. The unresolved name is in **L2's own
file**, at line 11, **in a comment**: the sentence explains what a check called
`verify_hydrated_roots_declared` *would* be, and the scanner counts the mention as a declaration.
That is this campaign's *"a citation is the opposite of a dependency"* family — a check name in prose
read as a check — in a file M36 does not own and never touched.

**Recorded and deliberately NOT fixed**, on the same terms as M28's `replay/package.json` failure:
a second track editing the first track's expectations is a collision this campaign has already paid
for. It belongs to whoever owns `replay/`.

---

## Step 30 — THE SWEEP: M0–M36 at 11,910, delta +0, no hole

Measured 2026-08-30 **after the last edit**, `setsid`-detached in this repository's own dev shell
(node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`, at `origin/dev` `4b627dc`, **74 markers for 37 milestones: no hole**,
**34 of 37 exit 0**:

```
m0 156  m1 182  m2 293  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 239  m36 137
                                                   CAMPAIGN TOTAL 11,910
```

**11,744 + 1 + 1 + 27 + 137 = 11,910 exactly**, and the summariser reports `delta +0` against a
reference table that named all four moves **before the sweep ran** — M1 181 -> 182, M2 292 -> 293,
M35 212 -> 239 and M36's own 137. **Every one of M0–M34 came out at its reference value TO THE
ASSERTION.**

**M36's own 137** is 74 / 29 / 34.
**M35's 239 is NOT M36's**: two parallel `m35:` commits landed tier 2's first and second rungs during
this milestone and took `test_unimplemented_oracle_refuses_by_name` 95 -> 109 -> 122.

### M9 DID NOT FLAKE, AND M15 DID NOT EITHER

M9 is **807, rc 0, 1,280 s**, immediately after m8's 177 s run — D19's standing condition, present
and not fired, the reference split exactly. M15 is **537, 382 s**.

### THE THREE NON-ZERO EXITS, AND ONLY ONE OF THEM IS THIS REPOSITORY'S OWN CAMPAIGN

- **M11 = 262 with NINE failing assertions** — the recorded ninth-upstream-move signature, count
  unchanged. Not repaired; `carry/` left at HEAD.
- **M20 = 237 with ONE failing assertion AND IT IS L2's** — `verify_named_checks_exist` reads
  `verify_hydrated_roots_declared` out of a COMMENT in L2's own
  `verify_hydrated_roots_match_state_reference.sh` and cannot resolve it. Count unchanged at 9.
  Recorded, not fixed.
- **M28 = 357 with ONE failing assertion AND IT IS L0's** — `verify_npm_pack_no_optional_native`
  pins the tracked `package.json` list and `replay/package.json` is a fifth tree. Count unchanged at
  54. Recorded, not fixed, for the fourth milestone running.

### L0, L1, L2 AND L3 CONTRIBUTE ZERO, AND THAT IS A MEASUREMENT

Nine of their check names — `verify_node_client_surface_narrow`,
`test_node_client_refusals_distinguishable`, `verify_client_uses_upstream_schema`,
`e2e_fetch_settled_transaction`, `test_missing_contract_artifact_refused`,
`test_private_half_declared_absent`, `e2e_replay_matches_published_effects`,
`verify_hydrated_roots_match_state_reference`, `verify_state_route_decided_on_measurement` — appear
**zero times as a summary line in the whole sweep log**, grepped one at a time. None of their
assertions is in the 11,910.

### A SWEEP IS A WRITER

`carry/rebase.json` and `carry/exposure.json` were checksummed before the sweep, came out
`79f597b2…` / `3836c2b6…` — the same two post-sweep digests every run since M30 — and were restored,
confirmed by `sha256sum -c`, **all four OK**, `git status carry/` clean.

`origin/dev` was fetched after the sweep and had **not** moved: `HEAD == origin/dev == 4b627dc`.

---

## Final state

| repo | branch | HEAD | pushed | tree |
|---|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `4b627dc` (== `origin/dev`) | — | M36's work, **NO COMMIT** |
| `codetracer-specs` | `latest` | — | — | the milestone file modified, **NO COMMIT** |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | — | its one pre-existing edit, **untouched** |

**No commits, no pushes.** `carry/` at its pre-sweep digests, `git status carry/` clean, nothing
under `replay/` in the diff. `origin/dev` was fetched after the sweep and had not moved.

**M36 = 137 (74 / 29 / 34), campaign total 11,910, delta +0, 34 of 37 exit 0.**
The four post-sweep edits are `CAMPAIGN-BRIEF.md`'s sweep paragraph, this log's last three steps and
the milestone file's header sentence — none of which any check opens except the milestone file, and
**m16 was re-run after it: 223, 2/2, exit 0**, its reference value. `just verify-m36` re-run after
the last of them: **137, 3/3, exit 0.**
