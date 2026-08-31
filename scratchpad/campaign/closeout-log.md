# Closeout pass — turning the residuals audit's fifteen re-described entries into checks

Started 2026-08-31, immediately after the residuals pass. Baseline: `dev` `9a6e3ea`, sweep
**12,176**, `delta +0`, 35 of 38 exit 0.

The residuals pass **re-described** 15 of the 21 `pending` entries with their true blockers and
deliberately did not close them. The user has since instructed that follow-up items be addressed.
This pass closes what is closeable and re-measures what is not.

## Step 0 — context read, and the state found

Read in full: `CAMPAIGN-BRIEF.md` (2,788 lines), `scratchpad/campaign/residuals-log.md`,
`OUT-OF-SCOPE.md`, and the M36/M37 review logs' outstanding sections.

State at start (measured, not assumed):

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `9a6e3ea` == `origin/dev` after `git fetch` | clean |
| `codetracer-specs` | `latest` | `ed5c139f` | clean |
| `noir` | `codetracer` | (checked below) | — |

No `verify-m` / `verify-l` process running — the six matches for the pattern are stale `tail -f`
processes on old sweep logs (etimes of 5 days, 7 days, 2 days), not sweeps. Load average 0.64.

## Step 1 — the pending census, re-derived rather than inherited

Parsed the milestone file by `- test_name:` / `status:` pairs, the same shape the residuals pass
used: **240 verification entries, 21 `pending`** (194 `passing`, 20 `passed`, 4 `completed`,
1 `verified`). The residuals pass counted 237 entries / 21 pending; the entry total has moved by
three since (other tracks' additions), the pending set has not.

The 21, and the audit's classification of each:

| milestone | entry | audit verdict |
|---|---|---|
| M11 | `verify_all_five_patches_submitted` | blocked on a human |
| M16 | `test_fallback_empty_note_hash_tree_root` | genuinely blocked (`not-fired` trigger) |
| M16 | `test_fallback_domain_separators_from_constants` | genuinely blocked |
| M16 | `test_fallback_checkpoint_stack_is_o_changes` | genuinely blocked |
| M16 | `e2e_fallback_matches_golden_vectors` | genuinely blocked |
| M18 | `e2e_ts_wasm_token_transfer` | *"Nothing blocks this but writing the check."* |
| M18 | `e2e_ts_wasm_amm` | *"Real work, not a check-writing exercise."* |
| M18 | `e2e_ts_wasm_phase_revert_semantics` | narrower true gap; *"the pieces exist"* |
| M18 | `e2e_ts_wasm_nested_call_fork_merge` | *"Closeable."* |
| M18 | `test_custom_bytecode_unhappy_paths` | true blocker is the ASSEMBLER |
| M21 | `test_form_b_tx_matches_pxe_bytes` | true blocker: the Tx-building half is unvendored |
| M21 | `test_settled_read_request_verification` | *"Closeable"*; stated route never existed |
| M22 | `e2e_block_deployments_through_processor` | true gap: nothing puts a deployment on a Tx |
| M22 | `e2e_block_token_flows` | *"No blocker other than writing it."* |
| M25 | `e2e_trace_token_transfer_steppable` | *"Exactly two things are missing… Closeable."* |
| M25 | `test_nested_call_reverted_contributes_no_side_effects` | true blocker: a CORPUS gap |
| M25 | `test_debug_log_events_surface` | *"Closeable."* |
| M26 | `e2e_form_b_single_ct_recording` | still blocked: no private step stream |
| M26 | `e2e_joined_trace_opens_in_codetracer` | owned elsewhere (`OUT-OF-SCOPE.md`) |
| M35 | `e2e_wallet_private_transfer` | ladder moved; `mint_to_private` executes |
| M35 | `e2e_joined_private_public_trace` | needs a private step stream |

**Working order: dependency order, smallest first, one commit per closed entry.**

## Step 2 — the one instrument six of the entries needed, built and measured

Six of the fifteen re-described entries were blocked on the same thing for five milestones —
*a transaction that calls a registered contract* — and the residuals pass measured that blocker
dead without writing the checks. They are all answered by ONE arm run:

- `orchestration/src/token_block_driver.ts` — the arms, composing only things that already exist
  (RI-72's vendored builder and deployment helpers, M22's `assembleBlock`/`sealBlock`, M13/M14's
  resident world state, M18's wasm simulator).
- `tools/run_token_block_arms.mjs` — one process, one module instantiation, every arm.
- `verification/lib_token_blocks.sh` — the shared precondition/accessor library, cross-milestone
  for the reason `lib_avm_wasm.sh` and `lib_l2_replay.sh` are.

**The recipe is upstream's own `token_test.ts`, call for call** (vendored here three times over as
RI-25): deploy, `constructor`, `mint_to_public`, `transfer_in_public`, `burn_public`, with each
balance read back through a STATIC `balance_of_public` whose return value is compared. Nothing in
the driver derives a storage slot: the constructor and the mint RUN, so the balances are what the
contract itself wrote.

### Four things the arms found that no document said

1. **`avm_steps_count()` reports the LAST simulation, and the processor's loop cannot be stepped.**
   Reading it after a block gives the last transaction's count for every transaction in it — a
   number that looks per-transaction and is not. The simulator is wrapped, delegating unchanged and
   reading the counter after each crossing, so `instructionsPerSimulation` is attributable.

2. **A deployment on a PRIVATE-ONLY carrier — upstream's own shape in `deployments.test.ts` —
   cannot be processed by this runtime.** `doTreeInsertionsForPrivateOnlyTx` calls
   `guardedMerkleTree.batchInsert(NULLIFIER_TREE, …)` and `ResidentMerkleWriteOperations.batchInsert`
   REFUSES by design. Measured: the transaction lands in `failed` with *"failed with duplicate
   nullifiers"*, which is the processor's wrapper around that refusal and names the wrong cause.
   The arm exercises it rather than claiming it.

3. **`PublicProcessor` calls `contractsDB.addNewContracts(tx)` in exactly ONE place** —
   `processPrivateOnlyTx`. So a deployment riding on a transaction WITH public calls is never
   extracted by the contract store, and `registrations` is `{0,0}`. It is still callable, and the
   route is upstream's `AvmTxHint.fromTx`, which carries the transaction's
   `revertibleContractDeploymentData` into the AVM, plus the contract-address nullifier the
   processor writes. The check asserts `addNewContracts == 0` **by name**, because a check that
   asserted only "it is callable" could not tell those two mechanisms apart.

4. **The first deployment arm could not have failed.** It deployed a second instance of the SAME
   artifact the carrier used, so both classes carried identical bytecode and a subject that "became
   callable" could have been the carrier's bytecode answering. The subject is `Child` now and the
   carrier `AvmTest`; the call read is `Child.pub_get_value`, which exists only in the subject's
   artifact. Found by asking what input would make the arm red.

### Two defects in this pass's own work, both found by running rather than by reading

- A nullifier constant collision: `DISCARDED` was `LANDED + 1`, which is the value the LANDING
  arm's nested frame emits. The "the discarded nullifier is still free" follow-up therefore
  reverted against a nullifier that had landed in the *other* arm — **the arm reported the exact
  opposite of its subject while looking correct.** Two distinct values now, asserted distinct.
- A comparison of a real newline against a JSON `\n` escape, in the debug-log check. It went red
  on its first run, which is the cheap direction.

## Step 3 — five checks written, run green, and their counts

| check | milestone | assertions |
|---|---|---|
| `test_debug_log_events_surface` | M25 | **24** |
| `e2e_block_token_flows` | M22 | **37** |
| `e2e_ts_wasm_token_transfer` | M18 | **49** |
| `e2e_ts_wasm_nested_call_fork_merge` | M18 | **38** |
| `e2e_ts_wasm_phase_revert_semantics` | M18 | **39** |
| `e2e_block_deployments_through_processor` | M22 | **38** |

All six 0 failures against the arms measured at
`aztec-m15-shapes/m13/…/avm.wasm` (sha256 `14882dcb…`, 49 exports, 8 `avm_coordinator_*`).

**The headline measurements, none of them typed into a check:**

- Token: `constructor` 7,145 instructions, then the **mint and the transfer in ONE block**, then
  balances **50 / 50**, then the burn, then **50 / 0** — upstream's own expectations to the unit.
  The no-mint control reverts on the contract's own `assert(balance >= amount)` and reads 0 / 0.
- Phases: `allSucceed` → 4242/5151/6262; `setupReverts` → **thrown out of the block**, 0/0/0;
  `appReverts` → lands, module code **1**, 4242 survives, 5151 rolled back, **6262 written — the
  teardown still ran**; `teardownReverts` → lands, module code **2**, 4242 survives, and the fee is
  **identical to the arm that did not revert**.
- Nested: `nested_call_to_add` and `nested_static_call_to_add` both return 8 at ~6x the flat call's
  instruction count; `nested_static_call_to_set_storage` is refused by the AVM naming `SSTORE` and
  `static context`; the gas allocations 2,000,000 and 8,000,000 produce **the same transaction gas,
  574,059** — unused gas refunded, measured; and the nullifier triple answers **FAIL / FAIL /
  SUCCEED**, so a reverted nested frame's write is provably not in the tree.
- Deployment: the 2×2 is complete — same-block and later-block calls both succeed with the
  deployment and both revert at **instruction one** with *"is not deployed"* without it.
