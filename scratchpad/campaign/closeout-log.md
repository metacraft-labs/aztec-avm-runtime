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

## Step 4 — an eighth entry, which the audit had called blocked

`test_custom_bytecode_unhappy_paths` (M18) was left `pending` by the residuals pass on the ground
that the malformed programs need the bytecode ASSEMBLER, which this repository does not have. That
is **still true and is asserted rather than quoted** — but it is not in the way, because each of the
four unhappy paths is defined by what the bytes are **not**:

| path | program |
|---|---|
| an invalid opcode | a byte no opcode uses — **1 byte** |
| a truncated instruction | a VALID opcode with its operands cut off — **1 byte** |
| an invalid tag | that instruction at full length, tag byte out of range — **5 bytes** |
| an out-of-range program counter | nothing at the counter — **0 bytes** |

Every constant is derived from the AVM's own headers at the `cpp` anchor, **twice**: the tool reads
`WireOpCode` and `ValueTag` in JavaScript, the check re-derives them with its own Python parser, and
the two are asserted equal. The AVM answers all four with **four different diagnostics**, and the
truncation one names `instruction size: 5`, which is `SET_8`'s wire length computed from upstream's
own operand table.

**The well-formed control is a real contract's own dispatch bytecode through the same custom path** —
179 instructions, returning the function's answer — because "malformed bytecode reverts" is equally
satisfied by an AVM that refuses all of it. And "not host-side crashes" is a **positive** claim: all
five run in one process with the control last.

`test_custom_bytecode_unhappy_paths`: **62 assertions, 0 failures.**

## Step 5 — the mutation matrix: twelve arms, and three of them had to be re-aimed

| arm | subject | result | what it killed |
|---|---|---|---|
| M1 | `collectDebugLogs` forced on | 24 / **1** | the flag control, and only it |
| M2 | one surfaced message rewritten | 24 / **1** | the message-vs-contract-source comparison |
| M3 | the mint never submitted | 37/**11**, 49/**12** | every balance, revert-code and per-tx gas assertion |
| M4 | the deployment not attached | 38 / **5** | the two calls, their values, the identity — control green |
| M5 | the teardown call dropped | 39 / **6** | the teardown read-backs and the TEARDOWN module code |
| M6 | both gas arms allocate the same | 38 / **1** | exactly the non-degeneracy guard |
| M7 | the note-hash index answers for everything | 33 / **3** | the note-hash half; the nullifier half green |
| M8 | the arm run HANGS | **0 / 1, rc 124** | the bound, named, with a summary line at column 0 |
| M9 | one block renamed | 37 / **17** | the block LABEL first, then every field as `MISSING` |
| M10 | the arms file truncated | **0 / 1** | the precondition, refusing by name |
| M11 | the "invalid" opcode is valid | 62 / **3** | the sentinel guard, the diagnostic, the distinct count |
| M12 | the well-formed control is malformed | 62 / **5** | exactly the control's assertions |

**Three arms had to be re-aimed, and each re-aiming is a finding.**

1. **M4's first form crashed the arm run** — it emptied the class loop and left the instance loop,
   so the transaction carried an instance whose class nothing knew, the run exited 1 and the check
   died at its precondition with `0 assertion(s), 1 failure(s)`. The die-before-summary path worked
   and **not one assertion of the section the arm was written for ever ran.**
2. **M6 went GREEN and that was a defect in the driver, not in the arm.** The gas allocations were
   declared twice — once in the call and once in the report — so mutating the call left the report
   still claiming they differed and the check's non-degeneracy guard passed over an equality that
   had become a tautology. One declaration now. *This is the arm that earned its keep.*
3. **M11's first form was refused by the TOOL's own guard**, which will not produce an arm run whose
   "invalid" byte is below the sentinel — so the check died before reaching its own guard. Two
   substitutions now, and having both guards is the point: one refuses to MAKE the bad arm, the
   other refuses to BELIEVE it.

And **M9 was split from M10** after M10's first run reported *thirty-five* failures over a truncated
arms file: loud, but a broken-check shape rather than a run-did-not-happen one, and the two have
different remedies. `tb_require_arms_shape` turns it into one named refusal; M9 now exercises the
accessor's `MISSING` path over a well-formed file instead.

`--demo-still-there` exits **5** as designed, and every arm's restore was verified against the
sha256 manifest.

## Step 6 — eight entries closed, each with its own commit

| commit | entry | milestone | assertions |
|---|---|---|---|
| `2e045f5` | `test_debug_log_events_surface` | M25 | 24 |
| `aba0966` | `e2e_block_token_flows` | M22 | 37 |
| `bf155c9` | `e2e_ts_wasm_token_transfer` | M18 | 49 |
| `899b56b` | `e2e_ts_wasm_nested_call_fork_merge` | M18 | 38 |
| `ca50cad` | `e2e_ts_wasm_phase_revert_semantics` | M18 | 39 |
| `fc92da1` | `e2e_block_deployments_through_processor` | M22 | 38 |
| `9d9e21a` | `test_settled_read_request_verification` | M21 | 33 |
| `6a78c3a` | `test_custom_bytecode_unhappy_paths` | M18 | 62 |

**320 new assertions.** Every check is wired into its milestone's own `verify-m<N>` recipe — the
brief's rule that a milestone that declares a check must run it — and each has a standalone recipe.

**The pending list is 21 → 14**, and four of the fourteen carry today's measurement rather than
yesterday's (see the specs commit `d12d4c31`).

## Step 7 — the sweep reference, declared before the run

| milestone | from | to | delta | what buys it |
|---|---|---|---|---|
| m18 | 283 | **471** | +188 | 49 + 38 + 39 + 62 |
| m21 | 334 | **367** | +33 | `test_settled_read_request_verification` |
| m22 | 265 | **340** | +75 | 37 + 38 |
| m25 | 284 | **308** | +24 | `test_debug_log_events_surface` |

**PREDICTED TOTAL 12,496** = 12,176 + 320. Nothing else may move: measured before the sweep,
`verify_named_checks_exist` is **9**, `verify_no_pipeline_predicates` **69**,
`just check-repo-hygiene` **28** and `verify_reuse_inventory_complete` **19** — all unchanged, and
the two failures in that set are the parallel tracks' known reds (L3's
`tools/scan_reverted_transactions.mjs`, L4's sixth `| grep -q`), with their counts unmoved.
