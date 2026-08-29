# L1 — Fetching a Settled Transaction — implementation log

Campaign: `codetracer-specs/Planned-Work/Aztec-Live-Chain-Replay.milestones.org`, milestone **L1**.
Branch: `l1/settled-transaction`, off `dev` at `a2e0acd`. **Nothing is committed** — the review agent commits.

---

## 1. WHAT WAS FETCHED FROM A LIVE CHAIN

Everything below was read from **Aztec testnet at `https://aztec-testnet.drpc.org`** (`l1ChainId`
11155111, rollup `0xd73a91bdcf6891c7642f3e460036e1ef2cc23178`, `nodeVersion` 5.2.0) on
**2026-08-29**, through L0's client unchanged.

**The primary fixture — a settled transaction with a public half.**

| | |
|---|---|
| transaction | `0x2090b63ca3a2714010ae02cf24b2e967965bf481305d929175af971e6ab56ad7` |
| block | **60616** (chain tip 60619 at capture) |
| index in block | 0 |
| revertCode | **0** |
| transaction fee | `0x…185135089cad043d` |
| enqueued public calls | **1**, no teardown |
| contract called | `0x2a9a1d0e8f1974267536abefa565e7a7351f92ddbe95ec13c57c79b70664f7c8` |
| contract class | `0x2b6749411979b61926b6f8836c3a1a28c39e9c0c3fb3322ed6e776f2f02cb6dc` (current == original) |
| **packed bytecode** | **23,157 bytes** |
| published effects | 9 public data writes, 1 nullifier, 0 note hashes, 0 private logs |
| GlobalVariables | blockNumber 60616, timestamp 1787970564, chainId `0x…aa36a7`, feePerL2Gas 1,988,400,363,955, feePerDaGas 0 |
| StateReference | noteHash `0x2f5662fa…`, nullifier `0x09e25d69…`, publicData `0x11293ad4…`, l1ToL2 `0x12def342…`, archive `0x2d0f40ed…` |

**The second fixture — a settled transaction with NO public half.**

| | |
|---|---|
| transaction | `0x1533315086638c2c474dde463c6a6a5ad684f6bd26869c2af9a77519ad4a07e0` |
| block | **60620** |
| enqueued public calls | **0** |
| published effects | **12 note hashes, 15 nullifiers, 2 private logs**, 1 public data write |

That second one is the private-half deliverable's evidence: a transaction whose private half's
*effects* the chain published in quantity and whose *execution* it did not publish at all.

**And four questions asked of the live node whose answers are recorded as refusals**: a fabricated
transaction hash (`getTxByHash` → `null`, `getTxEffect` → `null`), a fabricated contract address
(`getContract` → `null`) and a fabricated class id (`getContractClass` → `null`). Every one of them
is declared as fabricated inside the fixture, in `provenance.fabricatedProbes`, with a note saying
what it is for.

### Two facts about the live chain that nothing in this repository had recorded

1. **`getTxByHash` PRUNES; `getTxEffect` DOES NOT.** *(The QUALITATIVE half of this is confirmed by
   the review. The "**36 blocks**" below is NOT — it is two sightings four hours apart generalised
   into a constant, and the review measured 54–65 blocks and then found the mechanism, which is a
   FINALITY LAG rather than a block count. **Read §8.5 instead of this paragraph's number.**)*
   Scanning 140 testnet blocks: every transaction
   within roughly the last **36 blocks** answered, and every transaction older than that answered
   `undefined` while its `TxEffect` was still served in full — from `getTxEffect` and from the
   block body alike. Two independent sightings: at tip 60605 the oldest fetchable was block 60570
   (35 back) and the newest pruned was 60567 (38 back); at tip 60620 the oldest fetchable was 60583
   (37 back). A replay needs the `Tx` — it is what `AvmTxHint.fromTx` consumes — so **a settled
   transaction can become unreplayable while remaining perfectly visible in a block explorer.**
   This is a property of the node's configuration, not of the protocol. It is why
   `just capture-replay-fixture` is a deliberate act and not part of `verify-l1`, and it is the
   sharpest argument for committing fixtures at all: an old transaction cannot be re-captured.

2. **Aztec mainnet is live and completely idle.** `https://aztec.drpc.org` answers, `l1ChainId` 1,
   tip 64544 — and **150 consecutive blocks (64395–64544) carry zero transactions.** *(Re-taken by
   the review at tip 64571: **200 consecutive blocks (64372–64571)**, still zero. See §8.5.)* So both
   fixtures are testnet's by necessity rather than by preference, which the milestone asked to be
   said explicitly.

Both facts are in `pins.json` → `live_chain.captured_fixtures._comment`, and the first is also in
`replay/src/settled_transaction.ts`'s header where a caller meeting `SettledTransactionNotFound`
will find it.

---

## 2. WHAT WAS BUILT

```
replay/src/settled_transaction.ts   the fetch, the three-stage artifact refusal, the public-half
                                    declaration, and the resolution's unguarded control mode
replay/src/private_half.ts          the private-half declaration, both branches
replay/tools/settled_fixture.ts     the fixture format, the recorder and the player  (see §4)
replay/tools/capture_settled_fixture.mjs   the capture script, committed beside the fixtures
replay/fixtures/testnet_settled_tx.json        16 recorded calls, 172 KB
replay/fixtures/testnet_private_only_tx.json   11 recorded calls
replay/src/index.ts                 L1's exports (NOT the fixture format — see §4)
replay/tsconfig.json                `tools/` added to `include`, so the fixture module type-checks
verification/lib_l1_settled_tx.sh   work dir, fixture assertions, the probe prologue
verification/e2e_fetch_settled_transaction.sh        125 assertions
verification/test_missing_contract_artifact_refused.sh   94 assertions
verification/test_private_half_declared_absent.sh     61 assertions
verification/lib_l0_node_client.sh  ONE backwards-compatible edit: `l0_run_probe` takes the
                                    transcript sentinel as a parameter, defaulting to `l0.done`
Justfile                            verify-l1-{fetch,artifact,private}, verify-l1,
                                    capture-replay-fixture
pins.json                           live_chain.captured_fixtures; an L1 history entry; the
                                    "L1's first task" sentence corrected to what L1 actually did
REUSE-INVENTORY.md                  RI-88 (Tx's own public-call accessors) and RI-89 (recording at
                                    upstream's JsonRpcFetch)
scratchpad/campaign/l1-mutations.sh  sixteen arms plus a self-test of the harness's own red line
```

### The refusals L1 adds, and what each is about

| class | `kind` | the fact it reports |
|---|---|---|
| `MissingContractArtifact` | `replay-missing-contract-artifact` | the node does not know a contract the public half calls — at one of three stages, naming the address |
| `SettlingBlockUnavailable` | `replay-settling-block-unavailable` | the chain HAS the transaction and will not serve the block it settled in |
| `FixtureMiss` | `replay-fixture-miss` | the RECORDING does not carry this request. Not an answer |

`MissingContractArtifact`'s three stages exist because there are three different ways for the
bytecode not to be there and a caller deserves to know which:

- `instance` — `getContract` → nothing. Never published for public execution, so there is no class
  id to name and the refusal does not invent one.
- `class` — the instance is published and `getContractClass` → nothing. The node knows where the
  contract is and not what it runs; the refusal names the address **and** the class id.
- `bytecode` — both resolve and `packedBytecode` is **empty**. This is the sibling campaign's own
  failure in its own shape: an artefact that resolves, a length of zero, and an AVM that starts,
  reads nothing and emits a sentinel inside a well-formed container.

### The public half is declared too

A transaction with no enqueued public calls is common on Aztec — the scan that found these fixtures
met one in the same run. Its replay has nothing to execute, and an empty `contracts` array says
that in exactly the same way it would say "the resolution failed". So `publicHalf` is a declaration
with a count and a sentence, and L2/L3 read the declaration rather than an array's length. The
second fixture is what exercises it.

---

## 3. THE THREE CHECKS AND THEIR CONTROLS

`just verify-l1` — **280 assertions, 0 failures** (125 / 94 / 61), in this repository's own dev
shell (node v24.19.0). **No check touches the network.**

| check | the control, and what it proves |
|---|---|
| `e2e_fetch_settled_transaction` | An unknown hash is refused by name — and it is **the live node's own `null`**, captured, not a synthesised one. **Plus the control's own control**: a request the recording does not carry is `FixtureMiss` inside `NodeUnreachable` and NOT not-found, so an incomplete fixture cannot masquerade as a chain that does not have the transaction. Plus: one recorded response corrupted in memory is refused by **upstream's zod**, with the intact recording answering in the same process. Plus: a fixture with two provenance fields removed is refused naming both, with the intact one loading. |
| `test_missing_contract_artifact_refused` | The real contract resolves, with its 23,157 bytes read back off the buffer — through the **same function** the refusals come from. And **§6 produces the well-formed nothing**: `resolvePublicContractsUnguardedForControls` is that same function with one flag flipped, and what it returns is an object with the address, the right shape and `packedBytecodeBytes: 0`. Over the *intact* recording the same unguarded path resolves with the same bytes, so the zeros are a measurement of the edits and not a property of the flag. |
| `test_private_half_declared_absent` | Upstream's own `PrivateExecutionResult.random(2)` through the **same** `declarePrivateHalf`, which answers `available` with non-zero calls, ACIR bytes and partial-witness entries — so the absence statement is a branch and not a printed literal. Non-degenerate on the other side too: the settled arm is asserted over a transaction with **12 note hashes, 15 nullifiers and 2 private logs**, so "the chain carries the effects and not the execution" is said about a transaction that had a private half. |

Two smaller controls worth naming, because both were written after asking what would have to break:

- **Every one of the artifact arms is the REAL fixture with ONE recorded answer replaced**, and each
  substitution asserts it found its needle. An arm built from a hand-written fixture would be
  measuring a file somebody typed.
- **The version headers are exercised in both recorded shapes.** Played back as captured (the batch
  POST, the only shape upstream's client sends) `assertProtocolVersion` refuses with `field=absent`
  — the live behaviour, reproduced offline. Played back with the un-batched probe's headers the
  same client accepts, observing all five `ComponentsVersions` fields with the two pinned ones equal
  to the pin. So the obstacle is measurably **the proxy** and not this repository's version check.

---

## 4. THE FIXTURE FORMAT, AND WHY L0'S OWN CHECK MOVED IT

A fixture is a recording of **upstream's `JsonRpcFetch`** — the transport `createSafeJsonRpcClient`
takes as a parameter — keyed per request, not per POST. Playing it back drives the real
`createAztecNodeClient` over the real `AztecNodeApiSchema`, so **upstream's zod validates the
committed bytes on every run**. A fixture captured at the object layer would be read back by code we
wrote, and one that had drifted from the schema would read exactly like one that had not.

**A miss THROWS.** Answering `undefined` would make an incomplete recording read as
`SettledTransactionNotFound` — a fact about our recording reported as a fact about the chain, which
is the collapse L0's refusal classes exist to prevent, one layer down.

**The module was written in `replay/src/` and L0's `verify_client_uses_upstream_schema` went red on
it**: `…and replay/src does not declare [jsonrpc]  expected [0], got [1]`. The player assembles a
JSON-RPC response envelope by hand, and L0's deliverable is that nothing in `replay/src` declares a
wire type. **The scanner was right and the file was in the wrong place** — a fixture recorder is
test infrastructure, not part of the client a browser ships. It lives in `replay/tools/` beside the
capture script, `replay/tsconfig.json` includes `tools/` so it is still type-checked, and
`replay/src/index.ts` deliberately does not re-export it. `l1_prepare` asserts it is not in `src/`,
so the move cannot quietly undo itself.

**The version headers are recorded twice**, because the endpoint proxies: `onBatchPost` is what
upstream's client actually saw (empty) and `onSingleObjectPost` is a deliberately un-batched probe
taken in the same run and labelled a **reconstruction** inside the file. A fixture that silently
stored the second would be kinder than the chain it came from.

---

## 5. MUTATION RESULTS — sixteen arms, every one red, each on the assertions written for it

`scratchpad/campaign/l1-mutations.sh` (counts are `<total> / <red>`)

| arm | what it breaks | result |
|---|---|---|
| N1 | **the primary deliverable's guard is off** — an unknown contract becomes a plausible value | 94 / **32 red** |
| N2 | the refusal stops NAMING THE ADDRESS | 94 / **7 red** |
| N3 | **zero-length bytecode is accepted** — the sibling campaign's failure, re-introduced | 94 / **8 red**, including the stage set |
| N4 | the private-half STATUS becomes a printed literal | 61 / **2 red**, the control and the "they differ" |
| N5 | the published effects stop being read off the `TxEffect` | 61 / **3 red** |
| N6 | a fixture miss answers `null` instead of throwing | 125 / **3 red** |
| N7 | a provenance field stops being required | 125 / **2 red** |
| N8 | the fixture's declared provenance drifts from its recorded responses | 125 / **1 red** |
| N11 | the fetch swallows the refusal and returns a transaction with no contracts | 94 / **6 red** |
| N12 | a recorded response drifts — the bytecode is no longer the bytes the chain sent | 125 / **1 red** (23,157 → 23,154) |
| N13 | the locally-originated branch removed entirely | rc 1, **no summary line** — recorded as a **COARSE** arm |
| N14 | the un-batched header reconstruction is emptied | 125 / **4 red** |
| N15 | the settling-block refusal collapses into "not found" | 125 / **1 red** |
| N16 | the declared contract reference block claims the settling block while the wire sends none | 94 / **2 red** |
| N9 | **THE HANG ARM** | rc **124**, no summary line, the check's own `die` naming the bound |
| N10 | **THE DIE-BEFORE-SUMMARY ARM** | rc 1, no summary line |
| NMISS | the harness's own red line, run alone | `MUTATION MISS … ABORTING`, restore, **no arm result printed** |

Every arm verifies after the run that its mutation was still present. The backup is wiped and
re-taken every run, an in-progress marker refuses a run that died mid-mutation, and the restore is
verified by sha256 of all four files. (The sixteen-arm figures above are from the full run; N16 was
added after it and measured on its own, with the check at its final 94.)

**Two arms were wrong on their first run and both are recorded rather than quietly fixed**, because
both are failure states `CAMPAIGN-BRIEF.md` already names:

- **N9's first form was not a hang.** `await new Promise(() => {})` makes node print
  *Detected unsettled top-level await* and exit **13** in under a second — M24's exact finding,
  met again. It reported `rc=13, no summary line`: a die-before-summary wearing a hang's label.
  A live `setInterval` keeps the event loop from draining, and the arm now reaches its bound and
  reports **rc 124** with the check's own `die` naming it.
- **N12's `verify_mutation_survived` needle was the PRE-mutation text**, so the harness reported
  `MUTATION WAS UNDONE DURING THE RUN` and aborted with exit 3 — over an arm that had in fact
  applied and had in fact gone red. The guard failing safe is the right direction, and it is worth
  recording that the guard's own needle is a thing that can be wrong.
- **N4's first form was the branch removal now filed as N13.** It reddens by killing the probe
  rather than by exercising the control, so it was demoted and labelled, and a precise arm — the
  status constant — was written beside it. L0's M8/M11 pair is the precedent.

---

## 6. WHAT MOVED ELSEWHERE, AND WHAT DID NOT

Measured in this repository's own dev shell, before and after L1's edits:

| check | result | reference |
|---|---|---|
| `just verify-l0` | **188 / 0** (74 / 52 / 62) | 188 — unmoved, with `lib_l0_node_client.sh` edited |
| `just typecheck-replay` | passes | — |
| `verify_pinned_nightly_single_source` | **28 / 0** | 28 |
| `verify_reuse_inventory_complete` | **19 / 0** | 19 (the entry count is `>= 20`, so RI-88/89 add none) |
| `verify_no_pipeline_predicates` | **69 / 0** | 69 |
| `verify_named_checks_exist` | **9 / 0** | 9 |
| `verify_transcript_truncation_detection_uniform` | **44 / 0** | 44 |
| `verify_provenance_complete` | **64 / 0** | 64 |
| `just check-repo-hygiene` | **28 / 0** | 28 |

**The one shared file L1 edited is `verification/lib_l0_node_client.sh`**, and the edit is one
parameter: `l0_run_probe` takes the transcript sentinel, defaulting to `l0.done`. L1's probes end
`l1.done` so a transcript says which milestone wrote it. The alternative was a second copy of the
probe ritual, which is how a transcript check comes to be written without a completeness refusal —
the thing `verify_transcript_truncation_detection_uniform` exists to prevent. `verify-l0` was
re-run after the edit and is 188 / 0 with its 74 / 52 / 62 split unchanged.

**`verify_pinned_nightly_single_source` caught the L1 history entry** on its first run: it requires
the newest entry to name both npm pin values verbatim, so that "no pin moved" is a stated fact
rather than an absence. The entry says them now.

---

## 7. STILL OPEN, FOR L2 AND FOR WHOEVER UPDATES THE MILESTONE FILE

- **The milestone file was NOT edited.** `codetracer-specs` has live agents in it. L1's three
  verification entries still read `status: pending` and carry no `file:`. Whoever updates it should
  record the three files, the **125 / 94 / 61** split (this line said 91, which is a typo for the
  94 every other section and the check itself report), and — under L1's deliverables — that the
  fixtures are testnet's because **mainnet is idle**, and that `getTxByHash` **prunes at the
  chain's finalized tip** (§8.5 — NOT "roughly 36 blocks"), which bounds what "a demo with recent
  Aztec transactions" can mean. *Done by the review; see §8.*
- **`network` is still `UNESTABLISHED` and that was a decision, not an omission.** The open question
  offered L1 two ways to pin an endpoint: find a direct node, or send the version probe un-batched.
  No direct endpoint was found, and the second is a *second way of talking to a node* — the kind of
  second wire path L0's whole "nothing here declares a schema" deliverable exists to prevent. So the
  fixtures record the header absence as what the client saw, beside a reconstruction that is
  labelled one. `pins.json`'s `live_chain._comment` now says that instead of saying it is L1's first
  task.
- **L2 inherits the second fixture as a hazard, not just as a fixture.** A private-only transaction
  has nothing for an AVM to execute; `publicHalf.present` is the field to read, and an empty
  `contracts` array is not that field.
- **The retention horizon bounds L4.** "Every public transaction in a block replayed" is only
  possible for blocks inside the window, and a range replay over older blocks will meet
  `SettledTransactionNotFound` for transactions the block body still lists. That is the refusal
  behaving correctly and it needs saying in L4's per-transaction outcome table.
- **THE FIX FOR `resolvedAsOf` IS ONE ARGUMENT IN THE CODE AND A WHOLE RE-CAPTURE IN PRACTICE —
  L1's review judged it and left it with L2, for a reason the implementation did not have.**
  See §8.6. Whoever takes it in L2 should capture the fixture WITH the reference block from the
  start, because adding it later invalidates every committed recording.

- **`getContract` RESOLVES AS OF `latest`, AND THAT IS NOW A DECLARED LIMITATION RATHER THAN AN
  OPEN GAP — but it is still a limitation and it is L2's to close.** `getContract(address,
  referenceBlock?)` defaults to `'latest'`, and upstream's own doc comment says the instance's
  current class id is resolved as of that block — so a contract UPGRADED between the settling block
  and now would resolve to the class it runs today, and a replay would execute the wrong program
  without anything failing. L1 does not pass the argument, so every `ContractResolution` carries
  `resolvedAsOf: 'latest'` and `test_missing_contract_artifact_refused` asserts three things: the
  declared value, that every resolution carries it, and **that the recorded wire call really went
  out with no reference-block argument** — so the limitation cannot be declared away (mutation arm
  N16). The fix is one argument and it belongs to L2, which has to pass a reference block to the
  five membership-witness queries in the same change; it also wants a fixture of an upgraded
  contract, which this milestone did not find one of.

---

## 8. THE REVIEW — what was re-taken, what held, and the two things that did not

Every measurement below was taken independently by L1's review on 2026-08-29, in this repository's
own dev shell (node v24.19.0) or against the live chain by raw JSON-RPC that reaches none of this
repository's code.

### 8.1 The counts reproduce, and so does everything L0 measured

| re-taken | result | reference |
|---|---|---|
| `just verify-l1` | **280 / 0** (125 / 94 / 61) | 280 — to the assertion |
| `just verify-l0` | **188 / 0** (74 / 52 / 62) | 188 — unmoved by the `l0_run_probe` edit |
| `just typecheck-replay` | passes | — |
| `verify_no_pipeline_predicates` | 69 / 0 | 69 |
| `verify_named_checks_exist` | 9 / 0 | 9 |
| `verify_pinned_nightly_single_source` | 28 / 0 | 28 |
| `verify_reuse_inventory_complete` | 19 / 0 | 19 |
| `verify_transcript_truncation_detection_uniform` | 44 / 0 | 44 |
| `verify_provenance_complete` | 64 / 0 | 64 |
| `just check-repo-hygiene` | 28 / 0 | 28 |

Mutation matrix re-run in full: **sixteen arms, every one red, every failure count identical to
§5's** — 32 / 7 / 8 / 2 / no-summary / 3 / 3 / 2 / 1 / 6 / 1 / no-summary / no-summary / 4 / 1 / 2 —
and `restore verified by digest`. `NMISS` run alone: exit 2, `MUTATION MISS … ABORTING`, **no arm
result printed**, no in-progress marker left, all four files at their pre-run digests.

**One label in §5 is imprecise and the mechanism behind it is right.** N9 is recorded as
`rc 124`; the ARM's rc is 1 and the **PROBE's** rc is 124. The arm log carries
`FAIL the artifact probe exited 0  expected [0], got [124]` followed by the check's own `die`
naming the 20 s bound, so it is a real timeout properly diagnosed — but "the check failed" and
"the check saw what I broke" are different statements and the number should name which process
it belongs to.

### 8.2 THE FIXTURES ARE REAL — 25 of 27 recorded responses are byte-identical to the live chain

The strongest available check on a committed recording is to ask the chain the same questions
again. Every recorded call in both fixtures was re-issued by raw JSON-RPC (no repo code in the
path) and the results compared by sha256 of their JSON:

**25 identical, 2 different, 0 errors.** The two that differ are both `aztec_getBlockNumber([])` —
the chain tip, which necessarily moves. Every one of the four fabricated probes answers `null`
live, exactly as recorded, so the labelled-fabricated values really are values the chain does not
have. Nothing fabricated is presented as real; every provenance field required by
`REQUIRED_PROVENANCE_FIELDS` is present and non-empty in both files.

The proxy claim was re-taken with two `curl`s differing only in the body's shape: the
single-object POST returns **six** `x-aztec-*` headers, the batch POST returns **zero**. So
`onBatchPost: {}` is what the client saw and the labelled reconstruction is honest.

### 8.3 The zod claim reproduces, and so does L0's guard

Corrupting one recorded response in memory — `getTxEffect`'s `data.revertCode`, a number, set to a
string — and running the real client over the real `AztecNodeApiSchema`:

```
INTACT   : RETURNED  block=60616 revertCode=0 contracts=1 bytecodeBytes=23157
CORRUPTED: THREW ZodError  path ["data","revertCode"]  "expected number, received string"
INTACT#2 : RETURNED  block=60616 revertCode=0 contracts=1 bytecodeBytes=23157
```

Upstream's zod really does validate the committed bytes on every run, and the intact recording
answers in the same process.

**And L0's schema guard genuinely fires on the relocation.** Copying `settled_fixture.ts` back
into `replay/src/` and running `verify_client_uses_upstream_schema` gives
**62 assertions, 1 failure** — `…and replay/src does not declare [jsonrpc]  expected [0], got [1]` —
with the COUNT unchanged, which is what says it is a red check and not a smaller one. The move to
`tools/` did not weaken it; `l1_prepare` asserts the file is not in `src/` and that assertion is
one of the 94.

### 8.4 A DEFECT FOUND AND FIXED: three shell commands executed out of a comment, on every run

`l1_imports()` builds the probe prologue with `cat <<EOF` — **unquoted**, because it has to expand
`$L1_SRC` and `$L1_TOOLS`. Every template literal in that heredoc is correctly escaped `\``…\``.
Three backticks in **prose** were not:

```
// THE FIXTURE FORMAT IS IMPORTED FROM `replay/tools/`, NOT FROM THE PACKAGE'S INDEX, and that is
// L0's own check's doing: `verify_client_uses_upstream_schema` asserts that nothing in
// `replay/src` declares a wire type, …
```

An unescaped backtick in an unquoted heredoc is **command substitution**. So every run of every one
of L1's three checks executed `replay/tools/`, `verify_client_uses_upstream_schema` and
`replay/src` as commands, printed

```
lib_l1_settled_tx.sh: line 86: replay/tools/: Is a directory
lib_l1_settled_tx.sh: line 86: verify_client_uses_upstream_schema: command not found
lib_l1_settled_tx.sh: line 86: replay/src: Is a directory
```

to stderr — nine lines per `just verify-l1` — and substituted the empty output back in, so the
emitted probe carried the sentence **with its three subjects deleted**:

```
// THE FIXTURE FORMAT IS IMPORTED FROM , NOT FROM THE PACKAGE'S INDEX, and that is
// L0's own check's doing:  asserts that nothing in
//  declares a wire type, …
```

It was harmless *only* because the wreckage landed inside `//` comments and none of the three
names is a real command — the same accident one identifier away from executing something. Found by
reading the N9 arm's log rather than its result line, which is the campaign's own rule about
mutation arms paying off somewhere else.

Fixed by escaping the three backticks and recording the hazard in the file. Re-run after the fix:
**280 / 0, split unchanged at 125 / 94 / 61**, stderr clean, the comment intact in the emitted
probe. The count not moving is the point — this was noise and a mangled comment, not an assertion.

### 8.5 THE PRUNING WINDOW IS NOT ~36 BLOCKS. IT IS A FINALITY LAG.

This is the finding that matters most outside the milestone, and §1's number does not survive.

**Re-measured, four hours after §1's sightings.** At tip 60659 (2026-08-29T03:02Z), scanning 90
blocks: 37 carried transactions, 53 were empty. `getTxEffect` served **every** one of the 37 —
zero nulls — while `getTxByHash` answered for blocks down to **60605** and refused for **60594**
and below. So the qualitative finding is confirmed exactly: **effects are retained and bodies are
not, and a settled transaction becomes unreplayable while staying perfectly visible.**

But the window was **54–65 blocks**, not 36. So rather than curve-fit a third sighting, the review
read the mechanism out of upstream at `anchors.cpp`:

- `AztecNodeService.getTxByHash` (`yarn-project/aztec-node/src/aztec-node/server.ts:637`) calls
  `p2pClient.getTxByHashFromPool` **and nothing else**. It never reaches the tx ARCHIVE —
  `getArchivedTxByHash` exists on the p2p client and the node does not expose it, and
  `archivedTxLimit` (`P2P_ARCHIVED_TX_LIMIT`) defaults to **0** in any case.
- The pool deletes a mined transaction when its block is **FINALIZED**:
  `tx_pool_v2_impl.ts#prepareFinalization` takes the finalized block as its cutoff and
  `findTxsMinedAtOrBefore(cutoff)` names every transaction to delete.
  `keepFinalizedTxsForSlots` (`P2P_KEEP_FINALIZED_TXS_FOR_SLOTS`) defaults to **0** — delete at
  the finalized tip.

**So the horizon is `getBlockNumber() - getBlockNumber('finalized')`.** It is fixed in TIME and
variable in BLOCKS. Measured on testnet at 03:02Z: tip 60659, `finalized` **60601**, `proven`
60644 — a gap of 58 blocks and, by the blocks' own timestamps, **3,096 seconds ≈ 52 minutes**.
The observed boundary brackets the prediction: 60594 pruned ≤ 60601 finalized < 60602 =
`finalized + 1` ≤ 60605 fetchable, with 60595–60604 all empty so it cannot be tightened further
from real transactions. Ten minutes later the gap read **67 blocks** — the tip had advanced and
`finalized` had not moved — which is the same fact making the block count drift in front of you.

**Three consequences, and the first is the product one.**

1. **A demo over "recent Aztec transactions" has a replayability window of about an hour, not
   36 blocks.** Left alone it silently degrades from *debuggable* to *merely visible*, and no
   check anywhere goes red when it does — the block explorer still shows the transaction. If the
   demo is to be live rather than fixture-backed it needs a refresh cadence **well inside an
   hour**, and "36 blocks" would be the wrong thing to build a scheduler on: the same 36 blocks
   is 30 minutes on a busy chain and hours on an idle one.
2. **It does not have to be guessed at, and it needs no widening of the fourteen.**
   `getBlockNumber` is already permitted and already takes a tag, so `getBlockNumber('finalized')`
   reads the horizon at run time. Anything at or below that block is already unfetchable. That is
   a one-call precondition L4's per-transaction outcome table should use instead of discovering
   `SettledTransactionNotFound` per transaction.
3. **The committed fixtures were captured with about half an hour to spare and are now
   unre-capturable.** Their transactions are in blocks 60616 and 60620; `finalized` was 60601 and
   climbing while this review ran. That is the sharpest possible argument for committing fixtures
   at all, and it is why §8.6 lands the way it does.

**Mainnet's idleness reproduces and is stronger than recorded.** `https://aztec.drpc.org`,
`l1ChainId` 1, rollup `0x91ff8bbd…`, `nodeVersion` 5.2.0, tip 64571: **200 consecutive blocks
(64372–64571) carry zero transactions**, against §1's 150. There is nothing on mainnet to capture,
so both fixtures being testnet's is a measurement and not a preference.

`pins.json` and `settled_transaction.ts`'s header were corrected to state the mechanism instead of
the number.

### 8.6 THE `resolvedAsOf: 'latest'` LIMITATION IS L2's — judged, not inherited

The hazard is real and correctly described: `getContract(address, referenceBlock?)` defaults to
`'latest'` and upstream's own doc comment says the instance's current class id "is resolved as of
the given reference block", so an UPGRADED contract would resolve to the class it runs today and a
replay would produce a confident wrong trace. `getContractClass(id)` takes no reference block and
needs none — a class id is content-addressed — so the whole exposure is the one call.

**It is one argument in the code.** It is not one argument in the milestone, and the reason is
§8.5:

- Passing a reference block **changes the wire call**, from `aztec_getContract(["0x2a9a…"])` to
  `aztec_getContract(["0x2a9a…", 60616])`. The fixture is keyed on `(method, params)`, so every
  committed recording becomes a `FixtureMiss` — loudly, which is the format behaving correctly.
- **The fixtures cannot be re-captured.** Their transactions fall out of `getTxByHash` about an
  hour after they settled, and that hour is gone. A re-capture is necessarily a *different*
  transaction, with different bytecode, and 23,157 is quoted in `pins.json`, in two check headers
  and in this log, while N8, N12 and N14 pin literal fixture bytes as their needles. So the change
  costs the milestone's entire evidence base and a re-run of the mutation matrix.
- **And the hazard is not live over the committed subject** — measured, not assumed. On the live
  node, `getContract(addr)`, `getContract(addr, 60616)` and `getContract(addr, 'latest')` all
  return class `0x2b674941…`, and the instance's `originalContractClassId` equals its
  `currentContractClassId`. This contract has never been upgraded, so today's fixture would replay
  against the right bytecode either way.

So the declaration is honest, it is pinned in the value and on the wire by three assertions plus
arm N16, and moving it here would buy nothing over the committed subject at the price of every
number in the milestone. **L2's, and L2 should capture its fixture WITH the reference block from
the start** — adding it afterwards invalidates every recording, which is the trap this entry
exists to keep the next agent out of.

### 8.7 Scope, re-confirmed

`replay/src/node_surface.ts` is **not in L1's diff at all** — the 14/41 partition is untouched,
`getBlocks` is still in `CONTINUOUS_FOLLOWING` with the other nine, and
`verify_node_client_surface_narrow` re-derives the whole thing at 74 / 0. `network` stays
`UNESTABLISHED` and the reason recorded is the one that holds: both reachable endpoints are
proxies, and an un-batched version probe would be a second wire path. Each fixture records the
header absence as what the client saw beside a labelled reconstruction, and the check runs both.
