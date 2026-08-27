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
