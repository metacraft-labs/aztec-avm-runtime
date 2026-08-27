# M25 review log — Step-Level Tracing from the Observation Hook

Written as I go, not at the end.

## Step 0 — the state I inherited, and a concurrency incident I did not cause

The implementation agent's mutation chain finished (`MUTCHAINDONE`, restore verified). Its sweep
had **not**.

**Two M0–M25 sweeps were running over the same working copy when I arrived.** PID 1307321 was mine
(03:03:43); PID 1309414 was the implementation agent's deferred relaunch (03:03:51), fired eight
seconds after mine from the same session's shell snapshot. Both were executing `verify-m0` /
`verify-m1` against `/home/zahary/m/blocktracer/aztec-avm-runtime` simultaneously. The coordinator
confirmed the sequence and that its own `pkill` — intended to kill only the implementation agent's
— matched both.

Consequence for the record: **every sweep artefact written before 03:05 today is untrustworthy**
and none of it is summarised. Moved aside rather than deleted, so the incident is auditable:

```
~/.cache/m25rev/TAINTED-pre0305-impl.log
~/.cache/m25rev/TAINTED-pre0305-implpartial.log
~/.cache/m25rev/TAINTED-pre0305-rev.log
```

The authoritative sweep is **`~/.cache/m25rev/final-sweep.log`**, started
`2026-08-27T03:24:44+03:00` over the COMMITTED tree — the 03:05 one was discarded too, for a second
reason recorded in F8, and kept as `~/.cache/m25rev/DISCARDED-race-with-gashpp-residue.log`. It is
`setsid`-detached, in this repository's own dev shell (`direnv exec <aztec-avm-runtime>` — node
v24.19.0, the engine `TRACE-ABI.md` §2 requires), sole occupant of the tree. I poll it inside my
own run; a monitor process does not outlive the agent that spawned it, and two stale pollers from
earlier agents (PIDs 1316183, 1332322) were sitting in `until grep SWEEPDONE` loops over a log
that had already been deleted. Both killed.

Before starting it I confirmed the tree was not holding a mutated artefact — the failure mode the
implementation agent's own restore arm caught:

```
ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm
  259,839 bytes
  sha256 1e7e0e4fcd3f4183fb954d946fe9f263c508353af2292494f84a3ad07f4192ab
```

Both agree with `TRACE-ABI.md` §7 to the byte and to the prefix.

## Findings

### F1 — the concurrency incident left a TRACKED FILE MUTATED, and my sweep found it

`verify_provenance_complete` proves it can detect a corrupted provenance header by **mutating a
tracked file in the working tree** and restoring it on exit. One of the three sweeps killed at
~03:04 was inside that window, so the restore never ran:

```
 M reference/vm2-common/gas.hpp
-//   upstream-commit: 233d8e099336c1773b89e939100af047ed9c4f71
+//   upstream-commit: 0000000000000000000000000000000000000000
```

My sweep's M1 then read **rc=1 in 16 s**, with the diagnostics naming the real cause rather than
inventing one:

```
FAIL 1 file(s) have a wrong or missing provenance header: HEADER-WRONG  reference/vm2-common/gas.hpp
FAIL a header whose upstream-commit has been altered — the mutation changed nothing; the control is vacuous
FAIL the unmutated scratch copy already fails check-drift; the controls would be meaningless
verify_provenance_complete: 58 assertion(s), 3 failure(s)
verify_vendor_drift_clean:   5 assertion(s), 2 failure(s)
just check-drift:           22 assertion(s), 1 failure(s)
```

**Not an M25 regression, and not a flake.** Restored with `git checkout --`; the diff was exactly
the check's own mutation and nothing else. M1 is re-run alone after the sweep.

Worth carrying beyond this milestone: **a check that mutates a tracked file in place is one
`SIGKILL` away from handing the next agent a corrupt tree**, and its restore trap cannot help —
this campaign's own rule that "a process that never exits has no exit" has a sibling, which is
that a process that is *killed* has no trap either. The failure was loud, which is the saving
grace; `verify_vendor_drift_clean` said in as many words that its controls would be meaningless
rather than reporting a smaller milestone.

### F2 — OQ-5's artifact evidence is CONFIRMED, independently

Re-derived with my own decoder (`inflateRaw` → JSON), not by re-running the milestone's check, and
not from the document:

| figure | document | mine |
|---|---|---|
| `public_dispatch` bytecode | 50,939 B | **50,939** |
| `brillig_locations["0"]` entries | 9,021 | **9,021** |
| key range | [706, 50,526] | **[706, 50,526]** |
| first 15 keys | 706,715,720,…,790 | **identical** |
| `file_map` | 86 files | **86** |
| `brillig_procedure_locs` max | 9,589 | **9,589** |
| `assert_messages` | dropped | **absent** |

And the two decisive shape facts, which are what actually carry the verdict:

- the highest key is **inside** the bytecode (50,526 < 50,939), as a byte offset must be;
- the keys are **not** dense `0..N` — `dense-0..N ? false` — so they are not a Brillig opcode index.

The trap is real: the type is still `BrilligOpcodeLocation` after the rewrite, and
`brillig_pcs_to_avm_pcs` is consumed rather than serialised, so both the type name and an artifact
grep point away from the truth.

**Verdict: OQ-5 is settled favourably, rung 1, no upstream change needed. The claim survives.**

### F3 — but §2.2's stride claim is FALSE AS STATED, and nothing re-derives it

`SOURCE-MAPPING.md` §2.2: *"The keys are sparse, increasing, in **strides of 4–9**, and bounded
above by the bytecode length."* Measured over all 9,020 strides:

```
stride histogram  4:3168  5:4980  6:43  7:30  8:246  9:113  10:4  11:85  12:64  13:35
                  14:15  16:18  17:8  18:113  21:9  22:12  23:4  26:4  27:10  30:5
                  32:1  35:1  36:1  37:40  39:1  40:1  58:1  62:1  64:1  74:1  88:1
                  96:1  143:1  203:1  410:1
min 4   max 410   in [4,9]: 8,580 of 9,020 = 95.1 %
```

The document's own **first 15 keys**, which it prints two lines above, contain a stride of **18**
(772 → 790). So the claim is contradicted by the evidence printed beside it.

The other five §2.2 figures are all re-derived by `verify_oq5_source_mapping_verdict_recorded`
(lines 124–128), row-anchored. **The stride range is the one figure in §2.2 that nothing
re-derives, and it is the one that is wrong** — the campaign's own "a figure nobody re-derives
rots" shape, in the document that shape's rule was written for. Fixed: see F-FIX-1.

### F4 — claim 2's FINDING reproduces exactly; claim 2's REMEDY does not exist

I was told the split probe "is fixed and now refuses what the reference reader refuses". **It is
not fixed, and it was never changed.** Run by me over the arms the tree already holds:

```
$ ct-split-probe oq4-bigint.ct
OPEN ok  …  VALUES0_COUNT 2  VALUES0_NAMES control,subject  VALUES0_BYTES 103  …  DONE ok
$ ct-print --full oq4-bigint.ct
Error reading events: failed to decode events: cbor: expected byte string (major 2), got major 3
```

So the defect is real and reproduces to the character. What the milestone actually did is
**pin the blindness as an asserted fact** and run both readers —
`test_fr_rendering_matches_noir_tracer:112` asserts *"ct-split-probe reports DONE ok over the SAME
refused container"*.

**On the merits that is defensible, and I checked rather than assumed it.** The probe's header
declares its contract: it exits 0 whatever the container says and reports per-stream failures as
`ERR:` values, so `DONE ok` means *the probe completed*, not *the container is good*. It genuinely
exercises the split streams — it pulls records, reports `VALUES0_BYTES`, `VALUE_LOADED` and a
per-stream zstd frame-pledge census. What it does not do is decode a value's CBOR payload.

The question that decides whether that is tolerable is whether anything rests on the probe alone.
**Nothing does**, verified at all three call sites:

- `test_trace_metadata_declares_mapping_rung` uses it only for `OPEN`, `COLUMN_AWARE`,
  `STEP0_GLI` and `PATH_COUNT` — all stream-level facts it really reads — and runs `ct-print`
  separately for container content;
- `test_ct_container_roundtrip_ct_print` (M24's) reads the same variable set through **both**
  readers and asserts them **equal** (`:369`), so `ct-print` covers the decode;
- `test_fr_rendering_matches_noir_tracer` uses it only to pin this defect.

**Verdict: the claim as briefed does not survive — the probe is unchanged. The engineering is
sound and the finding is honestly recorded, but "verified fixed" would have been false.**

### F6 — CLAIM 3: every number survives an independent re-derivation; the REASON does not

**The numbers.** I re-walked the closure with a scanner deliberately unlike
`verification/_import_closure.py`: comments blanked by a string-aware state machine (so a `//`
inside a literal cannot eat a line), then every module specifier found — `from '…'`, bare
`import '…'` and `import('…')` — over the blanked text, resolving out of the **object store** at
the `ts` anchor rather than the worktree.

```
FILES 65   LINES 10421   UNRESOLVED (0): []
```

Exact agreement, including the reduced sets by summation: 329 + 275 + 154 + 122 = **880** (4
files), + 162 = **1,042** (5 files). The escape structure is confirmed edge by edge: **5** escapes
from the tester (`public_db_sources`, `cpp_public_tx_simulator`, `cpp_vs_ts_public_tx_simulator`,
`public_tx_simulator_interface`, `test_executor_metrics`), **3** from `avm/fixtures/utils.ts`
(`common/index`, `avm_memory_types`, `errors`), **0** from `fixtures/utils.ts` (a genuine leaf,
zero relative imports), **0** from `simple_contract_data_source.ts` and **0** from
`base_avm_simulation_tester.ts` — total **8**, as asserted. The tester's `../avm/fixtures/utils.js`
import is the six-line multi-line clause at `:15-20`, which is exactly the shape the retired
`[^;\n]` walker could not see.

**The structural premise.** Confirmed to the line: `NativeWorldStateService` appears **exactly
twice** — `:12` the import, `:89` the first parameter of `static async create` — its only use is
`await worldStateService.fork()` at `:96`, and the constructor at `:71` takes
`merkleTree: MerkleTreeWriteOperations`. **The premise the eight deferrals rested on is false as
stated, and that finding stands.** The vendored copy is real too:
`diffsim/src/public/fixtures/public_tx_simulation_tester.ts`, provenance header carrying
`upstream-commit: 3a68d68ac2…` — the same anchor — added by `999ac63 spike: revive the deleted TS
AVM against published npm packages`.

**AND THEN THE SENTENCE THE WHOLE UNBLOCKING RESTS ON IS FALSE.** RI-72 said the constructor's
interface is one *"that this repository's `ResidentMerkleWriteOperations` (RI-67) already
implements"*. The tree says the opposite, in the file's own docstring:

> It is deliberately **NOT** declared `implements MerkleTreeWriteOperations`: the declaration would
> be a claim of totality, and M19's review found exactly that defect in a mirror that claimed to be
> total and intercepted two of four methods.

It is structurally compatible where it can be and *loudly incompatible where it cannot*, with
enumerated refusals that throw `ResidentMerkleDbCannotAnswer`. `block_assembly.ts:160` says the
same thing again in passing.

**And the assertion that was supposed to support it could not fail.** Line 112–113 of the check:

```bash
assert_ge "this runtime already has a MerkleTreeWriteOperations implementation" 1 \
  "$(grep -c 'ResidentMerkleWriteOperations' orchestration/src/resident_merkle_operations.ts)"
```

A grep for a class name **in the file that declares that class**. It returns 1, and cannot return
less. So the load-bearing sentence of the campaign's twelve-entry unblocking decision was held up
by an assertion incapable of failing, standing in for a semantic property, asserting something the
grepped file contradicts three lines from where the grep matched. That is three of this campaign's
catalogued shapes stacked in two lines.

**THE CONCLUSION SURVIVES ANYWAY, FOR A BETTER REASON, AND I MEASURED IT.** The calldata half never
touches the interface at all:

| measurement | value |
|---|---|
| `merkleTree.` — a method invoked on the parameter, anywhere in the builder | **0** |
| `merkleTree` — mentions of it (control for that zero) | 7 |
| `merkletree\|world-?state` in `fixtures/utils.ts`, the tx-building leaf | **0** |
| …the same needle in the builder (control for that zero) | 10 |

`merkleTree` is stored and forwarded to the simulator, and the simulator is one of the five edges
the reduction severs. **No merkle implementation — ours, upstream's or any other — is needed to
build a transaction.** That is a strictly stronger statement than the false one, and it is now what
the check and RI-72 say. See F-FIX-2.

### F7 — claims 4, 5, 6, 8 survive

**Claim 4 — the mutation matrix.** Spot-checked six arms, not four, reading *which* assertions
reddened rather than that the check failed:

- **M6** (the one that mattered): the mutation swapped 50,939 and 50,526 **between rows**, leaving
  both figures in the file. Caught, 2 failures, each naming its row —
  `public_dispatch bytecode 50,526 bytes` wanted 50,939, and `keys in [706, 50,939]` wanted
  `[706, 50,526]`. M24's review's exact defect, reproduced and defeated by row anchoring.
- **M7** (die-before-summary): `verify_oq5` **21 / 1**, `test_trace_metadata` **0 / 1**, each with
  a summary line at column 0 ending `1 failure(s)` plus an explicit *"exited (status 1) before
  finish"* note. Reads red, not smaller.
- **M8** (the hang): **status 124** — which is `timeout`'s own "the bound expired" code and is
  therefore proof of a hang rather than the `ps` snapshot the implementation agent relied on. The
  diagnostic names the 900 s bound and the full command. M24 declared three hangs and one hung;
  this one really hangs.
- **M10**: 65 → **47** files, 10,421 → **8,083** lines — the recorded undercount to the unit.
- **M3**: 61/3 and 83/15, `pathsInterned` falling to 0 and named as such.
- **M1**: 50/6, the full-hex decode failing in every arm.

The restore arm's red is real and is the `cp -p` mtime defect described; the `touch` of
`ct-writer/src/lib.rs` and `Cargo.toml` is present in `restore()` at line 47, and the module on
disk now measures 259,839 / `1e7e0e4f…`, so the tree I inherited is consistent.

**Claim 5 — the §7 offsets.** Confirmed: offsets `0,4,8,12,16,24,32+32`, so **60 used, 4
reserved**, and the old "8 reserved / 56 used" was wrong in both figures. Four compile-time
assertions now pin it rather than one:

```rust
const _: () = assert!(OFF_ADDRESS + ADDRESS_LEN == CT_RECORD_SIZE);   // pre-existing
const _: () = assert!(OFF_RESERVED + 4 == OFF_L2_GAS);                // new
const _: () = assert!(CT_RECORD_FIELD_BYTES == 4 + 4 + 4 + 8 + 8 + ADDRESS_LEN);  // new
const _: () = assert!(CT_RECORD_RESERVED_BYTES == 4);                 // new
```

**The step record did not grow**: `CT_RECORD_SIZE` is still 64 and the position channel is a
separate 16-byte record (`POS_OFF_* = 0,4,8,12`, `POS_OFF_RESERVED + 4 == CT_POSITION_SIZE`).

**Claim 6 — the M24 repoints.** Module **259,839 bytes / sha256
`1e7e0e4fcd3f4183fb954d946fe9f263c508353af2292494f84a3ad07f4192ab`**, matching §7 to the byte and
to the prefix — measured by me, on the artefact, before I started the sweep. Container
**4,694,016** confirmed in `arms.tsv`'s own `#META` lines for all three real arms and in §2's
table rows.

**The OQ-6 re-measurement was correctly triggered, not opportunistic**, and the mechanism is the
proof: `_m24_oq6_stamp` hashes the **module's content** plus `run_oq6_arms.mjs`, `writer.ts`,
`abi.ts`, `config.ts` and the four benchmark parameters. M25 changed the module and three of those
hosts, so the stamp necessarily changed and a re-measurement was forced by construction. It is a
content stamp, not an mtime — which is what makes it un-gameable in the direction that matters.

**Claim 8 — the two self-recorded procedure defects contaminated nothing.** `arms.tsv`'s own
`#CONFIG` line records `node=v24.19.0 v8=13.6.233.17-node.51` — this repository's dev shell, not
the system `v25.9.0`/V8 14.1 the wrong-shell run used. The wrong-shell `arms.tsv` was deleted and
re-measured rather than corrected, which is the only safe direction. And the comment-edit defect
is closed by the module's sha matching §7 and the OQ-6 stamp being a content hash of that same
module: a stale figure could not survive either check.

### F8 — TWO WRITERS: a mutation harness and a verification sweep are the same hazard

Three sweeps ran over one working copy today, and the damage did not come from the sweeps racing
each other directly. It came from what one of them was *doing to the tree when it died*:
`verify_provenance_complete` proves its detection works by **mutating a tracked file** and
restoring it on exit. A killed process has no trap, so `gas.hpp` was left zeroed and the next
sweep's M1 read 164/169 in 16 s (F1).

I then reproduced the same class of hazard against myself: my mutation tests of my own new
assertions rewrote `SOURCE-MAPPING.md` and `REUSE-INVENTORY.md` while the sweep was mid-run.
`REUSE-INVENTORY.md` is read by `verify_reuse_inventory_complete` in **M1** — had the sweep been
in M1 rather than M4 at that moment, it would have gone red for my mutation and I would have had a
plausible number rather than an obvious one.

**The standing brief has a gap here and it is the gap both of today's incidents went through.** It
says a sweep must not run while a script is being *edited*, and it says two agents must not sweep
concurrently. It does not say that **a mutation harness is a writer**, and that a sweep and any
tree-mutating harness — the milestone's own mutation matrix, a check's internal negative control,
or a reviewer testing their own assertions — must be serialised against each other. The failure
mode is worse than a red milestone: a mutation that lands *between two assertions of the same
check* produces a plausible number rather than a failure, and that is unrecoverable after the fact.

Resolution here: the racing sweep was **discarded, not summarised** (kept as
`~/.cache/m25rev/DISCARDED-race-with-gashpp-residue.log`), all mutations were restored and verified
byte-identical against backups, the tree was confirmed clean (`provenance.py headers --check`
exits 0, `git status` empty), everything was committed, and a single final sweep was started over
the committed tree with no further writes. Its M0 and M1 came back **156 and 169 — both exactly at
reference** — which is the evidence that F1 was collateral and not a regression.

**And m0/m2/m3 were checked rather than assumed** before discarding: 156, 292, 199, all at
reference. M1 was the only casualty.

### F9 — the sweep summariser could never print a total, for any run

`m25-sweep.sh` ends `printf 'SWEEPDONE\n'`. The summariser tested
`line.startswith("######## SWEEP DONE")` — prefix and space. The two never match, so `done` stayed
False forever, the "no 'SWEEP DONE' marker" hole was permanently open, and **no run however clean
could get a total printed**.

It fails safe, which is exactly why it survived a milestone: an instrument whose only output is a
refusal does not look broken, and the operator reads "there is a hole in this log" rather than "I
cannot see holes at all". A 100 % false-refusal rate is indistinguishable from a bad log. Fixed to
accept both spellings, still anchored at column 0; the refusal on a genuinely truncated log is
unchanged, verified against the discarded log, which still refuses on M4's open marker.

## The fixes, and their controls

| # | fix | assertions |
|---|---|---|
| F-FIX-1 | §2.2's stride claim re-derived; §2.3's 8-vs-9 explained | `verify_oq5…` 61 → 68 |
| F-FIX-2 | RI-72's false "already implements" retracted; the vacuous grep replaced | `verify_transaction_builder…` 42 → **53** |
| F-FIX-3 | the milestone section's stale `1f785f24…` sha, false stride claim, false implements claim | 0 (prose) |
| F-FIX-4 | the summariser's unreachable completion marker | 0 (instrument) |
| F-FIX-5 | the vacuous-assertion counter, and the fifth site still quoting a number | 0 (prose) |
| F-FIX-6 | §7's corrected 4/60 pinned in the host and in the document | `test_trace_metadata…` 83 → **92** |
| F-FIX-7 | OQ-5 asserts which `@aztec` pin its artifact came from | `verify_oq5…` 68 → **71** |

**M25 as delivered 236 → as reviewed 266** (71 / 50 / 92 / 53).

**Both fixes were mutation-tested against themselves**, because replacing an assertion that cannot
fail with more of the same would be the worst possible outcome here:

```
MUT-A  the doc's stride census moved by ONE (8,580 -> 8,581)
       verify_oq5_source_mapping_verdict_recorded: 68 assertion(s), 1 failure(s)
       FAIL §2.2's stride census is stated in the row that names it

MUT-B  RI-72's correction sentence deleted
       verify_transaction_builder_closure_measured: 53 assertion(s), 1 failure(s)
       FAIL …and that the reduced set needs no merkle implementation at all
```

Both restored and verified byte-identical against backups afterwards.

The ten replacement assertions in F-FIX-2 each carry a control, and the two that matter most are
paired zeros: `merkleTree.` is **0** in the builder with **7** mentions as the control, and
`merkletree|world-?state` is **0** in the tx-building leaf with **10** in the builder as the
control. A broken needle drives both members of each pair to zero and the control fails — which is
the property the assertion it replaced did not have.

I also checked the 236th assertion the coordinator flagged — the non-emptiness control beside the
`assert_eq "" ""` on the tsavm worktree. **It discriminates**: against the real worktree
`git ls-files 'yarn-project/simulator/src/public/*'` counts **131**, and against a directory that
is not a git repository at all — the case where `git status --porcelain` prints nothing and the
emptiness assertion passes vacuously — it counts **0** and the `assert_ge 100` fails.

### F10 — OQ-4's verdict, verified end to end on the container rather than on the source

Read out of `~/.cache/aztec-m25-trace/field.ct` by the pinned reference reader, by me:

```
"name": "contractAddress"                     (not M24's contractAddressLow)
  "kind": "String"
  "text": "0x2f1abcde…090a0b0c"               66 characters, 64 lowercase hex
type record: "kind": "tkInt",  "lang_type": "Field"    the Noir tracer's own type
ct-print exit 0
```

And the refusal that decided against the obvious choice reproduces exactly, with the split probe's
blindness beside it (F4). **OQ-4 survives in full.**

### F11 — the count reconciliation, and the "41" in the brief is the stale figure

The closure check is **42**, not 41: the extra assertion is the non-emptiness control beside the
`assert_eq "" ""` on the tsavm worktree, and I verified it discriminates (131 versus 0). The M10
mutation arm's output and the restore arm's both read 42, so 42 is the figure in every artefact.
**M25 as delivered is 236, not 235** — 61 / 50 / 83 / 42.

After this review's two fixes it is **254** — 68 / 50 / 83 / 53. Accounted in both directions:

```
verify_oq5_source_mapping_verdict_recorded   61 -> 68   +7  the stride census (6) + its doc row (1)
test_fr_rendering_matches_noir_tracer        50 -> 50    0
test_trace_metadata_declares_mapping_rung    83 -> 83    0
verify_transaction_builder_closure_measured  42 -> 53  +11  -1 vacuous, +10 replacements, +2 inventory
                                                       ---
                                            236 -> 254  +18
```

`verify-m25` invokes exactly those four and nothing else (`Justfile:2060-2078`).

### F12 — OQ-6 run 6 re-derived from `arms.tsv`, and the aggregation is the interesting part

I recomputed §2's table from the raw 72 rows. **My first pass disagreed with the document on every
median while matching every minimum exactly** — which is the signature of a different aggregation
rather than a different measurement:

```
arm            flat median   2-stage   document
batched            625,262   625,653   625,653
perEvent           631,348   631,290   631,290
control            622,152   621,202   621,202
nopBatched           4,746     4,758     4,758
nopPerEvent          5,046     5,070     5,070
```

A flat median over all 72 rows is the naive estimator. The document's is the **two-stage** one —
median of the six reps within a session, then median across the twelve sessions — which is what
this brief means by *"the session is the unit of replication"*. All five then match **exactly**.

The percentage deltas still did not match, and for the same reason one level up: they are **paired
within session**, not a ratio of the two aggregate medians. Computed per session and then averaged,
with a t-based 95 % interval over the twelve sessions:

```
perEvent    - batched     mean +0.98 %   95% CI [+0.29, +1.67]     document +0.98 %, [+0.29, +1.67]
control     - batched     mean -0.38 %   95% CI [-0.78, +0.02]     document -0.38 %
nopPerEvent - nopBatched  mean +4.56 %   95% CI [+0.49, +8.63]     document +4.56 %
```

**Every figure reproduces to the stated precision, including both bounds of the interval.** The
verdict holds: +0.98 % is inside the pre-declared 3 % margin, so `within-noise` stands and §4's
secondary criterion still decides. Worth stating precisely, because the interval excludes zero: the
per-event arm really is slower, and the claim is that it is slower by less than the margin — not
that the difference is undetectable.

**A ratio of medians is not a paired comparison, and only one of them is the measurement.** Had I
stopped at my first pass I would have reported three figures as wrong that are right.

### F13 — claim 5's fix was real but landed in ONE of the three places that state the figures

M25 fixed the Rust side properly: `CT_RECORD_FIELD_BYTES` and `CT_RECORD_RESERVED_BYTES` are
asserted against the `OFF_*` constants at compile time, so the code cannot drift. **The other two
places that state the same two numbers were left exactly as exposed as before.**

- `ct-host/src/abi.ts` carries `RECORD_FIELD_BYTES = 60` as a **typed literal**, sitting directly
  above the `OFF_*` constants it summarises. That is the shape that caused the original defect — a
  number typed beside a layout rather than derived from it.
- **§7's corrected prose is compared to nothing at all.** The sentence *"a figure nobody re-derives
  rots even when the assertion beside it is correct"* is now in §7, about §7, unchecked.

Closed: the arms run recomputes both figures from the host's own offsets, and nine assertions tie
the three statements together — the host's literals against its offsets, the values themselves (so
the identity cannot be satisfied by two equal wrong numbers, the M23 `0 == 0` shape), their sum
against the size the **module** reports, and §7's two figures matched in the line that states them.

**And that document row cost two catalogued mistakes to anchor, both on one paragraph.** §7 wraps
at 100 columns and the sentence spans the break: the line above ends `"…so the"` and carries the
**retired 56**. So a needle built from the sentence matches nothing — *"a needle that spanned a line
break"* — and a needle built from `fields need` alone selects the **wrong line** and would compare
60 against the very figure being retired. The row is selected by two non-numeric phrases that
co-occur on one line only.

Mutation-tested: §7 set back to 56/8 gives **92 assertions, 2 failures**.
`test_trace_metadata_declares_mapping_rung` 83 → **92**.

### F14 — OQ-4's Noir half verified in the Noir checkout, not from the document

| claim | verified |
|---|---|
| `tracer_glue.rs:152` renders `Field` as `ValueRecord::Int { i: field_value.to_i128() as i64 }` | yes, that line |
| `:371` types it `(TypeKind::Int, "Field")` | yes |
| `field_element.rs` `to_i128` panics `"field element too large for i128"` | yes, :253-256 |
| gated on `fits_in_i128()` = `num_bits <= 127` | yes, :143-146 |

A 254-bit address is far above 127 bits, so the Noir tracer would **abort the recorder**, and below
that `as i64` truncates. **"Match the Noir tracer exactly" really is unavailable, and that is the
finding rather than a caveat on it.**

### F15 — OQ-5 never asserted WHICH artifact it measured, across two non-interchangeable pins

`pins.json` declares two `@aztec` nightly lines and says in as many words that they are not
interchangeable:

| line | version | consumers |
|---|---|---|
| `deletion_era` | 5.0.0-nightly.20260626 | diffsim, spike, orchestration |
| `current` | 5.3.0-nightly.20260819 | drift |

`SOURCE-MAPPING.md` §2.2 says its measurements are *"at the `deletion_era` pin"*. But
`M25_ARTIFACT_ROOTS` is `"diffsim spike drift probe-mt orchestration"` — the search **crosses both
lines** and puts a `current` root **third**, ahead of `orchestration`, which is a `deletion_era`
one. And the copies really do differ: diffsim and spike are byte-identical to each other
(`f22f588d…`), drift is not (`b5e109b0…`).

**It failed safe, so this is an attribution fix rather than a hole — and the difference is exactly
what the three assertions buy.** Demonstrated by pointing the search at the drift root alone:

```
FAIL the shipped AvmTest public_dispatch bytecode is 50,939 bytes   got 51,532
FAIL its debug symbols map 9,021 program counters                   got 9,108
FAIL over an 86-file file_map                                       got 89
FAIL the highest mapped pc is 50,526                                got 51,076
FAIL …and the largest is 410                                        got 518
FAIL 8,580 of the gaps fall in the 4–9 band                         got 8,661
…twelve in all, plus every document row
```

Every one of those reads as *"the transpiler stopped preserving the mapping"* or *"the document's
figures have rotted"*. **Neither is true**, and this campaign has believed that kind of red before —
it is the same misattribution `m9_completeness` exists to prevent, one milestone over. The artifact's
own `aztec_version` is now compared against what `pins.json` declares, so the **first** failure names
the cause with both versions in it.

Incidentally reassuring: the drift artifact still resolves to **rung 1**, so OQ-5's verdict is not an
artifact of one nightly line.

`verify_oq5_source_mapping_verdict_recorded` 68 → **71**.

## Recommendation: should M25 have vendored the 880-line builder?

**No — but pricing it must be the last time it is deferred, and the reason to act is not the line
count.**

Not vendoring in M25 was right for a sequencing reason rather than a scope one:

1. **Vendoring alone does not deliver any of the four pending entries.** Each also needs the four
   collection flags at `shipped_module_config.ts:42`, and those flags move the delta comparison in
   **another milestone's** check (`e2e_form_a_external_tx_roundtrip` Part 8). Landing an 880-line
   vendoring and a cross-milestone flag change in the same session as two open-question
   settlements would have produced a change whose failures nobody could attribute — which is the
   attribution discipline this campaign spends most of its brief on.
2. **It is a deliverable, not a fix.** It wants its own mutation matrix and four new
   `PROVENANCE.md` rows, and `verify_provenance_complete` makes +2 assertions per vendored file, so
   it moves M1 as well.
3. The implementation agent's sweep had not run. Stacking it on an unverified milestone compounds.

But the decision itself is now unambiguous, and **more secure than RI-72 originally made it**:

- **880 < 1,580**, the `PublicProcessor` vendoring this campaign already judged obvious.
- **No new package dependency** — every `@aztec/*` specifier resolves inside the four
  `orchestration/package.json` already has.
- **A pinned copy of the largest file is already in the tree** at the same anchor, with a
  provenance header, so the pattern is established rather than invented.
- **All eight escaping edges are enumerated by name**, five severed by dropping the simulator half
  and three by dropping three functions.
- And the true justification — **the calldata half never calls a method on the merkle parameter at
  all** — is strictly stronger than the false one it replaces.

**The finding worth carrying is not the price. It is that this question has now been settled twice
on claims nobody checked, in opposite directions.** Eight deferrals rested on *"upstream's only
builder constructs a `NativeWorldStateService`"* — false; it receives one, in a static factory it
need not use. The unblocking then rested on *"`ResidentMerkleWriteOperations` already implements
`MerkleTreeWriteOperations`"* — also false, and contradicted by a docstring three lines from where
the supporting grep matched. Both were resolvable by **reading the file**, and neither was read for
eight milestones. A question deferred repeatedly on an unchecked claim and then unblocked on
another unchecked claim is a worse failure than either claim alone, because the second one is what
a future agent will cite.

### F5 — §2.3's "nine paths" is right, and reads like a contradiction of its own table

The table says `source paths interned | 8`; the prose below says the container reports *"nine
paths"*. Both are true — the container interns the session's own program path in addition to the
8 source paths, which my probe run confirms (`PATH_COUNT 9` for rung 1, `1` for the rung-3
control). The 8 is re-derived by the check; the 9 is not, and nothing explains the difference.
Fixed as prose: see F-FIX-1.

---

## The sweep — M0–M25, 26 of 26, zero failing assertions

`~/.cache/m25rev/final-sweep.log`, started `2026-08-27T03:24:44+03:00` over the **committed** tree,
`setsid`-detached, one milestone at a time, nothing else running, in this repository's own dev
shell (node v24.19.0). No hole in the log.

```
m0  156  m1  169  m2  292  m3  199  m4  218  m5  236  m6  363  m7  287  m8  516  m9  807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283  m19 180
m20 237  m21 324  m22 260  m23 509  m24 350  m25 266        CAMPAIGN TOTAL 9,027
```

**Every unit is accounted for in both directions. M25's review moved exactly one milestone and it
is M25's own.** Every one of M0–M24 came out at its reference value **to the assertion**, so
8,761 + 266 = 9,027 exactly. Specifically:

- **M9 = 807 in 1,313 s, split 140/143/113/73/126/83/129, no flake.** The recorded flake did not
  appear and no re-run alone was needed.
- **M11 = 259** — upstream has not moved a sixth time.
- **M4 = 218** measured in the dev shell, so M19's review's PATH pin still holds.
- **M18 = 283** — `verify_named_checks_exist` stayed at 9, confirming that neither M25's four new
  checks nor this review's prose introduced a dangling check name. I pre-verified that with the
  check's own regex over all sixteen files I changed inside its scanned roots: zero unresolved.
- **M24 = 350**, split 58/86/48/37/30/91. Two things worth naming: `verify_trace_event_abi_batched_faster`
  is at **91**, so the OQ-6 content stamp matched and **no benchmark re-ran** — my edits touched
  `run_trace_arms.mjs`, not `run_oq6_arms.mjs` or the three hosts the stamp hashes; and
  `test_ct_container_roundtrip_ct_print` is at **86**, so the `contractAddressLow` →
  `contractAddress` repoint really did move no assertion count, exactly as claimed.
- **M19 = 180** — my comment-only edit to `e2e_differential_wasm_vs_native_cpp.sh` moved nothing.
- **M1 = 169**, the F1 collateral fully repaired, and unaffected by this review's edits to
  `CAMPAIGN-BRIEF.md` and `REUSE-INVENTORY.md`.

M25 itself: **71 / 50 / 92 / 53 = 266**, declared at 236.

**And the total printed at all, which is the F9 fix working end to end.** Before it, this
summariser refused every log it was ever given.

## What did not survive

1. **"The split probe is fixed and now refuses what the reference reader refuses."** It is
   unchanged. The defect is pinned as an asserted fact instead — defensible, and nothing rests on
   the probe alone, but "verified fixed" would have been false. (F4)
2. **`ResidentMerkleWriteOperations` "already implements" `MerkleTreeWriteOperations`.** It is
   deliberately declared not to, and the check propping the claim up could not fail. The conclusion
   survives on a stronger fact nobody had measured. (F6)
3. **§2.2's "strides of 4–9".** Contradicted by the fifteen keys printed two lines above it. (F3)
4. **The milestone section's module sha `1f785f24…`.** Stale by one comment edit; the module is
   `1e7e0e4f…`. §7 was right because a check re-derives it; the milestone file is re-derived by
   nothing. (F-FIX-3)
5. **"235 assertions."** It is 236 — the closure check is 42, not 41. (F11)
6. **§7's layout fix being complete.** It landed in Rust only; the host kept a typed literal and
   the document kept unchecked prose. (F13)
7. **The counter remedy being complete.** Four of five sites point at the brief; the fifth still
   quoted a number, one behind. (F-FIX-5)
8. **The sweep summariser.** Could never print a total for any run. (F9)

Everything else survived, including both headline verdicts, the closure numbers to the unit, the
mutation matrix, the §7 offsets, the module size and sha, the container growth, the OQ-6
re-measurement and its trigger, and both self-recorded procedure defects being harmless.
