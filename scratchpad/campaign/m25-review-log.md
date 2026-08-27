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

The authoritative sweep is **`~/.cache/m25rev/sweep.log`**, started `2026-08-27T03:05:43+03:00`,
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

### F5 — §2.3's "nine paths" is right, and reads like a contradiction of its own table

The table says `source paths interned | 8`; the prose below says the container reports *"nine
paths"*. Both are true — the container interns the session's own program path in addition to the
8 source paths, which my probe run confirms (`PATH_COUNT 9` for rung 1, `1` for the rung-3
control). The 8 is re-derived by the check; the 9 is not, and nothing explains the difference.
Fixed as prose: see F-FIX-1.
