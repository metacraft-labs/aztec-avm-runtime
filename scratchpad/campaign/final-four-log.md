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
