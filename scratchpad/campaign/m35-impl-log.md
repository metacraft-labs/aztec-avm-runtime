# M35 — Private Execution Inside the Wallet — IMPLEMENTATION log

Written as I go.

## Step 0 — the state I inherited

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `d24ac569` | clean |
| `codetracer-specs` | ? | ? | ? |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | one pre-existing edit — NOT to be committed |

`git fetch origin` taken: **`HEAD == origin/dev == d24ac5692d017df0d309cf7d52c7c0345ce92fe2`, zero
ahead, zero behind.** No rebase needed; the parallel L0/L1 track has not moved since M34's review
pushed.

No sweep was running when I started: `ps -eo pid,etime,cmd | grep -Ei 'verify-m|verify-l'` returns
nothing but stale `tail -f` processes from earlier sessions.

`REUSE-INVENTORY.md`'s last used id is **RI-96**, so the next free id is RI-97 — re-derived below
rather than remembered, and re-derived again if `origin/dev` moves.

---

## Step 1 — THE REGISTRY COUNT, RE-DERIVED, AND THE TRAP RI-65 WARNED ABOUT IS LIVE

**68. Three `misc`, forty-nine `utl`, sixteen `prv`, plus three legacy aliases.** Not remembered:
taken out of the `cpp` anchor's object store (`233d8e099336c1773b89e939100af047ed9c4f71`) by a
**structural** parse — find `export const ORACLE_REGISTRY = {`, scan to its balanced closing brace
with a string- and comment-aware reader, and take the keys at depth 1 — with the residue printed.
The residue is exactly sixty-eight `makeEntry` tokens (the value side of each pair) and nothing
else, so nothing was dropped and nothing was invented.

Run a second way, differently, before believing it (`CAMPAIGN-BRIEF.md`'s rule for when the
derivation IS the number): `grep -cE '^  aztec_[A-Za-z0-9_]+: makeEntry\('` also gives **68**, while
`grep -c '^  [A-Za-z0-9_]*:'` over the whole file gives **70** — the two extra are interface members
below the object, which is precisely why the structural parse is the one that counts.

**And RI-65's parallel-subdirectory trap is real and still on disk.** The checked-out
`upstream/tsavm` worktree's copy of `oracle_registry.ts` declares **53**, and does not carry
`acir_callback.ts` or `legacy_oracle_registry.ts` at all. Vendoring from the worktree that happens
to be checked out — the way RI-25 vendored the simulator files — would have shipped a 53-oracle
surface against 68-oracle bytecode.

## Step 2 — THE ENUMERATION, BEFORE A LINE WAS WRITTEN, WITH M33'S WALKER

`verification/_m35_closure.py` is twenty lines that import `_m33_closure.py` and add five GROUPS.
The resolver, the type-erasure rule, the residue categories and the dynamic-import census are all
M33's; a second walker would be a second answer to one question.

| group | files | lines | reaches a DD-9 package |
|---|---|---|---|
| `simulator` — `simulator/src/private/acvm_wasm.ts`, RI-64's WASMSimulator | 89 | 10,174 | no |
| `oraclewire` — `pxe/.../oracle/acir_callback.ts`, the wire layer M35 vendors | 409 | 44,205 | **`@aztec/simulator`** |
| `privhandler` — upstream's own handler for the 16 `prv` oracles | 502 | 56,444 | **`@aztec/simulator`** |
| `utlhandler` — upstream's own handler for the 49 `utl` oracles | 498 | 55,399 | **`@aztec/simulator`** |
| `cfsim` — `contract_function_simulator.ts`, the 926-line file RI-65 names | 516 | 58,284 | **`@aztec/simulator`** |

Zero `UNCLASSIFIED`, zero `UNPLACEABLE` in all five.

**Those are BUNDLER closures and they are not the vendoring bill.** The vendoring bill is the
RELATIVE closure — `_import_closure.py`, the first of M33's three derivations — because everything
the walk reaches through a workspace-package edge is `@aztec/foundation`, `@aztec/stdlib` and
`@aztec/constants`, which `orchestration/package.json` already declares. Both figures are stated
because they answer different questions, which is M33's own §1 discipline:

| what | files | lines |
|---|---|---|
| `acvm_wasm.ts` alone — **RI-64's own figure, reproduced to the unit** | **6** | **711** |
| `@aztec/simulator/client`, the whole entry point | **13** | **923** |
| `acir_callback.ts` — the oracle wire layer | **36** | **3,947** |
| …vendored as, because `transient_array_service.ts` is taken too | **37** | **4,038** |
| what M35 vendors | **50** | **4,961** |

### RI-64's identity claim is true of the six files it measured and false one file wider

RI-64 records that the `cpp` anchor's blobs "are identical to the `ts` anchor's". Re-measured
blob-by-blob over the THIRTEEN-file `client.ts` closure: twelve are `SAME` and **`client.ts` itself
DIFFERS** — at the `ts` anchor it also re-exports `SimulatorRecorderWrapper` and
`MemoryCircuitRecorder`, and at the `cpp` anchor it is four lines and does not. So the identity
holds exactly as far as it was enumerated, and the `cpp` anchor is the better one to vendor from for
a measured reason rather than only because the deliverable says so: **its closure is strictly
smaller.** ("An absence — or an identity — is only as wide as the spellings you enumerated.")

### The one DD-9 edge, and why no vendored byte is edited to sever it

`oracle_registry.ts:5` is `import { toACVMField } from '@aztec/simulator/client'` — a VALUE edge,
so type erasure does not remove it, and `@aztec/simulator` is the package whose hard dependencies
are `@aztec/native` and `@aztec/world-state`. `acir_callback.ts:1` and `oracle_type_mappings.ts:21`
take `ACIRCallback` / `ACVMField` from the same specifier as `import type`, and those two ARE
erased. The remedy is to vendor that entry point's own 13-file closure and alias the specifier in
the build's existing shim table, so the vendored bytes stay `local-edits: none` and `check-drift`
compares them against the anchor unchanged.

`@aztec/kv-store` appears once, in `fact_store.ts`, as `import type` — which is why the bundler
closure names it nowhere and the relative closure does.

## Step 3 — WHAT WAS VENDORED, AND WHAT IT MOVED

- `browser/src/vendor/simulator/` — 13 files / 923 lines, `yarn-project/simulator/src` @ `cpp`.
  **PROVENANCE.md V10, RI-64.**
- `browser/src/vendor/pxe/` — 36 files / 3,947 lines, `yarn-project/pxe/src` @ `cpp`.
  **PROVENANCE.md V11, RI-97** (new entry; RI-96 was the last used).

All 49 byte-identical to the anchor with only the generated provenance header added:
`just check-drift` reports **630** identical against a previous 581, and the two new tree rows take
it **22 -> 24** (one `tracked file count matches` assertion each).

*(CORRECTED BY M35'S REVIEW, because this step's figures are the state BEFORE
`transient_array_service.ts` was taken and were never brought forward. The pxe tree ships as **37**
files, the two trees as **50**, and `just check-drift` re-run by the review reports **631** identical
— 581 + 50 — not 630. `PROVENANCE.md` V11, `PRIVATE-EXECUTION.md` §2 and the `check-drift` row are
all right; only this paragraph was stale, and nothing re-derives it because it is a scratchpad. Left
in place with the correction beside it rather than silently re-typed.)* `verify_provenance_complete`
goes **68 -> 70**: tree rows add no per-file assertion, and the +2 is one per inventory id no row
had cited before — RI-64 and RI-97, exact in both parts.

`@aztec/noir-acvm_js@5.0.0-nightly.20260626` installed into `orchestration/package.json`, which is
already a `deletion_era` consumer, so `verify_pinned_nightly_single_source` stays **28**.
`verify_reuse_inventory_complete` stays **19** (its entry count is a `>=`).

**`verify_orchestration_reuse_enumerated` (M18) went red first, and that is the pin working.** It
compares the orchestration's dependency list EXACTLY — the property M33 met one milestone earlier —
and the list is six now. Updated with the reason recorded in the check itself; the count is
**unchanged at 66**, which is what says a pinned list moved and not a structure.

**And one false citation was corrected where it is written.** `orchestration/package.json`'s own
note said `@aztec/wallet-sdk` is "REUSE-INVENTORY.md RI-86 and RI-87". Those two ids are L0's; the
wallet-sdk entries were renumbered to **RI-88** and **RI-90** when the parallel track landed first,
and M33's note kept the pre-renumber numbers. Corrected in the file that carries the sentence.

## Step 4 — THE SPIKE THAT DECIDED THE SCOPE, and it was worth an hour

Before writing a handler, I asked the ACVM what a real private function actually calls. The
instrument is twenty lines: `executeCircuitWithReturnWitness` over the artifact's ACIR with a
foreign-call handler that RECORDS and then throws.

**Three findings, in order, and each one moved the plan.**

1. **`aztec_misc_assertCompatibleOracleVersion` is the first oracle every private function calls**,
   and its two arguments are the version. Measured: the `deletion_era` Token artifact declares
   **30.0** and the `current` one declares **30.8**, against the anchor's environment of **30.8**.
   Same major, so both are servable, and the minors DIFFER — which is what makes the deliverable's
   `environment minor >= contract minor` a comparison rather than an identity.
2. **A witness padded beyond the parameters is `Cannot satisfy constraint`.** My first spike set
   4,000 witness indices to zero and read the failure as a property of the circuit. It is a property
   of the harness: extra witnesses FORCE values the solver has to compute. Written into
   `private_execution.ts`'s header rather than remembered.
3. **With a real `PrivateContextInputs` and only the parameters,
   `OracleVersionCheck.private_function` runs to completion on FOUR oracle calls**, all of them
   in-memory. And `Token.transfer`, `Token.mint_to_private` and `PrivateVoting.cast_vote` all stop at
   the SAME oracle: `aztec_utl_getContractInstance`.

That third measurement is the whole scope decision. Tier 1 is enough for a real private function to
execute; tier 2's first rung is one named oracle away; and the ladder is a measurement rather than a
plan.

## Step 5 — WHAT WAS WRITTEN, AND THE THREE ANCHOR-VERSUS-PIN GAPS IT COST

| file | what it is |
|---|---|
| `browser/src/wallet/private_oracles.ts` | the 68-method handler: 33 served, 35 refusing BY NAME with a reason each, an ordered ledger that records refusals as well as servings, and a construction-time guard that reconciles the declared partition with the object that answers |
| `browser/src/wallet/private_execution.ts` | one ACIR frame: `PrivateContextInputs` + args -> `toACVMWitness` -> `WASMSimulator.executeUserCircuit` -> `buildACIRCallback` -> the handler, with the public inputs extracted and the whole `cause` chain reported |
| `browser/src/shims/{foundation_promise,stdlib_messaging,stdlib_aztec_address}.ts` | the three anchor-versus-pin gaps |
| `tools/run_private_execution_arms.mjs` | three arms, ALL IN CHROMIUM |
| `verification/{_m35_oracles,_m35_closure,_m35_doc_figures}.py`, `lib_m35_private.sh` | the instruments |

### THE INSTALLED PIN IS THE AUTHORITY, AND IT DISAGREED THREE TIMES

`CAMPAIGN-BRIEF.md` records this family twice (M23's `AztecNodeDebug`, M34's two zod schemas). M35
met it three times in one file set, and **the third is the first that is not a build failure**:

| symbol | `deletion_era` | `current` | how it surfaced |
|---|---|---|---|
| `allToCompletion` | absent | present | esbuild `No matching export` |
| `computeFeeJuiceMessageNullifier` | absent | present | esbuild `No matching export` |
| `AztecAddress.fromFieldUnsafe` (+3 siblings) | named `fromField` etc. | renamed | **inside the ACVM, at run time** |

A missing STATIC is not a missing export, so the third built cleanly and failed as
`Error awaiting \`foreign_call_handler\`` — eleven words naming nothing — with
`TypeError: U.fromFieldUnsafe is not a function` on `err.cause`. **Reading that cause is why the
executor walks the whole chain now.** The four renames are a rename and not new behaviour: measured
on both sides, `fromField(fr)` and `fromFieldUnsafe(fr)` are the same one-line body.

Each is a shim that re-exports the installed module and adds the one missing thing from upstream's
own source, **scoped to `browser/src/vendor/pxe/`** by an esbuild plugin that fails the build if any
entry matches nothing. All fifty vendored files stay `local-edits: none`.

**And the first comment on that scoping was wrong, which is why it was measured.** It claimed the
unscoped alias cost `browser.js` 2.27 KB. Built both ways: **265.37 KB either way.** The +2.27 is
chunk re-partitioning from M35's added exports — M34's mechanism in the other direction — and the
comment says that now.

## Step 6 — FOUR DEFECTS THE FIRST RUNS FOUND, EACH OF THEM A SHAPE

1. **`fetch failed`, four layers from the cause.** `WASMSimulator.init()` calls wasm-bindgen's
   argument-less init, which resolves `new URL('acvm_js_bg.wasm', import.meta.url)` — after esbuild,
   a chunk path that has never existed. `initPrivateExecution` pre-initialises with explicit URLs and
   there is deliberately **no default**: `PrivateExecutionNotInitialised` names itself where the
   mistake is.
2. **`{ bytecode, ...fn }` put the base64 string back over the decoded Buffer**, and the ACVM said
   *"Failed to deserialize circuit… differing serialization formats"* — a message that points at the
   compiler.
3. **`instanceof` is per-realm.** A probe passing an `Fr` built from `orchestration/node_modules` into
   the BUNDLE's `TxContext.empty` got `Type 'object' with value '0x…7a69' passed to BaseField ctor`.
   The request normalises `FieldLike`/`AddressLike` now, with its own refusal.
4. **THE NEEDLE CAME FROM MY MEMORY AND NOT FROM THE ARTEFACT.** `EPHEMERAL_RETURN_ORACLES` matched
   `ephemeral_array`; the mapping spells it `ephemeral-array(` with a HYPHEN, and the count was
   **zero**. This campaign's oldest needle defect, in the direction that reads as good news, caught
   because the arm PRINTS the matched labels beside the count.

And one in the check rather than the subject: a first draft counted the handler's methods with
`filter(k => !k.startsWith('is'))`, which drops the three scope markers **and**
`isNullifierPending` and `isExecutionInRevertiblePhase`, reporting 66 for a handler carrying 68 plus
3. A needle that is too wide reads as a subject two methods short.

## Step 7 — THE MEASUREMENT THAT DECIDED FOUR REFUSALS

`EphemeralArray.materializeSlot` calls `EphemeralArrayService.newArray` -> `allocateSlot`, which is
`do { slot = Fr.random(); } while (…)`. **Eight oracles return an `EphemeralArray`**, so serialising
any of their returns reads ambient entropy — and a recording made through one does not replay. That
is the first place in this campaign where upstream's own code sits on the other side of a property
this wallet declares, and it is why the four `fact` oracles refuse with a measurement rather than a
plan.

The count is derived twice and the two disagree **by design**: the label derivation sees 8 and the
outermost-`returnType` derivation over the anchor's source sees 7. The check asserts the SUBSET
relation and NAMES the residue — `aztec_utl_getFactCollection`, whose array is inside an `Option`.

## Step 8 — THE CHECKS AS FIRST DELIVERED: M35 = 180 (60 / 69 / 51), 3/3, exit 0

*(These are the counts BEFORE the three aborts of Step 11–12, which took them to 64 / 83 / 51 = 198.
The table is left at its delivered values and labelled, rather than silently re-typed: M34's review
found its own mutation table quoting pre-review counts in three rows, and the remedy is to say which
measurement a number is rather than to keep one number current.)*

| check | assertions | what it is about |
|---|---|---|
| `verify_oracle_coverage_is_measured` | **60** | 68 re-derived four ways with the 53-entry worktree as the control; the partition disjoint, summing, union-as-a-set; every implemented oracle EXERCISED; the oracle version; the ephemeral measurement; and `PRIVATE-EXECUTION.md`'s 27 figures |
| `test_unimplemented_oracle_refuses_by_name` | **69** | every refusal names itself, three ways, the third being 76,875 bytes of real ACIR |
| `e2e_private_function_executes_in_browser` | **51** | a private circuit solving in Chromium, and 4.4 MB fetched only when asked for |

**A FIFTH VERIFICATION ENTRY WAS ADDED AND TWO OF THE PLANNED FOUR REMAIN PENDING.** M35's plan names
`e2e_wallet_private_transfer` and `e2e_joined_private_public_trace`; neither can pass, because
`transfer` stops at `aztec_utl_getContractInstance`. Writing a check that passed over a lesser subject
would be the thing this campaign refuses. `e2e_private_function_executes_in_browser` owns what WAS
delivered.

## Step 9 — THE MUTATION MATRIX: nine arms, and three of them were the wrong shape first

`scratchpad/campaign/m35-mutations.sh`. M34's harness, subject changed; `still_there` failing
restores, verifies and **exits 5**, demonstrated in a sandbox both ways (`EXIT=5` on the undone case).

| arm | mutation | result | the failures, read |
|---|---|---|---|
| M1 | an unimplemented oracle returns instead of refusing | **69 / 4** | all 35 `RESOLVED`; none names itself; none says what it does not serve; **and the real ACIR frame stops being a refusal** and dies four layers down on `Cannot read properties of undefined (reading 'salt')` — which is the plausible default's whole cost, measured |
| M2 | the ledger records a version the bytecode did not declare | **60 / 2** | §6's contract version, and §8's document figure |
| M3 | `getRandomField` reads ambient entropy | **69 / 1** | the same-seed identity, and nothing else |
| M4 | a declared-implemented oracle stops being exercised | **60 / 4** | §5's three exercised assertions and §8's figure |
| M5 | one registry oracle falls out of the surface, consistently | **60 / 7** | the total, the handler-method count, the sum, the union-as-a-set, the uncovered name, the reason count, §8 |
| M6 | the refusal throws without naming the oracle | **69 / 1** | `namesItself`, and nothing else |
| M7 | **THE HANG** — the renderer never returns | **0 / 1 with a summary line** | bounded and NAMED: *"Runtime.evaluate did not complete within 60000 ms. That is the HANG state reported as a failure."* |
| M8 | **DIE BEFORE THE SUMMARY** — the arm report is hollowed | **1 / 2 with a summary line**, and **M8 held** | `m35_absent` names every absent field in ONE assertion and dies |
| M9 | a figure in `PRIVATE-EXECUTION.md` is made stale | **60 / 1** | §8 names the figure AND the row |

**THREE ARMS WERE THE WRONG SHAPE AND THE REWRITES ARE THE FINDING.**

- **M3 used `Date.now()` and did not fire — 69 / 0.** Eight poseidon2 calls through `avm.wasm` take
  well under a millisecond, so both draws landed in the same tick and the two seeds still agreed. A
  clock is the wrong ambient source for this mutation *because it is coarse*.
- **M5's first version never reached the check.** Adding a refused oracle to the implemented list
  trips `assertOracleSurfaceMatchesDeclaration` at CONSTRUCTION, so the page arm threw, the arm run
  exited 1, and the check died at its precondition with **0 assertion(s), 1 failure(s)** — M34's own
  M5, one milestone later. The guard being unfalsifiable from outside is the right outcome for the
  guard and the wrong shape for an arm, so the arm moved to the property the guard cannot see: an
  oracle falling out of the surface with every internal consistency check still agreeing.
- **M7 took three shapes before it was a hang.** A 404 answers in milliseconds; a promise that never
  settles is collected by V8 and CDP answers `Promise was collected` in seconds. Both produce
  `0 / 1` — the shape a hang produces — and only the log said which. A hang has to be a renderer that
  does not return.

**And the hang arm improved the library rather than only reporting.** The `die` said "exited 1" while
the kept report carried the bound and the state; `m35_require_arms` puts the report's own message into
the diagnostic now, and names a `timeout` exit (124/137) as a HANG with its bound.

## Step 10 — WHAT M35 MOVED ELSEWHERE, and every unit of it is accounted for

- **M28 353 -> 357.** `verify_browser_bundle_no_node_builtins` 64 -> **67** and
  `verify_browser_bundle_no_native_deps` 44 -> **45**. The external-edge assertion was a COUNT
  (`exactly one`) and M35's vendored files add six elided `import type` edges; a count would have to
  be bumped and would say nothing, so it is a named SET now, with a non-emptiness assertion on the
  emitted bytes it scans and a DD-9 membership test over the set. `just ci-browser-gate` stays
  **104**, `verify_npm_pack_no_optional_native` stays **54**, and the one failing assertion there is
  still L0's `replay/package.json`.
- **M33 246 -> 248.** `verify_provider_half_dd9_clean` 106 -> **108**: the orchestration's dependency
  pin moved to six and the reason is re-derived OFFLINE from `orchestration/package-lock.json` — the
  ACVM's dependency list is empty, with `@aztec/aztec.js`'s non-empty one as the control that the
  reader can answer both ways. **And its control build was failing outright**, because the CLI
  invocation had none of M35's four new resolutions; a control that cannot run is worse than one that
  cannot fail.
- **M27 345, M32 237, M34 217 — unchanged counts, moved FIGURES.** Twelve document figures in five
  documents, every one caught by the check that re-derives it: `BROWSER-PACKAGING.md` §1's three
  eager rows and its total, `BROWSER-GATE.md`'s two, `WORKER-NODE.md` §5's seven-row table (a new
  column), `WALLET-BOUNDARY.md` §6's three and `DEV-WALLET.md` §6's two.
- **Two budget bumps, recorded as data**: the wallet entry 300 -> 340 KB and the wallet demo
  340 -> 380 KB, each with a `bumps` entry naming what grew. **The zero DD-11 rests on did not
  move.**
- **`check-drift` 22 -> 24** (two tree rows) and **`verify_provenance_complete` 68 -> 70** (two
  inventory ids no row had cited). `verify_pinned_nightly_single_source` **28**,
  `verify_no_pipeline_predicates` **69**, `verify_named_checks_exist` **9**,
  `verify_reuse_inventory_complete` **19**, `just check-repo-hygiene` **28** — all unmoved.

**AND `verify_no_pipeline_predicates` WENT RED ONCE, IN MY OWN WORK.** A `grep … | grep -q .` I wrote
into `verify_browser_bundle_no_node_builtins` took the pinned census from five to six. Replaced with
`lib.sh`'s `str_has_sub` over a variable, which is the remedy that check exists to enforce, and with
a non-emptiness assertion on the bytes it reads.

## Step 11 — A SELF-REVIEW BEFORE THE SWEEP FOUND FOUR VALIDATIONS MISSING, AND THE SWEEP WAS RESTARTED TWICE

The first sweep was killed twenty-five minutes in and the second fifteen, both deliberately, and both
for the rule rather than for a finding: *"run your sweep after your last edit."*

**THE FIRST ABORT — a figure nobody re-derived, in the document written to record this milestone's
own vendoring.** `PRIVATE-EXECUTION.md` §2's last row said **50 files / 4,870 lines**. The file count
was right; the line count is 923 + 3,947, which is the 36-file relative CLOSURE, on a row stating
that 37 files are vendored — the two differ by `transient_array_service.ts`. The true figure is
**4,961**. Nothing would have found it, because the comparer compared the FILE count of that row and
left the line count alone. All eight figures of §2's table are derived now: three closure rows from
`_import_closure.py` over the materialised anchor, and the total from the TRACKED tree measured
against the anchor's own blobs, with a vendored file whose upstream path does not resolve REPORTED
rather than counted as zero lines. `verify_oracle_coverage_is_measured` 60 -> **62**, and the figures
it compares 27 -> **34**.

**THE SECOND ABORT — four validations that are upstream's and were not here.** A read of upstream's
own handler bodies against mine, done while the sweep ran, found four places where this handler was
MORE PERMISSIVE than upstream's, and in every one of them the permissive version is not visibly wrong
afterwards:

| what | upstream | what mine did | why it matters |
|---|---|---|---|
| an OVERLAPPING capsule copy | reverses the index order when `srcSlot < dstSlot` | copied forward always | slots 10..12 holding 1,2,3 copied three-wide to 11 leave **1,1,1** instead of 1,2,3, and the store reads back cleanly either way |
| a duplicate siloed nullifier | `#recordNullifier` THROWS | added it to a `Set` | `Set.add` of an existing member is a no-op — a double-spend within one transaction, waved through the only layer that can see it |
| consuming a note nobody created | `nullifyNote` throws *"Attempt to remove a pending note that does not exist."* | recorded it | the fabricated-note shape, arriving from the other direction |
| the calldata cap | throws past `MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS` | looked the calldata up and asserted nothing | an oracle NAMED `assertValid…` that validates nothing |

All four are implemented and all four are exercised **with their negative case**, so "served" means
"answers, and refuses what upstream refuses". `test_unimplemented_oracle_refuses_by_name` 69 -> **76**;
the cap is compared against `@aztec/constants`' own value rather than a number typed in the check.

*This is the difference between "the handler has a method for every oracle" and "the handler is a
handler". The coverage check could not have found it: the partition was already disjoint, summing and
fully exercised, and all four oracles were already answering.*

**M35 = 189 (62 / 76 / 51).** The reference table names it, plus M1 179 -> 181, M28 353 -> 357 and
M33 246 -> 248, before the sweep runs.

## Step 12 — A THIRD ABORT, AND IT FOUND THE HALF OF DELIVERABLE 4 NOTHING WAS FEEDING

The third sweep was killed five minutes in, for a read of upstream's own handler that turned up a
hook this one was leaving empty.

**`buildACIRCallback` wraps its dispatch table in a Proxy**, and the trap fires when the BYTECODE
calls an oracle name the registry does not declare — which is the other half of *"a bytecode/oracle
mismatch is loud"*, the half `assertCompatibleOracleVersion` cannot cover. The trap picks between
three diagnostics on `'nonOracleFunctionGetContractOracleVersion' in handler`, and without that
method it takes the FIRST: *"the contract's oracle version is unknown (the version check oracle was
not called before …). This usually means the contract was not compiled with the `#[aztec]` macro."*
Over a contract that called the version oracle first — as every `#[aztec]` contract does — and whose
version this handler had been holding since. **A wrong explanation is worse than none, and worse in
this campaign's own way: it names a cause the reader will go and check.**

The hook is fed now, and it is exercised through the REAL callback rather than through the handler,
because the trap is the callback's. §3b asserts the diagnostic NAMES the undeclared name, does NOT
claim the version is unknown, does NOT blame the macro, and DOES carry the environment's version —
which only the fed hook can produce. `test_unimplemented_oracle_refuses_by_name` 76 -> **83**.

**And its control was M34's finding in a second place.** A first version used
`aztec_utl_getNotes` as the "a declared oracle reaches through" control and got a `TypeError`:
`entry.deserializeParams` rejects the SLOT COUNT before the handler is reached, so the control
measured upstream's codec rather than this handler's refusal. That is M34's refusals arm exactly,
where all six "refusals" turned out to be `parseWithOptionals`. The control calls
`aztec_prv_getSenderForTags`, which declares no params, so no-argument IS its wire.

### THREE ROUNDS OF BISECTING THE MODULE GRAPH FOR FIVE LINES OF LOCAL ORDERING

Attaching the hook produced `ReferenceError: Cannot access 'G' before initialization` in the page,
inside a minified chunk, with a stack naming `armPrivateExecution` and nothing else. Three
hypotheses were tried and all three were wrong: re-exporting the callback from `entry_wallet.ts`,
wrapping it in `private_oracles.ts`, importing it directly in the demo. **The cause was that
`handler.nonOracleFunctionGetContractOracleVersion = …` had been inserted three lines ABOVE the
`const handler` declaration** — a temporal dead zone in one function, not a cycle in a graph.

Recorded because the minified stack pointed at the module graph and the defect was in five lines of
local ordering, and because the bisect that found it was to remove the change rather than to reason
about it.

## Step 13 — THE COUNTS AFTER THREE ABORTS

**M35 = 198 (64 / 83 / 51).** The three aborts moved it 180 -> 182 -> 189 -> 198, and every step is
itemised above: +2 for the vendoring table's line counts, +7 for the four upstream validations, +9
for the unknown-oracle diagnostic and the non-oracle method counted separately.

The neighbours, re-measured after the last build: `verify_browser_chunk_budget` **33**,
`test_worker_transferable_container_not_copied` **74**, `verify_provider_half_dd9_clean` **108**,
`e2e_wallet_public_transfer` **83**, `just ci-browser-gate` **104**,
`verify_browser_bundle_no_node_builtins` **67**, `verify_browser_bundle_no_native_deps` **45**,
`verify_browser_entry_points_are_dd5_shaped` **40**, `verify_browser_bundle_builds` **54**,
`verify_no_pipeline_predicates` **69**, `verify_named_checks_exist` **9**,
`verify_provenance_complete` **70**, `verify_reuse_inventory_complete` **19**, `check-drift` **24**,
`check-repo-hygiene` **28**, `verify_pinned_nightly_single_source` **28**.

**Every source edit moved the eager sets by hundredths of a kilobyte** — a comment does not survive
minification but a statement does — and every one of them was caught by the check that re-derives
it, in five documents, on every round. That is the argument for writing them that way, made four
times in one milestone.

## Step 14 — ONE OBSERVATION LEFT STANDING, WITH ITS MITIGATION

`e2e_private_function_executes_in_browser` §3 compares the circuit's own
`publicInputs.contractAddress` against the literal
`0x0000000000000000000000000000000000000000000000000000000000000777`, and `wallet_main.ts` types
`0x777n` in two places. That is a constant typed into a check over a value that also exists in the
thing under test — the family `CAMPAIGN-BRIEF.md` records as *"a constant you have just typed into a
check looks like a measurement to the person typing it."*

**It is the lesser form of that family and it is left rather than fixed, for two reasons.** First,
the direction: if the demo's address moves, this assertion goes RED — a failed equality naming both
sides — rather than silently green, which is the opposite of M34's finding 7, where a stale literal
turned a green check into a `die`. Second, the assertion it stands next to is a real two-producer
cross-check that does not depend on it: `returnsHash` is a value the CIRCUIT computed into its public
inputs and is compared against the hash the circuit's own `setHashPreimage` call carried, so the
section's substance survives the observation.

**The stronger form, for whoever takes it:** have the arm report the address it REQUESTED, and
compare the circuit's ECHO against the request. Two different producers out of one run, which is
what the neighbouring assertion already does for the hash.

*(Grepped rather than remembered: those are the only two typed hex literals in M35's three checks,
and the other — `!= 0x000…0` on `returnsHash` — is a non-degeneracy guard rather than a
measurement.)*

## Step 15 — THE SWEEP: M0–M35 at 11,730, delta +0, no hole

Measured 2026-08-30 after the last edit, `setsid`-detached in this repository's own dev shell
(node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`, **72 markers for 36 milestones: no hole**, **34 of 36 exit 0**:

```
m0 156  m1 181  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 198
                                                   CAMPAIGN TOTAL 11,730
```

**Every one of M0–M34 came out at its reference value TO THE ASSERTION**, and
**11,524 + 198 + 4 + 2 + 2 = 11,730** exactly, with the summariser reporting `delta +0` against a
reference table naming all four moves in advance — M35's own 198, M28 353 -> 357, M33 246 -> 248 and
M1 179 -> 181.

**M9 did NOT flake** — 807, rc 0, 1,282 s, immediately after m8's 175 s run, which is D19's standing
condition and it did not fire. **M15 did not flake either** (537, 382 s).

### The two non-zero exits, and neither is this milestone's

- **M11 = 262 with NINE failing assertions**, split **5 / 2 / 2** across
  `verify_carry_set_applies_to_upstream_head`, `verify_carry_ledger_complete` and
  `verify_carry_exposure_measured` — the recorded ninth-upstream-move signature, count unchanged.
  Not repaired; `carry/` left at HEAD.
- **M28 = 357 with ONE failing assertion AND IT IS L0'S.** `verify_npm_pack_no_optional_native` pins
  the tracked `package.json` list EXACTLY and `replay/package.json` is a fifth tree. The COUNT is
  unchanged by that failure, which is what says it is a pinned list and not a structure. Recorded
  and deliberately NOT fixed, for the third milestone running.

### L0's and L1's contribution is ZERO, and it is a measurement

Their six check names — `verify_node_client_surface_narrow`,
`test_node_client_refusals_distinguishable`, `verify_client_uses_upstream_schema`,
`e2e_fetch_settled_transaction`, `test_missing_contract_artifact_refused`,
`test_private_half_declared_absent` — appear **zero times in the whole sweep log**, grepped one at a
time. They live in `just verify-l0` and `just verify-l1`, which no `verify-m<N>` recipe invokes.

### A sweep is a writer

`carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` / `ec959b84…` before, came out
`79f597b2…` / `3836c2b6…` — the same two post-sweep digests every run since M30 has recorded — and
were restored from HEAD, confirmed by `sha256sum -c`, both OK, `git status carry/` clean.

### THE SWEEP WAS ABORTED THREE TIMES ON PURPOSE, WHICH IS THE RULE WORKING THREE TIMES

Twenty-five minutes, fifteen minutes and five minutes in. None of the three was a finding about the
sweep; all three were *"run your sweep after your last edit"*, and each abort bought a defect:
a document figure nobody re-derived (§2's line count), four validations that are upstream's and were
not here, and the half of deliverable 4 that nothing was feeding. The aborted logs are kept at
`~/.cache/aztec-m35-sweep-aborted.log` and `~/.cache/aztec-m35-sweep-aborted2.log`.

*Every one of the three was found by READING upstream's own code against this handler while the sweep
ran, which is the only work available during one.*

## Step 16 — THE POST-SWEEP EDITS, NAMED, AND WHY THEY CANNOT MOVE THE TOTAL

Four documents were written after the sweep because they carry the sweep's own numbers:
`CAMPAIGN-BRIEF.md`'s sweep paragraph, this log's Steps 14–16, the milestone section's sweep and
abort blocks, and the milestone file's Document header. **Neither `CAMPAIGN-BRIEF.md` nor this log is
opened by any check** — `CAMPAIGN-BRIEF.md` appears in `verification/` only inside error-message
strings, never as a path a check reads. **The milestone file IS read**, by
`verify_fallback_triggers_recorded_and_evaluated`, so **m16 was re-run after each edit to it: 223,
2/2, exit 0 both times** — its reference value to the assertion. `just verify-m35` re-run after the
last of them: **198, 3/3, exit 0.**

### AND THE DOCUMENT HEADER WAS THREE MILESTONES STALE

`:current_milestone:`, `:next_steps:` and `:executive_summary:` all said **M32**. M33, M34 and M35's
first draft each updated their own section and left the header, so the one field a reader looks at
first had been wrong since the M29–M36 extension's fourth milestone. Corrected, and **recorded in the
field itself rather than silently fixed**: that is the "prose drifts from measurement" family, and
the remedy this campaign keeps writing down is that a correction filed silently is a correction
nobody can date.

## Final state

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `d24ac569` (== `origin/dev`) | 21 modified, 51 added-not-committed, 17 untracked, **no commit** |
| `codetracer-specs` | `latest` | `10e66f4c` | `Planned-Work/Aztec-AVM-Runtime.milestones.org` modified, **no commit** |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | its one pre-existing edit, **untouched** |

No commits, no pushes. `carry/` at its pre-sweep digests, `git status carry/` clean. `origin/dev`
was fetched at the start, before each of the three sweep launches and after the last one, and did not
move: **`HEAD == origin/dev` throughout, zero ahead, zero behind.**
