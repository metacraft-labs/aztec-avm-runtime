#!/usr/bin/env bash
# Build `m40_private_trace.wasm` — the module a PAGE steps a private Aztec transaction with.
#
#   verification/build_m40_private_trace_wasm.sh [--force]      (or: just m40-tracer-build)
#
# Not a check: it prints no assertions and is invoked BY checks.
#
# ---------------------------------------------------------------------------------------------
# WHICH NOIR CHECKOUT, AND WHY IT IS THE PUBLISHED ONE
#
# `../noir` on `codetracer` — the branch that ships. Not `../noir-wt4-webpage`, whose
# `wasm/webpage` branch carries the Path A container writer and is UNPUBLISHED: `JOIN-SHAPE.md`
# §2 fact 7 is that no published remote ref contains its HEAD, and OQ-7's whole "the shared writer
# is not shippable" verdict rests on that. This module needs neither that writer nor that branch:
# it stops at the event stream and the page's own `ct_writer.wasm` writes the container.
#
# M39 measured that the published tree builds `noir_tracer_wasm` for `wasm32-unknown-unknown` in
# about a minute; this crate is that one plus a tape executor and an Aztec-artifact front end.
#
# THE CHECKOUT MUST BE CLEAN AND ON `codetracer`, exactly as `build_m38_private_trace_probe.sh`
# requires: a module built from uncommitted edits is evidence about nothing, and the differential
# this module exists for compares it against a probe built from the same commit.
#
# ---------------------------------------------------------------------------------------------
# WHICH LOCK DECIDES THIS ARTEFACT — M31's rule, stated rather than left to be discovered.
#
# The staged crate is its OWN workspace root (`[workspace]` with no members), so cargo resolves it
# a `Cargo.lock` of its own at build time. Every Noir crate it names is a PATH dependency into the
# checkout above, so the toolchain, the tracer and the ACVM are pinned by that checkout's commit;
# what is NOT pinned is the four crates.io leaves (`serde`, `serde_json`, `base64`, `flate2`), which
# resolve to whatever is newest and semver-compatible on a cold build. That is the same posture
# `build_m38_private_trace_probe.sh` takes for the native probe, and it is recorded here because
# "the two builds differ in nothing" is the sentence M31's review found to be false.
#
# The content stamp below therefore covers: the source, the generated manifest, the Noir commit and
# the trace-format commit. It does not cover the four leaves; a differential between this module and
# the native probe is what would notice if one of them changed an answer.
# ---------------------------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=build_m40_private_trace_wasm
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"
NOIR_ROOT="${M40_NOIR_ROOT:-$WORKSPACE_ROOT/noir}"
M40_WORK="${M40_TRACER_WORK:-$HOME/.cache/aztec-m40-tracer}"
CRATE="$M40_WORK/crate"
OUT="$M40_WORK/m40_private_trace.wasm"

export RUSTUP_HOME="${RUSTUP_HOME:-$HOME/.cache/aztec-m24-rustup}"
export CARGO_HOME="${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}"

[ -d "$NOIR_ROOT/tooling/tracer_wasm" ] || \
  die "no Noir tracer_wasm crate at $NOIR_ROOT/tooling/tracer_wasm (set M40_NOIR_ROOT)"

NOIR_BRANCH="$(git -C "$NOIR_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null)"
[ "$NOIR_BRANCH" = "codetracer" ] || \
  die "the Noir checkout at $NOIR_ROOT is on '$NOIR_BRANCH' and this module builds from
     'codetracer', the branch that ships. See this script's header."

NOIR_DIRTY="$(git -C "$NOIR_ROOT" status --porcelain 2>/dev/null | head -5)"
[ -z "$NOIR_DIRTY" ] || \
  die "the Noir checkout $NOIR_ROOT is dirty; a module built from uncommitted edits is evidence
     about nothing. Found: $NOIR_DIRTY"

NOIR_HEAD="$(git -C "$NOIR_ROOT" rev-parse HEAD)"

# AND IT MUST BE PUBLISHED. *A pin that is not published is not a pin, it is a local file* — this
# campaign's own rule, and this module is the one thing in M40 that a fresh clone would have to
# rebuild from a commit it does not have.
NOIR_PUBLISHED="$(git -C "$NOIR_ROOT" for-each-ref --contains "$NOIR_HEAD" --format='%(refname)' refs/remotes 2>/dev/null | head -3)"
[ -n "$NOIR_PUBLISHED" ] || \
  die "$NOIR_ROOT's HEAD $NOIR_HEAD is contained in ZERO published remote refs, so this module
     could only be built on this machine. Push the branch before building against it."

# The trace-format checkout the Noir workspace itself names, so this module cannot link a second
# copy of `codetracer_trace_types` — RI-42's failure, two copies on two paths being two distinct
# types that will not unify.
CTF_REL="$(grep -oE 'path = "\.\./[a-zA-Z0-9_.-]+/codetracer_trace_types"' "$NOIR_ROOT/Cargo.toml" | head -1 | sed 's|.*"\(.*\)"|\1|')"
[ -n "$CTF_REL" ] || die "could not read codetracer_trace_types' path out of $NOIR_ROOT/Cargo.toml"
CTF_ABS="$(cd "$NOIR_ROOT" && cd "$(dirname "$CTF_REL")" && pwd)"
[ -d "$CTF_ABS/codetracer_trace_types" ] || \
  die "$NOIR_ROOT/Cargo.toml points at $CTF_ABS/codetracer_trace_types, which is not there"
CTF_REV="$(git -C "$CTF_ABS" rev-parse HEAD 2>/dev/null)"

mkdir -p "$CRATE/src" "$CRATE/.cargo" || die "could not create $CRATE"

# COPIED THEN TOUCHED, for `build_m38_private_trace_probe.sh`'s reason: a restored source that keeps
# an older mtime is how a mutated artefact outlives its source, and cargo fingerprints on mtime.
cp "$VERIFY_DIR/m40_private_trace_wasm.rs" "$CRATE/src/lib.rs" || die "could not stage the source"
touch "$CRATE/src/lib.rs"

# The invocation-directory cargo config `tooling/tracer_wasm` carries, for its reason: `getrandom`
# picks its backend from a `--cfg` and cargo only reads this file from the directory it is invoked
# in.
cat > "$CRATE/.cargo/config.toml" <<'CFG'
[build]
target = "wasm32-unknown-unknown"

[target.wasm32-unknown-unknown]
rustflags = ['--cfg', 'getrandom_backend="wasm_js"']
CFG

cat > "$CRATE/Cargo.toml" <<EOF
[package]
name = "m40_private_trace"
version = "0.0.0"
edition = "2021"
publish = false

[workspace]

[lib]
crate-type = ["cdylib", "rlib"]

[dependencies]
acvm = { path = "$NOIR_ROOT/acvm-repo/acvm", features = ["bn254"] }
bn254_blackbox_solver = { path = "$NOIR_ROOT/acvm-repo/bn254_blackbox_solver" }
fm = { path = "$NOIR_ROOT/compiler/fm" }
nargo = { path = "$NOIR_ROOT/tooling/nargo" }
noir_debugger = { path = "$NOIR_ROOT/tooling/debugger", default-features = false }
noir_tracer = { path = "$NOIR_ROOT/tooling/tracer" }
# WITHOUT the \`js\` feature: that one links wasm-bindgen, and an import-free module is what lets a
# page instantiate this with \`WebAssembly.instantiate(bytes, {})\` and lets the host COUNT the
# imports it reaches. \`verification/m30/page/wasm_host.mjs\` is that host, unchanged.
noir_tracer_wasm = { path = "$NOIR_ROOT/tooling/tracer_wasm", default-features = false }
noirc_abi = { path = "$NOIR_ROOT/tooling/noirc_abi" }
noirc_artifacts = { path = "$NOIR_ROOT/tooling/noirc_artifacts" }
codetracer_trace_types = { path = "$CTF_ABS/codetracer_trace_types" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
base64 = "0.22"
flate2 = "1"

[target.'cfg(target_arch = "wasm32")'.dependencies]
# The same four \`tooling/tracer_wasm/Cargo.toml\` names, and for its reason: \`uuid\` refuses to
# compile on wasm32 without an explicit source of randomness, and \`codetracer_trace_types\` mints a
# UUIDv7 recording id.
uuid = { version = "1", features = ["js"] }
getrandom = { version = "0.3", features = ["wasm_js"] }
getrandom_v2 = { package = "getrandom", version = "^0.2.0", features = ["js"] }
getrandom_v4 = { package = "getrandom", version = "0.4.0-rc.0", features = ["wasm_js"] }
EOF

SRC_SHA="$(sha256sum "$CRATE/src/lib.rs" "$CRATE/Cargo.toml" "$CRATE/.cargo/config.toml" 2>/dev/null | sha256sum | cut -d' ' -f1)"
STAMP_FILE="$M40_WORK/built-from"
STAMP_WANT="$SRC_SHA $NOIR_HEAD $CTF_REV"
if [ "$FORCE" -eq 0 ] && [ -s "$OUT" ] && [ "$(cat "$STAMP_FILE" 2>/dev/null)" = "$STAMP_WANT" ]; then
  printf '%s: up to date (%s bytes)\n' "$TEST_NAME" "$(wc -c <"$OUT")"
  printf '%s\n' "$OUT"
  exit 0
fi

command -v nix >/dev/null 2>&1 || die "nix is required (the rust wasm toolchain is in neither dev shell)"

# `capnp` is a HARD build-time dependency of `codetracer_trace_format_capnp`'s build script and its
# absence does not say so — the build dies four crates deep with `exit status: 101`, which reads
# like a broken branch rather than a missing tool. The same trap `build_ct_writer_wasm.sh` and
# `build_noir_tracer_wasm.sh` both record.
build_script='
set -euo pipefail
export PATH="$CARGO_HOME/bin:$PATH"
rustup -q toolchain install stable --profile minimal >/dev/null 2>&1 || true
rustup -q target add wasm32-unknown-unknown >/dev/null 2>&1 || true
cd "$CRATE"
cargo build --release
'

printf '%s: building %s for wasm32-unknown-unknown\n' "$TEST_NAME" "$CRATE" >&2
CRATE="$CRATE" CARGO_HOME="$CARGO_HOME" RUSTUP_HOME="$RUSTUP_HOME" \
  nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c "$build_script" >&2 \
  || die "the M40 private-trace wasm build failed"

BUILT="$CRATE/target/wasm32-unknown-unknown/release/m40_private_trace.wasm"
[ -s "$BUILT" ] || die "the build reported success but produced no $BUILT"
cp -f "$BUILT" "$OUT"
printf '%s\n' "$STAMP_WANT" > "$STAMP_FILE"
printf '%s: %s (%s bytes)\n' "$TEST_NAME" "$OUT" "$(wc -c <"$OUT")" >&2
printf '%s\n' "$OUT"
