# M32 — Worker-Hosted Dev Node — REVIEW log

Written as I go. Adversarial verification of the implementation's four entries, 229 assertions,
sweep 11,049, `delta +0`.

Reference state at start (2026-08-29):

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `948623d` | 8 modified, 17 untracked (M32's work, uncommitted) |
| `noir-wt4-webpage` | `wasm/webpage` | must end `f0e7edcd2`, one pre-existing edit, zero published refs |

Campaign reference before M32: sweep M0–M31 = **10,820**.

---

## Step 0 — reading

Read in full: `CAMPAIGN-BRIEF.md` (1,455 lines), `OUT-OF-SCOPE.md`, `m32-impl-log.md`.
Pending: `m31-review-log.md`, `m30-review-log.md`, `WORKER-NODE.md`, `BROWSER-PACKAGING.md`,
`BROWSER-GATE.md`, the M32 milestone section.

---

## Step 1 — MEASUREMENT 1: the throttling refusal and the freeze. **BOTH HOLD**, and one is stronger
   than claimed.

Verified with a probe that shares nothing with M32 — a bare `p.html` spawning a bare `w.js` whose
whole body is `setInterval(() => postMessage({n, at: performance.now()}), 250)`
(`scratchpad/m32probe/throttle_probe.mjs`, run twice in this repository's own dev shell).

| attempt | answer |
|---|---|
| `Emulation.setCPUThrottlingRate` on the worker session, **rate 20** | refused, `-32000 Operation is only supported for pages, not workers` |
| …**rate 2** | the same refusal |
| …**rate 1** | the same refusal |
| `Emulation.setScriptExecutionDisabled` on the same worker session | **the same refusal** |
| `Emulation.setCPUThrottlingRate` on the PAGE session, rate 20 and rate 1 | accepted, `{}` |
| `Runtime.enable` + `Runtime.evaluate` on the worker session | accepted; `self instanceof DedicatedWorkerGlobalScope` = **true**, `typeof document` = undefined |

So the refusal is **not** a mis-issued command and not a value the handler rejected: the session is
live (two other domains answer on it), the identical command succeeds on the page over the same
connection, and the error code is `-32000` (a server-side refusal) rather than `-32601`/`-32602`.
**And it is broader than M32 states**: `setScriptExecutionDisabled` is refused with the same words,
so it is the whole `Emulation` domain that is page-only, not `setCPUThrottlingRate` in particular.
M32's sentence ("CPU throttling cannot be aimed at a dedicated worker over CDP at all") is true and
under-claims.

**And the freeze genuinely reaches a dedicated worker, measured on a worker that is not M32's.**
`Page.setWebLifecycleState('frozen')` on the document, with the worker's own `performance.now()`
stamped at each `postMessage`: gaps `249.9 250.3 249.7 250 250 **4024.4** 225.6 250.1 …` — median
**250 ms**, one gap of **4,024.4 ms** against a 4,000 ms freeze. Nothing of M32's is in that path.

**And the timer that produces M32's blocks is inside the worker**, not on the page: `startTicking`
only does `boot({intervalMs})` + `c.start()`, and `start()` is `runtime.start()` on the worker's own
`RunningPromise` (`entry_worker.ts:306`). So the gap in `producedAtMs` cannot be the page's timer
having stopped — there is no page timer driving production. The concern that the freeze was
"observed on the page" does not apply.

M32's own recorded run re-read out of `~/.cache/aztec-m32-worker/worker.json`: 40 blocks, gaps
`252.2 … 251.8` with one of **4,224.7 ms**, median **252.0**; wall clock `…352 -> …356`, a 4-second
jump; declared deviation `… 11 11 **8** 9 …`, exactly one shrink. Every figure the milestone quotes
is reproduced from the artefact.

*(Nit, recorded not raised: `WORKER-NODE.md` §6 and the impl log say **4,222 ms**; the arm file on
disk holds **4,224.7**; `CAMPAIGN-BRIEF.md`'s handover says **4,223**. All three are labelled
"one recorded run" and no check pins them, which is the document's declared convention — but three
different numbers for one sentence is the shape that becomes a rot.)*

## Step 2 — MEASUREMENT 2: the main-thread control. **HOLDS.**

Re-read from the arm file, not from the prose:

| | warm | busy | last block | busy window opened |
|---|---|---|---|---|
| worker | 15 | 16 | 8196.1 | 4388.8 → 8388.9 |
| main thread | 16 | **0** | **4193.5** | **4405.5** → 8405.5 |

`spun` is 28,672,619 and 29,262,218 — both loops ran. `busyActualMs` 4000 in both. The main-thread
chain's last block at 4193.5 predates its busy window opening at 4405.5, so the zero is not a
rounding of a block that slipped in at the edge.

The unawaited-`state()` reasoning holds under inspection: Comlink's proxy posts synchronously inside
the `apply` trap, so `busyOpenPending = c.state()` is on the wire before `blockMainThread` starts,
and the reply carries the WORKER's reading of when it handled it. The worker arm's window edges and
`producedAtMs` are therefore two readings of one clock; the main-thread arm's are two readings of
the page's. Neither arm compares across clocks.

## Step 3 — the reuse findings. **RI-82 and RI-83 hold; RI-84's rejection holds; one claim is false.**

**RI-82 — confirmed to the line.** `aztec-packages/yarn-project/end-to-end/src/test-wallet/`:
`worker_wallet.ts` **216**, `wallet_worker_script.ts` **66**, `worker_wallet_schema.ts` **14**. The
discipline is exactly as described: `schemaHasMethod` → `JSON.parse` → `parseWithOptionals(args,
getSchemaParameters(schema[fn]))` → dispatch → `jsonStringify`, with `getSchemaReturnType` on the
client side.

**AND IT IS MORE PRIOR ART THAN M32 RECORDED — this is the finding that matters past M32.**
The milestone cites three files. The directory holds three more, and two of them are load-bearing
for M33–M36:

- **`aztec.js/src/wallet/wallet.ts:665` declares `WalletSchema: ApiSchemaFor<Wallet>` — a COMPLETE
  wallet protocol, already written.** `WalletMethodSchemas` is 15 methods (`getChainInfo`,
  `getContractMetadata`, `getContractClassMetadata`, `getPrivateEvents`, `registerSender`,
  `getAddressBook`, `getAccounts`, `registerContract`, `registerContractClass`, `simulateTx`,
  `executeUtility`, `profileTx`, `sendTx`, `createAuthWit`, `requestCapabilities`) plus `batch`,
  which is derived from them by `createBatchSchemas` — so **upstream also ships request batching over
  the same boundary**. `WorkerWalletSchema` is `{...WalletSchema, proveTx, registerAccount}`: two
  lines of extension over a schema nobody here has to write.
- **`worker_wallet.test.ts` (22 lines) is a worked example of testing that boundary WITHOUT a
  worker** — `Reflect.construct(WorkerWallet, [undefined, stubClient])` — and its comment records a
  real defect of the shape (`undefined` fed to `JSON.parse`) that M33–M36 will meet.
- `test_wallet.ts` (426) and `utils.ts` (205) are the wallet the worker hosts.

**The transport half is Node's**, and M32 says so: `wallet_worker_script.ts` imports
`worker_threads` and `NodeListener`/`TransportServer`. So the shape transfers and the transport does
not, which is precisely RI-83/RI-84's split.

**RI-84 — the rejection is real, and the scanner did not undercount.** Re-run through the same
esbuild (`diffsim/node_modules/.bin/esbuild`) with the same four aliases: esbuild's own trailer says
**`4 errors`**, and they are `events` at `transport/node/node_listener.js:1`,
`worker_threads` at `node_listener.js:2`, `events` at `dispatch/create_dispatch_proxy.js:1` and
`events` at `transport_client.js:1` — three and one, exactly as declared. The check's needle is
`Could not resolve "[a-z_]+"`, which cannot see a `node:`-prefixed or hyphenated specifier; here
esbuild's own total agrees with it, so nothing was missed **in this instance**. Control: `comlink`
through the same command, **0 errors, 10.5 KB**, module produced.
`@aztec/foundation` `exports`: **72 subpaths, 0 wildcards**; `./transport` →
`dest/transport/index.js`, whose last line is `export * from './node/index.js'`. 787 lines confirmed
by `wc -l` over `foundation/src/transport/`. Every structural claim holds.

### ✗ CLAIM THAT DOES NOT SURVIVE — "a declared dependency of **both**"

`WORKER-NODE.md` §1, `entry_worker.ts`'s header and `REUSE-INVENTORY.md` RI-83 all say `comlink` is
"a declared dependency of **BOTH** `@aztec/bb.js` and `@aztec/foundation`, i.e. of two of the four
packages `orchestration/package.json` depends on". Measured in the installed tree:

```
@aztec/bb.js       dependencies     comlink ^4.4.1     <- yes
@aztec/foundation  devDependencies  comlink ^4.4.1     <- a DEV dependency
```

A `devDependency` of a published package is not installed for its consumers, so it is **not** why
comlink is in this tree and it is not one of "two of the four". The conclusion (comlink is already
here, via `@aztec/bb.js`) survives on one leg instead of two. Nothing asserts this sentence — the
check measures only that the build resolves — so it is unpinned prose, which is the family
`CAMPAIGN-BRIEF.md` calls "prose drifts from measurement". Corrected below.

---

## Step 4 — MEASUREMENT 3: the transferable. **THE HEADLINE SENTENCE WAS FALSE, AND THE MUTATION ARM
   WRITTEN FOR IT NEVER APPLIED.**

This is the finding of the review. `browser/src/entry_worker.ts`'s `containerBufferState` shipped:

```ts
      // `ArrayBuffer.prototype.detached` is the platform's own answer, not an inference from a
      // zero length: a zero-length buffer that was never transferred reports `false`.
      detached: buffer === null ? false : buffer.byteLength === 0,      // <- the inference
      …
      zeroLengthControl: (() => {
        const empty = new ArrayBuffer(0);
        return { byteLength: empty.byteLength, detached: empty.detached === true };  // <- the platform
      })(),
```

**The comment above the line is the negation of the line.** And it is not only the comment:
`WORKER-NODE.md` §4, the milestone section, `test_worker_transferable_container_not_copied`'s own
§5 header and the review brief's measurement 3 all say the container's `detached` is
`ArrayBuffer.prototype.detached`. It was `byteLength === 0`. Confirmed in the BUILT artefact, not
only the source — `browser/dist/worker.js` carried
`detached:e===null?!1:e.byteLength===0`.

**Why nothing saw it.** The only zero-length buffer the container path ever produces IS the
transferred one, so the inference and the platform agree at all three readings the check takes. The
`zeroLengthControl` was written for exactly this — but it is a SECOND expression over a SECOND
buffer, so it constrains its own code and not the container's.

**And the mutation arm reports a result over a mutation that did not happen.** `m32-mutations.sh`
M2's first substitution is
`detached: buffer === null ? false : buffer.detached === true,` →
`… buffer.byteLength === 0,`. Its needle was **not in the file**. `~/.cache/aztec-m32-mutall.log:27`
records it:

```
=== M2 — detached is computed from the length rather than read from the platform
MUTATION MISS in browser/src/entry_worker.ts: '      detached: buffer === null ? false : buffer.detached === true,'
…
test_worker_transferable_container_not_copied: 71 assertion(s), 1 failure(s)
```

`sub` printed the miss and **returned**; the script runs `set -uo pipefail` without `-e`, so the arm
rebuilt, ran, and produced the 1 failure it had predicted — from the SECOND substitution, which
mutated the control alone. The matrix recorded it as "M2 | `detached` computed from the length
instead of read from the platform | 71 / **1** | exactly the zero-length control … the most precise
arm in the matrix". It had mutated the control and not the subject, over a subject that was already
carrying the defect the arm claims to introduce.

This is `CAMPAIGN-BRIEF.md`'s "a mutation that crashes has not exercised the assertion it was written
for" with the crash removed — the arm did not crash, it measured something else — beside "a tautology
written beside a true statement reads as its proof".

**Where the residue came from.** The impl log's Step 6 records the stale-backup incident: a backup
taken during a two-arm trial run, files improved afterwards, and the next run's `restore_all`
reverting the improvements. The `mut1.log` trial at 19:56 shows the check at **69** assertions and
`after a MOVE {"byteLength":0,"detached":true,…}` with no `zeroLengthControl` — so the field was added
after it. The fresh backup taken at 20:20 already carries `byteLength === 0`, which is why M2 missed.
**The harness fix (wipe-and-re-take + an in-progress marker) is correct and did not undo the damage**:
a backup re-taken at the start of a run is taken from whatever the tree is, and the tree was already
wrong.

### What survives, stated precisely

The substantive claim — the container was TRANSFERRED and not copied — **does survive**, on two legs
the defect does not touch:

- `byteLength` 196608 → **0** is itself the platform reporting a detached buffer; a structured clone
  leaves it at 196608, which is what the COPY reading shows.
- `takeContainerBytes` guards with `if (buffer.detached === true) throw new ContainerAlreadyTransferred()`
  — the real property — so the second take being **refused by name** is a genuine platform reading.

What does not survive is the sentence about `detached`, the check's §5 comment, and M2's row.

### The fix (committed)

Not a corrected line. `containerBufferState` now has ONE reader and both readings go through it:

```ts
const read = (b: ArrayBuffer) => ({ byteLength: b.byteLength, detached: b.detached === true });
const own = buffer === null ? { byteLength: 0, detached: false } : read(buffer);
…
zeroLengthControl: read(new ArrayBuffer(0)),
```

so `zeroLengthControl` controls the instrument the container is measured with instead of a copy of
it, and `{byteLength: 0, detached: false}` is the one combination an inference cannot produce.
M2 becomes **one** substitution, on `read`. And `sub` now **refuses to continue** on a miss —
restoring, checking the restore, clearing the marker and exiting 3 — because a mutation that did not
apply must not be printed as an arm that behaved.

Re-measured after the fix, over a rebuilt bundle and a fresh arm run:

```
before        {"byteLength":196608,"detached":false,…,"zeroLengthControl":{"byteLength":0,"detached":false}}
after a COPY  {"byteLength":196608,"detached":false,…}
after a MOVE  {"byteLength":0,"detached":true, …}
test_worker_transferable_container_not_copied: 71 assertion(s), 0 failure(s)
```

and the corrected M2 arm: **71 / 1**, the one failure being
`…and NOT detached, so 'detached' is not a length test  (… {"byteLength":0,"detached":true} … "detached":false)`
— the same number as before, now for the reason the row claims.

---

## Step 5 — A SECOND DEFECT, IN THE CHECK THAT ADVERTISES THE PROPERTY: the operation list was
   asked of the FILE, not of the list.

`smoke_worker_chain_survives_main_thread_block` §11:

```bash
# EVERY OPERATION NAMED, not a count only: a document that lost an operation from the list while
# keeping the number would pass a size comparison.
assert_eq "…and every operation the bundle declares is named in the document" "" \
  "$(python3 "$VERIFY_DIR/_m32_doc_ops.py" "$BUNDLE_PROTOCOL" "$M32_DOC")"
```

`_m32_doc_ops.py` asked whether `` `name` `` occurred **anywhere in `WORKER-NODE.md`**. Measured:
delete `containerBufferState` from §2's list and the residue is **empty** — §4 mentions the operation
in prose, so the document can lose an entry from the list, keep the number, and pass BOTH the size
comparison and the residue comparison. That is `CAMPAIGN-BRIEF.md`'s "anchor the needle to the row,
not to the file" (M24's OQ-6 finding), in the check whose own comment claims the property.

**Fixed, and calibrated in four directions.** The scanner takes ONE bullet — the line naming
`operations** on the schema channel` to the next blank line **or the next `- ` bullet** — and answers
three questions:

| | as shipped | drop `containerBufferState` from §2 | add a phantom `provePrivate` | rename the anchor |
|---|---|---|---|---|
| `region` (lines) | **6** | 6 | 6 | **0** |
| `missing` | empty | **`containerBufferState`** | empty | **`NO-REGION(…)`** |
| `extra` | empty | empty | **`provePrivate`** | — |

(The first draft ended the region at the next BLANK line. §2's bullets are not blank-separated, so
it swallowed the three bullets after it — 16 lines — and `extra` reported `subscribe`,
`takeContainer`, `block`, `tx`, `trace` as undeclared names, which are the NEIGHBOURS' subjects.
A region that is too wide is the same defect as a needle asked of the whole file, one notch smaller;
caught by running the calibration rather than by reading it.)

`+3` assertions in that check: the region's own size (so "both residues are empty" cannot be "the
region is empty"), the missing residue against the list, and the **other direction**, which nothing
covered — a name the document lists that the bundle does not declare reads exactly like a correct
list until somebody counts.

---

## Step 6 — the mutation matrix. Five arms re-run, including the two the brief names.

`scratchpad/campaign/m32-mutations.sh M2 M3 M6 M10 M11`, `setsid`-detached, in this repository's own
dev shell, `TMPDIR` under `~/.cache`, with nothing else running. Every arm rebuilds the bundle and
re-measures the six arms first, so each is a full round trip.

| arm | declared | measured here | the failures, read |
|---|---|---|---|
| **M2** (corrected form) | 71 / 1 | **71 / 1**, rc 1 | `…and NOT detached, so 'detached' is not a length test` — `{"byteLength":0,"detached":true}` against `"detached":false`. Now a mutation of the reader the CONTAINER's own reading goes through, which is what the row always claimed |
| **M3** control yields instead of blocking | 75 / 4 | **77 / 4**, rc 1 | the spin counter (`>= 1000000, got [0]`), `produced NOTHING while blocked` (`[0]` vs `[16]`), `its LAST block predates the spin` (`8209 -lt 4388`), and the discriminator (`>= 3, got [0]`) — the four named, and only those |
| **M6** the freeze is recorded but never sent | 38 / 4 | **38 / 4**, rc 1 | **the chain comes out EVEN**: worker-clock gap `>= 2000, got [252]` — the median itself — host-clock gap `>= 2, got [1]`, the median ratio `252 -gt 1004`, and `the deviation SHRANK somewhere >= 1, got [0]`. The 4,224 ms gap collapses to one interval when nothing reaches the worker, which is the case the whole check exists for |
| **M10** THE HANG | 0 / 1 with a summary line | **0 / 1 WITH a summary line**, rc 1 | bounded and NAMED, in `worker-failed.json`: *"WorkerCallFailed: the worker node's 'readiness' message did not arrive within 20000 ms. That is the HANG state reported as a failure."* |
| **M11** die before the summary | 1 / 2 with a summary line | **1 / 2 WITH a summary line**, rc 1, and **`M11 held: the report is still hollow after the run`** | `m32_absent` names all eleven absent fields in ONE assertion and `die`s; M22's trap prints the summary. M30's review's guard fired and REPORTED, so the 1 / 2 is a measurement of the arm and not of a race |

**M2's first form is honestly recorded, and I confirmed it.** `~/.cache/aztec-m32-mut1.log:30` shows
that arm at `0 assertion(s), 1 failure(s)` — the crash, not coverage — exactly as the impl log and
the harness header say. That honesty stands. What did not stand is the *replacement*: see Step 4.

**The stale-backup defect's fix is real but did not undo the damage.** `snapshot()` does
`rm -rf "$BACKUP"` before copying and leaves a `.in-progress` marker that refuses a run started over
a mutated tree. Both are right. But a backup re-taken at the start of a run is taken from **whatever
the tree is**, and the M2 residue proves the tree was already wrong when the fix landed. The marker
guards a run that DIED mid-mutation; nothing guarded a source that was quietly left in a mutated
state by an earlier session. That gap is closable now that the files are tracked — see Step 8.

---

## Step 7 — the document figures, ROTTED ON PURPOSE. All three redden.

F17's lesson, and M28's review found `BROWSER-GATE.md` §5 swappable into stating the reverse of D22
while the gate stayed green. So each figure was made wrong and the owning check re-run.

| figure | rot | result |
|---|---|---|
| `BROWSER-PACKAGING.md` §1 total | left at **8,163.43** after the review's source fix moved it to 8,163.44 | `verify_browser_chunk_budget` **33 / 1** — `total-kb expected 8,163.44 in: **8,163.43 KB gzipped across every chunk;…**`. *Found by accident, which is the strongest form of this test: the check caught a figure I had made stale rather than one I had planted.* |
| `BROWSER-PACKAGING.md` §6 | 15 → **13** requests and 9 → **7** shared chunks | `verify_browser_chunk_budget` **33 / 1**, naming BOTH: `request-count expected 15 …` and `eager-chunk-requests expected 9 …` |
| `BROWSER-GATE.md` §3 | 1068 → **1064** inputs | `just ci-browser-gate` **104 / 1** — `the doc's browser input count is the metafile's [1068 on the line naming 'The browser bundle's module graph has'] … got [wrong:- … has 1064 inputs.]` |

All three restored and re-confirmed. **And M28's six checks came out at reference in that run**:
104 / 64 / 44 / 54 / 37 / 50 = **353**, with `verify_browser_entry_points_are_dd5_shaped` at 40
inside the gate (where M28's own recipe excludes it), exactly as the brief records.

*(One latent weakness, recorded not fixed: `_m27_doc_figures.py`'s `compare` requires the number
anywhere on the matched LINE, and §6's chunk-count line carries two numbers — `10  /demo.js + 9
shared chunks`. If the true chunk count were ever 10 it would be satisfied by the request count at
the start of the same line. It is 9 today, so the assertion discriminates today.)*

## Step 8 — every other claim, checked

| claim | verdict |
|---|---|
| 516 instructions, `revertCode` 0, block 1, two named functions | **holds** — read out of `arms.boot.transfer`: `executedSteps` 516 = `instructionsExecuted` 516, `revertCode` 0, `blockNumber` 1, `Token.transfer_in_public` + `Token.balance_of_public` |
| four worker targets in the restart arm, path B differs | **holds** — the check reads both and asserts the pair answers both ways in one run |
| "the only `document.` in the four source roots is `offerDownload`" | **true**, and unpinned. `grep -rn 'document\.'` over `orchestration/src node-host/src ct-host/src browser/src` returns three hits: two in `ct_download.ts`'s `offerDownload`, and one inside a COMMENT in `token_transfer.ts` that ends a sentence with the word "document." — a needle hazard if anything ever pins the count. Nothing does; the milestone says it is measured rather than asserted, and it is |
| `isDedicatedWorker: true, hasDocument: false, hasWindow: false` | **holds**, in both arms that probe it, taken by `Runtime.evaluate` on the worker's own session |
| M2's first form crashed the arm and was recorded rather than replaced quietly | **holds** — `~/.cache/aztec-m32-mut1.log:30` shows `0 assertion(s), 1 failure(s)` for that arm, and both the harness header and the impl log say so. *That honesty stands; it is the replacement that did not — see Step 4* |
| the stale-backup defect was found, fixed and written into `CAMPAIGN-BRIEF.md` | **the fix holds and is insufficient** — `snapshot()` does `rm -rf "$BACKUP"` and leaves `.in-progress`; both are right, and neither covers a source left mutated by an earlier session and then backed up, which is what happened. A `git status --porcelain` comparison against HEAD over the mutated file set is added |
| DD-5's rule is symbol-level, so it cannot see a new operation on `AvmRuntime` | **not a hole.** `browser.js` exports `AvmRuntime` itself, so every method of it IS a capability the reference bundle has. The rule's granularity is correct for the claim it makes |
| "the worker's fetches are not in the page's log" | **holds** — `arms.throttled.avmWasmRequests` is `[]` while `workerAvmWasmRequests` is `["/assets/avm.wasm"]`, and the DD-11 absence is asserted over the worker's log with `avm.wasm` in it as the positive control |
| `noir-wt4-webpage` untouched | **holds** — `f0e7edcd2` on `wasm/webpage`, exactly one modified file (`tooling/tracer/src/tracer_glue.rs`), `git for-each-ref --contains HEAD refs/remotes` = **0**, and zero published refs named `wasm/webpage`. Re-measured at the start of the review and again before the sweep. Not committed, not pushed |

---

## Step 9 — A FOURTH FINDING, and I got it wrong first: a COUNT inside a window is not production
   during it.

Reading the arm report rather than the check, the worker's sixteen busy-window blocks are spaced
`252.3 252.3 252.0 251.6 …` — evenly, across the whole four-second spin. **Nothing asserted that.**
The check counts blocks in `(busyOpen, busyClose]`, and a count is equally satisfied by a chain that
stalled for 3.8 seconds and delivered sixteen in a burst the moment the thread came back — a backlog
draining at the window's right-hand edge, which is the first alternative a sceptic reaches for and
the one the whole 2×2 is meant to exclude. The check's own header even names it ("the worker arm's
warm window is what says its busy-window count is a chain running rather than a backlog draining") —
but the warm window says nothing about *where inside the busy window* the blocks landed.

**And the first form of my own addition did not catch it.** I asserted that no consecutive pair of
in-window blocks is more than three ticker intervals apart. Calibrated by doctoring the arm report —
all sixteen blocks moved into the last 200 ms before the window closes, count unchanged — the check
reported **82 assertions, 0 failures**: a tight cluster looks like *perfect* cadence, because the 3.8
second stall in front of it lies between the window OPENING and the first block, which the span I
measured did not include.

With `busyOpen` as the first point, the same doctored report gives a largest interval of
**3,812 ms** and **two failures**:

```
  --   consecutive spacing: 16 gap(s) in the busy window, largest 3812 ms; 15 gap(s) warm, largest 252 ms
  FAIL …and NO interval from the window OPENING onward is more than three ticker intervals …
       (command failed: test 3812 -lt 750)
  FAIL …and its worst spacing is within twice the warm window's (command failed: test 3812 -le 504)
smoke_worker_chain_survives_main_thread_block: 82 assertion(s), 2 failure(s)
```

and over the real report, **252 ms in both windows at a 250 ms ticker**, 82 / 0. Arm report restored
and re-confirmed. *A control that is not run is a control that is the wrong shape* — this one was
written, read, and wrong, and only running it said so.

`+3`: the gap count (non-degeneracy — with fewer than two points the helper prints `-1`, which must
fail rather than pass vacuously), the bound, and the warm-window pair.

### And the same data answers the last attribution question about the freeze

`Emulation.setCPUThrottlingRate` at rate **20** is applied to the PAGE and stays applied for the
freeze plus three seconds after the thaw. Across that post-thaw stretch the worker's own gaps are
`251.6 252.1 251.7 251.9 252.3 251.7 252.1 251.5 …` — **ordinary cadence while the page is throttled
20×**. So the page's CPU throttle demonstrably does not reach the worker, and the 4.2 s gap is
attributable to the freeze alone. The independent probe says the same from the other side: it applied
**only** the freeze, no CPU throttle anywhere, and produced a 4,024 ms gap in a bare worker's own
clock.

---

## Step 10 — the digest triple, checked against M31's review's finding

The brief asked whether the three readings are the CONSUMER's or the runner's own bookkeeping — the
shape M31's review caught as "a digest compared against itself". They are not:

| reading | who takes it | over what |
|---|---|---|
| `copiedSha256` | the PAGE, `crypto.subtle.digest('SHA-256', …)` | the `Uint8Array` it received from a structured clone |
| `movedSha256` | the PAGE, same call | the `Uint8Array` it received from the transfer |
| `downloaded.0.sha256` | the RUNNER, node's `createHash('sha256')` | **the file on disk** that the browser's own download machinery wrote, after `offerDownload(moved.container, …)` built a Blob and clicked an `<a download>` |

So it is two page-side digests of two arrays that arrived by two different mechanisms, plus a
third taken **in a different process, by a different hasher, over bytes that went through the
browser's download path and the filesystem**. All three are
`b6aa579c7e07c0825ce2714ce8cbb0e801c048d0f71919e773e05b636185668f`, 196,608 bytes; the milestone's
`b6aa579c…` reproduces, and it is stable across the review's source fix (the fix touches the worker's
bookkeeping, not the container). `assert_ge "…and the digest is a real one" 64 "${#MOVED_SHA}"` is the
non-emptiness beside the equality.

**And RI-85's "with no edit to it" is true**: `git diff 948623d..HEAD -- tools/browser_cdp.mjs
verification/lib_m27_browser.sh` is empty; `browser_cdp.mjs` was last touched by M27.

**No scope drift into OUT-OF-SCOPE's territory.** `grep -rn 'CodeTracer\|codetracer'` over every M32
source, check and document returns nothing: M32 makes no claim about the debugger, only about bytes,
the reference reader's ancestors, and the browser's own download.

---

## Step 11 — one asymmetry in "the same load", recorded because it points the safe way

The two arms are meant to differ in exactly one thing — where the runtime is. Read side by side they
differ in two more, and both handicap the WORKER rather than the main thread, so neither threatens
the conclusion:

| | worker arm | main-thread control |
|---|---|---|
| `collectExecutionSteps` | **`true`** (`boot()` always passes it) | not passed, so the default |
| subscriptions | **three** (`block`, `tx`, `trace`) across a `Comlink.proxy` | one (`block`), in-process |
| interval / warm / busy | 250 / 4000 / 4000, **asserted equal by the check** | the same, asserted |

Both arms produce only EMPTY blocks in these windows, so step collection has nothing to collect; and
in both respects the worker is doing strictly more work than the control. The check asserts equality
of the three parameters that matter and not of these two. Recorded rather than raised: a
confounder that runs the wrong way for the claim is not a confounder for the claim.

---

## Step 12 — THE IMPLEMENTATION'S OWN TWO SWEEPS, VERIFIED INDEPENDENTLY BEFORE MINE

Both logs are still on disk and both were re-parsed with a summariser written for this step, not with
`m32-sweep-sum.py`:

| | started | finished | markers | total | m32 | m9 | non-zero exits |
|---|---|---|---|---|---|---|---|
| first | 2026-08-28 20:4x | **22:05:42** | **66** | **11,047** | **227** | 807 | `m11` only |
| second (reported) | **22:10:31** | **23:52:51** | **66** | **11,049** | **229** | 807 | `m11` only |

66 markers for 33 milestones in both: **no hole**. m27 345 and m28 353 in both. The account of the
difference — two hardenings of M32's own checks, +2 on
`smoke_worker_chain_survives_main_thread_block` — reproduces exactly.

**"The reported sweep is over the final tree" is TRUE OF THE CODE and qualified in the same log for
the documents.** Step 8.1 records three documentation edits landing after 23:52 —
`CAMPAIGN-BRIEF.md`, the milestone section and the impl log — and the re-run for them is in
`~/.cache/aztec-m32-post.log`, which I re-parsed: **m0 156, m1 175, m11 262 (rc 1), m14 460,
m16 223, m32 229**, every one at reference. The headline sentence ("there is exactly one sweep to
read and no post-sweep drift") overstates by one line what the paragraph below it corrects; the
measurement behind it is sound.

## Step 13 — THE REVIEW'S SWEEP: 11,054, M0–M32, and the two reds are both recorded conditions

`setsid`-detached, `direnv exec <aztec-avm-runtime>` — this repository's own dev shell, node
v24.19.0 — one milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`,
**taken after my last commit** (`07d3055`, pushed). Started 00:41:31, finished 02:24:30.
**66 markers for 33 milestones: no hole.**

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807*
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234
                                                       CAMPAIGN TOTAL 11,054
```

**Every one of M0–M31 came out at its reference value TO THE ASSERTION**, and 10,820 + 234 = 11,054
exactly. In the sweep itself the summariser printed `TOTAL 10771 … delta -283`, and the whole of the
283 is M9's flake, below; every other row was flagless.

- **M32's own 234** is 82 / 71 / 38 / 43. Declared at 229 (77 / 71 / 38 / 43); the five are the
  review's, in `smoke_worker_chain_survives_main_thread_block` and nowhere else.
- **Nothing else moved.** `verify_provenance_complete` **64** (M32 vendors nothing),
  `verify_pinned_nightly_single_source` **28**, `verify_reuse_inventory_complete` **19** (the
  entry-count assertion is `>= 20` and M32's four entries plus my edits to RI-83 do not move it),
  `just check-repo-hygiene` **28**, M27 **345** and M28 **353** with the browser bundle rebuilt four
  times over the review and three of their document figures corrected.
- **M11 = 262, rc 1, NINE failing assertions** — the recorded signature of the ninth upstream move
  (`7471a61f1a`), unchanged, not repaired, `carry/` left at HEAD.
- **M9 FLAKED, AT A SEVENTH DISTINCT TRUNCATION POINT.** 524, rc 1, twelve failing assertions.
  `807 − 524 = 283 = 140 + 143`, the two comparers that correctly REFUSE and print no summary while
  doing it. The truncation is `truncated-after-4051-lines-last-key-steps.burn.3777`; the sightings
  are now **39,113 / 16,719 / 14,572 / 17,866 / 3,943 / 15,688 / 4,051**. Same input, same module,
  same host, so a content-dependent defect stays ruled out and the trigger stays unestablished. The
  twelve red assertions are 11 in `test_observer_fires_on_exceptional_halt` and 1 in
  `test_existing_event_emitter_path_still_available` — **the two checks `m9_completeness` is still
  not wired into**, which is `CAMPAIGN-BRIEF.md`'s own outstanding item and not a finding about the
  interpreter. Re-run alone, which is the settled procedure: see below.
- **M15 did NOT flake** — 537, 382 s.
- **A SWEEP IS A WRITER.** `carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` /
  `ec959b84…` before, came out `79f597b2…` / `3836c2b6…` — the same two post-sweep digests M30's,
  M31's and M32's implementations all recorded, so the mechanism is unchanged — and were restored,
  confirmed by `sha256sum -c`.
- **`noir-wt4-webpage` was untouched throughout.** `f0e7edcd2` on `wasm/webpage`, exactly its one
  pre-existing edit, `git for-each-ref --contains HEAD refs/remotes` = **0**. No commit, no push.

### M9 re-run alone — 807, 7/7, exit 0

```
######## m9 start 2026-08-29T02:59:13+03:00
verify_observation_hook_step_records_identical: 140 assertion(s), 0 failure(s)
test_observer_does_not_perturb:                 143 assertion(s), 0 failure(s)
test_observer_fires_on_exceptional_halt:        113 assertion(s), 0 failure(s)
verify_observation_hook_overhead_budget:         73 assertion(s), 0 failure(s)
test_observer_disabled_is_free:                 126 assertion(s), 0 failure(s)
test_existing_event_emitter_path_still_available: 83 assertion(s), 0 failure(s)
verify_execution_observer_patch_applies_to_upstream: 129 assertion(s), 0 failure(s)
######## m9 rc=0 secs=1285
```

140 + 143 + 113 + 73 + 126 + 83 + 129 = **807**, the reference split exactly, no truncation, and
`test_observer_disabled_is_free`'s timing arm green. Not a regression. `carry/` re-verified against
the pre-sweep digests with `sha256sum -c` after it.

*(The first attempt at this re-run was killed when its launching shell timed out, despite `setsid`;
the log had no `rc=` marker and no `SWEEPDONE`, which is exactly the hole the summariser refuses over
— so it was relaunched rather than read. Worth recording: `setsid` inside a call the harness later
kills is not always enough; launch so that the launching call returns immediately.)*

## Step 14 — the throttling refusal is capable of failing, demonstrated

The check's strongest sentence is "asserted, so the day Chromium changes it this check says so".
Demonstrated rather than believed: the arm report's recorded verdict for
`worker.Emulation.setCPUThrottlingRate` was doctored from `{ok:false, error:"…only supported for
pages, not workers"}` to `{ok:true, rate:20}` and the check re-run —

```
  FAIL …and Chromium refused it: it is a page-only operation (…)
  FAIL …while the worker-target throttle was refused  expected [refused], got [ok]
smoke_worker_produces_blocks_while_throttled: 38 assertion(s), 2 failure(s)
```

— two failures, one from the whole-list needle and one from the per-mechanism verdict. Arm report
restored.

## VERDICT

**The three headline measurements: two hold as stated, one did not.**

1. **The throttling refusal and the freeze — HOLD, and one is stronger than claimed.** The refusal
   is real, reproduced on a page and worker that share nothing with M32, at three rates, with the
   same refusal for a second `Emulation` method (so the whole domain is page-only) and the same
   command accepted on the page over the same connection. The freeze reaches a **dedicated** worker:
   a bare `setInterval` worker shows a 4,024 ms gap in its own `performance.now()` against a 250 ms
   median, with no CPU throttle applied anywhere. In M32's own arm the timer is inside the worker,
   the page's CPU throttle demonstrably does not reach it (ordinary 252 ms cadence for three seconds
   after the thaw while the page is still throttled 20×), and M6 collapses the gap to 252 ms.
2. **The main-thread control — HOLDS and discriminates.** 15/16 against 16/0, both spin counters
   over 28 million, the control's last block at 4,193.5 ms predating its window opening at 4,405.5,
   and M3 reddening exactly the four assertions written for it. The unawaited-`state()` reasoning is
   sound: Comlink posts synchronously in the `apply` trap, so both window edges are the worker's own
   readings and `producedAtMs` is on the same clock. **What the count could not do is tell production
   from a backlog draining at the window's edge; that is measured now.**
3. **The transferable — the READINGS ARE THE CONSUMER'S, but `detached` was not what it said it
   was.** Four readings taken by the worker of its own memory, crossed on the schema channel, with a
   third digest taken in another process over the file the browser wrote — none of it the runner's
   own bookkeeping, so M31's "digest compared against itself" shape does not recur. But the
   `detached` field was `byteLength === 0`, the control was a second copy of the mechanism, and the
   mutation arm never applied. Fixed, calibrated, and the substantive claim survives on `byteLength`
   and on the named refusal.

**Four checks, 234 assertions, 4/4, exit 0. Campaign total 11,054, M0–M32, 33 milestones.**
