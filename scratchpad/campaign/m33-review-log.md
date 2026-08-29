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
