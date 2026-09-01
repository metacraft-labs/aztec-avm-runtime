<!-- M38's write-up. Every figure in §1, §3, §4 and §5 is re-derived from the artefacts on every
     run and compared AGAINST THIS FILE — by `verify_private_oracle_synchrony_enumerated` §6 and
     `e2e_private_function_steps_into_ct_container` §7 — each matched on the line that NAMES ITS
     SUBJECT rather than anywhere in the file, and as a delimited figure on that line rather than as
     a run of characters anywhere in it. Do not edit the numbers by hand; re-run and copy what the
     CHECK prints. -->

# The private half steps — what runs, what refuses, and where the synchrony boundary actually is

M38's write-up. `PRIVATE-EXECUTION.md` is M35's and is where the oracle surface lives;
`JOIN-SHAPE.md` is M26's and is where the two halves' writers are settled. This file is about the
third thing: **a private Aztec function stepped by the tracer this project already owns.**

---

## 0. THE ERROR THIS MILESTONE REPLACES, BECAUSE IT IS THE MOST USEFUL THING IN IT

The first M38 specified building a per-opcode observer inside the ACVM. It rested on a measurement
that was correct — `@aztec/noir-acvm_js` exports 32 symbols and none of them steps — and on a
conclusion that was false, because it asked what the **npm artifact** can do and never asked what
**this project already built**.

Two things existed the whole time. `nargo trace` **is** an ACVM stepper: `TracingContext` drives
`DebugContext::step_into_opcode()` in a loop and turns each step into `register_step` /
`register_variables` with source locations. And the sink has always been injectable —
`trace_circuit(…, tracer: &mut dyn TraceSink)`.

*An enumeration that asks the wrong subject returns a true answer to a question nobody asked.*

---

## 1. THE ENUMERATION, FIRST, AND IT IS A NUMBER

**Owned by `verify_private_oracle_synchrony_enumerated`.**

The milestone's first deliverable is the measurement, before any code: which oracles does a private
function that COMPLETES actually call, in order, and for each — can it be answered synchronously
from state already inside wasm, does it need a host round trip, or is it unimplemented?

The subject is `OracleVersionCheck.private_function`, the simplest frame M35 executes: 6,306 bytes
of ACIR, a 37-field context input, an 897-entry solved witness.

| | derived |
|---|---|
| oracle calls it made | **4** |
| of them answerable synchronously in wasm | **4** |
| of them needing a host round trip | **0** |
| of them unimplemented | **0** |
| distinct oracles among them | **3** |

In order, with what decides each class:

| # | oracle | class | why |
|---|---|---|---|
| 0 | `aztec_misc_assertCompatibleOracleVersion` | sync-in-wasm | neither declared `async` nor awaits |
| 1 | `aztec_prv_isExecutionInRevertiblePhase` | sync-in-wasm | neither declared `async` nor awaits |
| 2 | `aztec_prv_setHashPreimage` | sync-in-wasm | neither declared `async` nor awaits |
| 3 | `aztec_prv_isExecutionInRevertiblePhase` | sync-in-wasm | neither declared `async` nor awaits |

**So the synchrony boundary does not block this frame at all**, and that is the milestone's first
result rather than an assumption it started from.

### What decides a class, and why none of the three is a list

- **`unimplemented`** is the RUN's own ledger recording the call as `refused` or `unavailable`. It
  is the handler saying, at run time, that it did not answer — not a partition read off a
  declaration.
- **`host-round-trip`** is the handler method being declared `async`, or its body awaiting.
  `ForeignCallExecutor::execute` is synchronous Rust; a synchronous call cannot await a JavaScript
  promise, in a browser or anywhere else. This is a property of the DECLARATION, read off the
  handler's source.
- **`sync-in-wasm`** is what is left.

The observed list comes from a run and the classification from the source, and neither is typed:
of the sixty-eight oracles in the registry, the frame that completes calls **three**.

### The boundary's size, over the whole handler

| | derived |
|---|---|
| handler methods declared across the served and discovery partitions | **43** |
| handler methods declared `async` | **9** |

The nine are `getRandomField`, `notifyNullifiedNote`, `notifyCreatedNullifier`,
`isNullifierPending`, `getPendingTaggedLogsV2`, `getLogsByTagV2`,
`validateAndStoreEnqueuedNotesAndEvents`, `getAppTaggingSecret` and `resolveTaggingStrategy`.

**And every one of the nine awaits CRYPTO or the tagging half — not the network and not a disk.**
`poseidon2HashWithSeparator` and `siloNullifier` go through `avm.wasm`, whose world state is
*itself in wasm*. So "needs a host round trip" here means "cannot be answered inside a synchronous
Rust call", which is a statement about the language boundary rather than about the chain. That
distinction is what makes §2's remedy the right one instead of a workaround.

*(The first draft of the scanner that produced the 9 found **4**, because `discoveryServed` sits
inside a `discovery ? { … }` conditional and its methods are indented eight spaces rather than
four. The undercount was in the direction that reads as good news. Found by comparing the set the
scanner returned against the one a reader counts in the file, which is the campaign's own "run the
derivation twice, differently, before believing it".)*

---

## 2. WHAT WAS MISSING WAS ONE PARAMETER, AND IT IS NOW IN `noir`

`trace_circuit` took no foreign-call executor, so `TracingContext::new` constructed a
`DefaultDebugForeignCallExecutor` itself — which answers `print` and `debug_log` and none of M35's
oracles. `DebugContext::new`, one level down, **already** took the executor as a
`Box<dyn DebugForeignCallExecutor>`.

`noir` on `codetracer` now carries `trace_circuit_with_executor` and
`TracingContext::with_executor`, with both existing entry points keeping their signatures and
delegating with `None`. `tooling/tracer/tests/test_foreign_call_executor.rs` is four tests over it,
compiling its fixtures in process rather than spawning `nargo`.

### The finding that came with it, and it is about the tracer rather than about Aztec

`DefaultForeignCallBuilder::build` composes its layers over **`layers::Empty`**, whose `execute` is
`Ok(ForeignCallResult::default())` for every call. So `nargo trace` over a program calling an
oracle nobody implements **does not fail** — it continues over an empty answer. For an oracle that
returns fields the ACVM then refuses on a slot count; for a `void` one it succeeds silently.

Nothing in the tree said which of *"no handler ran"* and *"no handler was needed"* the tracer does.
It is a test of its own now, and it is the control that makes M38's refusals a measurement rather
than a tautology: the refusal is the INJECTED executor's doing.

### Two more defects the Aztec artifact found, both in `noir` and both fixed there

1. **`get_source_location_for_debug_location` panicked on a Brillig function the debug info does not
   describe.** It looked the function's location map up and `unwrap()`ed it, ten characters from an
   `unwrap_or_default()` that already tolerates a missing entry INSIDE that map. Reachable from a
   published artifact: `OracleVersionCheck.private_function` has **5** Brillig functions and
   `brillig_locations` for **3**.
2. **The recorder emitted NO steps at all for a program compiled without debug instrumentation.**
   `update_record` reads its step's position out of `stack_frames`, which comes from `DebugVars` and
   is filled by the `__debug_*` calls the source-level instrumenter injects. A contract artifact
   carries none of those, so the frame stack was empty at every step and the whole recording came
   out with zero `Step` records — over an execution the debugger positions perfectly well.
   **Measured before the fix: 1,004 opcodes stepped, 44 carrying a source location at 13 distinct
   positions, and 0 steps recorded.**

   *The gate is a property of the ARTIFACT, not of the moment, and the first version got that
   wrong.* Keying on "the frame stack is empty" is also true of an instrumented program before its
   first `__debug_fn_enter`, and six of the twelve fixture tests went red with one extra step each
   (`a_1_mul` 14 → 15). Keying on the artifact declaring no variables and no functions separates
   the two cases by their cause instead of by a symptom they share, and all twelve are unchanged.

---

## 3. HOW THE ORACLE ANSWERS CROSS THE BOUNDARY: A TAPE, NOT A REIMPLEMENTATION

**Owned by `test_unserved_private_oracle_refuses_by_name`.**

`ForeignCallExecutor::execute` is synchronous Rust and M35's implementations are TypeScript. Nothing
bridges that at the moment the ACVM asks. So the answers are **pre-fetched**, which is this
milestone's own stated remedy for exactly this case:
`PrivateExecutionRequest.recordTape` makes `executePrivateFunction` record the WIRE VALUES of every
oracle call — the fields the ACVM handed in and the fields the handler handed back — and the probe
replays that tape into the same circuit.

**Nothing in the probe implements an Aztec oracle.** It has no notion of what a capsule is, or a
nullifier, or a contract instance. It can only hand back a value M35's handler produced, for the
same oracle, at the same point in the sequence, in answer to the same inputs.

### The tape is the wire, not the ledger

`OracleCall.detail` is a sentence the handler writes about what it did (`counter=1
revertible=false`). Deriving `[0]` from the words `revertible=false` is a guess that happens to be
right, and this repository's rule is that a value nobody measured is a value nobody may use. The
tape is taken by wrapping upstream's own `ACIRCallback` — after `deserializeParams`, before
`serializeReturn` — so it records what crossed rather than what the handler was thinking.

*(A slot is a field OR an array of fields, and the first draft spread the single-field case into
sixty-six one-character strings. Wrong in a shape a reader skims past, because it is still an array
of strings of the right total length. Found by reading the first tape rather than by reasoning
about it.)*

### Four things make the executor refuse, each BY NAME

| what | when |
|---|---|
| the tape has run out | the frame asks for more calls than were recorded |
| the tape's next entry is a different oracle | the replay has diverged from the recording |
| the inputs differ | the same oracle, a different question |
| the call is past the recording's SERVED prefix | the tape carries the call that STOPPED the frame too, and that one was never answered |

The last is the one that matters. A refused call and a genuinely void oracle both appear on the tape
with empty `outputs`, so the discriminator comes from the recording rather than from the tape: the
executor is told how many calls the recording's handler ANSWERED (`oraclesServed`) and refuses
everything past that prefix. **An executor that handed back "no fields" instead would be handing
back a fabricated answer of length zero — which fails loudly for a circuit expecting fields and
SUCCEEDS for one expecting none, walking the frame past an oracle nobody served.**

The refusal is `ForeignCallError::NoHandler`, which is the ACVM's own "nobody answered this" and
carries the oracle's name into the execution error.

---

## 4. FOUR ARMS, AND THE REFUSAL LADDER IS THE RESULT

**Owned by `e2e_private_function_steps_into_ct_container` and
`test_unserved_private_oracle_refuses_by_name`.**

Each arm is a mutation of the TAPE rather than of the executor, so the refusal path under test is
the shipped one.

| arm | tape | steps | refused, by name |
|---|---|---|---|
| `replay` | the whole tape of a frame that completed | **21** | — |
| `truncate` | the same tape, last entry dropped | **13** | `aztec_prv_isExecutionInRevertiblePhase` |
| `refuseAll` | the same tape, emptied | **2** | `aztec_misc_assertCompatibleOracleVersion` |
| `permuted` | the same tape, ONE field of ONE recorded input changed | **2** | `aztec_misc_assertCompatibleOracleVersion` |
| `transfer` | a recording that STOPPED at an oracle M35 does not serve | **62** | `aztec_utl_getNotes` |

**The ladder is strict and monotone — 2 < 13 < 21 — and it is the measurement, not the arms'
labels.** Fewer answers, fewer steps, and the oracle that ran out is named at each rung.

**The `permuted` arm exists because a mutation survived.** Removing the executor's input comparison
altogether changed no arm's result: a faithful replay never disagrees with its own recording, so
that comparison was a branch nothing executed. This arm changes ONE field of ONE recorded input and
nothing else — same oracle, same sequence, same outputs — so the only thing that can refuse it is
the comparison, and the refusal names the fabricated field back. `isExecutionInRevertiblePhase` is
called twice in this very frame with different counters, which is the case an executor matching on
the NAME alone would answer with the wrong recording.

### The `transfer` arm is the strongest of the four, and it is a real contract

`Token.transfer` is **76,875** bytes of ACIR, **5,602** ACIR opcodes and **26** Brillig functions.
The probe replays the four oracles M35's handler served, and refuses `aztec_utl_getNotes` — **the
same oracle, by the same name, that M35's own browser run stopped at.** The boundary is identical
on both sides of a language boundary that cannot be crossed at run time.

That refusal is the `served_calls` gate firing on real data rather than on a planted case, which is
what makes it live code rather than a fail-safe arm nobody executes.

---

## 5. THE CONTAINER, READ BACK BY THE PINNED READER

**Owned by `e2e_private_function_steps_into_ct_container`.**

The container is written by `NimWriterSink` over `create_trace_writer(…, Ctfs)` — literally the sink
and the writer `nargo trace` uses. **No second writer**: the probe's only difference from
`nargo trace` is that it starts from an Aztec artifact instead of a Noir package, and that it
supplies an executor.

| | `replay` | `transfer` |
|---|---|---|
| ACIR opcodes in the circuit | **889** | **5,602** |
| opcodes the stepper stepped | **1,004** | **643** |
| …of those, opcodes carrying a source location | **44** | **349** |
| step records the recorder wrote | **21** | **62** |
| distinct `(path, line)` in the container | **13** | **47** |
| distinct source files in the container | **5** | **16** |
| paths the container interns | **60** | **135** |
| container bytes | **745,472** | **1,343,488** |
| `Step` events the pinned `ct-print` reads back | **22** | **63** |

**The reader's count is one more than the recorder's, in both arms, and that is not a discrepancy.**
`TraceSink::start` emits the entry step at line 1 before the loop begins;
`e2e_private_function_steps_into_ct_container` asserts the identity `container = probe + 1` rather
than either number alone, so a recording that lost a step and a reader that invented one both fail.

Every step carries a **column**, and the positions are `aztec-nr`'s own source:

```
aztec/src/oracle/version.nr:21:9                 <- assertCompatibleOracleVersion
aztec/src/oracle/version.nr:26:5
aztec/src/context/private_context.nr:184:34
aztec/src/context/private_context.nr:189:35
aztec/src/context/private_context.nr:523:38
```

The five files the `replay` arm steps through are `oracle/version.nr`,
`context/private_context.nr`, `oracle/execution_cache.nr`, `oracle/tx_phase.nr` and
`macros/internals_functions_generation/external/private.nr` — which is the story of the four oracle
calls, told by the trace.

---

## 6. WHAT IS DELIBERATELY NOT HERE

- **The container is DD-7's Path B**, written by the Nim FFI writer, because that is what the Noir
  half ships (`JOIN-SHAPE.md` §2 fact 6). A Path A private container is possible and is not
  shippable, for the reason that file gives: the only tree in which both halves link the same writer
  is `wasm/webpage`, and it is unpublished (fact 7). **Nothing here touches that worktree**, and
  `verify_oq7_shared_writer_verdict_recorded` still asserts its HEAD is contained in zero published
  remote refs.
- **No variables.** An Aztec artifact is compiled without `instrument_debug`, so there are no
  `__debug_*` calls and the container carries positions without locals. §2's second fix is what
  makes the positions arrive at all; the variables would need the contract recompiled with the
  instrumenter, which is a change to how Aztec builds artifacts and not to this runtime.
- **No frames.** For the same reason: `register_call` / `register_return` are driven by
  `__debug_fn_enter` / `__debug_fn_exit`. The container has **0** calls and **0** returns, so the
  private half is a flat positioned step stream rather than a call tree. `JOIN-SHAPE.md` §4's
  "a private-half step and a public-half step are distinguishable by frame" is a property of the
  JOIN record and of the public half's frames, and is untouched.
- **The tracer does not ORIGINATE the oracle answers.** It consumes a tape M35's handler produced.
  That is the honest description of what crosses the synchrony boundary, and it is stated here
  rather than left for a reader to notice.
- **No nested private calls.** `aztec_prv_callPrivateFunction` is tier 4 and still refuses, in the
  handler and therefore on the tape.
- **Nothing here drives CodeTracer.** The container is read by the pinned `ct-print`; "the file
  parses" and "the recording steps correctly in the debugger" are different claims and this
  establishes the first.
