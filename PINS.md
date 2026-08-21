# Pins and the re-pin policy

Every upstream pin lives in [`pins.json`](pins.json). **This file declares no version numbers**,
on purpose: if a number appeared here as well as there, one of the two would eventually be wrong.
This file says *when* pins move and *what a move must record*.

Enforced by `just verify-pinned-nightly` (`verification/verify_pinned_nightly_single_source.sh`).

## What is pinned

| pin | what it anchors |
|---|---|
| `anchors.cpp` | the C++ side: every prepared upstream patch's base, the `AVM_WASM` build, and all of `reference/` except the historical specs |
| `anchors.ts` | the TypeScript side: the last commit carrying the TS AVM and the public orchestration, vendored into `spike/src`, `diffsim/src`, `drift/src` and checked out as `upstream/tsavm` |
| `anchors.historical-protocol-specs` | `reference/historical-protocol-specs/`, the only commit at which the deleted protocol specs still exist |
| `npm.current` | **the** pinned `@aztec/*` nightly — what new work uses |
| `npm.deletion_era` | frozen evidence: the published line that is byte-comparable with `anchors.ts` |

## Why there are two npm lines and only one of them is "the pin"

`npm.current` is the pin. `npm.deletion_era` is an **artefact**, not a dependency choice.

The TypeScript AVM was deleted upstream. It runs here only because the npm packages published on
the day of the deletion still ship the whole tree, so `spike/` and `diffsim/` can resolve
`@aztec/simulator`'s siblings at exactly the version their sources were written against. That line
also still carries the *in-process* NAPI AVM, which is the only reason the differential oracle runs
without a barretenberg build. Bumping it does not update the evidence — it destroys it.

So the two are separated by role rather than by accident, `pins.json` says which tree uses which,
and the check fails if a tree drifts onto the wrong one. `drift/` exists precisely to answer "what
would happen on the current line", which is why it is the one tree on `npm.current`.

## Single source, and what that honestly means

`pins.json` is the only file that **declares** a pin. Three other kinds of file **contain** pin
values, and each is held to the declaration rather than trusted:

| kind | how it is held to `pins.json` |
|---|---|
| `*/package.json` | every `@aztec/*` dependency must equal the pin declared for that tree in `npm_consumers`. `tools/repin.py --apply` rewrites them; `--check` fails on any disagreement |
| `*/package-lock.json` | every `@aztec/*` entry's resolved `version`, and the version embedded in its `resolved` tarball URL, must equal the same pin |
| tracked prose (`*.md`) | any `x.y.z-nightly.YYYYMMDD` literal it mentions must be one of the declared pins. A stale number in a README therefore fails the check instead of quietly misinforming |

The literal cannot be reduced to one physical occurrence: npm requires a version in each
`package.json`, and a lockfile repeats it per entry. What *can* be — and is — guaranteed is that
there is exactly one **authority**, and that nothing anywhere disagrees with it.

## The re-pin policy

**Bump on a schedule, not opportunistically.**

1. **Cadence.** `npm.current` and `anchors.cpp` are re-pinned **at most once per calendar month**,
   and only at a milestone boundary. Between bumps the pin does not move, even if a nightly with a
   wanted fix appears. A bump mid-milestone changes the ground under a measurement that is still
   being taken.
2. **The two exceptions**, and they are the only ones: a security fix in a pinned package, or a pin
   that no longer resolves (a yanked nightly). Both are recorded in `history` with the exception
   named.
3. **`npm.deletion_era` and `anchors.ts` do not move at all.** They are frozen evidence. Moving
   `anchors.ts` forward means the TS AVM is gone; the correct response to wanting a newer TS side is
   to record *why* in `DRIFT.md`, not to re-pin.
4. **`anchors.historical-protocol-specs` does not move.** There is nothing to move it to — the path
   was deleted.
5. **A bump is not a version edit.** It is, in order:
   - `tools/repin.py --apply` (rewrites the `@aztec/*` versions in the affected trees),
   - `npm install` in each affected tree so the lockfile follows,
   - re-run the trees' suites and **record the measured before/after numbers**,
   - `just check-drift` and re-vendor `reference/` if `anchors.cpp` moved, updating
     `reference/PROVENANCE.md`'s dates — the point of that file is that its dates are true,
   - a new entry appended to `pins.json`'s `history`, and
   - a `DRIFT.md` entry for **every behavioural difference the bump surfaced**, including the ones
     that were absorbed silently. A bump that opens no drift entry and changed no measured number
     is a bump that was not verified.
6. **Every bump is recorded**, in `pins.json`'s `history` array, with the date, the milestone, what
   moved, why it moved now rather than later, and the drift entries it opened. The array is the
   record; `verify_pinned_nightly_single_source` asserts it is non-empty and that its newest entry
   names the values currently declared.

## Why a schedule rather than "keep current"

The differential oracle's value comes from comparing two things that are *pinned relative to each
other*. `@aztec/bb.js`'s prebuilt NAPI AVM, the vendored TypeScript sources and the C++ anchor form
one consistent set; moving any of them independently produces a green suite that is comparing a
newer implementation against an older expectation, or a red one whose failure is a version gap
rather than a defect. The cost of being a month behind is known and small. The cost of not knowing
which versions a measurement was taken against is the thing `DRIFT.md` exists to prevent.
