# M32 — Worker-Hosted Dev Node — IMPLEMENTATION log

Written as I go, after every completed step. No commits, no pushes: a review agent follows.

Reference state at start (2026-08-28):

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `948623d` | clean |
| `aztec-packages` | — | `ee3c0528d5` | clean |
| `noir` | `blocktracer` | — | clean |
| `codetracer-specs` | — | — | clean |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | **must end with exactly its one pre-existing edit** |

Campaign reference: sweep M0–M31 = **10,820**, 32 milestones, 31 of 32 exit 0, `delta +0`.

---

## Step 0 — reading, and the constraints this milestone runs under

Read in order: `M29-M32-proposed.md`, `OUT-OF-SCOPE.md`, `CAMPAIGN-BRIEF.md` in full, the M32 section
of the milestones file, `m31-review-log.md`, `m30-review-log.md`, `CHAIN-LOOP.md`,
`BROWSER-PACKAGING.md`.

The four things M32 owes, and the two that are traps:

1. `smoke_worker_chain_survives_main_thread_block` — **needs a control that discriminates**: the same
   load with the runtime ON the main thread must stall. Without it the test measures nothing.
2. `test_worker_transferable_container_not_copied` — **measured** by the source buffer being
   detached, not asserted from the call site.
3. `smoke_worker_produces_blocks_while_throttled` — M27 measured monotonic timestamps under
   throttling **on the main thread**. Inheriting that result would be inheriting a measurement of a
   different thing. It has to be re-taken IN A WORKER, under real throttling, and **the check has to
   be able to say the throttling did not reach the worker**.
4. `test_worker_restart_from_snapshot`.

### Baseline measurements taken before anything was written

`node browser/build.mjs` in this repository's own dev shell (node v24.19.0 — the system node is
v25.9.0 and is not the engine the checks run in):

```
browser.js    255.79 KB / 300 KB  (7 files)
testing.js    279.77 KB / 320 KB  (8 files)
demo.js       280.97 KB / 320 KB  (8 files)
node/node.js  225.36 KB / 245 KB  (4 files)
TOTAL       8,155.19 KB gzipped, 13.73 MB raw
```

Every one equals `BROWSER-PACKAGING.md` §1 to the hundredth of a kilobyte, so the baseline is the
document's. `chunks.json` saved to `~/.cache/aztec-m32-worker/chunks-baseline.json` so any movement
this milestone causes is attributable rather than argued about.

---

## Step 1 — the reuse enumeration, done BEFORE anything was written

The campaign has been wrong nine times about whether something needed building, and every miss was a
parallel subdirectory. So the search came first, across the fork and the installed `@aztec/*` tree.

**Found, and it is the whole design:** `aztec-packages/yarn-project/end-to-end/src/test-wallet/` —
`worker_wallet.ts` (216 lines), `wallet_worker_script.ts` (66), `worker_wallet_schema.ts` (14).
**Upstream hosts a wallet in a worker**, over exactly the four moving parts M32 needs: an `ApiSchema`
protocol declaration, `schemaHasMethod` / `getSchemaParameters` / `parseWithOptionals` /
`getSchemaReturnType` out of `@aztec/foundation/schemas`, `jsonStringify` out and `JSON.parse` +
schema in on both ends, and a transport.

**Its transport is `@aztec/foundation/transport` — REJECTED, and the rejection is a MEASUREMENT.**
`CAMPAIGN-BRIEF.md`'s rule: "IT DOES NOT BUILD HERE" is a claim and needs the same evidence as any
other. Built for the browser with the four shims the real build applies:

```
foundation/transport   4 errors: events x3, worker_threads x1
comlink                0 errors, 10.5 KB
```

`@aztec/foundation` has **72 export subpaths and no wildcard**, so the browser-safe half cannot be
imported alone; `./transport` resolves to `dest/transport/index.js`, which re-exports
`./node/index.js`. `verify` re-takes both measurements on every run, with comlink as the control.

**`comlink` 4.4.2 — REUSED.** It is what upstream's OWN browser worker uses
(`barretenberg_wasm_main/factory/browser/main.worker.ts` is `expose(...); postMessage(Ready)`), and
it is a declared dependency of **both** `@aztec/bb.js` and `@aztec/foundation`, i.e. of two of the
four packages `orchestration/package.json` depends on.

**And the value codecs are upstream's**: `Tx.schema`, `ContractClassPublicSchema`,
`ContractInstanceWithAddressSchema`, `AztecAddress.schema`, `schemas.Fr/BigInt/Integer`.

## Step 2 — what was written

| file | what it is |
|---|---|
| `browser/src/worker_protocol.ts` | the protocol: 19 schema-channel operations, 2 declared off-schema, 3 subscriptions, and `WORKER_PROTOCOL_BACKING` for DD-5 |
| `browser/src/entry_worker.ts` | the worker entry. `Comlink.expose({call, subscribe, takeContainer})` behind an `isWorkerScope()` guard, so a check can IMPORT it in Node and read the declarations out of the artefact |
| `browser/src/worker_client.ts` | the page's client. Every call bounded; a terminated client refuses by name rather than leaving a promise nothing can settle |
| `browser/demo/worker_main.ts` + `worker.html` | the demo page and the harness, M27's rule kept: every arm is a button |
| `tools/run_worker_arms.mjs` | six arms in six pages, measured once into `$M32_WORK/worker.json` |
| `verification/lib_m32_worker.sh` | sits on M27's module/bundle/chromium machinery; adds the arm run, `m32_arm`, and M29's `m32_absent` |
| four checks + `_m32_doc_ops.py` | below |
| `WORKER-NODE.md` | the write-up, opened by all four checks from the day it was written |

## Step 3 — the four checks, and what each measures

`just verify-m32`: **225 assertions, 4/4, exit 0.**

```
smoke_worker_chain_survives_main_thread_block: 75
test_worker_transferable_container_not_copied: 69
smoke_worker_produces_blocks_while_throttled:  38
test_worker_restart_from_snapshot:             43
```

### The 2×2 that discriminates

```
                 warm window   busy window
worker            15 blocks     16 blocks
main thread       16 blocks      0 blocks
```

Same interval (250 ms), same warm window (4000 ms), same 4000 ms synchronous spin, same measurement.
The main-thread arm's WARM cell is what makes its zero a stall rather than a broken chain; the
worker arm's warm cell is what makes its busy cell a chain running rather than a backlog draining.
The strongest form is asserted too: the main-thread chain's LAST block predates the moment the spin
began.

The window edges are the WORKER's own `performance.now()`, carried on `NodeState.atMs` from two
`state()` calls the page posts and does not await — the page cannot time a window in which it cannot
run code.

### The transferable, measured

```
before        {present:true, byteLength:196608, detached:false, takes:0, transfers:0}
after a COPY  {present:true, byteLength:196608, detached:false, takes:1, transfers:0}
after a MOVE  {present:true, byteLength:0,      detached:true,  takes:2, transfers:1}
a second MOVE refused: ContainerAlreadyTransferred
```

All four readings taken by the WORKER of its own memory. The copy is the control and goes through
the same method with `Comlink.transfer` not applied. The page's SHA-256 of what it received either
way is equal, and equal to the file the browser's download machinery wrote:
`b6aa579c…`, 196,608 bytes.

### Throttling, re-established IN A WORKER

| mechanism | Chromium's answer |
|---|---|
| `Emulation.setCPUThrottlingRate` on the WORKER's target | **refused**: `Operation is only supported for pages, not workers` |
| the same on the page's target | accepted |
| `Page.setWebLifecycleState('frozen')` | accepted |

So CPU throttling cannot be aimed at a dedicated worker over CDP at all — measured, and asserted, so
the day it changes the check says so. The freeze is what reaches it, and **whether it did is
measured by the worker**: 40 blocks, strictly increasing, exactly one second apart, with a **4,222 ms
gap in `producedAtMs`** (the worker's own monotonic clock, stamped at seal time) against a **median
gap of 252 ms**, and a 4-second jump in the host clock across the same pair. A run in which nothing
reached the worker produces an even chain and this check goes red.

### Restart, and the control that makes the identity capable of failing

Four workers in one page.
Path A (funding + an L1-to-L2 message + 3 blocks, all facade calls): archive root, four-tree state
reference and block number all IDENTICAL after the replay, and the restarted node then produces
block 4. Path B (the same plus a token transfer): archive root and state reference DIFFER, because
`runTokenTransfer` seeds a deployment nullifier, an initialisation nullifier and a token balance
DIRECTLY into the trees and registers a contract in the module's DB — none of them facade calls, so
none of them in M23's replay log. That is `CHAIN-LOOP.md` §5's stated cost, measured on a real
transaction for the first time, and it is the control: the same comparison over the same code
answers both ways in one run.

## Step 4 — two things the first run of the arms found, both of which would have been defects

1. **A worker's fetches are NOT in its page's network log.** The boot arm's page log carries
   `/worker.js` and NOT `/assets/avm.wasm`. So asking DD-11's question — "no request contained
   'barretenberg'" — of the PAGE's log would have been an absence asked of a log that excludes its
   subject by construction, which `CAMPAIGN-BRIEF.md` lists twice as a defect that shipped. The
   runner attaches to the worker's own CDP target and enables `Network` there; the absence is
   asserted over the WORKER's log, with `avm.wasm` present in it as the positive control.
2. **`Runtime.evaluate` with `returnByValue` cannot serialise a bigint**, and the protocol's replies
   carry real ones (`schemas.BigInt`, correctly — a block timestamp IS a bigint). The first arm run
   died in `say()`, four layers from anything to do with workers. Every arm return now goes through
   `plain()`, which is `JSON.parse(jsonStringify(...))` — upstream's own helper, already in the
   graph.

## Step 5 — what M32 moved in other milestones, and what it did NOT

The worker is two more entry points in the **same** esbuild pass, so esbuild's splitting
re-partitioned the shared chunks. **No milestone's assertion COUNT moved.** Three DOCUMENT figures
did, and all three are figures a check re-derives from the artefact on every run — which is how they
were found rather than argued about:

| document | figure | before | after |
|---|---|---|---|
| `BROWSER-PACKAGING.md` §1 | `browser.js` eager | 255.79 KB, 7 files | **255.87 KB, 8 files** |
| | `testing.js` eager | 279.77 KB, 8 | **279.93 KB, 10** |
| | the demo page | 280.97 KB, 8 | **281.12 KB, 10** |
| | `node/node.js` | 225.36 KB, 4 | unchanged — the Node pass is a separate one |
| | total across every chunk | 8,155.19 KB | **8,163.43 KB** |
| `BROWSER-PACKAGING.md` §6 | the demo page's requests | 13, of which 7 shared chunks | **15, of which 9** |
| `BROWSER-GATE.md` §3 | the browser metafile's inputs | 1,064 | **1,068** |

Re-measured afterwards, in this repository's own dev shell:

```
just verify-m27      345   (54/40/33/67/23/21/20/37/14/36)  10/10, exit 0
just verify-m28      353   (104/64/44/54/37/50)              6/6,  exit 0
just ci-browser-gate 104   after the gate document was corrected
verify_provenance_complete 64   verify_pinned_nightly_single_source 28
verify_no_pipeline_predicates 69   verify_reuse_inventory_complete 19 (85 entries, the check is >= 20)
verify_named_checks_exist 9    just check-repo-hygiene 28
```

Both at their reference values **to the assertion**.

### Two things worth carrying, found while doing that

1. **`verify_named_checks_exist` caught a check name that does not exist**, in a COMMENT in
   `worker_protocol.ts`: an early draft pointed at `verify_worker_protocol_is_dd5_shaped`, a name
   nothing implements. That is the check working exactly as intended and it is worth recording
   because the comment read perfectly well.
2. **THE BUILD PRINTS ONE FIGURE AND THE CHECKS RE-DERIVE ANOTHER, AT AN EXACT TIE.**
   `browser/build.mjs` prints `+(gzip/1024).toFixed(2)` and both `_m27_doc_figures.py` and M32's own
   §10 use Python's `round(gzip/1024, 2)`. The demo entry came out at exactly **281.125 KB**:
   JavaScript's `toFixed` rounds half away from zero and prints **281.13**; Python's `round` is
   banker's and gives **281.12**. The document must carry the CHECKS' value or the check is red over
   a document that agrees with the build. Recorded rather than papered over, because the next figure
   that lands on a tie will do this again.

## Step 6 — the mutation harness produced a defect of its own, and it is worth carrying

`scratchpad/campaign/m32-mutations.sh` took its backup with
`[ -f "$BACKUP/$f" ] || cp "$f" "$BACKUP/$f"` — copy only if a copy is not already there. That is
right within one run and **wrong across sessions**. Measured, on this harness, in this milestone:

1. The backup was taken during a two-arm trial run.
2. Two of the five backed-up files were IMPROVED afterwards — `containerBufferState` gained the
   zero-length control described below, and the protocol gained its schema.
3. The next run's very first `restore_all` **reverted both improvements in the working tree**, and
   the check then reported `MISSING` for a field whose source had been silently undone.

Read as a check result, that is a defect in the subject. It is a defect in the harness, and it is
`CAMPAIGN-BRIEF.md`'s "a mutated artefact outlived its restored source" **inverted**: a stale BACKUP
outliving the source it was taken from. The remedy is the same rule — never depend on state you did
not produce in this run — in two parts: the backup directory is wiped and re-taken at the start of
every run, and an **in-progress marker** is left while mutations are live so a run that died
mid-mutation is refused (with `--restore-previous` as the escape hatch) rather than having a backup
taken *of a mutated tree*, which would be the same defect with the sign flipped.

### And it found a real gap in the check, which is why the improvement existed

`test_worker_transferable_container_not_copied` says `detached` is "the platform's own answer rather
than an inference from a zero length". **That sentence was true of nothing**: the only zero-length
buffer in the sequence IS the transferred one, so an implementation computing
`detached = byteLength === 0` would agree with the platform at every point the check looks.
`containerBufferState` now reads a zero-length buffer that was **never transferred**, in the same
call, by the same code — `{byteLength: 0, detached: false}`, the one combination an inference cannot
produce — and mutation arm M2 is exactly that inference. Two assertions; the check is **71** rather
than 69, and `just verify-m32` is **227**.

## Step 7 — the mutation matrix: eleven arms, all re-run after the harness was fixed

`scratchpad/campaign/m32-mutations.sh`. Every arm names the assertions it expects to redden, and the
column that matters is WHICH — "the check failed" and "the check saw what I broke" are different
statements.

| arm | what it breaks | result | the failures, read |
|---|---|---|---|
| M1 | `Comlink.transfer` replaced by a plain return (the container is COPIED) | 71 / **10**, rc 1 | the six the arm is for — after-transfer length, after-transfer `detached`, the copy/transfer pair, and all three of the second-take refusal — plus **four collateral** on the packaging figures, because the mutation changes the bundle's bytes |
| M2 | `detached` computed from the length instead of read from the platform | 71 / **1**, rc 1 | exactly the zero-length control. Nothing else, because every other reading agrees with the platform |
| M3 | the main-thread CONTROL yields instead of blocking | 75 / **4**, rc 1 | the spin counter (0), "produced NOTHING while blocked" (16), "its LAST block predates the spin" (8211 vs 4385), and the discriminator |
| M4 | the worker node's `start()` does nothing | 75 / **4**, rc 1 | both of the worker's windows (0 and 0), the discriminator, and the warm-window agreement |
| M5 | `producedAtMs` is a constant | 38 / **3** + 75 / 4, rc 1 | the worker-clock gap (0 ms), the median ratio, and "production resumed"; and check 1's worker windows, because a constant timestamp puts every block outside both |
| M6 | the harness RECORDS the freeze but never sends it | 38 / **4**, rc 1 | worker-clock gap 252 ms, host-clock gap 1 s, the median ratio, and "the deviation SHRANK somewhere". This is the "a run in which the throttling did not take effect" case, and all four of the assertions written for it fire |
| M7 | `importSnapshot` returns state without replaying | 43 / **5**, rc 1 | block number 3 → 0, the archive root, the state reference, path B's block number, and the pair |
| M8 | path B stops seeding state behind the facade | 43 / **6**, rc 1 | the two "must DIFFER" assertions become equalities, the three token-transfer facts go `MISSING`, and the pair |
| M9 | an operation backed by a symbol only `testing.js` exports, left undeclared | 75 / **2**, rc 1 | the DD-5 set equality (`[blocks runTokenTransfer]` against the declared `[runTokenTransfer]`) and the document sentence that states it |
| M10 | **THE HANG** — the worker never posts its readiness message | **0 / 1 WITH a summary line**, rc 1 | bounded and NAMED: *"the worker node's 'readiness' message did not arrive within 20000 ms. That is the HANG state reported as a failure."*, then *"exited (status 1) before finish; the summary above counts that as a failure"* |
| M11 | **DIE BEFORE THE SUMMARY** — the arm report is hollowed | **1 / 2 WITH a summary line**, rc 1, and **"M11 held: the report is still hollow after the run"** | `m32_absent` names all eleven missing fields in ONE assertion and `die`s; M22's trap prints the summary |

**M10 and M11 are the two the brief asks for by name, and both behave.** M11 carries M30's review's
guard — bring the cache's producer current BEFORE mutating it, then assert after the run that the
mutation is still there — and it reported that it held, so the 1 / 2 is a measurement of the arm and
not of a race.

**The collateral packaging failures are real and are not noise to be suppressed.** Any mutation that
changes a source changes the minified bundle's bytes, and `WORKER-NODE.md` §5's eager figures are
DERIVED and asserted. M1 moved four of them by 0.01–0.02 KB. That is the document doing its job; it
is recorded here so a reader of an arm's failure list can tell the arm's own failures from the
bookkeeping.

**One mutation did not survive being written and is recorded rather than replaced quietly.** M2's
first form made the COPY path transfer as well, to collapse the control. Measured: the first take
then detaches the buffer, the second throws `ContainerAlreadyTransferred`, the arm run exits 1,
`m32_require_arms` dies at its precondition, and the check reports **0 assertions, 1 failure** — a
crash, not coverage, which is M24's review's rule met on this milestone's own harness. The property
it was meant to exercise is covered by M1 from the other side. M2 is the inference mutation instead,
and it is the most precise arm in the matrix: one failure, the one assertion written for it.

**And the harness's own restore is controlled.** `verify_restore_control` corrupts a scratch copy by
one line and requires the comparer to see it, on every run; after all eleven arms the tree is
`restore: every file is byte-identical to its pre-mutation copy`, and `just verify-m32` is 227 again.

## Step 8 — THE SWEEP: 11,049, M0–M32, 32 of 33 exit 0

`setsid`-detached, `direnv exec <aztec-avm-runtime>` — this repository's own dev shell, node
v24.19.0, the engine and the PATH the checks and CI use — one milestone at a time with nothing else
running, `TMPDIR` and the log under `~/.cache`. **66 markers for 33 milestones: no hole.**

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 229
                                                       CAMPAIGN TOTAL 11,049
```

`10,820 + 229 = 11,049` exactly, and the summariser reports **`delta +0`** against a reference table
that names M32's 229 in advance.

- **Every one of M0–M31 came out at its reference value TO THE ASSERTION.** Including M27 at 345 and
  M28 at 353 with the browser bundle rebuilt and three of their document figures corrected, M24 at
  350 (`ct-host/src` untouched, so `_m24_oq6_stamp` did not fire and no benchmark re-ran), M1 at 175
  and M0 at 156 with a new row in `README.md` and four new `REUSE-INVENTORY.md` entries.
- **M11 = 262, rc 1, NINE failing assertions** — the recorded signature of the ninth upstream move
  (`7471a61f1a`), unchanged, not repaired, `carry/` left at HEAD.
- **M9 did NOT flake** — 807, 7/7, exit 0 in **1,290 s**, immediately after M8's build, which is
  D19's standing hypothesis and it did not fire. Two sweeps in a row in this session.
- **M15 did not flake either** — 537, 6/6, 382 s.
- **A SWEEP IS A WRITER.** `carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` /
  `ec959b84…` before, came out `79f597b2…` / `3836c2b6…` — the same two post-sweep digests M31's
  review recorded, so the mechanism is unchanged — and were restored to the pre-sweep digests,
  confirmed by `sha256sum -c`.
- **`noir-wt4-webpage` was untouched throughout.** It begins and ends at `f0e7edcd2` on
  `wasm/webpage` with **exactly** its one pre-existing edit (`tooling/tracer/src/tracer_glue.rs`),
  and the branch tip is contained in **zero** published refs — OQ-7 fact 7, re-measured.
- **No commits and no pushes**, in any repository.

### The FIRST sweep, and why there were two

An earlier full sweep, taken at 22:05, read **11,047** with `m32 227` and the same `delta +0`. It is
not the reported figure because two things changed after it, both of them hardening this
milestone's own checks:

1. **Four document needles were anchored to their PHRASE rather than to their row.** `WORKER-NODE.md`
   §1's rejection row spells the split as `` `events` ×3 `` and `` `worker_threads` ×1 ``, so
   `str_has_word "$row" 3` — asserting the TOTAL — was satisfied by a part; and §5's packaging rows
   carry a BEFORE column, so a needle for the file count matched the pre-M32 figure the row records
   for contrast. That is M24's review's "anchor the needle to the row" one level further in.
2. **§3's three parameters became a TABLE, one figure per row**, because anchoring them exposed the
   other half: the sentence wrapped at 100 columns and "busy window **4000 ms**" was on the next
   line, so `row_for` could not see it. `CAMPAIGN-BRIEF.md`'s "a needle that spanned a line break",
   met by this milestone's own check on its own first run of the fix — and the remedy the campaign
   already prescribes for it.

`smoke_worker_chain_survives_main_thread_block` is **77** rather than 75 for the second change
(three rows × two assertions instead of one line × four), and `just verify-m32` is **229**. The
second sweep was then taken over the final tree, so there is exactly one sweep to read and no
post-sweep drift to reconcile — which is the shape `CAMPAIGN-BRIEF.md` asks for, with "after my last
edit" standing in for "after my last commit" because an implementation agent makes none.

### Step 8.1 — what changed AFTER the sweep, and what was re-measured for it

Three documentation edits landed after the sweep: `CAMPAIGN-BRIEF.md`'s new sweep block and its two
new lessons, the milestone section's own sweep block, and this log. `CAMPAIGN-BRIEF.md` is opened by
no check — it is cited in eleven check headers and read by none — but the rule is to re-measure
rather than reason, so the milestones that read this repository's documents or the specs tree were
re-run:

```
m0 156 rc=0   m1 175 rc=0   m11 262 rc=1 (nine failures, the ninth upstream move)
m14 460 rc=0  m16 223 rc=0  m32 229 rc=0
```

Every one at its reference value **to the assertion**. `carry/` was restored to its pre-sweep
digests afterwards, again.

## Step 9 — the tree, as it is left

- **No commits and no pushes in any repository.** `aztec-avm-runtime` HEAD is still `948623d`.
- `aztec-avm-runtime`: 8 modified (`BROWSER-GATE.md`, `BROWSER-PACKAGING.md`, `CAMPAIGN-BRIEF.md`,
  `Justfile`, `README.md`, `REUSE-INVENTORY.md`, `browser/build.mjs`, `browser/chunk-budgets.json`),
  17 untracked (the six sources, the runner, the library, the four checks, the doc-scanner, the
  write-up, and four scratchpad files). `carry/` at its pre-sweep digests.
- `codetracer-specs`: `Planned-Work/Aztec-AVM-Runtime.milestones.org` modified, nothing else.
- `noir-wt4-webpage`: untouched — `f0e7edcd2` on `wasm/webpage`, exactly one pre-existing edit,
  contained in **zero** published refs (OQ-7 fact 7, re-measured at the start and at the end).
- `aztec-packages` and `noir`: not touched.
- File modes match the repository's convention: the four checks and the two Python helpers are
  executable, `lib_m32_worker.sh` and `tools/run_worker_arms.mjs` are not, which is what
  `lib_m27_browser.sh` and `tools/run_browser_arms.mjs` are.

`just check-repo-hygiene` 28 / 0 and `just verify-m32` 229 over the final tree.
