# M35 — Private Execution Inside the Wallet — REVIEW log

Written as I go.

## Step 0 — coordination and the state I inherited

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `d24ac569` | M35's uncommitted work: 21 modified, 51 added, 17 untracked |

`git fetch origin` taken at review start: **`HEAD == origin/dev == d24ac5692d…`, zero ahead, zero
behind.** No rebase needed; the parallel L0/L1 track has not moved since M34's review pushed.

No sweep running: `ps` for `verify-m` / `verify-l` returns nothing.

`replay/` is untouched by M35's diff — confirmed by `git status --porcelain` (no `replay/` path in
the working set).

---

## Step 1 — THE BASELINE, RE-TAKEN WITH A FORCED ARM RUN

`M35_ARMS_REFRESH=1 just verify-m35` in this repository's own dev shell, `setsid`-detached, arms
re-run from scratch in Chromium 150.0.7871.128:

```
verify_oracle_coverage_is_measured:        64 assertion(s), 0 failure(s)
test_unimplemented_oracle_refuses_by_name: 83 assertion(s), 0 failure(s)
e2e_private_function_executes_in_browser:  51 assertion(s), 0 failure(s)
verify-m35: all checks passed
```

**198 = 64 + 83 + 51**, 3/3, exit 0. The declared split holds to the assertion.

---

## Step 2 — THE ORACLE COUNT, RE-DERIVED BY AN INSTRUMENT M35 DID NOT WRITE

`_m35_oracles.py` is M35's. So I wrote a **second, independent** parser
(`scratchpad/rederive.py`, review-local): a different comment/string blanker that preserves file
offsets, a brace walk from the declaration, and a depth-0 key extraction over the *cleaned* text
with the residue and the non-word residue characters both printed.

| source | count | misc / utl / prv | duplicates | residue |
|---|---|---|---|---|
| `cpp` anchor object store (`233d8e0993`) | **68** | 3 / 49 / 16 | none | 68 × `makeEntry`, 68 × `)` |
| vendored `browser/src/vendor/pxe/…/oracle_registry.ts` | **68** | 3 / 49 / 16 | none | identical |
| `upstream/tsavm` worktree | **53** | 3 / **36** / **14** | none | 53 × `makeEntry` |

**Name for name, anchor vs vendored: IDENTICAL** (`diff` of the two sorted key lists is empty).

**The fourth derivation, the built bundle in Chromium**, out of the fresh arm report:
`registry.total` **68**, `handlerMethods` **68**, `handlerMarkers` **3**, `handlerNonOracle` **1**,
`implemented` **33**, `refusing` **35**, `reasons` **35**, `exercised` **33**,
`environmentVersion` **{30, 8}**.

**And the fourth source genuinely disagrees FOR THE RECORDED REASON.** `upstream/tsavm` is checked
out at `3a68d68ac29aaf04fc6251c80a8eb874043cb260` — the **`ts` anchor**, 2026-06-25, two months
before the `cpp` anchor — so 53 is a different revision's registry and not a parser artefact: the
scope split moves too (36 `utl` and 14 `prv` against 49 and 16). It carries neither
`acir_callback.ts` nor `legacy_oracle_registry.ts` — confirmed by `ls`. **Legacy aliases: 3**,
re-derived from the anchor's `legacy_oracle_registry.ts` (the four later `^  name:` matches are
interface members below the object, which is the reason the structural parse exists).

**THE PARTITION, RE-DERIVED FROM THE SOURCE RATHER THAN FROM THE REPORT.** Parsing
`ORACLE_IMPLEMENTED` and `ORACLE_REFUSAL_REASONS` out of `private_oracles.ts` directly:
33 and 35, both sets of distinct names, both subsets of the registry, **intersection empty**,
**registry − implemented − reasons empty**, 33 + 35 = 68. Four claims, all survive.

---

## Step 3 — THE SAFETY PROPERTY, MUTATED IN ITS STEALTHIEST FORM

The brief asks for a refusing oracle made to return a plausible default. **M35's own M1 arm is the
blunt version** — every refusal returns `undefined` and still records `refused`. I wrote the sharp
one instead, **R1**: `aztec_utl_getContractInstance` alone — the oracle `transfer` stops at —
returns a **well-formed `ContractInstancePreimage`** (salt, deployer, originalContractClassId,
initializationHash, immutablesHash, publicKeys with a POINT), **and writes nothing to the ledger**,
so the exercised set, the partition, the sum, the disjointness, the handler-method count and
`assertOracleSurfaceMatchesDeclaration` all still agree with themselves.

**Something goes red, and it is the right something.**
`test_unimplemented_oracle_refuses_by_name`: **83 assertions, 9 failures**, count unchanged.

```
FAIL not one of them RESOLVED — nothing returned a plausible value   got [aztec_utl_getContractInstance]
FAIL and every one NAMES ITSELF …                                    got [aztec_utl_getContractInstance]
FAIL and says what it does not serve …                               got [aztec_utl_getContractInstance]
FAIL the refusals are visible in the ledger too      expected [35], got [34]
FAIL the frame refused                        expected [refused], got [failed]
FAIL at an oracle it NAMES  expected [aztec_utl_getContractInstance], got [null]
FAIL and refused exactly one                        expected [1], got [0]
FAIL the error chain carries the refusal's own message  (got "Cannot satisfy constraint")
```

`verify_oracle_coverage_is_measured`: 64 / 1 (the document figure). **The third rung saw it too**:
the real ACIR frame stopped being a refusal and became a `failed` — the fabricated instance carried
the circuit past the gate and into an unsatisfiable constraint, which is the plausible default's own
cost, measured. Restored and rebuilt; subject sha256 verified against the pre-mutation manifest.

---

## Step 4 — THE FOUR VALIDATIONS FIRE, EACH ON ITS OWN ASSERTION

Each reverted to the permissive form the impl log says it had, rebuilt, arms re-run, refusals check
run. **One failure each, the count unchanged at 83 every time**, so each is a live assertion and not
a structural change:

| reverted to | result |
|---|---|
| the overlapping capsule copy done forward always | `expected [1,2,3], got [1,1,1]` — the exact smear the write-up predicts |
| a duplicate siloed nullifier added to a `Set` | `NOT REFUSED` where `duplicate siloed nullifier` belongs |
| consuming a note nobody created, recorded | `NOT REFUSED` where `does not exist` belongs |
| the calldata cap looked up and not asserted | `NOT REFUSED` where `too many total args` belongs |

All four are present, all four fire, and all four fire on the one assertion written for them. The
cap is compared against `orchestration/node_modules/@aztec/constants`' own
`MAX_FR_CALLDATA_TO_ALL_ENQUEUED_CALLS` rather than a number typed in the check — verified by
reading the check.

---

## Step 5 — THE LADDER IS A MEASUREMENT, AND I RE-TOOK ALL FOUR RUNGS

The checks execute **only `Token.transfer`**. `Token.mint_to_private` and `PrivateVoting.cast_vote`
are claimed in `private_oracles.ts`'s refusal reason, in `PRIVATE-EXECUTION.md` §3 and in the
milestone section — and **nothing re-derives them**. So I ran them, in Node, against the BUILT
`wallet.js` bundle with `avm.wasm` opened through `testing.js` and the two ACVM modules fed off disk:

| contract | function | type | bytes | outcome | stopped at | served | witness |
|---|---|---|---|---|---|---|---|
| Token | `transfer` | `abi_private` | **76,875** | refused | `aztec_utl_getContractInstance` | 2 | — |
| Token | `mint_to_private` | `abi_private` | 17,582 | refused | `aztec_utl_getContractInstance` | 2 | — |
| PrivateVoting | `cast_vote` | `abi_private` | 9,507 | refused | `aztec_utl_getContractInstance` | 2 | — |
| OracleVersionCheck | `private_function` | `abi_private` | **6,306** | **executed** | — | **4** | **897** |

All three refusals reach the same rung by the same route — `assertCompatibleOracleVersion`,
`isExecutionInRevertiblePhase`, then the gate. **The claim is a measurement and it survives.**
§4's seven figures (6,306 / 37 / 897 / 4 / 76,875 / 2 / 1) are all confirmed independently, as is
`returnsHash = 0x08bc51382a…`.

---

## Step 6 — THE VENDORING

**All fifty files byte-identical to the anchor**, re-derived by walking `git ls-files` against
`git cat-file -p <cpp anchor>:<upstream path>` myself: **50 files, 4,961 lines, 0 unresolved,
0 differing** once the generated provenance header is removed (every local file *ends with* the
anchor blob exactly). §2's `50 / 4,961` row is right.

`just check-drift`: **24 assertions, 0 failures**, with `V10 browser/src/vendor/simulator [13]` and
`V11 browser/src/vendor/pxe [37]` both present — 22 → 24 confirmed, two tree rows at one assertion
each. Coverage: **821 mapped, 821 compared, 631 byte-identical**.

`@aztec/noir-acvm_js`'s dependency list is **EMPTY**, re-derived offline from
`orchestration/package-lock.json` by me (`packages['node_modules/@aztec/noir-acvm_js'].dependencies`
is `{}`), with `@aztec/aztec.js`'s twelve-entry list as the control that the reader answers both
ways. The orchestration declares **six** dependencies. RI-64's case holds.

**RI-64's narrowed identity claim is exactly right.** Blob-by-blob over the 13-file `client.ts`
closure at the `cpp` and `ts` anchors: **twelve SAME, `client.ts` DIFFERS**, and the difference is
the two extra re-exports (`SimulatorRecorderWrapper`, `MemoryCircuitRecorder`) — six lines at `ts`,
four at `cpp`. The correction is filed **where RI-64 is written**, not next door.

---

## Step 7 — L0/L1, AND THE M28 INTERACTION

L0's and L1's six check names appear in the `Justfile` three times each — a comment, their own
`verify-l0-*` / `verify-l1-*` recipe, and the `verify-l0` / `verify-l1` loop. **Zero of them appear
inside any `verify-m<N>:` recipe**, grepped one at a time over the recipe bodies. Nothing under
`replay/` is in M35's diff.

**M28's one failing assertion is still L0's, and M35's move does not touch it.**
`verify_npm_pack_no_optional_native:75` pins `ct-host diffsim drift node-host orchestration probe-mt
spike` and `git ls-files '*/package.json'` returns that list **plus `replay`**. M35's +4 is in
`verify_browser_bundle_no_node_builtins` (+3) and `verify_browser_bundle_no_native_deps` (+1);
`verify_npm_pack_no_optional_native`'s count is untouched. The two facts do not interact.

**The M28 and M33 attributions were re-derived from the diffs rather than believed.**
`no_node_builtins`: two assertions removed (the `exactly one` count and its follow-up), five added
(non-emptiness on the edges, the named SET, the Reactor membership, the emitted-bytes non-emptiness,
and "not one elided specifier survives") — **net +3, 64 → 67**. `no_native_deps`: one added (no DD-9
package in the external set) — **+1, 44 → 45**. `provider_half_dd9_clean`: two added (the ACVM's
empty list and the `@aztec/aztec.js` control) — **+2, 106 → 108**. Both attributions are exact.

---

## Step 8 — THE MUTATION MATRIX, RE-TAKEN, AND ONE ARM MOVED

M35's table was measured **before the three aborts** and honestly labelled as such. It is still a
matrix taken against a tree that was not shipped. Re-run by me against the shipped tree, then again
after my own fixes:

| arm | declared | re-taken (as shipped) | re-taken (after the review's fixes) |
|---|---|---|---|
| M1 | 69 / 4 | **83 / 5** | **95 / 5** |
| M2 | 60 / 2 | 64 / 2 | 64 / 2 |
| M3 | 69 / 1 | 83 / 1 | 95 / 1 |
| M4 | 60 / 4 | 64 / 4 | 64 / 4 |
| M5 | 60 / 7 | 64 / 7 | 64 / 7 |
| M6 | 69 / 1 | 83 / 1 | 95 / 1 |
| M7 (hang) | 0 / 1 + summary | **0 / 1 with a summary line** | same |
| M8 (die) | 1 / 2, "M8 held" | **1 / 2 with a summary line, M8 held** | same |
| M9 | 60 / 1 | 64 / 1 | 64 / 1 |
| **M10 (mine)** | — | — | **95 / 13** |

**M1 moved from four failures to five**, and the fifth is §3b's arity-chosen control — an assertion
the third abort added and the declared matrix never exercised. That is the only arm that moved.

**M7 fires for the right reason and NAMES it**, which is what the brief asks:
`the private-execution arm run exited 1: Runtime.evaluate did not complete within 60000 ms. That is
the HANG state reported as a failure.` — the bound and the state, not "exited 1". **M8 held**: the
hollow survived the run and `m35_absent` named all four absent fields in one assertion before dying,
with the abnormal-exit trap printing the summary line. **`still_there` exits 5**, demonstrated both
ways in a sandbox: `held -> continues` on the present case, `EXIT=5` on the undone one. No
`MUTATION MISS`, no `ABORTED`, no `DID NOT HOLD` in either run; the final restore re-measures 64 / 0.

**AND §5b NEEDED AN ARM OF ITS OWN, WHICH IS WHY M10 EXISTS.** M1 leaves `record(oracle, 'refused')`
in place, so the ACIR frames still report `outcome: refused` at the named oracle and neither §5 nor
§5b can see it — M1 is caught by §1 and §3b, which is coverage of the handler and not of the ladder.
M10 is the stealth default: **95 / 13**, four of them in §5b (`every one of them REFUSED` reads
`failed`, the stop set reads `{None}`, the stop is not a refusing oracle, and `each refused exactly
one` reads 0). An assertion that cannot be made to fail is the thing this campaign counts; §5b's can.

---

## Step 9 — THE FIXES

Three, all of them assertions rather than prose:

1. **The ladder is measured on every run.** `armPrivateExecution` runs `Token.transfer`,
   `Token.mint_to_private` and `PrivateVoting.cast_vote` — two contracts, three distinct bytecodes —
   and reports each rung. The argument width is read back out of `executePrivateFunction`'s own arity
   refusal rather than typed. §5b of `test_unimplemented_oracle_refuses_by_name` asserts the stop set
   is the singleton `{aztec_utl_getContractInstance}`, plus the non-degeneracies that it is three
   programs and not one run three times. **+12** (83 → 95). `PRIVATE-EXECUTION.md` §4 grows a row the
   figure comparer re-derives (34 → 35 figures).
2. **The address is compared against the request.** `e2e_private_function_executes_in_browser` §3
   compared `publicInputs.contractAddress` against `0x0…777` typed into the check. The arm reports
   `requestedContractAddress` now and the check compares the circuit's ECHO against the REQUEST, with
   a non-degeneracy that the request is not zero. **+2** (51 → 53).
3. **M10**, above, so §5b's assertions are shown to fail.

**M35 = 212 (64 / 95 / 53)**, 3/3, exit 0.

The build moved exactly one figure — `wallet-demo.js` 332.68 → **332.94 KB** (13 files unchanged) and
the all-chunk total 8,219.06 → **8,219.32 KB** — and every one of the four places carrying it was
found by the check that re-derives it going red: `PRIVATE-EXECUTION.md` §6, `DEV-WALLET.md` §6 (twice,
a table row and a prose sentence), `WORKER-NODE.md` §5 and `BROWSER-PACKAGING.md`. `wallet.js`'s eager
set did not move. Re-run afterwards: `verify_browser_chunk_budget` 33,
`test_worker_transferable_container_not_copied` 74, `verify_provider_half_dd9_clean` 108,
`verify_browser_bundle_no_node_builtins` 67, `verify_browser_bundle_no_native_deps` 45,
`verify_browser_entry_points_are_dd5_shaped` 40, `verify_browser_bundle_builds` 54 — every one at its
reference value, zero failures.

---

## Step 10 — STATUS HONESTY

Five verification entries: three `passed` with a `file:` that exists and contains the named check,
two `pending`.

**The two pending entries are honestly pending.** `e2e_wallet_private_transfer` and
`e2e_joined_private_public_trace` both name `aztec_utl_getContractInstance` as the blocker, and I
measured that blocker myself on three programs. Neither entry has a `file:`, neither carries prose in
`status:`, and the second declares that it depends on the first rather than on anything of its own.

**The fifth entry is not a lowered bar.** `e2e_private_function_executes_in_browser` claims something
the four planned entries do not name — a real private function executing in a page — and it does not
substitute for either pending entry: nothing in it asserts anything about `transfer`, a transaction,
or a joined container. It is a different claim, and it is the third rung of the campaign's own ladder
for what M35 actually shipped.

**And the write-up says the same thing where a reader arrives first.** `PRIVATE-EXECUTION.md` §7's
first bullet is *"`transfer` does not run"*, the goal section leads with it, and `:next_steps:` opens
with it. That is what an honest partial looks like.

---

## Step 11 — WHAT DID NOT SURVIVE

Five, and none of them is a false headline.

1. **THE LADDER WAS CLAIMED FOR THREE PROGRAMS AND MEASURED FOR ONE.** Fixed; see Step 9. The claim
   itself is TRUE — re-taken, all three stop at the same rung.
2. **THE MUTATION MATRIX WAS DECLARED AGAINST A TREE THAT WAS NOT SHIPPED.** Honestly labelled, and
   still not a measurement of what ships: re-taken, **M1 is five failures and not four**.
3. **§5b'S PREDECESSOR HAD NO ARM.** The matrix's own M1 cannot see a refusing oracle that returns a
   plausible value *and records nothing* — the ledger's `refused` entry keeps `stoppedAtOracle`
   pointing at the right name. M10 added.
4. **AN ADDRESS COMPARED AGAINST A LITERAL.** Declared by the milestone as the lesser form, and
   correctly so; replaced with the request/echo comparison anyway.
5. **THE IMPL LOG'S STEP 3 IS THE PRE-`transient_array_service.ts` STATE** — 36 pxe files, 49 total,
   `check-drift` 630 identical — and was never brought forward. The shipped figures are 37, 50 and
   **631** (581 + 50), and `PROVENANCE.md`, `PRIVATE-EXECUTION.md` §2 and the `check-drift` row are
   all correct. Corrected in place with the reason beside it.

**And what survived unchanged, having been attacked:** the 68/3/49/16 count four ways, the 53-entry
control and its recorded reason, the 33/35 partition and its disjointness, 33 exercised = 33
implemented in both directions, the refusal-by-name property under a stealth mutation, all four
upstream validations, the three aborts' claims, the 50-file / 4,961-line vendoring at
`local-edits: none`, `check-drift` 22 → 24, `verify_provenance_complete` 68 → 70,
`@aztec/noir-acvm_js`'s empty dependency list, RI-64's narrowed identity claim, the M28 353 → 357 and
M33 246 → 248 attributions, the browser network evidence in both directions, and `still_there`'s
exit 5.

**No assertion in M35's shipped set was found to be incapable of failing.** The campaign's running
total does not move.

---

## Step 12 — THE SWEEP: M0–M35 at 11,744, delta +0, no hole

Measured 2026-08-30 **after my last commit**, `setsid`-detached in this repository's own dev shell
(node v24.19.0), one milestone at a time with nothing else running, `TMPDIR` and the log under
`~/.cache`, **72 markers for 36 milestones: no hole**, **34 of 36 exit 0**:

```
m0 156  m1 181  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 357  m29 127  m30 218  m31 421  m32 237  m33 248  m34 217  m35 212
                                                   CAMPAIGN TOTAL 11,744
```

**11,524 + 212 + 4 + 2 + 2 = 11,744 exactly**, `delta +0` against a reference table naming all four
moves in advance — M35's own 212, M28 353 → 357, M33 246 → 248, M1 179 → 181. Every one of M0–M34
came out at its reference value TO THE ASSERTION.

**M9 did not flake**: 807, rc 0, 1,284 s, immediately after m8's 177 s run, which is D19's standing
condition and it did not fire. M15 did not flake either (537, 383 s).

**The two non-zero exits are both already on the record, and both were read rather than assumed.**
M11 is **262 with nine failing assertions, split 5 / 2 / 2** across
`verify_carry_set_applies_to_upstream_head`, `verify_carry_ledger_complete` and
`verify_carry_exposure_measured` — the ninth-upstream-move signature exactly, count unchanged, not
repaired, `carry/` left at HEAD. M28 is **357 with ONE failing assertion and it is L0's**:
`verify_npm_pack_no_optional_native` got `ct-host diffsim drift node-host orchestration probe-mt
replay spike` where it pins the same list without `replay`. **That check's own count is unchanged at
54**, which is what says the pinned list moved and not a structure — so M35's +4 (in
`verify_browser_bundle_no_node_builtins` and `verify_browser_bundle_no_native_deps`) does not
interact with it at all.

**L0 and L1 contribute zero, and that is a measurement**: their six check names —
`verify_node_client_surface_narrow`, `test_node_client_refusals_distinguishable`,
`verify_client_uses_upstream_schema`, `e2e_fetch_settled_transaction`,
`test_missing_contract_artifact_refused`, `test_private_half_declared_absent` — appear **zero times
in the whole sweep log**, grepped one at a time.

**A sweep is a writer.** `carry/*.json` were checksummed before the sweep and were identical to the
digests taken at review start. `carry/rebase.json` and `carry/exposure.json` came out `79f597b2…` /
`3836c2b6…` — the same two post-sweep digests every run since M30 — and were restored from HEAD,
`sha256sum -c`, all four OK, `git status carry/` clean.

**No sweep was running when mine started or finished**, and nothing under `replay/` was touched.

---

## Final state

| repo | branch | HEAD | pushed | tree |
|---|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `8c21cfd` | yes, `metacraft-labs` | clean, `carry/` at its pre-sweep digests |
| `codetracer-specs` | `latest` | `d40b0989` | yes | clean (rebased onto five L0/L1-era commits, no conflict) |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | **not committed** | its one pre-existing edit, untouched |

Three commits in `aztec-avm-runtime`:

- `d88954b` — M35's delivered work, at its own 198.
- `9cb89b6` — the review's fixes, taking it to 212.
- `8c21cfd` — the sweep at 11,744 and the two rules.

`origin/dev` was fetched at review start, before the sweep and after the last commit and did not
move; the push is a fast-forward. `codetracer-specs`' `origin/latest` HAD moved five commits, and the
rebase was clean — grepped for all **four** diff3 markers afterwards, none.
