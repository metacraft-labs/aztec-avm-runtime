#!/usr/bin/env bash
# build_noir_tracer_wasm.sh — build `noir_tracer_wasm.wasm`, the module M30's page turns a
# resolved program into a real `.ct` container with.
#
#   verification/build_noir_tracer_wasm.sh [--force]
#
# Not a check: it prints no assertions and is invoked BY checks (`m30_require_modules`).
#
# ---------------------------------------------------------------------------
# THE SOURCE WORKTREE IS READ-ONLY, AND THAT IS ENFORCED RATHER THAN INSTRUCTED.
#
# `tooling/tracer_wasm` exists on ONE branch — `wasm/webpage`, checked out at
# `../noir-wt4-webpage` — and that branch is UNPUBLISHED. `JOIN-SHAPE.md` §2 fact 7 is that
# `git for-each-ref refs/remotes --contains` is empty for its HEAD, and the whole "the shared
# writer is not shippable" verdict rests on it; `verify_oq7_shared_writer_verdict_recorded`
# asserts that emptiness and would go red the moment the branch were pushed. So M30 builds
# from that worktree and writes nothing into it that git can see.
#
# It also carries ONE uncommitted edit, deliberately: M26's OQ-4 `Field` rendering in
# `tooling/tracer/src/tracer_glue.rs`. `build_oq7_shared_writer_probe.sh` tolerates exactly
# that path by name and refuses any other; this script applies the same rule, for the same
# reason and with the same spelling, so a stray edit made while working on M30 fails HERE —
# loudly, naming the file — rather than silently changing what M26's probe measures.
#
# `cargo build` writes into `<worktree>/target/`, which that repository gitignores, and the
# built module is COPIED into M30's own work directory. Nothing downstream reads the
# worktree.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

WT="${M30_TRACER_ROOT:-$WORKSPACE_ROOT/noir-wt4-webpage}"
CRATE_DIR="$WT/tooling/tracer_wasm"
BUILT="$WT/target/wasm32-unknown-unknown/release/noir_tracer_wasm.wasm"

M30_WORK="${M30_WORK:-$HOME/.cache/aztec-m30-vfs}"
OUT="$M30_WORK/noir_tracer_wasm.wasm"
STAMP="$M30_WORK/.tracer-built-from"

export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

die() { printf 'build_noir_tracer_wasm: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_noir_tracer_wasm: %s\n' "$*" >&2; }

FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) die "unknown argument [$a]" ;;
  esac
done

[ -d "$CRATE_DIR" ] || die "no tracer_wasm crate at $CRATE_DIR"
[ -e "$WT/.git" ] || die "$WT is not a git worktree"

# THE ONE TOLERATED EDIT, BY NAME. Identical to `build_oq7_shared_writer_probe.sh:71-74`.
ALLOWED_EDIT="tooling/tracer/src/tracer_glue.rs"
WT_DIRTY="$(git -C "$WT" status --porcelain 2>/dev/null | grep -v " $ALLOWED_EDIT\$" | head -5)"
[ -z "$WT_DIRTY" ] || \
  die "the Noir worktree $WT carries edits other than $ALLOWED_EDIT. M30 builds from it and must
     never write to it; a module built from an edited worktree is evidence about nothing, and an
     edit here also changes what M26's OQ-7 probe measures. Found: $WT_DIRTY"

# AND THE BRANCH MUST STILL BE UNPUBLISHED. Not because M30 needs it to be, but because M30
# is the second consumer of this worktree and a second consumer is exactly how a fact that
# one milestone rests on gets changed by another. If this ever fails, OQ-7 has been reopened
# and `JOIN-SHAPE.md` §6 says so before this script does.
WT_HEAD="$(git -C "$WT" rev-parse HEAD 2>/dev/null)" || die "cannot read $WT's HEAD"
PUBLISHED="$(git -C "$WT" for-each-ref --contains "$WT_HEAD" --format='%(refname)' refs/remotes 2>/dev/null | head -3)"
[ -z "$PUBLISHED" ] || \
  die "the worktree's HEAD $WT_HEAD is contained in published remote refs ($PUBLISHED). That
     contradicts JOIN-SHAPE.md §2 fact 7, which OQ-7's verdict rests on. Do not paper over it here."

mkdir -p "$M30_WORK"

GLUE_SHA="$(sha256sum "$WT/$ALLOWED_EDIT" | cut -d' ' -f1)"
SRC_SHA="$(sha256sum "$CRATE_DIR"/src/*.rs "$CRATE_DIR/Cargo.toml" "$CRATE_DIR/.cargo/config.toml" 2>/dev/null | sha256sum | cut -d' ' -f1)"
STAMP_WANT="$WT_HEAD $GLUE_SHA $SRC_SHA"

if [ "$FORCE" = 0 ] && [ -f "$OUT" ] && [ -f "$STAMP" ] && \
   [ "$(cat "$STAMP" 2>/dev/null)" = "$STAMP_WANT" ]; then
  say "up to date ($(wc -c <"$OUT") bytes)"
  printf '%s\n' "$OUT"
  exit 0
fi

command -v nix >/dev/null 2>&1 || die "nix is required (the rust wasm toolchain is in neither dev shell)"

# `capnp` is a HARD build-time dependency of `codetracer_trace_format_capnp`'s build script
# and its absence does not say so: the build dies with `exit status: 101` four crates deep,
# which reads like a broken branch rather than a missing tool. Measured on this host, in this
# milestone, before the tool was added — the same trap `build_ct_writer_wasm.sh` records.
build_script='
set -euo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
rustup -q toolchain install stable --profile minimal >/dev/null 2>&1 || true
rustup -q target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$CRATE_DIR"
cargo build --release --no-default-features
'

say "building $CRATE_DIR (--no-default-features, so no wasm-bindgen glue)"
CRATE_DIR="$CRATE_DIR" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
  nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c "$build_script" >&2 \
  || die "the tracer wasm build failed"

[ -f "$BUILT" ] || die "the build reported success but $BUILT does not exist"

# THE WORKTREE MUST BE AS CLEAN AS IT WAS. `target/` is gitignored there, but asserting it
# rather than assuming it is the whole point of the rule above.
WT_DIRTY_AFTER="$(git -C "$WT" status --porcelain 2>/dev/null | grep -v " $ALLOWED_EDIT\$" | head -5)"
[ -z "$WT_DIRTY_AFTER" ] || \
  die "building left $WT dirty beyond $ALLOWED_EDIT: $WT_DIRTY_AFTER"

cp -f "$BUILT" "$OUT"
printf '%s\n' "$STAMP_WANT" >"$STAMP"
say "built and copied to $OUT ($(wc -c <"$OUT") bytes)"
printf '%s\n' "$OUT"
