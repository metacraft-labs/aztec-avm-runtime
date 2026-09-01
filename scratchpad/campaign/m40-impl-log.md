# M40 — the public half executes and both halves step in a browser — implementation log

## Step 0 — orientation (started 2026-09-01)

Reading, in order: CAMPAIGN-BRIEF.md (full, 2,862 lines), NESTED-CALLS.md (M39),
PRIVATE-TRACE.md (M38), JOIN-SHAPE.md (M26/OQ-7), PRIVATE-EXECUTION.md (M35),
m39-impl-log.md, OUT-OF-SCOPE.md.

### Measured state at start

| subject | measurement |
|---|---|
| `aztec-avm-runtime` branch | `dev`, HEAD `7595c1e` == `origin/dev`, tree clean |
| `noir` branch | `codetracer`, `7c40098a1` |

### The two gaps M39 handed over, restated

1. The transaction ENQUEUES two public calls and commits to them; they are not executed.
   M20/M29 machinery (`PublicProcessor`, the AVM, `ExecutedStepCollector`) pointed at `Child`.
2. M38/M39's stepper is native. The tracer wasm built from the PUBLISHED `noir` is sufficient
   (M39 measured 4,619,384 bytes in 61 s, carrying the executor seam) and must be driven in
   the page that already runs the private half.

Then the join: `e2e_joined_private_public_trace` (M35), tracked as `e2e_joined_public_half_executed`.

Standing constraints carried forward: `wasm/webpage` stays in ZERO published refs;
`noir-wt4-webpage` ends at `f0e7edcd2` with exactly its one pre-existing edit; tracer changes
go in `noir` on `codetracer`; do not touch `replay/` (L0-L5's).

## Step 1 — the measurements taken before any code

### 1a. The published `noir` builds the tracer wasm, and M39's figure reproduces TO THE BYTE

`cd noir/tooling/tracer_wasm && cargo build --release --no-default-features` under
`nix shell nixpkgs#rustup nixpkgs#capnproto` with M24's `CARGO_HOME`/`RUSTUP_HOME`:

| | measured here | M39 recorded |
|---|---|---|
| `noir_tracer_wasm.wasm` bytes | **4,619,384** | 4,619,384 |
| wall time (warm `target/`) | **59.61 s** | 61 s |
| `noir` HEAD | `7c40098a1` == `origin/codetracer` | same |

So gap 2 needs no unpublished branch, re-derived rather than inherited.

### 1b. WHAT THE PUBLISHED MODULE CANNOT DO YET — three gaps, read from source

`noir/tooling/tracer_wasm/src/`: `lib.rs` (239) + `memory_sink.rs` (309). Neither
`compile.rs` nor `ctfs_sink.rs` (those are `noir-wt4-webpage`'s).

1. **The bare ABI has one entry, `ct_trace`, and it takes a Noir `ProgramArtifact` + a
   `Prover.toml`.** An Aztec contract-function artifact is neither.
2. **No executor seam through the ABI.** `trace_artifact` (`lib.rs:98`) calls
   `noir_tracer::trace_circuit` (8 args) — not M38's `trace_circuit_with_executor` — so no
   oracle can be answered from a tape.
3. **`MemorySink::register_step_with_column` DROPS THE COLUMN** (`memory_sink.rs:264`,
   `_column`), and its own header says why: `StepRecord` in `codetracer_trace_types` carries
   only `(path_id, line)`. M39 §1c predicted this; it is confirmed at the line.

### 1c. AND THE PAGE'S OWN Path A WRITER CANNOT WRITE A NOIR STEP EITHER

`ct-writer/src/lib.rs`'s `emit()` (line 1046) is the ONE place both OQ-6 arms write a step, and
it unconditionally records five AVM variables per step — `opcode`, `contextId`, `l2Gas`,
`daGas`, `contractAddress`. A private Noir step has none of those. Writing a private half
through `ct_step`/`ct_ingest` would mean **fabricating four counters per step**, which is
exactly the family M29's `test_browser_steps_are_executed_not_mapped` exists to refuse.

So the browser private half needs a source-only step export on the module we own, not a
fabricated AVM record. `register_step_with_column` is already what `emit` calls for a
positioned step; what is missing is a way to reach it without the AVM half.

## Step 2 — GAP 1 IS CLOSED: THE PUBLIC HALF EXECUTES, IN CHROMIUM

`Parent.enqueue_calls_to_child_with_nested_first`, one page, one transaction.

### 2a. The enqueued calls are TAKEN FROM THE CIRCUIT, not re-declared

M39 surfaced `publicCallRequests` as `{contractAddress, calldataHash}` — a HASH and nothing else,
so a runner had to re-encode the call from a function name and arguments it chose itself. That is
a second producer of a value the circuit already committed to, and the fixture is built to expose
exactly that: **the two enqueued calls differ by their ARGUMENT (10 and 20) and not by their
function**, so a re-declaration is free to get it wrong and nothing would notice.

`private_execution.ts` now reports `msgSender`, `isStaticCall`, `counter` and the **calldata
preimage**, read out of the transaction's own execution cache under the hash the circuit committed
to — the same store `aztec_prv_assertValidPublicCalldata` reads. `runEnqueuedPublicCalls` rebuilds
each request from that preimage with upstream's own `PublicCallRequest.fromCalldata` and refuses if
the hash it derives is not the circuit's.

Measured, in Chromium:

| | counter 2 | counter 4 |
|---|---|---|
| frame that enqueued it | `enqueue_call_to_child` (nested) | `enqueue_calls_to_child_with_nested_first` |
| committed calldata hash | `0x124ef545…` | `0x2b667ab5…` |
| rebuilt from the preimage | `0x124ef545…` | `0x2b667ab5…` |
| selector resolves to | `pub_set_value` | `pub_set_value` |
| calldata fields | 2 | 2 |

Same function, different argument — which is the distinction the hash comparison protects.

### 2b. The public half runs, and it is 146 REAL AVM instructions

| | measured |
|---|---|
| executed steps | **146** |
| `stats["total_instructions_executed"]` | **146** |
| `drainedMatchesResult` | **true** |
| AVM contexts | **2** |
| distinct opcodes | **15** |
| `ProcessedTx.revertCode` | **0** (`OK`) |
| outcome | `processed` |
| container bytes | **180,224** |
| steps positioned in `aztec-nr` source | **110** of 146 |
| distinct source paths in the container | **4** + `/aztec/tx.avm` |
| `Call` frames opened | **2** (`Child.pub_set_value`, `context2`) |

The four source paths are `macros/dispatch.nr`, `oracle/avm.nr`, `serde/src/reader.nr` and
`context/public_context.nr`.

### 2c. THE THIRD DEFECT OF M39's FAMILY, FOUND BY THE PUBLIC HALF'S OWN GUARD

`wallet_main.ts`'s `classIdOf` hashed the artifact's **base64 TEXT** where
`makeContractClassPublic` wants the decoded bytecode: `computePublicBytecodeCommitment` was being
handed a string. Every address derived from it is self-consistent, so `aztec-nr`'s
`get_contract_instance` assertion holds and no private frame can tell.

It became visible the moment the public half had to REGISTER that class and the AVM had to find
bytecode by its id — the guard named both derivations:

| derivation | class id |
|---|---|
| over the artifact's base64 text | `0x228f83d8c6120e5e…` |
| over the decoded `public_dispatch` bytecode | **`0x0e85bd5140e3b445…`** |

That is M39's selector defect one contract over — *a value that was correct enough for one frame and
wrong for two* — and the third time this campaign has met the shape. Fixed in `classIdOf`, through
upstream's own `loadContractArtifact` + `getContractFunctionArtifact`.

### 2d. Both controls are PRODUCED, and both fire

| arm | what it changes | result |
|---|---|---|
| `corruptCalldata` | one field of one enqueued call's calldata, `0x…0a -> 0x…0b` | **refused**, naming both hashes |
| `noDeploymentNullifier` | the callee's deployment nullifier is not seeded | **1** instruction, opcode **68** (`LAST_OPCODE_SENTINEL`), 1 context, `revertCode` **1** |

The second reproduces M29's finding exactly, which is what makes the 146-step floor a number that
has been watched fail.

### 2e. THE JOIN: TWO CONTAINERS, ONE IDENTITY, BOTH READ BY THE PINNED READER

| | private half | public half |
|---|---|---|
| producer | the native probe (Path B, Nim writer) | the page's own `ct_writer.wasm` (Path A) |
| frames | **2** (`…with_nested_first`, `enqueue_call_to_child`) | 2 AVM frames |
| steps | **64**, all with columns | **146**, 110 positioned |
| container bytes | **917,504** | **180,224** |
| join record | `half=private halves=2 arm=split` | `half=public halves=2 arm=split` |

and the identity is the same on both: `join=0x0330099ccfa1701224ce448435ee4c05056c78d43802126cf581af8567a9b1b5`
— the outer frame's own `argsHash`, derived and not minted.

### 2f. THE PATH A WRITER DOES RECORD THE COLUMN, AND THAT IS A DIFFERENTIAL RATHER THAN A READING

The pinned `ct-print` renders the Path A container through its **legacy `events.log` reader**,
whose `Step` record is `(path_id, line)` — so no column appears in that rendering, and reading the
absence as "the browser's container has no columns" would be a fact about the READER stated as one
about the container.

Measured instead, by writing the same four steps twice and changing **one step's column**:

| | container bytes | sha256 |
|---|---|---|
| `columns: true`, column 1 | 176,128 | `f692d54f…` |
| `columns: true`, column 9 | 176,128 | `51ef36d8…` |
| `columns: false`, column 1 | 176,128 | `424631328…` |

Same size, three different digests. The column reaches the container (a delta-column opcode, which
is why the size does not move) and asking for columns at all changes the encoding.
