<!-- The M26 verdict. `verify_oq7_shared_writer_verdict_recorded` re-derives every figure in §2, §3
     and §5 from `~/.cache/aztec-m26-join/join.json` and from the two Noir checkouts on every run,
     and fails if this file and the measurement disagree. Do not edit the numbers by hand; re-run
     `just join-arms` and copy what it prints. -->

# Joining the private and public halves — OQ-7, settled

This file is to M26 what `SOURCE-MAPPING.md` is to M25 and `TRACE-ABI.md` is to M24: the verdict,
the evidence it rests on, the rejected option's measurements retained so the decision can be
revisited without redoing the work, and the consequences for the milestones that depend on it.

---

## 1. The question

> **OQ-7.** Can the Rust-side Noir tracer and the TypeScript-side runtime share one writer instance
> across the language boundary?

M24 answered the half it could. The module holds **one** global session: a second `ct_writer_open`
returns `CT_ERR_ALREADY_OPEN` (−7), and a wasm instance's linear memory is its own. So "share one
instance" cannot mean "open two writers"; it can only mean **one module instance with two
producers**.

---

## 2. The verdict, in one line each

> **Sharing is POSSIBLE and is demonstrated on one container. It is NOT SHIPPABLE, and the reason
> is publication rather than capability. The fallback — two containers, each carrying an explicit
> join record — is the shipped path.**

| # | fact | how it was established |
|---|---|---|
| 1 | one wasm instance holds **one** writer | ran it: a second `ct_writer_open` returns **−7**, `a writer is already open; call ct_writer_close first` |
| 2 | two instances **do not** share | ran it: two instances in one node process, disjoint pcs, **6** and **4** events, containers not byte-identical, each carrying only its own |
| 3 | `noir_tracer` is **writer-agnostic** | read it: `trace_circuit(…, tracer: &mut dyn TraceSink)`, and its `codetracer_trace_writer` dependency is `optional = true` behind a `nim-writer` feature whose default is off |
| 4 | a `TraceSink` over the pure-Rust writer **already exists** | read it: `tooling/tracer_wasm/src/ctfs_sink.rs`'s `CtfsSink` |
| 5 | so one module with both producers **works** | built and ran it — §3 |
| 6 | but the shipping Noir branch links a **different writer** | read it: `noir/Cargo.toml` resolves `codetracer_trace_writer` to `codetracer_trace_writer_nim` — DD-7's **Path B** — while this runtime is Path A |
| 7 | the branch where both resolve **Path A** is `wasm/webpage`, and it is **unpublished** | `git for-each-ref refs/remotes --contains` is empty for its HEAD |

**Facts 6 and 7 are the verdict.** *A pin that is not published is not a pin, it is a local file*
(`CAMPAIGN-BRIEF.md`, and M24's review paid for that sentence). Every anchor in `pins.json` must be
reachable from a published remote ref, and the only tree in which the two halves link the same
writer crate is not. Shipping the shared path would mean pinning a commit that resolves on one
machine — which is the exact defect M24's review found and fixed, reintroduced deliberately.

**And fact 6 is not a packaging accident.** On `wasm/webpage` the pure-Rust writer is present under
a *second* alias, `codetracer_trace_writer_rs`, used only by `tracer_wasm`; that file's own comment
says *"It is NOT used by `nargo trace`"*. So even there, the tracer the Noir campaign ships writes
Path B containers and this runtime writes Path A ones.

---

## 3. The demonstration: one writer, two producers, one container

`verification/oq7_shared_writer_probe.rs`, built by `verification/build_oq7_shared_writer_probe.sh`.
One `CtfsTraceWriter`; the **real** `noir_tracer` compiling and executing a **real** Noir program
through a `TraceSink` that borrows that writer; then the AVM half reproducing
`ct-writer/src/lib.rs`'s `emit()` call for call. Read back by the pinned `ct-print`:

```
FRAME 0  depth 0  <toplevel>                  31 steps
FRAME 1  depth 1  main                        31 steps      <- the Noir program
FRAME 2  depth 2  foo                          6 steps
FRAME 3  depth 3  bar                          3 steps
FRAME 4  depth 2  foo                          6 steps
FRAME 5  depth 3  bar                          3 steps
EVENT             ct.trace-join   join=… half=both halves=1 arm=shared reason=…
FRAME 6  depth 2  Token.transfer_in_public     6 steps      <- the AVM, enqueued call 1
FRAME 7  depth 2  Token.balance_of_public      6 steps      <- the AVM, enqueued call 2
```

146 events, **32 steps**, 8 calls, 6 returns, 2 paths, 1 join record — and the two public
frames open at **depth 2**, inside `main`, in the order the transaction enqueued them.

**The public frame is nested inside the private frames.** `main` and `<toplevel>` have not returned
when it opens, which is not an ordering trick: an Aztec transaction's enqueued public calls really
do run after the private half has finished, and the private half is what enqueued them. So a
private-half step and a public-half step are distinguishable **by frame** — the public ones are
inside a `Call` whose function id was interned from the contract's own **debug function name**,
`Token.transfer_in_public`, which is upstream's `getDebugFunctionName` and not a label this
repository invented — rather than by inspecting what a step's variables happen to contain.

**What the probe is NOT.** It is not shippable and this file does not pretend otherwise. It is
built from a worktree rather than from a pin, for the reason §2 gives. It exists so that "sharing
is possible" is a container somebody can open rather than a paragraph.

---

## 4. The fallback, which is a deliverable rather than a consolation

Two containers, **each carrying the same explicit join record**, and nothing inferred.

```
ct.trace-join   join=<id> half=private halves=2 arm=split reason=recorded-by-the-producer-not-inferred-by-a-reader
ct.trace-join   join=<id> half=public  halves=2 arm=split reason=recorded-by-the-producer-not-inferred-by-a-reader
```

**Why `halves` is in the record.** Without it a reader handed one half of a two-half join cannot
tell it from a whole recording. With it, an incomplete join is a refusal rather than a smaller
answer — which is the same shape as this campaign's "a check that dies reads as a smaller milestone
rather than a red one", one level down, in the data.

**Why the record is in the container and not in a sidecar.** Two `.ct` files that sit in one
directory, share a filename stem, or were written a second apart *look* joined, and a reader that
decides they are will be right almost every time and wrong on the run that matters — two
transactions recorded concurrently, a directory somebody copied files into, a stem that collided.
None of those is detectable afterwards, because the evidence a reader would need is exactly the
evidence nobody wrote down.

**What it cost the module: six exports, in their own `JOIN_EXPORTS` list.** `ct_log_event` and
`ct_log_event_count` for the record itself; `ct_call`, `ct_return`, `ct_call_depth` and
`ct_calls_opened` for the FRAMES. Without the first pair the shipped `ct_writer.wasm` cannot write
a join record at all; without the second it can only write a flat step stream, and *"a private-half
step and a public-half step are distinguishable by frame"* is not a property a flat stream has
however its steps are labelled. Either gap would have left M26 demonstrating that a *probe* can
produce a joined recording while leaving open whether the runtime can.

So the public half of the `split` arm is written **by the shipped module**: the join record through
`ct_log_event`, the rung declaration through `ct_declare_rung`, one frame per enqueued call through
`ct_call` / `ct_return`, the steps through `ct_ingest` — and read back through the pinned reader as

```
FRAME 0  depth 0  <toplevel>                  12 steps
FRAME 1  depth 1  Token.transfer_in_public      6 steps
FRAME 2  depth 1  Token.balance_of_public       6 steps
EVENT             ct.trace-join   join=… half=public halves=2 arm=split reason=…
EVENT             ct.mapping-rung 0x3051e7a9… rung=1 reason=artifact Token …
```

`ct_call_depth()` and `ct_calls_opened()` are both exported because neither alone is enough: a
recording with no frames and one whose frames all closed both end at depth 0.

`orchestration/src/trace_join.ts` owns the grammar and the joining. `joinRecordings` **refuses** on
five distinguishable grounds, each named in the throw: `unrecorded`, `identity-mismatch`,
`count-mismatch`, `duplicate-half`, `arm-mismatch`. A function that returned a best-effort join
would put the whole file back where it started, so there is no such function.

**The `shared` arm still writes a join record**, with `half=both halves=1`. A one-container
recording that says so is read by the same consumer as a two-container one, and the alternative —
no record when there is one file — would make "no join record" mean two different things.

### `TxProvenance.privateTrace` — the handle that joins them

M21 declared the field and left its shape to M26, saying that a type written from a deliverable's
wording rather than from the thing it describes is this campaign's own recurring defect. There is a
thing to describe now, and `PrivateTraceHandle` carries exactly what a consumer needs to OPEN the
recording: the **join identity** (the same string the containers' `ct.trace-join` records carry),
**how many halves** it has, and **which arm** produced it. It is derived FROM the record by
`privateTraceHandleFor`, not assembled beside it, so a handle and its recording cannot disagree
about which join they belong to — the same property `joinRecordings` enforces between two
containers, one level up.

**What is deliberately NOT in the handle is a file path.** A handle carrying one would make the
join a fact about a filesystem, which is what this whole section argues against. And nothing about
the RECORDING travels on the provenance, because DD-1 says provenance is metadata alongside the
transaction and M20's seal traps every read of it during the execution window: what travels is a
name, and there is nothing in it worth branching on.

---

## 5. Cross-half agreement: one field element, one spelling

M25 settled OQ-4 for the public half (`SOURCE-MAPPING.md` §4) and located the Noir half's
divergence at `noir/tooling/tracer/src/tracer_glue.rs`. **M26 applied it.** Both Noir checkouts —
`noir` on `blocktracer`, and the `noir-wt4-webpage` worktree the probe builds from — now render
`Field` as `ValueRecord::String { text: "0x" + 64 lowercase big-endian hex }` under the same
`(TypeKind::Int, "Field")`, and the build script asserts the two rendering lines are identical
between them so the demonstration and the shipped fix cannot drift.

Measured on the `shared` container, through the pinned reader:

| where | value | rendering |
|---|---|---|
| private half, Noir `x` | `0x0000…0004` | `ValueRecord::String`, 66 chars |
| private half, Noir `y` | `0x0000…0005` | `ValueRecord::String`, 66 chars |
| public half, contract address | `0x3051e7a94116d0ade3f33411a29365e1f0bd72d615eb9ca89705dc6d6da9076d` | `ValueRecord::String`, 66 chars |

**32 `String` values and 48 `Int` values** in that container, and the split is the point: the 48 are
`opcode`, `contextId`, `l2Gas` and `daGas`, which are counters and not field elements. "Everything
became a String" would satisfy a check that only looked at the fields; the counts are asserted in
both directions.

**The cost is recorded rather than glossed.** A small Noir `Field` now reads as
`0x000…04` instead of `4`, which is worse for an ordinary Noir program and is the price of one
spelling across the join. `SOURCE-MAPPING.md` §4.4 keeps the rejected option — fixing `BigInt`'s
CBOR encoding in the shared `codetracer_trace_types` crate — with the reason it is a decision above
this milestone.

---

## 6. What would reopen this

- **`wasm/webpage` published, or the Noir tracer's `codetracer_trace_writer` repointed at Path A on
  the branch it ships from.** Either removes fact 7 or fact 6, and the shared path becomes
  pinnable. Nothing else in §2 has to change.
- **A second consumer of `ct_log_event`.** The export is generic on purpose; a third record kind
  needs no third export, so the module does not move again.

> **WHY `noir-wt4-webpage` IS LEFT WITH AN UNCOMMITTED EDIT, DELIBERATELY.** That worktree carries
> one uncommitted change — OQ-4's `Field` rendering in `tooling/tracer/src/tracer_glue.rs` — and
> M26's review left it that way on purpose rather than tidying it. Committing it locally would make
> an unpushed commit, which this campaign's own rule calls a local file. **Pushing it would publish
> `wasm/webpage`, which is fact 7 above** — the fact the entire "not shippable" verdict rests on —
> and §6's first bullet names publishing that branch as one of the two things that would REOPEN
> OQ-7. `verify_oq7_shared_writer_verdict_recorded` asserts the branch's HEAD is contained in ZERO
> published remote refs and would go red the moment it were pushed. Reopening a settled question is
> not something a tidy-up should be able to do by accident. Nothing about the demonstration depends
> on the commit: `build_oq7_shared_writer_probe.sh` tolerates exactly this one edit by name
> (`ALLOWED_EDIT`), refuses any other, stamps the probe on the file's SHA rather than on `HEAD`, and
> asserts the rendering is identical in both checkouts.
- **A private half that actually executes here.** M21 measured why it does not: `@aztec/pxe`
  hard-depends on `@aztec/simulator`, which hard-depends on `@aztec/native` and
  `@aztec/world-state`, and beneath that sit 68 oracles of which none exists in this workspace. The
  private half in §3 is a real Noir program traced by the real Noir tracer, and it is **not an
  Aztec private function**. That is the gap between M26 as delivered and M26 as specified, and it
  is stated here rather than left for a reader to notice.

---

## 7. Consequences for the milestones that depend on this

### M27 / M28 — browser packaging and the no-Node gate

- The join surface adds **2,854 bytes** to the module, 259,839 → **262,693 bytes**, and **no
  imports**: the count is still 0 and the module still instantiates under a bare
  `WebAssembly.instantiate(bytes, {})`. `TRACE-ABI.md` §7 re-derives that figure from the built
  artefact on every run, so the two documents cannot disagree about it.
- `orchestration/src/trace_join.ts` imports nothing — no npm package and no Node module — so the
  join grammar is available to a browser host unchanged. The CONTAINER READING is not: decoding a
  `.ct` needs a reader, and this repository's is the pinned `ct-print`, which is a native binary.
  M27 owns what a browser reads a container with.
