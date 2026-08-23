# Working in this repo

This repo is worked on by several people and agents **concurrently**, often
inside the same checkout. That is not an accident to be designed away; it is the
normal mode here, and the rules below exist because ignoring it has already cost
work.

## What actually happened

During the wasm AVM spike, two agents were active in this checkout at the same
time:

- One staged `flake.nix`, `flake.lock` and `nix/wasi-sdk.nix` and went off to
  test them. Before it committed, the other ran a commit that swept those staged
  files into an unrelated commit
  (`3a4cf09 evidence: preserve the wasm AVM spike artefacts and its toolchain pin`).
  The dev-shell work landed under a commit message about spike artefacts, and
  the agent that wrote it could no longer commit it as its own change.
- In the other direction, the first agent briefly clobbered
  `vm2wasm/README.md`, which the second was in the middle of writing. It was
  restored, but only because someone noticed.

Neither was a merge conflict. Git never complained. Both were caused by
whole-tree commands run at the repo root by someone who assumed the tree was
theirs alone.

## The convention

**1. Stage explicit paths. Never `git add -A` or `git add .` at the repo root.**

```sh
git add flake.nix flake.lock nix/wasi-sdk.nix     # yes
git add -A                                        # no
git add .                                         # no, including from a subdirectory
```

`git add .` from a subdirectory is the same hazard with a smaller blast radius,
not a safe version of it. Name the files.

**2. Never run a whole-tree destructive command at the repo root.**

These discard other people's uncommitted work with no warning and no recovery:

```sh
git checkout -- .        git restore .        git restore --staged .
git reset --hard         git clean -fd        git stash -u
```

If you need to discard something, discard it by path:
`git checkout -- path/to/your/file`.

**3. Verify every staged path is yours before you commit.**

```sh
git diff --cached --name-only
```

Read that list. If it contains a file you did not touch, unstage it
(`git restore --staged <path>`) and commit only what you own. `git commit -a` is
`git add -A` wearing a different hat — do not use it.

**4. Prefer `git commit -- <paths>`** so the commit records exactly what you
name, regardless of what else is in the index:

```sh
git commit -m "..." -- flake.nix flake.lock nix/wasi-sdk.nix
```

**5. Expect the working tree to change under you.**

Files you did not touch will appear, vanish and change while you work. Do not
treat `git status` output as a description of your own change set; treat it as a
description of the tree. Re-read a file immediately before editing it if there
has been a gap, and never write a file back from a buffer you read minutes ago.

**6. If you need real isolation, take a worktree.**

For anything long-running or destructive — a rebase, a big refactor, a build
that rewrites sources — use a separate worktree rather than the shared checkout:

```sh
git worktree add ../aztec-avm-runtime-<topic> -b <topic>
```

The same applies to the sibling fork checkout at `../aztec-packages`, which has
several worktrees already (`git -C ../aztec-packages worktree list`).

**7. Announce shared files.**

`flake.nix`, `nix/`, `.envrc`, `Justfile`, `README.md`, `AGENTS.md` and the
`.gitignore`s are touched by everyone. Say so in the campaign log before you
edit one, and commit it in its own commit rather than folding it into unrelated
work.

## Scope

This convention governs this repo **and** the sibling fork checkout at
`../aztec-packages`. The fork additionally carries upstream Aztec's own
`AGENTS.md` and `CONTRIBUTING.md`, which are unmodified on purpose — every
downstream edit to an upstream file is a rebase cost forever, so downstream
conventions live here rather than there.

## The fork's branches, and the one line that must never be crossed

`../aztec-packages` has **two** remotes: `origin` is `metacraft-labs/aztec-packages`
and `upstream` is `AztecProtocol/aztec-packages`. Never push to `upstream`, and
never open a pull request from a script. Filing upstream is a person's decision
and a person's command — `submit/pr<N>-*.sh` in this repo, run by hand — and
`just verify-submission-manual` asserts that exactly one file here is even
capable of it.

It is a public repository, so every branch name and every commit message on it
must be neutral and user-facing: no internal project names, no roadmap, no
milestone identifiers.

| branch on `origin` | what it is |
|---|---|
| `aztec-avm-runtime` | the base commit plus our nix dev-shell commits. The fork's default branch, and what the checks build from |
| `pr/1-…` … `pr/5-…` | one per prepared upstream contribution, ready to file. **Generated**, not hand-built |
| `codetracer` | downstream development: `aztec-avm-runtime` plus all five patches in dependency order. The base for M12 onward |

**Do not commit onto the `pr/*` or `codetracer` branches by hand.** They are
regenerated from the patch files in `codetracer-specs/upstream-bugs/` by
`just make-fork-branches`, deterministically down to the commit id, and
`just verify-pr-branches` rebuilds every one of them and requires it to equal
what is published. A hand-made fixup would be silently discarded on the next
regeneration — and, worse, would mean the branch filed upstream is not the patch
that was reviewed. Change the patch file, then regenerate.

**`codetracer` is not the neutrality harness.** M3–M10 prove that the patches
change nothing natively by building the pristine base and the patched tree as
separate worktrees and comparing them. A branch with the patches already applied
cannot be the "before" side of that. Do not repoint a check at it.

## Layout

```
<workspace-root>/
├── aztec-avm-runtime/    this repo — the campaign's own work
└── aztec-packages/       the metacraft-labs fork, branch aztec-avm-runtime
```

Both are registered in the workspace manifests under the `codetracer` project.
The fork is a workspace-root **sibling**, not nested under this repo; the
verification checks assert that, so moving it will fail them.

## Before you push

`just check-repo-hygiene` — a flake, a lock, an `.envrc` and no uncommitted
generated files in either repo. `just verify-m0` runs the whole M0 check set.
