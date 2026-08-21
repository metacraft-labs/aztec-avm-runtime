# Aztec reference material — provenance, pinning and staleness

> **This file is the narrative companion for `reference/` only** — what each directory is, how
> stale it is, and what must not be trusted. The **authoritative, machine-checked mapping** for
> every vendored file in the repo (this directory and the vendored TypeScript trees alike) is
> [`../PROVENANCE.md`](../PROVENANCE.md), which the tooling reads; the pins it cites live in
> [`../pins.json`](../pins.json). Where the two disagree, the machine-checked one wins, because
> `just check-drift` enforces it.

Everything in this directory is a **vendored, pinned copy** of upstream Aztec material.
It is reference input, not our code. Do not edit files here; re-vendor instead. The one exception
is the generated `BEGIN VENDORED-PROVENANCE` header each file carries: it is written by
`just vendor-headers` and stripped before any drift comparison, so it can never mask a change.

**Upstream:** `https://github.com/AztecProtocol/aztec-packages`
**Pinned at:** `233d8e099336c1773b89e939100af047ed9c4f71` (branch `next`, committed **2026-08-19**)
**Vendored on:** 2026-08-21
**Licence:** Apache-2.0 (`LICENSE.aztec-packages.Apache-2.0`, *Copyright 2023 Spilsbury Holdings Ltd*).
The root `LICENSE` and `barretenberg/LICENSE` are both Apache-2.0 and differ only in one line of
boilerplate placeholder punctuation. No `NOTICE` file exists upstream. `avm-transpiler` is dual
`MIT OR Apache-2.0` (`avm-transpiler/Cargo.toml`), i.e. strictly more permissive.
Redistribution requires retaining the licence text and attribution; both are satisfied here.

> `DISCLAIMER.md` at the upstream root is a no-warranty / no-roadmap-commitment notice.
> It is **not** a licence restriction and does not narrow the Apache-2.0 grant.

## Why vendored rather than linked

Upstream moves fast — `next` is the default branch and takes nightly merges. Anything we
*reason against* must be pinned or a future reader cannot tell which version a claim was made
about. The whole bundle is 3.2 MB, so the cost of pinning is negligible.

## What is here

| directory | upstream path | last upstream change | what it is |
|---|---|---|---|
| `avm-spec/` | `yarn-project/simulator/docs/avm/` | **2026-05-21** (`9c95d6b409`) | **The current AVM specification.** 61 files: `README.md`, `avm-isa-quick-reference.md`, `gas.md`, `memory.md`, `addressing.md`, `wire-format.md`, `public-tx-simulation.md`, `external-calls.md`, `enqueued-calls.md`, `execution-lifecycle.md`, `calldata-returndata.md`, `errors.md`, `state.md`, `tooling.md`, plus **46 per-opcode files** under `opcodes/`. Hand-written prose — see the drift warning below. |
| `pil-vm2/` | `barretenberg/cpp/pil/vm2/` | **2026-07-28** (`c2ca120898`) | The AVM **constraint system** in PIL, declared by upstream's own `AGENTS.md` to be *"the source of truth for relation constraints"*. Includes `docs/README.md` (520 lines, 56 KB) — the most current large prose description of the circuit architecture. |
| `vm2-common/` | `barretenberg/cpp/src/barretenberg/vm2/common/` | `instruction_spec.cpp` **2026-07-07** (`cf0fc3928f`); `opcodes.hpp` **2026-02-13** (`cbbe96e7fd`) | **The de-facto normative ISA and gas table.** `instruction_spec.cpp` (742 lines) carries per-opcode wire format *and* gas cost; `opcodes.hpp` carries the opcode enum. Where the markdown in `avm-spec/` and this disagree, **this wins**. Includes the upstream `*.test.cpp` next to each header. |
| `constants/constants.nr` | `noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr` | **2026-08-18** (`a96bcfde13`) | Normative protocol constants: tree heights and IDs, per-tx limits, and **all the `DOM_SEP__*` domain separators** including `DOM_SEP__MERKLE_HASH = 2982624097`, `DOM_SEP__NULLIFIER_MERKLE = 1157584160`, `DOM_SEP__PUBLIC_DATA_MERKLE = 3756303423`. ⚠️ I copied this from the *untracked build artefact* `protocol/constants-codegen/inputs/constants.nr`; it is byte-identical (`cmp` clean) to the tracked path above, which is the canonical one. The C++ `aztec_constants.hpp` and the TS `constants.gen.ts` are both **generated** from it and are not in the upstream tree. |
| `trees-and-state/` | mixed, see below | — | The merkle/world-state corner, which has **no single spec**. `aztec_hash_policy.hpp` (2026-04-23, `d980498b4b`) is the load-bearing one: it shows internal nodes are hashed `poseidon2([SEP, lhs, rhs])` with a **per-tree** separator. `merkle_tree_hash.hpp` is `barretenberg/cpp/src/barretenberg/crypto/merkle_tree/hash.hpp`. `indexed_merkle_tree.mdx` (2026-08-19) is the live explainer of the indexed-nullifier construction. `noir-protocol-circuits-ABOUT.md` (502 lines) describes the kernel/rollup circuits. |
| `docs-extracts/` | `docs/docs-developers/docs/foundational-topics/advanced/circuits/` | **2026-08-19** (`e685ad1695`) | `public_execution.md` (the tx→AVM→rollup flow; states there is no public kernel circuit — the AVM proves all public functions in one proof), `avm_compatibility.md` (which Noir crypto primitives are available in public), `rollup_circuits.md`. |
| `avm-transpiler/` | `avm-transpiler/{src,README.md,Cargo.toml}` | **2026-08-10** (`864a30c24a`) | Noir/Brillig → AVM bytecode lowering. Dual `MIT OR Apache-2.0`. |
| `historical-protocol-specs/` | `docs/docs/protocol-specs/` **@ `9fe19ba7a19d76a819f1ee3dd968697170eebf7b`** | **deleted 2025-10-23** | ⚠️ **ABANDONED. See below.** 97 files, 1.0 MB. |

## ⚠️ Staleness and trust

Read this before treating anything here as authoritative.

### `historical-protocol-specs/` is abandoned on purpose — do not treat it as normative

There is **no `AztecProtocol/protocol-specs` repository** and there never was; the protocol specs
were a subtree of the monorepo docs site. They were **deleted on 2025-10-23** in
`0285bb092bb5d60aac1955ba833124f44da60436` *"chore(docs): Remove protocol specs from next
(#17911)"* — 384 files changed, 44,587 deletions — with the commit body stating the reason
outright:

> removes protocol docs from `next`, to avoid LLMs and humans from indexing on outdated info

The recovered copy here is from the parent commit `9fe19ba7a1`. Its own `intro.md` describes it as
*"a first attempt… still a work in progress… we haven't settled on exact hashes, or encryption
schemes, or gas metering schedules yet"* and names its audience as *"people at Aztec Labs"*. It
**predates the vm2 AVM rewrite entirely.**

It is vendored anyway because `state/` (7 files) and `rollup-circuits/` (5 files) remain the only
narrative description of tree/state semantics that exists at all, and design *intent* ages better
than design *detail*. **Every claim taken from it must be re-verified against `constants/constants.nr`
and `pil-vm2/` before it is relied on.** ~22 months stale.

`https://docs.aztec.network/protocol-specs/*` is 404. `protocol.aztec.network` does not resolve.
`AztecProtocol/docs` is deleted.

### `AztecProtocol/protocol-specs-pdf` — deliberately NOT vendored

It exists (5.9 MB PDF, 507 pages, `docusaurus-prince-pdf` render of the same deleted docs site),
but two facts disqualify it:

1. **It is frozen at 2024-12-24** (`pushed_at`, last commit `c19bd63a50`). The
   *2026-05-15* date is GitHub's `updated_at` metadata field, which an org-wide settings change
   touches — **it is not a content update.** So it is ~20 months stale, not 3.
2. **It has no licence.** `license: null`; the `/license` API returns 404; the two-file tree has no
   LICENSE. All rights reserved by default. **We must not vendor or redistribute it.**

Its content is also pre-vm2: zero occurrences of `POSEIDON2` or `TORADIXBE`, both of which are
current AVM opcodes.

`AztecProtocol/engineering-designs` (world-state design notes) is likewise **unlicensed** — read
only, do not vendor.

### `avm-spec/` prose can drift from the implementation

`yarn-project/simulator/docs/avm/` is hand-written, not generated from `instruction_spec.cpp`.
Nothing enforces agreement. It was last touched 2026-05-21 while `instruction_spec.cpp` moved
2026-07-07. **On any gas or wire-format question, `vm2-common/instruction_spec.cpp` is the
authority and the markdown is a convenience.**

A live example of exactly this class of divergence: AND / OR / XOR **lost their dynamic L2 gas**
upstream (`instruction_spec.cpp`), and `AVM_BITWISE_DYN_L2_GAS` / `AVM_DYN_GAS_ID_BITWISE` were
removed from `constants`; but the published `@aztec/constants` npm nightly still ships the old
constant, so code depending on it compiles and passes tests while metering differently from
production.

### `docs/llms.txt` is useless for AVM work

`https://docs.aztec.network/llms.txt` (45 KB) and `llms-full.txt` (6.4 MB) are regenerated on every
docs build and are therefore current — but they index the *developer* docs only. The entire AVM
specification (`yarn-project/simulator/docs/avm/`) is deliberately **not** published to the docs
site, so it appears in neither. The two AVM-related entries in `llms.txt` are
`avm_compatibility.md` and `public_execution.md`, both already extracted into `docs-extracts/`.

### Versioned snapshots

There is no downloadable protocol-spec bundle. There *is* a versioned developer-docs tree
(`docs/developer_versions.json` → `["v5.2.0"]`, released 2026-08-17, one version retained at a
time). The AVM docs are pinned per release by git tag — upstream's own
`version-v5.2.0/…/avm_compatibility.md` links to
`github.com/AztecProtocol/aztec-packages/blob/v5.2.0/yarn-project/simulator/docs/avm/avm-isa-quick-reference.md`.
So `git checkout v5.2.0` in the upstream clone is the "versioned spec bundle" if one is ever needed.

### `yarn-project/world-state/README.md` — NOT vendored, deliberately

40 lines, in-tree, and **wrong**: it still describes a "Contract Tree", "Contract Tree Roots Tree"
and "Note Hash Tree Roots Tree", none of which exist in the current five-tree model. Left out so
nobody reads it by accident.

## Re-vendoring

Everything above came from the `metacraft-labs/aztec-packages` fork, which since M0 lives as a
**workspace-root sibling** at `../aztec-packages` (it used to be at
`aztec-avm-runtime/upstream/aztec-packages`; that path is gone). To refresh: bump the pin in
`../pins.json`, re-copy the paths in the table, re-run `just vendor-headers` and `just check-drift`,
and **re-check every date in this file** — the point of it is that the dates are true. The re-pin
policy, including that this is done on a schedule rather than opportunistically, is `../PINS.md`.

Note that `historical-protocol-specs/` is pinned to a *different* commit from everything else
(`anchors.historical-protocol-specs`, the parent of the deletion), and that anchor cannot move —
there is nothing to move it to.
