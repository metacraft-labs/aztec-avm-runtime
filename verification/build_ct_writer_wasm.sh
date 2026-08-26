#!/usr/bin/env bash
# build_ct_writer_wasm.sh — materialise the trace-format dependency and build `ct_writer.wasm`.
#
#   verification/build_ct_writer_wasm.sh [--native-tests] [--force]
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
for a in "$@"; do
  case "$a" in
    --native-tests) NATIVE_TESTS=1 ;;
    --force) FORCE=1 ;;
    *) die "unknown argument [$a]" ;;
  esac
done

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
  git -C "$TRACE_FORMAT_REPO" archive "$REV" | tar -x -C "$CTF_DIR" \
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

OUT="$CT_WRITER_DIR/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"

build_script='
set -euo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
rustup -q toolchain install stable --profile minimal >/dev/null 2>&1 || true
rustup -q target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$CT_WRITER_DIR"
cargo build --release --target wasm32-unknown-unknown
'
if [ "$NATIVE_TESTS" = 1 ]; then
  # `--test-threads=1` because the module state is global — wasm is single-threaded and this
  # module has no lock. The tests take a serialising guard of their own as well; belt and braces,
  # because a test added later without the guard would otherwise fail intermittently and be
  # written off as a flake.
  build_script="$build_script"'
cargo test --release -- --test-threads=1
'
fi

CT_WRITER_DIR="$CT_WRITER_DIR" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
  nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c "$build_script" \
  || die "the wasm build failed"

[ -f "$OUT" ] || die "the build reported success but $OUT does not exist"
say "built $OUT ($(wc -c <"$OUT") bytes) against trace_format ${REV:0:10}"
printf '%s\n' "$OUT"
