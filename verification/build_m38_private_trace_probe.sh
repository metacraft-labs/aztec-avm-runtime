#!/usr/bin/env bash
# Build the M38 private-trace probe: an Aztec private function stepped by the real Noir tracer.
#
#   verification/build_m38_private_trace_probe.sh [--force]     (or: just m38-probe-build)
#
# It stages a scratch crate under `$M38_WORK/probe`, builds it, and leaves the binary at
# `$M38_WORK/probe/bin/m38probe`. `lib_m38_private_trace.sh`'s `m38_require_arms` runs it.
#
# ---------------------------------------------------------------------------------------------
# WHICH NOIR CHECKOUT, AND WHY IT IS NOT THE ONE `build_oq7_shared_writer_probe.sh` USES.
#
# `build_oq7_shared_writer_probe.sh` builds from `../noir-wt4-webpage`, the `wasm/webpage`
# worktree, because that is the only branch carrying `tooling/tracer_wasm/src/ctfs_sink.rs` and the
# Path A writer. This probe builds from **`../noir` on `codetracer`**, the branch that ships, for
# two reasons that point the same way:
#
#   1. `trace_circuit_with_executor` — the seam this milestone adds — is on `codetracer`. Putting
#      it on `wasm/webpage` instead would mean editing a worktree `JOIN-SHAPE.md` §2 fact 7 rests
#      on, and OQ-7's whole "not shippable" verdict rests on that fact.
#   2. The container is written by `NimWriterSink` over `create_trace_writer(…, Ctfs)`, which is
#      what `nargo trace` itself writes with. That is DD-7's **Path B**, and it is the writer the
#      Noir half ships — `JOIN-SHAPE.md` §2 fact 6, stated rather than worked around. A Path A
#      private container is possible and is not shippable, for the reason that file gives.
#
# THE WORKTREE MUST BE CLEAN. Unlike the OQ-7 probe there is no tolerated edit here: everything
# this probe needs is committed on `codetracer`. A probe built from uncommitted edits is evidence
# about nothing.
#
# THE TARGET DIRECTORY IS THE NOIR CHECKOUT'S OWN, deliberately: building `noir_tracer` from cold
# is most of the Noir compiler from cold, and sharing `$NOIR_ROOT/target` makes it a mostly-cached
# build. It is a build cache and nothing is read back out of it as evidence.
#
# It does not skip. A missing checkout, a dirty tree, a failed build or a failed run is a non-zero
# exit.
# ---------------------------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=build_m38_private_trace_probe
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
NOIR_ROOT="${M38_NOIR_ROOT:-$WORKSPACE_ROOT/noir}"
M38_WORK="${M38_WORK:-$HOME/.cache/aztec-m38-private-trace}"
PROBE="$M38_WORK/probe"

[ -d "$NOIR_ROOT/tooling/tracer" ] || \
  die "no Noir tracer at $NOIR_ROOT/tooling/tracer (set M38_NOIR_ROOT)"

NOIR_BRANCH="$(git -C "$NOIR_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$NOIR_BRANCH" = "codetracer" ] || \
  die "the Noir checkout at $NOIR_ROOT is on '$NOIR_BRANCH' and this probe builds from 'codetracer',
     the branch that ships. See this script's header."

NOIR_DIRTY="$(git -C "$NOIR_ROOT" status --porcelain 2>/dev/null | head -5)"
[ -z "$NOIR_DIRTY" ] || \
  die "the Noir checkout $NOIR_ROOT is dirty; a probe built from uncommitted edits is evidence
     about nothing. Found: $NOIR_DIRTY"

NOIR_HEAD="$(git -C "$NOIR_ROOT" rev-parse HEAD)"

# THE WRITER CRATES ARE THE ONES THAT CHECKOUT'S OWN `Cargo.toml` NAMES, resolved from it, so the
# probe cannot link a second copy of `codetracer_trace_types`. Two copies on two paths are two
# distinct types and will not unify — RI-42's failure, and `test_single_trace_types_instantiation`
# is what reproduces it.
CTF_REL="$(grep -oE 'path = "\.\./[a-zA-Z0-9_.-]+/codetracer_trace_writer_nim"' "$NOIR_ROOT/Cargo.toml" | head -1 | sed 's|.*"\(.*\)"|\1|')"
[ -n "$CTF_REL" ] || die "could not read the Nim writer's path out of $NOIR_ROOT/Cargo.toml"
CTF_ABS="$(cd "$NOIR_ROOT" && cd "$(dirname "$CTF_REL")" && pwd)"
[ -d "$CTF_ABS/codetracer_trace_writer_nim" ] || \
  die "$NOIR_ROOT/Cargo.toml points at $CTF_ABS/codetracer_trace_writer_nim, which is not there"
CTF_REV="$(git -C "$CTF_ABS" rev-parse HEAD 2>/dev/null)"

mkdir -p "$PROBE/src" "$PROBE/bin" || die "could not create $PROBE"

# COPIED THEN TOUCHED. A restored or re-staged source that keeps an older mtime is how a mutated
# artefact outlives its source; cargo fingerprints on mtime.
cp "$VERIFY_DIR/m38_private_trace_probe.rs" "$PROBE/src/main.rs" || die "could not stage the probe source"
touch "$PROBE/src/main.rs"

cat > "$PROBE/Cargo.toml" <<EOF
[package]
name = "m38probe"
version = "0.0.0"
edition = "2021"
publish = false

[workspace]

[dependencies]
acvm = { path = "$NOIR_ROOT/acvm-repo/acvm", features = ["bn254"] }
bn254_blackbox_solver = { path = "$NOIR_ROOT/acvm-repo/bn254_blackbox_solver" }
fm = { path = "$NOIR_ROOT/compiler/fm" }
nargo = { path = "$NOIR_ROOT/tooling/nargo" }
noir_debugger = { path = "$NOIR_ROOT/tooling/debugger", default-features = false }
noir_tracer = { path = "$NOIR_ROOT/tooling/tracer", features = ["nim-writer"] }
noirc_abi = { path = "$NOIR_ROOT/tooling/noirc_abi" }
noirc_artifacts = { path = "$NOIR_ROOT/tooling/noirc_artifacts" }
codetracer_trace_types = { path = "$CTF_ABS/codetracer_trace_types" }
codetracer_trace_writer = { path = "$CTF_ABS/codetracer_trace_writer_nim", package = "codetracer_trace_writer_nim" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
base64 = "0.22"
flate2 = "1"
EOF

SPEC_SHA="$(sha256sum "$PROBE/src/main.rs" "$PROBE/Cargo.toml" 2>/dev/null | sha256sum | cut -d' ' -f1)"
STAMP_FILE="$PROBE/built-from"
STAMP_WANT="$SPEC_SHA $NOIR_HEAD $CTF_REV"
if [ "$FORCE" -eq 0 ] && [ -x "$PROBE/bin/m38probe" ] \
   && [ "$(cat "$STAMP_FILE" 2>/dev/null)" = "$STAMP_WANT" ]; then
  printf '%s: up to date (%s)\n' "$TEST_NAME" "$PROBE/bin/m38probe"
  exit 0
fi

# THE TOOLCHAIN IS THE NOIR CHECKOUT'S OWN, read out of its `rust-toolchain.toml`, and the reason is
# the build cache: cargo's fingerprint includes the compiler, so a different rustc would rebuild the
# whole Noir compiler rather than reuse `$NOIR_ROOT/target`.
NOIR_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$NOIR_ROOT/rust-toolchain.toml" | head -1)"
[ -n "$NOIR_TOOLCHAIN" ] || die "could not read a toolchain channel out of $NOIR_ROOT/rust-toolchain.toml"
M38_RUSTUP_HOME="${M38_RUSTUP_HOME:-$HOME/.rustup}"
[ -d "$M38_RUSTUP_HOME/toolchains/$NOIR_TOOLCHAIN-x86_64-unknown-linux-gnu" ] || \
  die "the Noir checkout pins rust $NOIR_TOOLCHAIN and $M38_RUSTUP_HOME does not carry it"

# THE NIM COMPILER COMES FROM THE SIBLING'S OWN DEV SHELL, AND THAT IS THE WHOLE DIAGNOSIS.
#
# `codetracer_trace_writer_nim/build.rs` compiles a Nim static library, so `nim` must be on PATH.
# It is not on this repository's — measured: `direnv exec . command -v nim` is empty here and
# resolves under `codetracer-trace-format`'s shell. This is the campaign brief's own rule one step
# out: *a path dependency's `build.rs` runs in the DEPENDENT's environment while needing the
# DEPENDENCY's toolchain*, so the shell you need is next door rather than above.
#
# `CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1` is that build script's own documented escape
# from needing `nimble` as well; without it the failure is `nimble` rather than `nim`, and the
# campaign brief records an agent concluding "it does not build here" from exactly that.
[ -d "$CTF_ABS/.direnv" ] || [ -f "$CTF_ABS/.envrc" ] || \
  die "$CTF_ABS has no .envrc, so there is no dev shell to take `nim` from"
rc=0
direnv exec "$CTF_ABS" nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c '
  set -uo pipefail
  command -v nim >/dev/null || { echo "no nim on PATH inside the writer'"'"'s dev shell" >&2; exit 1; }
  export RUSTUP_HOME="'"$M38_RUSTUP_HOME"'"
  export CARGO_TARGET_DIR="'"$NOIR_ROOT"'/target"
  export CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1
  cd "'"$PROBE"'" || exit 1
  rustup run "'"$NOIR_TOOLCHAIN"'" rustc --version || exit 1
  rustup run "'"$NOIR_TOOLCHAIN"'" cargo build --release || exit 1
  cp "$CARGO_TARGET_DIR/release/m38probe" "'"$PROBE"'/bin/m38probe" || exit 1
' || rc=$?

[ "$rc" -eq 0 ] || die "the M38 private-trace probe failed to build (exit $rc)"
[ -x "$PROBE/bin/m38probe" ] || die "the build reported success but produced no $PROBE/bin/m38probe"
printf '%s\n' "$STAMP_WANT" > "$STAMP_FILE"
printf '%s: %s\n' "$TEST_NAME" "$PROBE/bin/m38probe"
