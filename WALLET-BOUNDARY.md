# The wallet protocol boundary — what was enumerated, what was measured, and what is deliberately empty

M33's write-up.

**Every figure in §1's closure table, §2's package table, §3's two counts and §6's packaging table
is re-derived from the artefacts and compared AGAINST THIS FILE on every run**, by
`verify_provider_half_dd9_clean` §9 — twenty-one figures, each looked for on the line that NAMES ITS
SUBJECT rather than anywhere in the file, and each matched as a DELIMITED figure on that line rather
than as a run of characters anywhere in it. (Both halves of that sentence were earned. The row
anchoring is M24's review's remedy. The field anchoring is M33's review's: two of the original
nineteen could not fail, because `245.87` supplies an `8` for a file count of 8 and `0` is a
substring of every number containing a zero digit.) Figures elsewhere (the per-location file counts in §1's
first table, the per-derivation intermediates, the five named pxe clauses) are named with the check
that measures the *property* instead, and are marked where it matters. That sentence is here because M27's identical sentence
was **false** — no check opened `BROWSER-PACKAGING.md` at all, and eleven of its figures had rotted
before its review measured how many — and because `_m32_doc_ops.py`, written to catch "the number is
right and an entry is missing", itself asked of the whole document instead of the row.

Two kinds of number appear below and they are marked differently. A **derived** figure is a property
of the artefacts and is asserted. A **recorded measurement** is a property of a moment — a registry
query needs a network, and the registry is not ours — and is labelled as one; what is asserted about
it is the same fact re-derived from a source that is offline and pinned.

---

## 1. THE ENUMERATION, and the tenth near-miss it found

**Owned by `verify_provider_half_dd9_clean` §6 and §8.**

`CAMPAIGN-BRIEF.md` records that the campaign has been wrong **nine** times about whether something
needed building, and that every miss was a *parallel subdirectory* to the one being searched. So
M33's first act was not to read `wallet-sdk/` but to enumerate everything in the fork with `wallet`
in its path, at the `cpp` anchor:

| location | files at the anchor | what it is |
|---|---|---|
| `yarn-project/wallet-sdk/` | 30 | the SDK the plan names |
| **`yarn-project/wallets/`** | **17** | **a whole package the plan does not mention** — `@aztec/wallets`, an *embedded* wallet with a declared `browser` entry point, an encrypted store and a wallet DB |
| `yarn-project/aztec.js/src/wallet/` | 9 | `wallet.ts` — `WalletSchema`, the complete protocol |
| `yarn-project/end-to-end/src/test-wallet/` | 6 | RI-82's shape, and the two files M32 did not cite |
| `docs/examples/webapp-tutorial/` | 68 | a worked dApp: an embedded wallet, a wallet connection, a test extension and e2e tests |
| `yarn-project/cli-wallet/` | 49 | the CLI wallet |
| `playground/src/wallet/` | 4 | a React wallet UI |

**`@aztec/wallets` is the tenth instance of that family**, and it is recorded in RI-91 rather than
adopted: its declared dependencies include **both** `@aztec/pxe` and `@aztec/wallet-sdk`, so its
package closure is a superset of the one §2 rejects. M34–M36 must read RI-91 before writing a
wallet — the account-contract providers, the encrypted store and the wallet DB are three things a
dev wallet would otherwise reinvent.

### The number, and the three derivations behind it

`CAMPAIGN-BRIEF.md`: *"when the derivation IS the number, run the derivation twice, differently,
before believing it."* Three were run, and the third moved the answer.

1. **The relative closure per declared subpath**, with `verification/_import_closure.py` — the
   walker whose multi-line-import defect M25's review found after it returned 47 files against a
   true 65. The provider half: 13 files, 3,097 lines, 6 package specifiers.
2. **The same, following workspace package edges** through each `package.json`'s `exports` map:
   565 files, 68,906 lines.
3. **The closure a BUNDLER walks** (`verification/_m33_closure.py`), which additionally drops
   `import type` clauses, because esbuild erases them before a byte is emitted. A closure that
   counts them measures the type-checker's graph and calls it the bundle's — an overcount in the
   direction that reads as BAD news for reuse, which is the direction nobody re-checks.

**The provider half of `@aztec/wallet-sdk` is 408 files and 47,330 lines, and it does not reach
`@aztec/pxe`.** The wallet half is 665 files and 81,348 lines and does. The third derivation is the
one the checks re-run.

| group | files | lines | workspace packages | reaches `@aztec/pxe` |
|---|---|---|---|---|
| provider half (`extension/provider`, `iframe/provider`, `types`, `manager`, `crypto`) | **408** | **47,330** | 9 | **no** |
| wallet half (`base-wallet`, both `handlers`) | **665** | **81,348** | 15 | **yes** |
| the protocol declaration alone (`types.ts`, `crypto.ts`) | **3** | **1,124** | **0** | no |
| `aztec.js/src/wallet/wallet.ts` — `WalletSchema` | **298** | **31,205** | 5 | no |

**The pxe edges, named**, and the two counts are on lines of their own because they are checked
separately — a single line carrying both would let a swap pass, which is M24's review's finding at
field level.

- **5** `@aztec/pxe` import clauses exist in the wallet half, in two files.
- **3** of them are pxe value edges — the ones that survive esbuild's type erasure:

```
wallet-sdk/src/base-wallet/utils.ts:8       import type { ContractNameResolver }   @aztec/pxe/client/lazy   TYPE
wallet-sdk/src/base-wallet/utils.ts:9       import { displayDebugLogs }            @aztec/pxe/client/lazy   VALUE
wallet-sdk/src/base-wallet/utils.ts:10      import { generateSimulatedProvingResult} @aztec/pxe/simulator   VALUE
wallet-sdk/src/base-wallet/base_wallet.ts:36 import { displayDebugLogs }           @aztec/pxe/client/lazy   VALUE
wallet-sdk/src/base-wallet/base_wallet.ts:37 import type { PXE, PackedPrivateEvent} @aztec/pxe/server        TYPE
```

*(The count matters and it changed under the third derivation: derivation 2 reports four distinct
`(file, specifier)` pairs, derivation 3 reports three value edges. Both say the wallet half reaches
pxe; only the third says how much of that survives type erasure. Stated here because "four edges,
all named" would have been a figure that was right about the conclusion and wrong about the
measurement.)*

**And the sharpest number is the smallest.** The protocol layer proper — `types.ts` (204 lines:
`WalletMessageType`'s eleven members, the message envelopes, discovery, key exchange, the heartbeat
knobs) plus `crypto.ts` and `emoji_alphabet.ts` (920 lines: ECDH P-256, HKDF, AES-256-GCM, the
verification hash) — is **three files and 1,124 lines with zero package dependencies of any kind**.
`types.ts`'s only import is `import type { ChainInfo }`. The 408 is the cost of the provider
*implementation*, and it is bought by one value import: `iframe/provider/iframe_wallet.ts` takes
`WalletSchema` from `@aztec/aztec.js/wallet`.

**The residue, printed rather than assumed away.** The provider closure reports **six** unresolved
relative specifiers, and they are the same six in every group: `constants.gen.js` (×2),
`protocol_contract_data.js` (×2) and two `contract-{class,instance}-registry.js`. All six are
*generated* files that do not exist in a source checkout, and all six are data modules rather than
doors to another package. The scanner reports **zero** unclassified import clauses and **zero**
unplaceable workspace specifiers, and both zeroes are asserted.

---

## 2. IS THE PROVIDER HALF SEPARABLE FROM `@aztec/pxe`? — TWO ANSWERS, AND THEY DISAGREE

**Owned by `verify_provider_half_dd9_clean` §6.**

**In the SOURCE: yes, measured.** 408 value-reachable files, zero `@aztec/pxe` edges, zero
`@aztec/native`, zero `@aztec/world-state`. Upstream really has drawn the line M33 wants.

**In the PACKAGE: no, and this is the finding.** npm has no subpath-scoped install: taking
`@aztec/wallet-sdk` takes its whole `dependencies` list, and that list names `@aztec/pxe` outright.

```
@aztec/wallet-sdk  ->  @aztec/pxe  ->  @aztec/simulator  ->  @aztec/native
                                                          ->  @aztec/world-state
```

This repository's own `orchestration/package.json` already states the rule that decides it, one
package along: `@aztec/simulator` is refused *"because `npm view @aztec/simulator@<pin> dependencies`
lists `@aztec/native` and `@aztec/world-state` as HARD dependencies, so importing it would pull the
NAPI AVM and the LMDB world-state addon into the shipped tree."*

So **M33's own escape clause fires, with the reaching import named**: depend where the package is
clean, vendor the protocol types where it is not.

| package | `@aztec` closure | reaches pxe / simulator / native / world-state |
|---|---|---|
| `@aztec/wallet-sdk` | **31** | **all four** |
| `@aztec/wallets` | **33** | **all four** |
| `@aztec/pxe` | 28 | simulator, native, world-state |
| `@aztec/aztec.js` — what M33 adds | **12** | **none** |

*(Those four closures are **derived**, from the anchor's own `package.json` files out of the object
store, so they are offline and reproducible. The same walk against the npm registry at the published
pin `5.0.0-nightly.20260626` is a **recorded measurement**, taken 2026-08-29: `@aztec/wallet-sdk` 27
packages reaching all four, `@aztec/aztec.js` 13 reaching none. The two differ by a few packages
because the anchor is a later revision than the published pin; they agree on every fact this
milestone rests on, and only the offline one is asserted.)*

### What that decides, per artefact

| artefact | decision | inventory |
|---|---|---|
| `WalletSchema` — 16 methods, `@aztec/aztec.js/wallet` | **depend** | RI-89 |
| `wallet-sdk/src/types.ts`, `crypto.ts`, `emoji_alphabet.ts` | **vendor** from the anchor | RI-88 |
| `wallet-sdk`'s `extension/` and `iframe/` transports | **replace** (shape reused, code not) | RI-90 |
| `@aztec/wallets` | **reject**, `cannot-reach-target` | RI-91 |
| `@aztec/foundation/schemas` + `/json-rpc` | depend, unchanged | RI-82 |

---

## 3. The protocol, and the third transport

**Owned by `verify_wallet_protocol_is_upstreams`.**

- **11 message types**, re-derived from `wallet-sdk/src/types.ts` at the anchor and compared
  against what the BUILT `wallet.js` exports, **as a set, in both directions and by value**:
  `aztec-wallet-discovery`, `-discovery-response`, `-disconnect`, `-key-exchange-request`,
  `-key-exchange-response`, `-ready`, `-secure-message`, `-secure-response`,
  `-session-disconnected`, `-ping`, `-pong`.
- **16 wallet methods**, and none of them typed anywhere in this repository:
  `NULL_WALLET_METHODS` is `Object.keys(WalletSchema)`, which is `WalletMethodSchemas`' fifteen plus
  the `batch` upstream *derives* from them with `createBatchSchemas`. A sixteenth method upstream
  adds is refused on the day the pin moves, with no edit here.
- **A third transport**, beside upstream's `extension` and `iframe`: a `MessagePort`, which is the
  in-page and worker case. Upstream's own extension transport already runs the secure session over a
  `MessagePort` — `DiscoveredWallet` holds one — so this is a third socket under an unchanged
  protocol rather than a new protocol. `port_connection_handler.ts` is
  `iframe_connection_handler.ts`'s state machine with `window.addEventListener('message')` replaced
  by `port.onmessage` — measured member for member against the anchor, all nine of upstream's
  present (two renamed) beside the four M33 declares as its own. **Its message-flow comment is a
  PARAPHRASE of upstream's, not a copy**, and three places said "unchanged" until M33's review
  compared them: four lines against five, `parent →` against `dApp ->`, and a PING/PONG line added
  that upstream's handler implements and upstream's comment omits.

### Two divergences from upstream's handler, both declared and both STRICTER

1. **The session binds `appId`.** Upstream's iframe handler reads `appId` out of the decrypted
   message and hands it to `getWallet(appId, chainInfo)` without comparing it to the `appId` the
   session was established for; on a cross-origin channel the origin check carries that weight, and
   a `MessagePort` has no origin. So a secure message whose `appId` disagrees is refused by name and
   answered with an error naming both ids.
2. **The app manifest is recorded where it arrives**, before dispatch — see §4.

---

## 4. §8.4 ACROSS THE BOUNDARY, in upstream's own field

**Owned by `e2e_discovery_keyexchange_session` §4.**

The milestone requires that the wallet is **told**, and can **report**, that this chain is simulated
and produces no proofs. Nothing needed inventing. `requestCapabilities(AppCapabilities)` is one of
`WalletSchema`'s fifteen methods, and `AppCapabilities.metadata` is upstream's own
`{name, version, description?, url?, icon?}` — the object a wallet shows a user in an authorization
dialog. So the runtime sends:

```
name:        aztec-avm-runtime (simulated)
version:     5.0.0-nightly.20260626          (pins.json's deletion_era, asserted)
description: <DISCLOSURE_LINE, verbatim from orchestration/src/disclosure.ts>
```

as the **first** secure message, and `PortConnectionHandler` records it **before dispatching**. So
the disclosure survives a wallet that refuses the call — which is exactly what happens here: the
null wallet refuses `requestCapabilities` by name, and `handler.disclosure()` still returns the line.
**Told, and able to report, with the call refused.** Both halves are asserted, and the expected
string is read out of `disclosure.ts` rather than typed into the check.

---

## 5. What is measured in Node, and what that does NOT say

**Owned by `verify_provider_half_dd9_clean` §10.**

M32's arms had to run in Chromium because their subject was a Web Worker, CPU throttling and
`Page.setWebLifecycleState`. M33's subject is a `MessagePort` and WebCrypto, and Node 24 implements
both to the same specifications the browser does. So `tools/run_wallet_arms.mjs` **imports the built
`browser/dist/wallet.js`** and runs the real handshake in-process: real ECDH P-256, real HKDF, real
AES-256-GCM, real structured-clone message passing. Every refusal, every message type and every
method name the checks read is a property of the built module.

**What that does not say is that the bundle loads in a page.** M33 shipped with that half asserted
on the esbuild **metafile** — the wallet entry reaches no `@aztec/native`, no `@aztec/world-state`,
no `@aztec/pxe` and no Node builtin, over a control build in which those packages are planted and
resolvable — plus M28's browser gate. **M33's review measured how much weaker that is, and then
closed it.**

*A free identifier is not an import, and a metafile only records imports.* With
`const _nodeOnlyProbe = setImmediate;` planted at the top of `port_wallet_provider.ts` — a Node
global, read at module-evaluation time, and neither `Buffer` nor `process`, so no shim supplies it
and no free-identifier scan names it — the rebuilt bundle imported cleanly in Node and died in
Chromium with `ReferenceError: setImmediate is not defined`. Over that bundle: `just verify-m33`
**224, 4/4, exit 0**; `verify_browser_bundle_no_node_builtins` **64 / 0**;
`verify_browser_bundle_no_native_deps` **44 / 0**;
`verify_verification_code_unreachable_from_browser` **37 / 0**; `smoke_browser_headless_full_flow`
**50 / 0** — and that last one does drive Chromium, over `browser.js`. Nothing anywhere referenced
`wallet.js` from a page.

So `verify_provider_half_dd9_clean` **§10** now loads it in one: a served copy of `browser/dist`, a
probe page that `import()`s `./wallet.js`, and assertions that it evaluated, that the module was
FETCHED over HTTP, that the exports the page sees are the operations Node reads out of the same
file, that the protocol enum crossed with all eleven members, and that the page has a `document`, a
`MessageChannel` and — the one Node cannot speak to, because a browser withholds it outside a
secure context — `crypto.subtle`. **The control is the plant, kept**: a second served site whose
`wallet.js` carries that one free identifier, which the same probe must report as a
`ReferenceError` naming it.

**The handshake is still measured in Node and that is still right**, because a `MessagePort` and
WebCrypto are the same thing in both engines. What changed is that "the artefact is browser-shaped"
is an observation with a control beside it rather than a property of a config file.

---

## 6. Packaging: a seventh entry point, and why it is not the reference

**Owned by `verify_provider_half_dd9_clean` §4 and by M27's `verify_browser_chunk_budget`.**

`wallet.js` is built as a seventh entry point in the **same esbuild pass**, and it is deliberately
**not** part of the browser reference surface. The reason is DD-11 rather than DD-5:

> A page that attaches no wallet must not download a wallet protocol to be told so.

DD-5's rule is a relation between three entries — `browser` is the reference, `testing` and `node`
are supersets — and this build already ships three further entries outside it (`demo`, `worker`,
`worker-demo`). `wallet` is the fourth such, and its export set is asserted **disjoint** from
`browser.js`'s, in both directions.

| | derived |
|---|---|
| `wallet.js`'s own module | **1.22 KB** gzipped |
| its eager set | **306.92 KB** gzipped across **9** files |
| `@aztec/aztec.js` bytes in that eager set | **13,398** |
| `@aztec/aztec.js` bytes in `browser.js`'s eager set | **0** |

**M35 MOVED THREE OF THOSE FOUR AGAIN, AND THE FOURTH IS STILL THE ONE THAT MATTERS.** M35 fills
the seam's private half, so the wallet entry now reaches upstream's `WASMSimulator` (RI-64,
`PROVENANCE.md` V10) and the whole private-execution oracle wire layer (RI-97, V11) — fifty vendored
files between them. The eager set goes **275.26 -> 297.12 KB** across the same **9** files, recorded
as a `bumps` entry in `chunk-budgets.json` (300 -> 340 KB) rather than absorbed. `wallet.js`'s own
module goes **0.69 -> 0.94 KB**, still a re-export stub, and the `@aztec/aztec.js` bytes in the eager
set move **13,379 -> 13,398** because the splitter re-partitioned around the new modules.
**The zero did not move.** *(And the 4.4 MB of ACVM wasm private execution needs is NOT in the
297.12: `acvm_js_bg.wasm` and `noirc_abi_wasm_bg.wasm` are fetched by URL at the moment a page asks
for a private execution, and `e2e_private_function_executes_in_browser` §5 measures their absence
from a page that does not — on a network log that carries `avm.wasm`, so the absence is asked of a
log that could have answered otherwise.)*

**M34 MOVED THREE OF THOSE FOUR AND THE FOURTH IS THE ONE THAT MATTERS.** M34 fills the seam, so the
wallet entry now reaches M26's vendored transaction builder (RI-72) and `@aztec/stdlib/testing`'s
`makeContractClassPublic`: the eager set goes **245.87 KB / 8 files -> 275.26 KB / 9**, recorded as a
`bumps` entry in `chunk-budgets.json` rather than absorbed. `wallet.js`'s OWN module falls
**16.24 -> 0.69 KB** for the opposite reason — M34 adds an eighth entry point that shares the
wallet's modules, so esbuild hoisted the protocol and the provider into a shared chunk and the entry
became a re-export stub. (That is also what reddened this check's `cpp_` positive-control needle,
which had been asked of `wallet.js` alone; it is asked of the whole eager SET now, which is both the
question DD-11 means and a set that cannot become a stub.) **The zero did not move**, and it is the
one DD-11 rests on: a page that attaches no wallet still pays not one byte of `@aztec/aztec.js`.

The wallet entry costs *less* than the reference entry, because it needs the protocol and its codecs
and not the runtime. `WalletSchema`'s 31,205-line closure resolves almost entirely into chunks the
reference bundle already carries — `zod`, `@aztec/stdlib`, `@aztec/foundation` — and the marginal
cost of `@aztec/aztec.js` itself is thirteen kilobytes.

`BROWSER-PACKAGING.md` §1 records what adding the entry moved and attributes every kilobyte of it:
a control build with the three new packages installed and the wallet ENTRY removed reproduces every
pre-M33 figure to the assertion, so the movement is the splitter's and not the dependency's.

---

## 7. What is deliberately not here

- **No wallet.** `createNullWallet` refuses every method of upstream's schema by name. Keys, note
  discovery, private execution and tagging are wallet responsibilities and M34–M36 own them. The
  seam ships exercised and empty rather than filled with plausible defaults, because a fabricated
  note or nullifier produces a transaction that *looks* valid.
- **No `@aztec/wallet-sdk` dependency**, for the packaging reason in §2 and for no other. Its source
  is clean; its package is not.
- **No key material of ours.** The ECDH keypair is generated per session by upstream's own
  `crypto.ts`, whose `generateKeyPair` asks for a non-extractable private key.
- **No batching yet.** `WalletSchema.batch` is in the method list and is refused like the rest.
  Upstream ships request batching over this boundary and M34 is where using it becomes a question.
- **No approval UI.** `autoApproveDiscovery` is a configuration flag with a callback beside it; a
  wallet with a user attaches one. M33 has no user.
- **No verification-hash display.** `hashToEmoji` is exported and unused. The hash is *compared* at
  both ends by the checks; showing it to somebody is a wallet's job.

---

## 8. What M34–M36 inherit

- The seam, with a wallet in it that refuses by name, so replacing the null wallet is a substitution
  rather than a construction.
- RI-91: `@aztec/wallets` exists, has a browser entry point, and cannot be depended on for the
  reason in §2. Read it before writing a dev wallet.
- RI-89: `WalletSchema` is the method list, so M34's wallet implements sixteen named methods and not
  a surface somebody invented.
- The disclosure carrier: §8.4 already crosses in `AppCapabilities.metadata`, so a real wallet
  inherits the honesty without a new message type.
