# Final-four pass — the last four `pending` entries that are real work in this repository

Started 2026-08-31, immediately after the closeout pass. Baseline: `dev` `e0d45b6`, sweep
**12,534**, `delta +0`, pending 21 -> 13.

The four, in the order the brief gives (tractable first):

1. **M18 `e2e_ts_wasm_amm`**
2. **M25 `test_nested_call_reverted_contributes_no_side_effects`**
3. **M25 `e2e_trace_token_transfer_steppable`**
4. **M21 `test_form_b_tx_matches_pxe_bytes`**

## Step 0 — context read, and the state found

Read in full: `CAMPAIGN-BRIEF.md` (2,788 lines), `scratchpad/campaign/closeout-log.md`,
`scratchpad/campaign/residuals-log.md`, `scratchpad/campaign/m37-review-log.md`, and
`OUT-OF-SCOPE.md`.

State at start, measured:

| repo | branch | HEAD | vs origin | tree |
|---|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `e0d45b6` | 0/0 | clean |
| `codetracer-specs` | `latest` | `1f2cc1ae` | 0/0 | clean |

No `verify-m` / `verify-l` process running (`ps aux` grep: zero matches). Load average 0.60.

---

## ENTRY 1 — M18 `e2e_ts_wasm_amm`

### Step 1.1 — what the entry asked for, and where each piece already was

The entry's residue, re-measured by the closeout pass, named five things. All five compose from
machinery that exists:

| the residue asks for | what supplies it |
|---|---|
| three Token instances plus the AMM | `createContractClassAndInstance` + `registerDirectly` (RI-72 + the closeout pass's own helper) |
| its own `constructor` per contract | `runOneBlock`, four transactions in one block |
| `set_minter` | one more transaction; `is_minter` READ BACK as the discriminator |
| balance seeding | `Token._increase_public_balance`, self-sent per token — upstream's own shape |
| each internal call with `sender` set to the AMM | `TestEnqueuedCall.sender`, which the vendored builder already honours |

The recipe is upstream's `yarn-project/simulator/src/public/fixtures/amm_test.ts` at the `cpp`
anchor, call for call — **except that upstream runs three of the AMM's four `abi_only_self`
entry points and this runs four.** `_swap_tokens_for_exact_tokens` is the fourth.

Upstream's partial-note workaround is kept as one: each `finalize_*_to_private` consumes a
partial-note VALIDITY COMMITMENT the private half would have emitted, computed with upstream's own
`poseidon2HashWithSeparator(…, DomainSeparator.PARTIAL_NOTE_VALIDITY_COMMITMENT)` and inserted
siloed by the emitting token. Eight of them.

### Step 1.2 — it ran first time, and the numbers are the pool's own

Three arms — `amm`, `ammNotSelfSent`, `ammNoMinter` — twelve blocks each, one variable each.

```
poolBefore        0            0            lpSupply 0
addLiquidity      600,000,000  500,000,000  lpSupply 100,000   locked 1,000
swapExactIn       640,000,000  468,837,908
swapExactOut      639,000,000  469,573,822
removeLiquidity   638,361,000  469,104,249  lpSupply 99,900
```

Every one of those is `Token.balance_of_public(amm)` or `Token.total_supply()` static-called in a
LATER block — the contracts' own view functions, never a hand-derived storage slot. The check
asserts them as DELTAS and as the pool's own CONSTANT-PRODUCT INVARIANT, not as constants.
Instruction counts 2,051 / 1,346 / 1,834 / 2,326 against 202 for a view call.

### Step 1.3 — a defect in this pass's own work, found by running

`artifactOnlySelfPublicFunctions` — the scan that makes *"the four this arm drives are all four the
artifact declares"* a measurement rather than a list — came back **EMPTY**, because it read the
LOADED artifact and `loadContractArtifact` does not carry `custom_attributes` through. An empty
list makes "these four are all of them" a comparison of one empty set with another, so the check
asserts the scan found FOUR *before* comparing the sets. Read off the raw JSON now.

### Step 1.4 — the check

`verification/e2e_ts_wasm_amm.sh`, **78 assertions**, wired into `just verify-ts-wasm-amm` and into
`verify-m18` (the brief's rule that a milestone which declares a check must run it).

Eight parts: the arms' provenance; four contracts with four distinct addresses and four distinct
contract-address nullifiers; the artifact's own `abi_only_self` scan; all four entry points
executing with four distinct instruction counts; the pool's state as deltas and as its
constant-product invariant; the eight partial notes; and the two controls.

### Step 1.5 — the mutation matrix: six arms, every one killed what it was written for

| arm | mutation | result | what went red |
|---|---|---|---|
| A1 | the foreign-sender control is self-sent after all | 78 / **8** | the `selfSender == user` identity, all four "with a foreign sender X reverts", the payload non-emptiness, the four-distinct-payloads count, and the control's empty pool |
| A2 | the no-minter control grants the minter anyway | 78 / **3** | `is_minter` reading 0, the control's revert, and its zero liquidity supply |
| A3 | the exact-out note siloed under the wrong token | 78 / **3** | exactly the FOURTH entry point: its revert code and its two exact-out deltas. The other three entry points stayed green |
| A4 | the `abi_only_self` scan drops its own predicate | 78 / **2** | exactly the two Part-2 assertions — the scan's size (4 -> 6) and the set equality |

**One prediction did not hold and it is recorded rather than quietly dropped.** A3's header
predicted the exact-out INVARIANT assertion would fall with the deltas. It did not, and the reason
is right: with the swap reverted the reserves do not move, so `b0*b1 >= b0*b1` is satisfied by
equality. An invariant is a `>=` and a reverted swap is the boundary case. The three that fired are
the ones that name the exact-out swap by name.

---

## ENTRY 2 — M25 `test_nested_call_reverted_contributes_no_side_effects`

### Step 2.1 — the corpus gap is real, and the remedy is a contract

The closeout pass proved by enumeration that the pinned corpus cannot express this entry: of
`AvmTest`'s 127 functions exactly TWO recover from a failed nested call and neither nested target
makes a side effect. **Re-derived here** (`§6` of the check), anchored to a DEFINITION
(`fn <name>(`) rather than a mention — because `AvmTest`'s source carries a commented-out call to
one of the two at line 1010, which a naive grep counts.

So the contract is authored: `fixtures/transpiler-contracts/nested_effects/`, compiled by the
nargo M31 builds from the anchor's own `noir` submodule and transpiled to AVM bytecode by the
module M31 runs **in Chromium**. That is the intended use of M30 and M31.

### Step 2.2 — three defects in this pass's own work, each found by running

1. **Oracle declarations inside a `contract {}` block are ENTRY POINTS.** `[Field; N]` is "Invalid
   entry point type" and `-> Field` is "missing pub keyword on return type" — five errors before
   the file compiled. `aztec-nr` puts the same declarations in `aztec/src/oracle/avm.nr` for that
   reason; the fixture's `src/avm_ops.nr` is that file cut down to six opcodes, and it is the only
   reason the fixture is multi-file.

2. **THE INSTRUCTION-COUNT CONTROL WAS THE WRONG SHAPE, AND ONLY RUNNING IT SAID SO.** The control
   for *"the effects were MADE and then discarded"* is a callee that halts BEFORE its side effects.
   The first draft put it in its own mode (6) called by its own outer (7). Measured: the
   early-reverting outer executed **139** instructions against the late-reverting one's **89** —
   MORE, not fewer, because a later branch of an `if`/`else if` chain costs more dispatch
   comparisons to reach, and that difference swamped the two opcodes the control exists to count.
   It is an ARGUMENT now, decided inside ONE branch of ONE callee reached by ONE outer, so both arms
   take the identical dispatch path. Re-measured: **94 against 89**, and the check asserts the two
   arms' state read-backs are IDENTICAL so the count is the only discriminator.

3. **A STALENESS PREDICATE THAT DID NOT WATCH ITS OWN PRODUCER — a live gap, pre-existing.**
   `m31_arms_newer_inputs` watched the page, four tools and the build outputs and **not
   `orchestration/src`** — while `arms.execute` has imported `transpiled_contract_driver.ts` since
   M31. Measured: a field added to the nested-effect driver was still absent from the report after
   a full check run. The symptom was the mild one only because M29's `m31_absent` sits in front of
   every comparison and refused; a CHANGED field would have read as the old measurement. Closed.

### Step 2.3 — what the arms measure

| | subject (`revertsAfterEffects`) | control (`succeeds`) | control (`revertsBeforeEffects`) |
|---|---|---|---|
| outer transaction | rc **0** | rc 0 | rc 0 |
| the outer frame's own reading of the call | **failed** | succeeded | failed |
| outer slot | 4242 | 4242 | 4242 |
| **inner slot** | **0** | **5151** | **0** |
| `TxEffect.nullifiers` | 2 — outer's present, **inner's absent** | **3** — both present | 2 |
| re-emit the inner nullifier | **succeeds** (still free) | **reverts** (landed) | succeeds |
| re-emit the outer nullifier | reverts | reverts | reverts |
| instructions | **94** | 135 | **89** |

Three independent witnesses — what the transaction RECORDED, what the tree HOLDS, what the tree
ANSWERS — each falsifiable in both directions by the succeeding arm, plus the instruction-count
control that separates *"no side effects"* from *"no side effects were ever made"*.

### Step 2.4 — one other milestone's check moved, and it is the brief's own rule

`verify_transpiler_rung1_mapping_survives` pinned *"exactly two of the corpus's AVM functions carry
a compiled procedure, and they are branches' and reverting's"* — as a `case` arm naming two
fixtures and, six lines below, the literal `2`, with nothing keeping the two in step. The new
fixture is a THIRD carrier: its `assert` compiles to the same procedure at Brillig index 11,
`{"0":{"11":[129,131]}}`. Repaired the way the brief asks — ONE declaration, used at both sites,
with the count derived from it and a floor so the pair cannot both be satisfied by an empty corpus.

`test_nested_call_reverted_contributes_no_side_effects`: **83 assertions, 0 failures.**

### Step 2.5 — the mutation matrix for entry 2, and one arm that had to be re-aimed

| arm | mutation | result | what went red |
|---|---|---|---|
| B1 (first form) | `CALLEE_FOR.succeeds` flipped in the DRIVER | 83 / **1** | **a finding, not a result** — see below |
| B1 (re-aimed) | the positive control runs the SUBJECT's outer function | 89 / **7** | the callee-vs-contract derivation, the control's verdict, its inner-slot value, its nullifier membership, its list-length identity, its `reEmitInner` revert, and the succeeding-arm step ordering |
| B2 | the early-revert control forwards the subject's argument | 89 / **3** | exactly §2's "differ only in the argument" and §5's two count comparisons. Every state assertion stayed green, which is the point of that section |
| B3 | the nested callee stops reverting, **in the CONTRACT** (recompiled by nargo, re-transpiled in Chromium) | 83 / **6** | all three witnesses at once |
| B4 | the transaction's own nullifier list reported empty | 83 / **5** | exactly §4b. §4a and §4c green — the three witnesses are independent |
| B5 | the arms run HANGS (bound cut to 90 s) | **0 / 1** | the bound, named, summary at column 0 |

**B1's first form is the finding.** It flipped `CALLEE_FOR.succeeds`, which is a **reported** field:
the callee is compiled into the outer mode's own `call_opcode` argument and the driver cannot change
it. Exactly ONE assertion moved — the check's comparison of two of the driver's own fields — and
every behavioural assertion stayed green over a run nothing had changed. That is *"a producer's
report about itself is not its output"* arriving through a mutation arm. The check now DERIVES the
outer→callee mapping from the contract's own source, with the comment stripper's two halves
asserted, and compares it against the declaration; the re-aimed arm changes the OUTER mode, which
is what the calldata carries. `test_nested_call_reverted_contributes_no_side_effects` 83 → **89**.

*(`--demo-still-there` exits 5 as designed, and every arm's restore was verified against the
sha256 manifest. B5's rc is 137 rather than 124 because `m31_bounded` uses `timeout -s KILL`, and
the library tests for both.)*

---

## ENTRY 4 — M21 `test_form_b_tx_matches_pxe_bytes`

### Step 4.1 — the brief said "do not invent a PXE". The answer was to install the real one.

The entry's recorded blocker had two parts, and the closeout pass re-derived both:

1. `generateSimulatedProvingResult` — step 2 of §5.4's pipeline — "appears in this tree at FIVE
   sites and every one of them is a COMMENT";
2. "there is still no PXE-built Tx fixture to compare against".

**(1) is true and stays true.** This runtime does not have step 2 and does not vendor it; §6 of the
check asserts that over the shipped sources, with the scanner shown to be capable of finding the
name.

**(2) was a statement about what nobody had built.** Measured today rather than argued:

| question | answer |
|---|---|
| is `@aztec/pxe` published at `npm.deletion_era`? | yes, `5.0.0-nightly.20260626` |
| is `generateSimulatedProvingResult` EXPORTED? | yes — `@aztec/pxe/simulator` |
| does it run without a world state? | yes: pure TypeScript, 404 packages, 39 s to install |
| does it consult the `AztecNode` it takes? | **no**, for this input — the stub THROWS and is never called |
| does it produce a real tail? | 38,557–82,722 bytes of `PrivateKernelTailCircuitPublicInputs` |

So the entry closes **as written**, against upstream's own PXE, and RI-64/RI-65's rejection of
`@aztec/pxe` for the SHIPPED graph is untouched — it is installed in `pxe-ref/`, a fifth harness
tree nothing ships, on exactly the terms `diffsim/`, `spike/`, `drift/` and `probe-mt/` are. RI-102
records the distinction those entries did not draw: *a package this runtime must not SHIP is not a
package a CHECK may not RUN.*

### Step 4.2 — what crosses, and in which direction

Two processes, two `@aztec/stdlib` installs — so the INPUTS cross as VALUES (a first nullifier and
a list of calldata fields, from which each half builds its own `PrivateExecutionResult` with its own
install's classes) and the TAIL and the OUTPUTS cross as BYTES.

Three cases. `Tx.toBuffer()` agrees to the digest, to the byte count and to the transaction hash in
all three.

### Step 4.3 — and the equality is made falsifiable four ways

Both halves call the same upstream `toSimulatedTx`, so "the bytes agree" would otherwise be a
tautology written beside a true statement:

* the comparer CAN say no — our transaction from the OTHER case's tail differs from PXE's primary,
  and EQUALS PXE's variant, so it is not merely different;
* the tail matters — PXE's two cases' tails differ, and neither is the empty tail;
* the calldata matters — our transaction with the calldata dropped differs from PXE's primary **and
  from PXE's no-calldata case**, because a `Tx` is decided by its tail as well as its calldata;
* the node was not consulted, with the same stub shown to count when it is.

**One of those four went red on its first run and the red was mine.** The first draft asserted that
the dropped-calldata transaction EQUALS PXE's no-calldata case. It does not: PXE's no-calldata case
was built from an execution with no calldata, so its TAIL is a different tail. Corrected to the
measurement, with the tails asserted different so the statement rests on something.

`test_form_b_tx_matches_pxe_bytes`: **78 assertions, 0 failures.** m21 369 -> 449 (+78, plus +2 in
`verify_transcript_truncation_detection_uniform`, below).

### Step 4.4 — three other checks moved, and one deliberately stayed red

* **`verify_transcript_truncation_detection_uniform` caught the new check on its first run**, at
  the assertion that exists for it: the probe drives a transcript with a `formB.done` sentinel and
  did not call the shared refusal, so the population went 32 -> 33 and the NOT-REACHING set 20 ->
  21. It calls `require_complete_transcript` now, so the reaching set goes 12 -> 13 and the backlog
  is unchanged — which is the split that says a new member did not join it. 55 -> 57.
* **`verify_pinned_nightly_single_source` is unchanged at 28**, with `pxe-ref` declared in
  `pins.json`'s `npm_consumers` at `deletion_era`. Its sandbox went red first, for the right reason:
  the sandbox stages TRACKED files and `pxe-ref/` was not yet added.
* **`verify_npm_pack_no_optional_native` 54 -> 55**, one assertion for the fifth harness tree — and
  **its declared list deliberately omits `replay`**. That is L0's tree and this check has been red
  on it since M33; adding it in the same edit would have turned another track's standing red green
  as a side effect of this pass's work. The pin names what this campaign owns, and the one failure
  it reports now names `replay` alone.

### Step 4.5 — the mutation matrix for entry 4: four arms, four precise kills

| arm | mutation | result | what went red |
|---|---|---|---|
| D1 | this runtime's seam drops the public calldata (`publicOnlyPrivateExecution` ignores its third parameter) | 78 / **8** | the two calldata-carrying cases' byte-identity, byte count and calldata count, plus the two derived controls. **The `noCalldata` case stayed green**, which is what says the failure is about the calldata |
| D2 | the node stub stops counting | 78 / **1** | exactly the paired positive. The `threw:` assertion beside it survives, so the pair is two facts |
| D3 | the reference stops running PXE's step 2 (the tail becomes the EMPTY tail) | 78 / **6** | §2 entirely, and the two derived controls. **The byte-identity assertions SURVIVED** — which is the finding the arm was written for: two producers agreeing about a degenerate input is not the claim, and §2 is what makes the input non-degenerate |
| D4 | the reference producer HANGS (bound cut to 20 s) | **13 / 1**, **rc 124** | the bound, named, summary at column 0 |

---

## ENTRY 3 — M25 `e2e_trace_token_transfer_steppable`

### Step 3.1 — the two pieces, and which one needed a source change

The entry names exactly two missing pieces. **One needed no change at all.**

**Piece 1 — per-step `l2Gas`/`daGas` in the TOKEN container.** Measured: they are already written.
`ct-print --full` over the container the browser downloaded interns five variable names —
`contractAddress`, `opcode`, `contextId`, `l2Gas`, `daGas` — and emits 2,582 `Value` events for 516
`Step` records. So the piece was a READING nobody had taken, and it is taken through the pinned
reader rather than off the arm's report, which is M29's *"a producer's report about itself is not
its output"* applied to gas.

**Piece 2 — the sender's balance leaf, on that transfer's own world state.** That needed the page's
own driver to read it. `readPublicDataLeaf` is M34's and already exists; the change is a leaf read
before and after, for BOTH ends of the transfer, and a report field.

### Step 3.2 — the bundle moved, and the blast radius was measured rather than feared

Baseline captured, source changed, rebuilt, diffed:

| entry point | before | after |
|---|---|---|
| `browser.js` (the DD-5 reference) | 265.79 KB | **265.79 KB — unchanged** |
| `testing.js` | 291.08 KB | 291.18 KB |
| `demo.js` | 292.30 KB | 292.39 KB |
| `node/node.js` | 225.48 KB | **unchanged** |
| `worker.js` / `worker-demo.js` / `wallet-demo.js` | | +0.09–0.10 KB each |
| `wallet.js` | 304.30 KB | **unchanged** |
| total | 8,230.68 KB | 8,230.78 KB |

`verify_browser_chunk_budget` re-derives every one of those from the
build's own report, so it named the three `BROWSER-PACKAGING.md` figures that had rotted and nothing
else. Corrected to the CHECK's value, which is this campaign's settled rule for the rounding family.
**m27 345/0 after, unchanged in count.**

### Step 3.3 — one defect in this pass's own work, found before it shipped

`m27_arm` prints `MISSING` for a JSON `null` — the same word it prints for a field that is not in
the report at all. So a balance leaf that is genuinely absent from the tree would have been
indistinguishable from a driver that forgot to report it: *"two missing keys agreeing"*. The driver
maps an absent leaf to `EMPTY`, a value the tree can produce and the reporter cannot, and the check
asserts the recipient's leaf is `EMPTY` before and a number after.

### Step 3.4 — what the check measures

`e2e_trace_token_transfer_steppable`, **53 assertions, 0 failures**, first run.

```
l2Gas 540,027 → 627,352 over 516 steps      daGas 96 → 224
contexts 1:314, 2:202                        sender leaf 1000 → 995, receiver leaf EMPTY → 5
```

* **gas**: strictly increasing l2Gas (0 non-positive deltas, so 516 distinct readings), 15 distinct
  per-step costs with the dearest more than ten times the cheapest — an opcode table rather than a
  counter; daGas non-decreasing, moving, and ZERO for most steps, which is the opposite shape and
  is why it is asserted separately.
* **the differential across the writer**: all 516 container steps compared field by field against
  the records the page DRAINED out of the module — 0 mismatches — with the same comparer shown to
  report disagreements when the pairing is shifted by one.
* **the balance leaves**: the sender's holds the seeded amount before and seeded-minus-transferred
  after; the receiver's is `EMPTY` before and exactly the transferred amount after; and the two
  together still hold what was seeded, which is the conservation law neither reading gives alone.
* **the parser can come back empty**: a 512-byte stub is refused by the reader and the parser then
  reports zero steps, so the 516 is a measurement.

### Step 3.5 — the mutation matrix for entry 3, and it found a defect in the check itself

| arm | mutation | result | what went red |
|---|---|---|---|
| C1 | **the container's `l2Gas` is fabricated at the WRITE site** (`ct_download.ts`) | 56 / **7** | every §2 assertion about the l2Gas sequence — strictly increasing, distinct per step, several distinct costs, the dearest above the cheapest — AND §3's differential at 516 mismatches. The drained records are untouched, so a check that read the gas out of the arm's report would have stayed green: this is M29's exact shape and this is the arm for it |
| C2 | the balance read-back is taken before the block | 56 / **5** | the three after-assertions and "the receiver's leaf came into existence". The BEFORE assertions stay green |
| C3 | the recipient's leaf is derived for the SENDER | 56 / **4** | "the receiver's is a different leaf", its `EMPTY`-before, its after value and the conservation sum |
| C4 | the parser's variable-id mapping is off by one | 56 / **23** | the VARIDS assertion by name, the completeness census, and everything downstream of a gas value that is no longer an integer |

**And the first run of C2 and C4 found a defect in the check rather than in the subject.**
`lib.sh` runs with `set -u`, and bash's `$(( ))` treats a bare word as a VARIABLE — so
`$(( 1000 + EMPTY ))` over a balance leaf the tree does not hold is an unbound-variable error that
**kills the check**. C2 reported `46 assertion(s), 4 failure(s)` where the check has 53: a
seven-assertion shrink, visible only because M22's abnormal-exit trap prints a summary at all. That
is the silent-shrink family arriving through an arithmetic expansion. Every site that does
arithmetic over a value the subject produced goes through a numeric guard now, and each asserts
numericness first — 53 → **56**, and C2 and C4 re-run at the full count.

**And the first C run had a second finding, in the harness rather than in the check.** All four arms
came back `0 assertion(s), 1 failure(s)`: the harness exports `AVM_WASM_PATH` pointing at M15's
module, which has no `avm_poseidon2_*` or `avm_grumpkin_*` exports, and M27's checks refuse it BY
NAME. The die-before-summary path worked perfectly over a mutation none of the four had exercised —
*"a mutation that crashes has not exercised the assertion it was written for"*, arriving through the
harness's own environment. The C arms name M27's own module now.

---

## THE SWEEP

### The reference, declared before the run

| milestone | from | to | delta | what buys it |
|---|---|---|---|---|
| m18 | 498 | **576** | +78 | `e2e_ts_wasm_amm` |
| m21 | 369 | **449** | +80 | `test_form_b_tx_matches_pxe_bytes` 78, and `verify_transcript_truncation_detection_uniform` 55 → 57 — the census's own population 32 → 33 and reaching set 12 → 13, which the new probe-driving check joins |
| m25 | 308 | **453** | +145 | `test_nested_call_reverted_contributes_no_side_effects` 89 + `e2e_trace_token_transfer_steppable` 56 |
| m28 | 357 | **358** | +1 | `verify_npm_pack_no_optional_native` 54 → 55, one assertion for the fifth harness tree. Its ONE failure is L0's `replay/` and is unchanged |
| m31 | 421 | **450** | +29 | the eighth transpiler fixture joins three per-fixture loops: 130 → 138, 135 → 150, 97 → 103 |

**PREDICTED TOTAL 12,867** = 12,534 + 78 + 80 + 145 + 1 + 29. Nothing else may move.

Pre-sweep state: `dev` clean and one commit ahead of `origin/dev` (the arithmetic guard), no
`verify-m`/`verify-l` process, load average 0.49, `carry/*.json` checksummed, the browser bundle
rebuilt from the RESTORED sources after the mutation matrix and verified back at its shipped
figures (8,230.78 KB total, `browser.js` 265.79 KB).

### THE SWEEP WAS ABORTED ONCE, SIX MINUTES IN, AND THE ABORT BOUGHT A CENSUS THAT WAS NARROWER THAN ITS OWN SENTENCE

The sweep is a long window in which the only safe work is read-only, and the brief says what that
window is for. Reading this pass's own four checks for the shapes it lists found one:

**`test_form_b_tx_matches_pxe_bytes` §6 asserts that no SHIPPED SOURCE defines or calls
`generateSimulatedProvingResult` — and scanned `orchestration/src/*.ts` and `browser/src/*.ts`,
which glob ONE directory each.** `orchestration/src/vendor/` and `browser/src/wallet/` were outside
it, and `browser/src/wallet/dev_wallet.ts` is one of the five citation sites the closeout pass
recorded. Measured before the fix and after: **both scans answer zero**, so the verdict is unchanged
and the entry's conclusion is untouched — but a census narrower than its own sentence is this
campaign's most repeated defect, and the two subdirectories are now asserted to be IN the file list
rather than assumed. `test_form_b_tx_matches_pxe_bytes` 78 → **80**, m21 449 → **451**.

And one smaller thing in the same read: `_m25_container_steps.py`'s comparer carried a branch for a
NEGATIVE offset that nothing ever passes. A fail-safe arm that never executes is a property of dead
code; it is gone.

The run was killed six minutes in, at m2, both fixed, the two checks re-run (80 / 0 and 56 / 0), and
the sweep restarted after the last edit rather than finished and explained.

**Revised prediction: m18 576, m21 451, m25 453, m28 358, m31 450 — TOTAL 12,869.**

### AND THE SWEEP WAS ABORTED A SECOND TIME, TWO MINUTES IN, FOR THE SAME FAMILY IN A DIFFERENT FILE

*"When you fix an instance of a form, grep for the form in the file you are fixing before you leave
it"* — one level up: **grep for it in the files this pass wrote.** The arithmetic hazard the C2 arm
found in `e2e_trace_token_transfer_steppable` was censused across all four new checks:

| check | unguarded `$(( ))` sites over an accessor's output |
|---|---|
| `e2e_ts_wasm_amm` | **8** |
| `test_nested_call_reverted_contributes_no_side_effects` | **1** |
| `e2e_trace_token_transfer_steppable` | 0 (fixed) |
| `test_form_b_tx_matches_pxe_bytes` | 0 |

Reproduced directly rather than argued: `bash -c 'set -u; X=MISSING; echo "$(( X + 1 ))"; echo after'`
prints `MISSING: unbound variable` and **never prints `after`**. Every accessor in those files returns
`MISSING` for an absent field — deliberately — so each of those nine sites was one absent field away
from KILLING its check instead of failing it. All nine are guarded, and the values they consume are
asserted NUMERIC first.

**AND THE FIRST FIX INTRODUCED TWO DEFECTS OF ITS OWN, BOTH CAUGHT BY RUNNING IT.**

  1. **The helpers were declared halfway down the file**, after the loop in PART 3 that uses them.
     Result: `num: command not found` three times, one arithmetic syntax error, and **four
     assertions of that loop vanished** — 78 → 75. The same silent shrink, one level further in.
     A helper is only defined from its declaration onward; they are at the top now.
  2. **The numeric census named variables that had not been assigned yet.** `set -u` killed the
     SUBSHELL the command substitution runs in, the parent carried on with an empty string, and
     `assert_eq "" ""` PASSED. *An assertion that cannot fail, created while fixing an instance of
     the family it belongs to.* Every value is read before the census now, and the census carries
     its own positive control — the same predicate run over a reading that really is `MISSING`.

`e2e_ts_wasm_amm` 78 → **80**, `test_nested_call_reverted_contributes_no_side_effects` 89 → **90**.

**Revised prediction: m18 578, m21 451, m25 454, m28 358, m31 450 — TOTAL 12,872.**

---

## THE MUTATION MATRIX, RE-TAKEN AGAINST THE TREE THAT SHIPS

The arithmetic guards moved three checks' counts, so the matrix was re-run after the last edit —
*"a matrix taken before the last edit is not a measurement of the tree that ships"*. **Every arm
reproduced its failure SET exactly, at the new counts.**

| arm | subject | result | what it killed |
|---|---|---|---|
| A1 | the foreign-sender control is self-sent after all | 80 / **8** | the sender identity, all four `only_self` refusals, the payload non-emptiness, the four-distinct count, the control's empty pool |
| A2 | the no-minter control grants the minter anyway | 80 / **3** | `is_minter`, the control's revert, its zero supply |
| A3 | the exact-out note siloed under the wrong token | 80 / **3** | exactly the FOURTH entry point and its two deltas |
| A4 | the `abi_only_self` scan drops its predicate | 80 / **2** | exactly the two Part-2 assertions (4 → 6) |
| A5 | the arm run HANGS | **0 / 1, rc 124** | the bound, named, summary at column 0 |
| A6 | the arms file truncated | **0 / 1** | one named refusal, listing the three missing arms |
| B1 | the positive control runs the SUBJECT's outer function | 90 / **7** | the contract-derived callee mapping and the whole positive control |
| B2 | the early-revert control forwards the subject's argument | 90 / **3** | the argument identity and §5's two count comparisons |
| B3 | the nested callee stops reverting, **in the CONTRACT** | 90 / **6** | all three witnesses at once |
| B4 | the transaction's nullifier list reported empty | 90 / **5** | exactly §4b; §4a and §4c green |
| B5 | the transpiler arm run HANGS | **0 / 1** | the bound, named (rc 137 — `m31_bounded` uses `timeout -s KILL` and tests 124 and 137) |
| C1 | **the container's l2Gas fabricated at the WRITE site** | 56 / **7** | the whole l2Gas sequence and the 516-record differential |
| C2 | the balance read-back taken before the block | 56 / **5** | the three after-assertions and the arrival test |
| C3 | the recipient's leaf derived for the SENDER | 56 / **4** | the leaf identity, the `EMPTY`-before, the after value, the conservation sum |
| C4 | the parser's variable-id mapping off by one | 56 / **23** | the id map by name, the completeness census, everything downstream |
| D1 | this runtime's seam drops the public calldata | 80 / **8** | the two calldata-carrying cases; `noCalldata` green |
| D2 | the node stub stops counting | 80 / **1** | exactly the paired positive |
| D3 | the reference stops running PXE's step 2 | 80 / **6** | §2 entirely; the byte-identity assertions SURVIVE, which is the arm's finding |
| D4 | the reference producer HANGS | **13 / 1, rc 124** | the bound, named |

`--demo-still-there` exits **5** as designed; every arm's restore was verified against the sha256
manifest; `HARNESS` reports no `MUTATION MISS`, no `ABORTED` and no `DID NOT HOLD`; and the tree is
clean afterwards, with the browser bundle rebuilt from the restored sources and verified back at its
shipped figures.
