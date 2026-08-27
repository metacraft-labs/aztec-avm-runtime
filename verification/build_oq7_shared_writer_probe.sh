#!/usr/bin/env bash
# Build the OQ-7 shared-writer probe: ONE `CtfsTraceWriter`, two producers, one container.
#
#   verification/build_oq7_shared_writer_probe.sh          (or: just oq7-probe)
#
# It stages a scratch crate under `$M26_WORK/oq7-probe`, builds it, and leaves the binary at
# `$M26_WORK/oq7-probe/bin/oq7probe`. `lib_m26_join.sh`'s `m26_require_arms` runs it.
#
# ---------------------------------------------------------------------------
# THE CRATE IS SCRATCH AND THE INPUTS ARE NOT, which is `build_oq4_rendering_probe.sh`'s discipline
# and it matters more here. The probe source is tracked (`verification/oq7_shared_writer_probe.rs`);
# the writer it links is the SAME `codetracer_trace_writer` the shipped module links; and the Noir
# side is the real `noir_tracer` rather than a stand-in.
#
# WHERE THE TWO SIDES COME FROM, AND WHY THEY ARE DIFFERENT KINDS OF INPUT:
#
#   the writer  — `$M24_CRATE/build-wasm-deps/ctf`, the checkout `build_ct_writer_wasm.sh`
#                 materialises FROM THE OBJECT STORE at `pins.json`'s `trace_format` revision. That
#                 is a pin.
#   the tracer  — `$OQ7_NOIR_ROOT` (default `<workspace>/noir-wt4-webpage`), a WORKTREE. It is NOT
#                 a pin and this script does not pretend it is: the branch it sits on
#                 (`wasm/webpage`) is unpublished, so it cannot be pinned, and that fact is itself
#                 part of OQ-7's verdict rather than an inconvenience. What this script DOES assert
#                 is that the worktree carries no edit except the ONE M26 itself makes (see below),
#                 that that edit matches the shipped one byte for byte, and that its writer paths
#                 resolve to the same revision as the pin — so the probe is evidence about the
#                 writer this campaign ships, even though the tracer half is evidence about a
#                 branch it cannot ship.
#
# THE TARGET DIRECTORY IS THE NOIR WORKTREE'S, DELIBERATELY. Building `noir_tracer_wasm` from cold
# is the Noir compiler from cold; sharing `$OQ7_NOIR_ROOT/target` turns that into a mostly-cached
# build. It is a build cache and nothing is read back out of it as evidence.
#
# It does not skip. A missing checkout, an unexpected edit, a failed build or a failed run is a
# non-zero exit.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=build_oq7_shared_writer_probe
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m26_join.sh"

FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

CTF="$M24_CRATE/build-wasm-deps/ctf"
[ -d "$CTF/codetracer_trace_writer" ] || \
  die "no materialised trace-format checkout at $CTF — run verification/build_ct_writer_wasm.sh first"
STAMP="$(cat "$M24_CRATE/build-wasm-deps/materialised-at" 2>/dev/null | tr -d '[:space:]')"
WANT="$(m24_pin trace_format commit)"
[ "$STAMP" = "$WANT" ] || \
  die "the materialised trace-format checkout is at '$STAMP' and pins.json says '$WANT'"

[ -d "$OQ7_NOIR_ROOT/tooling/tracer_wasm" ] || \
  die "no Noir tracer worktree at $OQ7_NOIR_ROOT (set OQ7_NOIR_ROOT)"
# THE WORKTREE MAY CARRY EXACTLY ONE EDIT, AND IT IS NAMED.
#
# "A probe built from uncommitted edits is evidence about nothing" is the rule, and this is the one
# place it is relaxed — deliberately, and narrowed to a single path rather than waived. M26's
# cross-half deliverable IS an edit to `tooling/tracer/src/tracer_glue.rs`: the Noir half must
# render a `Field` the way the public half does, or a joined recording contains one field element
# spelled two ways. An implementation agent makes no commits, so requiring a clean worktree here
# would mean demonstrating the join with a tracer that does NOT carry the fix the same milestone
# ships — which is worse than a named exception.
#
# What is asserted instead: nothing else is modified, and the file's `Field` arm is BYTE-IDENTICAL
# to the one in the checkout `test_fr_rendering_matches_noir_tracer` reads. So the demonstration and
# the shipped fix cannot drift apart.
ALLOWED_EDIT="tooling/tracer/src/tracer_glue.rs"
NOIR_DIRTY="$(git -C "$OQ7_NOIR_ROOT" status --porcelain 2>/dev/null | grep -v " $ALLOWED_EDIT\$" | head -5)"
[ -z "$NOIR_DIRTY" ] || \
  die "the Noir worktree $OQ7_NOIR_ROOT carries edits other than $ALLOWED_EDIT; a probe built from those is evidence about nothing: $NOIR_DIRTY"
SHIPPED_GLUE="$M26_NOIR_SOURCE/$ALLOWED_EDIT"
[ -f "$SHIPPED_GLUE" ] || die "no $SHIPPED_GLUE to compare the probe's tracer against"
# WHAT IS COMPARED IS THE RENDERING, NOT THE WHOLE ARM, AND THE REASON IS MEASURED. The two
# checkouts are on different branches and their `register_value` takes a different writer trait —
# `TraceWriter` on `blocktracer`, `TraceSink` on `wasm/webpage` — so the surrounding lines of the
# `Field` arm differ for a reason that has nothing to do with OQ-4. Diffing the whole arm therefore
# fails on a difference that is not the subject; diffing the two lines that DECIDE the rendering
# fails on exactly the difference that is.
for _needle in 'ValueRecord::String { text: field_to_hex(field_value), type_id }' \
               'format!("0x{}", field_value.to_hex())'; do
  for _tree in "$SHIPPED_GLUE" "$OQ7_NOIR_ROOT/$ALLOWED_EDIT"; do
    grep -qF -- "$_needle" "$_tree" || \
      die "$_tree does not carry the OQ-4 rendering line [$_needle]; the demonstration and the shipped fix have drifted"
  done
done
for _tree in "$SHIPPED_GLUE" "$OQ7_NOIR_ROOT/$ALLOWED_EDIT"; do
  # The control for the two greps above: the rendering they replace must be GONE from the Field
  # arm. Without it, a file carrying both lines would satisfy them.
  #
  # The arm is extracted into a VARIABLE first and the predicate reads the variable, rather than
  # `sed … | grep -q`. `verify_no_pipeline_predicates` pins the surviving count of that spelling at
  # five BY NAME, and M21's review wrote two new ones while fixing something else and was caught by
  # that pin; adding a sixth would have been the same move.
  _arm="$(sed -n '/        PrintableType::Field => {/,/        PrintableType::UnsignedInteger/p' "$_tree")"
  case "$_arm" in
    *'ValueRecord::Int { i: field_value.to_i128() as i64, type_id }'*)
      die "$_tree still renders Field through to_i128(); the OQ-4 verdict is not applied there" ;;
  esac
done

# The two halves must resolve the SAME writer checkout, or the probe would be linking two copies of
# `codetracer_trace_types` and would not compile — which is RI-42's failure and is what
# `test_single_trace_types_instantiation` reproduces. Asserted here rather than discovered in a
# compiler error four crates deep.
NOIR_CTF="$(cd "$OQ7_NOIR_ROOT" && grep -oE "path = \"\.\./[a-zA-Z0-9_-]+/codetracer_trace_types\"" Cargo.toml | head -1 | sed 's|.*"\(.*\)"|\1|')"
[ -n "$NOIR_CTF" ] || die "could not read the Noir worktree's codetracer_trace_types path out of its Cargo.toml"
NOIR_CTF_ABS="$(cd "$OQ7_NOIR_ROOT" && cd "$(dirname "$NOIR_CTF")" && pwd)"
NOIR_CTF_REV="$(git -C "$NOIR_CTF_ABS" rev-parse HEAD 2>/dev/null)"
[ "$NOIR_CTF_REV" = "$WANT" ] || \
  die "the Noir worktree resolves its writer crates at $NOIR_CTF_ABS ($NOIR_CTF_REV) and pins.json's trace_format is $WANT"
NOIR_CTF_DIRTY="$(git -C "$NOIR_CTF_ABS" status --porcelain 2>/dev/null | head -5)"
[ -z "$NOIR_CTF_DIRTY" ] || die "the writer worktree $NOIR_CTF_ABS is dirty: $NOIR_CTF_DIRTY"

PROBE="$M26_WORK/oq7-probe"
mkdir -p "$PROBE/src" "$PROBE/bin" || die "could not create $PROBE"

# `tar`-free staging, and the source is COPIED then TOUCHED. A restored or re-staged source that
# keeps an older mtime is how a mutated artefact outlives its source; cargo fingerprints on mtime.
cp "$VERIFY_DIR/oq7_shared_writer_probe.rs" "$PROBE/src/main.rs" || die "could not stage the probe source"
touch "$PROBE/src/main.rs"

cat > "$PROBE/Cargo.toml" <<EOF
[package]
name = "oq7probe"
version = "0.0.0"
edition = "2021"
publish = false

[workspace]

[dependencies]
codetracer_trace_types = { path = "$NOIR_CTF_ABS/codetracer_trace_types" }
codetracer_trace_writer = { path = "$NOIR_CTF_ABS/codetracer_trace_writer" }
noir_tracer = { path = "$OQ7_NOIR_ROOT/tooling/tracer", default-features = false }
noir_tracer_wasm = { path = "$OQ7_NOIR_ROOT/tooling/tracer_wasm", default-features = false }
noirc_abi = { path = "$OQ7_NOIR_ROOT/tooling/noirc_abi" }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
EOF

# THE STAMP HASHES THE TRACER SOURCE, NOT ONLY THE WORKTREE'S HEAD. The one permitted edit is
# UNCOMMITTED, so `git rev-parse HEAD` does not move when it changes and a HEAD-only stamp would
# leave a probe built before the Field-rendering fix looking current — which is "a mutated artefact
# outliving its restored source" with the signs reversed.
GLUE_SHA="$(sha256sum "$OQ7_NOIR_ROOT/$ALLOWED_EDIT" | cut -d" " -f1)"
SPEC_SHA="$(sha256sum "$PROBE/src/main.rs" "$PROBE/Cargo.toml" 2>/dev/null | sha256sum | cut -d' ' -f1)"
STAMP_FILE="$PROBE/built-from"
STAMP_WANT="$SPEC_SHA $WANT $(git -C "$OQ7_NOIR_ROOT" rev-parse HEAD) $GLUE_SHA"
if [ "$FORCE" -eq 0 ] && [ -x "$PROBE/bin/oq7probe" ] \
   && [ "$(cat "$STAMP_FILE" 2>/dev/null)" = "$STAMP_WANT" ]; then
  printf '%s: up to date (%s)\n' "$TEST_NAME" "$PROBE/bin/oq7probe"
  exit 0
fi

# THE TOOLCHAIN IS THE NOIR WORKTREE'S OWN, READ OUT OF ITS `rust-toolchain.toml`, AND THE REASON
# IS THE BUILD CACHE. Cargo's fingerprint includes the compiler, so building this probe with a
# different rustc than the one that filled `$OQ7_NOIR_ROOT/target` would rebuild the whole Noir
# compiler rather than reuse it. M24's own `$RUSTUP_HOME` does not carry that toolchain and
# installing a second copy of it would change the fingerprint anyway, so this one build uses the
# rustup home the worktree's own builds use. The version is read and asserted rather than assumed —
# a probe built by a compiler nobody named is a measurement nobody can reproduce.
NOIR_TOOLCHAIN="$(sed -n 's/^channel *= *"\(.*\)"/\1/p' "$OQ7_NOIR_ROOT/rust-toolchain.toml" | head -1)"
[ -n "$NOIR_TOOLCHAIN" ] || die "could not read a toolchain channel out of $OQ7_NOIR_ROOT/rust-toolchain.toml"
OQ7_RUSTUP_HOME="${OQ7_RUSTUP_HOME:-$HOME/.rustup}"
[ -d "$OQ7_RUSTUP_HOME/toolchains/$NOIR_TOOLCHAIN-x86_64-unknown-linux-gnu" ] || \
  die "the Noir worktree pins rust $NOIR_TOOLCHAIN and $OQ7_RUSTUP_HOME does not carry it"

rc=0
nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c '
  set -uo pipefail
  export RUSTUP_HOME="'"$OQ7_RUSTUP_HOME"'"
  export CARGO_TARGET_DIR="'"$OQ7_NOIR_ROOT"'/target"
  cd "'"$PROBE"'" || exit 1
  rustup run "'"$NOIR_TOOLCHAIN"'" rustc --version || exit 1
  rustup run "'"$NOIR_TOOLCHAIN"'" cargo build --release || exit 1
  cp "$CARGO_TARGET_DIR/release/oq7probe" "'"$PROBE"'/bin/oq7probe" || exit 1
' || rc=$?

[ "$rc" -eq 0 ] || die "the OQ-7 shared-writer probe failed to build (exit $rc)"
[ -x "$PROBE/bin/oq7probe" ] || die "the build reported success but produced no $PROBE/bin/oq7probe"
printf '%s\n' "$STAMP_WANT" > "$STAMP_FILE"
printf '%s: %s\n' "$TEST_NAME" "$PROBE/bin/oq7probe"
