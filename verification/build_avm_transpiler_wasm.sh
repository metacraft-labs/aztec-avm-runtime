#!/usr/bin/env bash
# build_avm_transpiler_wasm.sh — M31.
#
#   verification/build_avm_transpiler_wasm.sh [--force]
#
# Not a check: it prints no assertions and is invoked BY checks (`m31_require_build`). It prints
# one `KEY=value` line per artefact on stdout, so a caller reads paths rather than guessing them.
#
# It produces five things, each from a pinned revision and none from a working tree:
#
#   TREE      a build tree holding `avm-transpiler` at the campaign anchor and `noir/noir-repo`
#             at the commit that anchor's submodule pins, WITH the prepared upstream patch applied
#   NARGO     `nargo` built from that same noir, so the fixture artifacts are the version the
#             transpiler's crates expect
#   ARTIFACTS the fixture contracts under `fixtures/transpiler-contracts/`, COMPILED — never
#             committed as JSON, because an artifact nobody re-derives is a constant that rots
#   NATIVE    the native `avm-transpiler` binary
#   MODULE    `avm_transpiler_wasm.wasm`, the cdylib a browser drives
#
# ---------------------------------------------------------------------------------------------
# WHY `aztec-packages/noir/noir-repo` HAS TO BE MATERIALISED AT ALL
#
# It is a git SUBMODULE (`aztec-packages/.gitmodules:23` → `noir-lang/noir.git`) pinned at
# `40d6574f851d926f93e0c3a271bac3e6e82ac905` — *chore: Release Noir(1.0.0-beta.26)* — and in this
# workspace it has never been checked out: the directory exists and is EMPTY. All five of
# `avm-transpiler`'s path dependencies point into it, so before this milestone nothing here could
# build the transpiler at all, natively or otherwise.
#
# The workspace's own `noir` checkout carries that commit in its object store, so it is
# materialised with `git archive` — the same route `build_ct_writer_wasm.sh` uses for
# `codetracer-trace-format`, and for the same reason: an archive of a named revision cannot pick
# up a worktree's uncommitted state.
#
# THIS PARAGRAPH SAID SOMETHING THAT IS NO LONGER TRUE, AND THE CONCLUSION SURVIVES ON A
# DIFFERENT REASON. It read: *"`noir` on `blocktracer` is 1.0.0-beta.18 and the pin is
# 1.0.0-beta.26, with the pin NOT an ancestor of `blocktracer` — so M30's module, which is built
# from the branch, cannot stand in here"*. On 2026-08-30 the tracer branch was reconciled onto the
# beta.26 base, so `blocktracer` now reports **1.0.0-beta.26** and `40d6574f85` **IS** an ancestor
# of it — measured, not assumed (`git merge-base --is-ancestor`).
#
# What still holds, and it was always the stronger half: the branch carries four commits the pin
# does not — the `Field` hex rendering, the fixture repin, the virtual-filesystem compiler and the
# SSA pass-timer fix — so a module built from the branch is not a module built from the pin, and
# `git archive` of a NAMED REVISION is the only route that cannot pick up a worktree's
# uncommitted state. The version equality is now a reason to re-measure rather than a reason to
# substitute: the two trees agree on the release and differ on our own work.
#
# ---------------------------------------------------------------------------------------------
# WHY THE PATCH IS APPLIED HERE RATHER THAN COMMITTED ANYWHERE
#
# `codetracer-specs/upstream-bugs/aztec-transpiler-core-ffi/` holds a prepared upstream
# contribution. Applying it during materialisation means the patch is EXERCISED on every run
# rather than being a file nobody executes — the failure mode `CAMPAIGN-BRIEF.md`'s
# "IT DOES NOT BUILD HERE" rule is about. `git apply --check` runs first, so a patch that has
# rotted against the anchor is a named refusal and not a confusing compile error.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

AZTEC_REPO="${M31_AZTEC_REPO:-$WORKSPACE_ROOT/aztec-packages}"
NOIR_REPO="${M31_NOIR_REPO:-$WORKSPACE_ROOT/noir}"
SPECS_REPO="${M31_SPECS_REPO:-$WORKSPACE_ROOT/codetracer-specs}"

# The two revisions. `AZTEC_REV` is the campaign anchor every prepared patch is based on;
# `avm-transpiler/` is byte-identical between it and `aztec-packages` HEAD, measured with
# `git diff --stat`, so working at the anchor is also working at the tip.
AZTEC_REV="${M31_AZTEC_REV:-233d8e0993}"
NOIR_REV="${M31_NOIR_REV:-40d6574f851d926f93e0c3a271bac3e6e82ac905}"

PATCH="$SPECS_REPO/upstream-bugs/aztec-transpiler-core-ffi/0001-avm-transpiler-take-the-three-C-ABI-type-aliases-fro.patch"
SHIM_SRC="$REPO_ROOT/avm-transpiler-wasm"
FIXTURES="$REPO_ROOT/fixtures/transpiler-contracts"

# ITS OWN VARIABLE, NOT `M31_WORK`. It used to read `M31_WORK`, which `lib_m31_transpiler.sh`
# EXPORTS as the ARM REPORT's directory — so a check invoking this script silently redirected the
# whole build tree into the arms work dir. Nothing was wrong with the artefacts, but a harness
# that deleted `$M31_BUILD_DIR/baseline` to force a rebuild deleted a directory nothing was using,
# the stamp in the real one still matched, and a mutation arm went GREEN because its mutation had
# never taken effect. Found by M31's own mutation matrix (arm M8) and fixed here rather than in
# the harness, because the name collision is the defect.
WORK="${M31_BUILD_WORK:-$HOME/.cache/aztec-m31-transpiler}"
TREE="$WORK/tree"
ARTIFACTS="$WORK/artifacts"

# Under ~/.cache, never `$TMPDIR`: on this host `/tmp` is a RAM-backed tmpfs shared with every
# build. The SAME rustup/cargo homes the rest of the campaign uses — one toolchain, not one per
# milestone.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

die() { printf 'build_avm_transpiler_wasm: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_avm_transpiler_wasm: %s\n' "$*" >&2; }

FORCE=0
BASELINE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    # --baseline builds the SAME tree with the upstream patch NOT applied, natively only. It is
    # what `verify_transpiler_native_build_unaffected` compares against: "native builds are
    # unaffected" is a claim with a check behind it, not an assertion (upstream-bugs/CLAUDE.md).
    --baseline) BASELINE=1 ;;
    *) die "unknown argument [$a]" ;;
  esac
done

[ -d "$AZTEC_REPO/.git" ] || die "no aztec-packages checkout at $AZTEC_REPO"
[ -d "$NOIR_REPO/.git" ] || [ -f "$NOIR_REPO/.git" ] || die "no noir checkout at $NOIR_REPO"
[ -f "$PATCH" ] || die "the prepared upstream patch is missing: $PATCH"
[ -d "$SHIM_SRC/src" ] || die "no shim crate at $SHIM_SRC"
[ -d "$FIXTURES" ] || die "no contract fixtures at $FIXTURES"

git -C "$AZTEC_REPO" cat-file -e "$AZTEC_REV^{commit}" 2>/dev/null || \
  die "aztec-packages does not have $AZTEC_REV"
git -C "$NOIR_REPO" cat-file -e "$NOIR_REV^{commit}" 2>/dev/null || \
  die "the noir checkout does not have $NOIR_REV — that is the commit aztec-packages'
     noir/noir-repo submodule pins at the anchor, and the transpiler's five path dependencies
     all point into it"

# The submodule pin is not typed in twice: it is READ from the tree the anchor names, so a
# different anchor cannot silently keep an old noir.
DECLARED_NOIR="$(git -C "$AZTEC_REPO" ls-tree "$AZTEC_REV" noir/noir-repo | awk '{print $3}')"
[ -n "$DECLARED_NOIR" ] || die "aztec-packages@$AZTEC_REV declares no noir/noir-repo gitlink"
[ "$DECLARED_NOIR" = "$NOIR_REV" ] || \
  die "aztec-packages@$AZTEC_REV pins noir/noir-repo at $DECLARED_NOIR but this build was told
     $NOIR_REV. Building the transpiler against a different noir than upstream pins would make
     every byte-identity claim a claim about a tree upstream does not have."

command -v nix >/dev/null 2>&1 || \
  die "nix is required: neither dev shell carries a wasm32-unknown-unknown rust std"

PATCH_SHA="$(sha256sum "$PATCH" | cut -d' ' -f1)"

# ---- 0. the BASELINE tree: the same two revisions, the patch NOT applied ---------------------
if [ "$BASELINE" = 1 ]; then
  BTREE="$WORK/baseline"
  BSTAMP="$BTREE/.m31-tree-from"
  BSTAMP_WANT="$AZTEC_REV:$NOIR_REV:no-patch"
  if [ "$FORCE" = 1 ] || [ "$(cat "$BSTAMP" 2>/dev/null)" != "$BSTAMP_WANT" ]; then
    say "materialising the UNPATCHED baseline tree"
    rm -rf "$BTREE"
    mkdir -p "$BTREE/noir/noir-repo" || die "could not create $BTREE"
    git -C "$AZTEC_REPO" archive "$AZTEC_REV" avm-transpiler | tar -x -m -C "$BTREE" \
      || die "git archive of avm-transpiler@$AZTEC_REV failed"
    git -C "$NOIR_REPO" archive "$NOIR_REV" | tar -x -m -C "$BTREE/noir/noir-repo" \
      || die "git archive of noir@$NOIR_REV failed"
    # ASSERTED UNPATCHED. A baseline that silently carried the change would make the neutrality
    # comparison a comparison of one tree with itself — the campaign's oldest defect, in a
    # build script.
    grep -q 'use libc::{c_char, c_int, size_t};' "$BTREE/avm-transpiler/src/lib.rs" || \
      die "the baseline tree does not carry the pristine libc import; it is not a baseline"
    grep -q '^libc = ' "$BTREE/avm-transpiler/Cargo.toml" || \
      die "the baseline tree's Cargo.toml does not declare libc; it is not a baseline"
    printf '%s\n' "$BSTAMP_WANT" >"$BSTAMP"
  fi
  BNATIVE="$BTREE/avm-transpiler/target/release/avm-transpiler"
  BBUILD_STAMP="$BTREE/avm-transpiler/target/release/.m31-built-from"
  if [ "$FORCE" = 1 ] || [ ! -x "$BNATIVE" ] || \
     [ "$(cat "$BBUILD_STAMP" 2>/dev/null)" != "$BSTAMP_WANT" ]; then
    say "building the UNPATCHED native avm-transpiler"
    BTREE="$BTREE" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
      nix shell nixpkgs#rustup --command bash -c '
        set -euo pipefail
        export PATH="$CARGO_HOME/bin:$PATH"
        cd "$BTREE/avm-transpiler"
        cargo build --release
      ' >&2 || die "the baseline native build failed"
    [ -x "$BNATIVE" ] || die "the baseline build reported success but $BNATIVE does not exist"
    printf '%s\n' "$BSTAMP_WANT" >"$BBUILD_STAMP"
  fi
  printf 'BASELINE_TREE=%s\n' "$BTREE"
  printf 'BASELINE_NATIVE=%s\n' "$BNATIVE"
  say "baseline ready: $(wc -c <"$BNATIVE") bytes"
  exit 0
fi

TREE_STAMP_WANT="$AZTEC_REV:$NOIR_REV:$PATCH_SHA"
TREE_STAMP="$TREE/.m31-tree-from"

# ---- 1. the tree -----------------------------------------------------------------------------
if [ "$FORCE" = 1 ] || [ "$(cat "$TREE_STAMP" 2>/dev/null)" != "$TREE_STAMP_WANT" ]; then
  say "materialising avm-transpiler@${AZTEC_REV:0:10} + noir@${NOIR_REV:0:10}"
  rm -rf "$TREE"
  mkdir -p "$TREE/noir/noir-repo" || die "could not create $TREE"
  # `-m` so extracted files get the CURRENT time. `git archive` stamps files with the COMMIT's
  # timestamp, and cargo fingerprints on mtime — a 2026-08 archive extracted beside a target
  # directory built minutes ago is the "mutated artefact outlives its restored source" family,
  # and `build_ct_writer_wasm.sh` records meeting it.
  git -C "$AZTEC_REPO" archive "$AZTEC_REV" avm-transpiler | tar -x -m -C "$TREE" \
    || die "git archive of avm-transpiler@$AZTEC_REV failed"
  git -C "$NOIR_REPO" archive "$NOIR_REV" | tar -x -m -C "$TREE/noir/noir-repo" \
    || die "git archive of noir@$NOIR_REV failed"
  [ -d "$TREE/noir/noir-repo/acvm-repo/acvm" ] || \
    die "the materialised noir has no acvm-repo/acvm (is $NOIR_REV the right revision?)"

  ( cd "$TREE" && git apply --check -p1 --directory=. "$PATCH" ) 2>/dev/null \
    || ( cd "$TREE" && git apply --check "$PATCH" ) 2>/dev/null \
    || die "the prepared patch no longer applies to avm-transpiler@$AZTEC_REV.
     That is a real finding rather than a build problem: the patch is offered upstream against
     that commit, and it has to keep applying there."
  ( cd "$TREE" && git apply "$PATCH" ) || die "git apply failed after --check passed"
  # Applied, and ASSERTED applied. `git apply` returning 0 over a tree where the change was
  # already present is not a thing to find out about four artefacts later.
  grep -q 'use core::ffi::{c_char, c_int};' "$TREE/avm-transpiler/src/lib.rs" || \
    die "the patch applied but src/lib.rs does not carry the core::ffi import"
  ! grep -q 'libc' "$TREE/avm-transpiler/Cargo.toml" || \
    die "the patch applied but Cargo.toml still declares libc"
  printf '%s\n' "$TREE_STAMP_WANT" >"$TREE_STAMP"
fi

cp -r "$SHIM_SRC" "$TREE/avm-transpiler-wasm.new" || die "could not copy the shim crate"
rm -rf "$TREE/avm-transpiler-wasm/src" "$TREE/avm-transpiler-wasm/.cargo" \
       "$TREE/avm-transpiler-wasm/Cargo.toml"
mkdir -p "$TREE/avm-transpiler-wasm"
cp -r "$TREE/avm-transpiler-wasm.new/." "$TREE/avm-transpiler-wasm/"
rm -rf "$TREE/avm-transpiler-wasm.new"
# `cp` preserves nothing here (no -p), so the copies are new-mtimed and cargo cannot decline to
# rebuild from them. That is the `cp -p` trap this campaign has now met four times, avoided by
# construction rather than by a `touch` after the fact.

NARGO="$TREE/noir/noir-repo/target/release/nargo"
NATIVE="$TREE/avm-transpiler/target/release/avm-transpiler"
MODULE="$TREE/avm-transpiler-wasm/target/wasm32-unknown-unknown/release/avm_transpiler_wasm.wasm"

# ---- 2. nargo --------------------------------------------------------------------------------
NARGO_STAMP="$TREE/noir/noir-repo/target/release/.m31-built-from"
if [ "$FORCE" = 1 ] || [ ! -x "$NARGO" ] || \
   [ "$(cat "$NARGO_STAMP" 2>/dev/null)" != "$TREE_STAMP_WANT" ]; then
  say "building nargo from noir@${NOIR_REV:0:10} (this is the long pole; it is cached afterwards)"
  # GIT_COMMIT/GIT_DIRTY: `tooling/nargo_cli/build.rs` shells out to `git rev-parse HEAD` unless
  # they are set, and a `git archive` extraction has no `.git`. aztec's own `noir/bootstrap.sh`
  # sets exactly these two for exactly this reason, so this is upstream's escape and not ours.
  TREE="$TREE" NOIR_REV="$NOIR_REV" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
    nix shell nixpkgs#rustup --command bash -c '
      set -euo pipefail
      export PATH="$CARGO_HOME/bin:$PATH"
      export GIT_COMMIT="$NOIR_REV" GIT_DIRTY=false SOURCE_DATE_EPOCH=0
      rustup -q toolchain install 1.89.0 --profile minimal >/dev/null 2>&1 || true
      cd "$TREE/noir/noir-repo"
      cargo build --release -p nargo_cli
    ' >&2 || die "the nargo build failed"
  [ -x "$NARGO" ] || die "the nargo build reported success but $NARGO does not exist"
  printf '%s\n' "$TREE_STAMP_WANT" >"$NARGO_STAMP"
fi

# ---- 3. the fixture artifacts ----------------------------------------------------------------
FIX_STAMP="$ARTIFACTS/.m31-built-from"
FIX_LIST="$(find "$FIXTURES" -type f \( -name '*.nr' -o -name 'Nargo.toml' \) | LC_ALL=C sort)"
FIX_COUNT="$(printf '%s\n' "$FIX_LIST" | grep -c . || true)"
[ "${FIX_COUNT:-0}" -ge 6 ] || \
  die "only ${FIX_COUNT:-0} fixture source files under $FIXTURES; a stamp over an empty list
     matches every build"
FIX_WANT="$( { printf '%s\n' "$FIX_LIST" | xargs sha256sum; sha256sum "$NARGO"; } \
             | sha256sum | cut -d' ' -f1)"
if [ "$FORCE" = 1 ] || [ "$(cat "$FIX_STAMP" 2>/dev/null)" != "$FIX_WANT" ]; then
  say "compiling $((FIX_COUNT / 2)) fixture contracts with nargo"
  rm -rf "$ARTIFACTS"; mkdir -p "$ARTIFACTS" || die "could not create $ARTIFACTS"
  for pkg in "$FIXTURES"/*/; do
    name="$(basename "$pkg")"
    b="$WORK/build/$name"
    rm -rf "$b"; mkdir -p "$b"
    cp -r "$pkg." "$b/"
    ( cd "$b" && "$NARGO" compile ) >"$WORK/build/$name.log" 2>&1 \
      || die "nargo compile failed for the $name fixture; see $WORK/build/$name.log"
    out="$(find "$b/target" -maxdepth 1 -name '*.json' | head -1)"
    [ -n "$out" ] || die "nargo compiled $name and produced no artifact"
    cp "$out" "$ARTIFACTS/$name.json"
  done
  printf '%s\n' "$FIX_WANT" >"$FIX_STAMP"
fi

# ---- 4. the two builds -----------------------------------------------------------------------
# ONE STAMP OVER THE WHOLE SOURCE TREE, not over a hand-written file list. M30's review found a
# stamp naming nine files while the module linked 711, so a change to any of the other 702 left
# the script printing "up to date" and the checks measuring a module built before the change.
# The cost of the wide version was measured there at 62 ms.
SRC_LIST="$(find "$TREE/avm-transpiler" "$TREE/avm-transpiler-wasm" \
                 "$TREE/noir/noir-repo/compiler" "$TREE/noir/noir-repo/tooling" \
                 "$TREE/noir/noir-repo/acvm-repo" \
              -type f \( -name '*.rs' -o -name 'Cargo.toml' -o -name 'config.toml' \) \
              -not -path '*/target/*' 2>/dev/null | LC_ALL=C sort)"
SRC_COUNT="$(printf '%s\n' "$SRC_LIST" | grep -c . || true)"
[ "${SRC_COUNT:-0}" -ge 100 ] || \
  die "the build stamp found only ${SRC_COUNT:-0} source files; a stamp over an empty list
     matches every build. Check the paths."
BUILD_WANT="$( { printf '%s\n' "$SRC_LIST" | xargs sha256sum
                 sha256sum "$TREE/noir/noir-repo/Cargo.lock"; } | sha256sum | cut -d' ' -f1)"

NATIVE_STAMP="$TREE/avm-transpiler/target/release/.m31-built-from"
if [ "$FORCE" = 1 ] || [ ! -x "$NATIVE" ] || \
   [ "$(cat "$NATIVE_STAMP" 2>/dev/null)" != "$BUILD_WANT" ]; then
  say "building the native avm-transpiler"
  TREE="$TREE" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
    nix shell nixpkgs#rustup --command bash -c '
      set -euo pipefail
      export PATH="$CARGO_HOME/bin:$PATH"
      cd "$TREE/avm-transpiler"
      cargo build --release
    ' >&2 || die "the native transpiler build failed"
  [ -x "$NATIVE" ] || die "the native build reported success but $NATIVE does not exist"
  printf '%s\n' "$BUILD_WANT" >"$NATIVE_STAMP"
fi

MODULE_STAMP="$TREE/avm-transpiler-wasm/target/wasm32-unknown-unknown/release/.m31-built-from"
if [ "$FORCE" = 1 ] || [ ! -f "$MODULE" ] || \
   [ "$(cat "$MODULE_STAMP" 2>/dev/null)" != "$BUILD_WANT" ]; then
  say "building avm_transpiler_wasm.wasm for wasm32-unknown-unknown"
  TREE="$TREE" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
    nix shell nixpkgs#rustup --command bash -c '
      set -euo pipefail
      export PATH="$CARGO_HOME/bin:$PATH"
      rustup -q target add wasm32-unknown-unknown >/dev/null 2>&1 || true
      cd "$TREE/avm-transpiler-wasm"
      cargo build --release --target wasm32-unknown-unknown
    ' >&2 || die "the wasm build failed"
  [ -f "$MODULE" ] || die "the wasm build reported success but $MODULE does not exist"
  printf '%s\n' "$BUILD_WANT" >"$MODULE_STAMP"
fi

printf 'TREE=%s\n' "$TREE"
printf 'NARGO=%s\n' "$NARGO"
printf 'ARTIFACTS=%s\n' "$ARTIFACTS"
printf 'NATIVE=%s\n' "$NATIVE"
printf 'MODULE=%s\n' "$MODULE"
printf 'AZTEC_REV=%s\n' "$AZTEC_REV"
printf 'NOIR_REV=%s\n' "$NOIR_REV"
say "ready: module $(wc -c <"$MODULE") bytes, native $(wc -c <"$NATIVE") bytes, \
$(find "$ARTIFACTS" -name '*.json' | wc -l) artifacts"
