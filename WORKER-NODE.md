# The worker-hosted dev node — what was reused, what was measured, and what does not survive

M32's write-up.

**Every figure this document states is re-derived by one of M32's four checks and compared against
this file on every run**, and each is looked for on the line that NAMES ITS SUBJECT rather than
anywhere in the file. That sentence is here because M27's identical sentence was **false**: no check
opened `BROWSER-PACKAGING.md` at all, and eleven of its figures had rotted before its review measured
how many. Which check owns which section is stated at the head of each section, so a reader can find
the instrument rather than take the number.

Two kinds of number appear below and they are marked differently. A **derived** figure is a property
of the artefacts and is asserted. A **recorded run** is a property of the moment it was taken — a
block count under a four-second spin depends on the scheduler — and is labelled as one run and *not*
asserted; what is asserted about it is the invariant underneath. M27's §8 timer table is the
precedent, and it is the right one.

---

## 1. What already existed, and the two rejections with their reasons

**Owned by `smoke_worker_chain_survives_main_thread_block` §4–§5.**

The campaign has been wrong nine times about whether something needed building, and every miss was a
*parallel subdirectory*. So the enumeration came first.

| what M32 needs | what exists | verdict |
|---|---|---|
| a page-side client + worker script + protocol declaration | `yarn-project/end-to-end/src/test-wallet/` — `worker_wallet.ts` (216 lines), `wallet_worker_script.ts` (66), `worker_wallet_schema.ts` (14): upstream hosting a **wallet in a worker** | **REUSED, as a shape.** The protocol is an `ApiSchema` of `z.function({input, output})` driven by `schemaHasMethod` / `getSchemaParameters` / `parseWithOptionals` / `getSchemaReturnType`, with `jsonStringify` out and `JSON.parse` + schema in, on both ends. `worker_protocol.ts` is the same kind of object over this runtime's facade |
| the value codecs that cross the boundary | `Tx.schema`, `ContractClassPublicSchema`, `ContractInstanceWithAddressSchema`, `AztecAddress.schema`, `schemas.Fr`, `schemas.BigInt`, `schemas.Integer` | **REUSED unchanged.** Nothing here invents a wire format for somebody else's type |
| a browser worker transport | `comlink` 4.4.2 — what **upstream's own browser worker uses**: `barretenberg_wasm_main/factory/browser/main.worker.ts` is `expose(new BarretenbergWasmMain()); postMessage(Ready)` and `helpers/browser/index.ts` is `wrap<T>(worker)` plus a `readinessListener`. It is a runtime `dependencies` entry of **`@aztec/bb.js`**, which is how it is already installed here. (This row said "a declared dependency of **both** `@aztec/bb.js` and `@aztec/foundation`". Measured by M32's review: `@aztec/foundation` lists it under **`devDependencies`**, which a consumer does not install, so the reuse rests on bb.js alone) | **REUSED.** Builds for the browser with zero unresolved builtins |
| a richer transport | `@aztec/foundation/transport` — `TransportClient`, `TransportServer`, `Socket`, `Connector`, `Listener`, `Transfer`/`TransferDescriptor`, 787 lines. Its own `Socket` docstring says *"implementations could use e.g. MessagePorts for communication between browser workers"* | **REJECTED, `cannot-reach-target`, and the reason is a measurement.** Only the NODE sockets ship (`node/node_connector.ts`, `node/node_listener.ts`, over `worker_threads`); the package exposes `./transport` as a barrel and has **no wildcard subpath**, so the browser-safe half cannot be imported alone. Built for the browser with this build's four existing shims applied it leaves **4 unresolved Node builtins: `events` ×3 and `worker_threads` ×1**. Reaching it would mean adding an `events` shim and neutralising a node-only submodule inside the artefact whose whole CI gate (M28) is "no Node builtins" |
| the download | `offerDownload` in `browser/src/ct_download.ts` — four lines of DOM | **STAYS ON THE PAGE.** A worker has no `document`. This is the one thing in the browser package that cannot cross, and it is why the container had to |

**The rejection is a measurement, not an opinion**, and it is stated in
`browser/src/entry_worker.ts`'s header beside the code it explains.

---

## 2. The protocol

**Owned by `smoke_worker_chain_survives_main_thread_block` §4.**

- **19 operations** on the schema channel, declared in `browser/src/worker_protocol.ts` as
  `AvmWorkerNodeSchema` and exported from the built `worker.js` so a check reads them out of the
  ARTEFACT: `advanceBlocksBy`, `blocks`, `close`, `containerBufferState`, `exportSnapshot`,
  `fundFeeJuice`, `importSnapshot`, `injectL1ToL2Message`, `open`, `produceBlock`, `receiptFor`,
  `recordContainer`, `registerContract`, `runTokenTransfer`, `start`, `state`, `stop`,
  `submitExternal`, `submitLocal`.
- **Both submission forms are there and they are different calls.** `submitExternal` takes a `Tx`;
  `submitLocal` takes a `Tx` and builds Form B's provenance with `locallyOriginatedTx` on the worker
  side, so the page cannot choose a provenance string.
- **3 subscriptions** — `block`, `tx`, `trace` — delivered through a `Comlink.proxy` callback with
  each event `jsonStringify`d.
- **2 operations are off the schema channel, and both are declared by name with their reason** in
  `WORKER_OFF_SCHEMA_OPS`: `takeContainer` (megabytes; a JSON codec would copy them) and `subscribe`
  (a callback is not a value). The exposed surface is `call`, `subscribe`, `takeContainer` — three
  methods — and the check requires `exposed − {call}` to EQUAL the declared exceptions as a set, in
  both directions, so a third exception cannot appear undeclared.

### DD-5, mechanically

`WORKER_PROTOCOL_BACKING` names the symbol behind every operation, and the rule is M27's for
`NODE_CONVENIENCES` one step along:

```
{ operations whose backing symbol browser.js does not export }  ==  WORKER_TESTING_OPS
```

as a set, in both directions. Measured: that set is **exactly `runTokenTransfer`**, whose backing is
exported by `testing.js` and not by `browser.js` — M27's demo driver, which composes M26's vendored
transaction builder and lives in the testing entry by DD-5's own rule. Everything else is backed by
`openAvmRuntime`, `AvmRuntime` or `recordAndDownload`, all three of which the **reference** bundle
exports. An undeclared capability fails; a declaration for something the reference does export fails
too.

---

## 3. The main-thread measurement, and the control that discriminates

**Owned by `smoke_worker_chain_survives_main_thread_block` §6–§9.**

The parameters, which ARE derived and asserted — **one figure per row, each row naming its
subject**, because M29's review found a figure whose sentence wrapped between the number and the
thing it was a number of:

| parameter | value |
|---|---|
| block interval | **250 ms** |
| warm window | **4000 ms** |
| busy window | **4000 ms** |

The busy window is a synchronous `while (performance.now() - t0 < ms) {}` whose accumulator is
returned, so a loop an optimiser deleted would be visible.

Two pages, the same load, two windows each. **One recorded run, 2026-08-28:**

| where | warm window | busy window |
|---|---|---|
| worker      | 15 blocks | 16 blocks |
| main thread | 16 blocks | 0 blocks |

**The cell counts are a recorded run and are not asserted.** What is asserted on every run is the
pattern: both warm cells non-trivial, the worker's busy cell non-trivial, and the main thread's busy
cell **exactly zero**, with the two warm cells within two blocks of each other so the difference in
the busy column is attributable to where the runtime is and to nothing else.

The main thread's warm cell is what makes its zero mean something: a chain that produced nothing in
either window would be a broken chain reported as a stalled one.

**And a COUNT inside a window is not production during it.** Sixteen blocks between two readings is
equally true of a chain that stalled for 3.8 seconds and then delivered sixteen in a burst when the
thread came back — a backlog draining at the window's right-hand edge, which is the first reading a
sceptic should reach for. The count cannot tell them apart and the SPACING can, so the check measures
every interval **from the window's own opening onward** and requires none of them to exceed three
ticker intervals, with the warm window's worst spacing as the calibration. Measured: 252 ms in both
windows, at a 250 ms ticker. *This was added by M32's review, and its first form measured only the
gaps BETWEEN in-window blocks — over a doctored report with all sixteen blocks moved into the last
200 ms it reported 82 assertions and 0 failures, because a tight cluster looks like perfect cadence
when the stall in front of it is outside the span you measured. With the window's opening as the
first point the same report gives 3,812 ms and two failures.*

**The window edges are timed by whoever can time them.** In the worker arm the page cannot — being
unable to run code is the point — so the edges are the WORKER's own `performance.now()` readings,
carried back on `NodeState.atMs` from two `state()` calls the page posts and does not await.
`BlockSummary.producedAtMs` is on the same clock.

---

## 4. The transferable, measured by detachment

**Owned by `test_worker_transferable_container_not_copied`.**

One buffer, four readings, all taken by the WORKER of its own memory and crossed on the schema
channel:

| step | `present` | `byteLength` | `detached` |
|---|---|---|---|
| before any take | true | 196608 | false |
| after a COPY (no transfer list) | true | 196608 | false |
| after a TRANSFER | true | 0 | **true** |
| a second TRANSFER | refused by name — `ContainerAlreadyTransferred` |

The byte count is a recorded run (it is the container M29's step stream produces for this
transaction, currently 196,608 bytes); the **detachment pattern is the assertion**, and the copy is
the control that lives in the same code path as the thing it controls.

**And the sentence beside `detached` is exercised rather than written down — after M32's review
found that it had been written down and was FALSE.** It says `ArrayBuffer.prototype.detached` is the
platform's own answer rather than an inference from a zero length. But the only zero-length buffer in
the sequence above IS the transferred one, so an implementation computing `detached = byteLength === 0`
agrees with the platform at every point the check looks — and that is what `containerBufferState`
shipped: `detached: buffer.byteLength === 0` for the container, `empty.detached === true` for the
control beside it. **Two expressions, one of them the inference the other exists to rule out, and
nothing could see the difference.** The mutation arm written for exactly this (`m32-mutations.sh` M2)
could not apply its own first substitution — the needle `buffer.detached === true` was not in the
file — printed `MUTATION MISS`, mutated only the CONTROL, produced the one failure it had predicted,
and was recorded as coverage.

The remedy is not a corrected line. `containerBufferState` now has **one** reader,
`read(b) => ({byteLength: b.byteLength, detached: b.detached === true})`, and the container's reading
and the control's go through it. So the control controls the instrument the container is measured
with instead of a second copy of it; `{byteLength: 0, detached: false}` from a buffer that was never
transferred is the one combination an inference cannot produce; and M2 is now **one** substitution,
on `read`, which reddens exactly that assertion and nothing else. `sub` refuses to continue on a
miss, so a mutation that does not apply can no longer be printed as an arm that behaved.

The two paths deliver the **same bytes**: the page's SHA-256 of the copied container and of the
transferred one are equal, and both equal the SHA-256 of the file the browser's own download
machinery wrote to disk. A transfer that lost data would be a faster wrong answer.

---

## 5. Packaging: what the worker costs, and what it moved

**Owned by `test_worker_transferable_container_not_copied` §6 and by M27's
`verify_browser_chunk_budget`, which re-derives `BROWSER-PACKAGING.md`.**

The worker is built as two more entry points in the **same esbuild pass** as the browser, testing and
demo entries. Building it in a pass of its own would have given it a second copy of every shared
chunk and made "the worker adds no capability the browser reference lacks" a comparison between two
differently-built artefacts.

Adding them re-split the shared chunks slightly. Measured, before and after, in this repository's own
dev shell:

**AND M33 MOVED THE SECOND COLUMN AGAIN, WHICH IS WHY THE COLUMN IS LABELLED `current` RATHER THAN
`with M32`.** M33 adds a seventh entry point to the same pass (`wallet.js`, the wallet protocol
boundary) and esbuild re-partitioned once more. The middle column is what M32 measured and is kept,
because the *mechanism* — one more entry in one pass moves the boundaries — is what this section is
about, and a before/after pair with only one after is a pair nobody can check. The right-hand column
is what `test_worker_transferable_container_not_copied` §5 re-derives from `chunks.json` on every
run, so it is the one that cannot rot.

**AND M34 MOVED IT A THIRD TIME, DOWNWARDS, WHICH IS WORTH THE SENTENCE.** M34 adds an EIGHTH entry
(`wallet-demo.js`, the page that drives the wallet) and every eager total fell by roughly 0.7 KB
except the Node pass's, which is separate. That direction is the mechanism working rather than an
anomaly: a further entry sharing the same modules lets esbuild hoist MORE into chunks that several
entries already carry, and a chunk counted once is smaller than the same code duplicated. Nothing was
removed from any entry's graph, and the file counts are unchanged.

*(M34 added the `wallet-demo.js` row and did not add `wallet-demo.js` to
`test_worker_transferable_container_not_copied` §10's entry list, so it was the one row of this table
nothing re-derived — and it had already rotted, stating `309.51 KB` against a build reporting
`309.91`. M34's review put the entry in the loop; every row here is re-derived from `chunks.json`
now, three assertions each.)*

| entry point | before M32 | M32's measurement | current |
|---|---|---|---|
| `browser.js` | 255.79 KB, 7 files | 255.87 KB, 8 files | **263.10 KB, 9 files** |
| `testing.js` | 279.77 KB, 8 files | 279.93 KB, 10 files | **288.28 KB, 12 files** |
| `demo.js` | 280.97 KB, 8 files | 281.12 KB, 10 files | **289.50 KB, 12 files** |
| `node/node.js` | 225.36 KB, 4 files | 225.36 KB, 4 files | **225.49 KB, 4 files** |
| `worker.js` | — | 282.40 KB, 9 files | **290.78 KB, 11 files** |
| `worker-demo.js` | — | 283.48 KB, 11 files | **291.85 KB, 13 files** |
| `wallet-demo.js` | — | — | **309.99 KB, 13 files** |

`node/node.js` is unmoved in both moves, and for the same reason: the Node pass is a separate one.

*(The demo row was `290.12` when M33 wrote this and is `289.44` now; the point of the parenthesis
is the RULE and not the number. It is the CHECK's value and not the build's. `browser/build.mjs` prints
`+(gzip/1024).toFixed(2)` and the checks use Python's `round(gzip/1024, 2)`; the demo entry lands on
an exact rounding tie, so JavaScript rounds half away from zero and prints **290.13** while Python is
banker's and gives **290.12**. (That tie was M33's figure; M34's re-split moved the demo entry off it,
so the two agree again at 289.44 — which is luck rather than a fix.) `CAMPAIGN-BRIEF.md` records this happening to M32 at 281.125 and says
the document must carry the check's value; M33 wrote the build's here, `test_worker_transferable_container_not_copied`
went 71 / 2 in the sweep, and this is the correction. The next figure that lands on a tie will do it
again.)*

`BROWSER-PACKAGING.md` §1 and §6 are updated to the right-hand column, because
`verify_browser_chunk_budget` re-derives every one of those cells from `chunks.json` and compares.

**DD-11 travels with the worker, and it is asked of the log that can answer it.** A worker's fetches
are NOT in its page's network log — measured on the first run of these arms: the page's log carries
`/worker.js` and not `/assets/avm.wasm`. So the runner attaches to the worker's own CDP target,
enables `Network` there, and the absence is asserted over the WORKER's log with `avm.wasm` present in
it as the positive control. Asking the page's log would be an absence measured against a log that
excludes its subject by construction, which `CAMPAIGN-BRIEF.md` records twice as a defect that
shipped.

---

## 6. Throttling, re-established where it matters

**Owned by `smoke_worker_produces_blocks_while_throttled`.**

M27 verified monotonic timestamps under throttling **on the main thread**. A worker's timers throttle
differently, so inheriting that result would be inheriting a measurement of a different thing.

Two mechanisms are attempted and **what each one did is recorded rather than assumed**:

| mechanism | result |
|---|---|
| `Emulation.setCPUThrottlingRate` on the **worker's own** CDP target | **refused**: `Operation is only supported for pages, not workers` |
| `Emulation.setCPUThrottlingRate` on the page's target | accepted |
| `Page.setWebLifecycleState('frozen')` | accepted |

So CPU throttling cannot be aimed at a dedicated worker over CDP at all; the freeze is what reaches
it. That is a fact about Chromium and it is measured here rather than believed.

**And whether the freeze reached the worker is not taken on trust either.** The evidence is the
worker's OWN monotonic clock: `producedAtMs` is stamped inside the worker when a block is sealed, and
across the freeze it shows a gap of **at least two seconds** where every other consecutive pair is
about one block interval apart. A run in which neither mechanism reached the worker produces an even
chain and this check goes RED — which is the property M27's arm has for the main thread and which
this one had to earn separately.

One recorded run, re-taken by M32's review on 2026-08-29: 40 blocks, timestamps strictly increasing
and exactly one second apart, the freeze visible as a **4,226.9 ms** gap in the worker's own clock
between blocks 16 and 17 against a **252.0 ms** median, a **4-second** jump in the host clock across
the same pair, and the declared deviation collapsing from **11 to 8** — DD-4's second branch taking
over from the first, which is the whole point of an injected clock.

**The millisecond figure is a property of the run and nothing re-derives it, so it is the one number
in this file to distrust.** Three sites had three different values for it — 4,222 here and in the
impl log, 4,223 in the milestone file's two property lines, 4,224.7 in the arm report on disk — for
one sentence, which is `CAMPAIGN-BRIEF.md`'s "a figure nobody re-derives rots" caught before it
mattered. What is ASSERTED is the bound and the ratio: at least two seconds, more than four times the
median, with the median itself under three ticker intervals. Elsewhere the figure is now written
`≈4.2 s`, and this line is the only place a run's exact gap appears.

---

## 7. Termination and restart, and the case that does not round-trip

**Owned by `test_worker_restart_from_snapshot`.**

Four workers in one page:

1. **worker 1** — fee-juice funding, an L1-to-L2 message and three blocks, every one of them a
   facade call. Snapshot exported, then `terminate()` — not `close()`: the thread is killed under the
   runtime with no chance to flush anything, which is what a page does when a user hits reset. A call
   made afterwards is refused by name (`WorkerCallFailed`) rather than left pending for ever.
2. **worker 2** — a fresh node at genesis (block 0, asserted), the snapshot replayed. It reaches the
   **same archive root, the same four-tree state reference and the same block number**, and then
   produces one further block, because a replay that reached the right root and could not move would
   be a reconstruction rather than a resumption.
3. **worker 3** — the same, plus a token transfer. Snapshot exported, terminated.
4. **worker 4** — the snapshot from worker 3 replayed. The archive root and the state reference come
   out **DIFFERENT**, and that is correct.

**Why path B differs, stated rather than avoided.** A `ChainSnapshot` is M23's replay log: it records
what the runtime DID through its facade. `runTokenTransfer` registers a contract class and instance
in the module's contract DB and seeds a deployment nullifier, an initialisation nullifier and a token
balance **directly into the trees** — none of them a facade call, so none of them in the log. This is
`CHAIN-LOOP.md` §5's stated cost, measured on a real transaction for the first time.

Path B is also the **control**: without it, "the archive roots are equal" is a comparison that has
never been seen to come out unequal. With it, the same comparison over the same code answers both
ways in one run.

---

## 8. What is deliberately not here

- **No `SharedArrayBuffer` and no multi-threaded worker pool.** One worker, one runtime. The AVM
  module is single-threaded and `crossOriginIsolated` would put a COOP/COEP requirement on every page
  that embeds this.
- **No persistence.** Unchanged from M23 and M27: the replay-log snapshot is the agreed shape and a
  worker does not change it. `@aztec/kv-store`'s live browser store is `./sqlite-opfs`, which a
  worker can reach and which is DD-9-neutral; the door stays open and deliberately not walked
  through.
- **No `SharedWorker`.** A dev node shared between tabs is a different product decision — lifetime,
  ownership and whose snapshot wins — and nothing in M32 needs it.
- **The container is not streamed.** It crosses in one transfer, which is what makes the detachment
  measurable. A chunked transfer would be a different design and would need a different measurement.
