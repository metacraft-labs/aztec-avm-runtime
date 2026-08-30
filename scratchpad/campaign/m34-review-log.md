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
