# M36 Review Log — Note Discovery and Tagging

Review agent for M36, the last milestone of the wallet group.
Claim under review: all three entries passing, M36 = 137 (74/29/34), sweep **11,910**, `delta +0`,
with an honest partial recorded.

Written **as I go**, per the campaign brief's standing rule.

---

## Step 0 — preconditions

- `CAMPAIGN-BRIEF.md` read in full (2,244 lines).
- Live-sweep check: `ps aux | grep -E 'verify-m|verify-l|sweep'` returns only three stale
  `tail -f` processes from M14/M22/M30 review sessions (Aug 24/26/28). **No live sweep.**
- `git fetch origin`: `HEAD == origin/dev == 4b627dc`, `rev-list --left-right --count` = `0 0`.
  Nothing to rebase; the four-track branch is quiescent at the moment the review starts.
- Working tree carries M36's uncommitted work (20 modified, 2 added, 9 untracked).

Recent history confirms the four tracks the task names:
```
4b627dc L3: a settled Aztec transaction becomes a .ct the reference reader parses
cd954d8 L2's verification: 282 assertions, and the arm that tests the control
0937c72 m35: tier 2's second rung, and a wire-shape gap the version check cannot see
4950613 L2: L1's undeclared-fixture guard caught L2, so it is extended and not loosened
9f91d95 L2: a settled transaction re-executed, and the two routes the artefact closes
3b2365f L2: the reference block on the wire, as an option rather than an edit
ab779d9 m35: tier 2's first rung — the contract instance directory, and the ladder it moved
```

Priorities, in the order the task sets them:
1. The headline — note created in block 1, discovered and spent in block 3, in Chromium;
   `tags.mine == sealedFirstFields[0]` two-producers-one-value.
2. The tier-2 number 17 and the fabricated-instance control.
3. The RI-100 live bug and its sibling search.
4. Vendoring / zero new deps; mutation matrix; six aborts and four upstream validations;
   the boundary assertion; counts; the honest partial.


---

## Step 1 — M36 = 137 REPRODUCED, AND FROM A REAL BROWSER RATHER THAN A CACHE

First run of `just verify-m36` used the **cached** arm report and gave 74 / 29 / 34 = **137**. That is
not enough for a headline whose whole claim is *"in Chromium"*, so the run was re-taken with
`M36_ARMS_REFRESH=1`, which forces the arm subprocess:

```
  --   running the note-discovery arms in Chromium 150.0.7871.128 Arch Linux (timeout 1800s)   [x3]
e2e_note_discovery_across_blocks: 74 assertion(s), 0 failure(s)
test_tagging_index_advances:      29 assertion(s), 0 failure(s)
verify_local_history_boundary_declared: 34 assertion(s), 0 failure(s)
```

**137 (74 / 29 / 34), 3/3, exit 0, over three fresh Chromium runs of my own.** Summary lines counted at
column 0 only.

### Every headline figure re-derived from MY report, not quoted from the log

| figure | impl claims | my fresh run |
|---|---|---|
| `NoteGetter.insert_note` bytecode | 48,754 | **48,754** |
| solved witness | 3,588 | **3,588** |
| oracle calls, all served | 17 | **17**, and every entry begins `served:` |
| notes stored / ACTIVE after creation | 1 / 1 | **1 / 1** |
| `getNotes(ACTIVE)` after spend | 0 | **0** |
| `getNotes(ACTIVE_OR_NULLIFIED)` after spend | 1 | **1** |
| creation block / spend block | 1 / 3 | **1 / 3** |
| scopes on the note after re-validation | 2 | **2**, with 1 row |
| registry / servedWith / refusingWith | 68 / 43 / 25 | **68 / 43 / 25** |
| servedWithout / refusingWithout | 35 / 33 | **35 / 33** |
| discovery set | 8 | **8**, and `exercised` is the same set |

The ledger is the one the milestone describes: `assertCompatibleOracleVersion`,
`isExecutionInRevertiblePhase`, `getRandomField`, `notifyCreatedNote`, eight more `getRandomField`,
then **`getSenderForTags`, `getAppTaggingSecret`, `getNextTaggingIndex`**, then
`isExecutionInRevertiblePhase`. **No oracle in that ledger returns a TAG** — the wallet answers with a
sender ADDRESS, a SECRET and an INDEX, which is the precondition for the two-producer claim being
about a derivation rather than about a handoff.

### The tag values, read out of my own run

```
tags.mine             = 0x172300f47e8b6287235cb1e1686890728cc361b5dcd59f9c0743d398510ac62a
tags.sealedFirstFields[0] = 0x172300f47e8b6287235cb1e1686890728cc361b5dcd59f9c0743d398510ac62a
tags.theirs           = 0x2f1e489eec28fb96b54a0145af46afb9998bf646850af4809f27cb12630ab839
tags.sealedFirstFields[1] = 0x2f1e489eec28fb96b54a0145af46afb9998bf646850af4809f27cb12630ab839
myLogs 1 / theirLogsUnderTheirTag 1 / myLogsUnderTheirTag 0 / theirLogsUnderMyTag 0
```

Equal, and the two tags DIFFERENT. Whether that equality is *by construction* is the next step and is
not settled by reading it.

## Step 2 — VENDORING: byte-identical at the `cpp` anchor, verified against the object store

`PROVENANCE.md` V12 = `browser/src/vendor/pxe_notes` <- `yarn-project/pxe/src`, anchor `cpp`, RI-98, 2 files.

Compared against `git cat-file -p 233d8e099336c1773b89e939100af047ed9c4f71:<path>` in the sibling
`aztec-packages` checkout. **Both files differ raw** — because each carries the generated
`BEGIN VENDORED-PROVENANCE` header this campaign's `just vendor-headers` writes. With that header
stripped:

| file | lines | result |
|---|---|---|
| `contract_function_simulator/pick_notes.ts` | 160 | **BYTE-IDENTICAL** |
| `contract_function_simulator/execution_tagging_index_cache.ts` | 33 | **BYTE-IDENTICAL** |

`local-edits: none` **holds**. The headers declare `upstream-commit: 233d8e0993…`, matching `pins.json`
`anchors.cpp`.

**Zero new dependencies — VERIFIED STRUCTURALLY, not by reading the claim.** `git status --short`
names **no** `package.json` or `package-lock.json` anywhere in M36's diff. A dependency cannot be
added without one.

---

## Step 3 — THE VERDICT ON "TWO PRODUCERS, ONE VALUE": **IT IS NOT AGREEMENT BY CONSTRUCTION**

Reading the code establishes the shape but cannot settle the question, so it was settled by
falsification. The decisive property is: **if the two sides are one producer, a mutation to one of
them moves both and the identity stays green.**

`M2` mutates exactly one thing and it is on the WALLET side only —
`DevTagging.siloedTag`'s `SiloedTag.compute(...)` replaced by `Tag.compute(...)`, i.e. the
app-siloing step dropped. It does **not** touch `emittedTag`, `sealPrivateFrame`, the note database
or the circuit. Re-run by me:

```
e2e_note_discovery_across_blocks: 74 assertion(s), 5 failure(s)

FAIL the wallet's own siloed tag is the first field of the log the block carries
     expected [0x1d7b5a8c14586fda5ec66eeccd4c48d8d879b24bd49b978c99f828556ece4383]
     got      [0x172300f47e8b6287235cb1e1686890728cc361b5dcd59f9c0743d398510ac62a]
FAIL and the second wallet's tag is the first field of ITS log
     expected [0x0bcaf957fe344c81dd062e70bbb96b884f20958969499a4ac944f2ca80d92b1d]
     got      [0x2f1e489eec28fb96b54a0145af46afb9998bf646850af4809f27cb12630ab839]
FAIL the wallet finds its own log under its own tag                expected [1], got [0]
FAIL the second wallet finds ITS log under ITS tag                 expected [1], got [0]
```

**The right-hand values are unchanged from my clean run.** `0x172300f4…` and `0x2f1e489e…` are
exactly the two `sealedFirstFields` the unmutated tree produced. The left-hand values moved. So the
two sides are **separately reachable**: mutating the wallet's derivation moved the wallet's tag and
left the block's field where it was.

That closes the question in the direction the task asked about. The chain, now established rather
than read:

* the wallet answers `getSenderForTags` (an ADDRESS), `getAppTaggingSecret` (a SECRET) and
  `getNextTaggingIndex` (an INDEX). **My own ledger read confirms no oracle in the run returns a
  tag** — so the circuit cannot have been handed one;
* the ACIR circuit derives the tag in-circuit and emits it as `privateLogs[0].fields[0]` of its own
  public inputs — 48,754 bytes of bytecode, 3,588 witness entries, verified in my run;
* `sealPrivateFrame` applies upstream's `computeSiloedPrivateLogFirstField(contract, thatField)` —
  read at `note_database.ts:555`, and it consumes the circuit's field rather than recomputing one;
* the wallet independently computes `SiloedTag.compute({extendedSecret, index})` through
  `@aztec/stdlib` — a **TypeScript** hash chain against the circuit's **Noir** one.

**VERDICT: the two-producers-one-value claim SURVIVES, and it survives on a falsification I performed
rather than on the structure of the code.** It is a genuine cross-implementation identity
(Noir in-circuit derivation vs `@aztec/stdlib` in TypeScript), with the non-degeneracy — the two tags
asserted DIFFERENT — carrying its weight: under M2 both wallets stop finding their own logs, so the
control's both-halves shape fires too.

### One reading in the impl log that did NOT survive, and it is small

The impl log's matrix rows for M2 say the failures are *"both two-producer identities, and both
wallets stop finding their own log"* — that is **four**, against a declared and measured **five**. The
fifth is `LOCAL-HISTORY.md`'s figure comparer, which reddens because a rebuild in a mutated tree moves
the packaging figures. The rows for M1 and M6 *do* say "plus a document figure"; M2's does not. The
count is right and the check is right; the *reading* is one short. Recorded per this campaign's own
rule that "the check failed" and "the check saw what I broke" are different statements.

### And a second reading that did not survive, in M6

The impl log says M6's five are *"the unregistered-address control's four, including
`ContractInstanceNotHeld` and the not-`OracleUnimplemented` assertion"*. Measured:

```
FAIL an unregistered contract address is refused at tier 2's own rung (test null != null)
FAIL and the refusal names the oracle                    (str_has_sub null aztec_utl_getContractInstance)
FAIL and it is ContractInstanceNotHeld rather than OracleUnimplemented
FAIL and it says how many the directory holds
FAIL every figure LOCAL-HISTORY.md states …              (the document figure again)
```

The **not-`OracleUnimplemented` assertion PASSES** under M6, vacuously — `assert_false str_has_sub
null OracleUnimplemented` is satisfied by the absence of any refusal at all. It is *capable* of
failing (a refusal naming the wrong error would redden it) and it is guarded by the
`!= "null"` assertion two lines above, which does fire — so the CHECK is sound and this is a
correction to the log's reading, not a defect in the instrument. The fifth failure is the document
figure, not that assertion.

---

## Step 4 — THE MUTATION MATRIX, SIX ARMS SPOT-CHECKED, ALL SIX REPRODUCE

Run with `M36_MUT_WORK=$HOME/.cache/aztec-m36rev-mut` so the implementation's own harness state was
not touched, and against an **independent snapshot of the six subjects that I took myself** — because
the harness verifying its own manifest is the harness marking its own homework.

| arm | impl declares | I measured | summary line at column 0 |
|---|---|---|---|
| M2 the tag drops its app-siloing | 5 | **74 / 5** | yes |
| M6 `getContractInstance` fabricates | 5 | **74 / 5** | yes |
| M7 **THE HANG** | 0 / 1 | **0 / 1** | yes |
| M8 **DIE BEFORE THE SUMMARY** | 1 / 2, held | **1 / 2**, `M8 held` | yes |
| M10 a spent note stays ACTIVE | 2 | **74 / 2** | yes |
| M13 a note validated twice becomes two | 6 | **74 / 6** | yes |

`HARNESS_RC=0`, `restored; manifest verified`, **no `MUTATION MISS`, no `ABORTED`, no
`DID NOT HOLD`**. My own six-file snapshot compares **OK** on all six after the run, and
`carry/*.json` is byte-identical to its pre-review digests on all four.

**M7's diagnostic is bounded and names the state**, which is the property the arm exists for:
`cannot run: the note-discovery arm run exited 1: Runtime.evaluate did not complete within 60000 ms.
That is the HANG state reported as a failure.` — and it still prints
`e2e_note_discovery_across_blocks: 0 assertion(s), 1 failure(s)` at column 0, so it reads RED and not
SMALLER.

**M8 is the die-before-summary path and it held**: one assertion (`m36_absent` naming
`discovery.pageErrors discovery.consoleErrors lazy.pageErrors` in a single failure) and a second
failure from the abnormal-exit trap. The hollow survived the run — the ordering defect M30's review
recorded is not present here.

**M10 is the arm the ACTIVE/ACTIVE_OR_NULLIFIED pair exists for, and the pair behaved.** Only
`getNotes(ACTIVE) no longer returns it` reddened (1 where 0 belongs); the
`ACTIVE_OR_NULLIFIED still does` assertion stayed GREEN, which is exactly what says the two readings
are not one reading twice.

**`still_there` exiting 5 was NOT re-demonstrated by me** — no arm was undone in my run, which is the
correct outcome. The impl's claim that it was "demonstrated for real when a concurrent launch left
one live" is a claim about an incident I did not reproduce and am not in a position to confirm or
deny; the mechanism is present in the harness and I read it.

## Step 5 — THE LADDER: the calibration reproduces TO THE BYTE

`scratchpad/campaign/m36-ladder-spike.mjs`, run by me in this repository's dev shell against the
built bundle:

| program | bytes | outcome | stops at | served | witness |
|---|---|---|---|---|---|
| `Token.transfer` | **76,875** | refused | `aztec_utl_getContractInstance` | **2** | — |
| `Token.mint_to_private` | **17,582** | refused | `aztec_utl_getContractInstance` | **2** | — |
| `PrivateVoting.cast_vote` | **9,507** | refused | `aztec_utl_getContractInstance` | **2** | — |
| `OracleVersionCheck.private_function` | **6,306** | executed | — | **4** | **897** |

Every figure equals M35's shipped ladder and M36's Step 2. The derived instance address reproduces
exactly: `0x001e7cb55c8b273c4270f336c1bc48336192fa2e0041be8b2a4bc1e2a34c41cb`.

---

## Step 6 — THE TIER-2 NUMBER **17** IS CONFIRMED, BY AN INSTRUMENT I WROTE

The implementation's spike could not answer this on the merged tree — it passes no
`contractInstances`, so the "real instance" arm it documents is no longer reachable through it. So I
wrote my own three-arm instrument. The **fabricated** arm is built the strongest way available: a
SECOND, equally real instance (different class seed, every field a real field) filed in the
directory under the FIRST instance's address, so the only thing wrong is the correspondence.

| arm | `Token.transfer` | `Token.mint_to_private` | `PrivateVoting.cast_vote` |
|---|---|---|---|
| **refused** (nothing held) | `getContractInstance`, **2** | `getContractInstance`, **2** | `getContractInstance`, **2** |
| **fabricated** | *refused at CONSTRUCTION — see below* | same | same |
| **real** | `aztec_utl_getNotes`, **4** | `aztec_prv_getSenderForTags`, **17** | *served, then fails in-circuit, 5* |

**`Token.mint_to_private` -> `aztec_prv_getSenderForTags` at 17 served reproduces exactly**, and so
does `Token.transfer` -> `aztec_utl_getNotes` at 4. **The number that decided the tier-2 scope
survives an independent derivation.**

### THE FABRICATED ARM IS NO LONGER REACHABLE, AND THAT IS STRICTLY BETTER THAN THE CLAIM

I could not produce `Cannot satisfy constraint`, because the merged wallet refuses **earlier**:

```
contract instance directory entry 0 is not self-consistent: it is filed under
0x001e7cb55c8b273c4270f336c1bc48336192fa2e0041be8b2a4bc1e2a34c41cb but its own preimage derives to
0x1ae35d4048d577b98470c0dd5b56011e85dd9de00aa0c69d84a83d5de04d8d86. The circuit's
get_contract_instance asserts exactly this equality, so this entry would fail the ACVM as an
unsatisfied constraint rather than as a directory problem.
```

That is the landed `m35:` rung's construction-time guard, and I hit it by accident, which is the best
way to meet one. So:

* the *behavioural* demonstration in the tier-2 table (`Cannot satisfy constraint`, zero further
  oracle calls) is a **historical measurement of a code path the shipped wallet no longer permits**.
  It is not reproducible today and I record that rather than repeating it;
* the *substantive* claim — **the circuit is the instrument that refuses** — I confirmed at source
  instead, in upstream's own Noir at the `cpp` anchor:
  `noir-projects/labs/aztec-nr/aztec/src/oracle/get_contract_instance.nr:19` is
  `assert_eq(instance.to_address(), address);` inside `pub fn get_contract_instance`, with a safety
  comment giving exactly the campaign's reasoning;
* **no shipped check exercises the circuit-level refusal.** M6's control calls
  `h.getContractInstance(0x999)` directly on the handler, not through a frame, and I confirmed no
  `Cannot satisfy constraint` appears anywhere in M6's arm output. The property is real and is
  covered by a construction guard and by upstream's source, not by a behavioural check.

## Step 7 — COUNTS: 11,910 RE-DERIVED WITH MY OWN SUMMARISER

The implementation's sweep log is on disk (1,054,754 bytes). Re-parsed with a summariser I wrote for
this review — deliberately not `m36-sweep-sum.py` — applying the brief's rule that a summary line is
at **column 0** and a `note` is indented:

```
markers seen: 74   milestones: 37   TOTAL: 11,910
m0 156  m1 182  m2 293  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450 m11 262 m12 691 m13 458 m14 460 m15 537 m16 223 m17 297 m18 283 m19 180
m20 237 m21 325 m22 260 m23 509 m24 350 m25 272 m26 313 m27 345 m28 357 m29 127
m30 218 m31 421 m32 237 m33 248 m34 217 m35 239 m36 137
```

**74 markers for 37 milestones — no hole.** `11,744 + 1 + 1 + 27 + 137 = 11,910` exactly.

Every attribution re-derived from the log's own per-check splits:

| move | mechanism, measured | whose |
|---|---|---|
| M1 181 -> **182** | `verify_provenance_complete` 70 -> **71** | M36's (RI-98) |
| M2 292 -> **293** | `verify_fixture_corpus_manifest_complete` 37 -> **38** | M36's (the derived absent id) |
| M35 212 -> **239** | `test_unimplemented_oracle_refuses_by_name` 95 -> **122** | **NOT M36's** |
| M36 — -> **137** | 74 / 29 / 34 | M36's |

**M35's move is confirmed as the parallel track's**, two ways: `git log` on that check names only
`ab779d9` and `0937c72` (both `m35:`), and `test_unimplemented_oracle_refuses_by_name.sh` **is not in
M36's working diff at all**.

**The three non-zero exits are exactly as declared**, and my parser found no fourth:
M11 262 with nine failures split **5 / 2 / 2** (the ninth-upstream-move signature, count unchanged);
M20 237 with `verify_named_checks_exist` 9/1 (**L2's**); M28 357 with
`verify_npm_pack_no_optional_native` 54/1 (**L0's**). Both recorded, neither fixed — correct.

**L0/L1/L2/L3's nine check names appear ZERO times as a summary line**, grepped **one at a time**
against the anchored pattern. None of their assertions is in the 11,910.

`CAMPAIGN-BRIEF.md` was edited after the sweep; I checked whether that can matter. Ten verification
files mention it and **every one is a prose citation** — none opens the file — so the post-sweep edit
moves nothing.

## Step 8 — THE FOUR UPSTREAM VALIDATIONS: three fire, one is uncovered

| validation | arm | I measured |
|---|---|---|
| a cross-contract tagged-log read | **M11** | **74 / 4** — the control's three, each naming both addresses, + a document figure |
| an out-of-scope tagging secret | **M12** | **74 / 4** — the control's three, naming the scope and the list, + a document figure |
| an undeduplicated NOTE TABLE | **M13** | **74 / 6** — two rows, `getNotes` returns 2, one scope, `stored` 2, `eitherAfterSpend` 2, + a figure |
| **an undeduplicated SECRET SET** | **none** | — |

The secret-set deduplication is implemented (`private_oracles.ts:1415`, a `Map` keyed by
`s.toString()` over `[...provided, ...derived]`, with upstream's own reason quoted above it) and
**nothing anywhere asserts it**: no mutation arm, and `grep -rn 'dedup' verification/` returns one
unrelated hit. The implementation log says so honestly — *"two of them have their own control arm"* —
so this is a disclosed gap and not an overclaim, but the task asked whether all four fire and the
answer is that **three do and the fourth is covered by nothing.** Its permissive version returns the
same log twice, which is the double-count the milestone's own controls are about, arriving from the
secret side.

---

## Step 9 — THE RI-100 BUG AND ITS SIBLING SEARCH

### The bug is real and the fix is right — reproduced, not read

```
RI-100   old=['RI-10']    new=['RI-100']
RI-10    old=['RI-10']    new=['RI-10']
RI-098   old=['RI-09']    new=['RI-098']
```

Both sites are fixed (`_manifest_parser.py:164` `^### (RI-\d{2,}) ` with the literal space as the
right anchor, and `:228` `RI-\d{2,}(?!\d)` with an explicit lookahead). `REUSE-INVENTORY.md` carries
**exactly 99 headings, RI-01..RI-99** — one away, as claimed.

The derived-needle remedy in `verify_fixture_corpus_manifest_complete.sh` is the right shape and it
carries **the assertion that would have gone red the day the inventory reached it**:
`assert_false "the derived absent inventory id really is absent from REUSE-INVENTORY.md"`. That is
the +1 that takes M2 to 293.

### THE CENSUS WAS SCOPED TO `RI-` AND THE SAME FILE CARRIES THE SAME DEFECT TWICE

The implementation records the census as closed: *"`_inventory_parser.py` uses `\bRI-\d+\b` and is
right, `tools/provenance.py` has no such pattern, and the two-digit form existed in exactly one
file."* All three of those statements are **true** — I verified each by reading the file — and the
census is nonetheless **too narrow**, because it enumerated the `RI-` spelling rather than the
FORM. In the very file being fixed:

```
verification/_manifest_parser.py:80   ENTRY_RE = re.compile(r"^### (FX-\d{2}) — (.+)$")
verification/_manifest_parser.py:159  headings  = re.findall(r"^### (FX-\d{2}) — ", text, re.M)
```

`fixtures/MANIFEST.md` is at **FX-29** and grows about one per milestone, so this is latent rather
than live — but it fails **worse** than the RI case, and silently in three places at once.
`### FX-100 — …` does not match `FX-\d{2}` followed by ` — `, so the entry never enters `parse()`
and none of the ~20 per-entry rules runs; the "written OUTSIDE the BEGIN/END block" guard uses the
same truncating pattern and cannot see it either; and the contiguity rule sees `1..99` over 99 ids
and calls that contiguous. Every scope guard reports green over an entry nothing validated.

This is `CAMPAIGN-BRIEF.md`'s own rule — *"when you fix an instance of a form, grep for the form in
the file you are fixing before you leave it"* — unheeded **in the file being fixed**.

**FIXED, and calibrated in both directions.** With the old pattern a planted `### FX-100` is
invisible; with the new one the parser reaches it and the outside-the-block guard fires:
`FAIL manifest: FX-100 written OUTSIDE the <!-- BEGIN:manifest --> block, so nothing validates them`.
No assertion count moves (no three-digit FX id exists): **M2 re-run at 293**.

### A LIVE typed-absent-id defect one namespace over — RECORDED, not fixed

`verification/verify_tier_e_authored_fixtures_justified.sh:258` synthesises "extra" Tier E entries
starting at a hardcoded `fx = 26 + i`. The manifest already declares **FX-26, FX-27, FX-28 and
FX-29**, so `grow_tier_e` injects **duplicate ids** where it means to inject fresh ones — the exact
defect the `RI-99` control just paid for, one namespace over, and **live today**. Measured:
`grow_tier_e 1` produces two `### FX-26` headings.

**But its consequence is milder than it first looks, and I checked rather than assumed.** Running the
grown manifest through the parser, the tier-size rule the control exists for **still fires**:

```
FAIL FX-26: duplicate id
FAIL FX-27: duplicate id
FAIL manifest: Tier E has 4 entries, not strictly fewer than every other tier
```

So the control passes for the right reason *plus* a wrong one, rather than vacuously. It is
fragility, not a hole. Left unfixed because the fix wants a derived base id and the absence assertion
that goes with it, which moves `verify_tier_e_authored_fixtures_justified` off 50 and M2 off 293 —
a count move a review should not make on a check it is not reviewing. **Recorded for the next
milestone.**

Two more typed absent ids of the same family, both far from live, both recorded:
`verify_fallback_cost_priced.sh:442` greps for `^### FX-99 — ` (manifest at FX-29) and
`verify_sequencer_reuse_enumeration_recorded.sh:211` uses `RI-999` (inventory at RI-99).

**The inverse hazard was searched for and is absent**: every id match in the campaign's code carries a
right delimiter (a literal space, ` — `, `(?!\d)`, or `\b`), and no "highest id" is derived by string
sort anywhere — `verify_fixture_corpus_manifest_complete.sh:170` and `_manifest_parser.py:282` both
convert to `int` first, and `"RI-%02d" % 100` widens to `RI-100` rather than truncating. All
remaining fixed-width quantifiers in the repository are over genuinely fixed-width data (`\d{8}`
nightly datestamps, `[0-9a-f]{40}` and `{64}` git SHAs and tree roots, `%03d` session directories,
CMake-generated filenames) and are not hazards.

## Step 10 — A SILENT SKIP IN M36'S OWN CHECK — FOUND, MEASURED, FIXED

`verify_local_history_boundary_declared` §7 computed its comment-stripped source with
`… 2>/dev/null || true` and then guarded three assertions behind `if [ -n "$CODE_ONLY" ]`, with a
`note` in the `else`.

**Measured** by moving `verification/_import_closure.py` aside and running the check:

```
  --   the comment stripper is unavailable; §7's stripped-source assertions were not run
verify_local_history_boundary_declared: 31 assertion(s), 0 failure(s)
verify_local_history_boundary_declared: PASS
```

**A silent three-assertion shrink with no failure attributable to it, and it PASSES.** That is
*"a missing check reads as a smaller milestone, not as a red one"* — the shape that cost this
campaign 283 assertions once — and the three it loses are §7's strongest: that the refusal is in
stripped CODE rather than in prose, and that the stripper removed the prose. A `note` is indented, so
no summary line ever mentions it.

`_import_closure.py` is a file in this repository, not an environment condition, so its absence is a
defect. **Fixed** with a `die` under the existing abnormal-exit trap, so the milestone reads RED
rather than SMALLER. The green path is unchanged: **34, re-run.**

## Step 11 — THE HONEST PARTIAL: one bullet real, one bullet STALE

**Bullet 1 survives, and I measured it rather than reading it.** Nothing in the repository exercises
`Token.transfer` with a discovery source attached, so I wrote an instrument that does — a real
`DevNoteDatabase`, `DevTagging` and `DeterministicEphemeralArrayService` over the wallet's own
deterministic accounts, with an **empty note table**, which is the condition the sentence describes:

```
outcome: "failed",  stoppedAt: null,  served: 5,  bytes: 76875,  getNotesServed: true
ledger tail: … served:aztec_utl_getContractInstance, served:aztec_prv_isNullifierPending,
              served:aztec_utl_getNotes
lastError: "Error: Assertion failed"
```

`getNotes` **is reached and is SERVED**, the table holds nothing, and the frame then fails on the
circuit's own assertion. The restraint is real: nothing past `getNotes` is asserted anywhere, and
`stoppedAt` is `null` because the halt is in the circuit rather than at an oracle. (The one word the
measurement does not carry is "balance" — the ACVM says `Assertion failed` and does not name which.)

**Bullet 2 does NOT survive.** §7 said *"`PrivateVoting.cast_vote` needs a SECOND tier-2 rung,
`getPublicKeysAndPartialAddress` … It refuses by name."* Measured on the shipped tree, that rung is
**served**:

```
served:aztec_misc_assertCompatibleOracleVersion
served:aztec_prv_isExecutionInRevertiblePhase
served:aztec_utl_getContractInstance
served:aztec_prv_isNullifierPending
served:aztec_utl_getPublicKeysAndPartialAddress
ERR: Assertion failed: 9 output values were provided as a foreign call result for 2 destination slots
```

The second parallel `m35:` commit landed it while M36 was being verified. `PRIVATE-EXECUTION.md`
§3b records the change and analyses the wire-shape gap correctly — so the *analysis* exists — but
M36's own `LOCAL-HISTORY.md` §7 was left stating the superseded fact, and **nothing re-derives it**
(`_m36_doc_figures.py` re-derives FIGURES, and this is prose). It is the *"a figure nobody re-derives
rots"* / *"fix a false sentence where it is written"* family arriving through a shared branch, which
is the way it will keep arriving.

**Corrected at the source**, in `LOCAL-HISTORY.md` §7, with the measurement and a pointer to §3b for
the analysis. `_m36_doc_figures.py` and the boundary check's own §2/§6 needles both still pass:
**M36 re-run at 137 (74 / 29 / 34)** after all three of this review's edits.
