# M33 — The Wallet Protocol Boundary — REVIEW log

Written as I go.

## Step 0 — the state I inherited

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `d3c8228` (behind `origin/dev` `a2e0acd6` by 4) | 37 paths staged, nothing unstaged |
| `codetracer-specs` | `latest` | `84afae9e` | `Planned-Work/Aztec-AVM-Runtime.milestones.org` modified |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | one pre-existing edit — NOT to be committed |

`carry/` checksummed before anything: `exposure.json ec959b84…`, `rebase.json aaeb6877…`,
`overlap.json 6d4d275a…`, `series.json da229896…` — the two the sweep rewrites are at their
pre-sweep digests, so the implementation's restore held.

No sweep was running when I started (`ps` shows three stale `tail -f` processes from earlier
reviews and no `verify-m*`).

Working-tree backup: `git diff HEAD --binary` (336,384 bytes) plus a full tree copy at
`~/.cache/m33rev-tree-backup`.

---

## Step 1 — THE REBASE

`origin/dev` `a2e0acd6`, four L0 commits, `d3c8228` an ancestor. M33's 37 paths were committed to a
temporary commit, rebased onto `origin/dev`, and the commit unwound with `git reset --soft` so the
review continues on a staged tree — the workflow the campaign uses (implementation never commits;
the review commits after verifying).

**Exactly the two predicted conflicts**, `Justfile` and `REUSE-INVENTORY.md`, both pure appends
after the last M32 block. Resolved by keeping BOTH appends, L0's first then M33's. Nothing else
conflicted; L0's other seventeen paths are new files.

**The renumbering is complete and there is no duplicate.** Measured rather than read:
`REUSE-INVENTORY.md` carries **91 `### RI-<n>` headings, ids RI-01..RI-91, all distinct, none
missing, none repeated**. RI-86/RI-87 are L0's (`createAztecNodeClient`, `strictSurface`) and
RI-88..RI-91 are M33's. A repo-wide grep for `RI-8[5-9]|RI-9[0-9]` outside the inventory finds
**no M33 artefact citing RI-86 or RI-87**: the three vendored files' headers, `PROVENANCE.md`'s
F25–F27, `WALLET-BOUNDARY.md`, `CAMPAIGN-BRIEF.md` and the impl log all say RI-88..RI-91. The two
`RI-99`/`RI-999` hits are pre-existing negative controls in M14/M18 checks.

`just verify-m33` on the rebased tree: **224, 33 / 84 / 40 / 67, 4/4, exit 0.**

---

## Step 2 — CLAIM 1, the enumeration: SURVIVES, and it is stronger than claimed

Re-derived by me out of `~/.cache/aztec-m33-anchor` (materialised at `233d8e0993` from the fork's
object store): **provider 408 / 47,330, wallet 665 / 81,348, protocol 3 / 1,124, schema
298 / 31,205** — every figure to the unit.

**The third derivation is the right one for the NUMBER, and the CONCLUSION does not depend on it.**
I re-ran the same walker with `classify()` forced to treat every clause as a VALUE edge — derivation
2's semantics — and the provider half comes out **565 files / 68,906 lines, nine workspace packages,
and STILL reaches no DD-9 package**. So the separability finding survives type erasure being wrong
in either direction; only the size of the bill moves. (565 / 68,906 is derivation 2's published
figure to the unit, so that derivation reproduces too, as does the wallet half's 915 / 111,963.)
Where the erasure argument IS load-bearing is the protocol layer's zero: counting type clauses, the
`protocol` group is **480 files / 59,719 lines / 9 packages**, and the 3 / 1,124 / 0 that justifies
vendoring three files is a statement about the bundle and is correctly labelled as one.

**The residues are asserted at zero and the zeroes are readings.** `UNCLASSIFIED` is 0 in all four
groups and asserted; `UNPLACEABLE` is 0 in three and pinned at exactly 3 in the wallet half with the
pxe-side importer named. The six `UNRESOLVED` generated files are counted and two are named.

**The instrument can see the thing it reports absent** — the defect `CAMPAIGN-BRIEF.md` records
twice. All four DD-9 packages are in the walker's own workspace map (`@aztec/pxe`, `@aztec/native`,
`@aztec/world-state`, `@aztec/simulator`, from `yarn-project/{pxe,native,world-state,simulator}`),
so an edge to any of them enters `hits` rather than an unresolvable list. Demonstrated: the wallet
half under value semantics reports pxe and simulator, and under all-clause semantics reports all
**four**, from the same code path.

**One residue the walker cannot see, measured rather than assumed.** `CLAUSE_RE`/`BARE_RE` match
static `import … from`, `export … from` and bare `import '…'`. They do **not** match `import()` or
`require()`. Measured over all 408 provider-closure files: **zero dynamic `import()` with a literal
specifier and zero with a computed one.** So the absence is complete at this anchor — but it is
complete by measurement, not by construction, and nothing asserts it. See Step 6.

## Step 3 — CLAIM 2, the two answers: SURVIVES, both halves independently confirmed

The package half re-derived by me straight out of the object store, not through M33's walker:

| package | `dependencies` at `233d8e0993` |
|---|---|
| `@aztec/wallet-sdk` | aztec.js, constants, entrypoints, foundation, **pxe**, stdlib |
| `@aztec/wallets` | accounts, aztec.js, entrypoints, foundation, kv-store, protocol-contracts, **pxe**, standard-contracts, stdlib, **wallet-sdk** |
| `@aztec/aztec.js` | constants, entrypoints, ethereum, foundation, l1-artifacts, protocol-contracts, standard-contracts, stdlib (+ axios, tslib, viem, zod) |

`peerDependencies` is empty for `wallet-sdk`, so the pxe edge is a hard one. The closures the check
derives are **wallet-sdk 31, wallets 33, pxe 28, simulator 22, aztec.js 12**, matching §2's table.

**The both-ways control discriminates.** `@aztec/aztec.js` reaches none of the four over a closure
of twelve packages — a real walk, not an empty one — while `@aztec/wallet-sdk` and `@aztec/wallets`
both reach all four through the same walker in the same invocation.

## Step 4 — CLAIM 3, the tenth near-miss: SURVIVES, the rejection is measured

RI-91's `rejection-reason` is `cannot-reach-target` and it rests on a measurement the check re-takes
every run: `@aztec/wallets`' own `dependencies` names both `@aztec/pxe` and `@aztec/wallet-sdk`
(confirmed above, independently), and its closure is a superset of RI-88's. It is not a convenience
rejection: the package is enumerated, its file count (17) is recorded, its browser entry point is
named, and M34–M36 are pointed at it. `docs/examples/webapp-tutorial/` (68 files) is enumerated in
§1's table for the same reason.

---

## FINDING 1 — TWO OF `WALLET-BOUNDARY.md`'s NINETEEN FIGURES COULD NOT FAIL

`verify_provider_half_dd9_clean` §9 is the instrument the write-up's own first paragraph advertises:
*"nineteen figures, each looked for on the line that NAMES ITS SUBJECT rather than anywhere in the
file"* — M24's review's remedy for a check that matched `| <number> |` file-wide. The remedy is
applied at the ROW level and **the same defect is live one notch finer, at the FIELD level**:
`compare()` asked `wanted in row`, bare substring containment.

Measured by perturbing the document one figure at a time, fifteen perturbations, reading `BAD`:

- **the wallet entry's eager FILE COUNT.** The row is
  `| its eager set | **245.87 KB** gzipped across **8** files |`, and `245.87` supplies an `8`.
  A document saying **7** files where the artefact measures 8 gives `CHECKED 19, BAD <empty>` —
  green.
- **`@aztec/aztec.js` bytes in `browser.js`'s eager set**, which is `0`. Zero is a substring of every
  number containing a zero digit, so a document saying **900** passed. **This is the more dangerous
  of the two**: that zero is the whole of DD-11's reason for a separate entry point — *a page that
  attaches no wallet must not download a wallet protocol* — and it is the figure claim 4 rests on.

The other thirteen are caught. The remedy is a DELIMITED needle rather than a longer one:
`(?<![\d.,])<value>(?![\d.,])`, so a digit borrowed from a neighbouring figure cannot satisfy a
field. **All fifteen perturbations are red now**, the unmutated document is still `CHECKED 19,
BAD <empty>`, and `verify_provider_half_dd9_clean` is **84, 0 failures** — the fix adds no
assertion, it makes two existing ones capable of failing.

---

## Step 5 — CLAIM 4, dependency neutrality: SURVIVES, reproduced TO THE BYTE

I took the control build myself rather than reading the impl log's table: the three packages left
installed, the `wallet` entry removed from `BROWSER_ENTRIES`, its two budget rows removed, rebuilt
in this repository's own dev shell (node v24.19.0).

| entry | control build | pre-M33 reference (`WORKER-NODE.md` §5) |
|---|---|---|
| `browser.js` | 262,012 B = **255.87 KB**, 8 files | 255.87, 8 |
| `testing.js` | 286,644 B = **279.93 KB**, 10 | 279.93, 10 |
| `demo.js` | 287,872 B = **281.125 KB**, 10 | 281.12, 10 |
| `node/node.js` | 230,766 B = **225.36 KB**, 4 | 225.36, 4 |
| `worker.js` | 289,180 B = **282.40 KB**, 9 | 282.40, 9 |
| `worker-demo.js` | 290,284 B = **283.48 KB**, 11 | 283.48, 11 |
| TOTAL | **8,163.44 KB** | 8,163.44 (M32's review's corrected figure) |

**Every pre-M33 figure reproduces, and the demo row is the interesting one**: the control's demo
entry is 287,872 bytes, which is **281.125 KB exactly** — the M32 rounding tie the brief records.
JavaScript prints 281.13 and Python gives 281.12, and `WORKER-NODE.md` carries the CHECK's 281.12.
So "reproduces every pre-M33 figure to the assertion" is true, and the one place a reader might
think it is not is the tie the brief already documents.

So installing `@aztec/aztec.js`, `@aztec/entrypoints` and `@aztec/standard-contracts` moves **not
one byte** of any existing entry's eager set; the whole movement is esbuild re-partitioning around a
seventh entry point. Restored and rebuilt afterwards: the shipped `chunks.json` is byte-identical
per entry to the one I started with, so the harness is calibrated in both directions.

## Step 6 — CLAIM 5, the mutation matrix: SURVIVES on substance, three figures are stale

Re-ran all eight arms myself, `setsid`-detached, in the dev shell:

| arm | mine | impl log's table |
|---|---|---|
| M1 | 20 / 3 | 20 / 3 |
| M2 | **67 / 6** | 63 / 6 |
| M3 | **53 / 2** | 49 / 2 |
| M4 | 33 / 2 | 33 / 2 |
| M5 | **23 / 2** | 19 / 2 |
| M6 | **0 / 1 with a summary line**, `ArmTimeout: 'handshake.connect' exceeded 20000 ms` | same |
| M7 | **1 / 2**, `M7 held` | same |
| M8 | 84 / 1 | 84 / 1 |

**Every failure count matches; three assertion counts are four too low in the impl log**, and all
three are arms over `e2e_discovery_keyexchange_session`. The matrix was measured at Step 4, when
that check was 63; Step 5 removed an assertion that could not fail and added five, taking it to 67
and M33 to 224 — and the Step-4 table was never re-taken. The substance is unaffected (the arms red
on the same assertions) but it is "prose drifts from measurement" inside one log, so it is recorded
rather than left. `git status --porcelain` is empty after the run, so the restore held.

**M7's guard is load-bearing, and I made it say NO.** Under the fixed ordering the arm is 1 / 2 with
`M7 held`. I then reproduced the race the guard exists for — hollow the report, then `touch`
`browser/dist/wallet.js` so the bundle is newer than the hollow — and the check reports
**67 assertions, 0 failures, exit 0**, a fully green arm over a mutation that had been undone, with
the guard reporting `M7 DID NOT HOLD: the report was re-measured under the arm`. So the guard
produces both answers over the same instrument, and the cargo-mtime family's fifth appearance is
real and closed. **One notch weaker than the brief asks, and recorded:** the guard *diagnoses* but
does not *fail* — the harness prints `67 / 0` and the diagnosis side by side, where the brief says
"fail naming the cause instead of printing a result". It worked here because the implementer read
the log. Strengthened: the arm now exits non-zero after restoring.

---

## FINDING 2 — THE CORRECTED PXE-EDGE FIGURE WAS CORRECTED IN TWO PLACES AND LEFT WRONG IN TWO

M33's own Step 1b is a paragraph about this figure: derivation 2 reports **four** distinct
`(file, specifier)` pairs, derivation 3 reports **three** VALUE edges out of five clauses, and the
log says the four "would have been a figure that was right about its conclusion and wrong about its
measurement". `WALLET-BOUNDARY.md` §1 says three. `verify_provider_half_dd9_clean` asserts three.
And **two shipped artefacts still said four**:

- `browser/src/entry_wallet.ts:33` — *"the wallet half's has four, all named"*, in the comment on
  the entry point the milestone ships;
- `REUSE-INVENTORY.md` RI-88's `why:` — *"the wallet half's is 665 files and 81,348 lines with four
  pxe edges"*, which is worse, because it puts derivation 2's edge count beside derivation 3's file
  and line counts in the entry that justifies the vendoring.

Nothing re-derived either. Both corrected — and because a figure that has already rotted once is
the one to bind, both counts are **derived and compared against the document now**: the walker emits
`PXE_CLAUSE` for every `@aztec/pxe` clause with its kind (five: three VALUE, two TYPE, exactly §1's
list) beside the `PXE_EDGE` value subset, the check writes both into `closure.tsv`, and §9 compares
them. `CHECKED` goes **19 → 21** and the assertion count does **not** move — 84 — because BAD,
MISSING and CHECKED are three assertions however many figures they cover.

**The document carries the two counts on separate LINES on purpose.** With both on one line, a swap
satisfies both needles, which is M24's review's row-swap finding at field level. Verified: the swap
(3 clauses / 5 edges) is now caught on both, and each figure perturbed alone is caught.

---

## FINDING 3 — CLAIM 7: THE CONFIG-LEVEL ASSERTION IS NOT SUFFICIENT, AND I MEASURED HOW MUCH

The question the task poses is whether `verify_provider_half_dd9_clean`'s browser-*shape* assertion
on the metafile stands in for a browser run. **It does not, and the gap is a measurement rather than
an opinion.**

**First: nothing evaluated `wallet.js` in a browser.** Grepped — no `.html` in the repository
references it, and every reading of it is `node --input-type=module -e "await import(…)"` or
`tools/run_wallet_arms.mjs`. `smoke_browser_headless_full_flow` does drive Chromium, over
`browser.js`.

**Then the plant.** A metafile records IMPORTS. A **free identifier** is not an import:

```ts
const _nodeOnlyProbe = setImmediate;      // Node has it as a global; a page does not
```

at the top of `port_wallet_provider.ts`. It is not `Buffer` and not `process`, so
`browser/src/globals.js`'s injection does not supply it and `verify_browser_bundle_builds`'s
free-identifier scan does not name it. Rebuilt — the build is green — the results are:

| | |
|---|---|
| `node -e "await import('./wallet.js')"` | **OK, 19 exports, `READY_TIMEOUT_MS=15000`** |
| the same file, in Chromium 150 | **`ReferenceError: setImmediate is not defined`** |
| `just verify-m33` | **224 assertions, 4/4, exit 0** |
| `verify_browser_bundle_no_node_builtins` | 64 / 0 |
| `verify_browser_bundle_no_native_deps` | 44 / 0 |
| `verify_verification_code_unreachable_from_browser` | 37 / 0 |
| `smoke_browser_headless_full_flow` | 50 / 0 |

(The first `verify-m33` run over the plant reported one failure and it was **not** browser shape — it
was `wallet-own-kb expected 16.25`, the document size figure moving by the planted 60 bytes. With
the two size figures updated to match, all four checks are green: 33 / 84 / 40 / 67, exit 0, over a
bundle that dies on the first line a page evaluates. That is the exact statement.)

**So M33 owed a browser arm, and it is added** — deliberately the smallest one that closes this gap.
`tools/run_wallet_browser_arm.mjs` reuses M27's harness unchanged (`serveDirectory`,
`launchChromium`, `openPage`, `page.eval` — no new machinery), serves a copy of `browser/dist`, and
loads a probe page that `import()`s `./wallet.js`. `verify_provider_half_dd9_clean` §10 asserts:

- it EVALUATED, with its own presence check first and a `die` naming the Chromium error behind it —
  calibrated: read in the other order the check dies at `m33_absent` naming six absent fields, which
  is true and is the wrong diagnosis;
- the module was FETCHED over HTTP (so the probe measured the artefact, not an inline copy);
- the exports the PAGE sees are the operations Node reads out of the same file — two engines, two
  readings, one artefact;
- the protocol enum crossed with all eleven members;
- the page HAS a `document` (so this is a page, asked of it rather than inferred — M32's finding),
  a `MessageChannel`, and **`crypto.subtle`**, which is the one Node genuinely cannot speak to,
  because a browser withholds SubtleCrypto outside a secure context and Node has no such rule;
- **the CONTROL is the plant, kept**: a second served site whose `wallet.js` carries that one free
  identifier, which the same probe, the same server and the same browser must report as a
  `ReferenceError` naming `setImmediate`.

Calibrated in both directions: with the plant re-applied the check reports
`FAIL the wallet entry EVALUATES in a page  expected [true], got [false]` and dies naming the
Chromium error; restored, it is green.

**What is NOT owed, and this is a judgment I am making explicitly**: the handshake does not need to
run in Chromium. Its substance is a `MessagePort` and WebCrypto, and Node 24 and the browser
implement both to the same specifications; running it against the BUILT bundle in Node is a real
measurement of the artefact. `WALLET-BOUNDARY.md` §5 remains the right boundary and is rewritten to
say what is now observed and what is still inferred.

## FINDING 4 — AN ABSENCE AS WIDE AS ITS SPELLINGS, AND THE SPELLINGS WERE NOT WRITTEN DOWN

`_m33_closure.py` matches static `import … from`, `export … from` and bare `import '…'`. It does
**not** match `import()` or `require()`, and nothing said so. "The provider half reaches no
`@aztec/pxe`" is an absence, and an `import('@aztec/pxe')` added upstream would leave every pxe
assertion green over a graph that reaches it.

Measured over all 408 provider-closure files: **zero dynamic imports of either shape** — so the
enumeration is complete at this anchor. But complete by measurement, not by construction, and
nothing recorded it. The census is emitted and asserted now, with **two** controls: the WALLET half
has **three** dynamic imports (all lazily-loaded JSON contract artifacts, named), so the scanner is
seen finding them in a real tree; and the scanner is run over its own fixture and must match both
shapes there before its zero is believed, which is M29's review's remedy for a needle believed about
an artefact without being seen to match anything.

---

## Where the counts stand after the review's additions

`verify_provider_half_dd9_clean` **84 → 105**: +14 for §10's browser arm (13, plus one for splitting
`m33_absent` so the verdict is read before the fields that depend on it) and +7 for §8's
dynamic-import census and its two controls. **M33 is 245** (33 / 105 / 40 / 67), 4/4, exit 0.

Nothing else moved, measured rather than assumed after the additions: `verify_named_checks_exist`
**9**, `just check-repo-hygiene` **28**, `verify_no_pipeline_predicates` **69**,
`verify_reuse_inventory_complete` **19**, `verify_provenance_complete` **68**.

---

## FINDING 5 — "THE MESSAGE-FLOW COMMENT IS UPSTREAM'S, UNCHANGED" IS FALSE, IN THREE PLACES

RI-90's whole decision is *"the SHAPE is reused and the code is not"*, and the sentence offered as
evidence that the shape really is upstream's appears three times — in `REUSE-INVENTORY.md` RI-90
(*"the message-flow comment in `port_connection_handler.ts` is upstream's, unchanged, because the
flow is unchanged"*), in `WALLET-BOUNDARY.md` §3 (*"its message-flow comment is upstream's,
unchanged"*), and in `port_connection_handler.ts`'s own header (*"The message flow comment below is
upstream's, unchanged"*). Nothing checks it. Compared against
`yarn-project/wallet-sdk/src/iframe/handlers/iframe_connection_handler.ts` at the anchor, out of the
object store:

| upstream | ours |
|---|---|
| `parent → DISCOVERY            → show approval UI → send DISCOVERY_RESPONSE` | `dApp -> DISCOVERY            -> approval -> DISCOVERY_RESPONSE` |
| `parent → KEY_EXCHANGE_REQUEST → ECDH             → send KEY_EXCHANGE_RESPONSE` | `dApp -> KEY_EXCHANGE_REQUEST -> ECDH     -> KEY_EXCHANGE_RESPONSE` |
| `parent → SECURE_MESSAGE       → decrypt → Wallet → encrypt → SECURE_RESPONSE` | same, ASCII arrows |
| — | **`dApp -> PING                 -> PONG`** |
| `parent → DISCONNECT           → terminate session` | `dApp -> DISCONNECT           -> terminate` |

Four lines against five, `parent` against `dApp`, Unicode arrows against ASCII, and three of the
five re-worded. It is a **paraphrase**, and the added PING/PONG line is a real improvement rather
than an error — upstream's handler DOES implement it (`case WalletMessageType.PING` and the `PONG`
reply are both in that file); it is upstream's *comment* that omits it.

**The substantive claim survives and the evidence offered for it did not**, which is the shape
`CAMPAIGN-BRIEF.md` records for M23's wall-clock needles. Compared member for member, the
correspondence is real: upstream has `constructor / start / stop / approveDiscovery /
rejectDiscovery / terminateSession / getPendingSessions / handlePing / handleDiscoveryRequest`, and
ours has all nine (two renamed `pendingSessions` and `onPing`/`onDiscovery`) plus the four M33
declares as its own additions — `activeSessions`, `disclosure`, `refusals`, `refuse`.

All three sentences corrected to what is true. **A comment that claims to be a copy is a claim, and
it needs the same evidence as any other**; this one was three copies of an unchecked sentence.

---

## Independent re-derivations I took rather than read

| claim | how I re-took it | result |
|---|---|---|
| the three vendored files are byte-identical to the anchor | `git show <anchor>:…` against the local copy with the provenance header stripped by hand, not by the check's own stripper | **identical**, 204 + 603 + 317 = **1,124 lines** exactly |
| `@aztec/wallet-sdk`'s `dependencies` names `@aztec/pxe` | straight out of the object store, and again from the npm registry at the published pin | both: **yes**, and `peerDependencies` is empty, so the edge is hard |
| `@aztec/aztec.js` reaches none of the four | same two sources | both: **none** |
| exactly three packages added, no `.node` binary | the lock diff and `find … -name '*.node'` over the three installed trees | **3 packages, 0 `.node`, no `optionalDependencies`** |
| the new dependency uses the declared pin | `orchestration/package.json` against `pins.json`'s `npm.deletion_era` | all five at `5.0.0-nightly.20260626` |
| RI-90's divergence 1 is real | upstream's handler at the anchor passes `appId` straight to `getWallet(appId, chainInfo)` with no comparison to the session's | **real, and stricter as declared** |
| §4's disclosure is recorded BEFORE dispatch | read at `port_connection_handler.ts:400-407`, above the `schemaHasMethod` dispatch | **yes** |
| the M18 pin moved rather than loosened | the diff: `assert_eq` on the full five-package list, not a `>=` or a subset | **exact, not loosened** |
| M33's checks carry none of the campaign's vacuity shapes | scanned all four checks + the lib for self-comparisons, `assert_ge … 0`, and pipeline predicates | **none** |

---

## Step 7 — THE REBASED SWEEP: M0–M33 at 11,303, delta +0

`setsid`-detached, `direnv exec <aztec-avm-runtime>` — this repository's own dev shell, node
v24.19.0 — one milestone at a time with nothing else running, `TMPDIR` and the log under `~/.cache`,
started 09:52, **68 markers for 34 milestones: no hole**, 31 of 34 exit 0. Taken **after** the
rebase and after my last commit.

```
m0 156  m1 179  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 262  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 218  m31 421  m32 234  m33 245
                                                       CAMPAIGN TOTAL 11,303
```

**Every one of M0–M32 at its reference value TO THE ASSERTION**, and 11,282 + 21 = 11,303 exactly,
`delta +0` against a reference table naming the move in advance.

### L0's contribution, separated — and it is ZERO

**Measured, not assumed.** L0's three checks are in `just verify-l0`, which no `verify-m<N>` recipe
invokes: `verify_node_client_surface_narrow`, `test_node_client_refusals_distinguishable` and
`verify_client_uses_upstream_schema` appear **zero times in the whole sweep log**. So the entire
11,303 is M0–M33's, and L0's own **188** is a separate number that is not in it.

**And the 188 was re-taken rather than quoted.** `just verify-l0` first exited 1 with
`ERR_MODULE_NOT_FOUND: '@aztec/stdlib'` — `replay/node_modules` was not installed in this workspace,
which L0's own Justfile comment names as its one precondition, so that was an environment fact about
this checkout and not a finding about L0. With `npm ci` run in `replay/` (its `node_modules` is
gitignored, so the tree stays clean), **`just verify-l0` is 188, 3/3, exit 0 — 74 / 52 / 62, its
declared split to the assertion.**

### M33's own 245, and where the 21 came from

33 / **105** / 40 / 67, declared at 224 (33 / 84 / 40 / 67). All 21 are in
`verify_provider_half_dd9_clean`: **+14** for §10's browser arm (13, plus one for splitting
`m33_absent` so the verdict is read before the fields that depend on it) and **+7** for §8's
dynamic-import census and its two controls. The other two review fixes add **no** assertion — the
document comparer's needle became delimited and grew from 19 figures to 21 under the same three
assertions.

### M1 179 — claim 8's attribution, verified mechanically

`verify_provenance_complete` 64 → 68, and the mechanism was read out of the check rather than
believed: **one `assert_true "single-file row <f> is tracked"` per single-file `PROVENANCE.md` row**
(F25, F26, F27 → +3) and **one `pass "<id> justifies vendoring"` per distinct inventory id the
mapping cites** (RI-88 is new → +1). 3 + 1 = 4, exact in both parts. L0 touches neither file.

### The three non-zero exits, and only one is this repository's own work

**M9 = 807, four failing assertions, and the COUNT is the reference split exactly** —
140/143/113/73/126/83/129. This time the V8/WASI stdout truncation hit the **fallback EVENT stream**
rather than the step transcript, so both comparers ran and neither refused:
`truncated-after-10617-lines-last-key-events.burn.10412`. That is the second sighting on the events
stream (M29's review recorded 15,306) beside the seven on `steps`. **Re-run alone: 807, 7/7, exit 0**,
the reference split exactly. Not a regression, and the settled procedure worked.

**M11 = 262, nine failing assertions** — the recorded ninth-upstream-move signature. The count is the
signature and it is unchanged. Not repaired; `carry/` left at HEAD.

**M28 = 353, ONE failing assertion, AND IT IS L0'S.**
`verify_npm_pack_no_optional_native` pins the tracked `package.json` list EXACTLY — *"the three
shipped plus the four harness trees"* — and got `ct-host diffsim drift node-host orchestration
probe-mt **replay** spike`. `replay/package.json` was added by L0's `541bf5f`. The COUNT is unchanged
at 353, which is what says it is a pinned list rather than a structure, and L0's own log enumerates
the repo-wide checks it re-took with this one not among them. **Recorded and deliberately NOT
fixed**: a second track editing the first track's expectations is the collision this campaign has
already paid for three times.

### A sweep is a writer

`carry/rebase.json` and `carry/exposure.json` were `aaeb6877…` / `ec959b84…` before, came out
`79f597b2…` / `3836c2b6…` — the same two post-sweep digests every run since M30 — and were restored
from HEAD, confirmed by `sha256sum -c`, all four OK.

### `noir-wt4-webpage` was not touched

`f0e7edcd2` on `wasm/webpage`, its one pre-existing edit, zero published refs. No commit, no push.
