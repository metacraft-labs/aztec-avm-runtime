# The browser gate — what it prevents, and why it is not skippable

M28's write-up. **Every figure below is re-derived from an artefact by `ci_browser_gate.sh` §6 on
every run, and each one is looked for on the line that names its subject** — not anywhere in the
file. That sentence is a promise this repository has broken once already: `BROWSER-PACKAGING.md`
opened with the same claim, no check opened it, and eleven of its figures had rotted by the time
M27's review measured them. The check that reads this document is named in §6 below and you can run
it: `just verify-ci-browser-gate`.

---

## 1. The decay this prevents, named

DD-5 exists because **upstream's own browser story decayed exactly this way**. The pattern is not
that somebody decided to require Node; it is that nobody decided anything:

- a dependency is added for a good reason in a Node-only code path;
- it pulls a transitive dependency that reaches `fs`, or `worker_threads`, or a prebuilt `.node`;
- everything keeps working, because everything is tested under Node — which is this plan's own
  stated testing order, *Node first, browser last*;
- months later a page is opened, the bundler fails on an unresolved builtin, and the fix is no
  longer local: the dependency is now load-bearing and the browser path has to be rebuilt around
  it.

Each of those four steps is individually reasonable. The gate exists because **the point at which
this is cheap to fix is the pull request that introduces it**, and nothing but a check that runs on
that pull request can be there.

**Three concrete things in this repository would have decayed silently without it**, and all three
are measured rather than imagined:

1. **`msgpackr` optionally depends on `msgpackr-extract`**, a prebuilt-`.node` family with six
   platform packages. The Node bundle reaches it. The browser bundle does not — but nothing except
   `verify_browser_bundle_no_native_deps` would notice the day it did, because msgpackr's own
   fallback is silent by design and the page would simply get slower or fail at run time.
2. **`@aztec/simulator` is published at the exact nightly this repository pins**, and importing it
   would be the natural thing to do. `npm view` lists `@aztec/native` and `@aztec/world-state` as
   hard dependencies of it. One import, and DD-9's boundary is gone.
3. **The differential harness lives in the same checkout as the runtime.** `diffsim/` reaches
   `@aztec/native`, `@aztec/world-state` and `@aztec/telemetry-client`, and a relative import from
   `browser/src` to it is four characters of `../`.

## 2. What the gate is

**The gate recipe runs 7 checks.** The CI job `browser-gate` in `.github/workflows/avm-wasm.yml`
invokes that same recipe, `just ci-browser-gate`, by name rather than listing the checks again. A
parallel copy in the workflow is how a gate comes to test something slightly different from what a
developer runs.

| check | what it gates |
|---|---|
| `just ci-browser-gate` (`ci_browser_gate.sh`) | the gate's own composition, its CI wiring, and that it cannot be skipped |
| `verify_browser_bundle_no_node_builtins` | the shipped bundle's graph and emitted bytes reach no Node builtin |
| `verify_browser_bundle_no_native_deps` | no `@aztec/native`, `@aztec/world-state`, telemetry client, `cpp_*` file or native-addon loader |
| `verify_npm_pack_no_optional_native` | the packed tarball declares no optional native dependency and holds no binary |
| `verify_verification_code_unreachable_from_browser` | no browser entry point reaches `differential/` or the real `WorldState` binding |
| `verify_browser_entry_points_are_dd5_shaped` | DD-5: browser is the reference, Node is a declared superset (M27's check, run by the gate) |
| `smoke_browser_headless_full_flow` | a real headless Chromium loads, executes, blocks and emits a parseable `.ct` |

**The verify-m28 recipe runs 6 checks** — the gate minus
`verify_browser_entry_points_are_dd5_shaped`, whose assertions are counted in M27. Running it in
both lists would double-count it in a campaign sweep, which is the defect that once made M1 read
316 when it is 141.

## 3. The measurements the static gates rest on

Each is taken from one of the two metafiles `browser/build.mjs` writes, and each is re-derived by
§6 from the line that names it — one figure per line, because a table row carrying two numbers can
have them swapped and still contain both.

- The browser bundle's module graph has 1061 inputs.
- The node bundle's module graph has 967 inputs.
- Node builtins left external in the browser bundle: 0.
- Node builtins left external in the node bundle: 22.
- The browser bundle reaches `msgpackr-extract` 0 times.
- The node bundle reaches `msgpackr-extract` 1 time.

The two bundles are built from the same sources, against the same installed `node_modules`, by the
same `browser/build.mjs`, and differ only in esbuild's `platform`. **That is what makes the zeroes
measurements rather than absences from a tree that excludes their subject** — the campaign's own
most-repeated defect, which it has shipped twice.

The browser graph draws from exactly 6 distinct directory roots (`browser`, `browser-probe`,
`ct-host`, `node-host`, `orchestration/node_modules`, `orchestration/src`) and the partition is
total: every input is attributed to exactly one, so a seventh root is a red line rather than
something an allow-list failed to mention.

## 4. What "no Node builtin" means precisely, and what it does not

Four builtins ARE imported by this graph and are aliased to shims the build declares in
`.build-config.json`. The graph carries 43 `util` import edges, and `assert`, `tty` and `module`
account for the rest. A fifth name, `buffer`, resolves to npm's `buffer` package, which is the
browser implementation rather than Node's. The gate asserts that the set of aliased names is
EXACTLY the set the build declares, in
both directions, and that every alias is actually exercised — a declared alias nothing imports
would satisfy a subset test while doing nothing.

So the claim is not "this graph never says `util`". It is: **every builtin name in the shipped
graph resolves to a declared shim, none is left external, and none survives into the emitted
bytes.** The node bundle leaves 22 of them external and its emitted bytes carry them, which is what
says the browser bundle's zero is a measurement.

## 5. The packed package, and the honest part

`npm pack` is run for real — a `.tgz`, not `--dry-run` — for all **3** shipped packages
(`orchestration`, `node-host`, `ct-host`), and the manifest read is the one INSIDE the archive,
because npm rewrites it on pack. No member is a prebuilt binary, checked by extension AND by
requiring every member to decode as UTF-8, which is the arm that does not depend on having
enumerated the right suffixes.

**And the transitive closure is a different question with a different answer.** Two figures, and
they are on separate lines for the reason §3 gives — a line carrying two of them can have them
swapped and still contain both, which is precisely how this section passed a review mutation that
made it state the reverse of the data:

- The declared dependency closure of the shipped package is 268 packages.
- Manifests in that closure declaring `optionalDependencies`: 3.

All three are native-addon families — `msgpackr`, `msgpackr-extract` and
`@crate-crypto/node-eth-kzg`. That is `DRIFT.md` D22. The narrower true statement ("the published
package declares none") is not allowed to stand in for the wider one; what the gate owns is the
consequence, which is that the browser bundle reaches none of them.

## 6. What re-derives this document

`verification/ci_browser_gate.sh` §6 opens this file, takes each figure from the artefact it comes
from, and looks for it **on the line that names its subject** — the correction M24's review had to
make to an OQ-6 check that once passed a document with two table rows swapped, every figure present
and every figure re-derived. A subject line this document does not contain is a `ROW-MISSING`
failure rather than a silent pass.

Re-derived: §2's two recipe sizes, from the Justfile recipes themselves; §3's six bundle figures
and the root count, from the two metafiles; §5's package count and its closure size, from the
packed packages and the closure walk; §4's `util` edge count, from the browser metafile. The
instrument that judges this document is itself controlled — a wrong figure on a line that exists
and a subject line that does not exist are both required to be reported.

## 7. Why it cannot be skipped

The deliverable is "*the gate fails the build. It does not warn, and it is not skippable by a
flag*". Three things are asserted about the text of the recipe and of the CI job, each with a
negative control that plants the violation in a scratch copy and requires the same predicate to
report it:

- the recipe collects failures and `exit "$rc"`s; there is no `|| true` anywhere in it;
- the CI job and its gate step carry no `continue-on-error:` and no `if:`;
- no check in the gate has an early `exit 0` — `lib.sh`'s first design rule is that a check which
  cannot run in this environment FAILS, and never prints a SKIP line and exits 0.

The gate step also uses `shell: bash` rather than the default `bash -e {0}`, because the default has
no `pipefail` and the step pipes into `tee`: without it a failing gate hands the step `tee`'s exit
status and reports a green job. That is a recorded defect in this campaign, not a precaution.

## 8. What this gate does NOT establish

Stated here because a gate that is believed to cover more than it does is worse than one that is
known to be narrow.

- **It has never run in CI.** Every job in `avm-wasm.yml`, this one included, aborts at
  `Generate CI token`; the remaining blocker is a repository-level secret only the user can set.
  Every check the gate names has been executed locally, in this repository's own dev shell, and
  each was demonstrated against a planted violation. The gate is wired; it has not yet gated.
- **It is a check on the artefact this repository builds**, not on a published npm package: nothing
  here is published, and all three packed packages are `private: true`.
- **It says nothing about a Web Worker**, because there is none — the design document says main
  thread by default and a worker wrapper is a follow-up.
- **It does not gate the step stream's fidelity.** The container the browser downloads carries the
  artifact's own mapped program counters rather than the instructions the transaction executed;
  `test_trace_step_count_matches_instruction_count` is `pending` for that, in Node as well as in a
  browser.
