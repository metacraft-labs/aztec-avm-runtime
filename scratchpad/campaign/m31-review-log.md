# M31 — `avm-transpiler` to WebAssembly — REVIEW log

Written as I go. Serialised: mutation work first, sweep last, nothing concurrent.

Reference: implementation declares **M31 = 376** (123 / 59 / 114 / 80), sweep **10,775**,
`delta +0`, 31 of 32 exit 0, M11 259 -> 262.

---

## Step 0 — state at start of the review

| repo | branch | HEAD | tree |
|---|---|---|---|
| `aztec-avm-runtime` | `dev` | `a76f016` | M CAMPAIGN-BRIEF.md, M Justfile, M REUSE-INVENTORY.md, M carry/series.json + M31's untracked files |
| `aztec-packages` | — | `ee3c0528d5` | clean |
| `noir` | `blocktracer` | `4d2381630` | clean |
| `codetracer-specs` | — | `bc51a2d3` | M milestones.org, M upstream-bugs/SERIES.md, ?? upstream-bugs/aztec-transpiler-core-ffi/ |

`carry/` digests before any run of mine:

```
ec959b8477513b55…  carry/exposure.json      <- the pre-sweep digest the impl log names
6d4d275af39a1e65…  carry/overlap.json
aaeb68772fd333ba…  carry/rebase.json        <- the pre-sweep digest the impl log names
da2298960875b93e…  carry/series.json
```

So the implementation's "a sweep is a writer, and the two files were restored" is TRUE as found.

---

## Step 1 — the four checks, reproduced

`just verify-m31` in this repository's own dev shell, nothing else running:

```
verify_transpiler_wasm_output_identical_to_native: 123 assertion(s), 0 failure(s)
test_transpiled_contract_registers_and_executes:    59 assertion(s), 0 failure(s)
verify_transpiler_rung1_mapping_survives:          114 assertion(s), 0 failure(s)
verify_transpiler_native_build_unaffected:          80 assertion(s), 0 failure(s)
```

123 + 59 + 114 + 80 = **376**, the declared figure to the assertion. Then re-run with
`M31_ARMS_REFRESH=1`, which re-measured the arms (native binary, module in node, module in a fresh
Chromium): 123 / 0 again.

---

## Step 2 — BYTE-IDENTITY, ATTACKED

### 2.1 Reproduced with an instrument of my own

`rev_indep.mjs`: my own `WebAssembly.compile`/`instantiate`, my own memory marshalling through the
five `avmt_*` exports, my own `execFileSync` of the native binary into my own directory, my own
digests. **No repository code on the path.**

```
branches        wasm=957ac0230716cf53 (3542B)  native=957ac0230716cf53  IDENTICAL
counter         wasm=605843d672ec9cf3 (3277B)  native=605843d672ec9cf3  IDENTICAL
counter_variant wasm=53527fc0a45589a0 (3312B)  native=53527fc0a45589a0  IDENTICAL
memory          wasm=a078c6a01a43c91d (2403B)  native=a078c6a01a43c91d  IDENTICAL
multi           wasm=32e1afd7e20bad1c (4404B)  native=32e1afd7e20bad1c  IDENTICAL
private_only    wasm=2323b39764e7fe38 (1383B)  native=2323b39764e7fe38  IDENTICAL
reverting       wasm=170b74ea05d06b72 (2937B)  native=170b74ea05d06b72  IDENTICAL
reachedImports []
```

**The browser's digests equal the native digests I produced myself** — the fresh arm report's
`identity.<n>.browserSha256` is `605843d672ec9cf3…` for `counter`, which is the number my own
`execFileSync` of the native binary produced. So the browser half is cross-checked against a
native run this review took, not against the runner's.

`cmp` over the three output files, byte for byte, agrees for all seven.

**The comparison covers the WHOLE artifact.** The digest is `sha256` of the entire output JSON —
native writes a file and it is hashed whole; the page returns the whole buffer base64 and it is
hashed whole. **There is no exclusion list at all**, so M26's "an exclusion justified by the bug it
was hiding" has nothing to hide behind here. This is the strongest part of the milestone.

### 2.2 The control is SUFFICIENT — and I strengthened it

`counter` vs `counter_variant` is `+ 1` vs `+ 2`, and it does land inside the compared region.
Stronger than that, all seven fixtures have seven DISTINCT native digests, asserted
(`assert_eq "every fixture transpiles to a DIFFERENT artifact"`), so the comparer is calibrated
seven ways and not one.

I ran the perturbation the brief asked for anyway — one that changes CONTROL FLOW, not a constant:
`counter`'s loop body wrapped in `if i % 3 == 0 { … } else { acc = acc * 2 }`. Compiled with the
same `nargo`, transpiled by both producers:

```
counter_cf    wasm=7fdb6e2242d7bbd5 (3256B)  native=7fdb6e2242d7bbd5  IDENTICAL
counter_same  wasm=f819d11906a3acc1 (3267B)  native=f819d11906a3acc1  IDENTICAL
```

and the AVM bytecode itself moved **204 → 135 bytes** with a different digest, so the perturbation
reaches the transpiled region and is not folded away. Byte-identity survives a control-flow change
and the comparer discriminates it.

### 2.3 THE CLAIM THAT DID NOT SURVIVE — "three independent producers" is TWO

`tools/run_transpiler_arms.mjs` copies **`$M31_MODULE` itself** into the served site
(`copyFileSync(MODULE, SITE/assets/avm_transpiler_wasm.wasm)`) and the node arm reads the **same
file**. Measured: the arm report's `arms.browser.modules.sha256` is
`765197c134328c4c…`, which is `module.sha256`, which is the file node compiled. So node and
Chromium run **the same wasm bytes on the same engine family (V8)**. WebAssembly is deterministic;
their agreement is automatic modulo the host-side glue (node writes into `memory` directly, the
page goes through `wasm_host.mjs`'s `callWithString`). That glue difference is worth something —
it is not a producer.

**Genuinely independent producers: two.** Native x86-64 through `avm_transpile_file` (a separate
process, real files) versus wasm32 through `avm_transpile_bytecode` (in memory). The check's own
header says "the digests are taken at three independent points"; the milestone says "three
independent producers". The right statement is *two producers and three measurement points*.

### 2.4 …AND THE TWO PRODUCERS ARE MORE INDEPENDENT THAN CLAIMED, FOR A REASON NOBODY DECLARED

`avm-transpiler-wasm/` is its own workspace root with a `path` dependency on `avm-transpiler`, and
**it has no `Cargo.lock` in this repository**. `build_avm_transpiler_wasm.sh` runs a bare
`cargo build --release --target wasm32-unknown-unknown` in it — no `--locked`, no lock copied from
upstream — so cargo resolves the whole graph fresh from crates.io at build time. Read out of the
two builds' own `.d` files:

| crate | NATIVE build (upstream's pinned lock) | WASM build (fresh resolution) |
|---|---|---|
| getrandom | **0.4.1** | **0.4.3** |
| chrono | 0.4.43 | 0.4.45 |
| flate2 | 1.1.9 | 1.1.10 |
| serde_json | 1.0.149 | 1.0.151 |
| base64 | 0.23.0 | 0.23.1 |
| wasm-bindgen | — | 0.2.127 |

Three consequences, and they do not all point the same way.

1. **It strengthens byte-identity.** The two producers use different `serde_json` (the JSON writer)
   and different `flate2` (the DEFLATE that compresses `debug_symbols`) and still produce the same
   bytes. That is a better result than the milestone claims.
2. **It falsifies a stated claim.** `avm-transpiler-wasm/Cargo.toml` says in as many words: *"the
   two builds differ in target and in nothing else."* They differ in at least six transitive crate
   versions, two of which are on the serialisation path the comparison runs over.
3. **The wasm module is not pinned and not reproducible.** A cold build next week resolves whatever
   is newest and semver-compatible. The published module size (5,196,936 bytes) and the import name
   `__wbg___wbindgen_throw_bb96b2010945f0bc` are both functions of that floating resolution — and
   they already drifted inside this milestone (§2.3 of the impl log records 4,970,171 bytes for the
   same build). The build stamp does not cover it either: `BUILD_WANT` hashes `.rs`/`Cargo.toml`/
   `config.toml` plus `noir/noir-repo/Cargo.lock`, and **neither `avm-transpiler/Cargo.lock` nor
   the shim's lock is in it**. This is the campaign's "a pin that is not published is not a pin"
   family one level out: there is no pin.
4. **The getrandom reasoning cites a version the build does not use.** `.cargo/config.toml`,
   RI-79 and the milestone all argue from *getrandom 0.4.1*'s backend list
   (`src/backends.rs:10-38`, `src/backends/unsupported.rs`) and quote 0.4.1's `compile_error!`.
   The module links **0.4.3**. The conclusion holds — the import section has no
   `getRandomValues` binding — but the evidence offered is about a different version.

---

## Step 3 — the four imports, read with a THIRD instrument

Not the repository's walker and not the runner's `WebAssembly.Module.imports`, but `wasm-objdump`
out of the dev shell's wabt 1.0.41:

```
Import[4]:
 - func[0] <- __wbindgen_placeholder__.__wbindgen_describe
 - func[1] <- __wbindgen_placeholder__.__wbg___wbindgen_throw_bb96b2010945f0bc
 - func[2] <- __wbindgen_externref_xform__.__wbindgen_externref_table_set_null
 - func[3] <- __wbindgen_externref_xform__.__wbindgen_externref_table_grow
wasm-validate: VALID
```

Four, exactly those, **no `__wbg_new0`, no `__wbg_getTime`, no `wasi_snapshot_preview1`, no `env.`,
no `getRandomValues`**. `reachedImports` is `[]` in my own node instantiation and `[]` in the
report's Chromium arm, against a declared four. **Claim 4 holds.**

---

## Step 4 — the third blocker, verified and it is as reported

- `aztec-packages/noir/noir-repo` is an **EMPTY DIRECTORY** — `ls -A` returns 0 entries.
- `.gitmodules` declares it (`noir-lang/noir.git`, `shallow = true`); `git ls-tree` at **both**
  `233d8e0993` and HEAD gives `160000 commit 40d6574f851d926f93e0c3a271bac3e6e82ac905`.
- That commit is `chore: Release Noir(1.0.0-beta.26) (#13392)`.
- All five path dependencies point into it (`acvm`, `noirc_abi`, `noirc_artifacts`,
  `noirc_evaluator`, `noirc_frontend` — `avm-transpiler/Cargo.toml:16-20`).
- `git diff --stat 233d8e0993 HEAD -- avm-transpiler/` is empty.

So "nothing in this workspace could build the transpiler at all before this milestone" is true, and
it is the reason nobody had attempted it. **Worth recording prominently, as the brief said.**

### 4.1 A CLAIM THAT DID NOT SURVIVE, inside that one

The impl log §0.1 says: *"`noir` has **zero** `refs/remotes/*` refs, so the
`m24_published_refcount` shape cannot be applied to it here."* Measured:

```
git for-each-ref refs/remotes | wc -l   ->  57       (origin = metacraft-labs/noir)
remote refs containing 40d6574f…        ->  refs/remotes/origin/wasm/reconcile-then-extract
                                            refs/remotes/origin/wasm/upstream-clean
```

The shape applies and it answers **yes**. The conclusion — the pin is published — survives and is
in fact *stronger* than the log claims; the stated fact is false. (`git tag --points-at` is empty,
so "an upstream release tag" is also loose: it is the release COMMIT, with no tag object here.)

---

## Step 5 — the rung, verified over the fresh browser output

Eight AVM functions across the corpus, **seven on rung 1**, `private_only`'s appended revert
dispatch on rung 3 and labelled:

```
branches/public_dispatch         rung=1 pcs=56 pos=56 unpos=0 bc=558 [64, 489]  input [12..90]
counter/public_dispatch          rung=1 pcs=27 pos=27 unpos=0 bc=204 [64, 194]  input [12..38]
counter_variant/public_dispatch  rung=1 pcs=26 pos=26 unpos=0 bc=199 [64, 189]  input [12..37]
memory/public_dispatch           rung=1 pcs=15 pos=15 unpos=0 bc=144 [64, 134]  input [12..26]
multi/public_dispatch            rung=1 pcs=10 pos=10 unpos=0 bc=119 [64, 109]  input [12..21]
multi/second_public              rung=1 pcs=1  pos=1  unpos=0 bc=74  [64,  64]  input [12]
reverting/public_dispatch        rung=1 pcs=31 pos=31 unpos=0 bc=241 [64, 217]  input [12..42]
private_only/public_dispatch     rung=3 pcs=0                bc=22   (labelled)
```

Controls: `notRekeyed` = 27 avm pcs, 27 positioned by the real map, **0 by the stale one**;
`appendedRevertDispatch` rung 3 "brillig_locations is empty"; `noDebugSymbols` rung 3 "carries no
debug_symbols". Both rung-3 artifacts are LABELLED and neither is accepted. **Claim 3 holds.**

One honest weakness, not a defect: the stale map's own `rungFor` verdict is **1**
(`controls.notRekeyed.staleRung == 1`), because its keys 12..38 are inside a 204-byte bytecode. So
§1's *"the highest key is inside the transpiled bytecode"* and *"the lowest is past the dispatch
preamble"* are both satisfied by a map that was never re-keyed. The load-bearing instrument is §2's
key-SET comparison, and the M3 mutation arm's 22 failures are what say so.

---

## Step 6 — A CLAIM THAT DID NOT SURVIVE: the corpus DOES exercise `brillig_procedure_locs`

The milestone's Outstanding Tasks says:

> *"`brillig_procedure_locs` is still not re-keyed upstream … **None of the seven fixtures has a
> compiled procedure**, so the hole is not exercised here either — stated rather than left to look
> like coverage."*

Measured, by decoding `debug_symbols` out of the browser's own output files:

| fixture | `brillig_procedure_locs` in the OUTPUT | the INPUT's |
|---|---|---|
| `branches` | `{"0": {"11": [98, 100]}}` | `{"0": {"11": [98, 100]}}` |
| `reverting` | `{"0": {"11": [44, 46]}}` | `{"0": {"11": [44, 46]}}` |
| the other five | `{}` | `{}` |

**Two of the seven have a compiled procedure**, and the transpiled artifact carries the map
**byte-identical to the input's** — key `11`, a Brillig opcode INDEX, sitting in the same
`DebugInfo` whose `brillig_locations` were re-keyed to AVM byte offsets 64..489. That is
`SOURCE-MAPPING.md` §2.4 hole 1 demonstrated **exactly**, on this milestone's own artifacts, where
§2.4 had it only as a value-range argument over `AvmTest`. The hole is exercised; the statement
that it is not is false. Nothing in the milestone asserts it either way, so nothing was masking a
failure — but the sentence claims a coverage boundary the corpus does not have.

(It does not touch the rung claim: `ct-host/src/source_map.ts` reads `brillig_locations` only and
says so at `:40` — *"`brillig_procedure_locs` … is deliberately untouched."*)

---

## Step 7 — execution, verified over the fresh report

```
counter    processed  revertCode 0 / OK        41 instr  block 1  bc 204
reverting  processed  revertCode 1 / Reverted  41 instr  block 1  bc 241  reason "TX reverted"
branches   processed  revertCode 0 / OK        71 instr  block 1  bc 558
memory     processed  revertCode 0 / OK        29 instr  block 1  bc 144
```

`revertCode` is read off upstream's `ProcessedTx` (`transpiled_contract_driver.ts:287`) and
`instructionsExecuted` off M12's `avm_steps_count()` (`:248`). The counts are per-simulation, not
cumulative — 41 / 41 / 71 / 29 rather than 41 / 82 / 153 / 182 — so the export is reset per run and
the numbers are four measurements. **Claim 5 holds**, and M29's lesson is applied properly: a
reverting transpiled contract IS caught, both directly (`assert_eq "and it did NOT revert" 0`) and
through the non-constancy control.

---

## Step 8 — the enumeration: the numbers that reproduce and the ones that do not

**Nothing in the repository asserts any of them.** Grepped `verification/` and `tools/` for
`1,908`/`1908`, `2,293`/`2293`, `425`, `228`, `189`, `253`: not one appears in a check. The
milestone's FIRST deliverable is prose only. That is the "a figure nobody re-derives rots" family
by construction, and it is the reason the two results below could sit unnoticed.

**The closure split REPRODUCES.** `cargo metadata --filter-platform wasm32-unknown-unknown` run by
me over the materialised tree, through the implementation's own `m31-closure.py`:

```
from $TREE/avm-transpiler   ->  full 227   LINKED 188   HOST-ONLY 39
+ the shim itself as root   ->  full 228   LINKED 189   HOST-ONLY 39      == the published figures
```

(Running it from the shim directory instead gives 241 / 199 / 42, because the shim's *fresh*
lock resolves newer versions and pulls in `defmt-macros`, `cfg_aliases`, `winnow` — which is
§2.4's unpinned-resolution finding showing up a second time.)

**The 425/2,293 narrowing does NOT reproduce.** Unioning every `.rs` path out of every `.d` file
cargo emitted under `target/wasm32-unknown-unknown/` and running the implementation's own
`m31-census-linked-files.py` over it:

| | published | re-derived here |
|---|---|---|
| files compiled | **2,293** | **2,435** |
| fs | 81 | 78 |
| env | 37 | 34 |
| time | 138 | 139 |
| thread | 165 | 168 |
| process | 4 | 4 |
| **TOTAL** | **425** | **423** |

The per-package concentrations DO match (rayon 60 + rayon-core 24 = 84, jiff 50, der 38, chrono 18,
noirc_frontend 25 — all four figures the milestone quotes), so this is the same measurement taken
over a slightly different file set, not a different measurement. But **a larger file set produced a
smaller site count**, which the same scanner cannot do — so the two `linked-files.txt` differ in
composition and the published pair is not reproducible from the artefacts on disk. `linked-files.txt`
itself is not in the repository, so there is nothing to re-derive it from. *The methodological move
is sound — a `.d` union really is the set of files the compiler read, and narrowing to it is the
right instrument. The number attached to it is not re-derivable.*

**The 253 host-only sites are excluded with a reason, but the reason is per PACKAGE and not per
site**, which is the right granularity and is not what the milestone's wording implies: one class
reason ("runs in the compiler, never in the module") over 39 packages, with the seven that hold the
sites named. That is defensible; the wording "named and excluded with a reason rather than dropped"
reads as stronger than what was done.

**The transpiler's own ten sites carry individual verdicts and they are correct.** `main.rs`'s
seven are in the bin target, which a cdylib does not link — confirmed: the module exports
`avm_transpile_file` and `avm_transpile_bytecode` and no `main`. `lib.rs`'s three are inside
`avm_transpile_file` only, and `avm_transpile_bytecode` reaches none of them — confirmed by reading
the crate at the anchor.



---

## Step 9 — the upstream contribution, RE-RUN

`./verify.sh <aztec-packages> --noir <a clean git-archive of 40d6574f> --artifacts <the seven> --wasm`,
in this review's own invocation, with both worktrees built from scratch:

```
verify.sh: 37 assertion(s), 0 failure(s)
```

**Clean on its first run**, unlike M30's analogous script. What it actually did, checked rather
than trusted:

- both worktrees really were built (§3's two `cargo build --release` from cold);
- §4 ran over a real corpus of **7** and the digests it produced are the same seven this review
  produced from the materialised tree — `605843d6…` for `counter` in both — so the pristine
  upstream checkout and the campaign's build tree agree;
- **the discriminator was exercised**: `the pristine crate does NOT build for
  wasm32-unknown-unknown` and `…and it fails on exactly the import this patch removes` (a grep of
  the build log for `unresolved imports \`libc::c_char\``, not merely a non-zero exit), and
  `the patched crate DOES build` exit 0;
- the refusal path: run WITHOUT `--noir`, it stops at §2 naming `noir/noir-repo is not populated`
  and the remedy, rather than failing four crates deep;
- `aztec-packages` is left with the same **89** worktrees and a clean tree, both times.

**One small thing that did not survive.** `PR.md` and both re-derivations say the diff is
**+3 / -7**. `git apply --stat` says **3 insertions(+), 8 deletions(-)** — the patch removes a blank
line (patch line 66) and `grep -c '^-[^-]'` cannot see it. Both re-derivations (`verify.sh` §1 and
`verify_transpiler_native_build_unaffected` §1) use that same needle, so they agree with the prose
and disagree with git. The figure is re-derived by an instrument that shares the prose's blind
spot, which is the weaker half of "nothing in that document is a number only a human wrote down".
Not worth changing the assertion — `+3/-7` is the true count of *content* lines — but the
milestone should not claim git agrees.

**One claim I cannot check:** the prior-art search of the upstream tracker (2026-08-28). No network.

---

## Step 10 — the mutation matrix, all eleven arms RE-RUN

Every arm reproduces its declared result, and **the two self-reported defects are genuinely
fixed**:

| arm | result here | declared |
|---|---|---|
| M1 echo the input | 123 / **26** | 120 / 26 |
| M2 input digest reported as output's | 123 / **8** | 120 / 8 |
| M3 rung fed the not-re-keyed map | 114 / **22** | 114 / 22 |
| M4 rung-3 accepted as rung 1 | 114 / **1** | 114 / 1 |
| M5 the variant becomes a copy | 123 / **1** | 120 / 1 |
| M6 `revertCode` constant 0 | 59 / **2** | 59 / 2 |
| M7 `instructionsExecuted` constant 41 | 59 / **4** | 59 / 4 |
| M8 the baseline is patched too | **13 / 1** with a summary line | 13 / 1 |
| M9 a `__wbg_new0` import planted | 123 / **4** | 120 / 4 |
| M10 the page hangs | rc 1, `0 / 1` with a summary line | rc 1 |
| M11 die before the summary | **62 / 1 WITH a summary line** | 62 / 1 |

(The identity check's own total is 123 rather than 120 because of the implementation's own
self-review; the failure counts are unchanged, so those three assertions are green under every
mutation.)

- **M8 did not abort**, so the `M31_BUILD_WORK` rename really did fix the name collision and the
  arm's after-the-run effect assertion (`the baseline tree is non-pristine`) really is exercised.
- **M9 did not abort**, so the planted `__wbg_new0_planted_by_m9` really is in the built module —
  the optimiser-elimination defect is closed — and the four failures are the import count, the
  needle, and both declared-count reads.
- **M10 is bounded and named, with one hop.** The check's own stdout says only *"the transpiler
  arms run exited 1"* and points at `transpiler-failed.json`; the hang's name lives in that file's
  `arms.error.message` — *"Runtime.evaluate did not complete within 30000 ms. That is the HANG
  state reported as a failure."* — which is `browser_cdp.mjs`'s wording. So the property holds (a
  hang becomes a bounded failure with a summary line) and the impl log's quote is accurate; it is
  the RUNNER's internal CDP bound that fires, not `m31_bounded`'s.

---

## Step 11 — WHAT THE REVIEW CHANGED, and the mutation arms that show it can fail

M31 **376 -> 421**, in three checks and nothing else. Every unit accounted for in both directions:

| check | was | now | why |
|---|---|---|---|
| `verify_transpiler_wasm_output_identical_to_native` | 123 | **130** | +4 the noir pin's publication with its own negative control; +1 the host module's size; +2 the page's own digest of the MODULE compared against the file (nothing had compared them) |
| `test_transpiled_contract_registers_and_executes` | 59 | 59 | unmoved |
| `verify_transpiler_rung1_mapping_survives` | 114 | **135** | +21 §4b, `brillig_procedure_locs` measured instead of a false sentence about it |
| `verify_transpiler_native_build_unaffected` | 80 | **97** | +17 §6, the two builds' resolved dependency versions and the getrandom backend read from the version the build links |

4 + 1 + 2 = 7; 21; 17. 7 + 21 + 17 = **45**, and 376 + 45 = **421**.

One assertion was **replaced rather than added**: §6's *"the page ran M30's wasm_host.mjs
unchanged"* compared the repository's file against `wasmHost.servedSha256`, which the runner
computes over `$SITE/wasm_host.mjs` moments after `copyFileSync`-ing the repository's file into it —
two readings of one file in one process, **equal by construction**. It reads
`arms.browser.modules.hostSha256` now, taken by the PAGE over the bytes it fetched, which is the
same shape the fixture digests already had and the shape M30's review's correction asks for.

**Seven review mutation arms, `scratchpad/campaign/m31-review-mutations.sh`, all reddening for the
right reason:**

| arm | result |
|---|---|
| R1 the procedure map IS re-keyed | 135 / **3** — both carrying functions and the key-space assertion |
| R2 the page reports a digest that is not the module's | 130 / **1** — exactly the new comparison |
| R3a the publication predicate always answers 0 | 130 / **1** — "reachable from a PUBLISHED remote ref" |
| R3b the publication predicate always answers 1 | 130 / **1** — the CONTROL, so it controls in both directions |
| R4 both resolutions read from one lock | 97 / **1** — "the two builds resolve different versions" |
| R5 `wasm_js` reaches the rustflags line | 97 / **1** — the paired zero, not the whole-file grep |
| R6 every procedure map reported empty | 135 / **3** — the non-emptiness census, i.e. the vacuity guard |

**R5's first form crashed and that is recorded rather than replaced quietly.** Swapping the value
outright to `getrandom_backend="wasm_js"` gives **0 assertions, 1 failure**: the config is inside
the build script's content stamp, the module rebuilds, getrandom 0.4 has no `wasm_js` arm, the
build fails, and `m31_require_build` dies at the precondition — the check never reached §6. That is
M24's review's rule (*"the check failed" and "the check saw what I broke" are different
statements*), met on this review's own harness. The arm now adds `wasm_js` to the line while
leaving the backend selection valid.

**A shape I did NOT change, recorded so the next reader does not think it was missed.** All three
arm-reading checks open with `[ -z "$ABSENT" ] || die` followed by
`assert_eq "…carries every field this check reads" "" "$ABSENT"`. That assertion can never be red —
the `die` fires first. It is the exact shape `CAMPAIGN-BRIEF.md` prescribes as M29's remedy ("ONE
assertion that names every absent field … with a `die` behind it"), so the `die` is the instrument
and the assertion is the record. Left alone, named here.
