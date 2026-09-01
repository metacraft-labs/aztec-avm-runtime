<!-- M39's write-up. Every figure in §1, §3, §4 and §5 is re-derived from the artefacts on every run
     and compared AGAINST THIS FILE — by `test_nested_private_call_is_served` §13 and
     `e2e_transaction_steps_into_one_container` §10 — each matched on the line that NAMES ITS
     SUBJECT rather than anywhere in the file, and as a delimited figure on that line rather than as
     a run of characters anywhere in it. Do not edit the numbers by hand; re-run and copy what the
     CHECK prints. -->

# A transaction is a tree of frames — what tier 4 needed, what it cost, and what it exposed

M39's write-up. `PRIVATE-EXECUTION.md` is M35's and is where the oracle surface lives;
`LOCAL-HISTORY.md` is M36's; `PRIVATE-TRACE.md` is M38's and is where the tracer's own seam is;
`JOIN-SHAPE.md` is M26's and is where the two halves' writers are settled. This file is about the
thing all four were waiting on: **`aztec_prv_callPrivateFunction`, served, so that a private half is
a TRANSACTION rather than a FRAME.**

---

## 1. THE ENUMERATION, FIRST, AND IT IS A NUMBER

**Owned by `test_nested_private_call_is_served`.**

Before any code: what does serving this oracle in THIS runtime actually need? Taken by reading
upstream's own `callPrivateFunction`
(`aztec-packages/yarn-project/pxe/src/contract_function_simulator/oracle/private_execution_oracle.ts:645-756`)
against `browser/src/wallet/private_oracles.ts` and `private_execution.ts`, one capability at a
time, each with a citation.

| | derived |
|---|---|
| distinct requirements | **29** |
| of them already present | **5** |
| of them missing | **24** |
| of the missing, "share what is currently per-frame" | **6** |
| of the missing, genuinely new subsystems | **4** |

**The synchrony question was structurally OPEN, and that is the measurement rather than an
assumption.** `browser/src/vendor/pxe/contract_function_simulator/oracle/acir_callback.ts:42-48`
dispatches every registry entry through an `async` closure that `await`s the handler method, and the
ACVM awaits the promise it gets back. So `await executePrivateFunction(...)` inside a handler is
legal, and **zero of the 24 were blocked on the execution model.**

### The three things the enumeration found that a plan would not have

1. **The execution cache must be shared in BOTH directions, and the second one is the surprise.**
   The child's arguments were stored by the PARENT (`aztec-nr`'s `private_context.nr` does
   `execution_cache::store(args, args_hash)` one opcode before the oracle call) — and the parent
   reads the CHILD's return value back, because `ReturnsHash::get_preimage` is
   `execution_cache::load(self.hash)` run in the caller's frame over a hash the callee stored. A
   per-frame cache therefore does not fail AT the nested call; it fails on the opcode after it.
2. **One of the six sharing items points the OTHER way.** The ephemeral-array service must be PER
   FRAME: upstream constructs one in every oracle and does not pass it to a child, and
   `EphemeralParent`'s own isolation test exists to say a child must not see its parent's slots.
   Sharing everything would have been the easy edit and would have broken a rule nothing here
   measures.
3. **`sealPrivateFrame` is a rewrite, not a loop.** It takes ONE contract and silos every note hash
   against it; a two-contract transaction needs each note hash siloed against its own emitting
   contract. Not taken here — see §6.

---

## 2. THE FIXTURE IS UPSTREAM'S OWN, AND THE CALLEE IS THE EMPTIEST ONE IT HAS

`parent_contract/src/main.nr`:

```
#[external("private")]
fn entry_point(target_contract: AztecAddress, target_selector: FunctionSelector) -> Field {
    self.context.call_private_function(target_contract, target_selector, [0]).get_preimage()
}
```

and `child_contract/src/main.nr`:

```
#[external("private")]
fn value(input: Field) -> Field { input + self.context.chain_id() + self.context.version() }
```

`Child.value` reads no note, derives no tag, writes no storage and asks for no contract instance of
its own — so a failure is a failure of the NESTING. **It is also the control for the two chain
fields**: a child that had not been handed the parent's `txContext` returns a different field, and
the parent asserts nothing about it, so the returned value is the only place that disagreement is
visible.

**Measured before any tier-4 code, in Chromium: `Parent.entry_point` serves three oracles and stops
at exactly `aztec_prv_callPrivateFunction`.** No contract instance, no note, no key — tier 4 was the
only gap for this fixture, which is what makes the green a measurement of the nesting alone.

---

## 3. THE TRANSACTION, AND THE EVIDENCE IS THE LEDGERS

**Owned by `test_nested_private_call_is_served`.**

| | derived |
|---|---|
| `Parent.entry_point` bytecode | **6979** bytes |
| the caller's solved witness | **915** entries |
| oracle calls the caller made, all served | **7** |
| `Child.value` bytecode | **6352** bytes |
| the callee's solved witness | **910** entries |
| oracle calls the callee made, all served | **4** |
| the served set with a nested-call source attached | **36** |
| times the call-private wire regrouping fired | **1** |

```
PARENT (counters 0 -> 3)
  0 assertCompatibleOracleVersion  served  contract=30.0 environment=30.8
  1 isExecutionInRevertiblePhase   served
  2 setHashPreimage                served  <- the CHILD's arguments
  3 callPrivateFunction            served  fn=Child.value depth=1 static=false
  4 getHashPreimage                served  <- the CHILD's RETURN, read in the PARENT's frame
  5 setHashPreimage                served
  6 isExecutionInRevertiblePhase   served

CHILD (counters 1 -> 2, depth 1)
  0 assertCompatibleOracleVersion  served
  1 isExecutionInRevertiblePhase   served
  2 setHashPreimage                served  <- stores its RETURN under its own returnsHash
  3 isExecutionInRevertiblePhase   served
```

**Five things this says that `outcome: executed` does not.**

1. **The shared execution cache is used in both directions and the crossing is in the ledgers.** The
   child stores at its seq 2 under its own `returnsHash`; the parent loads it back at its seq 4
   under the same hash, in its own frame.
2. **The value that crossed is `2` — `input(0) + chain_id(1) + version(1)`** — read out of the tape
   rather than out of a count. Only a correctly-parented child produces it.
3. **The counter range chains.** Parent `0 -> 3`, child `1 -> 2`, and `aztec-nr`'s
   `self.side_effect_counter = end_side_effect_counter + 1` is what makes the parent's 3.
4. **The parent's own `returnsHash` equals the child's**, because `entry_point` returns exactly what
   `value` returned. Two producers, one value.
5. **The served set grew by exactly one.** `36` against M35's `35`, derived from the partition
   rather than typed, with all four combinations of the two optional sources reconciled at
   construction rather than the two that used to exist.

### Both halves of a transaction, on the fixture that has them

`Parent.enqueue_calls_to_child_with_nested_first` calls ITSELF privately — through
`enqueue_call_to_child`, which enqueues a public call — and then enqueues a second one directly:

| | derived |
|---|---|
| oracle calls the outer frame made | **7** |
| public calls the outer frame enqueued | **1** |
| public calls the nested frame enqueued | **1** |
| the transaction's side-effect counter range ends at | **5** |

The two enqueued calls address the same contract and carry **different** calldata hashes — the
argument (10 against 20) rather than the function, which is the distinction a field named `selector`
would have hidden. They are read from the CIRCUIT's own public inputs, not from the wallet's
bookkeeping.

---

## 4. THE PRIVATE HALF IS ONE CONTAINER WITH BOTH FRAMES

**Owned by `e2e_transaction_steps_into_one_container`.**

M38's probe grew a FRAME LIST, additively: a spec with no `frames` still describes one frame, and
all five of M38's arms reproduce every figure exactly.

| | `transaction` | `parentOnly` |
|---|---|---|
| frames in the container | **2** | **1** |
| steps the recorder wrote | **58** | **35** |
| `Step` events the pinned reader reads | **60** | **36** |
| …of those, carrying a COLUMN | **60** | **36** |
| `Call` records | **1** | **0** |
| distinct `(path, line)` positions | **22** | **22** |
| distinct source files stepped | **9** | **9** |
| paths the container interns | **100** | **78** |
| container bytes | **929792** | **901120** |

`35 + 23 = 58`, and `container = probe + frames` — M38's `container = probe + 1` identity
generalised, because `TraceSink::start` emits an entry step per traced circuit.

The nested frame carries the CHILD's contract address as its one call argument, which is M26's rule
for the public half and its reason: a frame must be attributable without stepping into it.
`parentOnly` runs the same frame with the same tape and no child in the list, and its container
carries **zero** calls — which is what makes the one Call the nesting rather than something the
writer does anyway.

### THE POSITION SETS ARE EQUAL, AND THAT IS THE MEASUREMENT

Both containers reach **22** positions over the same **9** files, and the two SETS are the same.
`Child.value` is `input + chain_id + version`, so the callee's own arithmetic produces no positioned
step, and every position it visits the `#[aztec]` preamble already took the caller through.

**So in this container the two frames are distinguishable BY FRAME and by nothing else.** That is
`JOIN-SHAPE.md` §4's sentence — *"a private-half step and a public-half step are distinguishable by
frame"* — arriving one level down on two PRIVATE frames, and it is why the Call and the Return are
not decoration: without them a reader has sixty steps over twenty-two positions and no way to tell
which frame it is in.

### The join record, recorded rather than inferred

```
metadata "ct.trace-join"
join=<the transaction's own argsHash> half=private halves=2 arm=split
reason=recorded-by-the-producer-not-inferred-by-a-reader
```

written through `TraceSink::register_special_event` with the same `format!` as
`verification/oq7_shared_writer_probe.rs`, read back out of the container by the pinned `ct-print`,
and **byte-identical to what `orchestration/src/trace_join.ts` renders for the same four fields** —
compared as bytes rather than each against a copy of itself.

**The identity is DERIVED and not minted**: the parent frame's own `argsHash`, a value the circuit
committed to, so two runs of one transaction agree and two transactions cannot collide.
`parentOnly` carries no record at all, which is what makes the transaction's one a measurement.
And one half of a declared two-half join is REFUSED by `joinRecordings` on `count-mismatch` —
`halves` is in the grammar so that an incomplete join is a refusal rather than a smaller answer.

---

## 5. THREE DEFECTS TIER 4 EXPOSED, AND THEY SHARE A SHAPE

Each was correct enough for one frame and wrong for two.

### 5a. A wire regrouping upstream's own compatibility table cannot express

`aztec_prv_callPrivateFunction`'s return changed shape between the two nightly lines this tree has
installed, read from source at both ends:

| line | `call_private_function_oracle`'s declared return | destination slots |
|---|---|---|
| `deletion_era` | `-> [Field; 2]` | **1** |
| the `cpp` anchor | `-> (u32, Field)` | **2** |

and `assertCompatibleOracleVersion` PASSES over the pair — 30.0 against 30.8, same major,
environment minor ≥ contract minor, which is upstream's own rule for "not breaking".

**`legacy_oracle_registry.ts` exists for exactly this** — *"so that versioning an oracle's wire
stops being a breaking change"*.
Entries in that table, every one of them keyed by a RETIRED name: **3**.
`callPrivateFunction` changed shape and KEPT its name, so a legacy entry for it is not merely absent
but unwritable: the key would collide with the live oracle and `buildACIRCallback` throws on exactly
that. The same is true of `aztec_utl_getPublicKeysAndPartialAddress`, which
`PRIVATE-EXECUTION.md` §3b measured. **Two same-name wire changes, and the table that exists to
absorb them can hold neither.**

The shim is the legacy entry that could not be written, keyed on the contract's declared VERSION
because the name was never retired, and **measured in both directions on every run**: with it off,
the same transaction halts at the slot count naming 2-against-1.

**And its own first draft was a guard that could not guard.** It keyed the callback wrapper by the
HANDLER METHOD name where `buildACIRCallback` keys by the ORACLE name, so it wrapped nothing and
returned the callback unchanged. It was caught because the shim REPORTS how many times it fired and
the number was **0** over a run that needed it; without that counter the two arms would have agreed
and read as "the shim is not the problem". A missing key is a refusal now, not a pass-through.

### 5b. A one-element array and a single field are the same thing on a normalised tape

`ForeignCallParam` is `Single(f) | Array(fs)`, and Brillig's destination for an array return is a
heap array of a declared width. M38's tape normalises every slot to an array of hex strings — which
it must, its own header records the sixty-six one-character strings the first draft produced — and
the replaying executor chose between them by length.

`aztec_prv_getHashPreimage`, the oracle behind `execution_cache::load`, returns `[Field; N]`, and
for a function returning one `Field` that is an array of **one**. Replayed as a `Single`, the parent
frame died with a bare `Failed assertion`, five of its seven recorded calls in.
The caller's circuit, whose 167 stepped opcodes that halt was **903** opcodes short of.

Every oracle M38's four arms exercised was a genuine `Single` or a multi-field array, so the rule
was right every time it had been tried — and `getHashPreimage` only appears once a frame READS
ANOTHER FRAME'S RETURN, which is only once tier 4 is served. The tape records the wire kind now, the
probe reports per call when it had to fall back to the guess, and this transaction's tape carries
**both** kinds, so the distinction is exercised rather than declared.

*A normalisation that makes a value readable can make it unreplayable, and the two are different
jobs.*

### 5c. The function selector this runtime derived was not the protocol's

| derivation | selector for `Parent.enqueue_call_to_child` |
|---|---|
| over the RAW artifact's `abi.parameters` | `0xeb8256a3` |
| the same, with the leading `inputs` parameter dropped | **`0x20abda42`** |
| `loadContractArtifact` + upstream's `getFunctionSelector` | **`0x20abda42`** |
| the CONTRACT's own `comptime FunctionSelector::from_signature` | **`0x20abda42`** |

A raw artifact's parameter list begins with `inputs: PrivateContextInputs`, which the macro injects
and no caller passes. **It has been wrong since the first frame this runtime executed and nothing
could see it** — the selector goes into the `CallContext` and no assertion in a single frame
compares it with anything. It became visible the moment one contract passed another's selector
across a nested call and the callee had to be FOUND by it.

---

## 6. WHAT IS DELIBERATELY NOT HERE

- **The anchor-line corpus cannot run here at all, and that is measured rather than worked around.**
  The context width the `deletion_era` artifacts declare: **37** fields.
  The context width the anchor line declares: **38** fields.
  The installed `@aztec/constants` says 37, so an anchor-line frame is refused before a single
  opcode. That pairing is anchor/pin reconciliation and
  `PRIVATE-EXECUTION.md` §3b assigns it to **M37**; an arm runs it on every run so the claim is a
  run rather than a paragraph.
- **The PUBLIC half of the joined transaction is not executed here.** The transaction ENQUEUES two
  public calls and the circuit's public inputs carry them; running them needs the AVM, a resident
  world state and a fee payer, which is M20's and M29's machinery pointed at `Child` rather than
  `Token`. So what exists is one container, the private half, carrying an explicit
  `half=private halves=2` record — and `joinRecordings` REFUSES it on `count-mismatch`, which is
  the grammar working rather than a gap being hidden.
- **No `sealPrivateFrame` over a tree.** §1's third finding: it silos every note hash against one
  contract. This transaction emits no note, so nothing here needed it and nothing here claims it.
- **The child's frame opens after the parent's step stream, not at the parent's call instruction.**
  `trace_circuit_with_executor` steps a whole circuit in one pass and there is no point inside that
  pass at which a second circuit's steps can be interleaved. The nesting expresses the CALL
  RELATIONSHIP rather than the instruction order — which is `JOIN-SHAPE.md` §3's own shape, whose
  public frames open inside `main` after the private half has stepped, for the same reason.
- **Nothing here drives CodeTracer.** The container is read by the pinned `ct-print`; *"the file
  parses"* and *"the recording steps correctly in the debugger"* are different claims and this
  establishes the first.
