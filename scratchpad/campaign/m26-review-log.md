# M26 review log — Joining Private and Public Traces

Adversarial review. Phases are SERIALISED: read → mutate-one-at-a-time → restore → verify restored →
sweep. Never a mutation harness and a sweep at once.

## Phase 0 — reading (in progress)

Read: `CAMPAIGN-BRIEF.md` in full, `JOIN-SHAPE.md`, the M26 section of the milestones file,
`scratchpad/campaign/m26-impl-log.md`. **`scratchpad/campaign/m26-brief.md` DOES NOT EXIST** — the
impl log's Step 0 says it was read; the file is not in the tree and not in git. Noted, not fatal.

### Finding R1 (defect, in the artefact the whole review is about) — a doc comment was STOLEN

`noir/tooling/tracer/tests/test_tracer.rs`: `field_small_int`'s doc comment was inserted directly
after the existing doc comment for `test_a_1_mul_via_ct_print_full` and BEFORE that test, so the
`a_1_mul` paragraph ("Pins: 1 call (main), 7 step events … x mutates through 3 → 12 → 144 → 20736
→ 429981696") is now the first three lines of `field_small_int`'s doc, and
`test_a_1_mul_via_ct_print_full` has no doc comment at all. Two unrelated docs concatenated into
one. Confirmed by reading lines 258-300 of the working copy.

### Fixture types check out

- `test_programs/trace/assert/src/main.nr` is `fn main(x: Field, y: pub Field)` with `a`/`b`
  derived from `x`/`y`, so all four vars the test maps through `field_small_int` really are Field.
- `test_programs/trace/types_test/src/main.nr` is
  `main(a: Field, b: u32, c: Point{x,y:Field}, d: Field, e: i8, f: bool, g: str<11>, h: [Field;2])`
  — the split the diff asserts (a, c.x, c.y, d, h[0], h[1] String; b, e Int) matches the source.
- The two remaining `["value"]["i"].as_i64()` sites (lines 361, 549) are in `a_1_mul` (all `u32`)
  and `if_then_else_reduced` (all `u32`), so they are correctly left alone.

## Phase 1 — THE HEADLINE CLAIM: the unexecuted Noir test expectations

The declared claim: *"They were not executed: `noir_tracer` on `blocktracer` links the Nim FFI
writer, whose static library this environment does not build, and the `_via_ct_print_full` tests
spawn a built `nargo`."*

### R2 — "this environment does not build it" is REFUTED. It is a missing step, one env var wide.

`codetracer_trace_writer_nim/build.rs:92` shells out to `nimble`, and `nimble` is not on this
host's PATH (`nim` is: `…-nim-wrapper-2.2.4/bin/nim`). The failure is

```
thread 'main' panicked at codetracer_trace_writer_nim/build.rs:92:14:
failed to run `nimble` -- it ships with the Nim toolchain and must be on PATH alongside `nim`
```

**That same `build.rs`'s own doc comment names the escape**, and it works:

```
$ CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1 cargo build -p codetracer_trace_writer_nim
    Finished `dev` profile … in 5.66s        (rc 0)
```

And the whole chain builds from there:
```
$ CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1 cargo build -p nargo_cli --bin nargo   → rc 0, 1m32s
$ CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1 cargo test -p noir_tracer --test test_tracer --no-run → rc 0, 48s
```
`ct-print` is already present at the sibling path the test's own locator uses
(`codetracer-trace-format-nim/ct-print`, 1,078,048 bytes). So **nothing environmental prevented
these tests from being run.**

### R3 — they RUN, and SIX OF THEM ARE ALREADY RED AT `HEAD`, before M26 touched anything

With M26's two edits in place: `0 passed; 6 failed`. Backed the two files up, `git checkout --`
them, re-ran, restored and verified by sha256 — **the baseline at `6db58caad` fails the SAME six
tests at the SAME six assertions with the SAME left/right values**:

| test | assertion | got | expected |
|---|---|---|---|
| `test_a_1_mul_via_ct_print_full` | `values` | 10 | 19 |
| `test_a_2_function_calls_via_ct_print_full` | `types` | 3 | 4 |
| `test_assert_via_ct_print_full` | `types` | 2 | 3 |
| `test_if_then_else_reduced_via_ct_print_full` | `values` | 78 | 155 |
| `test_multi_stmt_per_line_column_aware` | columns | `[9,27,45]` | `[1,9,1,27,1,45]` |
| `test_types_test_via_ct_print_full` | `types` | 10 | 11 |

None of the six is M26's, and M26 moves none of them. They are stale expectations left by the
column-aware merge that is `HEAD`. **But every one of them fires EARLIER in its test than the
`field_small_int` assertions do**, so the updated expectations are not merely unexecuted — they are
*unreachable* until somebody fixes six unrelated pins. That is strictly worse than the impl log
says, and it is the exact hazard the review brief names: the next person runs them, sees six
failures, and none of the diagnostics points at OQ-4's rendering.

### R4 — the updated expectations are nevertheless CORRECT, established by a route that executes

`nargo trace` was run for real on both fixtures and decoded by the real pinned `ct-print`, and the
helper's own predicates (variant, `0x` prefix, 66 characters, lowercase hex, top 48 digits zero,
low 64 bits decoded) applied to the actual values:

```
assert.nr      a 0x…000c → 12   b 0x…000c → 12   x 0x…000a → 10   y 0x…000a → 10     (all String/66)
types_test.nr  a 0x…0001 → 1    c.x 0x…0009 → 9  c.y 0x…000a → 10  d 0x…0003 → 3
               h[0] 0x…0007 → 7  h[1] 0x…0008 → 8                                     (all String/66)
               b {"kind":"Int","i":2}   e {"kind":"Int","i":4}      ← the two NON-Field arms
```

Every updated expectation matches, and the deliberate Int/String split is exactly as the diff
asserts. **Correctness is ESTABLISHED, not merely asserted.** Recommendation: KEEP the
expectations; do not revert them.

### R5 — it is NOT recorded where the next person will hit it

`grep -i 'not run|not execut|unexecuted|nim|does not build'` over `test_tracer.rs` finds nothing
about any of this. The fact lives only in `m26-impl-log.md` and in the milestone file in
`codetracer-specs` — two documents in two other repositories. Fixed below.

### R6 — WHY the six are red, established from the writer's own commit rather than guessed

`noir/Cargo.toml:144` resolves `codetracer_trace_writer` to `codetracer_trace_writer_nim` in the
sibling `codetracer-trace-format` checkout **by bare path, at no pinned revision**. That checkout
has moved 45 commits since `test_tracer.rs` was last touched (2026-06-18), 21 of them in
`codetracer_trace_writer_nim`. The decisive one is `ad76dc1`…`ad17f22`'s rewrite of
`register_step_with_column`, whose own doc comment records the behaviour change verbatim:

> *"Current split-stream traces therefore carry **one absolute step at the requested `(line, column)`**
> instead of **an intermediate column-1 step plus a separate delta step**."*

That is exactly `[1, 9, 1, 27, 1, 45]` → `[9, 27, 45]`, and it is exactly `values` `2n−1` → `n`
(a_1_mul 19→10, if_then_else 155→78, both `2·steps−1` → `steps`). **So half the staleness is
explained by a deliberate writer change that `noir` never re-ran against.**

Both writer checkouts are at PUBLISHED commits (`codetracer-trace-format` `4bf7ea2` is the tip of
`origin/blocktracer`; `codetracer-trace-format-nim` `7296a09` is contained in `origin/dev`), so a
repin would not be pinning a local file.

**But the other half is NOT explained, and I decline to pin a number I cannot certify.** Three
fixtures lose exactly one type-table entry and renumber the synthetics behind it:

```
assert       expected [None, Field, type_1]                     actual [None, Field]
types_test   expected [None, Field, type_1, u32, type_3, Point, i8, type_6, Bool, String, Array<2, ..>]
             actual   [None, Field,         u32, type_2, Point, i8, type_5, Bool, String, Array<2, ..>]
a_1_mul      expected [None, u32, type_1]                       actual the same — PASSES
```

A synthetic type that used to be registered no longer is, and `a_1_mul`'s survives while the other
three vanish. Nothing in the writer's commit messages accounts for that, and "one fewer type" is as
consistent with a lost type registration as with a removed duplicate. **Rewriting those arrays from
today's output would be writing an expectation from an output I cannot certify — the campaign's own
"a constant you have just typed into a check looks like a measurement", in the most literal form.**

**Resolution: record, do not repin.** The diagnosis, the reproduction commands and the two halves
(one explained, one not) go into `test_tracer.rs`'s own header, where the next person hits them.
Re-pinning the six is owed work that belongs to whoever owns the Noir tracer's fixture parity, not
to an M26 review commit.

## Phase 2 — baseline and mutation spot-checks (serialised, nothing else running)

`just verify-m26` in this repository's own dev shell, `setsid`-detached, `TMPDIR` under `~/.cache`:
**117 / 65 / 36 / 75 = 293, 0 failures, exit 0.** The declared split reproduces exactly.

Then five of the nine arms, one at a time, each restored and verified by sha256 (`mut1.log`):

| arm | declared | measured | which assertions went red |
|---|---|---|---|
| B (severed edge returns) | 117/2 | **117/2** | the dropped count 27 vs 28, and "…and is GONE from the vendored copies" |
| D (join becomes inferred) | 75/1 | **75/1** | the named ground, `expected [unrecorded], got [other:TypeError]` |
| F (enqueue order reversed) | 36/2 | **36/2** | the order identity AND its reversed-order control |
| H (**HANG**) | 36/27 | **36/27** | `ERR:_ct_frames-timed-out-after-10s` plus every frame assertion reading `MISSING` |
| I (**DIE BEFORE SUMMARY**) | 0/1 | **0/1** | the trap's `FAIL — exited (status 1) before finish`, and the `die` naming the unreadable JSON |

**All three self-reported harness defects hold fixed.** Arm H reads **36**, not 29 — the
`$(( MISSING - 1 ))` guard is real and the count does not shrink under the hang. Arm I genuinely
dies rather than re-running: the future-stamped non-JSON report makes `m26_require_arms` refuse,
and the trap turns a 0-assertion silent shrink into a counted failure. Arm D does redden as
`other:TypeError` rather than as an inferred join, exactly as the impl log records against itself —
what it demonstrates is that the refusal is load-bearing, not that a best-effort join is caught.

**And the two pre-landing fixes are in the shipped checks, verified by reading them:**
`verify_oq7_shared_writer_verdict_recorded.sh:181-196` compares the worktree HEAD's refcount (0)
against `refs/remotes/origin/master` **in the same repository** (measured: 10 refs contain it), with
`assert_false test "$PUBLISHED_CONTROL" = "$WEB_HEAD"` between them. No value is compared with
itself anywhere in the four checks.

## Phase 3 — what did not survive, and the fixes

### R7 — the vendoring pin had TWO measured holes; both are closed

`_vendor_lines.py` classified by MEMBERSHIP (`set`), so `check-drift` is not the backstop *and
neither was the named check*. Measured on scratch copies of `simple_contract_data_source.ts`,
before any fix:

- one retained line **repeated twenty times**: `VENDORED_LINES 125 / RETAINED 124 / ADDED 1 /
  DROPPED 1`, no `UNDECLARED` — **every assertion in the loop passed**, because `VENDORED_LINES`
  was computed and printed on every run and compared with nothing;
- two adjacent retained lines **swapped**: counts **byte-identical** to the uncorrupted file, empty
  residue — **everything passed**. Moving a statement from one method to another was invisible.

Closed: `_vendor_lines.py` now also computes the ORDER (a greedy in-order walk of the retained
lines through the upstream original, exact for subsequence matching) and prints `ORDERED` plus the
first line it could not place. The check pins `VENDORED_LINES` per file (123 / 246 / 98 / 106) and
`ORDERED == 1` per file, and carries **both corruptions as live controls**, each asserting that the
counts the old check relied on do NOT move.

### R8 — the merkle tripwire had no control, and its observation count is tautological

RI-72's load-bearing sentence rests on `merkleTouches` being empty. But **every trap throws**, so an
observation aborts the driver and no report is written at all — which means `merkleTouches` is empty
in *every report a check can read*, **including one produced with the tripwire wired to nothing**.
The only control offered was "a transaction was produced", which proves the builder ran, not that
the proxy is the object it holds. Closed: the driver reads `tester.merkleTree` back off the builder
after the build — the field the vendored constructor assigns — touches it, and reports that it threw
the tripwire's own message and that the observation list moved to 1. The build's own zero is now
snapshotted before the control, so the two facts stay independent.

(Traps implemented are `get`, `has`, `ownKeys`. `set`, `delete`, `defineProperty`,
`getOwnPropertyDescriptor` and `getPrototypeOf` pass silently — measured. They are off the claim's
axis: `merkleTree.x()` needs a `[[Get]]` and `Object.keys` hits `ownKeys` first, so RI-72's
`grep -c 'merkleTree\.' == 0` is genuinely covered. Recorded, not fixed.)

### R9 — `join_e2e_driver.ts` was NOT a declared input of the arm report's staleness test

`m26_require_arms` lists seven inputs and the driver that BUILDS the transaction half of the report
is not among them. Any field the driver starts emitting is read as `MISSING` from a report nothing
re-ran. Found by adding a field and watching it not appear. Added.

### R10 — the M24 floor that guards the native tests had stopped tracking the suite

`verify_ct_writer_wasm_zero_imports` asserts `NATIVE_PASSED >= 5` under a comment saying the crate
carries five `#[test]`s. It carries **fourteen**. Nine tests — M26's two among them — could have
been deleted with the check still green, which is the *weaker* form of the exact defect that check
was written to close. Raised to 14; the count of assertions does not move.

### R11 — `JOIN_EXPORTS`' own docstring says "M26 its two" over a list of six

The list began at two (`ct_log_event` + its counter) and grew to six when the fallback turned out
to need frames; the sentence beside it did not follow. Prose drifting from the measurement it sits
one line above. Fixed.

### R12 — `trace_join.ts` imports nothing, and NOTHING asserted it

`JOIN-SHAPE.md` §7 makes that property a consequence for M27 and M28. It is true (0 imports,
measured) and was unguarded. Asserted now, with `join_e2e_driver.ts`'s 8 imports as the control that
the needle can match something, and with the document's own sentence.

### R13 — the vacuous-assertion census is STILL an undercount, in one of the five declared places

The milestone claims the counter moved "25 → 27 in all five declared places".
`diffsim/src/public/public_tx_simulator/differential/fault_injection.ts:14` still reads *"this
campaign has shipped **twenty-four** assertions that could not fail"* — the number M25's review
retired from its sibling `e2e_differential_wasm_vs_native_cpp.sh:19` while leaving this one. Found
by grepping the spellings rather than trusting the paragraph, which is what the brief's own remedy
asks for and is the second time in three milestones that exact census has come up short. Converted
to name the family and point at `CAMPAIGN-BRIEF.md`, so the number now lives in ONE place.

### R14 — the "FOUR functions" trim count is six functions carrying four edges

`PROVENANCE.md`'s `tx-builder-calldata-half` and `REUSE-INVENTORY.md` RI-72 both say the trim drops
"FOUR functions" and then enumerate six declarations in three groups. Four is the number of escaping
EDGES. Two different quantities reported as one number, in two documents. Both reworded.

### Recorded, not fixed

- `test_join_fallback_two_recordings`'s "the module declares no constant for the join key" slices
  `sed -n '1,/^mod tests {$/p'`, so anything AFTER the tests module is invisible to the needle. A
  non-test `pub const` written at the bottom of `lib.rs` would be reported absent. Sound as measured
  (nothing follows the block today), not sound by construction. The other direction fails red.
- `parseJoinRecord` requires `reason` to be present but never checks it equals `JOIN_REASON`, while
  the field's docstring says "Always `JOIN_REASON`". The shell check asserts the literal separately.
- `ct_log_event`, `ct_call` and `ct_return` are called only from `tools/run_join_arms.mjs`. That is
  not a finding about M26: **no shipped runtime path in this repository calls anything in
  `ct-host`** — every ABI export, M24's nineteen included, is driven solely by the four
  `tools/run_*_arms.mjs` drivers. Parity, not a gap.

## Phase 4 — the two `pending` entries: honest blockers, one imprecise reason

**`e2e_form_b_single_ct_recording` — HONEST, and M21's chain re-derived at the anchor rather than
carried:** `git show 3a68d68ac2:yarn-project/pxe/package.json` lists `@aztec/simulator` in
`dependencies`, and `yarn-project/simulator/package.json` lists **`@aztec/native` and
`@aztec/world-state`**, both hard `dependencies`. None of the four is installed anywhere in this
repository's `node_modules`. So the private half cannot execute here, and the entry is pending on a
measured fact rather than on effort. Not a scope narrowing.

**`e2e_joined_trace_opens_in_codetracer` — honest, but the REASON as written was wrong.** The impl
log says *"CodeTracer itself is not in this tree to open anything"*. The `codetracer` repository IS
a sibling checkout in this workspace (`workspace-projects.md` lists it first). What is true — and is
what I measured — is that **there is no built `ct` binary anywhere in it**: the source tree is there,
`src/ct/` is Nim source, and `find -type f -perm -u+x -name ct` returns nothing. The blocker is a
debugger nobody has stood up, which is a different sentence from a debugger nobody has, and the
milestone entry says the measured one now. The entry stays `pending`, correctly: a deliverable that
names a product must be closed by that product opening the file.

## Phase 5 — the review's own mutations: every added assertion has one

`scratchpad/campaign/m26-review-mutations.sh`, three arms, one at a time, each restored and verified
by sha256 (`revmut.log`). Each arm is only satisfied if the NAMED assertion goes red.

| arm | mutation | result | which assertions went red |
|---|---|---|---|
| J | a retained line of a vendored file **repeated** | 133/**4** | the pinned content-line count (106 vs 109), `ORDERED`, and both of the duplication control's own legs |
| K | two adjacent retained lines **swapped** | 133/**3** | `ORDERED` only — **every count came back unmoved**, which is the demonstration that nothing else in the check can see a reordering |
| L | the builder handed a plain `{}` instead of the tripwire | 133/**3** | all three new tripwire assertions, on `NOT-THROWN` and on the observation count 0 vs 1 |

**Arm L is the one that matters most**, and its shape is the point: the ORIGINAL assertion —
`len(merkleTouches) == 0`, the one RI-72's whole entry rests on — **stayed GREEN** under it. A
tripwire wired to nothing produces exactly the same zero as a tripwire that works.

(In arm K the check's own reorder control also reddens, because that control is built FROM the file
under test and swapping an already-swapped pair restores upstream's order. It fails loudly rather
than hiding, which is the safe direction, and it is worth knowing when reading arm K's output.)

## Phase 6 — the numbers

`just verify-m26` after the fixes: **133 / 65 / 36 / 79 = 313, 0 failures, exit 0.**
Declared 293; the twenty are +16 in `verify_tx_builder_vendored_not_reimplemented` (8 in the
per-file loop, 5 in the two new controls, 3 on the tripwire) and +4 in
`test_join_fallback_two_recordings`. Exact in both parts.

### R15 — the sweep summariser's own reference table is stale

`scratchpad/campaign/m26-sweep-sum.py:36` declares `"m26": 279`. M26 was declared at **293**. 279 is
`117 + 65 + 36 + 61` — the count BEFORE step 10 grew `test_join_fallback_two_recordings` from 61 to
75. So the impl agent's own sweep must have printed `m26 293 <-- MOVED, reference 279 (+14)` and the
impl log records 293 with no mention of the flag. The instrument disagreed with the result and
nobody reconciled them. (Its usage line also still says `m25-sweep-sum.py`.)

## Phase 7 — OQ-7's demonstration, read out of the container rather than out of the document

Decoded the artefacts with the pinned reader and `_ct_frames.py` directly:

```
oq7-shared.ct        EVENTS 146  STEPS 32  CALLS 8  RETURNS 6  UNBALANCED 2
  FRAME 0 depth 0 <toplevel>                31 steps
  FRAME 1 depth 1 main                      31 steps
  FRAME 2 depth 2 foo    6      FRAME 3 depth 3 bar    3
  FRAME 4 depth 2 foo    6      FRAME 5 depth 3 bar    3
  EVENT ct.trace-join  join=aztec-tx-01949fcc7d927e9c-join half=both halves=1 arm=shared reason=…
  FRAME 6 depth 2 Token.transfer_in_public   6 steps, 1 call argument
  FRAME 7 depth 2 Token.balance_of_public    6 steps, 1 call argument

oq7-split.public.ct  EVENTS 93  STEPS 12  CALLS 3  RETURNS 2  UNBALANCED 1
  FRAME 0 depth 0 <toplevel>  12   FRAME 1 depth 1 Token.transfer_in_public 6
                                   FRAME 2 depth 1 Token.balance_of_public  6
  EVENT ct.trace-join   … half=public halves=2 arm=split …
  EVENT ct.mapping-rung 0x3051e7a9… rung=1 …
```

Every figure in `JOIN-SHAPE.md` §3 reproduces: 146 events, 32 steps, 8 calls, 6 returns, the two
public frames at **depth 2 inside `main`** in enqueue order, `<toplevel>` and `main` still open
(`UNBALANCED 2`) when they open. The frames are computed from the Call/Return sequence, so they are
real rather than a listing order. And `32 = 20 + 12` — the shared container's steps are the sum of
the two split containers', which is the identity that replaced the value compared with itself.

**Fact 2 verified independently too**: the two single-process instances report 6 and 4 module
events, and the containers differ (`sha256` `4ff95eea…` vs `ae449447…`). Had either seen the
other's, both would read 10.

**Fact 6 verified**: `noir/Cargo.toml:144` is
`codetracer_trace_writer = { path = "../codetracer-trace-format/codetracer_trace_writer_nim", package = "codetracer_trace_writer_nim" }`.
**Fact 7 verified**: `git -C noir-wt4-webpage for-each-ref refs/remotes --contains f0e7edcd2` is
**empty**, while the same predicate over `refs/remotes/origin/master` in the same repository answers
**10**. The control is sound and the two commits are asserted different.

## Phase 8 — the vendoring claims, item by item

| claim | verdict |
|---|---|
| 880 lines to the line | **VERIFIED exactly.** 329 / 275 / 154 / 122 out of the object store at `3a68d68ac2`, all four blobs newline-terminated so `wc -l` and content lines agree, and the check re-derives it every run |
| `PROVENANCE.md` F20–F23 + F24 | **VERIFIED.** Five rows, right paths, right anchor, RI-72 cited, class `tx-builder-calldata-half`, all five tracked |
| `check-drift` covers all five rows | **TOUCHES all five; one of the five is a TAUTOLOGY.** `tools/provenance.py:543-566` loops with no filter and prints `OK differs` ×4 and `OK missing-upstream` ×1. But F20–F23 get only a DIRECTION assertion — the repo's own documented limitation — and **F24's `missing-upstream` is returned by construction**: `git show <anchor>:"(none — added in this repo)"` cannot resolve, so it would pass over an empty `gas_compat.ts` or over ten thousand lines of anything. F24's real content pin is Part 4 of the named check, not `check-drift` |
| five numbered edits | **VERIFIED**, and the fifth's count was wrong: "FOUR functions" against six declarations carrying four escaping edges, in two documents. Fixed |
| `lodash.merge` escapes RI-72's `@aztec/*` scope | **VERIFIED, and it is out of scope for every rule the repo enforces.** Upstream imports it at the anchor; the vendored copy does not; it is absent from `orchestration/package.json`, from `package-lock.json` and from `node_modules`. **DD-9 says nothing about npm dependencies** — its text is one sentence about never exposing the upstream `PublicProcessor` constructor — and `verify_differential_containment` forbids only `optionalDependencies`, `@aztec/native` and `@aztec/bb.js`. Keeping `allSameExcept` would have been a **load failure**, not a rule violation. The trim is a correctness fix and RI-72's correction is honest |
| F24 exists because the nightly does not export `FALLBACK_TEARDOWN_{DA,L2}_GAS_LIMIT` | **VERIFIED BY MEASUREMENT.** `@aztec/stdlib/gas` exports 30 keys, none matching `FALLBACK`; it DOES export `GAS_ESTIMATION_TEARDOWN_{DA,L2}_GAS_LIMIT`, so the check's narrow `/FALLBACK_TEARDOWN/` filter is load-bearing and a looser `TEARDOWN` needle would have gone red for the wrong reason. Both names present at the anchor (`gas_settings.ts:14,16`). `gas_compat.ts` recomputes from `@aztec/constants` — L2 817500, DA 98304, no literals — and both halves are asserted |
| RI-72's load-bearing claim is EXECUTED, not grepped | **VERIFIED that it is executed. REFUTED that it was controlled** — see R8. The `Proxy` traps `get`, `has` and `ownKeys` and throws on each, which covers the claim's axis (`merkleTree.x()` needs a `[[Get]]`; `Object.keys` hits `ownKeys` first). `set`, `delete`, `defineProperty`, `getOwnPropertyDescriptor` and `getPrototypeOf` pass silently — measured, off-axis, recorded. The list can never be non-empty in a readable report, so the assertion on it was a tautology with nothing behind it until this review added the arming control |

## Phase 9 — publication, and one instruction that collides with the milestone's own verdict

`pins.json`'s five anchors all resolve to **published** commits: `cpp`, `ts` and
`historical-protocol-specs` upstream, `trace_format` `592fa42cbf` (1 remote ref) and
`trace_format_nim` `baea074019` (1 remote ref in each of the two checkouts). M24's review's rule
holds.

**`noir-wt4-webpage` IS DELIBERATELY LEFT UNCOMMITTED, and this is a decision rather than an
oversight.** It is a git worktree of `noir` sitting on `wasm/webpage`, carrying one uncommitted
edit to `tracer_glue.rs`. Committing it locally would produce an unpushed commit, which this
campaign's own rule calls a local file. **Pushing it would publish `wasm/webpage` — which is
precisely fact 7 of OQ-7's verdict, the fact the whole "not shippable" conclusion rests on, and
`JOIN-SHAPE.md` §6 names publishing that branch as one of the two things that would REOPEN OQ-7.**
`verify_oq7_shared_writer_verdict_recorded` asserts its refcount is 0 and would go red the moment
it were pushed. A review agent does not reopen a settled question as a side effect of tidying a
working tree. The probe's build script tolerates exactly this one edit by design
(`build_oq7_shared_writer_probe.sh:72`, `ALLOWED_EDIT`), and the file's content is asserted
identical to `noir`'s in both checkouts, so nothing about the demonstration depends on the commit.

The other three repositories are committed: `noir` (`eb8b28c27`), `aztec-avm-runtime` (`5c6d37c`),
`codetracer-specs` (`50bfbf19`). Nothing in any of them pins a commit of any other, so no ordering
can leave a pin naming an unpublished commit; they are pushed after the sweep, not before it.

## Phase 10 — THE SWEEP, and one milestone the review's own edit reddened

Run `setsid`-detached from this repository's own dev shell, one milestone at a time, `TMPDIR` and
the log under `~/.cache`, **after** the three commits. No hole in the log; the summariser printed a
total, which it refuses to do while one is open.

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 324  m22 260  m23 509  m24 350  m25 272  m26 313
                                                        CAMPAIGN TOTAL 9,352
```

**Every milestone at its reference value TO THE ASSERTION, delta +0**, 9,039 (m0–m25) + 313 = 9,352.
M26's own move is the only one: 293 → 313, +16 and +4 in two checks, itemised in Phase 6.

**M9 DID NOT FLAKE — 807, 7/7, exit 0 in 1,341 s, IN the sweep**, immediately after M8's build.

### R16 — M24 went red in the sweep, at an unchanged count, because of a COMMENT this review fixed

`m24 rc=1, 15 failing assertions, 350 assertions` — the count did not move, which is the shape that
distinguishes "a check grew" from "a check saw something". `_m24_oq6_stamp` hashes the module plus
`ct-host/src/{writer,abi,config}.ts` and `tools/run_oq6_arms.mjs` **by file content**. R11's
one-sentence docstring correction in `abi.ts` invalidated it, the twelve-session OQ-6 benchmark
re-ran inside the sweep, and `TRACE-ABI.md` §2 was left quoting run 9 against an `arms.tsv` holding
run 10.

**Reverting does not undo it**: the stamp on disk now names the post-edit inputs, so a revert is
another mismatch and another benchmark. The document is rendered from the new data instead —
**run 10: +1.21 %, [+0.58, +1.85] %, `within-noise`, control −0.35 %, crossing-only pair +18.71 %,
crossing ~8.7 ns** — §8 gains its tenth row and **runs 8, 9 and 10 are now THREE replicates of one
module**, reading +0.74 / +1.34 / +1.21. M24 re-run: **350, 6/6, exit 0.** The lesson is in the
brief: a content stamp that hashes source wholesale makes a comment expensive.

### The post-sweep edits were re-measured rather than assumed

`TRACE-ABI.md`, `SOURCE-MAPPING.md`, `CAMPAIGN-BRIEF.md`, `DRIFT.md`, the M25 check and the
milestone file all changed after the sweep. Re-run: **m1 175, m15 537, m19 180, m20 237, m22 260,
m23 509, m24 350, m25 272, m26 313 — every one at reference, exit 0.**

## Phase 11 — THE HEADLINE CLAIM, finished by execution rather than by inspection

The earlier baseline in Phase 1 was **WRONG, and wrong in the direction that exonerates the change**.
Reverting the two files in the LIVE checkout and re-running `cargo test` reproduces all six
failures — but **`cargo test -p noir_tracer` does not rebuild `nargo`**, and these tests SPAWN it,
so that run compared the OLD expectations against the NEW recorder. Re-taken in a separate
`git worktree` at the parent commit `6db58caad`, with `nargo` rebuilt into its own target dir, the
attribution splits in two:

| test | assertion | got | pinned | whose |
|---|---|---|---|---|
| `a_1_mul` | `values` | 10 | 19 | **pre-existing** |
| `a_2_function_calls` | `types` | 3 | 4 | **M26** |
| `assert` | `types` | 2 | 3 | **M26** |
| `if_then_else_reduced` | `values` | 78 | 155 | **pre-existing** |
| `types_test` | `types` | 10 | 11 | **M26** |
| `multi_stmt_per_line` | columns | `[9,27,45]` | `[1,9,1,27,1,45]` | **pre-existing** |

**The pre-existing half is explained**: `noir/Cargo.toml:144` resolves the writer to the sibling
`codetracer-trace-format` checkout **by bare path at no pinned revision**, 45 commits have landed
there, and `register_step_with_column`'s own doc comment now says *"one absolute step at the
requested `(line, column)` instead of an intermediate column-1 step plus a separate delta step"* —
which is the column list exactly, and `values` going from `2·steps−1` to `steps`.

**The other half is M26's, and it was NOT declared.** Rendering a `Field` as `ValueRecord::String`
instead of `ValueRecord::Int` removes exactly one type-table entry: the writer registers a nameless
companion type for a `TypeKind::Int` type the first time that type carries an `Int` VALUE, and a
`Field` no longer carries one. Measured with a baseline `nargo` in a clean worktree:

```
assert              [None, Field, type_1]           ->  [None, Field]
a_2_function_calls  [None, Field, type_1, ()]       ->  [None, Field, ()]
types_test          [None, Field, type_1, u32, type_3, Point, i8, type_6, Bool, String, Array<2,..>]
                ->  [None, Field,         u32, type_2, Point, i8, type_5, Bool, String, Array<2,..>]
a_1_mul             [None, u32, type_1]             ->  unchanged  (its companion follows u32)
```

The type RECORD is unchanged, still `(TypeKind::Int, "Field")` — which is what `tracer_glue.rs`
claimed and it is true. The type TABLE is not, and nothing said so.

### M26's OWN ASSERTIONS PASS, AND THAT IS NOW EXECUTED

With the stale pins repinned from measurement, **`test_assert_via_ct_print_full` and
`test_types_test_via_ct_print_full` are GREEN** — the two tests that call `field_small_int`, so
every one of M26's updated Field expectations runs and passes: `3 passed, 3 failed`, from
`0 passed, 6 failed`.

### Three remain red, all pre-existing, and deliberately NOT repinned

1. `a_1_mul`'s per-step `x` sequence is shifted by one leading `None`. Same cause as `values`, but
   the right expectation is a question about which step a stepper should stop on.
2. `a_2_function_calls` records its last step as **`("main", 142)` in a thirteen-line file**.
   Present byte-for-byte in the baseline decode — a recorder defect, and repinning it would write a
   bogus line number into a test.
3. `multi_stmt`'s `assert` step on line 4 no longer carries column 1.

Two of the three are asking whether today's output is right, which is the question. They belong to
the Noir fixture-parity milestone and the test header names each one.

**Recommendation, and it is what was done: FIX NOW.** Not because the pins were tidy to move, but
because one of the two causes is M26's own undeclared consequence — leaving it unfixed would have
shipped a behavioural change nobody had written down, behind a suite that could not reach the
assertions meant to catch it.

### R16 addendum — the M24 red is NOT the six exports, and the attribution matters

The obvious reading is that M26's six new module exports changed the module, moved the stamp and
left §2 stale. **That is not what happened, and it is refuted by three measurements:**

1. **The module has not been rebuilt since M26 finished.**
   `ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm` is
   **262,693 bytes, sha256 `5edf9671…`, mtime 06:17** — hours before this review's first edit and
   before the sweep. `TRACE-ABI.md` §7 states exactly those two figures and
   `verify_ct_writer_wasm_zero_imports` re-derives both from the artefact: it was **58/0** in the
   same sweep run in which the OQ-6 check failed. A changed module would have reddened §7 too.
2. **M24 was GREEN at 350 at the end of M26's own sweep**, with all six exports already in the
   module (they landed in M26's step 7, before its sweep). So §2 and `arms.tsv` agreed then.
3. **M26 did re-render §2 — three times**, for runs 7, 8 and 9, and §8's ninth row reads
   *"the SAME module as run 8"*. The document was current for the module it describes.

The desync therefore arose during the review, and the only stamp input the review touched is
`ct-host/src/abi.ts` — **a comment**. `_m24_oq6_stamp` hashes the module PLUS
`tools/run_oq6_arms.mjs`, `ct-host/src/{writer,abi,config}.ts` by file content, so R11's
one-sentence docstring correction was sufficient on its own.

**Why the distinction is worth the paragraph:** "M26 forgot to re-render after changing the module"
licenses the remedy "re-render after changing the module", which M26 already did and which would not
have prevented this. The true remedy is knowing that editing a COMMENT in those four files buys a
twelve-session benchmark, which is now in the brief.

### The corrected §2, checked against the coordinator's arithmetic

| row | median | min | crossings | container |
|---|---|---|---|---|
| `batched` | 627,120 | 616,408 | 25 | 4,694,016 |
| `perEvent` | 632,951 | 621,529 | 100,000 | 4,694,016 |
| `control` | 623,664 | 608,135 | 25 | 4,694,016 |
| `nopBatched` | 4,711 | 4,488 | 25 | 159,744 |
| `nopPerEvent` | 5,584 | 4,945 | 100,000 | 159,744 |

Whole rows, rewritten by `m24-render-trace-abi.py` from the sweep's own `arms.tsv` and matched
row-at-a-time by the check — M24's review's fix, so a swapped median cannot pass.

**The verdict holds, and the two ways of computing it differ slightly.** `perEvent - batched` is
**+1.21 %, [+0.58, +1.85] %, `within-noise`**; the control is **−0.35 %**, inside the margin, so the
instrument is calibrated. `(632,951 − 627,120) / 627,120 = +0.93 %` is the ratio of the two medians;
the document and the comparator use the **median of the per-session paired ratios**, which is the
paired statistic and is +1.21 %. Same sign, same order, and the sign is run 2's — the sixth of the
ten runs to land there. **The ABI decision does not move.**

**The container sizes are unchanged to the byte**: 4,694,016 for the three real arms, matching
`TRACE-ABI.md` §5's *"4,694,016 bytes, unchanged to the byte"* recorded when M26 added the exports,
and 159,744 for the two nop arms whose writer work is removed. Nothing about the artefact moved.
