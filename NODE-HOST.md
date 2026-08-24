# The Node host — driving `avm.wasm` from TypeScript

`node-host/` is the package everything downstream imports: M18's orchestration, M23's facade, M24
and M25's tracing. It is the boundary between TypeScript and the WebAssembly AVM, and this page is
what it does and why, with every number re-derived by `just verify-m17` rather than quoted.

The module it drives is M12's. Its twelve imports, thirty-nine exports, size and msgpack ABI are
[`REACTOR-ABI.md`](REACTOR-ABI.md)'s and are not re-argued here; where this page needs one of them
it names the artefact it comes from.

Reproduce with `just verify-m17`.

## The reuse question, and the answer

M17's first deliverable says: *"bb.js already ships a shim for exactly this import set to run
`barretenberg.wasm`; check whether it can be reused before writing one."*

**It was checked, and the premise is false.** The answer is below with the enumeration behind it,
because this campaign has been wrong seven times about whether something needed building and every
one of those misses was a directory *parallel* to the one being searched.

### The enumeration

One question asked of the **whole fork** at the pinned anchor, not of `barretenberg/ts/bb.js/`:
*which files build a WebAssembly import object or instantiate a module?* Eight files, in eight
directories:

| directory | file | what it is |
|---|---|---|
| `barretenberg/cpp/scripts/` | `run_wasm_bench_node.mjs` | **upstream's own `node:wasi` host** for a `--import-memory` WASI module |
| `barretenberg/ts/bb.js/src/barretenberg_wasm/` | `index.ts` | the front door |
| `…/barretenberg_wasm_base/` | `index.ts` | **the shim the deliverable means** |
| `…/barretenberg_wasm_main/` | `index.ts` | main-thread instantiation |
| `…/barretenberg_wasm_thread/` | `index.ts` | worker-thread instantiation |
| `docs/examples/webapp-tutorial/` | `vite.extension.config.ts` | a bundler config |
| `docs/examples/webapp-tutorial/test-extension/src/offscreen/` | `offscreen.ts` | a docs example |
| `yarn-project/sqlite3mc-wasm/src/` | `index.ts` | Emscripten loader hooks for SQLite |

And the same question of the **published `@aztec/*` packages** as installed (23 of them): only two
mention any WASI name at all — `bb.js` (13 files, all builds of the one shim above) and
`sqlite3mc-wasm` (4 files, all vendored Emscripten glue).

### What each candidate actually covers

Measured name by name against the **eleven** WASI imports `REACTOR-ABI.md` records for this
artefact:

| candidate | covers | misses | supplies things `avm.wasm` does not import |
|---|---|---|---|
| bb.js `BarretenbergWasmBase.getImportObj` | **2 of 11** — `clock_time_get`, `proc_exit` | the other nine | `random_get`, `env.logstr`, `env.throw_or_abort_impl` |
| `@aztec/sqlite3mc-wasm` vendored glue | 8 of 11 | `fd_prestat_get`, `fd_prestat_dir_name`, `proc_exit` | Emscripten-internal; not an exported API |
| **`node:wasi`** | **11 of 11** | — | — |

bb.js's shim is not a near miss and its own comment says why: *"We literally only need to support
random_get, everything else is noop implementated in barretenberg.wasm."* `barretenberg.wasm` is
hand-stubbed — its own `wasi_stubs.cpp` routes `fd_write` through `env.logstr` — and `avm.wasm` is a
genuine wasi-sdk 33 **reactor** whose libc startup and stdio come from wasi-libc. The two import
sets differ because the two artefacts are built differently. `random_get`'s **absence** from
`avm.wasm` is something `REACTOR-ABI.md` asserts by name, so the one import bb.js exists to provide
is the one this module must not have.

### The decision

**Reused: `node:wasi`. Not reused: bb.js's shim.**

And the reuse is not a fallback — it is what **upstream itself does**, in
`barretenberg/cpp/scripts/run_wasm_bench_node.mjs`, a directory parallel to `barretenberg/ts/`:
`new WASI({ version: 'preview1' })` plus `imports.env.memory = memory`, for a `--import-memory`
barretenberg module under Node. That file is the precedent and it is Aztec's, not ours.

**What is ours is one import**: `env.memory`, a `WebAssembly.Memory` sized from the module's own
declared minimum, read out of the binary's import section because
`WebAssembly.Module.imports()` does not report limits. Everything else in the twelve comes from
Node.

The package has **no dependencies at all** — not bb.js, not `@types/node`. `tsc` comes from
`pkgs.typescript` in this repo's dev shell and the three Node APIs used are declared in
`node-host/types/node-subset.d.ts`, so a clean checkout type-checks and runs it with no
`npm install` and no network.

## The toolchain gate, and the deliverable's premise that did not survive

The deliverable asks for *"the V8 `try_table` requirement asserted at load, so a toolchain flag
regression fails loudly on the pinned Node version"*, and the verification entry adds *"and rejects
a legacy-encoded build so the guard is known to work"*.

**Measured: the pinned Node's V8 accepts BOTH encodings.** Node 24.19.0 carries
V8 13.6.233.17-node.51, whose `--experimental-wasm-legacy-eh` defaults to **on**; a hand-encoded
legacy module validates *and runs*. So "avm.wasm loaded, therefore it uses `try_table`" is not an
argument on this engine, and a check that only loaded the module could not have failed.

Two regressions are therefore guarded, and they are not the same one:

| regression | what it looks like | how it is caught | its control |
|---|---|---|---|
| exceptions compiled out (`BB_NO_EXCEPTIONS`, `#define try if(true)`) — every C++ throw becomes `std::abort()`, so every AVM **revert becomes a trap** | the module has **no tag section** | the loader's `assertExceptionSupport` refuses it before compiling | a hand-built module with no tag section, which the *engine* accepts and the *gate* refuses |
| the legacy exception encoding | works today, stops working on an engine that has dropped it | the check runs the engine probe **twice**, once with `--no-experimental-wasm-legacy-eh` | the legacy probe is refused there by name — `Invalid opcode 0x06` — while `avm.wasm` still compiles |

`avm.wasm` as built carries a tag section of **3 bytes**, holding one tag: the C++ exception tag.
Its section list is `1, 2, 3, 4, 13, 6, 7, 8, 9, 10, 11, 0, 0`.

## The twelve imports, satisfied

Read from the module by the loader and compared against `REACTOR-ABI.md`'s own table, on both
sides, so a drift fails rather than passing:

- **eleven** `wasi_snapshot_preview1` functions, all from `node:wasi`;
- **one** `env.memory`, ours, at the module's declared minimum of **130 pages**.

An import the module grew is reported as itself (`AvmUnknownImport`, naming it) rather than as a
generic `LinkError`, and a memory below the declared minimum is refused by the loader with a
message about the minimum rather than by an instantiation failure that reads like a toolchain
problem.

## Trap versus revert

**A revert is a transaction outcome. A trap is a runtime bug.** They are not two flavours of
failure and this package does not let them become one.

| what happened | how it surfaces | type |
|---|---|---|
| the transaction reverted | **returned** | `TxOutcome` with `revertCode !== 0` and `reverted === true` |
| the transaction succeeded | **returned** | `TxOutcome` with `revertCode === 0` |
| the module returned a non-zero status | **thrown** | `AvmHostError`, carrying the status and the module's own `AvmReactorError.message` |
| the module trapped | **thrown** | `AvmTrap`, and the instance is **poisoned** |
| a call on an already-trapped instance | **thrown** | `AvmInstancePoisoned` |

`TxOutcome` carries `kind: 'tx-outcome'`; the failures carry `'trap'`, `'host-error'` and
`'poisoned'`. The discriminants are disjoint string literals, so **the compiler refuses the
confusion**, which is what "the type system enforces it" means here rather than a convention:

| the mistake | the compiler's answer |
|---|---|
| a trap returned where a `TxOutcome` is expected | `TS2739` |
| `.revertCode` read off an `AvmTrap` | `TS2339` |
| a `TxOutcome` passed where a failure is expected | `TS2345` |
| a `switch` over the failure kinds that forgets one | `TS2345` (via `unreachableKind(x: never)`) |

Each of those is a file under `node-host/typecheck/negative/` that must **fail** to compile, beside
a positive control under `typecheck/positive/` that must compile with the same compiler and the same
flags — without which "the negative cases fail to compile" would be a claim about the compiler
invocation rather than about the types.

At run time the distinction is measured on the real module, five arms through one boundary function:

| arm | result |
|---|---|
| the `revert` corpus program | `tx-outcome`, revert code non-zero, instance untouched |
| the `add` corpus program (the control) | `tx-outcome`, revert code zero |
| a DB handle that was never created | `host-error`, status **3** |
| bytes that are not msgpack | `host-error`, status **1**, with the module's message |
| a pointer past the end of linear memory | **`trap`** in `avm_simulate`, instance poisoned |

The trap is a genuine one on the real module: the host hands `avm_simulate` a pointer outside linear
memory, the module's own reader loads out of bounds, and a wasm out-of-bounds access is a trap and
therefore something the C++ `guarded()` **cannot** catch, because it is not an exception. It is also
exactly the shape of the host bug the deliverable is about. The two host-error arms are what make it
a discrimination rather than an observation, and they do it in two different ways: the
**malformed-input** arm is the same export, the same code path and the same classifier with **only
the pointer valid instead of out of bounds**, so the difference in verdict is the difference in the
pointer and nothing else; the **bad-handle** arm reaches the classifier through a different export
and comes back with a different status, so "host error" is not one word for one situation either.
Four arms, four distinct tokens, asserted as four rather than one at a time.

**And "the trap carries no revert code" is read off the caught object**, not asserted from the type
declaration. A mutation round showed why: a `poison()` that attaches `revertCode` to the trap at run
time — `(trap as unknown as Record<string, unknown>).revertCode = 0` — type-checks, is invisible to
a grep of `errors.ts`, and leaves every caught trap answering `0` to `.revertCode`, which a consumer
reads as *reverted with code zero*, i.e. **succeeded**. The same `in` test over the revert outcome,
where there *is* one, is the control.

**A trapped instance is never reused.** Its linear memory is undefined, so everything it would say
afterwards is meaningless; `InstancePool` retires it and builds a fresh one, measured as
`retired 1, created 2`. A pool that recycled a trapped instance would turn one runtime bug into an
unbounded number of wrong answers.

## Ownership, and why it does not leak on an error path

Two directions with different rules, both of them `REACTOR-ABI.md`'s:

- **host → module.** An input blob is `avm_alloc`ed, written, passed and freed, with the free in a
  `finally` so a status of 1, a decoder exception and a trap all reach it. Every pointer is recorded
  when allocated and removed when freed, so a leak is a **number** — `ownedAllocationsAtExit`,
  asserted zero at the end of every transcript run — rather than an impression.
- **module → host.** Results are not allocated per call: one module-owned buffer, reused, which the
  host copies out of before the next call. There is nothing for the host to own, which is why this
  direction cannot leak at all.

One case is deliberately *not* tidied up: after a trap the `finally` does **not** call `avm_free`,
because the allocator lives in the memory that is now undefined. Those allocations are counted as
`leakedAtTrap` and the instance is discarded whole, which reclaims them in one step.

## The step stream

Two ways to get it, both upstream's:

- `TxSimulationResult.execution_steps` already carries the whole stream — all 38,903 of `burn`'s
  records after **one** crossing and zero further ones;
- `avm_steps_batch(from, count)` for a host that would rather stream records into a trace writer as
  it goes (M24, M25), costing exactly `ceil(count / B)` crossings at batch size *B*.

Measured through this package at B = 4,096: **38,903 records, 10 crossings**, and **zero**
differences between the batched stream and the one that arrived inside the result — compared per
record, on every field, rather than by count.

Both crossing counts are readings of `Reactor.moduleCalls`, a counter incremented at the one
boundary, taken as a *difference* either side of the route being measured. That matters rather than
being tidiness: the zero used to be a constant the probe printed, which made the assertion beside it
one that nothing could falsify. The batched drain's own count is asserted against the same counter
as its control, so a counter stuck at any value fails rather than passing as a zero.

The window is clamped **by the module**, by subtraction, and this host passes the caller's numbers
through unchanged so that property keeps being exercised from here. `size_t` is 32 bits on `wasm32`
and `count` is a `uint32` the host chooses, so `from + count` wraps for a count near `2^32 - from`;
a wrapped end below the beginning would construct a vector from a reversed range, which is undefined
behaviour reachable straight from the boundary and which `guarded()` cannot catch because it is not
an exception.

## Compilation cached, instances pooled

`WebAssembly.compile` on a 1.5 MB module is the expensive half; instantiation is cheap. `ModuleCache`
keeps the compiled `WebAssembly.Module` keyed on its path, and concurrent callers share the one
in-flight compilation.

Measured over four rounds of the seven-program corpus, run both ways: **1 compilation** and 28 cache
hits; the pooled arm acquired **32 times and constructed one instance**, reusing it 31 times and
retiring none; **zero** mismatches between the 28 pooled results and the 28 fresh-instance results;
and **zero** page growth across rounds.

The pooled arm acquires **once per simulation** rather than once around the whole loop, and that is
the difference between a measurement and a tautology: a mutation round changed the pool to retire
its instance on every acquisition and the check still read "one instance created", because the pool
had only been asked once. Restructured, the same mutation reads **32**.

`acquire` is deliberately not re-entrant, and refuses rather than relying on a convention: the
reactor has ONE module-owned result buffer, so two callers through one instance would read each
other's results. The DB handles are **not** pooled — `avm_contract_db_create` and
`avm_merkle_db_create` are the module's own lifecycle and a transaction wants its own; recycling
them would be recycling transaction state.

## Peak linear memory

**199 pages / 12,736 KiB**, driving all seven corpus programs through one pooled instance. Budget
260 pages, chosen with headroom — a budget equal to the measurement fails on any change and
therefore gets raised rather than read — and below twice the measurement, so it can still fail.

Three figures exist and none of them is another:

| figure | what it is |
|---|---|
| **199 pages / 12,736 KiB** | this host, seven programs and their resident DBs through one instance |
| 173 pages / 11,072 KiB | M8's differential driver, reported from **inside** the module |
| 217 pages / 13.6 MiB | the vm2-wasm spike's driver, which ran every program **twice**; the milestone's entry still quotes it |

The per-program readings are monotonic — linear memory never shrinks — so the last is the peak and
"the heaviest corpus program" is a measurement. The spread across the seven is **32 pages** here
against M8's **one**, and the difference is a fact about the two drivers: this host seeds a fresh
pair of resident DBs per program where M8's driver reuses the tester's.

## The transcript

All seven corpus programs, driven through this package's own public entry points, produce **147**
`program.*` result lines — of which **56 are tree roots and sizes** — with **zero** mismatches
against the native x86-64 reference.

The comparison is directional and its exceptions are enumerated rather than filtered: the driver
emits `.beforeDeploy`, `.afterDeploy` and `.afterSimulate`, which are the *tester's* own DB and have
no counterpart on the reactor's ABI, and a `.bytes` line per program, which is a bytecode length
rather than a result field. And the comparator is shown to find a difference: one value is altered
in a copy and it must report exactly that key.

## Every mode ends with a sentinel, and the process drains before it exits

Every CLI mode prints `<mode>.done 1` and nothing after it, so a transcript missing it was
**truncated** rather than short, and the checks assert that token rather than a field of the result.

That is M9's lesson taken as a rule rather than as a fix. M9's review found a V8 run that exited 0
having written a prefix of its transcript; the assertions that noticed were "the fallback run
completed, expected [1], got []" and "oob emitted no events" — the second of which reads like a
finding about the AVM and is a sentence somebody could spend an afternoon investigating. It was an
I/O truncation.

The other half is that `process.exit()` **discards output that is still queued**. When fd 1 is a
file Node writes synchronously and the hazard is invisible; when it is a pipe it is not. Every exit
in this package and in `verification/wasm_host/run_wasm_test_binary.mjs` now drains stdout and
stderr first.

## CI

`.github/workflows/avm-wasm.yml` carries an eighth job, `node-host`, running `just verify-m17` in
its own work directory so it and M12's job cannot rebuild the same tree under each other. It
installs the published `@aztec/*` packages first, because the reuse enumeration reads them, and
asserts M17's own inputs — the package, its four type-level negatives, the write-up — before running
anything.

**It has never run.** Neither has any other job in that workflow: they all abort at
`Generate CI token` on "Input required and not supplied: app-id", which M11 recorded as undiagnosed.
So "the checks are wired into CI" means the job exists, is wired and names them — not that a run has
ever gated anything. The check asserts the former and this paragraph states the latter.

## What this milestone does not measure

- **The browser.** M28. Nothing here uses `node:fs` outside the loader's single `readFile`, and the
  WASI half would have to be replaced there — bb.js's shim is not the replacement either, for the
  reasons above, and the browser's answer is a question for that milestone rather than an assumption
  here.
- **Encoding.** This package decodes and never encodes. Every blob crossing into the module is
  produced by upstream's own msgpack packers in C++; a JavaScript encoder of ours would be a second
  implementation of upstream's schemas, and two implementations of an encoding are two things that
  can disagree. The same argument runs inside this repository: `node-host/src/msgpack.ts` is the
  **one** decoder, and `verification/wasm_host/reactor_lib.mjs` — which M13 had already extracted so
  that M12's and M13's hosts could not disagree — **re-exports** it rather than keeping a third copy.
  Node runs the `.ts` source directly, so there is no build step between the two.
- **Concurrency.** One instance, one caller. The AVM is single-threaded, the module imports a
  non-shared memory, and `avm_result_ptr()` names one buffer.
- **Anything about the module itself.** Its imports, exports, size and ABI are M12's, and
  `REACTOR-ABI.md` is where they are argued.
