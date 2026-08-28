# M29 — Executed Steps, Not Mapped Ones — implementation log

Written as I go, per the brief. The tree is left quiescent at every step; no commits, no pushes.

## Step 0 — reading and pricing, before any code

**What already exists, enumerated by subdirectory before concluding anything is ours to write.**

| the thing M29 needs | where it already is |
|---|---|
| the per-instruction hook | M9's `ExecutionObserverInterface`, compiled into `avm.wasm`; the flag is `PublicSimulatorConfig::collect_execution_steps`, default `false` |
| the executed stream, host side | `avm_steps_count()` / `avm_steps_batch(from, count)` (M12), and the whole stream also arrives inside `TxSimulationResult.executionSteps` |
| the batched drain | `node-host/src/steps.ts` — `stepCount`, `drainSteps`, `expectedCrossings`, `formatStep`, `ExecutionStep`. **Every import in that file is `import type`**, so it carries no runtime dependency at all and is browser-safe as written; `browser/src/loader.ts` already imports `Reactor` from `node-host` at value level, so this is not a new coupling. |
| the writer and the event ABI | M24's `ct-host` — `CtWriter.push`/`flush` -> `ct_ingest(ptr, len)`, 64-byte records |
| the source positions | M25's `ContractSourceMap` (rung-1, keyed by AVM byte offset) |
| the executed-instruction statistic | `TxSimulationResult.stats["total_instructions_executed"]`, behind `collect_statistics` — decoded already (`node-host/src/transcript.ts:110`) |

**The one thing that stands between them**, found by reading rather than assumed:
`orchestration/src/shipped_module_config.ts:42` hard-codes

```ts
export const PATCH_REQUIRED_CONFIG_FIELDS = { collectExecutionSteps: false };
```

and it is spread over the caller's config, so **no caller can switch step collection on**. That is
the whole of the missing plumbing on the input side.

## Step 1 — measurement before design

Recorded below as it is taken.

### 1.1 The plumbing works, and the first thing it showed was not what M29 went looking for

`collectExecutionSteps: true` reaches the module; `avm_steps_count()` answers; `drainSteps` decodes;
and the drained records equal the ones inside `TxSimulationResult.executionSteps` **per record**.

Then the number came out at **1**.

| what the AVM did with M27's demo transaction | measured |
|---|---|
| `stats["total_instructions_executed"]` | **1** |
| the one record | `ctx=1 pc=0 op=68 l2=6540000 da=786432 addr=0x115d…96c1` |
| opcode 68 | M9's `LAST_OPCODE_SENTINEL` — `read_instruction` threw before the opcode was known |
| `revertCode` | **1** |
| what M27's container said | **64 steps**, `opcode: (pc % 200) + 1`, "rung 1, 64 of 64 positioned" |

**M27's container did not merely fabricate its opcodes; it fabricated them over a transaction that
had not run.** Nothing could see it: the steps came from the artifact's debug map, which is a
property of the artifact and not of the execution, and the block's verdict — `processed` — is the
BLOCK's verdict, with a revert being a legitimate outcome inside it. `smoke_browser_token_transfer`
asserts `processed` and is right to; it just does not mean what a reader assumes.

### 1.2 Three seeding gaps, each found by the stream and each named

Every one of these was invisible before there was an executed stream to look at, and each was fixed
by adding one seeding step to `browser/src/token_transfer.ts`. The numbers are the executed
instruction count after each fix.

| # | what was missing | how the stream said so | steps after |
|---|---|---|---|
| 1 | the **deployment nullifier**, `siloNullifier(CONTRACT_INSTANCE_REGISTRY, address)` | `pc=0`, opcode 68 (sentinel): the AVM answers an undeployed address with no bytecode at all | 1 -> **175** |
| 2 | the **public initialization nullifier**, `siloNullifier(address, poseidon2_with_sep([address], PUBLIC_INITIALIZATION_NULLIFIER))` | the tail was `NULLIFIEREXISTS`, `JUMPI_32`, `INTERNALCALL`, `REVERT_8` — `assert_is_initialized_public`, which every non-`#[noinitcheck]` public function calls | 175 -> **222** |
| 3 | a **token balance** for the sender (`public_balances` map, slot read out of the artifact) | the tail became `LT_16`, `JUMPI_32`, `INTERNALCALL`, `REVERT_8` — `assert(balance >= amount)`; the sender had fee juice and no tokens | 222 -> **471**, and context 2 appears |
| 4 | `isStaticCall` on the `#[view]` `balance_of_public` call | context 2 ended `GETENVVAR_16`, `JUMPI_32`, `INTERNALCALL`, `REVERT_8` | 471 -> **516**, `revertCode` **0** |

Why upstream's own tester needs none of this: `PublicTxSimulationTester` seeds the contract-address
nullifier only (`base_avm_simulation_tester.ts:160`) and its corpus is `AvmTest`, which has no
initializer and no balances. Token has both.

**Final state of the demo transaction: 516 executed instructions, 24 distinct opcodes, two AVM
contexts, `revertCode` 0.** 389 of the 516 resolve to a source position; 127 do not, and those are
`SOURCE-MAPPING.md` §2.4's residual hole 2 — compiled procedures appended past the end of
`brillig_pcs_to_avm_pcs` (`transpile.rs:489,505`) — which is why the RUNG DECLARATION is now
measured over the executed stream rather than taken from the artifact.

### 1.3 The container, end to end, in Node

516 events, 2 frames from the AVM's own context ids, 389 positioned / 127 unpositioned, 14 paths,
1 log event, `ct_writer_kind()` = 1, 196,608 bytes. `ct-print --full` exits 0 over it with 516
`"type": "Step"` records and names `macros/dispatch.nr`, `oracle/avm.nr` and two
`crates/serde/src/*` files.

### 1.4 The native differential is cheap and it is exact

`avm_differential steps` natively: **2.99 s**. `avm_differential reactorinputs`: **0.94 s**. Feeding
the native driver's own `reactorInputs.burn.faststeps` blob to **M27's** `avm.wasm` through
`browser/src/native_parity.ts` gives **38,903 records** — M9's and M12's measured count — and a
per-record comparison against the native transcript reports **0 mismatches over 38,903 records**,
with an EMPTY exclusion list.

## Step 2 — what was written, and the decisions inside it

### 2.1 The one edit that unblocked everything

`orchestration/src/shipped_module_config.ts` spread a hard-coded `{ collectExecutionSteps: false }`
over every caller's config. `patchFieldsFor(options)` replaces the constant with a caller's choice
and **asserts the key set is unchanged at run time** — the value is negotiable, the key set is not,
because the encoding DELTA this runtime declares is exactly `Object.keys(PATCH_REQUIRED_CONFIG_FIELDS)`
and `e2e_form_a_external_tx_roundtrip` Part 8 rests on it.

### 2.2 The drain is at the boundary, in the same turn as the simulation

`g_steps` inside the module is REPLACED by every `avm_simulate` (`avm_reactor.cpp`, M12's patch,
two assignment sites). A page that ran a transaction, produced a block and only then asked for the
steps would get whatever the block processor simulated last — the same records for a
one-transaction block, silently the wrong ones for a two-transaction block. So
`ExecutedStepCollector` wraps `Reactor.simulate` and drains immediately.

**And it copies the result buffer BEFORE the drain.** This was a latent bug the drain would have
exposed: `runtime.ts` passed `() => decodePublicTxResult(reactor.result()!)` as the decoder, which
re-reads the module's ONE result buffer — and `avm_steps_batch` writes into that same buffer. A
caller decoding it after a drain would decode a window of step records as a `TxSimulationResult`:
not a crash, a plausible wrong object. `steps.lastResultBytes` is the copy, taken in the same turn.

### 2.3 The rung is declared from the execution

Documented in `SOURCE-MAPPING.md`'s new §6 M29 entry and in `ct_download.ts`'s header. The short
version: 389 of 516 executed steps resolve, 127 do not, a rung-1 declaration would make
`CtWriter.close()` throw `MappingRungDegraded`, and M25's rule is "never rounded up". The SESSION
rung stays `RUNG_SOURCE` (columns are recordable and are recorded); the CONTRACT declaration is the
coverage claim and is measured.

### 2.4 Frames come from the AVM's own context ids

M27 dealt the artifact's mapped pcs round-robin across the enqueued call names — the right NUMBER of
frames with arbitrary steps in them. `ct_download.ts` now keeps a stack of context ids: a new id is
a call, an id already on the stack is a return. Two frames, and they are the two enqueued calls.

## Step 3 — what moved outside M29, in both directions

| what | from | to | why |
|---|---|---|---|
| `e2e_browser_downloads_ct_container_and_ct_print_parses` (M27) | 34 | **36** | two assertions that could not fail removed (`every step positioned`, `none unpositioned` — true by construction), five that can added |
| `BROWSER-PACKAGING.md` §1 and §6 figures | 253.94 / 277.43 / 277.65 / 223.61 / 8,149.89 | 255.78 / 279.69 / 280.89 / 225.31 / 8,155.06 | the reference entry reaches `executed_steps.ts`, the demo also reaches `native_parity.ts`; `verify_browser_chunk_budget` re-derives every cell and refused the stale ones |
| `BROWSER-GATE.md` §3 input counts | 1061 / 967 | 1064 / 969 | the same two modules, in both bundles; `just ci-browser-gate` re-derives them |
| M25's `test_trace_step_count_matches_instruction_count` | `pending` | **retired** | carried to M29 in the same edit. M25's total is unchanged at 272, because a `pending` entry has no assertions |

Measured after each: **M27 345** (was 343, +2 and no other check moved), **M28 353** (unchanged),
**M24 350** (unchanged — `ct-host/src` was not touched, so `_m24_oq6_stamp` did not fire and no
benchmark re-ran), **M25 272** (unchanged).

## Step 4 — the mutation matrix, and the two things it found in M29's own checks

Eight arms, `scratchpad/campaign/m29-mutations.sh`, serialised before any sweep, restored and the
restore verified **against the harness's own copies** — two of the five files are new in M29 and
therefore untracked, so `git status --porcelain -- <path>` would have printed nothing whatever the
harness did, which is a defect this campaign has shipped twice. The comparison carries its own
control: a one-line corruption of a copy is reported.

### Round 1 — and it found a coverage gap and a no-op

| arm | what it breaks | what happened |
|---|---|---|
| **M1** the synthesised path returns | `opcode: (pc % 200) + 1` back in the recorder, everything else real | **42 assertions, 1 failure — and the one failure was a `grep` of the source tree.** Every behavioural assertion passed over a container full of fabricated opcodes |
| **M2** the drain loses a record | `drainSteps(…, count - 1)` | **no-op.** `total` bounds the LOOP, not the window: one 4,096-record batch returns all 516 either way. Both checks green |
| M3 collection off | the demo stops asking for the hook | 0 assertions, 1 failure, `ExecutedStepsUnavailable` quoted in full |
| M4 one altered parity record | `pc + 1` on record 0 | caught — 4 failures, **two of which were the CONTROLS misfiring** (`expected 1, got 2`) |
| M5 "the hang" | an unsettled promise in the page | **not a hang.** V8 collects it; CDP answers `Promise was collected` in seconds |
| M6 die before summary | the native binary is not where the library looks | 0 assertions, 1 failure, naming the path and the remedy |
| M7 the rung rounded up | rung 1 declared over a stream with holes | 0/1, `MappingRungDegraded: … the first at pc 0. 389 step(s) were positioned and 127 were not` |
| M8 unpositioned steps dropped | `continue` instead of `push` | caught in both checks — 2 failures each, `expected 516, got 389` and the declared-rung implication |

**M1 is the finding.** Everything the check read was upstream of the writer: the arm's drained
records, and `recording.distinctOpcodes`, which `ct_download.ts` computed from those same drained
steps. The number was read from the producer's own report rather than from the thing the producer
produced — `CAMPAIGN-BRIEF.md`'s "anything asserted must be read from the artefact" in its exact
shape.

**Three fixes, all of them in M29's own work:**

1. `verification/_m29_container_opcodes.py` — the opcodes that are IN the container, read back
   through the pinned reader. The variable id is resolved from the `VariableName` records rather
   than pinned at 1, and a name that never appears is a refusal rather than an empty histogram. The
   check now asserts the container's histogram equals the drained stream's, opcode for opcode, with
   a one-count corruption as the control that the comparison can fail, and with M27's rule applied
   to the SAME executed pcs as a second control that the two multisets really are different.
   `test_browser_steps_are_executed_not_mapped` 42 -> **52**.
2. `ct_download.ts` accumulates `distinctOpcodes` from the opcode it actually pushes, not from the
   drained step it read it out of.
3. The parity check's controls expect `BASE + 1` rather than `1`, so a corrupted subject produces
   two red assertions that say what is wrong instead of four that include the instrument.

**M2 and M5 were re-written**, and both rewrites are recorded rather than quietly swapped: `total`
is a loop bound, so the first M2 measured nothing; and an unsettled promise is collected, so the
first M5 was M24's review's "a mutation that crashes has not exercised the assertion it was written
for" happening again. M2 now drops a decoded record — caught by the producer's own
count-versus-decoded precondition, by name — and M5 spins the renderer, which is what a bound is for.

### Rounds 2 and 3 — after the fixes

| arm | what happened |
|---|---|
| **M1** (re-written to mutate the EVENT, not the local `opcode`, so `distinctOpcodes` does not move and only the container can see it) | **52 assertions, 3 failures**: the source grep, `THE CONTAINER'S OPCODE HISTOGRAM IS THE DRAINED STREAM'S` failing, and `…and it is NOT the histogram the container carries` **succeeding** — the container's opcodes ARE the synthetic rule over the executed pcs. Both behavioural failures say exactly what is wrong |
| **M2** (drops a decoded record) | 0 assertions, 1 failure, and the diagnostic is the producer's own precondition quoted in full: *"the module counted 516 step(s) and the drain decoded 515"* |
| **M4** | **31 assertions, 2 failures**, both about the subject: the per-record comparison and the first record printed side by side. The two control assertions that used to add noise now pass, because they expect `BASE + 1` |
| **M5** (a spin, not an unsettled promise) | 0 assertions, 1 failure: *"Runtime.evaluate did not complete within 60000 ms. That is the HANG state reported as a failure."* — a real hang, bounded and named |

The restore was verified after every round: five files byte-identical to the harness's own copies,
with the comparison's own control (a one-line corruption of a copy) reported.

## Step 5 — the sweep

Run `setsid`-detached from **this repository's own dev shell** (`direnv exec <aztec-avm-runtime>`,
not the workspace root's — M25's review's finding), `TMPDIR` and the log under `~/.cache`, one
milestone at a time, with nothing else running. The mutation harness ran to completion, restored,
and the restore was verified BEFORE the sweep started; the two are serialised because they are two
writers.

`verify-m11` rewrites `carry/rebase.json` and `carry/exposure.json` on every run — a sweep is
itself a writer — so both are checksummed before the sweep and restored after it.

### The sweep, and the two things it caught in M29's own work

**M0–M29, 30 milestones, `setsid`-detached in this repository's dev shell, one at a time.** The
first pass came out with four non-zero exits, and two of them were M29's:

| milestone | what | verdict |
|---|---|---|
| m9 | **524, rc 1, 12 failures** — the recorded flake's signature exactly: `807 - 524 = 283 = 140 + 143`, the two checks that correctly REFUSE to compare and print no summary line while doing it | not M29; re-run alone, which is the settled procedure |
| m11 | 259, rc 1, 9 failures — the tip has moved again, to `7471a61f1a92f5b2f474db714f34430253892d99`, with the `barretenberg/cpp` conjunct failing (the seventh move's known open class) and the exposure and ledger hashes stale. **The count is unchanged**, which is the recorded signature | not M29; a known, recorded, non-M29 condition |
| **m21** | 324, rc 1, 1 failure: `the derived population is exactly the recorded size, in both directions — expected [30], got [31]` | **M29's, and it is a good catch** |
| **m27** | 345, rc 1, 1 failure: three figures in `BROWSER-PACKAGING.md` off by 0.01 KB | **M29's** |

**m21 is the more interesting one.** `verify_transcript_truncation_detection_uniform` derives — does
not list — the set of checks that depend on a transcript having finished, and M29's differential
joined it because it names the `avmSteps.done` sentinel. That check's own header says the derived
population exists so that "the eighth transcript check is exactly the one this is for", and M29
wrote the eighth spelling of the completeness question by hand — `assert_true … str_has_line
"$NATIVE_TXT" 'avmSteps.done 1'` — instead of calling M21's shared refusal. It calls
`require_complete_transcript` now and is the **sixth** entry on section 3's comparer list, so the
census reads 31 / 22 / 9: the new member joined the reaching set rather than the backlog.
`verify_transcript_truncation_detection_uniform` 43 -> 44, **m21 324 -> 325**, and
`e2e_browser_container_opcodes_match_native` 31 -> 30 because a refusal is not an assertion.

**m27 is the mundane one and is still worth stating**: the figures were taken before the last edit
to `ct_download.ts`, and the bundle grew by a few bytes. `verify_browser_chunk_budget` re-derives
every cell of §1 and §6 out of `chunks.json`, so it refused them — which is the check doing its job
and the document being what rots. Re-derived after the final build: 255.79 / 279.70 / 280.89 /
225.31, total 8,155.07.

**Re-measured after both fixes: m21 325, m27 345, m28 353, m29 105 — 1,128, delta +0, four of four
exit 0.**

### M9 alone, which is the settled procedure

**807 — the reference exactly — split 140 / 143 / 113 / 73 / 126 / 83 / 129, in 1,291 s.** The
truncation flake did **not** recur: `verify_observation_hook_step_records_identical` is 140/0 and
`test_observer_does_not_perturb` 143/0, so both transcripts were complete and both comparisons ran.

**One assertion failed and it is the OTHER M9 condition, not this one.** `test_observer_disabled_is_free`:
*"the disabled path is not SLOWER than the unpatched build, within +2% (95% CI of the mean over 12
sessions) — +1.29% CI [+0.52%, +2.05%], cost budget +2%"*. The point estimate is inside the budget
and the CI's upper bound crosses it by 0.05 percentage points, on a box that has been running
headless browsers, wasm builds and a thirty-milestone sweep all session. The brief names this as a
separate condition from the truncation and says not to conflate them; it is recorded here as a
timing measurement taken on a loaded machine, not as a regression, and the count is the reference to
the assertion.

## Step 6 — final state

The tree is quiescent. `carry/rebase.json` and `carry/exposure.json` are restored to their
pre-sweep checksums (`eb8f3cad…`, `078c45c5…`) — a sweep is a writer and `verify-m11` rewrites both
on every run. **No commits and no pushes**, per the standing rule. `noir-wt4-webpage` and
`wasm/webpage` were not touched.

Documents updated: `BROWSER-PACKAGING.md` (§1, §6, §7 — every figure re-derived by
`verify_browser_chunk_budget` on every run), `BROWSER-GATE.md` (§3's two input counts, re-derived by
`just ci-browser-gate`), `SOURCE-MAPPING.md` (a new §6 entry: the rung declared from the execution,
and hole 2's first number — 24.6%), `CAMPAIGN-BRIEF.md` (the per-milestone table, the ninth upstream
move, and three new entries under "an assertion must be capable of failing", taking that family's
running total to thirty).

### The arithmetic, checked rather than typed

The documents said `10,048 + 105 + 2 + 1 = 10,157`. **It is 10,156.** Caught by summing the
summariser's own reference table rather than re-reading the sentence — which is what this campaign
means by "if a document states a measurement, something must take that measurement again and
compare". Corrected in `CAMPAIGN-BRIEF.md` and in the milestone file, along with the exit count:
**28 of 30 exit 0**, the two reds being M11's ninth upstream move and M9's disabled-path timing
assertion, both conditions the brief already names.
