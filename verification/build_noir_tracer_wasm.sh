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
# THE BUILD RUNS IN A STAGED COPY, NOT IN THE WORKTREE. `cargo build` rewrites `Cargo.lock`
# whenever the lock no longer matches what the manifest's path dependencies declare, and the
# worktree's path dependencies are `../ctf-wt-wasm/...` -- a worktree that moves with
# `pins.json`'s `trace_format` anchor. The committed lock on `wasm/webpage` describes the writer
# revision it was committed against, so after any writer move a build in place WROTE
# `Cargo.lock` into the worktree and the dirty-tree check below refused every later build:
# measured, m30 0/4 with ` M Cargo.lock`. So the tree is materialised from the worktree's HEAD
# by `git archive`, with the one tolerated edit copied over it, beside a `ctf-wt-wasm` link so
# the same relative paths resolve to the same writer. Cargo may re-resolve THAT copy's lock;
# the difference is kept in `$M30_WORK/cargo-lock.diff` rather than discarded.
#
# The target directory is still `<worktree>/target/`, which that repository gitignores, as a
# build cache, and the built module is COPIED into M30's own work directory. Nothing downstream
# reads the worktree.
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
# THE WRITER THE TRACER LINKS IS PART OF WHAT WAS BUILT, so it is part of the stamp. Without it a
# `trace_format` move left the cached module in place, built against the previous writer.
CTF_WT="$WORKSPACE_ROOT/ctf-wt-wasm"
CTF_HEAD="$(git -C "$CTF_WT" rev-parse HEAD 2>/dev/null)" || die "cannot read $CTF_WT's HEAD (the writer the tracer's path dependencies name)"
SRC_SHA="$(sha256sum "$CRATE_DIR"/src/*.rs "$CRATE_DIR/Cargo.toml" "$CRATE_DIR/.cargo/config.toml" 2>/dev/null | sha256sum | cut -d' ' -f1)"
# THE CRATE'S OWN rust-toolchain FILE NAMES THE COMPILER, and lib_toolchain.sh holds the build to
# that channel exactly (installed by version, repaired if a garbage collection broke it, rooted, and
# refused unless `rustc --version` agrees). It is in the stamp so a different compiler rebuilds.
. "$HERE/lib_toolchain.sh"
RUST_VER="$(tc_toolchain_file_channel "$CRATE_DIR")" || die "$CRATE_DIR has no rust-toolchain file to take the channel from"
STAMP_WANT="$WT_HEAD $GLUE_SHA $SRC_SHA rust-$RUST_VER ctf-$CTF_HEAD"

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
TC_PATH="$(tc_rust_ensure "$RUST_VER" "$CRATE_DIR")" || die "the rust toolchain $RUST_VER could not be made usable"
build_script='
set -euo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
case "$(rustc --version)" in "rustc $RUSTUP_TOOLCHAIN "*) : ;; *) echo "rustc is not $RUSTUP_TOOLCHAIN: $(rustc --version)" >&2; exit 1 ;; esac
cd "$STAGE_CRATE"
cargo build --release --no-default-features
'

# THE C TOOLCHAIN FOR `wasm32-unknown-unknown`, the same three variables `build_ct_writer_wasm.sh`
# exports and for the same reason: the writer this tracer links compiles C libzstd through
# `zstd-sys`, and `cc-rs` with no `CC_wasm32_unknown_unknown` falls back to the host `gcc`, which
# dies on `-I wasm-shim/` four crates deep. Required rather than optional here, because there is no
# writer revision on the pinned line that builds without it.
[ -n "${WASI_SDK_PATH:-}" ] || die "WASI_SDK_PATH is not set; the writer's C libzstd needs the dev shell's wasi-sdk clang (run it inside this repository's dev shell)"
export CC_wasm32_unknown_unknown="${CC_wasm32_unknown_unknown:-$WASI_SDK_PATH/bin/clang}"
export AR_wasm32_unknown_unknown="${AR_wasm32_unknown_unknown:-$WASI_SDK_PATH/bin/llvm-ar}"
export CFLAGS_wasm32_unknown_unknown="${CFLAGS_wasm32_unknown_unknown:---target=wasm32-unknown-unknown}"

# The staged tree: `$STAGE_ROOT/<worktree name>` from `git archive` of the worktree's HEAD plus
# the tolerated edit, and `$STAGE_ROOT/ctf-wt-wasm` linking the real writer worktree, so the
# manifest's `../ctf-wt-wasm/...` resolves exactly as it does from the worktree.
STAGE_ROOT="$M30_WORK/staged-tree"
STAGE="$STAGE_ROOT/$(basename "$WT")"
STAGE_CRATE="$STAGE/${CRATE_DIR#"$WT"/}"
rm -rf "$STAGE_ROOT" && mkdir -p "$STAGE" || die "could not create $STAGE"
git -C "$WT" archive "$WT_HEAD" | tar -x -C "$STAGE" || die "git archive of $WT at $WT_HEAD failed"
cp -f "$WT/$ALLOWED_EDIT" "$STAGE/$ALLOWED_EDIT" || die "could not stage $ALLOWED_EDIT"
ln -s "$CTF_WT" "$STAGE_ROOT/ctf-wt-wasm" || die "could not link $CTF_WT into $STAGE_ROOT"
cp -f "$STAGE/Cargo.lock" "$M30_WORK/cargo-lock.committed" 2>/dev/null || :

say "building $STAGE_CRATE, staged from $WT @ ${WT_HEAD:0:10} (--no-default-features, so no wasm-bindgen glue)"
STAGE_CRATE="$STAGE_CRATE" CARGO_TARGET_DIR="$WT/target" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" RUSTUP_TOOLCHAIN="$RUST_VER" \
  PATH="$TC_PATH:$PATH" bash -c "$build_script" >&2 \
  || die "the tracer wasm build failed"

[ -f "$BUILT" ] || die "the build reported success but $BUILT does not exist"

if diff -u "$M30_WORK/cargo-lock.committed" "$STAGE/Cargo.lock" >"$M30_WORK/cargo-lock.diff" 2>&1; then
  say "the worktree's committed Cargo.lock resolved unchanged"
else
  say "cargo re-resolved the STAGED Cargo.lock against ctf-wt-wasm @ ${CTF_HEAD:0:10}; the difference is in $M30_WORK/cargo-lock.diff"
fi

# THE WORKTREE MUST BE AS CLEAN AS IT WAS. `target/` is gitignored there, but asserting it
# rather than assuming it is the whole point of the rule above.
WT_DIRTY_AFTER="$(git -C "$WT" status --porcelain 2>/dev/null | grep -v " $ALLOWED_EDIT\$" | head -5)"
[ -z "$WT_DIRTY_AFTER" ] || \
  die "building left $WT dirty beyond $ALLOWED_EDIT: $WT_DIRTY_AFTER"

cp -f "$BUILT" "$OUT"
printf '%s\n' "$STAMP_WANT" >"$STAMP"
say "built and copied to $OUT ($(wc -c <"$OUT") bytes)"
printf '%s\n' "$OUT"
