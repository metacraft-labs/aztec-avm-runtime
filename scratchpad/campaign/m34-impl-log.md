# M34 — The CodeTracer Dev Wallet (public entrypoints) — IMPLEMENTATION log

Written as I go.

## Step 0 — the state I inherited

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `0902fa9` | clean |
| `codetracer-specs` | ? | ? | ? |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | one pre-existing edit — NOT to be committed |

`git fetch origin` taken: **`HEAD == origin/dev == 0902fa9`, zero ahead, zero behind.** No rebase
was needed — M33's review already rebased onto L0's `a2e0acd6` and pushed. The parallel L0 track has
not moved since.

No sweep was running when I started: `ps` shows three stale `tail -f` processes from earlier
reviews' logs and no `verify-m*` / `verify-l*` process.

`REUSE-INVENTORY.md` carries 92 `### RI-` headings, of which one is the `### RI-nn — name` template,
so the ids are RI-01..RI-91 and **the next free id is RI-92**. *(That was true at Step 0 and stopped
being true at Step 8 — see below. The three entries are RI-94..RI-96.)*

Environment: the system node is v25.9.0; everything below runs through
`direnv exec /home/zahary/m/blocktracer/aztec-avm-runtime` (node v24), which is the engine the
checks and CI use.

---

## Step 1 — THE ENUMERATION, BEFORE A LINE WAS WRITTEN

The campaign has been wrong **ten** times about whether something needed building, and M33's own
tenth was found by enumerating first. M34's plan gives four named things to reuse; each was
measured, and **the biggest one came out `no`.**

The instrument is M33's own walker. `verification/_m34_closure.py` is thirty lines that import
`_m33_closure.py` and add four GROUPS — the resolver, the type-erasure rule, the residue categories
and the dynamic-import census are all M33's and none of them is copied. A second walker would be a
second answer to one question.

### Q1 — is `BaseWallet` subclassable? **NO, and the measurement has four parts.**

| part | measurement |
|---|---|
| the PACKAGE | `@aztec/wallet-sdk` -> `@aztec/pxe` -> `@aztec/simulator` -> `@aztec/native` + `@aztec/world-state`. RI-88, M33's, unchanged. |
| the VENDORING COST | `base-wallet/index.ts` ALONE: **656 files, 79,060 lines, 15 workspace packages**, reaching `@aztec/pxe` AND `@aztec/simulator` through **three named VALUE edges** (`base_wallet.ts` -> `@aztec/pxe/client/lazy`; `utils.ts` -> `@aztec/pxe/client/lazy` and `@aztec/pxe/simulator`). "666 lines" is the file; 79,060 is the bill. |
| the CONSTRUCTOR | `protected constructor(protected readonly pxe: PXE, protected readonly aztecNode: AztecNode, …)`. It does not import a PXE, it **requires an instance**. |
| the FIVE METHODS | `getAccounts` is `abstract` — no body at all. `registerContractClass` is `return this.pxe.registerContractClass(artifact)`. `registerSender` is one `this.pxe.registerTaggingSecretSource(…)`. `getChainInfo` is two lines over `aztecNode.getNodeInfo()`. `getContractMetadata` is `this.pxe.getContractInstance` plus three `aztecNode` calls. **Between them, zero lines of reusable logic that do not require a `PXE`.** |

(And a fifth, smaller: `base_wallet.ts` opens `import { inspect } from 'util'` — a Node builtin M28's
gate refuses.)

So the decision is **replace**, `cannot-reach-target`, RI-93. The 666 lines are almost entirely
`simulateTx` / `profileTx` / `completeFeeOptions`, which is M35's path and not M34's.

### Q2 — the other three, and all three are `yes`

- **`WalletSchema` (RI-89, M33's).** Re-derived here rather than quoted: **298 files / 31,205
  lines / 5 packages, reaching none of the four**, which is M33's figure to the unit through a
  walker invoked differently.
- **Upstream's public-only entrypoint shape.** `wallet-sdk/src/base-wallet/utils.ts`'s
  `simulateBatchViaNode`, *"Minimal entrypoint structure — no real private execution, just public
  call requests"*. **Reused as a SHAPE and not as code**, because the function that builds it calls
  `generateSimulatedProvingResult` from `@aztec/pxe/simulator` — one of the three pxe VALUE edges
  above. M26's vendored `createTxForPublicCalls` (RI-72, F20–F24) builds the same object without it.
- **M26's vendored builder.** Used as `token_transfer.ts` uses it, tripwire and all.

### Q3 — what upstream's OTHER entrypoint does, because the plan did not say

`@aztec/entrypoints` is installed and is **clean — 193 files / 22,463 lines / 5 packages, reaching
none of the four.** And `DefaultEntrypoint` is still unusable, for a reason that is one line of its
own source: `if (call.type !== FunctionType.PRIVATE) throw new Error('Public entrypoints are not
allowed');`. Measured rather than assumed, and recorded so nobody re-opens it.

### Q4 — `worker_wallet.test.ts`, the 22-line worked example

Read. It is `Reflect.construct(WorkerWallet, [undefined, stubClient])` — a way to test a wallet
PROXY with no worker. M34 does not need it: the dev wallet is a plain object behind M33's
`getWallet` callback, so a test constructs it directly. Its actual lesson is the one in its own
comment — *"registerContract / registerContractClass return void, which the worker serialises as
`undefined`; feeding that to JSON.parse throws"* — and **that lesson turned out to be about the
ANCHOR and not about the pin**; see Step 3.

### THE ELEVENTH NEAR-MISS DID NOT HAPPEN, AND THE ENUMERATION IS WHY

`git ls-tree | grep -i wallet` at the anchor, by directory, reproduced M33's seven locations and
found nothing M33 had not. `@aztec/wallets` (RI-91) is still `cannot-reach-target` for RI-88's
reason. Nothing new to adopt, and that is a measurement rather than an absence of effort.

---

## Step 2 — WHAT WAS WRITTEN

| file | what it is |
|---|---|
| `browser/src/wallet/dev_keys.ts` | deterministic derivation: seed -> poseidon2 -> upstream's `deriveKeys` -> upstream's `computeAddress`. No ambient randomness anywhere. |
| `browser/src/wallet/dev_wallet.ts` | the wallet. Ten of `WalletSchema`'s sixteen methods served, six refused BY NAME with a reason each, a decision ledger, and `sendTx` building the public-only transaction with M26's vendored builder. |
| `browser/demo/wallet_main.ts` + `wallet.html` | the demo page and the harness, M27's convention: every arm is a button. |
| `tools/run_wallet_transfer_arms.mjs` | seven arms, ALL IN CHROMIUM. |
| `verification/_m34_closure.py` | thirty lines over M33's walker. |

Three existing files were touched, each additively:
`browser/src/entry_wallet.ts` (+22 exports, `WALLET_ENTRY_OPS` moved in step with them, because
M33's check compares the declaration and the artefact as SETS in both directions);
`browser/src/ct_download.ts` (an OPTIONAL `extraLogEvents`, defaulting to none, so M27's and M29's
`logEvents` figure of 1 is unmoved);
`orchestration/src/resident_db.ts` (`nullifierExists`, the same two-call shape as
`readPublicDataLeaf` with the other tree id).

### The key derivation is upstream's, and that it works here was not obvious

`browser/src/foundation_grumpkin.ts` records that address derivation is the SECOND route from a
public-only page to the 7.9 MB proving stack. Under this build's redirect table the route is clean:
`sha512ToGrumpkinScalar` is `hash.js` (pure JS), and every curve and hash operation is the module's.
**Measured in the page: 45 poseidon2 calls, 14 grumpkin calls, and ZERO requests containing
`barretenberg`.**

**And `foundation_grumpkin.ts`'s header is wrong about one thing.** It says `reduce512BufferToFr`
"has exactly one caller in this graph: `deriveKeys`". `git grep reduce512BufferToFr` at the anchor
over `yarn-project/` finds the two DECLARATIONS (grumpkin's and secp256k1's) and **no caller at
all**. The throw is still right; the sentence naming its caller is not, and it is the sentence that
would stop somebody trying this route. Corrected in `dev_keys.ts`'s header rather than left.

## Step 3 — THE INSTALLED PIN IS THE AUTHORITY, AND IT DISAGREES WITH THE ANCHOR TWICE

Both found by RUNNING the thing, both in upstream's own codecs, and both would have been invisible
to a reader of the anchor's source. This is M23's `AztecNodeDebug` family — five methods at the
anchor, three at the pin — in a second place.

| method | the `cpp` anchor's source | `@aztec/aztec.js@5.0.0-nightly.20260626`, measured |
|---|---|---|
| `WalletSchema.registerContract` | `output: z.void()` | an **intersection** of the instance preimage with `{address}` — `undefined` FAILS |
| `FunctionCall`'s return type | `returnType?: AbiType` with a back-compat transform accepting `returnTypes` | `returnTypes: z.array(AbiTypeSchema)`, **required**, and `toJSON` emits it |

Measured with `getSchemaReturnType(WalletSchema[k]).parseAsync(undefined)` over all sixteen methods:
**`registerContractClass` is the only one that accepts `undefined`.** So upstream's own worked
example — `worker_wallet.test.ts`, whose subject is precisely that void-returning methods serialise
as `undefined` — is testing a property that holds for ONE of the two methods it names, at this pin.

## Step 4 — THE ARMS RAN, IN CHROMIUM, AND ALL SEVEN PASS

`node tools/run_wallet_transfer_arms.mjs`, rc 0. The headline:

```
transfer_in_public through the wallet: outcome=processed  block=1  revertCode=0
  516 executed steps across 2 AVM contexts    (M29's direct-path figures, to the step)
  contractClassId and contractAddress IDENTICAL to the direct shortcut's
  0 requests containing 'barretenberg'
  13 wallet decisions, all of them in the .ct container
```

The container: **196,608 bytes, 389 steps positioned, 127 unpositioned, declaredRung 2, 15 log
events** — 1 mapping-rung + 1 step-producer + 1 wallet-seed + 12 wallet-decision... no: 1 + 1 + 1 +
13 = 16 `Event` records, of which `logEvents` counts 15 (the rung is declared, not logged). Read
back through the PINNED `ct-print --full`, every decision is there as an `elkTraceLogEvent` with
`metadata: "ct.wallet-decision"`.

Three defects the run found, each fixed and each worth recording because each is a shape:

1. **A ZodError with two union issues at an EMPTY path and no method name.** One of nine calls
   failed and nothing said which. `callWallet(c, method, …)` attaches the name now — "a failure that
   cannot name its subject" is what most of this campaign's rules are about.
2. **`Object couldn't be returned by value`**, CDP's entire diagnosis, once `sendTx` succeeded and
   the report carried a `TxHash` instance. `jsonSafe()` converts at the page boundary.
3. **THE REFUSALS ARM WAS MEASURING THE WRONG REFUSAL.** Called over the wire with no arguments,
   a refused method never reaches the wallet: upstream's `parseWithOptionals` rejects the ARGUMENTS
   first, with a `too_small` zod error naming no method. All six "refusals" were upstream's codec,
   not the wallet's. The arm now calls each one DIRECTLY (where the refusal is `DevWalletRefused`
   naming the method) and sends ONE refused method over the wire with arguments the codec accepts,
   so a refusal is also shown to survive the whole encrypted round trip.

Also fixed by running it: `transfer_in_public` is not in `artifact.functions` at all — a `#[public]`
function of a contract with a `public_dispatch` lives in `nonDispatchPublicFunctions`, and
`getContractFunctionAbi` is upstream's own two-place lookup. "The artifact has no
transfer_in_public", over an artifact that has it.

---

## Step 5 — THE CHECKS: M34 = 206 (79 / 49 / 33 / 45), 4/4, exit 0

| check | assertions | what it is about |
|---|---|---|
| `e2e_wallet_public_transfer` | **79** | the transfer, the handshake, the refusal partition, the declining control, and §8's document comparison |
| `test_wallet_keys_deterministic` | **49** | determinism in two engines and three processes, plus the structural no-randomness half |
| `test_deployment_through_wallet` | **33** | registration through the wallet, and the labelled shortcut |
| `verify_wallet_decisions_appear_in_trace` | **45** | the ledger, read out of the CONTAINER through the pinned reader |

## Step 6 — THE MUTATION MATRIX: nine arms, and every one reads WHICH assertions went red

`scratchpad/campaign/m34-mutations.sh`. The harness is M33's, with one thing made stricter:
**`still_there` failing now restores, verifies and exits 5**, where M33's diagnosed and continued —
which is the fifth appearance of that family and the one `CAMPAIGN-BRIEF.md` asks to be a failure.

| arm | mutation | result | the failures, read |
|---|---|---|---|
| M1 | an unserved method returns a plausible default | 79 / 4 | `RESOLVED` for all six refused methods; the over-the-wire refusal becomes a ZodError instead of a `DevWalletRefused`; **and a fourth that is the mutation's own byte cost**, two packaging figures moving by one hundredth |
| M2 | the wallet authorizes and does not RECORD it | 45 / 5 | the signing decision is gone from the container, the account it named with it, the two containers become identical, and the set difference reports `NOTHING REMOVED` |
| M3 | the derivation reads `Date.now()` — a spelling the census does NOT name | 49 / 5 | both same-seed identities, the cross-process pair, and the Chromium-versus-Node comparison. **The structural half stays green, which is the point of the arm** |
| M4 | the decisions stay in the wallet's report and never reach the container | 45 / 23 | every per-method assertion, the byte-for-byte comparison, the sequence check and the log-event floor |
| M5 | the wallet registers the class and RECORDS that it did not | see below | §1's `registered=1` |
| M6 | a dev shortcut still works and stops being named one | 33 / 1 | the labelled-write count, 3 against a floor of 4 |
| M7 | **THE HANG** — the wallet never posts `WALLET_READY` | 0 / 1 **with a summary line** | bounded and NAMED: the provider's `wallet-ready` wait runs out at 15,000 ms, the arm run exits 1, `m34_require_arms` dies naming the kept report, and the abnormal-exit trap prints the summary |
| M8 | **DIE BEFORE THE SUMMARY** — the arm report is hollowed | 2 / 2 **with a summary line**, and **M8 held** | `m34_absent` names all four absent fields in ONE assertion and dies |
| M9 | a figure in `DEV-WALLET.md` is made stale | see below | §8 names the figure AND the row |

**M5's FIRST VERSION WAS THE WRONG SHAPE, AND THE RULE IS THE BRIEF'S OWN.** It skipped the host
call entirely, so the class never reached the module, the transaction could not execute, the ARM RUN
exited 1 and the check died at `m34_require_arms`: **`0 assertion(s), 1 failure(s)`** — the
die-before-summary path working, and **not one assertion of the section the arm was written for**.
"The check failed" and "the check saw what I broke" are different statements. Rewritten so the write
still happens and only the RECORD lies, which is also the more dangerous defect of the two.

**AND M9 FOUND A DEFECT IN M34's OWN CONTROL.** Over an already-perturbed document, §8's
perturbation control finds nothing to perturb, its `python3` heredoc dies on an `assert`, and the two
assertions after it fail for a reason that has nothing to do with the comparer — 79 / 3 where the
arm predicts 79 / 1. That is `CAMPAIGN-BRIEF.md`'s fourth mutation state ("a substitution that does
not find its needle") **inside a check rather than inside a harness**. The control `die`s naming the
cause now.

**M1's fourth failure is not coverage and is recorded as such.** Mutating a source file changes the
bundle's bytes, so `DEV-WALLET.md`'s two packaging figures move by a hundredth of a kilobyte and §8
reports them. That is §8 behaving correctly over a tree M34 does not ship; it is an artefact of
mutating the subject and not an assertion the arm exercised.

## Step 7 — WHAT M34 MOVED ELSEWHERE

- **M33 245 -> 246.** `verify_provider_half_dd9_clean` 105 -> 106, and the +1 is one non-emptiness
  assertion. Its `cpp_` byte scan was asked of `wallet.js` ALONE; M34's eighth entry point made
  esbuild hoist the wallet's modules into a shared chunk, `wallet.js` became a **0.67 KB** re-export
  stub, and the scan's PAIRED positive-control needle (`aztec-wallet-`) went red — which is what a
  paired needle is for and is the only reason this was noticed. It is asked of the whole eager SET
  now, which is also the question DD-11 means.
- **Six document FIGURES in four documents, every one caught by the check that re-derives it**:
  `BROWSER-PACKAGING.md` §1's four eager rows and its total; `BROWSER-GATE.md`'s browser input count
  1135 -> 1138; `WORKER-NODE.md` §5's six-row table (plus a seventh row for the new entry); and
  `WALLET-BOUNDARY.md` §6's four wallet figures.
- **Every eager total FELL by roughly 0.7 KB**, which is the mechanism working rather than an
  anomaly: an eighth entry sharing the same modules lets esbuild hoist MORE into chunks several
  entries already carry, and a chunk counted once is smaller than the same code duplicated.
- **One budget bump, as data**: the wallet entry's eager budget 270 -> 300 KB with a `bumps` entry
  naming the cause. The zero DD-11 rests on did not move.
- **Nothing else**: `verify_provenance_complete` 68 (M34 vendors nothing),
  `verify_pinned_nightly_single_source` 28, `verify_no_pipeline_predicates` 69,
  `verify_named_checks_exist` 9, `check-repo-hygiene` 28, `verify_reuse_inventory_complete` 19,
  M27 **345**, M32 **234**, M28 **353 with the ONE failing assertion that is L0's** —
  `verify_npm_pack_no_optional_native` pins the tracked `package.json` list and `replay/package.json`
  is a fifth tree. Recorded and deliberately not fixed, exactly as M33's review recorded it.

**AND `verify_named_checks_exist` WENT RED ONCE, IN MY OWN PROSE.** `dev_keys.ts` cited upstream's
`test_wallet.ts` by filename and the repo-wide scanner read `test_wallet` as a check name that does
not exist. Reworded to name the CLASS instead; the scanner is right and the citation was the problem.


---

## Step 8 — `origin/dev` MOVED SEVEN COMMITS MID-MILESTONE, AND THE SWEEP CAUGHT IT

I fetched and rebased at Step 0 and there was nothing to do: `HEAD == origin/dev == 0902fa9`. By the
time the sweep started, the parallel track had pushed **seven L1 commits** (`410d76c`), and **m0
went red thirty-seven seconds in** — `verify_workspace_repos_registered`, on *"the workspace checkout
shares history with the fresh clone"*. That check clones the remote default branch and asks whether
this checkout contains its head; it is the instrument for exactly this and it worked.

**The sweep was KILLED and will be re-run, rather than finished and explained.** A run whose first
milestones measure a different tree from its last is not a measurement — M33 did the same one
milestone earlier, for the same reason. The aborted log is kept at
`~/.cache/aztec-m34-sweep-aborted.log` (two milestones: m0 rc=1, m1 rc=0 at 179).

### The rebase

`git stash push -u` -> `git merge --ff-only origin/dev` (0 ahead, 7 behind, so a fast-forward) ->
`git stash pop`. **Exactly one textual conflict, `Justfile`, a pure append at EOF**; both appends
kept, L1's first. Everything else — `REUSE-INVENTORY.md`, `CAMPAIGN-BRIEF.md`, the eight tracked
files M34 edits — merged clean.

**AND THE CONFLICT MARKERS ARE DIFF3, WHICH IS A HAZARD `origin/dev`'S OWN HEAD COMMIT IS ABOUT.**
That commit is *"fix: strip two diff3 base markers left by the L1 rebase"*. This checkout's
`merge.conflictStyle` produces FOUR markers — `<<<<<<<`, `|||||||`, `=======`, `>>>>>>>` — and my
first resolution kept the `|||||||` line and its base region as content, exactly as L1's had. It was
caught in seconds because `just --list` refuses to parse a `|||||||` line, but a Markdown file would
have swallowed it silently. **Grep for all four markers after resolving.** Recorded in
`CAMPAIGN-BRIEF.md` beside the append-and-renumber paragraph.

### The renumbering

L1 took **RI-92** (`Tx`'s public-call accessors) and **RI-93** (recording at `JsonRpcFetch`). M34's
three entries were written as RI-92..RI-94 and are **RI-94..RI-96** now, renumbered in
`REUSE-INVENTORY.md`, `DEV-WALLET.md`, `browser/src/wallet/dev_wallet.ts` and the milestone section.
Verified mechanically rather than read: **97 `### RI-` headings, of which one is the template, ids
RI-01..RI-96, no duplicate** — `sort | uniq -d` is empty, where before the renumber it printed 92
and 93.

*This is the third time two campaigns have appended the same id to one file, and the second time
the M-track has been the one to renumber. The id is assigned when the work LANDS, not when it is
written.*

### And the sweep was restarted a SECOND time, for the rule rather than for a finding

After the rebase I improved two comments in `dev_wallet.ts` while the restarted sweep was five
minutes in. `CAMPAIGN-BRIEF.md`'s rule is *"run your sweep after your last commit, not before it"*,
and a comment is an edit. Killed, rebuilt, and **confirmed the rebuild produced identical eager
figures for every entry point** (esbuild minifies comments away, so the bytes did not move) — which
is the measurement that says the restart was procedural rather than necessary — then restarted.

Recorded because the cheap version of this rule is "kill it and re-run", and the expensive version
is M24's: a comment in `ct-host/src` invalidates a content stamp and buys a twelve-session benchmark
and a document re-render.


---

## Step 9 — ONE MORE CORRECTION, FOUND BY READING MY OWN COMMENT

`DEV_WALLET_SERVED`'s doc comment claimed the list was *"compared against the ones it actually
answers, in both directions"*. **Nothing compared them.** The property was true behaviourally — the
checks exercise all sixteen methods, ten across the encrypted session and six required to refuse —
but the mechanism the comment described did not exist, and three separate declarations of one
partition (`DEV_WALLET_SERVED`, the `served` object, and `DEV_WALLET_REFUSAL_REASONS`) are three
things to drift. A method listed as served that silently refuses is the plausible-default shape
wearing a table of contents.

`assertServedMatchesDeclaration` reconciles all three at construction and throws NAMING the
difference in either direction; `e2e_wallet_public_transfer` §6 exercises it both ways over the
BUILT bundle (a correct list accepted; a list with one name dropped and one fabricated rejected,
with both directions in one message), and adds the behavioural half a construction-time guard cannot
give — **not one of the ten served methods appears in the wallet's own ledger as refused**, over a
run in which all ten were exercised, with the exercised count asserted so an under-exercised run
cannot satisfy it vacuously.

**e2e_wallet_public_transfer 79 -> 83; M34 206 -> 210.** Four assertions, itemised: three for the
guard (accepts, rejects the missing direction, rejects the extra direction) and one for the ledger.

*The sweep was killed a THIRD time for this, twenty-five minutes in.* The alternative was to ship a
comment that overstates its mechanism beside a sweep that predates the fix, which is the
prose-drifts-from-measurement family with the evidence attached.

**And it moved two more figures**, because adding an export changes the bundle:
`WALLET-BOUNDARY.md` §6's wallet rows (own module 0.67 -> 0.69 KB, eager 274.98 -> 275.21 KB),
`BROWSER-PACKAGING.md`'s total (8,195.74 -> 8,195.96) and `DEV-WALLET.md` §6's two rows. Every one
was named by the check that re-derives it, which is the whole argument for writing them that way.

### One edit deliberately DEFERRED until after the sweep

M33's Outstanding tasks say *"a wallet-demo page in M34's arms would run the handshake there too"*,
and M34's arms do. Closing that sentence is a one-line edit to
`codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org` — **and that file IS read by a
check**: `verify_fallback_triggers_recorded_and_evaluated` (M16) matches its seven conjunct texts
verbatim against it, because *"the milestone is the authority for what the triggers say"*. The edit
is in a different section and cannot touch those conjuncts, but "a sweep is a measurement of the tree
at the moment it ran" does not have an exception for edits one believes to be harmless. Deferred to
after the sweep, with m16 re-run to confirm.

---

## Step 10 — THE SWEEP: M0–M34 at 11,514, delta +0, no hole

Measured 2026-08-29 after the last edit, `setsid`-detached in this repository's own dev shell
(node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`, **70 markers for 35 milestones: no hole**, **33 of 35 exit 0**, on the tree rebased onto
`origin/dev` `410d76c`:

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234  m33 246  m34 210
                                                   CAMPAIGN TOTAL 11,514
```

**Every one of M0–M32 came out at its reference value TO THE ASSERTION**, and
**11,303 + 1 + 210 = 11,514** exactly, with the summariser reporting `delta +0` against a reference
table naming both moves in advance. **M9 did NOT flake** — 807, rc 0, 1,282 s, immediately after
m8's 178 s run, which is D19's standing condition and it did not fire.

### L0's and L1's contribution is ZERO, and it is a measurement

Their six check names — `verify_node_client_surface_narrow`,
`test_node_client_refusals_distinguishable`, `verify_client_uses_upstream_schema`,
`e2e_fetch_settled_transaction`, `test_missing_contract_artifact_refused`,
`test_private_half_declared_absent` — appear **zero times in the whole sweep log**. They live in
`just verify-l0` and `just verify-l1`, which no `verify-m<N>` recipe invokes. Their own totals are
separate figures and are not in the 11,514.

### The two non-zero exits, and only one is this repository's own work

- **M11 = 262 with NINE failing assertions**, the recorded ninth-upstream-move signature, split
  5 / 2 / 2 across `verify_carry_set_applies_to_upstream_head`, `verify_carry_ledger_complete` and
  `verify_carry_exposure_measured`. The COUNT is the signature and it is unchanged. Not repaired;
  `carry/` left at HEAD.
- **M28 = 353 with ONE failing assertion AND IT IS L0'S.**
  `verify_npm_pack_no_optional_native` pins the tracked `package.json` list EXACTLY and got
  `… probe-mt replay spike`. `replay/package.json` is a fifth tree. The count is unchanged, which is
  what says it is a pinned list and not a structure. Recorded and deliberately NOT fixed.

### Nothing else moved

`verify_provenance_complete` **68**, `verify_pinned_nightly_single_source` **28**,
`verify_no_pipeline_predicates` **69**, `verify_named_checks_exist` **9**,
`verify_reuse_inventory_complete` **19**, `just check-repo-hygiene` **28**, `check-drift` **22**
(read inside M1's `verify_vendor_drift_clean`), M27 **345**, M32 **234**.

### A sweep is a writer

`carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` / `ec959b84…` before, came out
`79f597b2…` / `3836c2b6…` — the same two post-sweep digests every run since M30 has recorded — and
were restored from HEAD, confirmed by `sha256sum -c`, all four OK.

### The one deferred edit, made after the sweep and re-verified

M33's Outstanding tasks entry *"a wallet-demo page in M34's arms would run the handshake there too"*
is closed, in the milestone file, which `verify_fallback_triggers_recorded_and_evaluated` reads.
**m16 re-run after the edit: 223, 2/2, exit 0** — its reference value to the assertion.

### The post-sweep edits, named, and why they cannot move the total

Three documents were written AFTER the sweep, because they carry the sweep's own numbers and could
not have been written before it: `CAMPAIGN-BRIEF.md`'s sweep paragraph, this log's Step 10, and the
milestone section's sweep and rebase blocks. **Neither file is opened by any check.**
`CAMPAIGN-BRIEF.md` appears in `verification/` only inside error-message strings, never as a path a
check reads — grepped. The milestone file IS read, by
`verify_fallback_triggers_recorded_and_evaluated`, so **m16 was re-run after each of the two edits to
it: 223, 2/2, exit 0 both times** — its reference value to the assertion.

## Final state

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `410d76c` (== `origin/dev`) | 15 modified, 18 untracked, **no commit** |
| `codetracer-specs` | `latest` | `fb9512a9` | `Planned-Work/Aztec-AVM-Runtime.milestones.org` modified, **no commit** |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | its one pre-existing edit, **untouched** |

No commits, no pushes. `carry/` at its pre-sweep digests, all four OK.
