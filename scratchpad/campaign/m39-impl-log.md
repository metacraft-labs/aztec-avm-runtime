# M39 — End-to-End Joined Transaction Tracing — implementation log

## Step 0 — orientation (started)

Reading, in order: CAMPAIGN-BRIEF.md (full), PRIVATE-TRACE.md, JOIN-SHAPE.md,
PRIVATE-EXECUTION.md, LOCAL-HISTORY.md, m38-impl-log.md, the M35/M26/M38 milestone
sections, OUT-OF-SCOPE.md.

State at start:
- noir @ codetracer HEAD 7c40098a1, clean.

## Step 0 — orientation (done for the primary docs)

Read: PRIVATE-TRACE.md (M38), JOIN-SHAPE.md (M26/OQ-7), PRIVATE-EXECUTION.md (M35),
LOCAL-HISTORY.md (M36), m38-impl-log.md, OUT-OF-SCOPE.md, the M26/M35/M38 milestone
sections, and CAMPAIGN-BRIEF.md lines 1..1850 (continuing).

### Measured state at start (2026-09-01)

| subject | measurement |
|---|---|
| `aztec-avm-runtime` branch | `dev`, at `origin/dev` `c329c72`, clean but for this log |
| `noir` branch | `codetracer`, `7c40098a1`, clean |
| `noir-wt4-webpage` HEAD | `f0e7edcd2`, ONE edit (`tooling/tracer/src/tracer_glue.rs`) |
| `noir-wt4-webpage` published refs containing HEAD | **0** |
| `verify-m` / `verify-l` processes | **0** |
| load average | 0.53 |

### The three blockers, restated from the docs

1. tier 4 `aztec_prv_callPrivateFunction` refuses -> private half = one FRAME, not a TRANSACTION.
2. M38's step stream is the NATIVE tracer replaying a tape; `ct_writer`/`CtWriter` in
   `browser/src/wallet/` measures **0**.
3. `e2e_form_b_single_ct_recording` wants ONE container -> needs the shared writer OQ-7 ruled
   unshippable on facts 6 and 7. NOT to be reopened.

Two enumeration agents launched: (a) tier-4 requirements, (b) browser-path survey.

## Step 1 — structural measurements taken while the enumeration agents run

### 1a. The two Noir trees each have HALF of what a browser private stepper needs

| | `noir` (`codetracer`, editable) | `noir-wt4-webpage` (`f0e7edcd2`, read-only) |
|---|---|---|
| M38's `trace_circuit_with_executor` / `TracingContext::with_executor` | **yes** | **no** |
| `tooling/tracer_wasm/src/ctfs_sink.rs` (Path A `.ct` writer in wasm) | **no** | **yes** |
| `codetracer_trace_writer_rs` workspace alias | **no** (`Cargo.toml` has only the nim alias, line 181) | **yes** (`Cargo.toml:203`) |
| `tooling/tracer_wasm/src/` | `lib.rs` (238) + `memory_sink.rs` (309) | `compile.rs` (161) + `ctfs_sink.rs` (334) + `lib.rs` (476) + `memory_sink.rs` (254) |
| `trace_source_to_container` export | **absent** | present |

`diff` of `tooling/tracer/src/lib.rs` between the two trees: **227 lines**, and the delta is
M38's three changes.

**So neither tree can both (a) answer an Aztec oracle and (b) write a `.ct` container from
wasm.** This is OQ-7 facts 6/7 one level down, and it is measured rather than assumed.

### 1b. The nested-call fixture EXISTS and is upstream's own, and it is minimal

`aztec-packages/noir-projects/labs/noir-contracts/contracts/test/parent_contract/src/main.nr:10-14`

```
#[external("private")]
fn entry_point(target_contract: AztecAddress, target_selector: FunctionSelector) -> Field {
    self.context.call_private_function(target_contract, target_selector, [0]).get_preimage()
}
```

and `child_contract/src/main.nr:25-28`

```
#[external("private")]
fn value(input: Field) -> Field { input + self.context.chain_id() + self.context.version() }
```

`Child.value` touches NO notes, NO tagging, NO storage — the minimal callee.
Both artifacts are on disk: `*/node_modules/@aztec/noir-test-contracts.js/artifacts/parent_contract-Parent.json`
and `child_contract-Child.json` (102 artifacts in that directory).

**And `Parent.enqueue_calls_to_child_with_nested_first` (main.nr:54-63) is the END-TO-END SHAPE
ITSELF**: a nested private call AND an enqueued public call, in one transaction.

### 1c. WHERE THE COLUMNS LIVE, AND IT DECIDES THE BROWSER DESIGN

M39's success sentence says both halves must step **with columns**. Measured, in two files:

- `noir/tooling/tracer_wasm/src/memory_sink.rs` header:
  *"`register_step_with_column` **drops the column**, because the `StepRecord` in
  `codetracer_trace_types` carries only `(path_id, line)`. The pure-Rust writer drops it at the
  same place and for the same reason; only the Nim writer's `DeltaColumn` follow-up event
  preserves it."*
  So Path A in Rust loses columns, and that is why M38's container (Path B, Nim, native) has them.
- `aztec-avm-runtime/ct-writer/src/lib.rs:1056-1065` — the RUNTIME's own Path A writer, the one
  already in the page, **honours** a column: `ct_ingest` stages `(path_id, line, column)` and calls
  `TraceWriter::register_step_with_column`, and `lib.rs:55` records that `want_columns` is
  **HONOURED** at the current `trace_format` anchor (`dropped_column_awareness()` is `false`).

**So the column is lost in the wasm SINK, not in the Path A writer.** `memory_sink.rs` already
carries `line_lengths` alongside the event stream for exactly this class of reason ("nothing in the
low-level event stream carries them, so they are kept alongside"). A per-step column side channel
is the same remedy for the same cause, in the same file — and it is a change to `noir`, which the
standing rules permit.

That makes a browser private half possible WITHOUT touching `wasm/webpage`: the tracer emits, the
page's already-shipped `ct_writer.wasm` writes. The Noir tracer links no writer at all on that
path, so OQ-7 facts 6 and 7 are untouched — this is a different answer to the same need rather than
the answer OQ-7 ruled out.

### 1d. THE PUBLISHED TREE'S TRACER **DOES** BUILD FOR wasm32, AND IT IS A QUARTER THE SIZE

Measured, not assumed. `cd noir/tooling/tracer_wasm && cargo build --release --no-default-features`
under `nix shell nixpkgs#rustup nixpkgs#capnproto` with M24's `CARGO_HOME`/`RUSTUP_HOME`
(the same invocation `verification/build_noir_tracer_wasm.sh` uses for the OTHER tree):

| | `noir` (`codetracer`, PUBLISHED) | `noir-wt4-webpage` (unpublished) |
|---|---|---|
| builds for `wasm32-unknown-unknown` | **yes, 1 m 01 s** | yes |
| module bytes | **4,619,384** | 16,981,xxx (M30's, on disk) |
| carries M38's executor seam | **yes** | no |
| writes a `.ct` container inside the module | no (memory sink) | yes (`ctfs_sink`) |

`--no-default-features` drops the wasm-bindgen glue, so the module is import-free and the
`extern "C"` surface (`ct_alloc`/`ct_free`/`ct_trace`/`ct_result_len`/`ct_result_is_error`) is what
a page calls — the same shape M30's page already drives.

**So the browser private stepper does not need the unpublished worktree.** It needs
(a) the executor seam, which `noir` has; (b) a column side channel out of the memory sink, which
is a small change to `noir`; and (c) the page's own `ct_writer.wasm`, which is already there and
already honours columns.

## STEP 2 — THE TIER-4 ENUMERATION, WHICH IS THE FIRST DELIVERABLE AND IS A NUMBER

**Serving `aztec_prv_callPrivateFunction` in this runtime needs 29 distinct things. 5 already
exist. 24 do not.** Taken by reading upstream's own `callPrivateFunction`
(`aztec-packages/yarn-project/pxe/src/contract_function_simulator/oracle/private_execution_oracle.ts:645-756`)
against this runtime's `private_oracles.ts` and `private_execution.ts`, one capability at a time,
each with a citation.

| | count |
|---|---|
| distinct requirements | **29** |
| already HAVE | **5** (R1 registry entry, R2 async dispatch, R6 selector derivation, R9 `PrivateContextInputs`, R21 the child's two returned fields) |
| MISSING | **24** |
| — primitive/data in-repo, only plumbing missing | 6 |
| — "share what is currently per-frame" | 6 (R14 execution cache, R15 note cache, R16 revertible phase, R17 calldata counter, R18 capsules, R19 transient arrays) |
| — genuinely new subsystems | **4** (R4 address+selector -> bytecode registry, R5 selector index, R23 nested-result tree + a tree-aware `sealPrivateFrame`, R24 merged ledger/tape) |

**The synchrony/re-entrancy question is STRUCTURALLY OPEN, and this is the deciding citation** —
`browser/src/vendor/pxe/contract_function_simulator/oracle/acir_callback.ts:42-48`:

```ts
target[oracleKey] = async (...inputs: ACVMField[][]) => {
  ...
  const result = await (handler as any)[methodName](...positional);
  return entry.serializeReturn(result);
};
```

Every registry entry is dispatched through an `async` closure that `await`s the handler method, and
the ACVM awaits the promise. **Zero of the 24 are blocked on the execution model.** `await
executePrivateFunction(...)` inside a handler method is legal.

### The three findings inside the enumeration that a plan would not have produced

1. **The execution cache must be shared in BOTH directions, and the second one is the surprise.**
   The child's args preimage was stored by the PARENT (`aztec-nr`'s `private_context.nr:1036-1038`
   does `execution_cache::store(args, args_hash)` before the oracle call) — and the PARENT reads the
   CHILD's return values back, because `ReturnsHash::get_preimage` does `execution_cache::load` in
   the parent's frame over a hash the child stored (`returns_hash.nr:22-33`). A per-frame cache
   therefore throws on the opcode AFTER the nested call returns, not on the call itself.
2. **The ephemeral-array service must be PER-FRAME and today it is shared whenever M36's discovery
   source is attached.** Upstream constructs it fresh in every oracle
   (`utility_execution_oracle.ts:133`) and deliberately does NOT pass it to the child
   (`private_execution_oracle.ts:690-726`); `private_oracles.ts:822` takes
   `discovery?.ephemeral ?? new EphemeralArrayService()`. `EphemeralParent.test_isolation` is
   upstream's own test that this must not happen. So one of the six sharing items points the
   OTHER WAY, and shipping tier 4 without noticing would have made a green nested call that
   violates upstream's isolation rule.
3. **`sealPrivateFrame` is a rewrite, not a loop.** `note_database.ts:521-546` takes ONE contract
   and silos every note hash against it, with nonces indexed off `nullifiers[0]`. A Parent+Child
   transaction needs note hashes siloed against EACH emitting contract with the nonce index over
   the CONCATENATED array.

### The fixture, and it is upstream's own

`Parent.entry_point` -> `Child.value`, both at `aztec_version 5.3.0-nightly.20260819` /
`noir_version 1.0.0-beta.25+75061fab`, **identical to the Token / PrivateVoting /
OracleVersionCheck artifacts the arms already execute**, and both already inside `findUnder`'s
existing search list (present in `drift/`, `spike/`, `diffsim/`).
`Child.value` = `input + chain_id + version`: no notes, no tagging, no storage, no contract
instance of its own — which also makes it the control for R10, because a child that did not
receive the parent's chainId/version returns the wrong field.

## STEP 3 — THE BROWSER PATH, MAPPED, AND THE THREE GAPS NAMED

The page already does the PUBLIC half end to end: `wallet.html` -> `wallet-demo.js` ->
`recordAndDownload` (`browser/src/ct_download.ts:215`) over `ct_writer.wasm`'s C ABI
(`ct-host/src/writer.ts`), with `ExecutedStepCollector` supplying real executed steps and
Chromium's `Browser.setDownloadBehavior` dropping the `.ct` into `~/.cache/aztec-m34-wallet/downloads/`.

The PRIVATE half's stepper is native-only today. The chain is
`wallet.html` in Chromium -> `armPrivateExecution` -> `recordTape` ->
`~/.cache/aztec-m35-private/private-execution.json` -> `run_m38_trace_arms.mjs` -> native
`m38probe` -> `.ct` in `~/.cache/aztec-m38-private-trace/arms/<arm>/`.

Three gaps stand between that and the same page:

1. **The wasm module cannot be given an executor.**
   `noir-wt4-webpage/tooling/tracer_wasm/src/lib.rs:91` calls `trace_circuit` (8 args).
   `trace_circuit_with_executor` is only on `noir` @ `codetracer` (`tooling/tracer/src/lib.rs:491`).
2. **The wasm module has no Aztec-artifact front end that yields a container.** `TraceRequest`
   takes Noir SOURCE and recompiles; `trace_artifact` returns a `MemoryTrace`, not a container.
3. **`build_noir_tracer_wasm.sh` forbids touching `noir-wt4-webpage`** beyond `tracer_glue.rs`,
   on pain of invalidating `JOIN-SHAPE.md` §2 fact 7.

But §1d says gap 3 does not have to be paid: `noir` on `codetracer` builds a 4.6 MB
`noir_tracer_wasm` in 61 s and HAS the executor seam. Gaps 1 and 2 become work in `noir`, which
the standing rules permit, and the container is written by the page's own `ct_writer.wasm` rather
than inside the tracer — so the Noir tracer links no writer on that path at all.

Reusable verbatim: the `[u32 LE len][summary][.ct]` envelope + host shim
(`verification/m30/page/wasm_host.mjs:104-135`), the `TapeExecutor` refusal discipline
(`verification/m38_private_trace_probe.rs:118-139`), the tape (already produced in the same page),
`offerDownload` (`ct_download.ts:441`), and `orchestration/src/trace_join.ts`.

## STEP 4 — THE RED, MEASURED IN CHROMIUM BEFORE ANY TIER-4 CODE

`tools/run_m39_nested_arms.mjs` + `armNestedPrivateCall` in `browser/demo/wallet_main.ts`.
Chromium 150.0.7871.128, the built wallet bundle, upstream's `WASMSimulator` over real ACIR.

`Parent.entry_point(childAddress, childSelector)` — **6,979 bytes of ACIR, 2 argument fields**:

| seq | oracle | outcome |
|---|---|---|
| 0 | `aztec_misc_assertCompatibleOracleVersion` | served |
| 1 | `aztec_prv_isExecutionInRevertiblePhase` | served |
| 2 | `aztec_prv_setHashPreimage` | served |
| 3 | **`aztec_prv_callPrivateFunction`** | **refused** |

`outcome: refused`, `stoppedAtOracle: aztec_prv_callPrivateFunction`, and the refusal names itself
through `OracleUnimplemented` with tier 4's own recorded reason.

**Three things this red establishes that a plan could not:**

1. **Tier 4 is the ONLY gap for this fixture.** `Parent.entry_point` never asks for
   `getContractInstance`, a note, a tag or a key. Three oracles, then the nested call. So a green
   here is a measurement of the NESTING and of nothing else.
2. **Seq 2 is the enumeration's R12/R14 arriving on real data.** `aztec_prv_setHashPreimage` is the
   parent storing the child's args into the execution cache one opcode before it asks for the
   nested call — which is why a per-frame cache cannot serve this oracle even in principle.
3. **The ladder is 3, and it is the floor every later measurement is compared against.** A green
   that produced fewer than four calls would be a frame that stopped earlier for a new reason.

## STEP 5 — TIER 4 IS SERVED, AND THE FIRST GREEN RUN FOUND A SECOND INSTANCE OF §3b's FAMILY

`aztec_prv_callPrivateFunction` is served. The first run in Chromium:

```
parent oracleCalls: 0 assertCompatibleOracleVersion  served
                    1 isExecutionInRevertiblePhase   served
                    2 setHashPreimage                served
                    3 callPrivateFunction            SERVED
  child[0]: Child.value  executed  depth 1
     calls: assertCompatibleOracleVersion, isExecutionInRevertiblePhase,
            setHashPreimage, isExecutionInRevertiblePhase   (all served)
```

**The nested frame RAN** — `Child.value` is `outcome: executed` at depth 1 — and then the PARENT
halted inside the circuit:

```
Assertion failed: 2 output values were provided as a foreign call result for 1 destination slots
```

### The two sides, read from source rather than inferred

| line | `call_private_function_oracle`'s declared return | destination slots |
|---|---|---|
| `deletion_era` (`upstream/tsavm/.../aztec-nr/aztec/src/oracle/call_private_function.nr`) | `-> [Field; 2]` | **1** (one slot holding a 2-array) |
| the `cpp` anchor (`aztec-packages/noir-projects/labs/aztec-nr/.../call_private_function.nr`) | `-> (u32, Field)` | **2** (a tuple, two scalar slots) |

and the vendored wire is the anchor's:
`CALL_PRIVATE_RESULT = STRUCT([{endSideEffectCounter: FIELD}, {returnsHash: FIELD}])` — 2 slots.

**And `assertCompatibleOracleVersion` PASSES over it**: the artifact declares oracle version
**30.0**, the environment implements **30.8**, same MAJOR and environment minor >= contract minor,
which is upstream's own rule for "not breaking".

**This is `PRIVATE-EXECUTION.md` §3b's finding on a SECOND oracle, and it is the stronger instance**
— because §3b closed with the sentence *"33 oracles are still refused, and any of them whose wire
shape moved between the anchors carries the same latent gap"*, and this is that sentence coming
true on the very next refusal anybody served. A prediction this campaign wrote down and then met.

The artifacts came from `diffsim`, which is the `deletion_era` line
(`aztec_version 5.0.0-nightly.20260626`). `drift` carries the same two contracts at
**5.3.0-nightly.20260819**, the `current` pin that matches the `cpp` anchor — which is §3b's own
confirmation route, and it is taken as an ARM rather than by swapping a path, so both readings are
on the record on every run.

### STEP 5b — AND THE ANCHOR-LINE CORPUS CANNOT RUN HERE AT ALL, WHICH IS A BIGGER FACT THAN §3b's

The obvious remedy — run the `drift` line's artifacts, which is §3b's own confirmation route — was
tried and refused by the runtime before a single opcode:

```
entry_point declares 3 argument field(s) beyond its context inputs and 2 were supplied
```

Derived from the two artifacts' own ABIs rather than from the message:

| | `PrivateContextInputs` width, from the artifact's `inputs` parameter |
|---|---|
| `diffsim` / `spike` / `probe-mt` — `deletion_era` 5.0.0-nightly.20260626 | **37** |
| `drift` — `current` 5.3.0-nightly.20260819, matching the `cpp` anchor | **38** |
| `browser/node_modules/@aztec/constants` `PRIVATE_CONTEXT_INPUTS_LENGTH` | **37** |

**So the whole frame's input struct is a different width on the anchor line, not just one oracle's
return.** `executePrivateFunction` builds a 37-field context because the INSTALLED `@aztec/stdlib`
is the `deletion_era` pin, and `countArgumentsSize(abi) - 37` over a 38-field artifact reports one
argument too many — which is the arithmetic saying so rather than a coincidence.

That is `PRIVATE-EXECUTION.md` §3b's own closing sentence again, one level up: the pairing is
anchor/pin reconciliation and belongs to **M37**. It is recorded here and deliberately not taken.

**Consequence for M39:** the corpus this runtime can execute is the 30.0 one, and the 30.0 wire for
this oracle is one destination slot. Tier 4 is served and the CHILD FRAME EXECUTES; what stops the
parent is a two-field regrouping between the two lines. The remedy follows M35's own precedent for
this exact class — `PRIVATE-EXECUTION.md` §2's "anchor-versus-pin gap", which cost three shims —
and it is measured in BOTH directions rather than switched on.

## STEP 6 — THE GREEN: ONE TRANSACTION, TWO PRIVATE FRAMES, IN CHROMIUM

Three arms, one page each, `~/.cache/aztec-m39-nested/nested.json`.

| arm | line | ctx declared/built | `wireCompatApplied` | outcome |
|---|---|---|---|---|
| `nested` | `deletion_era` 5.0.0-nightly.20260626 | 37 / 37 | **1** | **`executed`** |
| `noCompat` | the same, shim off | 37 / 37 | **0** | `failed` — *2 output values … for 1 destination slots* |
| `anchorLine` | `current` 5.3.0-nightly.20260819 | **38 / 37** | — | refused to assemble, before a single opcode |

### The evidence, and it is the LEDGERS rather than the outcome word

```
PARENT (Parent.entry_point, 6,979 bytes ACIR, 915-entry witness, counters 0 -> 3)
  0 assertCompatibleOracleVersion  served  contract=30.0 environment=30.8
  1 isExecutionInRevertiblePhase   served  counter=1
  2 setHashPreimage                served  hash=0x08bc5138… len=1     <- the CHILD's args
  3 callPrivateFunction            served  fn=Child.value depth=1 static=false
                                           args=1 counter=1->2 returnsHash=0x247b9960…
  4 getHashPreimage                served  hash=0x247b9960… len=1     <- the CHILD's RETURN
  5 setHashPreimage                served  hash=0x247b9960… len=1
  6 isExecutionInRevertiblePhase   served  counter=3

CHILD (Child.value, 6,352 bytes ACIR, 910-entry witness, counters 1 -> 2, depth 1)
  0 assertCompatibleOracleVersion  served
  1 isExecutionInRevertiblePhase   served  counter=2
  2 setHashPreimage                served  hash=0x247b9960… len=1     <- stores its RETURN
  3 isExecutionInRevertiblePhase   served  counter=2
```

**Five things this says that "outcome: executed" does not:**

1. **The shared execution cache is used in BOTH directions, and the ledger shows the crossing.**
   The child stores its return at ITS seq 2 under `0x247b9960…`; the parent loads it back at ITS
   seq 4 under the same hash, in its own frame. That is the enumeration's R14 second direction —
   the one that fails on the opcode AFTER the nested call — happening.
2. **The value that crossed is `0x…02`, and 2 is the answer only a correctly-parented child gives.**
   `Child.value(input) = input + chain_id + version`, called with `input = 0` on a chain whose id
   and version are both 1. A child that had not received the PARENT's `txContext` returns something
   else, and nothing in the parent asserts it — so this field is the only place that disagreement is
   visible. Read from the tape (`getHashPreimage` outputs), not from a count.
3. **The side-effect counter range chains.** Parent `0 -> 3`, child `1 -> 2`, and `aztec-nr`'s
   `self.side_effect_counter = end_side_effect_counter + 1` is what makes the parent's 3.
4. **The parent's own `returnsHash` EQUALS the child's** — `0x247b9960…` on both public inputs —
   because `entry_point` returns exactly what `Child.value` returned. Two producers, one value.
5. **The `callPrivateFunction` TAPE entry's outputs are ONE slot holding TWO fields**
   (`['0x…02', '0x247b9960…']`), which is what the circuit received rather than what the handler
   returned — because the shim sits between the handler and the tape. M38's replaying Rust executor
   needs the former.

### AND THE SHIM'S FIRST DRAFT WAS A GUARD THAT COULD NOT GUARD, FOUND BY ITS OWN COUNTER

The first version keyed the callback wrapper by the HANDLER METHOD name (`callPrivateFunction`).
`buildACIRCallback` keys its object by the ORACLE name (`aztec_prv_callPrivateFunction`) and
resolves the method from it by upstream's `aztec_{scope}_{methodName}` convention — so the wrapper
wrapped nothing, returned the callback unchanged, and the run failed exactly as before.
**It was caught because the shim reports how many times it fired and the number was 0 over a run
that needed it**; without that counter the two arms would have agreed and read as "the shim is not
the problem". A missing key is a `die` now rather than a pass-through.

### THE FINDING BEHIND THE SHIM: UPSTREAM'S OWN COMPATIBILITY TABLE CANNOT EXPRESS THIS CASE

`legacy_oracle_registry.ts` (vendored, RI-97) exists for exactly this problem and says so:
*"Wire shapes that already-deployed contracts still call by their original oracle name … so
versioning an oracle's wire (e.g. adding return fields) stops being a breaking change."*
`buildACIRCallback` installs those entries beside the live ones.

**It holds three entries and every one is keyed by a RETIRED name** —
`aztec_utl_getL1ToL2MembershipWitness`, `aztec_utl_getLogsByTag`, `aztec_utl_getPendingTaggedLogs`,
each superseded by a `…V2`. So upstream's rule for changing a wire is: change the NAME.

**`aztec_prv_callPrivateFunction` changed shape and kept its name.** A legacy entry for it is not
merely absent, it is unwritable: the key would collide with the live oracle and `buildACIRCallback`
throws on precisely that. The same is true of `aztec_utl_getPublicKeysAndPartialAddress`, §3b's
subject. **Two same-name wire changes, and the table that exists to absorb them can hold neither.**
That is the finding; the shim is the legacy entry that could not be written, keyed on the
contract's declared VERSION because the name was never retired.

## STEP 7 — THE PRIVATE HALF IS A TRANSACTION IN ONE CONTAINER, AND THE ROUTE THERE FOUND A DEFECT

M38's probe grew a FRAME LIST, additively: a spec with no `frames` still describes one frame, and
**all five of M38's arms were re-run and came out identical on every one of twenty-two figures**
(steps, opcodes, positions, paths, first steps, calls, returns, container bytes, refusals — 0
differences), with only additive keys appearing.

### The result, read back by the pinned `ct-print`

| | `transaction` | `parentOnly` (the control) |
|---|---|---|
| frames | **2** | 1 |
| max depth | **1** | 0 |
| steps the recorder wrote | **58** | 35 |
| `Step` events the reader reads | **60** | **36** |
| …of those, carrying a COLUMN | **60** | **36** |
| `call_entry` / `call_exit` | **1 / 1** | **0 / 0** |
| distinct `aztec-nr` source files stepped | **9** | 9 |
| paths the container interns | **100** | 78 |
| container bytes | **925,696** | 901,120 |

`35 + 23 = 58`, and `container = probe + frames` (58 + 2, 35 + 1) — M38's `container = probe + 1`
identity generalised, because `TraceSink::start` emits an entry step per traced circuit.

The nested frame is `value`, entry step 36, exit step 59, carrying the CHILD's contract address as
its one call argument — so it is attributable without stepping into it, which is M26's rule for the
public half applied here. **`parentOnly` is the control that says the Call is the nesting**: the
same parent, the same tape, zero calls.

### THE ROUTE THERE FOUND A DEFECT IN M38's TAPE, AND IT IS THE CAMPAIGN'S FAVOURITE SHAPE

The first two-frame run halted: the parent replayed **five of its seven** recorded oracle calls and
died **167 opcodes into 903** with a bare ` Failed assertion`. The `parentOnly` control failed
identically, so it was not the nesting.

**The cause: a one-element ARRAY and a SINGLE field are the same thing on a normalised tape.**
`ForeignCallParam` is `Single(f) | Array(fs)`; M38's tape normalises every slot to an array of hex
strings (which it must — its own header records the sixty-six one-character strings the first draft
produced), and the replaying executor chose between them with `if fields.len() == 1 { Single }`.

`aztec_prv_getHashPreimage` — the oracle behind `execution_cache::load` — returns `[Field; N]`, and
for a function returning one `Field` that is an array of **one**. Replayed as a `Single`, the
Brillig heap array of width 1 receives a scalar and reads out of bounds, which Noir reports as an
assertion with no message.

**Every oracle M38's four arms exercised was a genuine `Single` or a multi-field array**, so the
rule was right every time it had been tried. `getHashPreimage` is the first oracle in this campaign
whose return is a one-element array, and it only appears once a frame READS ANOTHER FRAME'S RETURN
— i.e. only once tier 4 is served.

The tape records `inputKinds` and `outputKinds` now, taken at the same wrapping point as the values
themselves. The probe uses the recorded kind, refuses an unknown one by name, and **reports per call
when it had to fall back to the length guess** — so a replay that guessed is a replay whose result
says so. Over the regenerated tapes the guess count is **0** everywhere, and M38's five arms are
unchanged to the assertion.

*The general form, and it is one this file already names: a normalisation that makes a value
readable can make it unreplayable, and the two are different jobs. Record the shape beside the
value.*

### A SECOND, SMALLER ONE FOUND ON THE WAY

The probe handed the tracer an EMPTY `error_types` map, so every assertion rendered as
` Failed assertion` over artifacts that declare their messages by name (`Parent.entry_point`
declares three, including `Preimage mismatch`). The map is built from the artifact's own ABI now.
It did not turn out to be the diagnosis here — the failing assertion was a bare Brillig
out-of-bounds with no payload at all — which is itself the finding: *the blank message was not the
missing map, and fixing the map is what allowed that to be established rather than assumed.*

## STEP 8 — BOTH HALVES OF A TRANSACTION EXIST, AND FINDING THAT FOUND A THIRD DEFECT

`Parent.enqueue_calls_to_child_with_nested_first` is upstream's own both-halves fixture: it calls
ITSELF privately (through `enqueue_call_to_child`, which enqueues a public call) and then enqueues
a second one directly. Measured in Chromium:

```
outcome executed, counters 0 -> 5, 7 oracle calls
  enqueued public calls (outer frame): 1, to Child 0x2330fbe5…
  child[0] Parent.enqueue_call_to_child  executed  depth 1
     enqueued public calls: 1, to the same Child, a DIFFERENT calldataHash
```

**One transaction, two private frames, two enqueued public calls.** The two enqueued calls differ
by their `calldataHash` and not by their contract, which is the argument (10 against 20) rather than
the function — the distinction a field named `selector` would have hidden, and the reason the
report names it `calldataHash`.

### THE THIRD DEFECT: THE FUNCTION SELECTOR THIS RUNTIME DERIVES WAS NOT THE PROTOCOL'S

The first run of that fixture refused, and the refusal named itself exactly:

```
NestedCallRefused: unknown-selector: no function of 'Parent' derives selector 0x20abda42.
The artifact derives [enqueue_call_to_child=0xeb8256a3, …]
```

Measured in node against the installed `@aztec/stdlib`, over `Parent.enqueue_call_to_child`:

| derivation | selector |
|---|---|
| `fromNameAndParameters` over the RAW artifact's `abi.parameters` | `0xeb8256a3` |
| the same, with the leading `inputs` parameter dropped | **`0x20abda42`** |
| `loadContractArtifact` + upstream's own `getFunctionSelector` | **`0x20abda42`** |
| what the CONTRACT derives, `comptime FunctionSelector::from_signature("enqueue_call_to_child((Field),(u32),Field)")` | **`0x20abda42`** |

A raw artifact's parameter list begins with `inputs: PrivateContextInputs` — the frame's context,
which the macro injects and no caller passes — and `loadContractArtifact` strips it before the
selector is derived. `executePrivateFunction` did not.

**It has been wrong since the first frame this runtime executed and nothing could see it.** The
selector goes into the `CallContext` and no assertion in a single frame compares it with anything.
It became visible the moment one contract passed another's selector across a nested call and the
callee had to be FOUND by it — a value nobody measured, right-looking until the first consumer that
compared it. Fixed in `privateFunctionSelector`, with all four derivations recorded at the line.

*This is the third defect tier 4 exposed, and all three share a shape: a value that was correct
enough for one frame and wrong for two.*

## STEP 9 — THE JOIN RECORD, WRITTEN BY THE PRIVATE HALF AND READ BY THE PINNED READER

The probe writes a `ct.trace-join` record through `TraceSink::register_special_event`, using the
same `format!` as `verification/oq7_shared_writer_probe.rs` rather than a second spelling.

Read back out of the container by the pinned `ct-print`:

```
metadata "ct.trace-join", 160 bytes
join=0x17c08357cb1e842e… half=private halves=2 arm=split
reason=recorded-by-the-producer-not-inferred-by-a-reader
```

and `orchestration/src/trace_join.ts`'s `formatJoinRecord` over the same four fields renders **the
same 160 bytes**, compared as bytes rather than each against a copy of itself.

**The join identity is DERIVED and not minted**: it is the parent frame's own `argsHash`, a value
the circuit committed to, so two runs of one transaction agree and two transactions cannot collide.
A random id would make the join a fact about when the driver ran.

**`parentOnly` carries no join record at all**, deliberately — it is one frame and not a half of
anything — which is what makes "the transaction's container carries one" a measurement rather than
a property of the writer.

## STEP 10 — THE CHECKS, AND WHAT RUNNING THEM MOVED

`just verify-m39` — **148 assertions, 0 failures, 2/2, exit 0**:
`test_nested_private_call_is_served` **77**, `e2e_transaction_steps_into_one_container` **71**.

### Two defects the container check found in ITSELF, on its first run

1. **The 512-byte stub reads as ZERO steps, not `UNREADABLE`, and the first draft asserted the
   opposite.** M38's own check records exactly that — *"the fact that it does NOT refuse one is
   recorded rather than assumed, because the first draft of that control asserted the opposite"* —
   and this file's first draft asserted the opposite again, one milestone later. Zero is the
   stronger control: an instrument that refuses says nothing about what it counts.
2. **"The transaction's container has strictly more distinct lines" is FALSE, and the truth is a
   better sentence.** Both containers reach **22** distinct `(path, line)` pairs over the same
   **9** files and the two SETS are equal: `Child.value` is `input + chain_id + version`, so the
   callee's own arithmetic produces no positioned step, and every position it visits the
   `#[aztec]` preamble already took the caller through. **So in this container the two frames are
   distinguishable BY FRAME and by nothing else** — which is `JOIN-SHAPE.md` §4's sentence arriving
   one level down, on two PRIVATE frames, and the reason the Call and Return are not decoration.
   Asserted as an EQUALITY of the sets, with a non-emptiness floor, so a future callee that DOES
   add a position moves the line rather than passing it silently.

### Four documents carried figures this work moved, and every one was named by its own comparer

| document | figure | was | is |
|---|---|---|---|
| `BROWSER-PACKAGING.md` | total gzipped across every chunk | 8,230.98 KB | **8,234.22 KB** |
| `PRIVATE-EXECUTION.md` §6 | the wallet entry's eager set | 304.5 KB | **306.91 KB** |
| `PRIVATE-EXECUTION.md` §6 | the wallet demo page's eager set | 344.36 KB | **347.58 KB** |
| `LOCAL-HISTORY.md` §6 | the same two rows | | |
| `PRIVATE-TRACE.md` §1 | handler methods declared | 43 | **44** |
| `PRIVATE-TRACE.md` §1 | of them `async` | 9 | **10** |

Re-run after the corrections: **m27 345, m35 239, m36 150, m38 150 — every one at its reference
value to the assertion, 0 failures, exit 0.**

**And M38's own guard did the finding rather than a grep.** `verify_private_oracle_synchrony_enumerated`
does not merely COUNT the async methods, it requires the write-up to NAME each one — so adding a
tenth `die`d the check at 34 of 35 assertions until `PRIVATE-TRACE.md` named
`callPrivateFunction`. A count would have been satisfied by any tenth method.

### Two sentences tier 4 made false, corrected where they are written

`PRIVATE-TRACE.md` §6 and `PRIVATE-EXECUTION.md` §7 both declared that
`aztec_prv_callPrivateFunction` refuses. Corrected in place rather than noted elsewhere — *a note
about a false sentence in a neighbouring file is a second document to keep in step.* And the
refusal's stated REASON was rewritten for the same rule one level down: it named "its own
ephemeral-array service and its own side-effect counter range", and the built thing shares the
counter range and deliberately does NOT share the ephemeral service.

### AND `verify_named_checks_exist` FOUND ONE OF M38's, WHICH M38's SWEEP HAD ATTRIBUTED AWAY

Adding a name of M39's own made the check red and its whole set readable, and the set was longer
than the story: `verify_foreign_call_executor_is_injectable` names TWO Rust test files in `noir`,
and M38 declared `test_foreign_call_executor` and not `test_tracer`. **So that check's one
set-comparison assertion has carried an unresolved name of this repository's own making since M38
landed, while M38's sweep attributed m20's single failure entirely to L3's
`test_reverted_transaction_recorded_as_reverted`.** The attribution was right about that name and
incomplete about the set — and a set comparison reports ONE failure however many members it has, so
the count did not move and nothing said so.

*A check that names a SET needs its whole set read, not its count.*

Both remaining unresolved names are parallel tracks' — L3's above and L2's
`verify_hydrated_roots_declared` — count unchanged at 9, recorded and not fixed.
`verify_no_pipeline_predicates` 69/1 is **L4's** sixth `| grep -q` at
`verify_browser_replay_dd9_clean.sh:336`, which M38's sweep already names; none of M39's three new
shell files contains one. `just check-repo-hygiene` is **28/0**.

## STEP 11 — THE MUTATION MATRIX, FIRST PASS, AND IT FOUND THREE THINGS

Eight arms on M38's harness. `still_there` over a silently undone mutation exits **5**, measured —
and the first measurement of it read `rc=0` because the invocation piped it into `tail`, which is
this campaign's own "a pipe that put the failure counter in a subshell" arriving in the way an
agent *reads* a result rather than in a check.

| arm | subject | result | verdict |
|---|---|---|---|
| N1 | the execution cache is per frame again | 21 / **3** | killed |
| N2 | the child's `msgSender` is the tx origin, not its caller | **84 / 0** | **SURVIVED — a real gap** |
| N3 | the wire shim fires unconditionally | **84 / 0** | **SURVIVED — unkillable here** |
| N4 | the selector includes the context parameter again | 62 / **3** | killed |
| N5 | the replay guesses the wire kind from the slot length | **82 / 0** | **SURVIVED — the mutation never applied** |
| N6 | the nested frame's `Call` is never written | **82 / 0** | **SURVIVED — the mutation never applied** |

### N5 and N6 are M32's FOURTH STATE, and the arm's prediction disagreeing is why I looked

`m39_require_trace_arms` checks that the probe BINARY exists and never rebuilds it, while
`m39_trace_newer_inputs` watches the probe's SOURCE. So mutating `m38_private_trace_probe.rs` marks
the arms stale, the arms re-run — **with the old binary** — and the report is a faithful
measurement of unmutated code, printed as the arm's result.

That is *"a mutation that never applied, printed as the arm's result"*, the worst of M32's four
states. **M38's own `m38_require_arms` builds the probe (`lib_m38_private_trace.sh:58`) and mine
did not** — the one line of its library I did not carry over, in the library whose header says it
sources M38's rather than repeating it.

*And the arm's PREDICTION agreeing with its RESULT is the condition under which nobody re-reads the
log — here the two disagreed, which is the only reason this was found.*

### N2 is a gap in the CHECK, not in the code

`Child.value` is `input + chain_id + version` and reads no `msg_sender`, so handing the child the
transaction's origin instead of its caller changes no value the check reads. Upstream's
`deriveCallContext` passes THIS frame's contract precisely so that a contract cannot impersonate the
caller of the frame above it — and nothing asserted it.

### N3 is unkillable HERE, and that is a fact about the corpus

The shim's predicate is *"the contract declared an older minor of the same major"*. Every artifact
this runtime can execute is 30.0 against an environment of 30.8, so `older` is true for all of them
and removing the test changes nothing any arm can see. **The corpus that would make it false — the
anchor line — cannot assemble a frame here at all** (37 fields against 38), which is the same
measurement §6 records.

Per this campaign's own rule the three wrong responses are deleting the guard, deleting the arm, and
leaving the arm unlabelled. All three are kept: the guard, the arm, and a comment **at the guard**
naming the arm that cannot kill it and why.

## STEP 12 — THE MUTATION MATRIX, SECOND PASS, AFTER THE THREE REPAIRS

| arm | subject | result | what it killed |
|---|---|---|---|
| N1 | the execution cache is per frame again | 21 / **3** | the transaction stops executing; the check DIES at a missing field, with a summary line |
| N2 | the child's `msgSender` is the tx origin, not its caller | 88 / **1** | exactly the assertion written for it, and nothing else |
| N3 | the wire shim fires unconditionally | 88 / 0 | **EXPECTED SURVIVOR**, declared at the arm AND at the guard |
| N4 | the selector includes the context parameter again | 66 / **3** | the selector pair and the both-halves arm, which dies at a missing field |
| N5 | the replay guesses the wire kind from the slot length | 82 / **7** | the guessed-kind count 0 -> 5, the trace error, the replayed-call identity 11 -> 9, and six document rows |
| N6 | the nested frame's `Call` is never written | 29 / **7** | both call counts, the frame's name, its call argument, the step identity, and then the numeric guard `die`s on the two missing span readings |
| N7 | the trace arm run HANGS (bound cut to 20 s) | **0 / 1**, rc **137**, bound NAMED | the precondition, with a summary line at column 0 |
| N8 | the trace arm report is truncated | **1 / 2** | the precondition, through the second of `m38_absent`'s three spellings of absence |
| demo | `still_there` over a silently undone mutation | exit **5** | — |

`HARNESS: restored; manifest verified`; no `MUTATION MISS`, no `DID NOT HOLD`; tree clean after.

**N7 is a hang and not a die-before-summary wearing a hang's label.** The rc is 137 — `timeout`
escalating to SIGKILL — because the arm holds a LIVE TIMER. A promise with no pending handle exits
13 and an `await` in a synchronous function exits 1, and this campaign has written both by accident
while meaning a hang.

## STEP 13 — THE SWEEP WAS ABORTED ONCE, AND THE ABORT BOUGHT THIRTEEN ASSERTIONS THAT COULD NOT FAIL

Killed at m2, five minutes in, `carry/*.json` verified OK against the pre-sweep digests and the tree
clean. The only work a sweep leaves is reading your own checks, and that is where this campaign's
aborts keep finding things.

**§9 of `test_nested_private_call_is_served` was six tautologies.** It asserted each of the
nested-call oracle's five refusal grounds with
`str_has_sub "$(cat private_oracles.ts)" "'unregistered-contract'"` — **a name grepped in the file
that declares that name**, this campaign's own catalogued form, which cannot be less than true. The
comment beside it even said one of them *"was exercised by a real run"* — during development, with
nothing re-deriving it.

Four of the five are **produced** now, each by removing exactly ONE thing from the working
transaction and leaving everything else alone:

| ground | what was removed | what the ACVM carried back |
|---|---|---|
| `unregistered-contract` | the callee, from the artifact directory only | *"this wallet can execute 1 contract(s) and none of them is at 0x2330…"* |
| `unknown-selector` | the selector, replaced by `0xdeadbeef` | *"no function of 'Child' derives selector 0xdeadbeef. The artifact derives […]"* |
| `not-private` | nothing — a PUBLIC function's selector is passed to a private call | *"'Child.pub_set_value' matches selector 0xeb1e3342 and is not an abi_private function"* |
| `depth-exceeded` | the bound, set to 0 | *"a nested call at depth 1 exceeds this wallet's bound of 0"* |

Each is asserted on the LAST ledger entry, **parsed rather than grepped** — a substring search for an
outcome anywhere in a ledger is satisfied by any entry having it, and the key order is the reader's
`sort_keys` rather than the producer's, which the first needle got wrong. Each is `unavailable`
rather than `refused`, which is M35's third outcome. And **the four grounds reported are asserted to
be four DIFFERENT grounds**, because four refusals that all named the same one would satisfy
everything above. The fifth stays declared and the check says which is which.

**Then the census was widened over the FORM rather than the spelling** — the rule this campaign
wrote after a two-digit census closed on `RI-` and missed `FX-` in the file being fixed. Seven more
`str_has_sub` assertions whose haystack was a source file:

| what it grepped | replaced by |
|---|---|
| `export async function privateFunctionSelector` | the same upstream comparison on a SECOND function, because one function agreeing is a coincidence |
| `export function oraclesServedFor` | the always-served list parsed from source against the served set the RUN reports |
| the enqueued-call extractor's own source line | the callee the CIRCUIT committed to against the address the page derived |
| `readonly inputKinds:` / `readonly outputKinds:` / the fallback's diagnostic | asking the TAPE whether every slot carries a kind, with the slot count asserted non-zero |

Thirteen assertions that could not fail, in one milestone's own two checks, found by reading them
while a sweep ran. **M39 goes 170 -> 201.**

*And moving one replacement above the variable it reads made the check exit on an unbound variable —
which the abnormal-exit trap turned into a RED milestone with a summary line rather than a smaller
one, which is exactly what it is for.*

## STEP 14 — THE MUTATION MATRIX, RE-TAKEN AFTER THE LAST EDIT

| arm | subject | result | what it killed |
|---|---|---|---|
| N1 | the execution cache is per frame again | 21 / **3** | the transaction stops executing; the check DIES at a missing field, with a summary line |
| N2 | the child's `msgSender` is the tx origin, not its caller | 118 / **1** | exactly the assertion written for it |
| N3 | the wire shim fires unconditionally | 118 / 0 | **EXPECTED SURVIVOR**, declared at the arm and at the guard |
| N4 | the selector includes the context parameter again | 96 / **4** | both selector comparisons — the callee's and the caller's — and the both-halves arm, which dies |
| N5 | the replay guesses the wire kind from the slot length | 83 / **7** | the guessed count 0 -> 5, the trace error, the replayed-call identity 11 -> 9, six document rows |
| N6 | the nested frame's `Call` is never written | 29 / **7** | both call counts, the frame name, its argument, the step identity, then the numeric guard `die`s |
| N7 | the trace arm run HANGS (bound cut to 20 s) | **0 / 1**, rc **137**, bound NAMED | the precondition, summary line at column 0 |
| N8 | the trace arm report is truncated | **1 / 2** | the precondition, through the second spelling of absence |
| demo | `still_there` over a silently undone mutation | exit **5** | — |

`HARNESS: restored; manifest verified`; **no `MUTATION MISS`, no `DID NOT HOLD`**; tree clean after,
and the bundle rebuilt after every arm that mutated it — because restoring a SOURCE leaves the
mutated ARTEFACT on disk, which is the first entry on this campaign's own list.

**N4 gained a failure between the third pass and this one (3 -> 4)**, and that is the new
second-function selector assertion doing work: one function agreeing with upstream is a coincidence
a hard-coded answer also produces.

## STEP 15 — THE SWEEP WAS ABORTED A SECOND TIME, FOR FOUR TYPED LITERALS

Killed at m2 again, six minutes in, `carry/*.json` verified OK and the tree clean. The census this
time was mechanical — `assert_eq "…" "<digits>"` across both checks — rather than a re-read of the
lines that looked suspect, which is the rule this campaign wrote after a census closed on one
spelling and missed another in the file being fixed.

Two of the twenty said *"is the browser run's"* and compared against the literals **2** and **1**.
That is a description claiming a measurement its comparison cannot make — the campaign's 40th and
41st instance — and a transaction with three frames would have moved both artefacts together and
neither assertion. One compared a LOOP'S ITERATION COUNT against the list the loop iterates, which
is an assertion over the number of arguments the check itself passed. One asserted the wire shim
fired *"exactly once"*, which is a property of the fixture typed into a check.

All four are readings now. The remaining sixteen are definitions — an entry frame is at depth 0, a
control carries zero calls — and are left alone, which is the distinction the census exists to make.

**M39 goes 201 -> 205.**

## STEP 16 — THE MUTATION MATRIX, RE-TAKEN AFTER THAT LAST EDIT

| arm | subject | result | what it killed |
|---|---|---|---|
| N1 | the execution cache is per frame again | 21 / **3** | the transaction stops executing; the check dies at a missing field, with a summary line |
| N2 | the child's `msgSender` is the tx origin, not its caller | 121 / **1** | exactly the assertion written for it |
| N3 | the wire shim fires unconditionally | 121 / 0 | **EXPECTED SURVIVOR**, declared at the arm and at the guard |
| N4 | the selector includes the context parameter again | 99 / **4** | both selector comparisons — the callee's and the caller's — and the both-halves arm, which dies |
| N5 | the replay guesses the wire kind from the slot length | 84 / **7** | the guessed count, the trace error, the replayed-call identity, six document rows |
| N6 | the nested frame's `Call` is never written | 29 / **7** | both call counts, the frame name, its argument, the step identity, then the numeric guard dies |
| N7 | the trace arm run HANGS (bound cut to 20 s) | **0 / 1**, rc **137**, bound NAMED | the precondition, summary line at column 0 |
| N8 | the trace arm report is truncated | **1 / 2** | the precondition |
| demo | `still_there` over a silently undone mutation | exit **5** | — |

`HARNESS: restored; manifest verified`; no `MUTATION MISS`, no `DID NOT HOLD`; tree clean after.

## STEP 17 — THE SWEEP: **13,227**, `delta +0`, NO HOLE, AND M9 DID NOT FLAKE

Measured M0–M39 on 2026-09-01 **after the last commit**, `setsid`-detached in this repository's own
dev shell (node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log
under `~/.cache`. **80 markers for 40 milestones, no hole. 36 of 40 exit 0.** Polled **inside the
agent's own run** in ten-minute blocks — every background waiter attached to it was killed by the
harness, which is why the campaign's rule is what it is.

```
m0 156   m1 181   m2 293   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 807
m10 450  m11 287  m12 691  m13 458  m14 460  m15 537  m16 225  m17 297  m18 578
m19 180  m20 237  m21 451  m22 349  m23 512  m24 350  m25 454  m26 340  m27 345
m28 358  m29 127  m30 218  m31 450  m32 237  m33 248  m34 217  m35 239  m36 150
m37 171  m38 150  m39 205
                                                       CAMPAIGN TOTAL 13,227
```

The summariser validated the reference's own `_total` first and then reported **`delta +0`**:
every one of the forty came out at its declared value, and the single move was named in
`m39-reference.json` before the run. **13,022 + 205 = 13,227 exactly**, and M39's 205 is 121 / 84.

**M9 DID NOT FLAKE** — 807, rc 0, **1,279 s**, immediately after m8's **179 s** build, which is
D19's standing condition, present and not firing. M15 did not either (537, 382 s).

**FOUR NON-ZERO EXITS AND NOT ONE IS M39's**, all four declared in the reference before the run:

| milestone | check | count | offending subject | whose |
|---|---|---|---|---|
| m11 | four checks, 9 failing assertions | **287, unchanged** | the tenth upstream move, `upstream/next` still `f6bf848795` against a recorded `7471a61f1a` | **upstream's** |
| m20 | `verify_named_checks_exist` 9/1 | unchanged | `tools/scan_reverted_transactions.mjs` and `verify_hydrated_roots_declared` | **L3's and L2's** |
| m21 | `verify_no_pipeline_predicates` 69/1 | unchanged | a sixth `\| grep -q` in `verify_browser_replay_dd9_clean.sh:336` | **L4's** |
| m28 | `verify_npm_pack_no_optional_native` 55/1 | unchanged | `replay/package.json` as an eighth tree | **L0's** |

**M16 IS NO LONGER RED, AND THAT IS A PARALLEL TRACK'S REPAIR RATHER THAN M39's.** M38's sweep read
m16 **225 rc=1** on a needle handed to a THIRD engine; this reads **225 rc=0**, and the fix is commit
`c329c72`, which was on `origin/dev` before this pass began. The count is identical either way.

**THE SIXTEEN L0–L5 CHECK NAMES APPEAR ZERO TIMES AS A COLUMN-0 SUMMARY LINE**, grepped one at a
time against the summariser's own anchored pattern. None of their assertions is in the 13,227.

**A sweep is a writer**: `carry/*.json` checksummed before, `sha256sum -c` after —
`exposure.json` and `rebase.json` came back **FAILED**, were restored from HEAD, and all four
re-verified OK.

### AND THE FIRST SWEEP OF THIS PASS FOUND THAT THE "NOTHING ELSE MAY MOVE" LIST WAS INCOMPLETE

The first run came out at the same **13,227** with **seven** non-zero exits: the four above plus
**m32, m33 and m34**, on the SAME eager-size figures in `WALLET-BOUNDARY.md`, `WORKER-NODE.md` and
`DEV-WALLET.md`. **Every count was at its reference value and only the rc moved**, which is what says
a pinned figure moved and not a structure.

The cause is worth the sentence: the milestones re-run by hand before that sweep were the ones whose
SUBJECTS this pass had changed, not the ones whose FIGURES it had. Five documents carry the wallet
entry's and the wallet demo page's gzipped eager sizes and this pass had corrected two of them.
Corrected to the checks' values and the three re-run individually — **237 / 248 / 217, zero
failures** — and the sweep above is the one taken after that commit.

### AND AN AD-HOC SUMMARISER GOT m28 WRONG WHILE THE REAL ONE GOT IT RIGHT

Re-running m28 after the rebase, a quick `awk -F'[ ,]'` reported **254** against a reference of 358.
The shortfall is exactly `just ci-browser-gate: 104 assertion(s)` — **the one check whose printed
name contains a SPACE**, which is the trap `m39-sweep-sum.py`'s own header records
(*"an `^([A-Za-z_0-9]+):` needle silently DROPS it, which is how m0 once came out 128 against a
reference of 156"*). The sweep's summariser uses the anchored pattern and read 358 correctly. *A
summariser is a thing under test, and an ad-hoc one written at the prompt is not the one that was.*

## STEP 18 — THE REBASE ONTO L4 AND L5

`origin/dev` gained two commits while this pass ran — `29bd9cf` (**L4**) and `57496bd` (**L5**, a new
track). Rebased onto both; **twelve commits replayed with no conflict**, and all four diff3 markers
grepped for afterwards rather than three, which is the hazard this campaign records.

Re-measured after the rebase, because a rebase is a change to the tree the sweep measured:
`verify_named_checks_exist` **9/1** and `verify_no_pipeline_predicates` **69/1** — both unchanged,
both on the same parallel-track subjects, so L5's new checks added no unresolved name and no
pipeline predicate. `check-repo-hygiene` **28/0**. **m25 454, m27 345, m28 358, m39 205** — every one
at its reference value. Nothing under `replay/` was touched.
