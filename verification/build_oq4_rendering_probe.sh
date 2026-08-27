#!/usr/bin/env bash
# Build and run the OQ-4 rendering probe, producing one container per rendering arm.
#
#   verification/build_oq4_rendering_probe.sh      (or: just oq4-probe)
#
# It writes `$M25_WORK/oq4-<arm>.ct` for each of int, low64, bigint, string, raw.
#
# THE CRATE IS SCRATCH AND THE INPUTS ARE NOT. The probe source is tracked
# (`verification/oq4_rendering_probe.rs`); the `Cargo.toml` and `Cargo.lock` are generated here
# from `ct-writer`'s own, so the probe resolves EXACTLY the dependency versions the shipped module
# resolves. A probe on a different lock file would be evidence about a different writer.
#
# It does not skip. A missing checkout, a failed build or a failed run is a non-zero exit.

set -uo pipefail

TEST_NAME=build_oq4_rendering_probe
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m25_trace.sh"

CTF="$M24_CRATE/build-wasm-deps/ctf"
[ -d "$CTF/codetracer_trace_writer" ] || \
  die "no materialised trace-format checkout at $CTF — run verification/build_ct_writer_wasm.sh first"
STAMP="$(cat "$M24_CRATE/build-wasm-deps/materialised-at" 2>/dev/null | tr -d '[:space:]')"
WANT="$(m24_pin trace_format commit)"
[ "$STAMP" = "$WANT" ] || \
  die "the materialised trace-format checkout is at '$STAMP' and pins.json says '$WANT'"

PROBE="$M25_WORK/oq4-probe"
mkdir -p "$PROBE/src" || die "could not create $PROBE"
cp "$VERIFY_DIR/oq4_rendering_probe.rs" "$PROBE/src/main.rs" || die "could not stage the probe source"

cat > "$PROBE/Cargo.toml" <<EOF
[package]
name = "oq4probe"
version = "0.0.0"
edition = "2021"
publish = false

[dependencies]
codetracer_trace_types = { path = "$CTF/codetracer_trace_types" }
codetracer_trace_writer = { path = "$CTF/codetracer_trace_writer" }
EOF

# ct-writer's own lock, with only the ROOT package renamed. Everything below it is identical, which
# is the property that makes this probe evidence about the shipped writer.
sed 's/^name = "aztec-ct-writer"$/name = "oq4probe"/' "$M24_CRATE/Cargo.lock" > "$PROBE/Cargo.lock" \
  || die "could not derive a lock file from $M24_CRATE/Cargo.lock"

rc=0
nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c '
  set -uo pipefail
  export RUSTUP_HOME="'"$RUSTUP_HOME"'" CARGO_HOME="'"$CARGO_HOME"'"
  export PATH="$CARGO_HOME/bin:$PATH"
  rustup -q toolchain install stable --profile minimal >/dev/null 2>&1 || true
  cd "'"$PROBE"'" || exit 1
  for arm in int low64 bigint string raw; do
    rustup run stable cargo run --quiet -- "$arm" "'"$M25_WORK"'/oq4-$arm.ct" || exit 1
  done
' || rc=$?

[ "$rc" -eq 0 ] || die "the OQ-4 rendering probe failed (exit $rc)"
for arm in int low64 bigint string raw; do
  [ -s "$M25_WORK/oq4-$arm.ct" ] || die "the probe reported success but produced no $M25_WORK/oq4-$arm.ct"
done
printf '%s: five rendering arms in %s\n' "$TEST_NAME" "$M25_WORK"
