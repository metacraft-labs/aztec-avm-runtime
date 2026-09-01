# Note discovery over a chain we PRODUCED — what that serves, and what it does not

M36's write-up.

**Every figure in §1's ladder, §3's discovery table, §4's tagging table and §6's packaging table is
re-derived from the artefacts and compared AGAINST THIS FILE on every run**, by
`e2e_note_discovery_across_blocks` §9 — each looked for on the line that NAMES ITS SUBJECT rather
than anywhere in the file, and each matched as a DELIMITED figure on that line. Both halves of that
sentence were earned by somebody else: the row anchoring is M24's review's remedy after a document
stated the reverse of its own data with every figure present, and the field anchoring is M33's
review's.

---

## 1. THE BOUNDARY, AND IT IS THE FIRST SECTION ON PURPOSE

**Owned by `verify_local_history_boundary_declared`.**

> these queries serve a chain this node PRODUCED, not a chain it SYNCED: there is no archiver
> client, no L1 and no reorg handling, and a block this node did not produce is refused by name
> rather than fetched

That sentence is not written here. It is `LOCAL_HISTORY_BOUNDARY` in
`browser/src/wallet/local_history.ts`, it is the tail of every `LocalHistoryOnly` refusal the
runtime raises, and this document QUOTES it — so the document, the runtime and the check compare
one string rather than keeping three in step. `CAMPAIGN-BRIEF.md` records what the alternative
costs: *"a correction filed in a neighbouring file is not a correction"*, and the copy with a user
is the one inside a thrown message.

The milestone's own words are *"the claim is asserted rather than only written"*, so the check does
three things and not one:

1. the sentence in this document is byte-identical to the constant in the module;
2. the BUILT bundle exports that constant, with the same value, read out of `wallet.js` rather than
   out of the source;
3. **the runtime PRODUCES the refusal** — a query past the produced history raises
   `LocalHistoryOnly`, in Chromium, and the message carries the sentence. A boundary nothing
   enforces is a paragraph.

### What is different about a self-produced chain, stated rather than implied

| | a real network | here |
|---|---|---|
| where blocks come from | an archiver client over `AztecNode` | the dev node's own block stream; there is no client |
| reorgs | a note can be de-nullified, so `NoteDao` carries block hashes for both events | none; unexercised here |
| foreign logs | most of the tag index belongs to other people | every log was emitted by a transaction this process sealed |
| a block we do not have | fetched | **`LocalHistoryOnly`, by name** |
| what it demonstrates | that sync works | **nothing about sync** |

**Real-chain sync is the separate L0/L1 live-chain-replay track's job.** Nothing in M36 is evidence
for it, and this table is here so that nobody reads M36's green checks as if it were.

---

## 2. TIER 2's FIRST RUNG, AND THE SAME MEASUREMENT TAKEN TWICE INDEPENDENTLY

**Owned by `e2e_note_discovery_across_blocks` §1 and §8.**

M35 measured that `Token.transfer`, `Token.mint_to_private` and `PrivateVoting.cast_vote` all stop
at `aztec_utl_getContractInstance`, tier 2's first rung. M36 asked whether closing it is worth
leaving its own eight for, and answered with the ladder rather than with a plan. Three runs, the
instrument calibrated against the unmutated bundle first:

| run | `Token.transfer` stops at | `Token.mint_to_private` stops at | `PrivateVoting.cast_vote` stops at |
|---|---|---|---|
| the oracle refused (M35, reproduced) | `aztec_utl_getContractInstance`, 2 served | `aztec_utl_getContractInstance`, 2 served | `aztec_utl_getContractInstance`, 2 served |
| a FABRICATED instance served | nothing — `Cannot satisfy constraint`, 3 served | the same | the same |
| a REAL instance, at its derived address | **`aztec_utl_getNotes`**, 4 served | **`aztec_prv_getSenderForTags`**, **17** served | `aztec_utl_getPublicKeysAndPartialAddress`, 4 served |

Two things follow and they point the same way.

**Without that rung, not one of M36's eight oracles is reachable by any real contract.** Every real
private function stops one rung earlier, so an M36 that stayed strictly inside its eight could only
have exercised them through synthetic handler calls — which say nothing about a contract. With it,
two of the three programs stop *on M36's own subject*.

**And the fabricated arm is the control that says the value must be real.** `get_contract_instance`
CONSTRAINS the preimage against the address it was asked about, so a well-formed but wrong instance
does not carry `transfer` one instruction further: it turns a refusal that names its cause into an
unsatisfiable constraint that names nothing. *The circuit is the instrument that refuses here*,
which is this campaign's oldest rule arriving from the other side. The wallet therefore serves the
oracle from the instances it actually registered and refuses an unknown address BY NAME.

**M35's strongest sentence is retired by this rather than contradicted.** "All three stop at
`aztec_utl_getContractInstance`" was true, was re-derived by M35's review, and is now a fact about a
state that no longer exists; `PRIVATE-EXECUTION.md` §3 and §4 say so where they said it.

### THE SAME RUNG WAS CLOSED TWICE, INDEPENDENTLY, AND THE TWO MEASUREMENTS AGREE TO THE NUMBER

While M36 was being written, a parallel `m35:` commit landed on `origin/dev` closing this rung, and
its ladder is **the same three stops with the same served counts — 4, 17 and 4** — taken by a
different agent with a different instrument. That is corroboration of the kind this campaign almost
never gets: two independent derivations of a figure that decides a scope.

**Its MODEL is the better one and M36 keeps it rather than its own.** M36 had put
`getContractInstance` in a SECOND partition, served only when a note-discovery source is attached,
and recorded `refused` for an address the wallet does not hold — **a fact about the DATA written as a
fact about the PARTITION**, which is exactly what makes one oracle appear in both the served and the
refused sets of a single run. The landed version serves it unconditionally from a directory of
instances the wallet HOLDS, refuses an unheld address as `ContractInstanceNotHeld`, and adds a third
ledger outcome, `unavailable`, for that case; it also re-derives every held instance's address from
its own preimage at construction, with upstream's own `computeContractAddressFromInstance`.

So M36's second partition is the **eight** note and tagging oracles and the rung is in the
always-served set. **The two figures are not written into the check.** A second `m35:` commit landed
tier 2's SECOND rung — `getPublicKeysAndPartialAddress`, which is where M36's own ladder measured
`PrivateVoting.cast_vote` stopping — while this milestone was being verified, taking the always-served
set from 34 to **35** and the union from 42 to **43**. A literal would have had to move both times.
The check asserts the DIFFERENCE is eight, that the rung is not in the discovery set, that the two
partitions each sum to the re-derived registry count, and that the served figure the handle reports
equals the one the surface report does — four relations, none of them a number typed in a check.

---

## 3. A NOTE CREATED IN BLOCK 1, DISCOVERED, AND SPENT IN BLOCK 3

**Owned by `e2e_note_discovery_across_blocks` §2–§7.**

### The fixture was chosen by measurement

**Enumerated first and then executed, and the two words are not the same one.** The two contract
packages declare **278** `abi_private` functions across **76** contracts, of which **226** take only
fields, integers and structs. Those were enumerated mechanically; the ones whose NAMES suggested a
note, a log or a tag were then EXECUTED against this handler and their oracle ledgers read. Four are
below. *A claim quantified over a set is only as strong as the members the instrument touched*, so
what is claimed here is that the fixture was chosen from a measured shortlist rather than from
memory — not that all 226 were run.

| candidate | note hash | private log | calls the tagging oracles | verdict |
|---|---|---|---|---|
| `NoteGetter.insert_note` | **1** | **1** | **all three** | the fixture |
| `Token.mint_to_private` | 0 | 1 | `getSenderForTags`, `getAppTaggingSecret` | no note hash to validate |
| `TestLog.emit_raw_private_log` | 0 | 1 | none | the tag would be one this page chose |
| `OracleVersionCheck.private_function` | 0 | 0 | none | M35's fixture; no side effects |

`NoteGetter.insert_note` is the one that creates a note AND derives its own tag through
`getSenderForTags` → `getAppTaggingSecret` → `getNextTaggingIndex`. **The wallet never hands it a
tag**, which is what makes the discovery a discovery.

### The measurement

| | derived |
|---|---|
| `NoteGetter.insert_note` bytecode | **48,754** bytes |
| its solved witness | **3,588** entries |
| oracle calls it made, all served | **17** |
| note hashes its public inputs claimed | **1** |
| private logs its public inputs claimed | **1** |
| the served set with a discovery source attached | **43** |
| the served set without one | **35** |
| notes stored after block 1 | **1** |
| `getNotes(ACTIVE)` after creation | **1** |
| `getNotes(ACTIVE)` after the spend in block 3 | **0** |
| `getNotes(ACTIVE_OR_NULLIFIED)` after the spend | **1** |

The last two are a pair on purpose. A check that read only the ACTIVE side could not tell
*nullified* from *never stored*, which is the both-sides-zero family this campaign has a rule for.

### The chain of custody, step by step

1. **`NoteGetter.insert_note` executes** — upstream's `WASMSimulator` over real ACIR, in Chromium.
   It calls `notifyCreatedNote` (M35's oracle, which now keeps the note's randomness and content
   because a validation request carries both) and then all three tagging oracles.
2. **The frame is sealed into block 1** by `sealPrivateFrame`, which does the KERNEL's job with
   upstream's own hash functions — `siloNoteHash`, `computeNoteHashNonce`, `computeUniqueNoteHash`,
   `siloNullifier`, `computeSiloedPrivateLogFirstField` — and is a **labelled dev shortcut across
   one layer**. There is no kernel and no proof; §8.4's disclosure still crosses this seam.
3. **The wallet computes the siloed tag INDEPENDENTLY** — `SiloedTag.compute({secret, index})` from
   its own keys — and finds the log in the index. Two producers, one value.
4. **The note is VALIDATED before it is stored**: the unique note hash is recomputed here from the
   contract address and checked against the note hashes that transaction actually wrote.
5. **Block 3 carries the note's siloed nullifier**, and `getNotes(ACTIVE)` stops returning it.

### Five validations that are UPSTREAM'S, found by reading its own handler bodies

Three of them were missing from this handler until upstream's `LogService`, `PrivateExecutionOracle`
and `NoteStore` bodies were read against it — **while a sweep was running, which is the only work
available during one and is where M35's three aborts found four validations of exactly this kind.**
In every case the permissive version is not visibly wrong afterwards.

- **A contract may only read logs tagged for ITSELF.** `LogService.fetchLogsByTag`'s first lines
  refuse a request whose `contractAddress` is not the executing frame's. Without it a contract silos
  the tag with ANOTHER contract's address and reads that contract's tagged logs — and the answer is
  well-formed either way. A first version of this file's handler documented the permissive behaviour
  in a comment *as though it were the design*, which is worse than leaving it undocumented.
- **A contract may only act for an account in the execution's SCOPES.** Upstream calls
  `assertAllowedScope` in three places — `fetchTaggedLogs`, `getAppTaggingSecret` and
  `NoteService.getNotes` — and this handler had none of them. `scopes` is required and non-empty
  here, because an empty list makes every scope out of scope, which reads as "the wallet holds
  nothing" rather than as a caller who forgot an argument.
- **The combined secret set is DEDUPLICATED.** Upstream's own comment: *"these sources can overlap
  … so we deduplicate the combined set."* A secret appearing twice scans the same tags twice and
  returns THE SAME LOG TWICE — the double-count §4's control is about, arriving from the secret side
  instead of the index side.
- **A note validated twice is ONE note with TWO scopes.** `NoteStore.addNotes` reads the existing
  note by its siloed nullifier and calls `StoredNote.addScope` on it; `NoteStore.getNotes` collects
  into a `Map` keyed by the same value. A table of ROWS holds two, `getNotes` returns two, and a
  contract tries to spend one note twice — the double-count §4's control is about, arriving from the
  storage side. The scope SET is the non-degeneracy: without it, "one row" is also what a second
  validation that did nothing at all would produce.
- **A transaction with no nullifiers is an error rather than an `undefined` field.**
  `#toRetrievedTaggedLog` throws; every Aztec transaction emits at least one (its own), so a zero
  there is a fact about how the block was sealed. A zero field would be a nonce seed the note-hash
  derivation then uses.

### The controls, each for a different way this could be vacuous

- **Another account's note is not discovered.** A second wallet with a different deterministic seed
  runs the same circuit into the same block. Its log is in the same tag index; the first wallet
  finds **0** of it under its own tag, and its own **1** under its own. So "found" is a statement
  about the tag rather than about the index being non-empty.
- **A fabricated note is refused BY NAME.** The same validation request with the note hash moved by
  one is refused, naming the unique hash and the transaction — so "stored" is a statement about the
  chain rather than about what the contract said.
- **A query past the produced history is `LocalHistoryOnly`.** §1's boundary, produced.
- **An unregistered contract address is refused at tier 2's own rung**, carrying the §2 measurement.
- **A log request for another contract is refused**, naming both addresses.
- **A tagging secret for an account outside the scopes is refused**, naming the scope and the list —
  while an INVALID RECIPIENT still returns `None`, which is upstream's own split and the only `None`
  its doc expects.

---

## 4. TAGGING, FROM THE WALLET'S DETERMINISTIC KEYS

**Owned by `test_tagging_index_advances`.**

| | derived |
|---|---|
| accounts the tagging half holds | **2** |
| the first of three consecutive `getNextTaggingIndex` calls returns | **1** |
| the second | **2** |
| the third | **3** |
| distinct siloed tags those three indexes produce | **3** |
| logs a replayed (secret, index) lookup returns, twice | **1** and **1** |

*(The indexes start at **1** and not at 0, and that is the measurement rather than an off-by-one:
the CIRCUIT reserved index 0 while it was deriving its own tag, so the counter these three calls
advance is one the contract has already used. A run that reported 0, 1, 2 would be a run whose
counter did not survive the execution that came before it.)*

**The index is RESERVED as it is handed out, not merely read.** Two sends to the same recipient that
both used index *n* would produce one tag, and the recipient would see one log where two were sent.
That is why `getNextTaggingIndex` advances a counter rather than returning one, and it is why
upstream's `ExecutionTaggingIndexCache` (vendored, RI-98) sits in front of it: two draws inside one
execution have to agree with each other and with the persisted counter.

**And a replayed tag does not double-count.** The same (secret, index) looked up twice returns the
same single log both times — discovery is idempotent, not accumulating. A tag index that appended on
read would report a note twice and a contract would try to spend it twice.

### The derivation is upstream's, read from the INSTALLED PIN

`CAMPAIGN-BRIEF.md`: *"read the anchor to understand the design; read the INSTALLED PIN to know what
will parse."* M23 met it as `AztecNodeDebug`, M34 twice in zod schemas, M35 three times in one file
set. **M36 is the fourth**, in `@aztec/stdlib/logs`:

| symbol | `cpp` anchor | installed `deletion_era` pin |
|---|---|---|
| `AppTaggingSecret` statics | `computeDirectional`, `computeAppSiloed`, `computeViaEcdh` | **`computeUnconstrained`, and nothing else** |
| the ECDH helper | exported `computeSharedTaggingSecret` | **not exported**; `deriveAppSiloedSharedSecret` instead |

Three missing STATICS, which is not a missing export and therefore not a build failure — the shape
M35 met inside the ACVM at run time. The vendored WIRE is unaffected: it imports only
`AppTaggingSecretKind`, `appTaggingSecretKindFromDeliveryMode` and `Tag`, and all three exist at the
pin. So no new shim is owed; what is owed is that M36's own derivation is written against the pin,
and it is.

**And one hash was nearly missed.** `SiloedTag.compute` is THREE steps — `Tag.compute`, then
`computeLogTag(tag, UNCONSTRAINED_MSG_LOG_TAG)`, then the silo — and a first draft did the first and
the third. The middle one is a domain separation chosen by the secret's KIND; skipping it produces a
well-formed field no contract ever emits, so every lookup would miss and *"no logs found"* would
have been a fact about that function rather than about the chain. Read out of the pin's own
`siloed_tag.js`.

---

## 5. THE MEASUREMENT M35 LEFT OPEN, ANSWERED

**Owned by `test_tagging_index_advances` §4.**

`PRIVATE-EXECUTION.md` §5 records that `EphemeralArrayService.allocateSlot` is
`do { slot = Fr.random(); } while (…)`, so serialising any oracle return carrying an
`EphemeralArray` reads ambient entropy — the measurement that decided four of M35's refusals. **Two
of M36's own eight returns are ephemeral arrays** (`getPendingTaggedLogsV2`, and `getLogsByTagV2`
nested one deep), so M36 had to answer it rather than inherit it.

| | derived |
|---|---|
| slots the deterministic allocator issued | **3** |

`DeterministicEphemeralArrayService` overrides `allocateSlot` with a pre-derived
`poseidon2(seed, counter)` stream under a separator derived from a label, and **refuses by name when
the stream runs out rather than falling back to a random draw**.

**It is upstream's own injection point and not an edit.** `EphemeralArray.fromValues(service, …)`
takes the service from the CALLER, `newArray` reaches its slot through `this.allocateSlot()`, and
`allocateSlot` is a public method — so all fifty-two vendored files stay `local-edits: none` and
`check-drift` still compares the whole tree against the anchor.

The evidence is behavioural, not a name grep: the same seed produces the same first four slots in
two independently constructed services, and a different seed produces different ones.

---

## 6. PACKAGING

**Owned by M27's `verify_browser_chunk_budget` and `verify_provider_half_dd9_clean` §4.**

| | derived |
|---|---|
| the wallet entry's eager set | **304.5 KB** gzipped across **9** files |
| the wallet demo page's eager set | **344.36 KB** gzipped across **13** files |
| `@aztec/aztec.js` bytes in `browser.js`'s eager set | **0** |
| files vendored into `browser/src/vendor/pxe_notes` | **2** |

M36 adds no dependency and no wasm module: the tagging derivation is `@aztec/stdlib/logs`, which was
already installed, and the two vendored files import nothing that was not already reachable. **The
zero did not move**, and it is the one DD-11 rests on.

---

## 7. WHAT IS DELIBERATELY NOT HERE

- **`Token.transfer` still does not complete.** With tier 2's first rung closed it reaches
  `aztec_utl_getNotes`, is served, finds no note for that account and fails the circuit's own
  balance assertion. What lies past `getNotes` for `transfer` has not been measured and is not
  claimed.
- **`PrivateVoting.cast_vote` no longer stops at an ORACLE — it halts inside the CIRCUIT.** This
  bullet said it *"needs a SECOND tier-2 rung, `getPublicKeysAndPartialAddress` … It refuses by
  name"*, which was true when M36 took its ladder and became false while the milestone was being
  verified: the second parallel `m35:` commit landed that rung. Re-measured by M36's review against
  the shipped bundle, `cast_vote` serves five oracles — `assertCompatibleOracleVersion`,
  `isExecutionInRevertiblePhase`, `getContractInstance`, `isNullifierPending` and
  **`getPublicKeysAndPartialAddress`** — and then fails with
  `Assertion failed: 9 output values were provided as a foreign call result for 2 destination slots`.
  That is `PRIVATE-EXECUTION.md` §3b's wire-shape gap, which is where it is analysed; this bullet is
  corrected here rather than left pointing at a rung that is closed, because **a note about a false
  sentence in a neighbouring file is not a correction**.
- **No private events.** `validateAndStoreEnqueuedNotesAndEvents` stores notes and **refuses an
  event validation request by name**: upstream keeps events in a `PrivateEventStore`, another
  `AztecAsyncKVStore` consumer, and accepting the request while storing nothing would make
  `getPrivateEvents` answer an empty set that looks like "there were no events". M34 already refuses
  `getPrivateEvents` for the same reason.
- **No handshake registry.** `resolveTaggingStrategy` serves the `unconstrained-secret` strategy —
  upstream's own default, `address-derived` — and refuses a CONSTRAINED delivery mode by name,
  because a constrained secret comes from an on-chain handshake registry this runtime does not have.
  Returning a handshake discriminant nothing backs would send the contract to look up a secret
  nobody published.
- **No reorgs.** See §1.
- **No proving.** Unchanged since M2; §8.4's disclosure still crosses the seam.

---

## 8. WHAT THE NEXT MILESTONE INHERITS

- A note database and a tagging half in the wallet, so the remaining oracles are a substitution
  rather than a construction.
- Tier 2's first rung closed, with the ladder re-measured on every run — so the next boundary is a
  fact about `getPublicKeysAndPartialAddress` and `getNotes`, not about `getContractInstance`.
- The deterministic ephemeral-slot service, which unblocks every remaining ephemeral-array return —
  including the four `fact` oracles M35 refused for exactly that reason.
- `sealPrivateFrame`, which is the one labelled shortcut between a private frame and a block, and
  the place a real private kernel would go.
