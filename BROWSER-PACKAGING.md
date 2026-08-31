# Browser packaging — what a page downloads, and what it does not

M27's write-up.

**Every figure in §1 and §6 is re-derived from the artefact and compared AGAINST THIS FILE on every
run** — `verify_browser_chunk_budget` §6, which opens this document the way
`verify_avm_wasm_size_budget` opens `REACTOR-ABI.md`. Figures elsewhere are named with the check
that measures the *property*, which is not the same thing and is marked where it matters.

That distinction is here because the sentence this replaced — *"Everything here is re-derived by a
check on every run"* — was **false**, and M27's review measured how false. No check opened this file
at all: `lib_m27_browser.sh` defined and exported `M27_DOC` and nothing read it, uniquely among this
repository's milestone write-ups (`REACTOR-ABI.md` is read by three checks, `BOUNDARY-SHAPE.md` by
six, `CHAIN-LOOP.md` by seven). Eleven figures had already rotted, including the total in §1, four
counts in §2, the entry-point attribution in §6 and every cell of §8's table.

---

## 1. The measurement this milestone is about

The design document's §8.5 measured the whole execution surface bundling for the browser at
**10.56 MB minified / 6.84 MB gzipped, eagerly loaded**, and drew the right conclusion: the AVM
itself is a rounding error and the size is two dependencies. DD-11 then made code splitting a v1
requirement rather than an optimisation, with one concrete demand — *"a page which only executes a
public transaction never fetches the barretenberg wasm at all"*.

Measured here, on 2026-08-28, by `browser/build.mjs`, which fails the build on a regression.
**M29 moved every figure in this section**, by a few kilobytes each: the reference entry now reaches
`browser/src/executed_steps.ts` (the drain over M12's `avm_steps_batch`) and the demo additionally
reaches `browser/src/native_parity.ts` (the differential arm). Nothing lazy moved and no chunk
changed class, which is what the per-entry budgets exist to make visible.

**AND M32 MOVED THEM AGAIN, BY LESS, FOR A REASON THAT IS NOT ABOUT THIS PAGE.** It adds two entry
points to the SAME esbuild pass — `worker.js` and `worker-demo.js` — and esbuild's splitting is a
function of which entries reach which module, so the chunk boundaries moved: three of the existing
entries gained files (7 -> 8, 8 -> 10, 8 -> 10) and a tenth to a fifth of a kilobyte each,
`node/node.js` is unmoved because the Node pass is a separate one, and the total gained 8.19 KB. No
chunk changed CLASS and nothing lazy became eager, which is the property these budgets exist for and
which the per-entry rows below are what make visible. `WORKER-NODE.md` §5 carries the before/after
pair; the second column here is the after:

**AND M33 MOVED THEM A THIRD TIME, FOR THE SAME MECHANISM AND WITH THE ATTRIBUTION MEASURED RATHER
THAN ASSERTED.** It adds a seventh entry point to the same pass — `wallet.js`, the wallet protocol
boundary — and the chunk boundaries moved again. Two facts about that, and the second is the one
worth the paragraph:

* **The npm install moved nothing.** M33 adds `@aztec/aztec.js` (and, transitively,
  `@aztec/entrypoints` and `@aztec/standard-contracts`) to `orchestration/package.json`. Built with
  those three installed and the wallet ENTRY removed, every cell of the table below reads
  **255.87 / 279.93 / 281.13 / 225.36** — its pre-M33 value to the assertion. So the whole of the
  movement is the seventh entry point's re-splitting and none of it is the dependency.
* **Not one byte of the wallet protocol is in the reference entry's eager set.** The +7.88 KB on
  `browser.js` is, per package, out of the esbuild metafile: `@aztec/stdlib` +24,869 raw bytes,
  `@aztec/foundation` +5,700, `@aztec/blob-lib` +930 — upstream code the reference already reached,
  hoisted into a chunk it now shares with the wallet entry — and **`@aztec/aztec.js`,
  `@aztec/entrypoints` and `@aztec/standard-contracts` contribute exactly 0**.
  `verify_provider_half_dd9_clean` asserts that zero on every run, with the wallet entry's own
  13,371 bytes of `@aztec/aztec.js` as the control that the measurement can be non-zero.

| entry point | eager, gzipped | files | M27's figure |
|---|---|---|---|
| `aztec-avm-runtime/browser` — the DD-5 reference | **265.79 KB** | 9 | 253.94 KB |
| `aztec-avm-runtime/testing` | 291.08 KB | 12 | 291.09 KB |
| the demo page | 292.3 KB | 12 | 292.3 KB |
| `aztec-avm-runtime/node` | 225.48 KB | 4 | 223.61 KB |

and, lazily, never in any eager set:

| chunk | gzipped | fetched by the demo? |
|---|---|---|
| `chunks/barretenberg-threads-*.js` | 3,018.02 KB | **no** |
| `chunks/barretenberg-*.js` | 2,997.30 KB | **no** |
| `chunks/ContractClassRegistry-*.js` | 495.93 KB | no |
| `chunks/FeeJuice-*.js` | 185.88 KB | yes, when a fee payer is funded |
| `chunks/ContractInstanceRegistry-*.js` | 103.25 KB | no |

**8,230.68 KB gzipped across every chunk; 265.79 KB is what the reference entry point costs.** That is
the whole of DD-11 in two numbers, and the difference between them is exactly the two things DD-11
names.

*(Both numbers moved in M35, which adds private execution to the WALLET entry — fifty vendored files
between upstream's `WASMSimulator` and the oracle wire layer. The reference entry moved 263.1 ->
265.79 KB and it does not reach any of them: an entry point that gains exports changes how
`splitting: true` partitions the common modules, so every entry that shares one moves with it. And
the 4.4 MB of ACVM wasm the private path needs is in NEITHER number, because it is fetched by URL at
the moment a page asks for a private execution — measured on a network log by
`e2e_private_function_executes_in_browser` §5, with a control page that asks for none and fetches
neither.)*

`verify_browser_chunk_budget` re-derives every cell of both tables above OUT OF `chunks.json` and
compares it to this file, row by row, and proves the enforcement can fail — in three directions, of
which the third is the one this paragraph is about. (Making one contract artifact eager took the
reference entry from **253.94 KB to 750.09 KB** and the build refused; that pair is M27's review's,
taken at M27's baseline and left at it rather than restated at every later baseline, because nothing
re-derives it — it is the demonstration that the per-entry rule can refuse, and it took M27's review
to find that nothing exercised that rule at all. The rule itself is exercised on every run by §4b,
which sets `browser.js`'s eager budget to 1 KB and requires the build to fail on the eager line.) The
per-entry EAGER totals are budgeted separately from the per-file sizes, because a per-file budget
cannot see the regression that matters — a lazily-loaded megabyte moving into the eager set changes
which chunks a page fetches and not how big any of them is.

---

## 2. What was reused from upstream, and where this diverges

The milestone's first deliverable: *"upstream's own browser configuration reused as the starting
point ... start from what they do and record any divergence"*. Upstream's is
`aztec-packages/playground/vite.config.ts`.

**Reused.**

- **The chunk-size validator**, shape and discipline both: a `{ pattern, maxSizeKB, description }`
  list, a walk of the output directory after the write, violations collected and **thrown** so the
  build fails rather than warns, and a per-bump log recording what grew and why. Ours keeps the log
  as data (`browser/chunk-budgets.json`'s `bumps`) so a check can read it.
- **Lazy-loading the two heavy things.** At our pin the mechanism is already inside bb.js:
  `barretenberg_wasm/fetch_code/browser/index.js` does `await import('./barretenberg.js')`.
- **`@aztec/protocol-contracts`'s own `<name>/lazy.js`**, which is what the deployed Playground
  reaches through `./providers/lazy`. Two of the three artifact barrels are redirected straight at
  upstream's lazy module; they `export *` the same event modules their eager siblings do, which is
  what makes the redirect safe rather than merely convenient.

**Divergences, each with its reason.**

1. **esbuild, not vite.** Vite is not in this repository's toolchain and would add ~400 packages
   for a build with no dev server, no HMR and no JSX. esbuild is already installed twice here
   (`spike/node_modules`, `diffsim/node_modules`) and the design document's own §8.5 measurement was
   taken with it, so this build is comparable to the campaign's own baseline rather than to a new
   one. Vite's production build is rollup, which splits the same way; what differs is the plugin
   API, not the artefact.
2. **The polyfill set is different, and upstream's would not have been enough.** The Playground
   polyfills `['buffer', 'path', 'process', 'net', 'tty']`. Measured on THIS dependency graph,
   `esbuild --platform=browser` fails on `util` (**43** files), `assert` (**8**), `tty` (1) and `module`
   (1) — re-derived from `meta.json`'s input graph by M27's review, which found 37 and 5. Only
   `tty` overlaps. `path` and `net` never appear, because we do not import `@aztec/pxe`.
3. **The shims are this repository's own**, from `browser-probe/shims/` — written for the spike's
   browser probe, tracked, and **eleven** lines between them (4 + 5 + 2; it said twelve
   until M27's review counted them) — plus one new one for `module`.
4. **TWO `@aztec/foundation` modules are substituted** — poseidon2 *and* grumpkin, which is §3's
   whole point — one `@aztec/protocol-contracts` barrel is replaced by a six-line shim over
   upstream's lazy loader, and two more are redirected straight at upstream's lazy siblings. Five
   redirects; `verify_browser_bundle_builds` asserts that all five fired in both passes. (This said
   "One … and two more" until M27's review read `substitution.json`: the sentence predates grumpkin
   and was never revisited when §3.2 was written directly below it.) That is §3, and it is DD-11
   rather than packaging.

---

## 3. The two routes from a public-only page to the proving wasm

DD-11 was **unsatisfiable** before this milestone, not merely unmet, and finding out why took two
measurements with two different instruments.

### 3.1 Poseidon2 — found by instrumenting the call

`Barretenberg.initSingleton`, wrapped around one Form A run — the public-only path, nothing private,
no proving — is called **82 times**, from four sites, all four inside
`@aztec/foundation/dest/crypto/poseidon/index.js`:

```
26  feeJuiceBalanceLeafSlot -> @aztec/protocol-contracts/fee-juice -> hash/map_slot.js
26  feeJuiceBalanceLeafSlot -> @aztec/stdlib/hash/hash.js:151
16  HashedValues.fromValues  -> @aztec/stdlib/hash/hash.js:172
14  Tx.getTxHash             -> private_to_public_kernel_circuit_public_inputs.js:67
```

In a browser those are `BarretenbergSync.initSingleton()`, whose `fetchCode` fetches 7.9 MB of
proving stack. **To compute a hash.**

### 3.2 Grumpkin — found by reading the browser's own request log

With poseidon2 exported and substituted, the public-only page **still fetched
`chunks/barretenberg-*.js`**. The remaining caller is address derivation:

```
computeAddress(publicKeys, partialAddress)                keys/derivation.js:59
  = Grumpkin.add(Grumpkin.mul(G, preaddress), publicKeys.ivpkM)
```

A contract's address is a commitment to its class, its salt and its public keys, so **every page
that registers a contract computes one** — which is every page that executes a transaction against a
contract.

The first enumeration was *correct and insufficient*. `CAMPAIGN-BRIEF.md`'s rule — "an absence claim
is only as wide as the spellings you enumerated" — one level up: what closed it was not a better
enumeration but a different instrument. That is why
`verify_public_only_page_never_fetches_barretenberg` is asserted on `Network.requestWillBeSent` and
not on the bundler's configuration, and why the milestone says so in as many words.

### 3.3 The answer: `avm.wasm` is a barretenberg build

`vm2_sim` links `crypto_poseidon2`, which declares `ecc`. Both the hash and the curve are already in
the module the page has downloaded. M27's thirteenth overlay
(`verification/m27/0001-test-vm2-export-poseidon2-and-grumpkin-from-the-reac.patch`) exports four
names, whose C++ is upstream's own:

| export | upstream |
|---|---|
| `avm_poseidon2_hash` | `bb::crypto::Poseidon2<Poseidon2Bn254ScalarFieldParams>::hash` |
| `avm_poseidon2_permutation` | `Poseidon2Permutation<...>::permutation` |
| `avm_grumpkin_mul` | `bbapi_ecc.cpp`'s `GrumpkinMul::execute`, on-curve check included |
| `avm_grumpkin_add` | `bbapi_ecc.cpp`'s `GrumpkinAdd::execute` |

**The module: 55 exports, 1,621,354 bytes**, against M23's twelve-overlay 51 / 1,595,118. A
different artefact, measured separately, exactly as M13 and M23 each did for their own overlay; no
earlier milestone's module is repointed and no earlier milestone's pinned export count moves.

**The agreement with bb.js is measured** — `test_browser_crypto_matches_bb_js`, in one process:
nine poseidon inputs (including the empty one), the permutation, the domain-separated hash, five
grumpkin scalars and an addition; a perturbed-input control for each primitive; and an off-curve
point refused by the module by name.

---

## 4. A twelfth WASI import, and a comment that was wrong before it was measured

`REACTOR-ABI.md` records **eleven** `wasi_snapshot_preview1` imports for `avm.wasm` and asserts the
ABSENCE of `random_get` by name. That is true of M12's, M13's and M23's modules and **false of
M27's**: exporting grumpkin makes `bb::numeric::RandomEngine` reachable, through a **vtable**, so
`--gc-sections` cannot prove it dead. Traced through the unstripped module's disassembly rather than
guessed:

```
wasi_snapshot_preview1.random_get  <-  __wasi_random_get  <-  __getentropy
                                   <-  RandomEngine::get_random_uint{64,128,256}()
```

The first draft of `browser/src/wasi.ts` said the import would never be *called*. The counter said
**1**. Read at four points in one process:

```
after instantiate      random_get 0
after poseidon2 hash   random_get 0
after grumpkin MUL     random_get 1     <- here, and only here
after grumpkin ADD     random_get 1
```

`mul_const_time` blinds, and the engine seeds itself once, lazily. The blinding is internal and does
not move the result. **The point is not the number; it is that the number was measured** — a
plausible false sentence did not ship only because the shim counts its own calls. DD-3 is why
`randomBytes` is an injectable option rather than an unconditional `crypto.getRandomValues`.

---

## 5. DD-5 — three entry points, and a mechanical rule

M23 shipped one entry point and marked this deliverable **unmet** rather than "met in spirit". It is
M27's.

| entry | what it is |
|---|---|
| `aztec-avm-runtime/browser` | the REFERENCE. No filesystem, no persistence, no prover, no `AztecNode` type. |
| `aztec-avm-runtime/testing` | the browser entry plus deterministic clocks and M26's vendored transaction builder. Everything it adds runs in a page. |
| `aztec-avm-runtime/node` | the SUPERSET, by five declared conveniences and nothing else. |

"Convenience" and "capability" are easy words to argue about, so the rule is mechanical:
`NODE_CONVENIENCES` is a **value** in `entry_node.ts`, exported and therefore readable out of the
built bundle, and `verify_browser_entry_points_are_dd5_shaped` requires

```
(node exports) − (browser exports)  ==  NODE_CONVENIENCES,   as a SET, both directions
```

so an undeclared addition fails and a declaration for something absent fails too. A comment could
not be compared with a bundle.

**And the check reads the artefacts by IMPORTING them**, which is not decoration: three separate
defects in the Node bundle — a `require` shim that threw, a missing `__dirname`, our browser `util`
and `process` shims applied to a pass where the real ones exist — were each found by the Node entry
failing to load, one at a time. A check that read the sources would have reported a healthy
superset over a bundle nobody could import.

---

## 6. What a page actually fetches

`verify_public_only_page_never_fetches_barretenberg`, on the browser's own log. Seventeen requests,
and the enumeration below totals 17 requests, which it did not before M27's review:

```
1   /index.html                       the demo page
12  /demo.js + 11 shared chunks       289.5 KB gzipped — the DEMO entry's eager set, which is
                                      the browser entry's 263.1 KB plus the page itself
1   /favicon.ico                      the browser's, not ours
1   /assets/avm.wasm                  1,621,354 bytes — the AVM and its world state
1   /assets/token_contract-Token.json the contract artifact, fetched when a contract is needed
1   /chunks/FeeJuice-*.js             185.88 KB — a protocol-contract artifact, on demand
```

(It said "`/demo.js` + 6 shared chunks / 253.94 KB" and enumerated to twelve under a heading that
says thirteen. Both are M27's review's corrections: the chunk count was seven, and 253.94 KB was a
different entry point's number — `browser.js`, which this page never requests. **M32 took the chunk
count from seven to nine and the request total from thirteen to fifteen**, by adding two entry
points to the same esbuild pass and moving the chunk boundaries; the two new ones are 0.06 KB
each, so the page pays 0.15 KB more and makes two more round trips. **M33 took them to eleven and
seventeen**, by adding the seventh entry point (`wallet.js`) to the same pass — the demo page does
not import the wallet boundary and does not fetch `wallet.js`, so what it pays is two more round
trips for chunks the splitter re-partitioned, not any wallet code. All three figures are re-derived
from the arm run by `_m27_doc_figures.py` on every run, which is how each change was found rather
than argued about.)

and **`barretenbergRequests: []`**.

The absence has a control in the same browser, through the same observer: the `provingControl` arm
is a second page whose only difference is that it calls `BarretenbergSync.initSingleton()` on
purpose, and its list is non-empty. Without that, an empty list is equally consistent with a page
that fetched nothing, an observer attached after navigation and a needle that never matched.

---

## 7. The product claim

> `e2e_browser_downloads_ct_container_and_ct_print_parses` — the container downloaded from the demo
> page parses under `ct-print --full`.

Measured:

```
downloaded by the browser   aztec-avm-01949fcc-7d92-7e9c-8000-000000002701.ct
                            196,608 bytes — equal to the bytes the page held
the recording               516 events, 2 frames, 14 interned paths,
                            389 steps POSITIONED and 127 unpositioned,
                            artifact rung 1, DECLARED rung 2
ct-print --full             exit 0, 26,011 lines, 516 Step records
the paths it names          /aztec/tx.avm
                            …/aztec-nr/aztec/src/macros/dispatch.nr
                            …/aztec-nr/aztec/src/oracle/avm.nr
                            …/noir-protocol-circuits/crates/serde/src/reader.nr
                            …/noir-protocol-circuits/crates/serde/src/type_impls.nr
```

M27 added no format and no writer. `ct_writer.wasm` declares zero wasm imports (M24), `ct-host` has
no dependencies and no Node builtin (DD-7's reason for a raw C ABI, recorded in
`ct-host/package.json` as "what M27 needs"), and `ContractSourceMap` (M25) is what makes the steps
rung-1. What M27 added is a `Blob`, an object URL, and `DecompressionStream('deflate-raw')` where
Node used `inflateRawSync`.

**THE READER'S VERDICT HAS A CONTROL, AND THE OBVIOUS ONE DOES NOT WORK.** Halving the container
does **not** make `ct-print` refuse it — a `.ct` is a directory of independent streams and the ones
that survive a truncation are still well formed. That exit status is recorded rather than hidden.
The controls that do discriminate corrupt something every reader must parse: a 512-byte stub, and a
`recording_id` shortened to 35 characters. Both are refused, the second naming `meta.dat`.

**M29 REPLACED THE NUMBERS ABOVE, AND THE PARAGRAPH THAT USED TO BE HERE.** It read: *"the step
count is not an instruction count — the program counters are the artifact's own first N mapped pcs,
and `test_trace_step_count_matches_instruction_count` is still `pending`."* It is not pending any
more. The container's 516 steps are the 516 instructions the AVM executed, drained through M12's
`avm_steps_batch` and ingested through M24's `ct_ingest`, and the count equals
`stats["total_instructions_executed"]` for the same transaction. The synthesised path is deleted
rather than kept as a fallback.

**Three of the numbers moved for a reason that is not the step stream, and it is the more
interesting half.** M27's demo transaction *reverted at its first instruction*: the contract was
registered in the module's contract DB but never given a deployment nullifier, so the AVM answered
its address with no bytecode and executed one record — pc 0, opcode 68, M9's `LAST_OPCODE_SENTINEL`.
Nothing could see it, because the block still reported the transaction `processed` (a revert is a
legitimate outcome inside a block) and the steps came from the artifact rather than from the run.
Three seeding gaps were found this way and are now closed in `browser/src/token_transfer.ts`: the
deployment nullifier, the public initialization nullifier, and a token balance for the sender; plus
`isStaticCall` on the `#[view]` second call. `revertCode` is 0.

**The declared rung is now MEASURED over the executed stream, and it is 2.** 389 of the 516 executed
steps resolve to a `(path, line, column)`; the other 127 are in regions the artifact's
`brillig_locations` does not key — `SOURCE-MAPPING.md` §2.4's residual hole 2, compiled procedures
appended after the main body. While the steps *were* the mapped pcs, every one of them had a
position by construction and "rung 1, 64 of 64 positioned" was true and said nothing. M25's rule is
that a rung is never rounded up, and this is the first place it has had to bite: the artifact is
still rung 1, the recording declares rung 2, and the reason carries the split.

---

## 8. Blocks on a real timer, in a tab that stops

`smoke_browser_produces_block_on_real_timer` asserts the milestone's clause *"including while the
tab is throttled"*, and the clause is the check. The monotonicity rule is

```
timestamp = max(prevTimestamp + minBlockSpacingSeconds, floor(clock.nowMs() / 1000))
```

and asserting it against a steady 250 ms chain asserts almost nothing: the first branch holds
throughout and a runtime that ignored the wall clock entirely would pass. So the arm **freezes the
page** — `Page.setWebLifecycleState('frozen')`, which is what Chromium does to a backgrounded tab it
stops paying for — with `Emulation.setCPUThrottlingRate: 20` alongside, because a frozen tab and a
merely slow tab are different failures.

Nine blocks. **THIS TABLE IS ONE RUN AND CANNOT BE PINNED, which is why it is labelled rather than
asserted.** Every cell is a function of when the arm ran and how the scheduler behaved: the
timestamps are epoch seconds, the wall clocks are the host's, and the deviations depend on where the
freeze landed between two ticks. It was recorded on 2026-08-27, and a re-run produces different
numbers — M27's review re-ran it and got `1787837264..1787837272` with a three-second gap where this
run had four. What `smoke_browser_produces_block_on_real_timer` asserts on EVERY run is the
invariants underneath it: strictly increasing, exactly one second per block, real epoch seconds
rather than a counter, a wall-clock gap of at least two seconds somewhere, the declared deviation
equal to `timestamp - wallClockSeconds` per block, and at least three of those deviations non-zero.

One recorded run:

| # | timestamp | wall clock | declared deviation |
|---|---|---|---|
| 1 | 1787825502 | 1787825502 | 0 |
| 2 | 1787825503 | 1787825502 | 1 |
| 3 | 1787825504 | 1787825503 | 1 |
| 4 | 1787825505 | 1787825503 | 2 |
| 5 | 1787825506 | 1787825503 | 3 |
| 6 | 1787825507 | 1787825503 | 4 |
| 7 | 1787825508 | **1787825507** | 1 |
| 8 | 1787825509 | 1787825507 | 2 |
| 9 | 1787825510 | 1787825508 | 2 |

Strictly increasing throughout, one second per block. **The freeze is visible in the data**: between
blocks 6 and 7 the host clock jumps (four seconds in this run, three in the review's) and the
declared deviation collapses to 1 — the rule's second branch taking over from the first, which is
the whole point of DD-4's injected clock. The check requires that jump to be at least two seconds,
because a run in which the freeze did not take effect produces a perfectly even chain over which
every monotonicity assertion would pass. **The jump's SIZE is a property of the run rather than of
the runtime, and is not asserted.**

---

## 9. What is deliberately not here

- **No persistence.** M23 settled it: the replay-log `exportSnapshot`/`importSnapshot` is the agreed
  shape and Anvil, Hardhat and Ganache all default to ephemeral. `@aztec/kv-store`'s live browser
  store is `./sqlite-opfs` and is DD-9-neutral — it pulls `@aztec/sqlite3mc-wasm`, which ships
  `vendor/jswasm/sqlite3.wasm` and no `.node` — so the door is open and deliberately not walked
  through. See `CHAIN-LOOP.md` §6.
- **No web worker — UNTIL M32, WHICH IS THE FOLLOW-UP THIS BULLET NAMED.** The design document says
  the main thread by default and a worker wrapper is a follow-up, and that is still true of the
  entry points in §5: `aztec-avm-runtime/browser` runs on the calling thread and nothing here
  changed. M32 adds `worker.js` and `worker-demo.js` beside them — a dev node hosted in a Web
  Worker, with the page holding a client — and `WORKER-NODE.md` is its write-up. The two new entry
  points are budgeted in `chunk-budgets.json` like every other, and §1's figures above are the
  post-M32 ones.
- **No prover, and there never will be one.** §8.4; `receipt.proving` is the literal `'none'` and the
  disclosure is written before a runtime exists at all.
- **`@aztec/bb.js` is still in the graph, on purpose.** Aliasing it away entirely would have been
  easier and strictly worse: `verify_bb_js_browser_condition_honoured` would then be asking an
  absence of a tree that excludes its subject by construction, which `CAMPAIGN-BRIEF.md` lists twice
  as a defect that shipped. It resolves from `dest/browser/` — 32 files, zero from `dest/node/` —
  and its 7.9 MB chunk is reachable and never fetched.
- **`Grumpkin.reduce512BufferToFr` throws.** Its one caller here is `deriveKeys`, which derives a
  SECRET key; this runtime has no private half (`JOIN-SHAPE.md` §6) and a page that reached it would
  be deriving keys it cannot use. A throw naming the caller beats a wrong reduction, and beats a
  silent 7.9 MB download to do it right.
