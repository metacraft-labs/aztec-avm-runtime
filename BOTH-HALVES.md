<!-- M40's write-up. Every figure in §2, §3 and §4 is re-derived from the artefacts on every run and
     compared AGAINST THIS FILE — by `e2e_joined_public_half_executed` §8 and
     `e2e_joined_private_public_trace` §7 — each matched on the line that NAMES ITS SUBJECT
     rather than anywhere in the file, and as a delimited figure on that line rather than as a run
     of characters anywhere in it. Do not edit the numbers by hand; re-run and copy what the CHECK
     prints. -->

# Both halves of one transaction, executed and stepped in a browser

M40's write-up. `NESTED-CALLS.md` is M39's and is where the private half became a TRANSACTION;
`PRIVATE-TRACE.md` is M38's and is where the tracer's own seam is; `JOIN-SHAPE.md` is M26's and is
where the two halves' writers are settled; `PRIVATE-EXECUTION.md` is M35's and is where the oracle
surface lives. This file is about the two things all four left open: **the enqueued public calls
actually running, and the private half stepping in the page that executed it.**

---

## 1. WHAT M39 HANDED OVER, IN ITS OWN WORDS

`NESTED-CALLS.md` §6:

> **The PUBLIC half of the joined transaction is not executed here.** The transaction ENQUEUES two
> public calls and the circuit's public inputs carry them; running them needs the AVM, a resident
> world state and a fee payer […] So what exists is one container, the private half, carrying an
> explicit `half=private halves=2` record — and `joinRecordings` REFUSES it on `count-mismatch`,
> which is the grammar working rather than a gap being hidden.

and `PRIVATE-TRACE.md` §6's own limitation, that the container is written by the Nim FFI writer in a
native binary.

Both are closed. The fixture is unchanged: `Parent.enqueue_calls_to_child_with_nested_first`, which
calls ITSELF privately through `enqueue_call_to_child` — enqueueing one public call — and then
enqueues a second directly.

---

## 2. THE PUBLIC HALF EXECUTES, FROM THE CALLDATA THE CIRCUIT COMMITTED TO

**Owned by `e2e_joined_public_half_executed`.**

| | derived |
|---|---|
| public calls the transaction enqueued | **2** |
| instructions the public half executed | **146** |
| AVM contexts they ran in | **2** |
| distinct opcodes among them | **15** |
| the public half's container bytes | **180224** |
| steps of it positioned in aztec-nr source | **110** |
| instructions the unseeded control executed | **1** |

### The calldata is the circuit's, and that is the whole difference

A private circuit ENQUEUES its public calls and commits to each one's calldata by a HASH in its
public inputs. Every other driver in this repository names a function and its arguments and encodes
them — **a second producer of a value the circuit already produced**, free to disagree with it.

This fixture is built to expose exactly that: its two enqueued calls differ by their **argument**
and not by their function, so a re-declaration that got the argument wrong would run two identical
calls and every count above would agree with it. The two arguments are in the table below and are
read out of the CALLDATA on every run, not out of the contract's source.

| | counter 2 | counter 4 |
|---|---|---|
| enqueued by | `enqueue_call_to_child` (the nested frame) | `enqueue_calls_to_child_with_nested_first` |
| the argument it carries | **10** | **20** |
| the hash the circuit committed to | `0x124ef545…` | `0x2b667ab5…` |
| the hash rebuilt from the preimage | `0x124ef545…` | `0x2b667ab5…` |
| the selector resolves to | `pub_set_value` | `pub_set_value` |

The preimage is read out of the transaction's own execution cache under the hash the circuit
committed to — the same store upstream's `assertValidPublicCalldata` reads — and the request is
rebuilt from it with upstream's own `PublicCallRequest.fromCalldata`.

**And the comparison has an arm that makes it fail.** `corruptCalldata` changes ONE field of ONE
call's calldata and nothing else; the public half refuses, naming both hashes and what it would
otherwise have been running.

### The carrier is derived rather than minted

`createTxForPublicCalls` refuses a transaction with no non-revertible nullifier, and upstream's own
tester supplies `new Fr(420000 + txCount)` — a counter, which would make two runs of one transaction
two different carriers and two different transactions the same one. The first nullifier here is the
private half's own `argsHash`, which is also the join identity.

### The seeding is a decision read off the artifact

`Child` declares no initializer, so `assert_is_initialized_public` is in none of its public
functions and exactly **one** nullifier is seeded: the deployment one. Seeding the initialization
nullifier unconditionally would put a value in the tree that no circuit asserts on.

**Without the deployment nullifier the AVM answers the address with no bytecode**: one instruction,
at pc 0, carrying M9's `LAST_OPCODE_SENTINEL` (68), in one context, `revertCode` 1 — and the block
still reports the transaction `processed`. That is M29's finding reproduced, and it is what makes
the 146 above a number that has been watched fail.

### The defect the public half's own guard found

`classIdOf` hashed the artifact's **base64 text** where `makeContractClassPublic` wants the decoded
bytecode: `computePublicBytecodeCommitment` was being handed a string.

| derivation | class id |
|---|---|
| over the artifact's base64 text | `0x228f83d8c6120e5e…` |
| over the decoded `public_dispatch` bytecode | **`0x0e85bd5140e3b445…`** |

Every address derived from the first is self-consistent, so `aztec-nr`'s `get_contract_instance`
assertion (`instance.to_address() == address`) holds and **no private frame can tell**. It became
visible the moment the public half had to register that class and the AVM had to find bytecode by
its id. That is M39's function-selector defect one contract over — *a value that was correct enough
for one frame and wrong for two* — and the third time this campaign has met the shape. Both
derivations are taken on every run and asserted to DISAGREE, so the fix is a measurement rather than
a corrected constant.

---

## 3. THE PRIVATE HALF STEPS IN THE SAME PAGE

**Owned by `e2e_joined_private_public_trace`.**

Two wasm modules and **no third writer**:

| | what it is |
|---|---|
| `m40_private_trace.wasm` | `noir_tracer` built for `wasm32-unknown-unknown` from the PUBLISHED `noir`, with M38's executor seam and a tape-replaying foreign-call executor. It stops at the CodeTracer low-level event stream and emits it as an ordered op list. |
| `ct_writer.wasm` | the page's own Path A writer, already there, already used by the public half. It gains one export pair for this: `ct_source_step` / `ct_source_steps_written`. |

**The Noir tracer links no container writer on this path at all**, which is why `JOIN-SHAPE.md` §2's
facts 6 and 7 are untouched and `wasm/webpage` stays unpublished — asserted on every run rather than
asserted about. This is a different answer to the same need rather than the answer OQ-7 ruled out.

| | derived |
|---|---|
| steps the browser's tracer produced | **66** |
| of those, carrying a COLUMN | **64** |
| private frames in the container | **2** |
| ops replayed into the writer | **147** |
| paths the private container interns | **78** |
| the private half's container bytes | **208896** |
| steps the NATIVE probe produced | **64** |
| column differences between them | **2** |
| imports the tracer module declares | **4** |

`browser = native + frames` — `TraceSink::start` emits an entry step per traced circuit, which is
M38's `container = probe + 1` identity generalised the same way M39 generalised it.

### Why `ct_source_step` had to exist

`ct-writer`'s `emit()` — the one place both OQ-6 arms write a step — records five variables per
step: `opcode`, `contextId`, `l2Gas`, `daGas` and `contractAddress`. Those are upstream's
`ExecutionStep` and they are the right shape for the AVM.

**A Noir private frame has none of them.** Writing the private half through `ct_step` would have
meant the host inventing four counters per step — the exact shape M29 found in M27's synthesised
opcodes, and the reason `recordAndDownload` refuses to fabricate a step stream rather than falling
back to one.

### The differential: two implementations walked the same circuit

The wasm module and M38's native probe are two independent implementations of the tape executor,
deliberately: M38's is native, links the Nim writer and is read by two milestones' checks, and
moving its executor into a library would move their figures. What ties them together is not a shared
file but a measurement, taken on every run with the native side read back through the pinned reader:

* the two `(path, line)` sequences are **identical, in order, all 66 steps**;
* the columns differ at exactly **2** steps — one per frame — and both differences are the same
  shape: the tracer emits no column for a frame's entry step, and a column-aware container's decoder
  answers 1.

Two implementations agreeing position for position is a stronger statement than one implementation
used twice, and it is the only shape that can catch a defect in either.

### The column reaches the container, and that is a digest pair

The pinned `ct-print` renders a Path A container through its **legacy `events.log` decoder**, whose
`Step` record is `(path_id, line)` and has no column field at all. Reading that absence as "the
browser's container has no columns" would be a fact about the READER stated as one about the
container — this campaign's "an absence asked of a tree that excludes the subject by construction".

Measured instead by writing the same transaction twice with one field changed:

| arm | container bytes | sha256 |
|---|---|---|
| the tracer's columns | 208,896 | `d53fc677…` |
| every step's column set to 0 | 208,896 | `d7da2342…` |

Same op list, same steps, same paths, same size — a different digest, because a column is a delta
opcode rather than a field. The column reaches the container.

### The module reached no import

It DECLARES four `wasm-bindgen` placeholders, and every one is satisfied with a function that
records the call and then throws. `reachedImports` is empty: **nothing in the tracer crossed back
into JavaScript**, which is a measurement the run makes rather than a promise a build flag gives.

---

## 4. THE JOIN CLOSES

Both containers are written **in one Chromium page, from one execution of one transaction**, and the
browser's own download machinery writes both files.

```
ct.trace-join   join=<the transaction's own argsHash> half=private halves=2 arm=split reason=recorded-by-the-producer-not-inferred-by-a-reader
ct.trace-join   join=<the transaction's own argsHash> half=public  halves=2 arm=split reason=recorded-by-the-producer-not-inferred-by-a-reader
```

| | value |
|---|---|
| the join identity both halves carry | `0x0330099ccfa170…` |

*(The identity is stated in exactly ONE place, and it is compared against the arm report's own
`argsHash` on every run. The two lines above show the GRAMMAR, which is why the value is elided
there: a figure written twice is a figure that can rot in one of the two.)*

* the identity is the outer frame's own `argsHash` — a value the circuit committed to — so two runs
  of one transaction agree and two transactions cannot collide;
* both records are compared **as bytes** against what `orchestration/src/trace_join.ts` renders,
  rather than each against its own copy of a format string;
* `joinRecordings` accepts the pair and reports `order: [private, public]`;
* **and either half alone is refused on `count-mismatch`**, which is what `halves` is in the grammar
  for and is produced rather than declared.

---

## 5. WHAT IS DELIBERATELY NOT HERE

- **Nothing here drives CodeTracer.** Both containers are read by the pinned `ct-print`; *"the file
  parses"* and *"the recording steps correctly in the debugger"* are different claims and this
  establishes the first. The headless replay SDK is owned elsewhere and is out of scope for this
  campaign; a summary that let "readable by the reference reader" drift into "verified in
  CodeTracer" would be describing work nobody did.
- **`e2e_form_b_single_ct_recording` stays pending.** One container for both halves needs the shared
  writer, and OQ-7 ruled that unshippable on `JOIN-SHAPE.md` §2's facts 6 and 7. Publishing
  `wasm/webpage` to make one container work would reopen a question settled on measurement; the
  shipped join is two containers with an explicit record, and this milestone did not touch that
  worktree.
- **The private half's container carries no embedded source views.** `ct-writer` has no export for
  them, and the native probe's container has 78. A reader that wants the source text reads it from
  the artifact; a reader that wants to STEP has every position and every column.
- **The child's frame opens after the parent's step stream**, not at the parent's call instruction —
  `trace_circuit_with_executor` steps a whole circuit in one pass. The nesting expresses the CALL
  RELATIONSHIP rather than the instruction order, which is `NESTED-CALLS.md` §6's own statement and
  `JOIN-SHAPE.md` §3's shape one level down.
- **The anchor-line corpus still cannot run here**, for M39's measured reason: 38 context fields
  against the installed `@aztec/constants`'s 37. That pairing is anchor/pin reconciliation and
  belongs to M37.
