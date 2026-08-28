#!/usr/bin/env bash
# build_noir_vfs_wasm.sh — build `noir_wasm.wasm`, the module M30's page compiles a virtual
# filesystem with.
#
#   verification/build_noir_vfs_wasm.sh [--force]
#
# Not a check: it prints no assertions and is invoked BY checks (`m30_require_modules`).
# Modelled on `build_ct_writer_wasm.sh`, which does the same job for the trace writer.
#
# ---------------------------------------------------------------------------
# WHY THE SOURCE IS A WORKTREE AND NOT AN OBJECT-STORE ARCHIVE.
#
# `build_ct_writer_wasm.sh` materialises its dependency with `git archive <rev>` out of the
# object store, because that dependency is PINNED: `pins.json` names a commit and a build
# from a worktree could silently pick up a different one. This module's source is not a
# dependency — it is the milestone's own work, uncommitted by construction (an
# implementation agent makes no commits), so there is no commit to archive. The stamp below
# therefore hashes the SOURCE FILES rather than a revision, which is the same discipline
# `build_oq7_shared_writer_probe.sh` applies to the one uncommitted edit it tolerates: a
# HEAD-only stamp would leave a module built before an edit looking current, which is "a
# mutated artefact outliving its restored source" with the signs reversed.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

NOIR_ROOT="${M30_NOIR_ROOT:-$WORKSPACE_ROOT/noir}"
CRATE_DIR="$NOIR_ROOT/compiler/wasm"
OUT="$NOIR_ROOT/target/wasm32-unknown-unknown/release/noir_wasm.wasm"
STAMP="$NOIR_ROOT/target/wasm32-unknown-unknown/release/.m30-built-from"

# Both under ~/.cache: `$TMPDIR` on this host is a RAM-backed tmpfs shared with every build,
# and a cargo registry in RAM is how `/tmp` filled twice during M22's sweep. These are the
# SAME two directories `build_ct_writer_wasm.sh` uses, deliberately — one rustup toolchain
# for the campaign rather than one per milestone.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

die() { printf 'build_noir_vfs_wasm: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_noir_vfs_wasm: %s\n' "$*" >&2; }

FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) die "unknown argument [$a]" ;;
  esac
done

[ -d "$CRATE_DIR" ] || die "no noir compiler/wasm crate at $CRATE_DIR"
[ -f "$CRATE_DIR/src/vfs.rs" ] || \
  die "$CRATE_DIR/src/vfs.rs does not exist; M30's resolver is not in this checkout"
[ -f "$CRATE_DIR/.cargo/config.toml" ] || \
  die "$CRATE_DIR/.cargo/config.toml is missing; cargo reads the wasm target and the getrandom
     backend from it, and only from the INVOCATION directory"

# THE TOUCH LIST: the files this milestone edits, which are also the ones cargo has to be
# told about (see the mtime paragraph below). The evaluator file is here because M30 changed
# it — the SSA pass timer's unconditional clock read, which is what made the bare path reach
# a JS import — and a module built before that change answers a different question about
# imports.
#
# THIS LIST IS **NOT** THE STAMP, AND THAT DISTINCTION IS A FINDING RATHER THAN A DESIGN.
# It used to be: `STAMP_WANT` was the sha256 of these nine files, and when it matched the
# script exited BEFORE invoking cargo at all. But the module links the whole Noir compiler —
# 711 `.rs` files under `compiler/` and `tooling/` — so a change to any of the other 702 left
# the stamp matching, no cargo running, and the four checks measuring a module built before
# the change while reporting green. That is "a mutated artefact outlived its restored source"
# with a wider aperture than the `cp -p` case below: there, cargo was invoked and declined;
# here it was never invoked. Found by M30's review. Closing it costs **62 ms** — measured, by
# hashing all 711 on this host — which is nothing beside the build it guards.
STAMP_INPUTS=(
  "$CRATE_DIR/src/vfs.rs"
  "$CRATE_DIR/src/compile_vfs.rs"
  "$CRATE_DIR/src/compile.rs"
  "$CRATE_DIR/src/compile_new.rs"
  "$CRATE_DIR/src/errors.rs"
  "$CRATE_DIR/src/lib.rs"
  "$CRATE_DIR/Cargo.toml"
  "$CRATE_DIR/.cargo/config.toml"
  "$NOIR_ROOT/compiler/noirc_evaluator/src/ssa/builder.rs"
)
for f in "${STAMP_INPUTS[@]}"; do
  [ -f "$f" ] || die "the touch list names $f, which does not exist"
done

# The stamp proper: every Rust source and every manifest the module could link, sorted so the
# digest does not depend on `find`'s directory order, plus the two files that are neither
# (`.cargo/config.toml` carries the target and the getrandom backend; `Cargo.lock` carries
# the dependency revisions).
STAMP_TREE="$(find "$NOIR_ROOT/compiler" "$NOIR_ROOT/tooling" "$NOIR_ROOT/acvm-repo" \
                -type f \( -name '*.rs' -o -name 'Cargo.toml' \) 2>/dev/null | LC_ALL=C sort)"
STAMP_TREE_COUNT="$(printf '%s\n' "$STAMP_TREE" | grep -c . || true)"
# A STAMP OVER NOTHING MATCHES EVERYTHING. If the paths above ever stop resolving, the digest
# of an empty list is a constant and every build would report "up to date" forever — the
# emptiest form of the defect this stamp exists to prevent. Refuse instead.
[ "${STAMP_TREE_COUNT:-0}" -ge 100 ] || \
  die "the stamp found only ${STAMP_TREE_COUNT:-0} source files under $NOIR_ROOT/{compiler,tooling,acvm-repo};
     a stamp taken over an empty list matches every build. Check the paths."
STAMP_WANT="$( { printf '%s\n' "$STAMP_TREE" | xargs sha256sum
                 sha256sum "$CRATE_DIR/.cargo/config.toml" "$NOIR_ROOT/Cargo.lock"; } \
               | sha256sum | cut -d' ' -f1)"

if [ "$FORCE" = 0 ] && [ -f "$OUT" ] && [ -f "$STAMP" ] && \
   [ "$(cat "$STAMP" 2>/dev/null)" = "$STAMP_WANT" ]; then
  say "up to date ($(wc -c <"$OUT") bytes)"
  printf '%s\n' "$OUT"
  exit 0
fi

command -v nix >/dev/null 2>&1 || \
  die "nix is required: neither dev shell carries a wasm32-unknown-unknown rust std, and this
     module is built the way build_ct_writer_wasm.sh builds its own"

# THE STAMP IS CONTENT-BASED AND CARGO'S FINGERPRINT IS MTIME-BASED, AND THE GAP BETWEEN
# THEM PRODUCES A MODULE THAT DOES NOT MATCH ITS SOURCE.
#
# Measured, in this milestone, by the mutation harness: an arm mutated
# `noirc_evaluator/src/ssa/builder.rs`, built, then restored the file with `cp -p` — which
# puts the original mtime back. The restored file was OLDER than the rlib the mutated one had
# produced, so cargo declined to recompile it; this script's content stamp correctly said
# "rebuild", ran `cargo build`, and cargo emitted a module STILL CARRYING THE MUTATION while
# reporting success. Four checks then failed for a reason that had nothing to do with the tree
# on disk.
#
# `touch`ing the stamped inputs before the build closes it: whatever their timestamps were,
# they are now newer than anything built from them. This is the same mechanism
# `build_ct_writer_wasm.sh` handles with `tar -x -m`, in the other direction.
for f in "${STAMP_INPUTS[@]}"; do touch "$f"; done

build_script='
set -euo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
rustup -q toolchain install stable --profile minimal >/dev/null 2>&1 || true
rustup -q target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$CRATE_DIR"
cargo build --release
'

say "building $CRATE_DIR for wasm32-unknown-unknown"
CRATE_DIR="$CRATE_DIR" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
  nix shell nixpkgs#rustup --command bash -c "$build_script" >&2 \
  || die "the wasm build failed"

[ -f "$OUT" ] || die "the build reported success but $OUT does not exist"
printf '%s\n' "$STAMP_WANT" >"$STAMP"
say "built $OUT ($(wc -c <"$OUT") bytes)"
printf '%s\n' "$OUT"
