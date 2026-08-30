# The CodeTracer dev wallet — what it is, what it refuses, and why it is deliberately not a real wallet

M34's write-up.

**Every figure in §2's closure table, §3's counts, §4's transfer figures and §6's packaging table is
re-derived from the artefacts and compared AGAINST THIS FILE on every run**, by
`e2e_wallet_public_transfer` §8 — each looked for on the line that NAMES ITS SUBJECT rather than
anywhere in the file, and each matched as a DELIMITED figure on that line rather than as a run of
characters anywhere in it. Both halves of that sentence were earned by somebody else: the row
anchoring is M24's review's remedy, and the field anchoring is M33's review's, which found two of
nineteen figures that could not fail because `245.87` supplies an `8` and `0` is a substring of every
number containing a zero digit.

---

## 1. THE DESIGN GOAL, STATED SO NOBODY LATER "HARDENS" IT INTO USELESSNESS

A production wallet guards keys and hides its reasoning. **A debugging wallet must do the
opposite:**

- **every oracle call visible** — every method call this wallet serves or refuses is a record in an
  ordered ledger, and every record is written into the `.ct` container as a `TraceLogEvent`;
- **every decision explicable** — a refusal names the method AND what would have to exist for it to
  stop; an authorization names the account and the call count;
- **keys deterministic** — derived from a seed that lives in the trace metadata, so a recording
  replays identically.

These are properties a real wallet **cannot** have and a CodeTracer wallet **should**. They are the
deliverable, not a weakness to be tidied away later. The one that is easiest to "harden" by accident
is the third: **no ambient randomness.** The seed is an argument, never generated. That is DD-4's
discipline applied to entropy instead of to time, and for the same reason — a value read from the
ambient environment makes a recording that cannot be replayed, whether it is a clock or a key.
Upstream's own wallets call `Fr.random()` for an account secret, which is right for a wallet holding
somebody's money and wrong for one whose whole purpose is that the recording comes out the same
twice.

`test_wallet_keys_deterministic` measures both halves separately, because they are different
statements: behaviourally (same seed, same addresses, twice, in two engines and three processes) and
structurally (no randomness spelling is reachable from the key path, over stripped CODE rather than
over prose, with a control that finds one).

---

## 2. `BaseWallet` IS NOT SUBCLASSED, AND THAT IS A MEASUREMENT WITH FOUR PARTS

**Owned by `e2e_wallet_public_transfer` §8 and `verification/_m34_closure.py`.**

M34's plan said: *"`BaseWallet` (666 lines) — subclass it; do not reinvent `getAccounts`,
`getChainInfo`, `registerSender`, `registerContractClass`, `getContractMetadata`."* That was the
right instruction to give, and the measurement says no. Four parts, and the fourth is the one that
settles it.

| group | files | lines | workspace packages | reaches a DD-9 package |
|---|---|---|---|---|
| `wallet-sdk/src/base-wallet/index.ts` — the class M34 was told to subclass | **656** | **79,060** | 15 | **`@aztec/pxe` and `@aztec/simulator`** |
| `aztec.js/src/wallet/wallet.ts` — `WalletSchema`, which M34 DOES depend on | **298** | **31,205** | 5 | no |
| `@aztec/entrypoints`, upstream's other entrypoint package | **193** | **22,463** | 5 | no |

Those are the third derivation — the closure a BUNDLER walks, with `import type` clauses dropped
because esbuild erases them before a byte is emitted — taken with M33's own walker rather than a
second one. `verification/_m34_closure.py` is thirty lines that import `_m33_closure.py` and add four
groups; the resolver, the type-erasure rule, the residue categories and the dynamic-import census are
all M33's. The `298 / 31,205` row reproduces M33's figure to the unit, through a walker invoked
differently, which is what makes it a re-derivation rather than a quotation.

**1. The package.** `@aztec/wallet-sdk`'s own `dependencies` names `@aztec/pxe`, whose closure
reaches `@aztec/simulator` and through it `@aztec/native` and `@aztec/world-state` — the NAPI AVM and
the LMDB world-state addon. That is RI-88, measured in M33, and it is why the protocol types are
vendored rather than depended on.

**2. The vendoring cost.** `base-wallet/index.ts` alone is 656 files and 79,060 lines, reaching
`@aztec/pxe` AND `@aztec/simulator` through **3** named VALUE edges:

```
wallet-sdk/src/base-wallet/base_wallet.ts   import { displayDebugLogs }             @aztec/pxe/client/lazy
wallet-sdk/src/base-wallet/utils.ts         import { displayDebugLogs }             @aztec/pxe/client/lazy
wallet-sdk/src/base-wallet/utils.ts         import { generateSimulatedProvingResult} @aztec/pxe/simulator
```

"666 lines" is the file. 79,060 is the bill.

**3. The constructor.** `protected constructor(protected readonly pxe: PXE, protected readonly
aztecNode: AztecNode, …)`. It does not merely import a PXE type — it **requires an instance**. This
runtime has none, by design. A subclass that handed it a fabricated one would be the plausible
default this campaign exists to refuse.

**4. What the five named methods actually contain.** Read at the anchor, one at a time:

| method | `BaseWallet`'s body |
|---|---|
| `getAccounts` | `abstract` — **there is no body to inherit** |
| `registerContractClass` | `return this.pxe.registerContractClass(artifact)` |
| `registerSender` | one `this.pxe.registerTaggingSecretSource({…})` |
| `getChainInfo` | two lines over `aztecNode.getNodeInfo()` |
| `getContractMetadata` | `this.pxe.getContractInstance` plus three `aztecNode` calls |

**Between them they contain zero lines of reusable logic that do not require a `PXE`.** The 666 lines
are almost entirely `simulateTx`, `profileTx` and `completeFeeOptions` — the private-execution path
M35 owns. (And a fifth, smaller reason: `base_wallet.ts` opens `import { inspect } from 'util'`, a
Node builtin M28's browser gate refuses outright.)

So the decision is **replace**, `cannot-reach-target`, recorded as RI-95.

### What IS reused, which is most of it

| artefact | decision | inventory |
|---|---|---|
| `WalletSchema` — the method list and every argument and return codec | **depend**, unchanged from M33 | RI-89 |
| upstream's public-only entrypoint SHAPE (`base-wallet/utils.ts`) | **reuse the shape, not the code** | RI-94 |
| `deriveKeys` / `computeAddress` from `@aztec/stdlib/keys` | **depend** | RI-96 |
| M26's vendored transaction builder | **reuse**, unchanged | RI-72 |
| `BaseWallet` itself | **replace** | RI-95 |
| M33's transport, protocol, handshake and disclosure carrier | **reuse**, byte for byte | RI-88, RI-90 |

**Upstream's `DefaultEntrypoint` is not usable, and the reason is one line of its own source:**
`if (call.type !== FunctionType.PRIVATE) throw new Error('Public entrypoints are not allowed');`.
Measured rather than assumed, and recorded here so nobody re-opens it. The shape M34 wants is
`base-wallet/utils.ts`'s `simulateBatchViaNode` — upstream's own words, *"Minimal entrypoint
structure — no real private execution, just public call requests"* — and M26's vendored
`createTxForPublicCalls` (RI-72, `PROVENANCE.md` F20–F24) builds the same object without going
through `@aztec/pxe/simulator`'s `generateSimulatedProvingResult`, which is one of the three pxe edges
above.

---

## 3. THE SURFACE: SIXTEEN METHODS, TEN SERVED, SIX REFUSED BY NAME

**Owned by `e2e_wallet_public_transfer` §6.**

The method list is never typed here. `DEV_WALLET_METHODS` is `Object.keys(WalletSchema)` — upstream's
own object — and `DEV_WALLET_REFUSED` is that set minus the served one, so a seventeenth method
upstream adds is refused on the day the pin moves with no edit here. The check reads the list twice
by two routes (out of the built bundle and out of the installed `@aztec/aztec.js` in a separate
process) and compares them as sets before anything else.

- **16** methods in upstream's `WalletSchema` at the installed pin — the whole surface, and the
  number this wallet never types.
- **10 served**: `getAccounts`, `getAddressBook`, `getChainInfo`, `getContractClassMetadata`,
  `getContractMetadata`, `registerContract`, `registerContractClass`, `registerSender`,
  `requestCapabilities`, `sendTx`.
- **6 refused**, each naming itself and what would have to exist: `getPrivateEvents` (note discovery;
  **M36 stores NOTES and still refuses EVENTS by name**, because upstream keeps them in a
  `PrivateEventStore` — another `AztecAsyncKVStore` consumer — and accepting the request while
  storing nothing would make this method answer an empty set that looks like "there were no
  events"), `simulateTx`, `profileTx`, `executeUtility` and `createAuthWit` (private execution, M35), and
  `batch` (M34 crosses one call at a time on purpose, so that every decision has its own trace
  record).

Served and refused are asserted **disjoint and summing to the whole schema**, so a method that fell
out of both — the shape a fabricated name would take — fails.

**And the declaration is reconciled with the implementation at construction.** `DEV_WALLET_SERVED` is
a list a check reads; the object that answers is built inside `createDevWallet` and closes over the
host, so the list cannot be derived from it. `assertServedMatchesDeclaration` throws naming the
difference in either direction before the wallet exists, and the check exercises it both ways over
the BUILT bundle — a method listed as served that silently refuses is the plausible-default shape
wearing a table of contents. The guard is not the whole evidence: all sixteen methods are exercised
behaviourally, ten across the encrypted session with the wallet's own ledger read for each, and six
required to refuse by name.

**A refused method called across the wire with the wrong ARITY never reaches the wallet at all**, and
that is worth writing down because it made the first version of this check measure the wrong thing:
upstream's own `parseWithOptionals` rejects the arguments first, with a `too_small` zod error naming
no method. All six "refusals" in that run were upstream's codec rather than the wallet's. The arm
calls each one directly now, where the refusal is a `DevWalletRefused` naming the method and its
reason, and sends ONE refused method over the wire with arguments the codec accepts, so a refusal is
also seen to survive the whole encrypted round trip.

---

## 4. THE TRANSFER, END TO END, IN A BROWSER

**Owned by `e2e_wallet_public_transfer` §1–§5.**

`transfer_in_public` runs from a wallet handshake to a settled block to a `.ct` container, and every
step of it crosses M33's boundary as an AES-256-GCM `SECURE_MESSAGE`. The runtime does not reach
around the seam at any point.

| | derived |
|---|---|
| executed AVM steps | **516** |
| AVM contexts | **2** |
| `ProcessedTx.revertCode` | **0** |
| wallet decisions recorded | **13** |
| requests containing `barretenberg` | **0** |

The step count is the direct path's figure **to the step**, which is the interesting part: the wallet
route and the back-door route execute the same program. **That is an assertion now and it was prose
until M34's review** — `test_deployment_through_wallet` §5b compares this arm's `executedSteps` and
`contexts` against the `shortcut` arm's, which runs `runTokenTransfer` in a runtime of its own **in
the same browser session**, with a non-degeneracy floor beside it and the declining arm's `0` as the
control that the comparison separates. Before that, the left-hand side was re-derived from the arm
and the right-hand side was a number measured in another milestone's arm run that nothing here
re-derived, which is the family this campaign calls "a figure nobody re-derives rots" — in the
sentence carrying this milestone's headline.

**And the agreement is not by construction.** The wallet enters M26's vendored builder through its
no-`fnName` branch with `[derivedSelector, ...args]`, after re-deriving the selector from the
artifact IT registered; `runTokenTransfer` enters through the `fnName` branch and lets the builder
derive and prepend. Two different entries into one builder, one identical program.

`revertCode` is read separately from `outcome` for M29's reason — `processed` is upstream's word for
"the public processor turned it into a `TxEffect`", and a transaction that reverts at instruction one
is still processed.

**The one thing this page proves that nothing else does.** M33's review established that a metafile
records IMPORTS and a free identifier is not one: with `const _nodeOnlyProbe = setImmediate;` planted,
`just verify-m33` was 224 assertions, 4/4, exit 0 over a bundle that died on the first line a page
evaluated. Its remedy was a probe page that IMPORTS the bundle. M34 ships a wallet rather than a
protocol, so the wallet is **loaded and EXERCISED** in a browser: the handshake, the ECDH, the
session, the deterministic key derivation through `avm.wasm`'s own grumpkin, the vendored transaction
builder, the AVM and the `.ct` writer all execute in Chromium, and the container the page downloads
is read back through the pinned `ct-print`.

### The control: a wallet that refuses to sign

The milestone requires *"a named failure, not a silent no-op"*, and both halves are asserted. The
declining wallet raises `DevWalletAuthorizationDeclined` naming the account and the reason; the chain
has no outcome for the transaction, produced no block, and the AVM executed **0** steps.

### The signing decision, on a transaction that carries no signature

A public entrypoint has no signature, and that does not make the decision go away: the wallet decides
whether to authorize a transaction from one of ITS accounts, and it refuses an account it did not
derive. It also re-derives every call's function selector **from the artifact it registered** and
refuses on a disagreement with the one the caller declared — a wallet that dispatched to whatever
selector it was handed would be a wallet that signs whatever it is given.

---

## 5. THE INSTALLED PIN IS THE AUTHORITY, AND IT DISAGREES WITH THE ANCHOR TWICE

Both found by RUNNING the wallet, both in upstream's own codecs, and both invisible to a reader of
the anchor's source. This is M23's `AztecNodeDebug` family — five methods at the anchor, three at the
pin — in a second place.

| subject | the `cpp` anchor's source | `@aztec/…@5.0.0-nightly.20260626`, measured |
|---|---|---|
| `WalletSchema.registerContract`'s output | `z.void()` | an **intersection** of the instance preimage with `{address}`; `undefined` FAILS |
| `FunctionCall`'s return type | `returnType?: AbiType`, with a transform accepting either spelling | `returnTypes: z.array(AbiTypeSchema)`, **required**, and `toJSON` emits it |

Measured with `getSchemaReturnType(WalletSchema[k]).parseAsync(undefined)` over all sixteen methods:
**`registerContractClass` is the only one that accepts `undefined` at this pin.** So upstream's own
worked example — `end-to-end/src/test-wallet/worker_wallet.test.ts`, 22 lines, whose whole subject is
that void-returning methods serialise as `undefined` — is testing a property that holds for one of
the two methods it names.

---

## 6. PACKAGING: AN EIGHTH ENTRY POINT, AND ONE BUDGET BUMP

**Owned by `verify_provider_half_dd9_clean` §4 and M27's `verify_browser_chunk_budget`.**

`wallet-demo.js` is an eighth entry point in the **same esbuild pass**, for the reason `worker-demo`
is: the page it drives hosts the runtime AND the wallet at once, and a pass of its own would give it
a second copy of every shared chunk.

| | derived |
|---|---|
| the wallet entry's eager set | **304.12 KB** gzipped across **9** files |
| the wallet demo page's eager set | **343.59 KB** gzipped across **13** files |
| `@aztec/aztec.js` bytes in `browser.js`'s eager set | **0** |

*(Both figures moved in M35, which fills the private half of the seam: the wallet entry now reaches
upstream's `WASMSimulator` and the whole 68-oracle wire layer, 275.26 -> 297.12 KB and 309.99 ->
334.51 KB, with two more `bumps` entries recording it. `PRIVATE-EXECUTION.md` §6 carries that
accounting; this table is re-derived on every run either way, which is why it moved here rather than
rotting.)*

**One budget was bumped and it is recorded as data rather than absorbed.** The wallet entry's eager
budget goes 270 -> 300 KB, with a `bumps` entry in `chunk-budgets.json` naming what grew and why: the
wallet now BUILDS transactions, so M26's vendored builder is reachable from it where before nothing
was. That cost is the deliverable rather than a regression — a wallet that did not construct the
transaction would be a wallet the runtime reached around.

**The zero did not move**, and it is the one DD-11 rests on: a page that attaches no wallet still
pays not one byte of `@aztec/aztec.js`.

*(A figure that ends in a zero is written without it — `309.7`, not `309.70` — because the comparer
formats by stripping trailing zeros and its needle is DELIMITED, so a trailing digit is refused. The
document carries the CHECK's spelling, which is the same rule `WORKER-NODE.md` §5 records for the
rounding tie that put a build and a check one hundredth apart.)*

---

## 7. WHAT IS DELIBERATELY NOT HERE

- **No private execution.** `simulateTx`, `profileTx`, `executeUtility` and `createAuthWit` refuse by
  name. M35 owns them.
- **No note database and no tagging** *(M34's state; M36 built both — `LOCAL-HISTORY.md`)*.
  `getPrivateEvents` refuses by name, and it still does after M36: the note half is served and the
  EVENT half is not, for the reason §3 now gives.
- **No approval UI.** `autoApproveDiscovery` is a flag with a callback beside it; a wallet with a
  user attaches one. M34 still has no user.
- **No batching.** Upstream ships request batching over this boundary and `batch` refuses by name —
  deliberately, because M34's fifth deliverable is that every decision has its own trace record, and
  a batch is one message carrying several.
- **No key material that leaves the wallet.** The account secrets are derived and used; nothing
  exports them.
- **The node-side dev shortcuts are NOT the wallet's.** The contract-address nullifier, the public
  initialization nullifier, a token balance and the fee-juice credit are four direct writes into the
  resident world state, each labelled `[DEV SHORTCUT]` in the demo page's own log. They are seeding a
  chain nobody mined, which is the node's business; a wallet has no way to do them and no business
  doing them. `registerContract` is the one that IS a wallet's business, and it goes through the
  wallet.

---

## 8. WHAT M35 AND M36 INHERITED — AND SPENT

- A wallet in the seam, so the next milestone is a substitution rather than a construction: every
  method M35 implements is one that currently refuses by name, and the refusal names the milestone.
- The decision ledger and its trace records, so "every oracle call visible" is machinery that already
  exists rather than a thing to build. M35's 68 oracles go through the same ledger.
- Deterministic keys, which is what makes a private-execution recording replayable at all.
  *(M36 spent them on TAGGING: every app tagging secret is an ECDH over these accounts' own keys, so
  the tag a contract emits and the tag the wallet looks for are two derivations of one seed.)*
- The measurement in §2, so nobody re-opens `BaseWallet`.
