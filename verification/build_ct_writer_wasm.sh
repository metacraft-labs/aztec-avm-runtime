#!/usr/bin/env bash
# build_ct_writer_wasm.sh — materialise the trace-format dependency and build `ct_writer.wasm`.
#
#   verification/build_ct_writer_wasm.sh [--native-tests] [--force] [--path-b]
#
# `--path-b` builds DD-7's Path B -- the Nim writer, materialised and cross-compiled by
# `ct-writer/build.rs` at the `trace_format_nim_writer` anchor -- instead of Path A. It is a
# different module, so it goes in a different target directory: sharing one would make each build
# clobber the other's artefact, and a check that then read "the module" would be comparing one
# module with itself and reading the agreement as evidence.
#
# `--native-tests` is refused together with `--path-b`, and refused by name. The Path B feature
# builds only for wasm32 (see `ct-writer/build.rs` for why the second host toolchain was declined),
# so a host `cargo test` under it fails inside a build script with a message about a target, four
# crates away from the flag that caused it.
#
# Not a check: it prints no assertions and is invoked BY checks (`m24_require_module`). Modelled
# on `build_avm_wasm.sh`, which does the same job for the AVM.
#
# ---------------------------------------------------------------------------
# THE DEPENDENCY COMES OUT OF THE OBJECT STORE, NEVER OUT OF A WORKTREE.
#
# `git archive <rev>` reads the object database. The trap this closes is a REVISION difference,
# not a location one: `codetracer-trace-format` has a worktree at `../ctf-wt-wasm` sitting on the
# branch this revision is the tip of, and copying from it would silently pick up whatever that
# worktree currently holds — including uncommitted edits, and including the branch having moved.
# M22's review turned the same instruction into an enforced precondition for `upstream/tsavm`;
# this is the same enforcement for a different repository.
#
# The revision is NOT declared here. It is `pins.json`'s `trace_format` anchor, because pins.json
# is the single authority for every pin this repo depends on (PINS.md), and a sha1 typed into a
# shell script is a second authority by another name.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

CT_WRITER_DIR="$REPO_ROOT/ct-writer"
DEPS_DIR="$CT_WRITER_DIR/build-wasm-deps"
CTF_DIR="$DEPS_DIR/ctf"
STAMP="$DEPS_DIR/materialised-at"

TRACE_FORMAT_REPO="${TRACE_FORMAT_REPO:-$WORKSPACE_ROOT/codetracer-trace-format}"

# Both under ~/.cache: `$TMPDIR` on this host is a 32 GB tmpfs shared with every build, and a
# cargo registry in RAM is how `/tmp` filled twice during M22's sweep.
export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

die() { printf 'build_ct_writer_wasm: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_ct_writer_wasm: %s\n' "$*"; }

NATIVE_TESTS=0
FORCE=0
# `` = the crate's DEFAULT, which is what the runtime ships; `a` and `b` name a path explicitly.
#
# BOTH ARMS ARE EXPLICIT AND THE DEFAULT IS A THIRD THING, deliberately. When `path-a` was the
# default, "no flag" and "--path-a" were the same build and one spelling could stand for both.
# Flipping the default to `path-b` would have made every unflagged caller silently build the OTHER
# writer — including `m41_require_path_a`, whose whole job is to produce the module the comparison
# calls Path A. A check comparing a module with itself reports agreement, and agreement is what it
# was looking for.
ARM=""
for a in "$@"; do
  case "$a" in
    --native-tests) NATIVE_TESTS=1 ;;
    --force) FORCE=1 ;;
    --path-a) ARM=a ;;
    --path-b) ARM=b ;;
    *) die "unknown argument [$a]" ;;
  esac
done
PATH_B=0
[ "$ARM" = b ] && PATH_B=1
if [ "$PATH_B" = 1 ] && [ "$NATIVE_TESTS" = 1 ]; then
  die "--path-b and --native-tests cannot be combined: the path-b feature builds only for wasm32,
     so a host \`cargo test\` under it dies inside ct-writer/build.rs with a message about a
     target rather than about this flag. Run the native tests against Path A."
fi

# ---- the pinned revision ---------------------------------------------------
REV="$(python3 - "$REPO_ROOT/pins.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
a = p["anchors"].get("trace_format")
print(a["commit"] if a else "")
PY
)" || die "pins.json could not be read"
case "$REV" in
  [0-9a-f][0-9a-f]*) : ;;
  *) die "pins.json declares no 'trace_format' anchor commit" ;;
esac

[ -e "$TRACE_FORMAT_REPO/.git" ] || die "no codetracer-trace-format checkout at $TRACE_FORMAT_REPO"
git -C "$TRACE_FORMAT_REPO" cat-file -e "$REV^{commit}" 2>/dev/null \
  || die "$TRACE_FORMAT_REPO does not have the pinned trace_format revision $REV"

# ---- materialise -----------------------------------------------------------
if [ "$FORCE" = 1 ] || [ ! -f "$STAMP" ] || [ "$(cat "$STAMP" 2>/dev/null)" != "$REV" ]; then
  say "materialising codetracer-trace-format @ ${REV:0:10} from the object store"
  rm -rf "$CTF_DIR"
  mkdir -p "$CTF_DIR"
  # `-m` — EXTRACT WITH THE CURRENT TIME, NOT THE ARCHIVE'S.
  #
  # `git archive` stamps every file with the COMMIT's timestamp, and cargo's fingerprint is
  # mtime-based. So re-materialising at a different revision can leave the new sources OLDER than
  # the rlibs a previous revision's build left in `target/`, and cargo then reuses them. Measured:
  # moving the pin to the column-aware anchor, building, moving it back, building, and moving it
  # forward again produced a build in which `codetracer_ctfs` was NOT recompiled and
  # `codetracer_trace_writer` was — four `cannot find function \`compress_pledged\` in crate
  # \`codetracer_ctfs\`` errors from a tree that has it. That direction fails loudly; the campaign
  # brief records the same mechanism in the direction that does NOT — "a mutated artefact outlived
  # its restored source, because cargo'"'"'s fingerprint is mtime-based and the restore put the
  # original timestamp back" — and that one produced a wrong number nobody could see.
  #
  # With `-m` every materialised file is newer than anything built before it, so a revision change
  # always invalidates. `--force` alone did not, which is what made this look like a broken branch.
  git -C "$TRACE_FORMAT_REPO" archive "$REV" | tar -x -m -C "$CTF_DIR" \
    || die "git archive of $REV failed"
  # The extracted tree carries its own `[workspace]` root. Our crate declares path dependencies
  # INTO it, which makes cargo treat those crates as members of that workspace and our crate as a
  # separate one — which is what we want, and which needs the extracted root left alone.
  printf '%s\n' "$REV" >"$STAMP"
else
  say "codetracer-trace-format @ ${REV:0:10} already materialised"
fi

for c in codetracer_trace_types codetracer_trace_writer codetracer_ctfs; do
  [ -d "$CTF_DIR/$c" ] || die "the materialised tree has no $c (is $REV the right revision?)"
done

# ---- build -----------------------------------------------------------------
# `capnp` is a HARD build-time dependency and its absence does not say so: without it the build
# dies inside `codetracer_trace_format_capnp`'s build script with `exit status: 101`, four crates
# deep, which reads like a broken branch rather than a missing tool.
command -v nix >/dev/null 2>&1 || die "nix is required (the rust wasm toolchain is not in either dev shell)"

case "$ARM" in
  b)
    TARGET_DIR="${M41_PATH_B_TARGET:-$HOME/.cache/aztec-m41-writer/target-path-b}"
    FEATURES="--no-default-features --features path-b"
    ;;
  a)
    # Its own target directory for the same reason Path B has one: two modules that overwrite each
    # other are one module a check can compare with itself.
    TARGET_DIR="${M41_PATH_A_TARGET:-$HOME/.cache/aztec-m41-writer/target-path-a}"
    FEATURES="--no-default-features --features path-a"
    ;;
  *)
    # The DEFAULT — whatever `ct-writer/Cargo.toml` says the runtime ships. Every consumer that
    # does not care which writer wrote a container builds this one, and `TRACE-ABI.md` §7's byte
    # count is a figure about it.
    TARGET_DIR="$CT_WRITER_DIR/target"
    FEATURES=""
    ;;
esac
mkdir -p "$TARGET_DIR" || die "could not create $TARGET_DIR"
OUT="$TARGET_DIR/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"

# THE C TOOLCHAIN FOR `wasm32-unknown-unknown`, WHICH CARGO CANNOT STATE AND THE BUILD SCRIPT MUST.
#
# `zstd-sys` compiles C when the trace-format tree selects the C libzstd backend, and `cc-rs` looks
# for `CC_<target>` / `AR_<target>` / `CFLAGS_<target>`. With none set it falls back to the host
# `gcc`, which dies compiling `cover.c` for a target it cannot emit — four crates deep, with a
# message about a C file and nothing about a toolchain.
#
# The dev shell already ships wasi-sdk 33 and exports `WASI_SDK_PATH`, so this is three lines. No
# sysroot and no wasi-libc include path: `zstd-sys` ships its own `wasm-shim/` and turns it on for
# this triple. Overridable, so a caller with another toolchain is not fought.
if [ -n "${WASI_SDK_PATH:-}" ]; then
  export CC_wasm32_unknown_unknown="${CC_wasm32_unknown_unknown:-$WASI_SDK_PATH/bin/clang}"
  export AR_wasm32_unknown_unknown="${AR_wasm32_unknown_unknown:-$WASI_SDK_PATH/bin/llvm-ar}"
  export CFLAGS_wasm32_unknown_unknown="${CFLAGS_wasm32_unknown_unknown:---target=wasm32-unknown-unknown}"
fi

build_script='
set -euo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
rustup -q toolchain install stable --profile minimal >/dev/null 2>&1 || true
rustup -q target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$CT_WRITER_DIR"
cargo build --release --target wasm32-unknown-unknown --target-dir "$TARGET_DIR" $FEATURES
'
if [ "$NATIVE_TESTS" = 1 ]; then
  # `--no-default-features --features path-a`, AND IT IS NOT A PREFERENCE. These tests run on the
  # HOST, and Path B builds only for wasm32 — `ct-writer/build.rs` refuses any other target by
  # name, so a host `cargo test` under the default feature set dies inside a build script with a
  # message about a target rather than about the tests. What they exercise is this module's own
  # bookkeeping — the session, the position FIFO, the rung table, the counters, the refusals —
  # which is identical under both backends because none of it is behind the seam. Path A is
  # therefore the arm that can host them, not the arm they are about.
  #
  # `--test-threads=1` because the module state is global — wasm is single-threaded and this
  # module has no lock. The tests take a serialising guard of their own as well; belt and braces,
  # because a test added later without the guard would otherwise fail intermittently and be
  # written off as a flake.
  build_script="$build_script"'
cargo test --release --no-default-features --features path-a -- --test-threads=1
'
fi

# `nim` and `nix` must survive into the build shell: `ct-writer/build.rs` runs both under
# `--path-b`, and `nix shell` does not remove them from PATH -- but `PATH` is what the inner
# `bash -c` inherits, so it is passed explicitly rather than assumed.
CT_WRITER_DIR="$CT_WRITER_DIR" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
  TARGET_DIR="$TARGET_DIR" FEATURES="$FEATURES" PATH="$PATH" \
  CC_wasm32_unknown_unknown="${CC_wasm32_unknown_unknown:-}" \
  AR_wasm32_unknown_unknown="${AR_wasm32_unknown_unknown:-}" \
  CFLAGS_wasm32_unknown_unknown="${CFLAGS_wasm32_unknown_unknown:-}" \
  nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c "$build_script" \
  || die "the wasm build failed"

[ -f "$OUT" ] || die "the build reported success but $OUT does not exist"
case "$ARM" in
  b) say "built $OUT ($(wc -c <"$OUT") bytes) -- PATH B, the Nim writer, against the trace_format_nim_writer anchor" ;;
  a) say "built $OUT ($(wc -c <"$OUT") bytes) -- PATH A, the pure-Rust writer, against trace_format ${REV:0:10}" ;;
  *) say "built $OUT ($(wc -c <"$OUT") bytes) -- the crate's DEFAULT arm" ;;
esac
printf '%s\n' "$OUT"
