# M30 — Compiling Noir from a Virtual Filesystem — implementation log

Written as I go, per the brief. No commits, no pushes. `noir-wt4-webpage` is never committed and
never edited (see step 0.4 — editing it would redden M26).

## Step 0 — reading and pricing, before any code

Read in order: `scratchpad/campaign/M29-M32-proposed.md`, `CAMPAIGN-BRIEF.md` in full, the M30
section of `codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org`,
`scratchpad/campaign/m29-review-log.md`, `TRACE-ABI.md`, `SOURCE-MAPPING.md`,
`BROWSER-PACKAGING.md`.

### 0.1 State at start

`aztec-avm-runtime` on `dev`, HEAD `efa7c07` ("m29 review: the final sweep at 10,178"), tree clean.
`noir` on `blocktracer`, HEAD `01cf48082`, tree clean. `codetracer-specs` — M30 section is
`status: planned` with four `pending` verification entries.

Worktrees of `noir`:

| worktree | branch | HEAD | state |
|---|---|---|---|
| `noir` | `blocktracer` | `01cf48082` | clean |
| `noir-wt1-extract` | `wasm/extract-from-fork` | `b8fd9f08a` | — |
| `noir-wt2-reconcile` | `wasm/reconcile-then-extract` | `4f49a6e96` | — |
| `noir-wt3-upstream` | `wasm/upstream-clean` | `4111457c3` | — |
| `noir-wt4-webpage` | `wasm/webpage` | `f0e7edcd2` | **one uncommitted edit**, `tooling/tracer/src/tracer_glue.rs` — M26's, deliberate |

### 0.2 The enumeration — what already exists, by subdirectory

Searched: all five `noir` worktrees, `aztec-packages` (+ its ~90 worktrees under `~/.cache`),
`aztec-avm-runtime` including `spike/ diffsim/ drift/ probe-mt/ browser/ browser-probe/ upstream/
reference/ vm2wasm/ fixtures/ tools/`, and all five `node_modules` roots.

| the thing M30 needs | where it already is |
|---|---|
| an in-memory `path -> source` map into the compiler | `compiler/wasm/src/compile.rs:131-159` `PathToFileSourceMap`, `:248-265` `file_manager_with_source_map`, `compile_new.rs:37` |
| an in-memory `fm::FileManager` | `compiler/fm/src/lib.rs:18-24` — no `std::fs` in the file at all; `add_file_with_source` at `:51` |
| a crate-graph builder | `noirc_driver::{prepare_crate, prepare_dependency, add_dep}`; `compile.rs:267-298` `process_dependency_graph` |
| `Nargo.toml` parsing | **TypeScript only** — `compiler/wasm/src/noir/package.ts:127-132` via `@ltd/j-toml`. The Rust side never parses a manifest; the graph arrives pre-computed from JS (`compile.rs:126-130`) |
| a browser file manager | `src/noir/file-manager/file-manager.ts` + webpack's `resolve.alias: { fs: 'memfs' }` (`webpack.config.ts:88-90`) — so `createNodejsFileManager` IS the browser one |
| a browser multi-file test with a local dep | `test/compiler/browser/compile.test.ts:30-35` — already works, through webpack |
| fixtures with a local `path` dependency | `test/fixtures/{with-deps,deps/lib-a,deps/lib-b,deps/lib-c,noir-contract}` |
| a `.ct` from Noir source in wasm | `noir-wt4-webpage/tooling/tracer_wasm` — `compile.rs:42` `compile_source`, `ctfs_sink.rs`, `lib.rs:440` `ct_trace_source_container`; a 16,964,933-byte prebuilt module at `web/noir_tracer_wasm.wasm` |
| an import-free wasm loader | `noir-wt4-webpage/tooling/tracer_wasm/web/tracer.mjs` |
| headless-Chromium driving, dependency-free | `aztec-avm-runtime/tools/browser_cdp.mjs` (M27) |

**So the enumeration says: the VFS *compile* seam is there, and everything on top of it that
`Nargo.toml` decides is in TypeScript.** What is NOT there anywhere, measured with the needles
named:

1. **A git-dependency refusal.** `noir-wasm-compiler.ts:71-79` wires
   `GithubCodeArchiveDependencyResolver(fileManager, fetch)`: a GitHub dependency is answered by
   **downloading a zip over the network**, and any other git host falls through to
   `dependency-manager.ts:122-124`'s anonymous `throw new Error('Dependency not resolved')`.
   Native `nargo` shells out to `git clone` into `$HOME/nargo` (`nargo_toml/src/git.rs:51-62`).
   Needles `refus`, `not supported`, `only github` over `compiler/wasm/src`, `tooling/nargo_toml/src`
   and `tracer_wasm/src`: the only hits are `github-dependency-resolver.ts:50` and a test name.
   **Neither refuses by name.**
2. **A position on a compile error.** `errors.rs:83-104`'s `Diagnostic` carries `file` and BYTE
   OFFSETS and no line and no column; `noir-wasm-compiler.ts:192-203` turns them into
   `lineOffsets.findIndex(offset => offset > secondary.start)` — an index used as a line number —
   and prints no column at all, and `#resolveFile`'s `catch` returns `''`, which makes every
   position collapse to 0 for a file it cannot read.
3. **`[package].entry` honoured.** `package.ts:62-80` hard-codes `lib.nr` / `main.nr`. Native
   `nargo` honours the field (`nargo_toml/src/lib.rs:193-200`) and refuses a missing one by name.
   A manifest declaring a custom entry therefore compiles a **different file** through
   `noir_wasm` than through `nargo`, with no diagnostic — a silent wrong answer.
4. **`Nargo.toml` handling in `tracer_wasm`.** Needles `git`, `Nargo.toml`, `dependenc` over
   `tracer_wasm/src` and `web/`: two hits, both prose in comments. `TraceRequest` carries `files`
   and `entry_point` and nothing else, and `compile_source` builds exactly **one** crate — no
   `prepare_dependency`, no `add_dep`. Multi-*file* works; multi-*crate* does not.
5. **`createMemFSFileManager`'s recursive readdir is broken** —
   `memfs-file-manager.ts:12-23` iterates `for (const handle in contents)` (`in`, over an array,
   so `handle` is `"0"`, `"1"`, …), calls `.isFile()` on that string, and pushes bare names rather
   than joined paths. `nodejs-file-manager.ts:7-18` has the correct `for..of` + `fs.stat` + join.
   Nothing in `test/file-manager/file-manager.test.ts` calls `readdir` at all. Not on the shipped
   path (webpack aliases `fs` to `memfs` and uses the nodejs manager), so it is recorded rather
   than fixed — M30 does not need it and a fix it cannot run is the artefact
   `CAMPAIGN-BRIEF.md` warns about.

Also absent everywhere, so nothing can be reused from them: no `@noir-lang/*` in ANY of the five
`node_modules` roots; no `node_modules`, no `build/`, no `dist/`, no `pkg/` in ANY noir worktree;
no `.wasm` at all under `noir` on `blocktracer`; `aztec-packages/noir/noir-repo` is an empty
directory; and `grep -rn 'noir_wasm|Nargo\.toml|PathToFileSourceMap|source-resolver'` over the
whole of `aztec-avm-runtime` is **0 hits**.

**And `source-resolver` itself does not exist in this fork.** `source-resolver`, `source_resolver`,
`initializeResolver`, `initialiseResolver` — zero hits across all five worktrees,
`aztec-avm-runtime`, `aztec-packages` and every `node_modules` on the machine. The milestone's
"the `source-resolver` seam" is `PathToFileSourceMap` + `file_manager_with_source_map`, which is
the push-shaped replacement for it. Stated because a check greping for the old name would be
asserting an absence that is true for the wrong reason.

## Step 1 — what was written, and why there rather than somewhere else

### 1.1 The decision about where the code goes

`compiler/wasm` on `noir`'s `blocktracer` branch. Not `noir-wt4-webpage` (step 0.4), and not
`aztec-avm-runtime` (which has no Noir front end in any form, and whose `browser/` bundle is
gated by `verify_browser_bundle_no_node_builtins`'s six-root rule and by
`BROWSER-PACKAGING.md`'s re-derived chunk figures — a Noir compiler has no business in it).

### 1.2 `compiler/wasm/src/vfs.rs` — the resolver, in Rust

The manifest half moves **into the module**: `Nargo.toml` parsed from the VFS with `toml`,
`[package].entry` honoured, local `path` dependencies walked breadth-first inside the map,
cycles refused, non-library dependencies refused, and **`git` dependencies refused by name with
the manifest LINE they sit on** (`toml::Spanned`, so the line is a measurement of the manifest
rather than a constant — asserted by a test that moves the dependency down the file and requires
the number to move).

Each package is registered with `prepare_dependency` **at its own VFS entry path**, the way
native `nargo` does (`tooling/nargo/src/lib.rs:35-50`), rather than re-keyed to `<alias>/lib.nr`
the way `package.ts:112-114` does. The consequence is the one the milestone asks for: a
diagnostic inside a *dependency* names a path the caller put in the tree.

`position_diagnostics` renders `(file, line, column, end_line, end_column)` from the
`FileManager`'s own `codespan_files::Files::location`, keeping the byte offsets the shipped
`Diagnostic` carries so an existing consumer does not have to change.

### 1.3 `compiler/wasm/src/compile_vfs.rs` — two hosts, one code path

A `wasm-bindgen` binding (`compile_program_from_vfs`, `compile_contract_from_vfs`,
`resolve_vfs_plan`) and a **bare C ABI** (`nv_alloc`/`nv_free`/`nv_result_len`/`nv_compile_vfs`),
both calling `resolve_vfs` + `compile_resolved`. The bare ABI exists because a wasm-bindgen module
cannot be driven without generated glue, and glue is a build artefact rather than a source file —
the same reason `tooling/tracer_wasm` has a `ct_*` ABI, and deliberately the same shape so one
page can drive both modules through one loader.

### 1.4 Measured: `cargo test -p noir_wasm`

**37 passed, 0 failed** (10 pre-existing + 27 new), natively, in this repository's sibling dev
shell (`direnv exec .../codetracer-trace-format`, which supplies the `nim` the workspace's
`codetracer_trace_writer_nim` build script needs). The three-file tree with a local dependency
does not merely resolve — it **compiles**, and so does the transitive `app -> a -> b` tree.

### 0.3 Environment

- Neither dev shell carries a `wasm32-unknown-unknown` rust std. The established route is
  `nix shell nixpkgs#rustup` with `RUSTUP_HOME`/`CARGO_HOME` under `~/.cache`
  (`verification/build_ct_writer_wasm.sh:110-124`). `wasm-pack` and `wasm-bindgen` are on neither
  PATH.
- `noir` has no `.envrc`; its workspace resolves `codetracer_trace_writer` to
  `codetracer_trace_writer_nim` (`Cargo.toml:144`), whose `build.rs` needs `nim` —
  `direnv exec /home/zahary/m/blocktracer/codetracer-trace-format` supplies it (nim 2.2.8).
- `noir/target` is 17 GB (debug only). `noir-wt4-webpage/target` is 12 GB and **already carries a
  `wasm32-unknown-unknown` tree**, so a wasm32 build has been done there before.

### 0.4 Why `noir-wt4-webpage` is read-only for this milestone

`JOIN-SHAPE.md` §6 records that publishing `wasm/webpage` is fact 7 of OQ-7's verdict and that
`verify_oq7_shared_writer_verdict_recorded` asserts its HEAD is in **zero** published remote refs.
Beyond that, `build_oq7_shared_writer_probe.sh` **tolerates exactly one uncommitted edit by name**
(`tracer_glue.rs`) and refuses any other. So an edit of any other file in that worktree would turn
M26 red. It is a build source and a reading source for M30, never a target.

## Step 2 — the browser half

### 2.1 Two modules, one page, no bundler

`verification/m30/page/` is three files — `index.html`, `wasm_host.mjs`, `vfs_page.mjs` — plus
`tools/m30_vfs_trees.mjs` copied in beside them by the arm runner. It fetches two `.wasm` files
and calls their C ABIs. There is no esbuild, no webpack and no generated wasm-bindgen glue in the
path, which is the point: if a check finds a compiled Noir program at the end of it, no JavaScript
compiled it.

`tools/run_vfs_arms.mjs` serves the site and drives it through `tools/browser_cdp.mjs` — M27's
dependency-free CDP client, reused unchanged and the only thing of M27's that is.

### 2.2 The import counter, and what it measured

`wasm_host.mjs` satisfies **every** import either module declares with a function that records the
call and then throws. Across eighteen compilations in a real browser:

```
reached: { compiler: [], tracer: [], instantiations: 2 }
declaredImportModules: ["__wbindgen_externref_xform__","__wbindgen_placeholder__"]
declaredImports: 28 (compiler) / 7 (tracer)
```

Empty is the interesting answer and 28 is what stops it being vacuous.

**It was NOT empty at first.** With the module as built before any change to `noirc_evaluator`, the
first call trapped:

```
noir_wasm: the module reached __wbindgen_placeholder__.__wbg_new0_f788a2397c7ca929
  at js_sys::Date::new_0
  at chrono::offset::utc::Utc::now
  at noirc_evaluator::ssa::builder::SsaBuilder::run_passes
  at noirc_evaluator::ssa::create_program
  at noirc_driver::compile_main
```

`builder.rs:276-286`'s `time()` read the clock **unconditionally** and discarded the answer whenever
`print_timings` was false. Natively that is a `clock_gettime` nobody reads; on
`wasm32-unknown-unknown` it is a wasm-bindgen JS import in every compile. One line, and
`cargo test -p noirc_evaluator` is 1,079 passed / 0 failed over it.

### 2.3 The measured arm report

```
compilerModule 14,418,442 B  sha256 25460a02a2d8…
tracerModule   16,982,693 B  sha256 9d2793f74e67…
trees sha256 == servedSha256: true
git refusal            app/Nargo.toml:7:17   expectation 7:17   (derived independently)
git refusal, moved     line 11               expectation 11
git refusal, no tag    line 6                expectation 6
type error in the dep  util/src/lib.nr:1:27  expectation 1:27
…moved six lines down  util/src/lib.nr:7:27  expectation 7
trace A container 172,032 B, 21 events, sha 5a0492e3…   B sha 4db9ef48…   A2/A3/D == A
navigations 1   instantiations 2   wasmRequests 2
```

## Step 3 — the checks

| check | assertions |
|---|---|
| `test_vfs_multifile_compiles` | **67** |
| `test_vfs_compile_errors_carry_positions` | **41** |
| `e2e_vfs_edit_recompile_retrace` | **44** |
| `verify_git_dependency_refused_by_name` | **51** |
| | **203** |

Cross-cutting checks re-run and unmoved: `verify_named_checks_exist` 9,
`verify_reuse_inventory_complete` 19, `just check-repo-hygiene` 28, `verify_provenance_complete` 64,
`verify_pinned_nightly_single_source` 28, `verify_no_pipeline_predicates` 69,
`verify_oq7_shared_writer_verdict_recorded` 65.

## Step 4 — the mutation matrix

Eleven arms, in `scratchpad/campaign/m30-mutations.sh`. Every arm records the failing assertion
TEXT; every mutated file is restored and the restore is compared by sha256 against a copy the
script took, with the comparison shown to notice a one-character corruption.

| arm | broken | result |
|---|---|---|
| M1 | git refusal -> silent `continue` | 3 / **4** — the tree resolves, the stage is `None`, the fields are absent, the `die` is counted |
| M2 | the refusal loses the dependency's NAME | 51 / **2** — exactly the two "names itself" assertions |
| M3 | the manifest line becomes 1:1 | 51 / **5** — exactly the five position assertions |
| M4 | the resolver swallows the whole VFS | 67 / **6** and 44 / **4** |
| M5 | `[package].entry` ignored | 67 / **2** — and ONLY the native suite sees it |
| M6 | diagnostics lose line and column | 41 / **6** |
| M7 | library sources re-keyed `<alias>/lib.nr` | 41 / **3**, incl. "that path is a file the caller put in the VFS" |
| M8 | the tracer handed the whole tree | 44 / **1** — the join assertion and nothing else |
| M9 | the SSA timer reads a clock again | the arms run **exits 1** naming `__wbg_new0_…` from `run_passes` |
| M10 | **THE HANG** | `the VFS arms run did not finish within 180s and was killed. That is the HANG state reported as a failure` → **0 / 1** |
| M11 | **DIE BEFORE THE SUMMARY** | both checks report **1 / 2** *with a summary line* |

### 4.1 Two of M30's own assertions could not fail, and the harness found them

1. **The decoy control.** It compared two artifacts after EDITING a `.nr` file outside `src/`. An
   edit to a file that is not part of the program cannot change the artifact whatever the resolver
   does — so under M4, with the resolver swallowing the whole tree, those assertions stayed
   **green**. They are ADDITIONS now. Measured: one added unreferenced `.nr` file takes the program
   hash from 1206613220 to 4090147220 and leaves the BYTECODE byte-identical, so the hash is the
   discriminating reading and the bytecode is not.
2. **The dependency-sensitivity fixture** first changed `x + x` to `x + x + x - x` — different
   SOURCE, same CIRCUIT, folded back by the SSA passes. That assertion went red on its own first
   run, over an edit that had not edited anything the compiler could see. It is `x + x + x` now.

### 4.2 And the harness reproduced a recorded campaign defect

`restore_all` used `cp -p`, which puts the original mtime back, and cargo's fingerprint is
mtime-based. After the M9 arm restored `noirc_evaluator/src/ssa/builder.rs`, the restored file was
OLDER than the rlib the mutated one had produced; cargo declined to recompile; the next build
emitted a module **still carrying the mutation** and reported success, while this milestone's own
content stamp correctly said "rebuild". All four checks then failed for a reason that had nothing
to do with the tree on disk — "a mutated artefact outlived its restored source", exactly.

Fixed in **two** places, not one: the harness restores content and `touch`es, and
`build_noir_vfs_wasm.sh` `touch`es its stamped inputs before invoking cargo, which closes it for
every caller and not only for the harness.

### 4.3 The hang arm was caught twice, by two different bounds, and the difference matters

First run: `browser_cdp.mjs`'s 60 s CDP round-trip bound fired
(`Runtime.evaluate did not complete within 60000 ms`) and the arms run exited 1. That is correct,
but it is the SHARED client's bound rather than M30's, and it also means a legitimate arm on a slow
box would have been cut off at 60 s. `run_vfs_arms.mjs` raises the connection's bound to
`M30_EVAL_MS`; re-run, the hang is caught by `m30_require_arms`'s own `timeout -s KILL` and named:
*"the VFS arms run did not finish within 180s and was killed. That is the HANG state reported as a
failure."*

## Step 5 — the sweep, taken after the last edit

`setsid`-detached, `direnv exec <aztec-avm-runtime>` (this repository's own dev shell, not the
workspace root's — M25's correction), `TMPDIR` and the log under `~/.cache`, one milestone at a
time with nothing else running. **62 markers for 31 milestones: no hole.**

```
m0 156  m1 175  m2 292  m3 199  m4 218  m5 236  m6 363  m7 287  m8 516  m9 807
m10 450  m11 259  m12 691  m13 458  m14 460  m15 537  m16 223  m17 297  m18 283
m19 180  m20 237  m21 325  m22 260  m23 509  m24 350  m25 272  m26 313  m27 345
m28 353  m29 127  m30 203
                                                       CAMPAIGN TOTAL 10,381
```

**30 of 31 exit 0.** `10,178 + 203 = 10,381` exactly, and **every one of M0–M29 came out at its
reference value TO THE ASSERTION** — the summariser reports `delta +0` against the reference table.

- **M9 did NOT flake**: 807, 7/7, exit 0 in 1,281 s, immediately after M8's build — which is
  `DRIFT.md` D19's standing hypothesis, and it did not fire. Worth as much as a sighting.
- **M11 is the one red**: 259 with **nine** failing assertions and the count unchanged, the
  recorded signature of the ninth upstream move (`7471a61f1a`). Not repaired; `carry/` is left at
  HEAD rather than half-repaired.
- **A sweep is a writer.** `carry/rebase.json` and `carry/exposure.json` were checksummed before
  (`aaeb6877…`, `ec959b84…`) and restored to those exact digests after; `sha256sum -c` confirms
  both.
- `m30` took 5 s because everything it needs was already current: both module stamps matched, the
  arm report was not stale, and `cargo test -p noir_wasm` was warm.

### 5.1 Nothing else moved, and each is a reading rather than an inference

`verify_provenance_complete` 64 (M30 vendors nothing), `verify_pinned_nightly_single_source` 28
(no new anchor), `verify_no_pipeline_predicates` 69 (no new `| grep -q`),
`verify_reuse_inventory_complete` 19 (the check is `>= 20` on the entry count, so RI-76 and RI-77
add none), `verify_named_checks_exist` 9, `just check-repo-hygiene` 28,
`verify_oq7_shared_writer_verdict_recorded` 65 — all re-run individually as well as inside the
sweep.

### 5.2 Final tree state

```
aztec-avm-runtime   M Justfile, M REUSE-INVENTORY.md, M CAMPAIGN-BRIEF.md,
                    ?? tools/{m30_vfs_trees.mjs,run_vfs_arms.mjs},
                    ?? verification/{lib_m30_vfs.sh,build_noir_*.sh,4 checks,m30/},
                    ?? scratchpad/campaign/m30-*
noir                M Cargo.lock, M compiler/noirc_evaluator/src/ssa/builder.rs,
                    M compiler/wasm/{Cargo.toml,src/lib.rs},
                    ?? compiler/wasm/src/{vfs.rs,compile_vfs.rs}
noir-wt4-webpage    M tooling/tracer/src/tracer_glue.rs   — EXACTLY as found
codetracer-specs    M Planned-Work/Aztec-AVM-Runtime.milestones.org
```

No commits, no pushes, in any repository.
