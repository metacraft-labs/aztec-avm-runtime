# M24 review log — `.ct` Writer Binding and the Trace Event ABI

Written as I go. Four prior reviews were killed mid-sweep; everything long runs `setsid`-detached
with its log under `~/.cache`.

---

## R0 — the two documents I was told to read first, and one of them does not exist

- `scratchpad/campaign/m24-brief.md` — **DOES NOT EXIST.** The scratchpad holds
  `m24-impl-log.md`, `m24-mutations.sh`, `m24-mutation-results.txt` and
  `m24-render-trace-abi.py` and no brief. M23 has no `m23-brief.md` either, so the
  per-milestone brief is a coordinator artefact that was never written to disk for M24.
  Recorded, not fixed.
- `scratchpad/campaign/ctfs-writer-parity-brief.md` — **DOES NOT EXIST** anywhere under
  `/home/zahary/m/blocktracer` (searched to depth 4). The superseding decision is therefore
  taken from my instructions rather than from a file.

Read in full: `CAMPAIGN-BRIEF.md`, `TRACE-ABI.md`, the M24 section of
`Aztec-AVM-Runtime.milestones.org` (lines 9357-9379), `m24-impl-log.md`.

---

## R1 — THE PUBLICATION CLAIM. **THE PINS ARE UNPUBLISHED. CONFIRMED, AFTER A LIVE FETCH.**

This is the claim I was asked to establish, and it is true in the worst direction.

### What was measured

`git ls-remote origin` against both real remotes, then `git fetch origin --prune` to refresh
remote-tracking refs (both fetches DID move `origin/dev`, so the ref state I checked against is
current and not a stale cache), then `git for-each-ref --contains <sha>` over **all** refs
(heads *and* remotes) in each repository.

| pinned commit | repo | contained by |
|---|---|---|
| `9cbc127ef8` (`trace_format`) | `metacraft-labs/codetracer-trace-format` | `refs/heads/wasm/ctfs-writer` **only** |
| `baea074019` (`trace_format_nim`) | `metacraft-labs/codetracer-trace-format-nim` | `refs/heads/wasm/nim-to-wasm` **only** |
| `47ba17f43d` (`control_commit`) | `metacraft-labs/codetracer-trace-format-nim` | `refs/heads/wasm/nim-to-wasm` **only** |

`ls-remote origin` on `codetracer-trace-format` lists 37 heads and **no `refs/heads/wasm/ctfs-writer`**.
`ls-remote origin` on `codetracer-trace-format-nim` lists 18 heads and **no `refs/heads/wasm/nim-to-wasm`**.
No `refs/remotes/*` ref in either repository contains any of the three commits, after a fetch.

**So all three pinned commits exist only in a local object store on this host.** M24's own
`pins.json` says the branch is "LOCAL-ONLY", so the fact was recorded — but recorded as a
*rationale for pinning a commit instead of following a branch*, which is not the consequence.
The consequence is that `verification/build_ct_writer_wasm.sh` and `verification/build_ct_print.sh`
do `git archive <rev>` out of an object store nobody else has: **they succeed here and fail
everywhere else, including CI**, and every check in the milestone is green either way.

Status: **blocking defect**. Remedy attempted below (push the two branches to the
`metacraft-labs` remotes the campaign already owns).

### The remedy: both branches are now published

```
git -C ctf-wt-wasm     push origin wasm/ctfs-writer:refs/heads/wasm/ctfs-writer   -> [new branch]
git -C ctfnim-wt-wasm  push origin wasm/nim-to-wasm:refs/heads/wasm/nim-to-wasm   -> [new branch]
```

Re-verified after a fresh `git fetch --prune` in each repository:

```
9cbc127ef8  refs/heads/wasm/ctfs-writer  refs/remotes/origin/wasm/ctfs-writer
            ls-remote origin refs/heads/wasm/*  ->  9cbc127ef8…  refs/heads/wasm/ctfs-writer
baea074019  refs/heads/wasm/nim-to-wasm  refs/remotes/origin/wasm/nim-to-wasm
47ba17f43d  refs/heads/wasm/nim-to-wasm  refs/remotes/origin/wasm/nim-to-wasm
            ls-remote origin refs/heads/wasm/*  ->  0f0169830a…  refs/heads/wasm/nim-to-wasm
```

Both worktrees were clean at push time (`git status --porcelain` empty in each), so what is on
the remote is exactly what the pins name. No PR opened; pushed to `metacraft-labs` only, per the
standing brief. **The three commits are now published and the exposure is closed** — but the
prose that says otherwise has to follow, and a check has to hold it, or the next anchor has the
same hole. Both are done below.

---

## R2 — `just verify-m24` reproduces, exactly

Run `setsid`-detached under `direnv exec` (this repository's own dev shell — **node v24.19.0 /
V8 13.6.233.17-node.51**, the engine `arms.tsv` names), `TMPDIR` under `~/.cache`.

```
verify_ct_writer_wasm_zero_imports:     49 assertion(s), 0 failure(s)
test_ct_container_roundtrip_ct_print:   46 assertion(s), 0 failure(s)
test_dropped_column_awareness_asserted: 39 assertion(s), 0 failure(s)
test_single_trace_types_instantiation:  37 assertion(s), 0 failure(s)
test_trace_writer_backpressure:         30 assertion(s), 0 failure(s)
verify_trace_event_abi_batched_faster:  91 assertion(s), 0 failure(s)
                                       292, exit 0
```

Summary lines at column 0 only. **292 = 49/46/39/37/30/91 confirmed**, verdict `within-noise` at a
3.0 % margin, engine reported by the check as node v24.19.0 / V8 13.6.233.17-node.51 — the same
engine the `#CONFIG` line of `arms.tsv` carries. Claim 1's first half survives.

---

## R3 — claims verified by direct inspection

### Zero wasm imports and 246,527 bytes (claim 5) — **both true, measured on the module**

Not read from a recorded number; read out of the binary, in the dev shell:

```
ls -l  aztec_ct_writer.wasm                  246527 bytes
sha256                                       75626c7268de8ff4…  (= TRACE-ABI.md §7's 75626c72…)
WebAssembly.Module.imports()                 length 0, []
raw section walk (id,len)                    1/380 3/1052 4/7 5/3 6/9 7/337 9/337 10/214852 11/29516
  -> there is NO section id 2 at all         (import section absent, not merely empty)
  -> section id 5 (Memory) IS present        (the memory is DEFINED, not imported)
WebAssembly.Module.exports()                 20: memory + 19 functions
```

### Byte-identical containers from both ABIs (claim 4) — **true, with a control**

```
cmp equivalence-batched.ct equivalence-perevent.ct   -> rc 0, identical
sha256 both                                          -> a16e5622…  (same)
sizes                                                -> 282,624 each   (TRACE-ABI.md §3 agrees)
crossings                                            -> 8 vs 2,000     (genuinely different paths)
NEGATIVE CONTROL: cmp equivalence-batched.ct roundtrip.ct -> "differ: byte 17", rc 1
```

So the comparer can say "different"; the equality is not vacuous. The check also has non-degeneracy
partners (≥10,000 bytes, crossing counts must differ, both containers must READ). What the check
does NOT carry is a control of its own — the evidence that `identical` can come out `false` is the
M11 mutation, not an in-check control. That is acceptable but worth naming.

### DD-7's conditionality (claim 6) — **true, and I executed the counterfactual**

`ct_dropped_column_awareness()` returns `DROPPED_COLUMNS`, set at close from
`s.writer.dropped_column_awareness()` (`ct-writer/src/lib.rs:308,322`) — the writer's own signal,
not a literal. The host's `close()` throws only `if (columnsRequested && dropped)`
(`ct-host/src/writer.ts:278`).

Executed a plain recording through the real module:

```
ordinary recording: events 100  columnsRequested false  droppedColumnAwareness false
module ct_columns_requested()       = 0
module ct_dropped_column_awareness()= 0
=> assert(droppedColumnAwareness === true) would FAIL here
```

and the arms' `gates` array shows the other side: `columns:true` on Path A throws
`ColumnAwarenessUnavailable` at configuration time (and again through a `JSON.parse`'d `true`), a
shape-identical unresolved object throws `UnresolvedTracingConfig`, a columns-requested run closed
on the Path A module throws `ColumnAwarenessDropped`, and the fifth gate —
`ordinary-recording-is-allowed` — does NOT throw, which is what stops the other four being
satisfied by a host that refuses everything. Claim 6 survives whole.

### M18's stale reason clause (claim 8, second half) — **corrected in both places, no status moved**

`git diff` of `Aztec-AVM-Runtime.milestones.org` contains exactly **one** `:status:` change
(M24 `planned` -> `completed`) and exactly **six** `status:` changes, all of them M24's own
verification entries `pending` -> `passing`. M18's five pending entries are still `pending`. The
clause is corrected in the `e2e_ts_wasm_token_transfer` description *and* in M18's "What is not
done" prose, and both corrections say in terms that the conclusion does not move. Survives.

---

## R4 — the enumeration (claim 2). **DOES NOT SURVIVE AS STATED.**

Dispatched a broad search over the whole workspace and then verified every load-bearing hit by
reading the file myself.

**What survives:** Path A (`codetracer-trace-format/codetracer_trace_writer`, `CtfsTraceWriter`)
and Path B (`codetracer-trace-format-nim`) are the two general-purpose writers and neither was
M24's to write. `codetracer_trace_writer_ffi` is exactly what was claimed — verified directly:
`grep -c no_mangle` = **24**, `crate-type = ["staticlib", "cdylib"]`, cbindgen build script and a
committed header, `trace_writer_register_step` one call per event, no batch entry point. And the
dependency-graph half of the claim survives *exhaustively*: across every `Cargo.toml` and all 23
`Cargo.lock` files naming these crates there is **no** `git =` and **no** crates.io `source =` —
every one is path-resolved, and the three worktrees are worktrees of the same object store.

**What does not:**

| the claim | the counterexample, verified by reading it |
|---|---|
| "two real `.ct` writers exist in this workspace" | `codetracer-native-recorder/ct_recorder/src/ct_recorder/ctfs_nim.nim` — 1,169 lines, own `CtfsMagic`, `CtfsVersion = 4`, `createCtfs`/`createCtfsStreaming`/`addFile`/`allocBlock`/`insertDataBlock`/`writeCtfsToFile`/`closeCtfs`; driven by `trace_writer.nim` (873 lines, "creates a CTFS trace container with meta.dat and per-thread event streams") which imports only `meta_dat` and `uuid_v7` from the sibling. **A third `.ct` writer, live, in a recorder repo.** |
| same | `codetracer/src/backend-manager/src/browser_stream_host.rs` — `JsonFileCtfsWriter`, own `TraceLowLevelEvent`/`StepRecord`/`ValueRecordOnDisk`, writes `<program>.ct/{trace,trace_metadata,trace_paths}.json`; its `Cargo.toml` names no trace-format crate |
| same | `codetracer-pure-python-recorder/src/trace.py:248` and `codetracer-pure-ruby-recorder/lib/recorder.rb:410` each serialise the legacy three-file container in their own language, no FFI |
| "no vendored copy … in twenty-two recorder repos" | `codetracer-native-backend/src/ctfs_meta_writer.rs:29` calls itself "a thin **in-crate vendored copy**"; `codetracer-wasm-recorder/tracewriter/codetracer_trace_writer{,_columns}.h` and `codetracer-php-recorder/ext/codetracer_trace_writer.h` are hand-maintained, mutually diverged copies of the cbindgen header — two of those three inside recorder repos |
| "OQ-6's per-event arm … for Go" | true historically, **stale now**: `codetracer-wasm-recorder/scripts/detect-trace-format.sh:21-27` records the migration to the Nim FFI on 2026-05-08, and **no `Cargo.toml` in the workspace depends on `codetracer_trace_writer_ffi`** |

None of this changes M24's conclusion — the event-ingest ABI was still unwritten and reusing
Path A was still right. It is a reason-not-conclusion correction, in the section whose entire
subject is how wide a search was. Corrected in the milestone and in `REUSE-INVENTORY.md` RI-42.

---

## R5 — the three "hang" mutations (claim 1, second half). **ONE OF THEM IS A HANG.**

Re-ran M5, M6 and M7 through M24's own harness, then reproduced each on its own with the full
check output captured, because the harness prints only `^  FAIL` lines and a `die` does not
produce one.

```
M5  roundtrip     rc=1  0 assertion(s), 1 failure(s)     M7  backpressure  rc=1  0 assertion(s), 1 failure(s)
M5  backpressure  rc=1  0 assertion(s), 1 failure(s)
M6  roundtrip     rc=1  0 assertion(s), 1 failure(s)
```

So the precondition fix is real and reproduces: **each gives one named failure and a summary
line**, which is exactly what the `die`-in-a-subshell and `die`-under-`>/dev/null` family used to
destroy. That part of claim 1 survives.

**But only M6 hangs, and only M6 exercises the bound.**

| id | elapsed | the diagnostic |
|---|---|---|
| M6 | **27 s** against a 25 s bound | `the ct-writer arms run EXCEEDED its 25s bound and was killed (status 124)` … `Command: node --experimental-strip-types …run_ct_writer_arms.mjs …` |
| M5 | seconds | `tools/run_ct_writer_arms.mjs failed; see …/bounded-run.log` — and the log reads `Warning: Detected unsettled top-level await`. **Node exits 13 on an unsettled top-level await; the driver never hangs.** |
| M7 | **2 s** | same driver-failed message; the log is `RangeError: offset is out of bounds` at `encodeStep (abi.ts:144)` |

So "three hangs" is **one hang**, and "the bound fired" is true of M6 alone.

### And M7 is worse than mis-labelled: it never reaches the assertions it is supposed to test

M24's matrix says M7 is "the host stops flushing until close … the container is still correct;
only the crossing identity and the buffer bound can see it". It is not: letting `filled` run past
`batchRecords` writes past the end of the wasm-side buffer on the **first** arm, the driver dies,
and **not one backpressure assertion runs**. The check's central claim had therefore never been
exercised by anything.

**So I wrote the mutation M7 was meant to be** (`scratchpad/campaign/m24-review-mutations.sh`,
RM1): events are held in a JS array and encoded into a freshly allocated wasm buffer in ONE
crossing at flush time, so host-side buffering grows with the transaction and the container is
unchanged. The check catches it, by exactly the assertions it advertises:

```
test_trace_writer_backpressure: 30 assertion(s), 5 failure(s)
  FAIL the host heap does not scale with the event count  (test 108 -lt 40)
  FAIL the small arm crossed exactly ceil(N / batch) times   expected [25],  got [1]
  FAIL and so did the large arm                             expected [245], got [1]
  FAIL the large arm really did cross many times             expected >= 100, got [1]
  FAIL and it happened many times, not once by luck          expected >= 10,  got [2]
test_ct_container_roundtrip_ct_print: 46 assertion(s), 1 failure(s)
  FAIL the crossing count is exactly ceil(events / batch)    expected [10],  got [1]
```

**The claim survives; the mutation that was supposed to establish it does not.** Noted separately:
`bufferBytes` did not catch it and cannot — it is `batchRecords * RECORD_SIZE`, derived rather
than measured, so "host-side buffering is identical at 65,536 bytes" is a statement about the
driver's argument. The crossing identity and the heap ratio are the load-bearing assertions.

---

## R6 — OQ-6 (claim 3). Design sound; **one gap, now closed**

Read `tools/run_oq6_arms.mjs` rather than its prose. Sessions really are separate **processes**
(`spawnSync(process.argv[0], […, '--session', k])`, one per session, with `timeout:` and a
`#TIMEOUT` row on expiry); the rotation really is ABBA (`block % 2 === 0 ? ARMS : reversed`), so
every arm's mean position within a block pair is equal and the check reads `POSITIONSPREAD` out of
the **table** rather than out of the comment; `ct_ingest_control` really is a second export of the
same body from the same module and runs in the same rotation; min and median are both reported;
every session is bounded. The machine condition is stated in §2 and was read at both ends of the
run. The comparator is itself under test four ways (a fabricated 30 % difference, its reverse, a
scattered control, and a too-short table at exit 3). The honest conclusion — `within-noise`,
speed cannot choose — is what the check asserts, and it asserts the *instability* from §8's own
retained table (at least three runs, signs must be BOTH) rather than as a sentence.

**The gap: the numbers were re-derived, their attribution was not.** Every §2 figure was matched
as `| <number> |`, anywhere in the file. Measured (RM2):

```
swap `batched`'s and `perEvent`'s median and min between the two rows of §2
  -> verify_trace_event_abi_batched_faster: 91 assertion(s), 0 failure(s)
```

A document stating that the per-event arm is the faster one, while the data says the opposite,
passed. The needles are row-anchored now and the same swap gives **four named failures**.

**And a second gap in the same family:** §7's two measured figures were quoted and re-derived by
nothing. `TRACE-ABI.md` §7 changed from 246,527 back to 245,724 passed
`verify_trace_event_abi_batched_faster` 91/0 **and** `verify_ct_writer_wasm_zero_imports` 49/0 —
which is precisely why the milestone file carried 245,724 in two places. Both the size and the
sha256 prefix are re-derived from the built module now, and both mutations redden.

---

## R7 — what the review changed, and what it costs in assertions

Six new assertions in `verify_ct_writer_wasm_zero_imports` (**49 -> 55**) and two in
`test_ct_container_roundtrip_ct_print` (**46 -> 48**). `verify_trace_event_abi_batched_faster`
stays at **91** — the row-anchoring replaces ten needles with ten stricter ones and adds none.

```
verify_ct_writer_wasm_zero_imports      49 -> 55   +1 the trace-format checkout is present
                                                   +1 the pinned commit is on a PUBLISHED remote ref
                                                   +1 the counter's own negative control (empty namespace -> 0)
                                                   +1 TRACE-ABI.md exists as a file
                                                   +1 §7 quotes the module's MEASURED byte count
                                                   +1 §7 quotes its MEASURED sha256 prefix
test_ct_container_roundtrip_ct_print    46 -> 48   +1 the pinned reader commit is published
                                                   +1 and so is its control_commit
M24                                    292 -> 300  (55 / 48 / 39 / 37 / 30 / 91)
```

Every one of the eight was mutated and reddens (`scratchpad/campaign/m24-review-mutations-round2.sh`):

```
pins.json -> a DANGLING commit (git commit-tree, no ref)
   git archive of it succeeds locally: 1,873,920 bytes; remote refs containing it: 0
   verify_ct_writer_wasm_zero_imports: 55 assertion(s), 1 failure(s)
     FAIL the pinned trace_format commit is reachable from a PUBLISHED remote ref  expected >= 1, got [0]
§2 rows swapped
   verify_trace_event_abi_batched_faster: 91 assertion(s), 4 failure(s)
§7 byte count -> 245,724
   verify_ct_writer_wasm_zero_imports: 55 assertion(s), 1 failure(s)
§7 sha256 prefix -> deadbeef
   verify_ct_writer_wasm_zero_imports: 55 assertion(s), 1 failure(s)
```

The dangling-commit probe is the one that matters: it reproduces the blocking defect exactly —
a commit `git archive` resolves here and no remote has — and shows the new assertion is the thing
that would have caught it. The probe leaves an unreferenced commit object in
`codetracer-trace-format`; it is unreachable and `git gc` will drop it.

Tree after every mutation run: `grep -rn MUTATION` over `ct-writer/src`, `ct-host/src`, `tools/`,
`pins.json` finds nothing but the prose in `TRACE-ABI.md` that describes defect 10; `pins.json`
back at `9cbc127ef8…`; and the module rebuilt from clean sources after `rm -rf target` is
**246,527 bytes, sha256 75626c72…** — byte-identical to the one measured at the start, which
independently reproduces the "two clean builds are byte-identical" claim at the corrected figure.

---

## R8 — status honesty (claim 8, first half)

`:status: completed`, six entries `passing`, is **defensible and I am leaving it**, with one thing
said out loud.

Deliverable by deliverable, each checked rather than read: the writer is compiled to wasm with a
raw C ABI and zero imports and is reused unmodified (measured); OQ-6 was settled by measurement
(and the milestone says in its own first paragraph that the deliverable's *wording* — "with the ABI
chosen on the number" — is not met, because the number has no stable sign; that is the honest
form, and the check asserts what was established rather than the premise); DD-7 is honoured and its
conditionality is real (executed); the single instantiation is asserted in the lock file and the
failure reproduced twice; the reader consequence is held as a one-commit difference with both
readers built and run; and the revisit trigger is recorded with its cost — now marked **superseded**
rather than deleted, since the Rust CTFS writer is to reach full parity with the Nim one, so M25's
OQ-5 outcome no longer forces a writer swap.

**What is worth saying out loud: `completed` was declared on a milestone that was reproducible on
exactly one machine.** Nothing in the six deliverables was wrong, and no check was weak in the way
this campaign usually finds — the hole was one level down, in whether the build inputs existed
anywhere but here. That is not a reason to move the status now that the branches are pushed and the
property is asserted; it is a reason to note that "all six entries passing" was never going to
detect it, and that the campaign's reproducibility posture — pinned anchors, `check-drift`,
`PROVENANCE.md` — had no assertion anywhere that a pinned commit is fetchable. It has one now.

The nine Outstanding Tasks are all genuine outstanding work rather than gaps in what M24 claims;
one of them ("no browser engine has been measured") named the wrong engine and is corrected.

---

## R9 — the sweep, M0-M24

Run **after** the review's last commit, `setsid`-detached, one milestone at a time with nothing
else running, `TMPDIR` and the log under `~/.cache`, **inside this repository's own dev shell**
(`direnv exec`) — the engine and the PATH every check and CI use, which is M19's review's finding
and M24's own defect 11. Order is M24's: `m0 m1 m24 m22 m23 m18 m20 m21 m2 m17 m13 m16 m19 m10 m12
m11 m14 m15 m3 m4 m5 m6 m7 m8 m9`.

Summarised by `scratchpad/campaign/m24-review-sweep-sum.py`, which counts **only** summary lines at
column 0 matching `^([A-Za-z_0-9][A-Za-z_0-9 .-]*): (\d+) assertion\(s\), (\d+) failure\(s\)$` —
the character class admits the space in `just check-repo-hygiene:`, which an `[A-Za-z_0-9]+` needle
silently drops — and which **refuses to print a total while a hole is open**. It found a defect in
itself on its first run against a live log: `######## m0 rc=0 secs=40` also satisfies the START
pattern, so a start-first reader opened a second `m0`, closed neither, and reported the whole sweep
as one long hole. The end marker is tested first now, and the reason is written beside it.

(Result appended below when the sweep finishes.)

### Deferred until after the sweep, deliberately

Extending the row-anchored §2 needle from `| arm | median | min |` to the **whole row**, so the
crossings and container-bytes columns are re-derived too (the comparator emits `crossings.<arm>`
and `containerBytes.<arm>` for every arm, so the data is already there). It changes no assertion
COUNT — two per arm either way — but "do not edit a shell script while a run is reading it" and
"a sweep is a measurement of the tree at the moment it ran" both say to do it afterwards and
re-run `verify-m24`.

### The sweep, first pass — 8,428, and **twenty-four of twenty-five milestones are at their
### reference value TO THE ASSERTION**

```
m0 156   m1 169   m2 292   m3 199   m4 218   m5 236   m6 363   m7 287   m8 516   m9 524*
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 324  m22 260  m23 509  m24 300
                                                      TOTAL 8,428   (* M9 flaked; see below)
```

Accounted in both directions:

- **M24 292 -> 300, +8**, and every unit of it is the review's: `verify_ct_writer_wasm_zero_imports`
  49 -> 55 (+6) and `test_ct_container_roundtrip_ct_print` 46 -> 48 (+2). Nothing else in M24
  moved — `test_dropped_column_awareness_asserted` 39, `test_single_trace_types_instantiation` 37,
  `test_trace_writer_backpressure` 30 and `verify_trace_event_abi_batched_faster` 91 are all
  exactly M24's figures, which is the point: the row-anchoring in the OQ-6 check replaced ten
  needles with ten stricter ones and added none.
- **Every other milestone is its reference value exactly.** Including M4 at 218 measured **in the
  dev shell**, which is where M19's review found the `wasm-opt`-on-PATH difference — so that fix
  holds. Including M11 at 259, so upstream has not moved a fifth time. Including M22 at 260 and
  M23 at 509.
- Named regression checks, all at reference: `just check-repo-hygiene` **28**,
  `verify_provenance_complete` **58**, `check-drift` **22** (a NOTE inside
  `verify_vendor_drift_clean`, which is 10), `verify_named_checks_exist` **9**,
  `verify_reuse_inventory_complete` **19**, `verify_pinned_nightly_single_source` **28**,
  `verify_orchestration_reuse_enumerated` **66**. My `pins.json` prose edits moved none of them.
- `repin: 202 assertion(s), 0 problem(s)` appears as an indented NOTE and is **not** counted —
  that line is why M1 was once reported as 316 when it is 141.

So with M9 at its reference 807 the campaign total is **8,711 = 8,703 + 8**, and the only thing
that moved is the thing the review added.

### M9 flaked, and the flake exposed a defect the standing brief had already half-named

`verify-m9` came out **524, exit 1, 12 failing assertions**. 807 - 524 = **283**, and
140 + 143 = **283** exactly: **two checks printed no summary line at all.**

```
verify_observation_hook_step_records_identical:  cannot run: the v8 step transcript … is INCOMPLETE:
                                                 truncated-after-14572-lines-last-key-steps.burn.14298
                                                 (expected sentinel 'avmSteps.done')
test_observer_does_not_perturb:                  cannot run: [v8] the step transcript … is INCOMPLETE: (same)
test_observer_fires_on_exceptional_halt:         113 assertion(s), 11 failure(s)
verify_observation_hook_overhead_budget:          73 assertion(s), 0 failure(s)
test_observer_disabled_is_free:                  126 assertion(s), 0 failure(s)
test_existing_event_emitter_path_still_available: 83 assertion(s),  1 failure(s)
verify_execution_observer_patch_applies_to_upstream: 129 assertion(s), 0 failure(s)
```

**This is the documented M9 flake in its exact shape** — the V8 step transcript stops inside
`burn` and the `avmSteps.done` sentinel never arrives; last time it was 16,719 of 38,915, this time
14,572 lines ending at `steps.burn.14298`. Not a regression in the subject.

**Three things are worth carrying, and none of them is M24's:**

1. **`m9_completeness` WORKS NOW, and the brief still lists its fix as outstanding.** Two checks
   refused to compare and named the truncation precisely. That is exactly what the brief asks for.
2. **But a refusal that `die`s prints no summary line**, so those two checks contributed **0**
   instead of 140 and 143 and the milestone read as a *smaller* milestone rather than a red one —
   `-283` with no failure attributable to them. This is the silent-death shape M22 built the
   abnormal-exit trap for, and M9's checks do not have it: the trap lives in `lib_m22_block.sh`,
   `lib_m23_chain.sh` and `lib_m24_ct_writer.sh` only. **M24's outstanding task says a fourth
   milestone wanting the trap is when it moves into `lib.sh`. This is a fifth caller wanting it,
   and it is retrospective.**
3. **And the completeness precondition covers two of the four checks that read that transcript.**
   `test_observer_fires_on_exceptional_halt` produced **11 red assertions** with names like
   "[v8] oob recorded a step for every one of them — expected [3], got []" and "[v8] burn's last
   record is the instruction that exhausted the gas", and `test_existing_event_emitter_path_still_available`
   one more — every one of which reads like a discovery about the interpreter and none of which is.
   That is the precise misattribution the brief says `m9_completeness` exists to prevent, still
   happening, in the two checks it was not wired into.

M9 is being re-run alone on an otherwise idle box (load 0.75) to establish flake rather than
regression, per the brief's own settled procedure.

### M9 re-run alone — **807, 7/7, exit 0, 1,283 s.** Flake, not regression.

```
verify_observation_hook_step_records_identical: 140   test_observer_disabled_is_free:                  126
test_observer_does_not_perturb:                 143   test_existing_event_emitter_path_still_available:  83
test_observer_fires_on_exceptional_halt:        113   verify_execution_observer_patch_applies_to_upstream: 129
verify_observation_hook_overhead_budget:         73                                            TOTAL 807
```

Load 0.75 at the start, 1.26 at the end. The split is the reference's, check for check.

### The final accounting, in both directions

```
sweep first pass                       8,428
  M9 replaced by its alone-run     - 524 + 807
                                       8,711
reference (M0-M24, M24's impl)         8,703
  + M24 292 -> 300                   +     8
                                       8,711        exact, nothing left over
```

Nothing moved that the review did not move, and everything the review moved is enumerated
per assertion in R7. The final `just verify-m24` after the whole-row needle change is
**300, 6/6, exit 0** (55 / 48 / 39 / 37 / 30 / 91), and mutating a container-bytes cell of §2
gives one named failure at 91, so the strengthened needle bites on every column of the row.
