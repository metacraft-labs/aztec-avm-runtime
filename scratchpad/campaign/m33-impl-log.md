# M33 — The Wallet Protocol Boundary — IMPLEMENTATION log

Written as I go. Reference state at start (2026-08-29):

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `d3c8228` | clean |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | exactly its one pre-existing edit; zero published refs |
| `aztec-packages` | — | `ee3c0528d54` | clean, untouched |

Campaign reference before M33: sweep M0–M32 = **11,054**, 33 milestones, 31 of 33 exit 0.

---

## Step 0 — reading

Read in full: `M33-M36-proposed.md`, `OUT-OF-SCOPE.md`, `CAMPAIGN-BRIEF.md` (1,576 lines),
the M33 section of `Aztec-AVM-Runtime.milestones.org`, `m32-review-log.md`, `WORKER-NODE.md`,
`REUSE-INVENTORY.md` RI-82/83/84/85.

---

## Step 1 — THE ENUMERATION, BEFORE A LINE OF CODE

### 1.1 The census of parallel subdirectories — and there is a TENTH near-miss

The brief says the campaign has been wrong **nine** times about whether something needed writing,
every miss a parallel subdirectory. So the first thing measured was not `wallet-sdk/` but
**everything in the fork with `wallet` in its path**, at the `cpp` anchor `233d8e0993`:

| location | files at the anchor | what it is |
|---|---|---|
| `yarn-project/wallet-sdk/` | **30** | the SDK M33-M36-proposed.md names |
| **`yarn-project/wallets/`** | **17** | **A WHOLE PACKAGE M33's plan does not mention** — `@aztec/wallets`, `src/embedded/embedded_wallet.ts`, with **`src/embedded/entrypoints/browser.ts`** and a `node.ts` beside it, a `wallet_db.ts`, a `store_encryption.ts` and three account-contract providers |
| `yarn-project/aztec.js/src/wallet/` | **9** | `wallet.ts` (`WalletSchema`), `capabilities.ts`, `account_manager.ts` |
| `yarn-project/end-to-end/src/test-wallet/` | **6** | RI-82's shape, and the two files M32 did not cite |
| **`docs/examples/webapp-tutorial/`** | **68** | **a worked dApp**: `src/embedded-wallet.ts`, `src/wallet-connection.ts`, `test-extension/src/wallet/wallet-impl.ts`, plus `tests/e2e/extension-wallet.test.ts` |
| `yarn-project/cli-wallet/` | **49** | the CLI wallet |
| `playground/src/wallet/` | **4** | a React wallet UI |
| `docs/docs-developers/.../wallet-extension/` | 8 `.md` | **`02-wallet-protocol.md`** — the protocol written down by its authors |

`@aztec/wallets` is the tenth instance of the campaign's own family: a parallel subdirectory, one
level up from the one the plan named. It is recorded here rather than adopted — see §1.4 for why
its dependency list decides that.

### 1.2 THE NUMBER — the provider/dApp half, transitively, three derivations

`CAMPAIGN-BRIEF.md`: *"when the derivation IS the number, run the derivation twice, differently,
before believing it."* Three derivations were run, each answering a different question, and the
third moved the answer materially.

**Derivation 1 — relative closure per declared subpath** (`@aztec/wallet-sdk` declares **8**
`exports` subpaths). Walker: `verification/_import_closure.py`'s `closure()`, the one whose
multi-line-import defect M25's review found and fixed. Residue printed and zero in every row.

| subpath | files | lines | package specifiers | `@aztec/pxe` |
|---|---|---|---|---|
| `./base-wallet` | 4 | 1,010 | 31 | **YES ×3** |
| `./extension/handlers` | 7 | 1,940 | 1 | no |
| `./extension/provider` | 6 | 1,774 | 6 | no |
| `./iframe/handlers` | 5 | 1,472 | 4 | no |
| `./iframe/provider` | 8 | 2,144 | 6 | no |
| `./crypto` | 2 | 920 | **0** | no |
| `./types` | 3 | 1,124 | 1 | no |
| `./manager` | 12 | 3,094 | 6 | no |
| **PROVIDER half** (provider ∪ types ∪ manager ∪ crypto) | **13** | **3,097** | **6** | **no** |
| **WALLET half** (base-wallet ∪ both handlers) | **13** | **3,298** | **33** | **YES** |

**Derivation 2 — transitive across workspace package boundaries.** `@aztec/<pkg>/<sub>` resolved
through `yarn-project/<pkg>/package.json`'s `exports` (`./dest/x.js` → `src/x.ts`), 48 workspace
packages mapped by reading every `package.json` `name` rather than guessing from the directory:

| | files | lines | workspace pkgs | reaches `@aztec/pxe` |
|---|---|---|---|---|
| PROVIDER half | 565 | 68,906 | 9 | **NO** |
| WALLET half | 915 | 111,963 | 18 | **YES**, 4 edges |

**Derivation 3 — the closure a BUNDLER walks.** Derivations 1 and 2 count every `from '…'` clause.
TypeScript's `import type` clauses are **erased by esbuild before a byte is emitted**, so a closure
that counts them measures the type-checker's graph and calls it the bundle's — an overcount in the
direction that reads as BAD news for reuse, which is the direction nobody re-checks. The classifier
prints every clause it cannot place and that residue is **0** in every row below.

| | value files | value lines | workspace pkgs | ext pkgs | pxe | native | world-state |
|---|---|---|---|---|---|---|---|
| **PROVIDER half** | **408** | **47,330** | 9 | 18 | **NO** | **NO** | **NO** |
| WALLET half | 665 | 81,348 | 15 | 25 | **YES** | no | no |
| `wallet-sdk/src/types.ts` | **1** | **204** | **0** | **0** | NO | NO | NO |
| `wallet-sdk/src/crypto.ts` | **2** | **920** | **0** | **0** | NO | NO | NO |
| `aztec.js/src/wallet/wallet.ts` (`WalletSchema`) | **298** | **31,205** | 5 | 16 | **NO** | **NO** | **NO** |

**THE NUMBER, stated once: 408 files and 47,330 lines.** That is what the provider/dApp half of
`@aztec/wallet-sdk` needs transitively, as a bundler walks it, and **it does not reach
`@aztec/pxe`.** The four pxe edges are all in the wallet half and all named:
`base-wallet/base_wallet.ts → @aztec/pxe/client/lazy`, `→ @aztec/pxe/server`,
`base-wallet/utils.ts → @aztec/pxe/client/lazy`, `→ @aztec/pxe/simulator`.

And the sharpest number of all: **the protocol layer proper is 3 files and 1,124 lines with ZERO
package dependencies of any kind.** `types.ts` (204 lines) declares `WalletMessage`,
`WalletResponse`, `WalletMessageType`, `WalletInfo`, `DiscoveryRequest`/`DiscoveryResponse`,
`KeyExchangeRequest`/`KeyExchangeResponse` and `HeartbeatOptions`, and its single import —
`ChainInfo` — is `import type`. `crypto.ts` + `emoji_alphabet.ts` (920 lines) are free-standing
WebCrypto. The 408 is the cost of the provider *implementation*, and it is bought entirely by one
VALUE import: `iframe/provider/iframe_wallet.ts` imports `WalletSchema` from `@aztec/aztec.js/wallet`.

### 1.3 IS THE PROVIDER HALF SEPARABLE FROM `@aztec/pxe`? — TWO ANSWERS, AND THEY DISAGREE

**At the import-graph level: YES, measured.** 408 value-reachable files, zero `@aztec/pxe` edges,
zero `@aztec/native`, zero `@aztec/world-state`.

**At the PACKAGE level: NO, and this is the finding.** npm has no subpath-scoped install: taking
`@aztec/wallet-sdk` takes its whole `dependencies` list. Measured against the registry at this
repository's own pin, `5.0.0-nightly.20260626`, by walking `npm view … dependencies` transitively:

```
@aztec/wallet-sdk  ->  27 @aztec packages, and it reaches
                       @aztec/pxe -> @aztec/simulator -> @aztec/native + @aztec/world-state
@aztec/aztec.js    ->  13 @aztec packages, reaches NONE of those four
@aztec/entrypoints ->  12 @aztec packages, reaches NONE
@aztec/stdlib      ->   9 @aztec packages, reaches NONE
```

`@aztec/wallet-sdk`'s own declared dependency list names `@aztec/pxe` outright. So the seam M33 is
about exists in upstream's SOURCE and does not exist in upstream's PACKAGING, and this repository's
own `orchestration/package.json` already states the rule that decides it: `@aztec/simulator` is
refused *"because `npm view @aztec/simulator@<pin> dependencies` lists `@aztec/native` and
`@aztec/world-state` as HARD dependencies, so importing it would pull the NAPI AVM and the LMDB
world-state addon into the shipped tree."* The same sentence, one package along.

**So M33's own escape clause fires, and with the reaching import named**, exactly as the milestone
asks: depend where the package is clean, vendor the protocol types where it is not.

### 1.4 What that decides, per artefact

| artefact | decision | reason, measured |
|---|---|---|
| `WalletSchema` / `WalletMethodSchemas` / `createBatchSchemas` (`@aztec/aztec.js/wallet`) | **DEPEND** | published at the pin; its whole `@aztec` closure is 13 packages and reaches none of pxe/simulator/native/world-state |
| `wallet-sdk/src/types.ts` — the wire protocol | **VENDOR from the anchor** | 204 lines, **zero value dependencies**; the package that ships it drags pxe |
| `wallet-sdk/src/crypto.ts` + `emoji_alphabet.ts` | **VENDOR from the anchor** | 920 lines, **zero dependencies of any kind**; same packaging reason |
| `wallet-sdk` `iframe/` and `extension/` providers | **REPLACE** (shape reused, code not) | they are transports for an iframe and a browser extension; M33's target is the in-page/worker case, which is a third transport beside them, not either of them |
| `@aztec/wallets` (`EmbeddedWallet`, incl. `entrypoints/browser.ts`) | **REJECT, `cannot-reach-target`** | its declared dependencies include `@aztec/pxe` **and** `@aztec/wallet-sdk`, so its closure is a superset of the one above; it is the M34–M36 wallet, not M33's provider |
| `@aztec/foundation/schemas` + `/json-rpc` (RI-82) | **DEPEND, unchanged** | already installed and already used by M32's worker protocol |

Residue, stated rather than dropped: derivation 3 reports **6 unresolved relative specifiers** in the
provider closure and they are the same six in every row — `constants.gen.js` (×2),
`protocol_contract_data.js` (×2) and two `contract-{class,instance}-registry.js`. All six are
**generated** files that do not exist in a source checkout; they are data modules (generated
constants and contract artifacts) and none of them is a door to another package. They are counted as
unresolved rather than assumed away, and the count is asserted.

---

## Step 1b — A CORRECTION TO §1.2, MADE BY THE THIRD DERIVATION AND WORTH THE PARAGRAPH

§1.2 above said the wallet half reaches `@aztec/pxe` by **four** edges "all named". That is
derivation 2's answer — four distinct `(file, specifier)` pairs — and it is not the bundle's.
Derivation 3, promoted into `verification/_m33_closure.py` and re-run on every check, reports
**three VALUE edges** out of **five import clauses**:

```
wallet-sdk/src/base-wallet/utils.ts:8        import type { ContractNameResolver }      @aztec/pxe/client/lazy   TYPE
wallet-sdk/src/base-wallet/utils.ts:9        import { displayDebugLogs }               @aztec/pxe/client/lazy   VALUE
wallet-sdk/src/base-wallet/utils.ts:10       import { generateSimulatedProvingResult } @aztec/pxe/simulator     VALUE
wallet-sdk/src/base-wallet/base_wallet.ts:36 import { displayDebugLogs }               @aztec/pxe/client/lazy   VALUE
wallet-sdk/src/base-wallet/base_wallet.ts:37 import type { PXE, PackedPrivateEvent }   @aztec/pxe/server        TYPE
```

Both derivations say the same thing about the conclusion — the wallet half reaches pxe and the
provider half does not — and only the third says how much survives type erasure. Recorded here
rather than silently corrected, because "four edges, all named" would have been a figure that was
right about its conclusion and wrong about its measurement, which is the shape this campaign keeps
finding.

---

## Step 2 — WHAT WAS BUILT, AND THE ENGINE THAT ALMOST MADE EVERY FIGURE WRONG

### 2.1 The one environment finding, and it cost three sets of measurements

The first three builds were taken in a **plain shell, node v25.9.0**. The checks build in **this
repository's own dev shell, node v24.19.0** — and `browser/build.mjs` reports gzipped sizes through
`node:zlib`, whose output differs between the two. Measured: the same tree gives
**8,158.59 KB / browser 264.87** on v25.9.0 and **8,188.71 / 263.75** on v24.19.0.

`CAMPAIGN-BRIEF.md` already names this exactly — *"the repository's own `.envrc` is the shell; the
workspace root's is not it"*, and *"a check that compiles must pin its PATH"*. It reached M33 in a
third disguise: not a missing tool and not the wrong `.envrc`, but the **system node** doing the
compressing. Every figure in this log and in `BROWSER-PACKAGING.md` is a dev-shell figure, and the
control build below was re-taken in the dev shell after the first one was found to be on v25.

### 2.2 The attribution, with a control build

The wallet entry moves `BROWSER-PACKAGING.md` §1's table. Two facts, both measured rather than
argued:

| | with the three new packages installed, WALLET ENTRY REMOVED | as shipped |
|---|---|---|
| `browser.js` | **255.87 KB, 8 files** | 263.75 KB, 9 files |
| `testing.js` | **279.93 KB, 10** | 288.90, 12 |
| `demo.js` | **281.13 KB, 10** | 290.12, 12 |
| `node/node.js` | **225.36 KB, 4** | 225.36, 4 |
| `worker.js` | **282.40 KB, 9** | 291.40, 11 |
| `worker-demo.js` | **283.48 KB, 11** | 292.48, 13 |

**The left-hand column is every pre-M33 figure to the assertion.** So installing `@aztec/aztec.js`,
`@aztec/entrypoints` and `@aztec/standard-contracts` moves *nothing*; the whole movement is esbuild
re-partitioning around a seventh entry point.

And the +7.88 KB on the reference entry is attributed per package, out of the metafile:

```
@aztec/stdlib      183,770 -> 208,639   +24,869
@aztec/foundation   48,737 ->  54,437    +5,700
@aztec/blob-lib      2,911 ->   3,841      +930
@aztec/aztec.js          0 ->       0        0   <- and this is the one that matters
@aztec/entrypoints       0 ->       0        0
@aztec/standard-contracts 0 ->      0        0
```

`verify_provider_half_dd9_clean` §9 asserts that zero on every run, with the wallet entry's own
**13,371** bytes of `@aztec/aztec.js` as the control that the measurement can be non-zero.

### 2.3 What was reused, vendored and written

| | dependencies |
|---|---|
| **REUSED (depend)** — `WalletSchema` from `@aztec/aztec.js/wallet` (RI-89) | `@aztec/aztec.js@5.0.0-nightly.20260626` added to `orchestration/package.json`; npm installed **three** packages (`aztec.js`, `entrypoints`, `standard-contracts`), none with a `.node` binary |
| **REUSED (depend)** — `@aztec/foundation/schemas` + `/json-rpc` (RI-82, M32's) | already installed |
| **VENDORED** — `wallet-sdk/src/{types,crypto,emoji_alphabet}.ts` at anchor `233d8e0993`, `PROVENANCE.md` **F25–F27**, `local-edits: none` (RI-88) | **none** — 1,124 lines with zero package edges |
| **WRITTEN** — `browser/src/entry_wallet.ts` | the three below, plus the vendored protocol |
| **WRITTEN** — `browser/src/wallet/port_wallet_provider.ts` | `@aztec/aztec.js/wallet`, `@aztec/foundation/{json-rpc,schemas}`, the vendored crypto and types, and `orchestration/src/disclosure.ts` for §8.4 |
| **WRITTEN** — `browser/src/wallet/port_connection_handler.ts` | the same, minus `disclosure.ts` |
| **WRITTEN** — `browser/src/wallet/null_wallet.ts` | `@aztec/aztec.js/wallet` only |
| **WRITTEN** — `tools/run_wallet_arms.mjs` | the BUILT `browser/dist/wallet.js`, and nothing else |
| **WRITTEN** — five verification scanners + `lib_m33_wallet.sh` | `_import_closure.py` (reused, not re-written) |
| **REJECTED** — `@aztec/wallets` (RI-91), `@aztec/wallet-sdk` as a package (RI-88), its two transports (RI-90) | — |

---

## Step 3 — THE FOUR CHECKS

```
verify_wallet_protocol_is_upstreams  33
verify_provider_half_dd9_clean       84
test_null_wallet_refuses_by_name     40
e2e_discovery_keyexchange_session    63
                              M33   220,  4/4, exit 0
```

Two defects were found in my own checks before they landed, both by running them rather than by
reading them:

1. **`comm -12` printed "file 1 is not in sorted order" three times AND STILL RETURNED EMPTY.** The
   assertion "no wallet export is in the reference bundle" was green over a tool that had refused to
   compare. It is a Python set intersection now, with a positive control that puts one name on both
   lists and requires the intersector to find it.
2. **A `"0\t"` comparison that could never be equal** to the tab-separated field it was reading, so
   the "no package dependency" assertion was red for a quoting reason and not a real one. Replaced
   by an `awk` field read, with the provider half's **9** as the control that the pair of zeroes is
   a reading rather than a shape.

---

## Step 4 — THE MUTATION MATRIX, eight arms

`scratchpad/campaign/m33-mutations.sh`, `setsid`-detached, in this repository's own dev shell.

| arm | mutation | result | the failures, read |
|---|---|---|---|
| M1 | a method returns a plausible default instead of refusing | **20 / 3** | `RESOLVED` names all sixteen; the check then dies at `m33_absent` and the trap prints the summary |
| M2 | the session stops binding `appId` | **63 / 6** | exactly §6's six, and only those |
| M3 | the provider accepts a response from a wallet it did not discover | **49 / 2** | the call SETTLES, so the timeout field is absent; `m33_absent` names it and dies |
| M4 | one message type's wire VALUE drifts | **33 / 2** | the byte-identity comparison and `VALUE_DIFF = PING` — and NOT `MISSING` |
| M5 | the wallet is no longer TOLD | **19 / 2** | `m33_absent` names all three disclosure fields and dies |
| M6 | **THE HANG** | **0 / 1 with a summary line** | `ArmTimeout: 'handshake.connect' exceeded 20000 ms` in the arm's own stderr; the run exits 1 and `m33_require_arms` dies naming the report it kept |
| M7 | **DIE BEFORE THE SUMMARY** | **1 / 2 with a summary line**, `M7 held` | `m33_absent` names all nine absent fields in ONE assertion and dies |
| M8 | a `WALLET-BOUNDARY.md` figure made stale | **84 / 1** | §9 names the figure AND its row |

**M7 DID NOT HOLD ON ITS FIRST RUN, AND THE GUARD IS WHAT SAID SO.** It reported
`M7 DID NOT HOLD: the report was re-measured under the arm` and **63 / 0** — a green arm over a
mutation that had been undone, which is M30's review's third state exactly. The cause is the race
that review names: the preceding arm's `restore_all` left the sources newer than `browser/dist`, so
`m27_require_bundle` rebuilt, the fresh bundle was newer than the report this arm had just hollowed,
and `m33_require_arms` re-measured over the hollow. Fixed by bringing the cache's producer current
BEFORE mutating the cache; re-run, it is 1 / 2 with the summary line and the hold confirmed.

**The restore is verified by content, not by tracked-ness.** M32's guard is
`git status --porcelain` against HEAD, which cannot work here because M33's files are staged and
uncommitted by design. The harness takes a `sha256sum` manifest of the six mutated files before the
first mutation and runs `sha256sum -c` after the last restore; it exits 4 if the content does not
reproduce. Verified after every round: `RESTORE VERIFIED`.

---

## Step 5 — TWO THINGS THE SELF-REVIEW PASS FOUND IN MY OWN CHECKS

Beyond the two in Step 3 (both found by *running* the checks), a read-through found a third and it
is `CAMPAIGN-BRIEF.md`'s purest family:

**`assert_ge "the handshake completed inside a sane wall-clock window" 0 "$ELAPSED"`** — a
wall-clock duration is never negative, so the assertion could not fail. It is gone. What replaced it
is what "every wait is bounded" can actually assert: the three declared bounds are read out of the
BUILT bundle and each asserted positive (a bound of zero is no bound), with the ORDERING asserted
too — `KEY_EXCHANGE_TIMEOUT_MS` the shortest, because a long window there helps a MITM, and
`DISCOVERY_TIMEOUT_MS` the longest, because it may need a human at the wallet end. One assertion
removed, five added: `e2e_discovery_keyexchange_session` goes **63 → 67** and M33 goes **220 → 224**.

### A recorded nit, not a defect

`tools/run_wallet_arms.mjs`'s ARM 1 constructs `wire()`'s handler and then a SECOND
`PortConnectionHandler` on the same port, because ARM 1 is the only arm that needs the
`onSessionEstablished` / `onPendingDiscovery` callbacks. **Only the second is ever started**, and
`PortConnectionHandler` installs `port.onmessage` in `start()` and nowhere else, so there are never
two handlers listening on one port. Recorded rather than tidied, because tidying it during the
sweep would put an unverified edit into the run.

---

## Step 6 — A FOREIGN COMMIT LANDED ON THE REMOTE, AND M0 SAW IT

`verify_workspace_repos_registered` went **156 / 1 failure** in this sweep, at
`aztec-avm-runtime: the workspace checkout shares history with the fresh clone`. The cause is
measured, not reasoned about, and it is not M33's:

```
local HEAD                     d3c8228   (M32's review's last commit)
git ls-remote origin dev       a2e0acd6
git cat-file -e a2e0acd6       fatal: Not a valid object name
```

**`origin/dev` moved to `a2e0acd6` and this checkout does not have that object.** The check clones
the remote and requires the local checkout to share history with it; with an unfetched move it
cannot. This is the same shape M32's review recorded in its Step 15 — a foreign commit landing
between one measurement and the next — pointing the other way: there, the commit landed and nothing
moved; here it landed and one assertion says so.

**Nothing was fetched during that sweep**, deliberately: a sweep is a measurement of the tree at the
moment it ran. Fetched afterwards, `verify_workspace_repos_registered` is **39 / 0** and m0 is
**156, 7/7, exit 0**. A fetch is neither a commit nor a push; it brought four commits of a
PARALLEL EFFORT into `refs/remotes/origin/dev` — see Step 8.

---

## Step 7 — THE FIRST SWEEP WAS ABORTED, ON PURPOSE, AND THE REASON IS A RULE I BROKE

The first sweep reached **m18** and found something M33 had moved and I had not:
`verify_orchestration_reuse_enumerated` pins the orchestration's dependency list **exactly**, and
M33 adds a fifth entry. **66 assertions, 1 failure** — the count unchanged, the value wrong, which
is the shape that check exists to produce.

I fixed it *while the sweep was still running*, and that is the rule I broke:
`CAMPAIGN-BRIEF.md` — *"a sweep is a measurement of the tree at the moment it ran"* — and
*"run your sweep after your last commit, not before it."* Editing `orchestration/package.json` and
a check mid-run means the remaining milestones would have measured a different tree from the first
eighteen. **So the sweep was killed and restarted rather than finished and explained**, and the
aborted log is kept at `~/.cache/m33/sweep-aborted.log` as the record.

Before restarting, the four milestones most likely to be moved by a new `@aztec` dependency were
run individually, with nothing else running:

| | | |
|---|---|---|
| **m18** | **283** (66 / 28 / 38 / 28 / 123), 5/5 | the fix; the expectation moved to the five, EXACTLY, with the reason measured rather than asserted |
| **m21** | **325**, 8/8 | `verify_oq2_pxe_embedding_decision_recorded` and `verify_txe_private_flow_prior_art_consulted` both read the manifest and both still pass — the forbidden four are still absent, and `@aztec/aztec-node` is not `@aztec/aztec.js` |
| **m27** | **345**, 10/10 | after `BROWSER-PACKAGING.md` §1 and §6 were corrected |
| **m28** | **353**, 6/6 | after `BROWSER-GATE.md` §3 was corrected — see below |

**AND M28 FOUND THREE MORE FIGURES, WHICH IS WHAT M28 IS FOR.** `just ci-browser-gate` came out
**104 / 3**, each failure naming its figure and its line:

| figure | was | is | why |
|---|---|---|---|
| the browser bundle's module-graph inputs | 1068 | **1135** | `m28_scan` reads the whole PASS's metafile, and the pass gained `wallet.js` |
| `util` import edges in that graph | 43 | **45** | two more, from the wallet entry's closure |
| the declared dependency closure | 268 | **271** | `@aztec/aztec.js` + `@aztec/entrypoints` + `@aztec/standard-contracts`, three exactly |

`optionalDependencies` stays at **3**, which is the figure D22 is about, so nothing native moved.
All three were found by the gate re-deriving them, which is the instrument M28's review had to
write after eleven of M27's figures rotted unnoticed.

---

## Step 8 — A PARALLEL EFFORT LANDED ON `origin/dev`, AND IT COLLIDES WITH M33'S INVENTORY IDS

`origin/dev` went `d3c8228` -> **`a2e0acd6`**, four commits, from the **L0 live-chain replay**
track: `replay/` (a node client, 1,019 lines of `src/`), three checks, a mutation harness and a
log. `d3c8228` IS an ancestor, so a rebase is a fast-forward for the base and a normal replay for
this work.

**It takes RI-86 and RI-87.** `createAztecNodeClient`/`AztecNodeApiSchema` and M21's
`strictSurface`. M33 had appended RI-86..RI-89, so **M33's four entries are renumbered
RI-88..RI-91**, everywhere they are cited — `REUSE-INVENTORY.md`, `PROVENANCE.md`'s F25–F27,
`WALLET-BOUNDARY.md`, `CAMPAIGN-BRIEF.md`, the milestone section, the three vendored files'
provenance headers (regenerated by `just vendor-headers`, `rewrote 0 file(s)` afterwards) and this
log. Re-verified: `verify_reuse_inventory_complete` **19 / 0**, `verify_provenance_complete`
**68 / 0**, `just check-drift` **22 / 0**, `just verify-m33` **224, 4/4**.

**This tree deliberately still sits on `d3c8228` and there is a RI-86/RI-87 GAP in it.** That is not
an oversight: the campaign reference of 11,054 was measured on `d3c8228`, so a sweep on that base is
the only one in which "M33 moved M1 and nothing else" is a statement about M33. The gap closes the
moment the work is rebased onto `origin/dev`, and none of the three inventory/provenance checks
requires contiguity — measured, not assumed.

**What the reviewer inherits.** `Justfile` and `REUSE-INVENTORY.md` are appended to by both tracks
and will conflict textually on the rebase; both resolve by keeping both appends. `pins.json` is
L0's alone (164 lines) and M33 does not touch it. The other seventeen files L0 adds are new paths.
L0 also adds `replay/src` as a source root and three checks, either of which may move M0's
`verify_named_checks_exist` and M21's `verify_no_pipeline_predicates` — both of which are **9** and
**69** on THIS base, and both of which are L0's to account for on its own.

---

## Step 9 — THE SWEEP: M0–M33 at 11,282, delta +0, every milestone at reference TO THE ASSERTION

`setsid`-detached, `direnv exec <aztec-avm-runtime>` — this repository's own dev shell, node
v24.19.0 — one milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`.
Started 07:32:17, finished 09:15. **68 markers for 34 milestones: no hole.**

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234  m33 224
                                                       CAMPAIGN TOTAL 11,282
```

**The summariser reports `delta +0` against a reference table that names both moves in advance**, and
11,054 + 224 + 4 = 11,282 exactly.

- **M33's own 224** is 33 / 84 / 40 / 67 across four checks.
- **M1 175 -> 179, and it is the only other number that moved.** `verify_provenance_complete`
  64 -> 68: M22's mechanism exactly — one `is tracked` assertion per new single-file row (three:
  F25, F26, F27) plus one for RI-88, an inventory id no row had cited before. 3 + 1 = 4, exact in
  both parts.
- **Nothing else moved.** `verify_pinned_nightly_single_source` 28 (M33 declares no pin;
  `@aztec/aztec.js` goes in at the `deletion_era` pin the file already names),
  `verify_no_pipeline_predicates` 69, `just check-drift` 22, `verify_named_checks_exist` 9,
  `just check-repo-hygiene` 28, `verify_reuse_inventory_complete` 19, **M27 345 and M28 353** with
  the browser bundle rebuilt many times and six of their document figures corrected.
- **M9 did NOT flake** — 807, 7/7, exit 0 in 1,283 s, immediately after M8's build, which is D19's
  standing hypothesis and it did not fire. **M15 did not flake either** (537, 382 s).

### The two non-zero exits

**M11 = 262, rc 1, SIX failing assertions — the recorded ninth-upstream-move signature, unchanged.**
`verify_carry_set_applies_to_upstream_head` 52 / 4 (the `barretenberg/cpp` conjunct: upstream touched
**5** paths there against an expected 0, so the decision procedure exits 2 and prints `void` rather
than `transfers`) and `verify_carry_ledger_complete` 17 / 2 (the committed ledger's digest against
what the data renders to). **The COUNT is the signature and it is unchanged**; the failure count is
not — M32's sweep read nine, this one six, at the same condition. Not repaired, `carry/` left at
HEAD.

**M32 = 234, rc 1, TWO failing assertions — AND THAT ONE WAS MINE.** `WORKER-NODE.md` §5's demo row
carried **290.13** where `test_worker_transferable_container_not_copied` computes **290.12**. It is
the exact rounding tie `CAMPAIGN-BRIEF.md` records happening to M32 at 281.125: `browser/build.mjs`
prints `+(gzip/1024).toFixed(2)` and the checks use Python's `round(gzip/1024, 2)`, so JavaScript
rounds half away from zero and Python is banker's. The brief's own rule — *the document must carry
the CHECK's value* — and I wrote the build's. **The count did not move**, which is what says it is a
figure and not a structure. Corrected, and re-run: **234, 4/4, exit 0** (82 / 71 / 38 / 43). M32's
four checks are the only readers of `WORKER-NODE.md`, so nothing else needed re-running.

*(That is the sixth document figure M33 moved and the fourth kind of instrument that caught one:
`verify_browser_chunk_budget` §6 caught three in `BROWSER-PACKAGING.md`, `ci_browser_gate` §6 caught
three in `BROWSER-GATE.md`, `test_worker_transferable_container_not_copied` §5 caught this one, and
M33's own `verify_provider_half_dd9_clean` §9 catches its own. Every one of them was found by a
check re-deriving a number from the artefact, which is the whole argument for writing them.)*

### A sweep is a writer

`carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` / `ec959b84…` before, came out
`79f597b2…` / `3836c2b6…` — the same two post-sweep digests M30's, M31's and M32's runs all recorded,
so the mechanism is unchanged — and were restored from HEAD, confirmed by `sha256sum -c`, both OK.

### `noir-wt4-webpage` was untouched throughout

`f0e7edcd2` on `wasm/webpage`, exactly its one pre-existing edit (`tooling/tracer/src/tracer_glue.rs`),
`git for-each-ref --contains HEAD refs/remotes` = **0**, and zero remote refs named `wasm/webpage`.
No commit, no push. `aztec-packages` is clean and untouched at `ee3c0528d54`.

---

## Step 10 — the tree, as it is left

| repo | branch | HEAD | published | tree |
|---|---|---|---|---|
| `aztec-avm-runtime` | `dev` | **`d3c8228`** (four behind `origin/dev`'s `a2e0acd6`; `d3c8228` IS an ancestor) | not pushed — **no commit was made** | 40 paths staged, nothing unstaged |
| `codetracer-specs` | `latest` | unchanged | not pushed | `Planned-Work/Aztec-AVM-Runtime.milestones.org` modified (M33's section, and M1's Verification count) |
| `noir-wt4-webpage` | `wasm/webpage` | **`f0e7edcd2`** | **contained in ZERO published refs** | exactly its one pre-existing edit (`tooling/tracer/src/tracer_glue.rs`) |
| `aztec-packages` | — | `ee3c0528d54` | — | clean, untouched |

Re-verified after the last edit: **m0 156 · m1 179 · m16 223 · m32 234 · m33 224**, all 0 failures,
and `carry/rebase.json` / `carry/exposure.json` at their pre-sweep digests (`sha256sum -c`, both OK,
`git status --porcelain -- carry/` empty).

### The four entries

| | |
|---|---|
| `verify_wallet_protocol_is_upstreams` | **passed**, 33 |
| `verify_provider_half_dd9_clean` | **passed**, 84 |
| `test_null_wallet_refuses_by_name` | **passed**, 40 |
| `e2e_discovery_keyexchange_session` | **passed**, 67 |

None pending.

### For the reviewer, in order of what would cost most to miss

1. **The rebase.** `origin/dev` is four commits ahead with the L0 replay track. `Justfile` and
   `REUSE-INVENTORY.md` are appended to by both and conflict textually; keep both appends. M33's
   inventory ids are already RI-88..RI-91, so the gap at RI-86/RI-87 closes rather than collides.
2. **The sweep is on `d3c8228`**, deliberately — the same base 11,054 was measured on. After the
   rebase, L0's `replay/src` source root and three checks may move M0's `verify_named_checks_exist`
   and M21's `verify_no_pipeline_predicates`; both are 9 and 69 on this base.
3. **M11's red is the ninth upstream move**, unrepaired, `carry/` left at HEAD. Six failing
   assertions this time against nine last time, at the same condition; the COUNT (262) is the
   signature.
4. **`WALLET-BOUNDARY.md` §5 states a boundary rather than glossing one**: the handshake is real —
   real ECDH P-256, HKDF and AES-256-GCM over a real `MessagePort`, against the BUILT bundle — and
   it is measured in Node. Nothing here runs `wallet.js` in Chromium. Do not let "the handshake
   works" drift into "the handshake works in a page".
