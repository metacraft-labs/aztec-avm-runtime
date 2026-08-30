# M34 — The CodeTracer Dev Wallet (public entrypoints) — REVIEW log

Written as I go. Adversarial: every claim is re-taken, not read.

## Step 0 — coordination and inherited state

`git fetch origin` taken first. **`HEAD == origin/dev == 410d76c`, zero ahead, zero behind** — the
seven L1 commits M34's log describes were already fast-forwarded into this checkout by M34's own
rebase, and `origin/dev` has not moved since. **No rebase was needed.**

No sweep was running: `ps -eo pid,etime,cmd | grep -Ei 'verify-m|verify-l|sweep'` shows only three
stale `tail -f` processes from earlier reviews' logs (etime 1–5 days) and no `verify-m*`,
`verify-l*` or `just` process.

M34's work is **uncommitted**: 15 modified tracked files, 18 untracked. That is the campaign's
convention (implementation agents never commit).

---

## Step 1 — THE CENTRAL OBLIGATION: reproduced, in Chromium, from a fresh run

`M34_ARMS_REFRESH=1 just verify-m34` in this repository's own dev shell (node v24.19.0), arms
**re-measured from scratch** (the refresh flag forces a stale verdict per check, so the seven-arm
browser run was taken **four times**, once per check, and every check agreed).

```
e2e_wallet_public_transfer:           83 assertion(s), 0 failure(s)
test_wallet_keys_deterministic:       49 assertion(s), 0 failure(s)
test_deployment_through_wallet:       33 assertion(s), 0 failure(s)
verify_wallet_decisions_appear_in_trace: 45 assertion(s), 0 failure(s)
                                      = 210, 4/4, exit 0
```

**83 / 49 / 33 / 45 = 210, the declared split to the assertion.**

Out of *my* arm report, not M34's:

| figure | measured |
|---|---|
| Chromium | 150.0.7871.128 Arch Linux |
| outcome / block / `ProcessedTx.revertCode` | `processed` / 1 / 0 |
| executed AVM steps / `instructionsExecuted` | 516 / 516 |
| AVM contexts | 2 |
| wallet decisions | 13 |
| requests containing `barretenberg` | `[]`, with `["/assets/avm.wasm"]` in the same log |
| container | 196,608 bytes, 389 positioned / 127 unpositioned, 15 log events |
| declined arm | 0 executed steps, no outcome, no block |

**Is the page genuinely doing the work?** Yes, and it is not close. Every arm is
`page.eval('window.walletDemo.arm…()')` against `wallet-demo.js` served over HTTP to Chromium;
`browser/demo/wallet_main.ts` opens `avm.wasm` from `./assets/avm.wasm` **in the page**
(the network log shows the fetch), creates the wallet in the page, runs the `MessageChannel` +
AES-GCM session in the page, derives the keys in the page, builds the transaction with M26's
vendored builder in the page, executes the AVM in the page and writes the `.ct` with
`ct_writer.wasm` in the page. The container is written by **Chromium's own download machinery**
and read back off disk. Nothing is resolved in Node and reported by the page: the Node process
only opens pages, evaluates one expression per arm, and reads a downloaded file.

**Is the 516 agreement by construction?** Partly not the way the claim implies — see Step 2.

---

## Step 2 — the 516 agreement: TRUE on both sides, ASSERTED on neither

Re-derived independently, out of M27's own arm report (`~/.cache/aztec-m27-browser/browser.json`),
which is the direct-path measurement `SOURCE-MAPPING.md` §6 states and M29's
`test_browser_steps_are_executed_not_mapped` re-derives row by row:

```
arms.publicOnly.transfer.executed.instructionsExecuted = 516
arms.download.recording.executedSteps                  = 516
arms.download.recording.stepsPositioned                = 389
arms.download.recording.stepsUnpositioned              = 127
arms.download.recording.contexts                       = 2
```

and out of MY M34 arm run: **516 / 389 / 127 / 2**. So the agreement is real, and it is **not
agreement by construction**: the wallet route builds its calldata through the vendored builder's
*no-`fnName`* branch with `args: [derivedSelector.toField(), ...call.args]` after re-deriving the
selector from the artifact IT registered, while `runTokenTransfer` uses the `fnName` branch and lets
the builder derive and prepend. Two different entries into one builder, one identical program.

**But nothing asserts it.** `e2e_wallet_public_transfer` §3 asserts only floors (`>= 100` steps,
`>= 2` contexts) and the drained/statistic identity. §8 re-derives `DEV-WALLET.md`'s **516** from the
arm — the LEFT side. The RIGHT side ("M27's and M29's direct-path figure to the step") is prose in
§4 that nothing re-derives, in a document whose own header sentence is that every figure is
re-derived. And the `shortcut` arm runs the direct path **in the same browser run**, so the
right-hand number is available for the cost of two report fields and is not reported.

*This is the milestone's own headline datum sitting in the "a figure nobody re-derives rots" family.*

---

## Step 3 — the mutation matrix, all NINE arms re-taken

`M34_MUT_WORK=~/.cache/m34rev-mut scratchpad/campaign/m34-mutations.sh` — every arm run by me, in
this dev shell, with the bundle rebuilt per arm and the seven browser arms re-measured per arm.
Tree verified restored afterwards (`diff` against the harness's own backup: all four SAME).

| arm | declared | **re-taken** | the failures, read |
|---|---|---|---|
| M1 | 79 / 4 | **83 / 3** | `RESOLVED` for all six refused methods; the over-the-wire refusal is a `ZodError` not a `DevWalletRefused`; **and the declared fourth did not recur** — §8's packaging figures were green, so the "byte cost" failure M34 declared NOT-coverage is not even reliably present |
| M2 | 45 / 5 | **45 / 5** | as declared |
| M3 | 49 / 5 | **49 / 5** | as declared; the structural half stays green, which is the arm's point |
| M4 | 45 / 23 | **45 / 23** | as declared |
| M5 | §1 `registered=1` | **33 / 1** | exactly that assertion; the rewrite is the right shape |
| M6 | 33 / 1 | **33 / 1** | the labelled-write floor |
| M7 | 0 / 1 + summary | **0 / 1 + summary** | `WalletHandshakeTimeout: 'wallet-ready' did not complete within 15000 ms` — bounded and named, kept report, trap prints the summary |
| M8 | 2 / 2, `M8 held` | **2 / 2, `M8 held`** | `m34_absent` names all four absent fields in ONE assertion and dies |
| M9 | §8 names figure and row | **81 / 2** | `steps expected 516 in: \| executed AVM steps \| **515** \|` — the figure AND the row, plus the perturbation control's own `die` |

**The declared assertion counts in the impl log's matrix table are the PRE-Step-9 ones** (79, where
`e2e_wallet_public_transfer` is 83). The arms are right; the table was not re-taken after Step 9
added four assertions.

---

## Step 4 — claims re-taken one at a time

**Claim 5 — `BaseWallet` NOT subclassed. HOLDS, in every part.** Re-derived, not read:

```
_m34_closure.py <anchor> basewallet
  FILES 656   LINES 79060   WS_PKGS 15   UNCLASSIFIED 0
  REACHES @aztec/pxe        REACHES @aztec/simulator
  PXE_EDGE base_wallet.ts -> @aztec/pxe/client/lazy
  PXE_EDGE utils.ts       -> @aztec/pxe/client/lazy
  PXE_EDGE utils.ts       -> @aztec/pxe/simulator
```

and out of the anchor's object store directly: `base_wallet.ts` is **666** lines,
`import { inspect } from 'util'` at line 64, `protected constructor(protected readonly pxe: PXE,
protected readonly aztecNode: AztecNode, …)` at 124, `abstract getAccounts()` at 156,
`registerContractClass` is `return this.pxe.registerContractClass(artifact)` at 395–396,
`registerSender` is one `this.pxe.registerTaggingSecretSource(…)`, `getChainInfo` is two lines,
`getContractMetadata` is `this.pxe.getContractInstance` and then `aztecNode` calls throughout.
**A deviation from the plan justified by measurement, and the measurement is right.**

**Claim 6 — anchor versus pin. HOLDS, in every part.** At the anchor
`WalletSchema.registerContract` is `output: z.void()`; at the pin it is
`ContractInstanceWithAddressSchema`, which is literally
`ContractInstanceSchema.and(z.object({ address: schemas.AztecAddress }))` — a zod **intersection**.
`FunctionCall` at the anchor is `returnType?: AbiType` with a transform accepting `returnTypes`
optional; at the pin `returnTypes: z.array(AbiTypeSchema)`, required. And re-run over all sixteen
methods, `getSchemaReturnType(WalletSchema[k]).parseAsync(undefined)`:
**`registerContractClass` is the only one that accepts `undefined`** — so upstream's own
`worker_wallet.test.ts` (22 lines, read at the anchor) does test a property that holds for one of
the two methods it names.

**Claim 3 — `registerContract` behind the seam. HOLDS.** Five `[DEV SHORTCUT]` labels in
`wallet_main.ts`, all five inside `say(…)` calls and none in a comment; zero in `dev_wallet.ts`.
The two routes' class id and address are compared and equal, over two real `0x`-64-hex values.

**Claim 2 — the refusal is named. HOLDS.** `DevWalletAuthorizationDeclined` naming the account and
the reason, `declined` in the ledger, no outcome, no block, **0** executed steps.

**Claim 7 — the `reduce512BufferToFr` sentence. THE MEASUREMENT HOLDS; THE CORRECTION DID NOT.**
See Step 5.

**Claim 8 — M33 245 → 246.** `verify_provider_half_dd9_clean` re-run: **106 assertions**, and the
+1 is the `assert_ge … 500000` non-emptiness on the eager-set read. The scan is over
`EAGER-KEY` — the whole eager set — not `wallet.js`. Confirmed correct.

---

## Step 5 — THE CLAIMS THAT DID NOT SURVIVE, and what was done about each

### 5.1 The `reduce512BufferToFr` correction was never made where the sentence lives

**The measurement holds; the repair did not happen.** `git grep reduce512BufferToFr` at the `cpp`
anchor **repository-wide** (not only `yarn-project/`, which is what M34 measured) returns the two
declarations — `foundation/src/crypto/grumpkin/index.ts:83` and `.../secp256k1/index.ts:55` — and
**no call site**; the same is true of all four installed `@aztec/foundation` trees at the published
pin. `deriveKeys` reaches `sha512ToGrumpkinScalar` instead, which is `hash.js`.

But `browser/src/foundation_grumpkin.ts` was **`git status` clean**, and still carried the false
sentence in **three** places:

* the file header — *"it has exactly one caller in this graph: `deriveKeys`"*;
* the method's doc comment — *"Its one caller in this graph is `deriveKeys`"*;
* **the string the `Promise.reject` carries** — *"Its only caller here is deriveKeys"* — which is
  the copy an engineer who reaches the throw actually reads.

M34 wrote the correction into `dev_keys.ts` and `REUSE-INVENTORY.md` instead, giving as its reason
that *"it is the sentence that would stop somebody trying this route"* — which is exactly why the
place it is written matters. **Corrected at the source, all three.** Recorded in
`CAMPAIGN-BRIEF.md` as a family: *a correction filed in a neighbouring file is not a correction, and
check whether the sentence is also in a message the program emits.*

### 5.2 The collision detector's control could not fail — the 38th instance

`test_wallet_keys_deterministic` §5 asserts the two derived domain separators collide with no member
of upstream's `DomainSeparator`, and pairs it with a control whose own comment names the defect it
then commits. The control was a **second, three-line script**:

```python
ups = json.loads(sys.argv[1]); planted = ups[0]
print('COLLIDES' if planted in set(ups) else 'NO_COLLISION')
```

`ups[0] in set(ups)` over a list the `assert_ge … 30` two lines above has already asserted
non-empty. It never runs the detector, which is a different script taking `sys.argv[2:4]` and doing
`int(s) in ups`. **Measured**: it prints `COLLIDES` unconditionally.

Fixed to one `_m34_collision` function used for the subject and the control alike, called with an
upstream member substituted for one separator, required to **name the value back**. Demonstrated by
mutating the detector to `hits = []`:

```
FAIL …and the detector CAN say otherwise, naming the value it found
     expected [COLLIDES: 116501019], got [NO_COLLISION]
test_wallet_keys_deterministic: 50 assertion(s), 1 failure(s)
```

The old control was green under that same mutation. `CAMPAIGN-BRIEF.md`'s running total moved
37 → **38**. The substantive claim survives: real separators `NO_COLLISION`, planted member
`COLLIDES: 116501019`.

### 5.3 The 516 identity was prose; it is an assertion now

See Step 2. `browser/demo/wallet_main.ts`'s `shortcut` arm now reports `executedSteps` and
`contexts` from its own runtime, and `test_deployment_through_wallet` §5b asserts the identity with
a `>= 100` floor beside it and the declining arm's `0` as the control that the comparison separates.
Demonstrated: doctoring `shortcut.executedSteps` to 515 gives

```
FAIL the wallet route executes the direct route's program, to the step  expected [515], got [516]
```

### 5.4 `WORKER-NODE.md` §5's `wallet-demo.js` row was outside every instrument, and had rotted

`test_worker_transferable_container_not_copied` §10 re-derives that table from `chunks.json` for a
**typed list of six entries**. M34 added a seventh ROW and not a seventh entry, so the row was
re-derived by nothing — and it stated **309.51 KB** where M34's own final build reported
**309.91**. Every other row was right, which is why nobody looked. `wallet-demo.js` is in the loop
now (+3 assertions, M32 234 → **237**) and the row carries the measured value.

### 5.5 `REUSE-INVENTORY.md` RI-96 states 45 poseidon2 calls; the artefact says 54

Re-measured twice on a clean tree (`transfer.report.poseidonCallsTotal`): **54**, with
`grumpkinCallsTotal` 14 and the barretenberg count 0. Nothing re-derives the poseidon figure — the
zero is the one a check reads. RI-96 corrected, with the reason recorded.

### 5.6 `dev_keys.ts` claimed a mechanism that does not exist

Its header said the no-randomness property is asserted *"over the BUILT bundle's own module
graph"*. §4 scans **two source files**. The check's own §4 heading said "REACHABLE FROM THE WALLET'S
KEY PATH", which is not what a two-file scan measures either. Both corrected to state the
measurement; the reachability question is answered by the behavioural half (Chromium and two Node
processes agreeing over the built bundle), which is where it belongs.

### 5.7 §8's perturbation control hard-coded `**516**`

The control that proves `_m34_doc_figures.py` can report a wrong figure substituted the literal
`'| executed AVM steps | **516** |'` — a constant typed into a check, over a figure the same check
re-derives. The day the artifact legitimately moves and the document is correctly updated, the
needle stops matching and the `die` fires: a check that should be green reports
`81 assertion(s), 2 failure(s)`. **M34's own M9 arm produces exactly that shape.** The row is found
by its SUBJECT now and the replacement is `<what the ARM measured> + 1`, so the perturbed document
is wrong whatever the row said — an increment of the row's own value would "repair" a document that
is already off by one, which is the state M9 creates.

### 5.8 `test_deployment_through_wallet` §5's comparator control compared unlike things

*"the same comparison distinguishes the two runs' transactions"* compared a **transaction hash**
with a **contract address**. Two different kinds: it could only have failed if both read `MISSING`,
which makes it a degeneracy guard wearing a comparator's label. Replaced by a comparison of two real
`0x`-64-hex values of the same kind from the same arm (the class id and the address, both already
asserted well-formed and required to differ), with the degeneracy guard kept and named as one.

### 5.9 Two citations that point at nothing

`_m34_closure.py`'s docstring said its figures are re-derived by `test_wallet_keys_deterministic`
§2; they are re-derived by `e2e_wallet_public_transfer` §8. `dev_keys.ts` said the separator is
recomputed by §3; it is §5. Both corrected.

### 5.10 The impl log's mutation table quotes pre-Step-9 counts

`e2e_wallet_public_transfer` is 83 and the table says 79 in three rows. Not a defect in the work;
recorded because the next reader would compare the wrong numbers.

---

## Step 6 — the two declarations the brief singled out

**M5's rewrite.** The first version skipped the host call, the class never reached the module, the
arm run exited 1 and the check died at `m34_require_arms` with `0 assertion(s), 1 failure(s)` — not
one assertion of §1 ran. The rewrite lies only in the RECORD (`registered=${registered}` becomes the
literal `registered=0`) and re-taken by me it is **33 / 1**, the single failure being
`…and the node's resident store accepted exactly one new class`, which is §1's `registered=1` — the
assertion the arm was written for and nothing else. The rewrite is the right shape, and it is the
more dangerous of the two defects: a ledger that reports work nobody did.

**`still_there` exits 5.** Extracted verbatim into a sandbox and run both ways:

```
present case:  continued, rc=0
absent case:   !! MX DID NOT HOLD: the mutation is no longer in subject.txt.
               An arm whose mutation was undone must FAIL, not print a result beside a diagnosis.
               restore_all called / verify_restored called
EXIT=5
```

It restores and verifies **before** exiting, and the harness runs `set -uo pipefail` without `-e`,
so the `exit` leaves the whole run rather than the function. Strictly stronger than M33's, which
diagnosed and continued — which is the fifth appearance of that family and the one
`CAMPAIGN-BRIEF.md` asks to be a failure.

**M1's fourth failure.** Declared as the mutation's own byte cost moving two packaging figures and
declared NOT coverage. Re-taken, M1 is **83 / 3** and §8 is entirely green — so the fourth failure
does not even reproduce. The declaration was honest and is, if anything, conservative; the impl
log's `79` in that table is the pre-Step-9 assertion count.

---

## Step 7 — corroboration the milestone did not claim, and one observation left standing

**The bytes DD-11 scans are the bytes the page ran.** `verify_provider_half_dd9_clean` §2 now scans
the WALLET entry's eager set — nine files. Eight of them are shared chunks, and **all eight appear
in the transfer arm's own network log**; the ninth is `wallet.js` itself, the 0.69 KB re-export stub,
which the demo page does not fetch because it imports `entry_wallet.ts` directly and esbuild resolves
that to the same chunks. So the artefact the DD-9/DD-11 absence is measured over and the artefact
Chromium executed are the same bytes, which is a link neither check states and which is the strongest
answer to "did the page really run the reviewed code".

**Corroboration that the wire is a wire.** The over-the-wire refusal comes back with
`name: 'Error'` while the direct one is `name: 'DevWalletRefused'`, with the message preserved —
an error class does not survive serialisation, and a same-process call would have kept it. That is
the encrypted round trip leaving a fingerprint, measured rather than asserted.

**One observation left standing, with its mitigation.** §5's `assert_eq "…the chain has no outcome
for it" "MISSING" "$D_OUTCOME"` cannot distinguish "the field is null" from "the path is misspelled"
— `m34_arm` prints `MISSING` for both, and `m34_absent` cannot guard a field whose expected value
IS `MISSING`. It is not exploitable here because §3 asserts `transfer.report.outcome == processed`
over the same field name in the same report format, so a rename goes red there. Recorded rather than
fixed; a third assertion for a path a neighbouring section already pins is not worth the count.

---

## Step 8 — the decisive probe, queued for after the sweep

M33's review earned its keep with `const _nodeOnlyProbe = setImmediate;` — a Node global read at
module-evaluation time, invisible to a metafile and to a free-identifier scan. The equivalent probe
for M34 is to plant it in `dev_wallet.ts` and confirm the ARM RUN dies in Chromium rather than
reporting seven green arms. Queued rather than run now, because a sweep is a measurement of the tree
at the moment it ran and the tree is under one.

The mutation matrix already answers a weaker form of the same question three times over: M3 changes
`dev_keys.ts`'s derivation and only the Chromium-versus-Node comparison can see it (49/5, structural
half green); M7 removes `handler.start()` and the PAGE times out at the provider's own 15,000 ms
bound; M1 changes `dev_wallet.ts` and the failure arrives as a `ZodError` from upstream's codec on
the far side of the session. All three are browser-observed consequences of editing the reviewed
sources, which is not something a Node-resolved stage could produce.

---

## Step 9 — the counts after the review

| check | delivered | after the review |
|---|---|---|
| `e2e_wallet_public_transfer` | 83 | **83** |
| `test_wallet_keys_deterministic` | 49 | **50** |
| `test_deployment_through_wallet` | 33 | **39** |
| `verify_wallet_decisions_appear_in_trace` | 45 | **45** |
| **M34** | **210** | **217** |

And one other milestone, declared before the sweep ran:
`test_worker_transferable_container_not_copied` 71 → **74**, so **M32 234 → 237**. That is finding
5.4 and nothing else; the other three M32 checks are untouched.

`verify_provider_half_dd9_clean` re-measured at **106** (M33 246), `verify_browser_chunk_budget` at
**33**, `verify_named_checks_exist` **9**, `verify_no_pipeline_predicates` **69**,
`verify_reuse_inventory_complete` **19**, `just check-repo-hygiene` **28**, m16 **223** after the
milestone-file edits.

Expected campaign total: 11,514 + 3 + 7 = **11,524**, and the summariser's reference table names
both moves in advance.

---

## Step 10 — THE SWEEP: M0–M34 at 11,524, delta +0, no hole

Measured 2026-08-30 **after my last commit**, `setsid`-detached in this repository's own dev shell
(node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`, **70 markers for 35 milestones — no hole**, **33 of 35 exit 0**:

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 237  m33 246  m34 217
                                                   CAMPAIGN TOTAL 11,524
```

11,514 + 3 + 7 = **11,524**, `delta +0` against a reference table naming both moves in advance.
**M9 did NOT flake** — 807, rc 0, 1,283 s, immediately after m8's 174 s run.

**The two reds are both known-not-mine.** M11 262 / rc 1 / nine failing assertions, split
5 / 2 / 2 across `verify_carry_set_applies_to_upstream_head`, `verify_carry_ledger_complete` and
`verify_carry_exposure_measured` — the recorded ninth-upstream-move signature, count unchanged,
`carry/` left at HEAD. M28 353 / rc 1 / one failing assertion, and it is L0's:
`the tracked package.json files are the three shipped plus the four harness trees — got
[… probe-mt replay spike]`.

**L0/L1 contribute zero, grepped one name at a time:** `verify_node_client_surface_narrow` 0,
`test_node_client_refusals_distinguishable` 0, `verify_client_uses_upstream_schema` 0,
`e2e_fetch_settled_transaction` 0, `test_missing_contract_artifact_refused` 0,
`test_private_half_declared_absent` 0.

**A sweep is a writer.** `carry/rebase.json` / `carry/exposure.json` checksummed before
(`aaeb6877…` / `ec959b84…`), came out `79f597b2…` / `3836c2b6…`, restored, `sha256sum -c` both OK,
`git status carry/` clean.

---

## Step 11 — THE DECISIVE PROBE, run after the sweep

`const _nodeOnlyProbe = setImmediate;` planted at the top of `browser/src/wallet/dev_wallet.ts`,
bundle rebuilt. **The exact plant that left M33 at 224 assertions, 4/4, exit 0.**

```
NODE:      import('./wallet.js') -> NODE OK, DEV_WALLET_NAME=CodeTracer dev wallet
CHROMIUM:  the wallet demo page did not become ready; page errors:
           ["ReferenceError: setImmediate is not defined
             at http://127.0.0.1:45367/chunks/chunk-PRFCFIS3.js:1:59429"]
           arm run exits 1
           e2e_wallet_public_transfer: 0 assertion(s), 1 failure(s)  (with a summary line)
```

Restored, rebuilt, `git status` clean, and `just verify-m34` re-run: **83 / 50 / 39 / 45 = 217,
4/4, exit 0.**

**VERDICT: the wallet genuinely runs in the browser.** Not "asserted browser-shaped" and not merely
"observed to evaluate" — observed to do the thing, by an instrument shown to notice when it stops.
