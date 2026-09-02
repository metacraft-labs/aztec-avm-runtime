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

## Step 3 — GAP 2 IS CLOSED: THE PRIVATE HALF STEPS IN CHROMIUM TOO

Two wasm modules in one page and **no third writer**:

| | what it is |
|---|---|
| `m40_private_trace.wasm` | `noir_tracer` built for `wasm32-unknown-unknown` from the PUBLISHED `noir` (`e78dc9935`), with M38's executor seam and a tape-replaying foreign-call executor. **7,281,067 bytes.** It stops at the CodeTracer low-level event stream and emits it as an ordered op list. |
| `ct_writer.wasm` | the page's own Path A writer, already there, already used by the public half. It gains **one export pair** for this: `ct_source_step` / `ct_source_steps_written`. |

**The Noir tracer links no container writer on this path at all**, so `JOIN-SHAPE.md` §2's facts 6
and 7 are untouched and `wasm/webpage` stays unpublished. This is a different answer to the same
need rather than the answer OQ-7 ruled out.

### 3a. Why `ct_source_step` had to exist

`ct-writer`'s `emit()` — the one place both OQ-6 arms write a step — records five variables per
step: `opcode`, `contextId`, `l2Gas`, `daGas`, `contractAddress`. **A Noir private frame's step has
none of them.** Writing the private half through `ct_step` would mean the host inventing four
counters per step, which is the exact shape M29 found in M27's synthesised opcodes.

`ct_writer.wasm` goes **262,693 -> 263,211 bytes**, sha256 `e94bacebd…`. Still zero imports.

### 3b. THE RESULT, MEASURED IN CHROMIUM

| | measured |
|---|---|
| steps the tracer produced | **66** |
| …carrying a COLUMN | **64** (the two without are the frame-entry steps, one per frame) |
| frames | **2** |
| `Call` / `Return` written | **1 / 1** |
| ops replayed into the writer | **147** |
| paths interned | **78** |
| container bytes | **208,896** |
| the module's DECLARED imports | 4 |
| the module's REACHED imports | **0** |
| `ct-print --full` over it | **exit 0**, 66 Step records, the nested `Call` carrying the caller's address, the join record |

`reachedImports: []` is a measurement rather than a build flag: every declared import is satisfied
with a function that records the call and then throws, so nothing in the tracer crossed back into
JavaScript.

### 3c. THE DIFFERENTIAL: TWO INDEPENDENT IMPLEMENTATIONS, POSITION FOR POSITION

The native probe (M38's, Nim writer, `std::fs`) and this module (wasm, `MemorySink`, Path A) are
two implementations of the tape executor, deliberately — one is native and read by two milestones'
checks, and moving its executor into a library would move their figures. What ties them together is
a measurement:

| | native container, through the pinned reader | the wasm module |
|---|---|---|
| steps | **66** | **66** |
| `(path, line)` sequence | — | **identical, all 66** |
| column differences | — | **2** |

and the two differences are at step **0** and step **38** — the frame-entry steps, one per frame —
where the tracer emits NO column and a column-aware container's decoder answers 1. Everywhere the
tracer produced a column, the two agree.

### 3d. THE COLUMN REACHES THE CONTAINER, AND THAT IS A DIGEST PAIR

The pinned reader renders a Path A container through its legacy `events.log` path, whose `Step`
record is `(path_id, line)`. Reading the absence of a column THERE as "the browser's container has
no columns" would be a fact about the reader stated as one about the container.

Measured instead, by writing the same transaction twice with one field changed:

| arm | container bytes | sha256 |
|---|---|---|
| `bothHalves` (the real columns) | 208,896 | `d53fc677…` |
| `columnsDropped` (every step column 0) | 208,896 | `d7da2342…` |

Same ops, same steps, same paths, same size — different digest.

## Step 4 — THE JOIN CLOSES

Both containers are written **in one Chromium page, from one execution of one transaction**, and
`joinRecordings` accepts the pair:

```
JOINED  joinId=0x0330099ccfa1701224ce448435ee4c05056c78d43802126cf581af8567a9b1b5
        arm=split  order=[private, public]
ONE HALF ALONE -> refused, ground=count-mismatch
```

The identity is the outer frame's own `argsHash` — a value the circuit committed to — so two runs
of one transaction agree and two transactions cannot collide.

## Step 5 — THE CHECKS, NAMED AFTER THE ENTRIES THEY CLOSE

`just verify-m40` — **132 assertions, 0 failures, 2/2, exit 0**:
`e2e_joined_public_half_executed` **60**, `e2e_joined_private_public_trace` **72**.

The names are the milestone entries', deliberately. The convention is that a non-`pending` entry
names a `file:` that exists and CONTAINS the named test, and `verify_named_checks_exist` refuses a
check name in this repository's sources that resolves to nothing — so naming the entries in a check
header would have created two unresolved names. Naming the checks after the entries satisfies both,
and is what M39 already does.

### Two defects in the checks' own first runs, both found by running them

1. **A comment inside a single-quoted `python3 -c` program carried an apostrophe**, which CLOSED the
   program. Every field answered the empty string and sixteen assertions compared it against real
   values — loudly, which is the cheap direction, but a comment that terminates the program it
   documents is worth recording.
2. **The split-versus-legacy reader discriminator asked whether ANY event carried a `kind`.** A
   `Type` event carries `kind: "tkNone"`, so a Path A container read as `split` and `withColumn`
   answered **0** where it has to refuse to answer at all. An instrument that cannot see the subject
   must SAY so — `m40_container` answers `NOCOLUMNS` from that rendering now, and the discriminator
   is the reader's own `counts` object.

## Step 6 — WHAT MOVED ELSEWHERE, AND EVERY FIGURE IS THE CHECK'S

| document | figure | was | is |
|---|---|---|---|
| `TRACE-ABI.md` §7 | `ct_writer.wasm` bytes | 262,693 | **263,211** |
| `TRACE-ABI.md` §7 | its sha256 prefix | `5edf9671` | **`e94baceb`** |
| `TRACE-ABI.md` §2 | the whole OQ-6 arm table | run 10 | **run 11** |
| `TRACE-ABI.md` §8 | retained runs | ten | **eleven** |
| `BROWSER-GATE.md` §3 | browser metafile inputs | 1,196 | **1,198** |
| `BROWSER-PACKAGING.md` | four eager rows + the total | | **8,239.78 KB** |
| `WORKER-NODE.md` §5 | seven current-column rows | | |
| `DEV-WALLET.md`, `PRIVATE-EXECUTION.md`, `LOCAL-HISTORY.md` | the wallet / wallet-demo eager pair | | **307.17 / 352.88 KB** |

**The OQ-6 benchmark re-ran because this pass edited `ct-host/src`**, which is exactly what
`CAMPAIGN-BRIEF.md` says buying a comment there costs. §2 is re-rendered from the new `arms.tsv` by
`m24-render-trace-abi.py` and **run 11 joins §8's retained table at +1.07 %, [+0.36, +1.78] %** —
run 2's sign, run 10's size, on a fifth distinct module, `within-noise`. The control reads +0.22 %
with an interval straddling zero, which is the instrument saying it cannot resolve a difference
between two byte-for-byte identical arms.

### AND M39's ARMS WENT RED, WHICH FOUND THE CLASS-ID DEFECT'S SHARPER FORM

`classIdOf` did not simply hash the wrong thing. **It had TWO KINDS OF CALLER**: the wallet demo
hands it a `loadContractArtifact`ed Token whose `bytecode` is BYTES, and `privateContractInstance`
hands it a RAW artifact whose `bytecode` is base64 TEXT. One caller was right and the other wrong,
and both produced a well-formed class id.

And the first fix — routing everything through `loadContractArtifact` — **cannot load an
anchor-line artifact at all**: measured on both lines, the `deletion_era` Parent loads and the
`cpp`-anchor one fails with `Cannot read properties of undefined (reading 'find')`. M39's
`anchorLine` arm derives an instance for exactly one of those in order to measure that this runtime
cannot execute it, so the throw replaced a measurement with a page error. A fourth instance of
read-the-anchor-versus-read-the-pin, found by M39's arms rather than by reading.

`publicDispatchBytecode` reads the shape, refuses a third kind by name, and is the ONE derivation
both routes go through.

## Step 7 — THE MUTATION MATRIX, RE-TAKEN AFTER THE LAST EDIT

| arm | subject | result | what it killed |
|---|---|---|---|
| P1 | the calldata hash comparison is removed | 1 / **2** | the CONTROL stops refusing, so `m38_absent` names the absent field and the check dies with a summary line |
| P2 | the initialization nullifier is seeded unconditionally | 60 / **1** | exactly the assertion written for it |
| P3 | the class id is the base64 TEXT's commitment again | 60 / **9** | the whole execution — 1 instruction, opcode 68, 1 context, `revertCode` 1 — plus the class-id pair and a document row |
| P4 | `ct_source_step` ignores its column argument | 72 / **1** | the digest pair, and nothing else can see it |
| P5 | the nested frame's `Call` op is never emitted | 72 / **2** | the container's call count and a document row |
| P6 | the op list carries no column, while the report still counts them | 72 / **2** | the column identity AND the digest pair |
| P7 | the browser arm run HANGS (bound cut to 20 s) | **0 / 1**, rc **137**, bound NAMED | the precondition, with a summary line at column 0 |
| P8 | the browser arm report is truncated | 1 / **2** | the precondition, through the second of `m38_absent`'s three spellings of absence |
| demo | `still_there` over a silently undone mutation | exit **5** | — |

`HARNESS: restored; manifest verified`; no `MUTATION MISS`, no `DID NOT HOLD`; tree clean after.

**P7 is a hang and not a die-before-summary wearing a hang's label.** The rc is 137 — `timeout`
escalating to SIGKILL — because the arm holds a LIVE TIMER. A promise with no pending handle exits
13 and an `await` in a synchronous function exits 1, and this campaign has written both by accident.

### THE MATRIX FOUND TWO THINGS IN M40's OWN WORK, AND THE FIRST IS THE CAMPAIGN'S COMMONEST SHAPE

1. **P6's first run killed ONE assertion where it should have killed three.** The arm makes the
   module emit `column: 0` in every op while leaving its own `stepsWithColumn` at the real figure —
   and §2's column identity stayed GREEN, because it was **reading the producer's report about
   itself rather than what the producer produced**. Only the digest pair noticed.
   `recordPrivateHalf` counts the columns it passes to `ct_source_step` now — the boundary the
   container is on the other side of — and the control's count is asserted ZERO at the same
   boundary, because an arm that set a flag and wrote the columns anyway would give two equal
   digests and read as "the column does not reach the container". **72 assertions, up from 70.**
2. **P5's first form was killed by a GUARD rather than by the assertions it was written for.**
   Dropping only the `Call` op leaves the `Return`, and `ct_return` with no frame open is
   `CT_ERR_NO_FRAME` — so the writer threw before a container existed and the check died at its
   precondition. Both ops are dropped now.

**And P6's first needle MISSED**, because a formatter had split the line it named across four.
`sub` reported `MUTATION MISS`, restored the tree, verified its manifest and exited **3** without
printing a result.

## Step 8 — THE SWEEP WAS ABORTED ONCE, AND THE ABORT BOUGHT AN ASSERTION THAT COULD NOT FAIL

Killed at m4, fifteen minutes in, every child confirmed gone, `carry/*.json` unchanged against the
pre-sweep digests and the tree clean. The only work a sweep leaves is reading your own checks, and
that is where this campaign's aborts keep finding things.

**§6's `no M40 file reaches for the unpublished worktree` was the second form on this campaign's
own list.** One assertion — `grep -l 'noir-wt4-webpage' <seven files> | grep -cv <the one
legitimate mention> == 0` — and a needle that silently stopped matching drives it to 0 as surely as
a clean tree does. The ONE file that legitimately mentions the worktree is the build script's
header, which records why it builds from `noir` instead, and **nothing asserted that it was found**.

It is the paired zero now: the mention IS found where it is expected, and it is found NOWHERE else,
with the set size and the files' existence asserted beside them so "no other file mentions it"
cannot be "no file was scanned". **Calibrated in both directions**: a planted mention in
`run_m40_trace_arms.mjs` fires the second assertion and names the file, and breaking the needle to
`noir-wt4-webpageXX` fires the first.

**And the two CHECK files were dropped from the scanned set, which is a decision rather than an
omission.** This check names the worktree because it asserts a fact about it; a scan that included
itself would be an assertion about the check instead of about the code M40 ships.

**M40 goes 132 -> 135.**

## Step 9 — THE SWEEP WAS ABORTED A SECOND TIME, FOR THE HALF OF THE WRITE-UP NOTHING COMPARED

Killed at m1, six minutes in, every child confirmed gone, `carry/*.json` unchanged and the tree
clean.

**`m38_assert_doc` closes a write-up's BOLD NUMBERS and nothing closed the other half.**
`BOTH-HALVES.md` quotes eight ABBREVIATED values — `0x124ef545…`, `0x2b667ab5…`, the two class ids,
the two container digests, the join identity — because a sixty-six character hex string is
unreadable in a table. **Every one of them was prose.** That is M38's second abort finding one
kind of figure over: *thirteen of a write-up's twenty-six figures stated and compared by NOTHING,
under a header claiming all of them were re-derived on every run.*

`verification/_m40_doc_prefixes.py` compares each against the artefact's own value, on the ROW that
names its subject, and **the ellipsis is required**: a token that does not end in one is refused as
MISSING rather than compared as a prefix of itself, so a document quoting a whole value cannot pass
by accident. Calibrated over this document in both directions — `d53fc677…` changed to `dEADbeef…`
is reported `BAD`, and `` `pub_set_value` `` (a token with no ellipsis) is reported `MISSING`.

### Three things the same read found

1. **`(10 and 20)` was prose too.** The fixture's whole point is that its two enqueued calls differ
   by their ARGUMENT and not by their function, and the check compared the two HASHES and never the
   values behind them. It is a table row now — **10** and **20** — read out of the CALLDATA on
   every run, walked over the frame tree and sorted by the circuit's own side-effect counter, with
   the two asserted DIFFERENT beside it.
2. **The join identity was stated TWICE**, in two lines of one code block, and re-derived nowhere.
   It is stated in exactly ONE place now and elided in the block, which shows the grammar: a figure
   written twice is a figure that can rot in one of the two.
3. **A row's first backticked token is not always its value.** `over the decoded
   `public_dispatch` bytecode` names a FUNCTION first and quotes the class id second, and a comparer
   taking token 0 would have compared a class id against a function name. It said `MISSING` rather
   than passing — the ellipsis rule doing exactly what it exists for.

**And the argument extraction met `Argument list too long`**: the arm report's `run` node is 157 KB
and passing it as an argv is a bare exec failure with nothing naming the cause. It reads the report
from the file now. **And a `#` comment inside a `\` continuation ENDS the command**, so the specs
below it became a separate command and the comparison silently shrank — found because the covered
count is asserted against `$#`.

**M40 goes 135 -> 145.**

## Step 10 — THE FIRST FULL SWEEP: 13,372, `delta +0`, NO HOLE, AND TWO OF THE SIX REDS WERE MINE

Measured M0–M40 on 2026-09-02, `setsid`-detached in this repository's own dev shell (node
v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`. **82 markers for 41 milestones, no hole. 35 of 41 exit 0.** Polled INSIDE the agent's
own run in nine-minute blocks — **five background waiters were killed by the harness** while the
sweep ran on, which is why the campaign's rule is what it is.

```
m0 156   m1 181   m2 293   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 807
m10 450  m11 287  m12 691  m13 458  m14 460  m15 537  m16 225  m17 297  m18 578
m19 180  m20 237  m21 451  m22 349  m23 512  m24 350  m25 454  m26 340  m27 345
m28 358  m29 127  m30 218  m31 450  m32 237  m33 248  m34 217  m35 239  m36 150
m37 171  m38 150  m39 205  m40 145
                                                       CAMPAIGN TOTAL 13,372
```

**Every one of M0–M39 came out at its reference value TO THE ASSERTION**, and 13,227 + 145 = 13,372
exactly. **M9 DID NOT FLAKE** — 807, rc 0, **1,283 s**, immediately after m8's **179 s** build,
which is D19's standing condition, present and not firing. M15 did not either (537, 383 s).

### FOUR OF THE SIX REDS ARE OTHER TRACKS' AND TWO WERE M40's OWN

| milestone | count | what | whose |
|---|---|---|---|
| m11 | **287, unchanged**, 8 failures | the **ELEVENTH** upstream move: `upstream/next` `7471a61f1a` -> `89b3b1c14505b8595e4bc5cd3499dda1bf7e8d81` | **upstream's** |
| m20 | 237, unchanged, 1 | `verify_named_checks_exist` on L3's and L2's two names | **L3's and L2's** |
| m21 | 451, unchanged, 1 | `verify_no_pipeline_predicates`, a sixth `\| grep -q` | **L4's** |
| m28 | 358, unchanged, 1 | `verify_npm_pack_no_optional_native`, `replay/package.json` as an extra tree | **L0's** |
| m25 | 454, unchanged, 1 | **M40's**: the export union is 38 and the check asserts 36 | **mine** |
| m26 | 340, unchanged, 2 | **M40's**: the same union, and `JOIN-SHAPE.md` §7's module size | **mine** |

**Every count is unchanged in all six, which is what says a pinned list moved and not a structure.**

`ct-host` gains a FOURTH export list, `SOURCE_STEP_EXPORTS`, for the reason the third is in its own:
appending to another milestone's list moves that milestone's assertion count for a change that is
not its. M25's and M26's checks assert the union is "exactly the THREE lists" at 36; both now name
M40's two and assert the FOUR lists at 38. **m25 454 -> 455, m26 340 -> 341.**

And `JOIN-SHAPE.md` §7 stated the module's size as the join surface's own arithmetic
(259,839 -> 262,693), which a later milestone growing the module makes false in one of the two
numbers. It states the CURRENT size as its own figure now, with the delta kept as the historical
measurement it is.

### AND A `git add -A` COMMITTED THE TWO FILES THE SWEEP REWROTE

**A sweep is a writer**, and `verify-m11` rewrites `carry/exposure.json` and `carry/rebase.json` to
the current `upstream/next` on every run. The procedure is to checksum before and restore after;
what happened here is one step worse than forgetting the restore — the next commit's `git add -A`
picked the rewrites up and **committed** them.

That is the half-repair the brief names: the two files would have recorded the eleventh upstream
move while `carry/overlap.json` and `CARRY-LEDGER.md` still record the tenth. Three files move
together or the ledger and the data disagree, and the decision half of that repair is M11's rather
than a milestone that happened to run its check. Both restored to `HEAD~1`; the digests are back to
`3836c2b6…` and `79f597b2…`, which are the post-sweep values every run since M30 has produced.
