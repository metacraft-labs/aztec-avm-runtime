#!/usr/bin/env bash
# verify_transpiler_native_build_unaffected — M31.
#
#   verification/verify_transpiler_native_build_unaffected.sh   (or: just verify-m31)
#
# ============================================================================================
# "NATIVE BUILDS ARE UNAFFECTED" IS A CLAIM AND NEEDS THE SAME EVIDENCE AS ANY OTHER.
# ============================================================================================
#
# `codetracer-specs/upstream-bugs/CLAUDE.md` says it in as many words: *demonstrate neutrality,
# do not assert it — the same test binaries, the same counts, before and after.* So this check
# builds the transpiler BOTH ways from the same two pinned revisions:
#
#   patched    `$WORK/tree`      — `verification/build_avm_transpiler_wasm.sh`
#   baseline   `$WORK/baseline`  — the same script with `--baseline`, which materialises the same
#                                  archives and DOES NOT apply the patch, asserting that the
#                                  pristine `use libc::{c_char, c_int, size_t};` is there before
#                                  it builds. A "baseline" that silently carried the change would
#                                  make everything below a comparison of one tree with itself.
#
# …and then runs both binaries over every fixture and compares the outputs BYTE FOR BYTE.
#
# ============================================================================================
# WHAT THE PATCH IS, AND WHY IT IS ARGUABLE ON UPSTREAM'S OWN TERMS.
# ============================================================================================
#
# `avm-transpiler` uses `libc` for exactly three names — `c_char`, `c_int` and `size_t` — on ONE
# line of `src/lib.rs`, plus a `use libc as _;` in `src/main.rs` to keep
# `unused_crate_dependencies` quiet. `core::ffi::c_char` and `core::ffi::c_int` have been stable
# since Rust 1.64 and follow the same platform rules; `libc::size_t` IS `usize`. The crate's own
# `rust-toolchain.toml` pins 1.89, so the aliases are available unconditionally.
#
# The motive is disclosed rather than hidden: `libc` defines nothing for a target it does not
# know, so that one line is enough to make the crate unbuildable on `wasm32-unknown-unknown`:
#
#     error[E0432]: unresolved imports `libc::c_char`, `libc::c_int`, `libc::size_t`
#
# That is a reason for US to write the patch. The reason for upstream to take it is that a crate
# should not depend on `libc` for three aliases the standard library provides.

TEST_NAME="verify_transpiler_native_build_unaffected"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m31_transpiler.sh"
m31_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m31_require_build

# ---------------------------------------------------------------------------
echo "== 1. the patch is small, and its shape is read from the patch file"
# ---------------------------------------------------------------------------
PATCH_FILE="$M31_PATCH_DIR/0001-avm-transpiler-take-the-three-C-ABI-type-aliases-fro.patch"
assert_dir "the prepared contribution has a directory" "$M31_PATCH_DIR"
assert_file "…with a patch in it" "$PATCH_FILE"
assert_file "…a PR.md" "$M31_PATCH_DIR/PR.md"
assert_file "…and a verify.sh" "$M31_PATCH_DIR/verify.sh"
TOUCHED="$(grep '^diff --git ' "$PATCH_FILE" | sed 's|^diff --git a/||; s| b/.*$||' | LC_ALL=C sort)"
TOUCHED_N="$(printf '%s\n' "$TOUCHED" | grep -c . || true)"
assert_eq "the patch touches exactly four files" "4" "$TOUCHED_N"
for f in avm-transpiler/Cargo.toml avm-transpiler/Cargo.lock avm-transpiler/src/lib.rs avm-transpiler/src/main.rs; do
  assert_true "…including $f" str_has_line "$TOUCHED" "$f"
done
# NOTHING OUTSIDE THE CRATE. `avm-transpiler/` is the whole blast radius, which is the claim
# `git show --stat` would be offered for upstream.
assert_eq "…and nothing outside avm-transpiler/" "0" \
  "$(printf '%s\n' "$TOUCHED" | grep -vc '^avm-transpiler/' || true)"
ADDED="$(grep -c '^+[^+]' "$PATCH_FILE" || true)"
REMOVED="$(grep -c '^-[^-]' "$PATCH_FILE" || true)"
assert_true "the diff is small: $ADDED added, $REMOVED removed" test "$((ADDED + REMOVED))" -lt 20
assert_ge "…and it is not empty" 1 "$ADDED"
# The generated C header is NOT in the patch, which is the ABI claim in its cheapest form.
assert_false "avm_transpiler.h is untouched, so the C ABI is unchanged" \
  str_has_line "$TOUCHED" avm-transpiler/avm_transpiler.h

# ---------------------------------------------------------------------------
echo "== 2. the two trees really are different trees"
# ---------------------------------------------------------------------------
m31_bounded "$M31_BUILD_TIMEOUT" "the UNPATCHED baseline build" \
  "$VERIFY_DIR/build_avm_transpiler_wasm.sh" --baseline \
  || die "build_avm_transpiler_wasm.sh --baseline failed; see $M31_WORK/bounded.log"
BASELINE_NATIVE=""
BASELINE_TREE=""
while IFS= read -r line; do
  case "${line%%=*}" in
    BASELINE_NATIVE) BASELINE_NATIVE="${line#*=}" ;;
    BASELINE_TREE) BASELINE_TREE="${line#*=}" ;;
  esac
done <"$M31_WORK/bounded.log"
[ -n "$BASELINE_NATIVE" ] && [ -x "$BASELINE_NATIVE" ] || \
  die "the baseline build printed no usable BASELINE_NATIVE= line (see $M31_WORK/bounded.log)"
assert_file "the baseline binary exists" "$BASELINE_NATIVE"
assert_file "the patched binary exists" "$M31_NATIVE"

# THE DIFFERENCE, PER FILE AND EXACT. Not "the trees differ" — WHICH lines differ, so a baseline
# that had drifted for some other reason would be visible.
BASE_SRC="$BASELINE_TREE/avm-transpiler/src/lib.rs"
PATCH_SRC="$M31_TREE/avm-transpiler/src/lib.rs"
assert_ge "the baseline carries the libc import the patch removes" 1 \
  "$(grep -c 'use libc::{c_char, c_int, size_t};' "$BASE_SRC" || true)"
assert_eq "…and the patched tree does not" "0" \
  "$(grep -c 'use libc::' "$PATCH_SRC" || true)"
assert_ge "…and carries core::ffi instead" 1 \
  "$(grep -c 'use core::ffi::{c_char, c_int};' "$PATCH_SRC" || true)"
assert_ge "the baseline's Cargo.toml declares libc" 1 \
  "$(grep -c '^libc = ' "$BASELINE_TREE/avm-transpiler/Cargo.toml" || true)"
assert_eq "…and the patched one does not" "0" \
  "$(grep -c 'libc' "$M31_TREE/avm-transpiler/Cargo.toml" || true)"
CHANGED_LINES="$(diff "$BASE_SRC" "$PATCH_SRC" | grep -c '^[<>]' || true)"
assert_eq "lib.rs differs in exactly six lines, three each way" "6" "$CHANGED_LINES"
# THE HEADER IS BYTE-IDENTICAL between the two trees. `size_t` in C and `usize` in Rust are the
# same width by definition, so the ABI does not move and the header does not have to.
assert_eq "avm_transpiler.h is byte-identical in both trees" \
  "$(sha256sum "$BASELINE_TREE/avm-transpiler/avm_transpiler.h" | cut -d' ' -f1)" \
  "$(sha256sum "$M31_TREE/avm-transpiler/avm_transpiler.h" | cut -d' ' -f1)"
# …and that comparison can fail, shown on two files that ARE different.
assert_false "…and that comparison is capable of reporting a difference" \
  test "$(sha256sum "$BASE_SRC" | cut -d' ' -f1)" = "$(sha256sum "$PATCH_SRC" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
echo "== 3. THE SAME OUTPUT, BEFORE AND AFTER, FOR EVERY FIXTURE"
# ---------------------------------------------------------------------------
NEUTRAL_WORK="$M31_WORK/neutrality"
rm -rf "$NEUTRAL_WORK"; mkdir -p "$NEUTRAL_WORK" || die "could not create $NEUTRAL_WORK"
FIXTURE_COUNT=0
for input in "$M31_ARTIFACTS"/*.json; do
  name="$(basename "$input" .json)"
  FIXTURE_COUNT=$((FIXTURE_COUNT + 1))
  "$BASELINE_NATIVE" "$input" "$NEUTRAL_WORK/$name.base.json" >/dev/null 2>&1
  brc=$?
  "$M31_NATIVE" "$input" "$NEUTRAL_WORK/$name.patched.json" >/dev/null 2>&1
  prc=$?
  assert_eq "$name: the baseline binary exits 0" "0" "$brc"
  assert_eq "$name: the patched binary exits 0" "0" "$prc"
  assert_file "$name: the baseline wrote an output" "$NEUTRAL_WORK/$name.base.json"
  assert_file "$name: the patched binary wrote an output" "$NEUTRAL_WORK/$name.patched.json"
  BSHA="$(sha256sum "$NEUTRAL_WORK/$name.base.json" | cut -d' ' -f1)"
  PSHA="$(sha256sum "$NEUTRAL_WORK/$name.patched.json" | cut -d' ' -f1)"
  # NON-EMPTY BEFORE EQUAL: two zero-byte files have the same digest.
  assert_ge "$name: the output is not empty" 500 "$(wc -c <"$NEUTRAL_WORK/$name.patched.json")"
  assert_eq "$name: patched output == baseline output, byte for byte" "$BSHA" "$PSHA"
done
assert_ge "the neutrality comparison ran over the whole corpus" 7 "$FIXTURE_COUNT"
# AND THE COMPARISON IS SHOWN TO DISCRIMINATE, on this run, over these files: two DIFFERENT
# fixtures' outputs must not compare equal. Without this the section above is seven comparisons
# by an instrument nothing has calibrated.
assert_false "…and that comparison can report a difference between two real outputs" \
  test "$(sha256sum "$NEUTRAL_WORK/counter.patched.json" | cut -d' ' -f1)" \
     = "$(sha256sum "$NEUTRAL_WORK/branches.patched.json" | cut -d' ' -f1)"

# ---------------------------------------------------------------------------
echo "== 4. the dependency really went away"
# ---------------------------------------------------------------------------
# `libc` leaves the CRATE's dependency list; it stays in the lock, because four other packages in
# the closure still want it. Both halves are asserted, because "the dependency is gone" would be
# the wrong claim and an easy one to make.
BASE_LOCK_DEPS="$(python3 - "$BASELINE_TREE/avm-transpiler/Cargo.lock" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'name = "avm-transpiler"\nversion[^\n]*\ndependencies = \[\n(.*?)\]\n', s, re.S)
print("".join(m.group(1).split()) if m else "MISSING")
PY
)"
PATCH_LOCK_DEPS="$(python3 - "$M31_TREE/avm-transpiler/Cargo.lock" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'name = "avm-transpiler"\nversion[^\n]*\ndependencies = \[\n(.*?)\]\n', s, re.S)
print("".join(m.group(1).split()) if m else "MISSING")
PY
)"
assert_false "the baseline's lock entry was read" test "$BASE_LOCK_DEPS" = "MISSING"
assert_false "…and the patched one" test "$PATCH_LOCK_DEPS" = "MISSING"
assert_contains "the baseline lists libc as a direct dependency" '"libc",' "$BASE_LOCK_DEPS"
assert_not_contains "…and the patched tree does not" '"libc",' "$PATCH_LOCK_DEPS"
# EVERYTHING ELSE IS THE SAME. One removal, nothing else moved.
REMOVED_ONLY="$(python3 - "$BASE_LOCK_DEPS" "$PATCH_LOCK_DEPS" <<'PY'
import sys
b = set(sys.argv[1].split(',')); p = set(sys.argv[2].split(','))
print(f"{sorted(b - p)} {sorted(p - b)}")
PY
)"
assert_eq "…and libc is the only difference, in one direction" "['\"libc\"'] []" "$REMOVED_ONLY"
# `libc` is still IN the lock, reached by other packages. Saying "the dependency is gone" would
# be false and this is where it would be caught.
assert_ge "libc is still a package in the lock, wanted by others in the closure" 1 \
  "$(grep -c '^name = "libc"' "$M31_TREE/avm-transpiler/Cargo.lock" || true)"

# ---------------------------------------------------------------------------
echo "== 5. the wasm target is added WITHOUT a crate-type change upstream"
# ---------------------------------------------------------------------------
# The `cdylib` lives in THIS repository's shim, not in upstream's manifest. Adding it upstream
# would make every native `cargo build` link a shared object nobody asked for, which is a cost a
# maintainer would be right to refuse — and it is not needed: a cdylib only needs an rlib, and
# `avm-transpiler` already is one.
assert_ge "upstream's crate-type is unchanged: staticlib and rlib" 1 \
  "$(grep -c 'crate-type = \["staticlib", "rlib"\]' "$M31_TREE/avm-transpiler/Cargo.toml" || true)"
assert_eq "…with no cdylib added to it" "0" \
  "$(grep -c 'cdylib' "$M31_TREE/avm-transpiler/Cargo.toml" || true)"
assert_ge "…and the cdylib is declared in this repository's shim instead" 1 \
  "$(grep -c 'crate-type = \["cdylib", "rlib"\]' "$M31_SHIM/Cargo.toml" || true)"
# The getrandom backend is a CONSUMER's decision and lives with the consumer, for the same reason.
assert_ge "the getrandom backend is chosen in the shim's own .cargo/config.toml" 1 \
  "$(grep -c 'getrandom_backend="unsupported"' "$M31_SHIM/.cargo/config.toml" || true)"
# EXCLUDING `target/`, and the exclusion is a finding rather than a tidy-up: the first version of
# this counted 12, all of them cargo's own fingerprint and dep-info files recording the RUSTFLAGS
# the shim's config supplied. A scanner over a build tree is scanning the build's own bookkeeping.
UPSTREAM_SRC="$(find "$M31_TREE/avm-transpiler" -type f -not -path '*/target/*' | LC_ALL=C sort)"
assert_ge "there are upstream source files to scan" 10 "$(printf '%s\n' "$UPSTREAM_SRC" | grep -c . || true)"
assert_eq "…and not in upstream's tree" "0" \
  "$(printf '%s\n' "$UPSTREAM_SRC" | xargs grep -lc 'getrandom_backend' 2>/dev/null | grep -c . || true)"
# The paired positive: the same scanner FINDS it where it is.
assert_ge "…and that scanner finds it in the shim, where it lives" 1 \
  "$(grep -lc 'getrandom_backend' "$M31_SHIM/.cargo/config.toml" | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 6. THE TWO BUILDS' RESOLVED DEPENDENCIES, WHICH ARE NOT THE SAME SET"
# ---------------------------------------------------------------------------
# ADDED BY M31's REVIEW. `avm-transpiler-wasm/Cargo.toml` said "the two builds differ in target and
# in nothing else". They do not. The shim is its OWN workspace root with its OWN `Cargo.lock`,
# resolved fresh at build time, while the native binary builds against upstream's PINNED
# `avm-transpiler/Cargo.lock`. Measured on this run rather than described:
#
#   getrandom  0.4.1 (native, pinned)   vs  0.4.3 (wasm, fresh)
#   serde_json 1.0.149                  vs  1.0.151      <- the JSON writer the digests run over
#   flate2     1.1.9                    vs  1.1.10       <- the DEFLATE that packs debug_symbols
#
# This CUTS BOTH WAYS and both are asserted. It makes byte-identity a stronger result — two
# different JSON writers and two different DEFLATE implementations producing the same bytes — and
# it makes the wasm module UNPINNED, because nothing here passes `--locked` and no lock for the
# shim is committed. The second half is recorded as an Outstanding task rather than closed here;
# what is closed is that the difference is a MEASUREMENT and no longer a sentence claiming the
# opposite.
NATIVE_LOCK="$M31_TREE/avm-transpiler/Cargo.lock"
WASM_LOCK="$M31_TREE/avm-transpiler-wasm/Cargo.lock"
assert_file "the native build has upstream's pinned lock" "$NATIVE_LOCK"
assert_file "the wasm build has a lock of its own, resolved at build time" "$WASM_LOCK"
lockver() { # <lock> <crate>
  python3 - "$1" "$2" <<'PY'
import re, sys
s = open(sys.argv[1]).read()
m = re.search(r'\nname = "%s"\nversion = "([^"]+)"' % re.escape(sys.argv[2]), s)
print(m.group(1) if m else "MISSING")
PY
}
DIFFERING=0
for crate in getrandom serde_json flate2; do
  NV="$(lockver "$NATIVE_LOCK" "$crate")"
  WV="$(lockver "$WASM_LOCK" "$crate")"
  assert_false "$crate: the native lock names a version" test "$NV" = "MISSING"
  assert_false "$crate: the wasm lock names a version" test "$WV" = "MISSING"
  [ "$NV" != "$WV" ] && DIFFERING=$((DIFFERING + 1))
done
# NOT a pinned pair of numbers — the versions move. What is asserted is that the two resolutions
# are NOT the same set, which is the fact the old comment denied.
assert_ge "the two builds resolve different versions of at least one shared crate" 1 "$DIFFERING"
# …and the reader is told WHICH, so this is a measurement and not a boolean.
note "resolved versions — getrandom $(lockver "$NATIVE_LOCK" getrandom)/$(lockver "$WASM_LOCK" getrandom), serde_json $(lockver "$NATIVE_LOCK" serde_json)/$(lockver "$WASM_LOCK" serde_json), flate2 $(lockver "$NATIVE_LOCK" flate2)/$(lockver "$WASM_LOCK" flate2)"
# THE getrandom BACKEND IS CHECKED AGAINST THE VERSION THE BUILD ACTUALLY LINKS, not against the
# one the comment was written about. `.cargo/config.toml`, RI-79 and the milestone all argue from
# getrandom 0.4.1's `src/backends/unsupported.rs`; the module links a different 0.4.x. The
# conclusion holds only if THAT version still has the backend, so it is read out of the registry
# source cargo used.
GR_VER="$(lockver "$WASM_LOCK" getrandom)"
assert_ge "the wasm build's getrandom version was read" 5 "${#GR_VER}"
GR_SRC="$(find "${CARGO_HOME:-$HOME/.cache/aztec-m24-cargo}/registry/src" -maxdepth 2 \
          -type d -name "getrandom-$GR_VER" 2>/dev/null | head -1)"
assert_dir "…and its source is in the cargo registry cache" "${GR_SRC:-/nonexistent}"
assert_file "…and that version still ships the unsupported backend" \
  "${GR_SRC:-/nonexistent}/src/backends/unsupported.rs"
assert_ge "…whose body is the refusal and not a value" 1 \
  "$(grep -c 'Error::UNSUPPORTED' "${GR_SRC:-/nonexistent}/src/backends/unsupported.rs" 2>/dev/null || true)"
# The paired zero, on the EFFECTIVE line rather than on the file: `wasm_js` is named in the
# config's prose (it is noir's answer, and RI-79 records why this build declines it), so a
# whole-file grep would be the "a citation counted as a call" defect. The `rustflags` line is what
# cargo reads.
RUSTFLAGS_LINE="$(grep '^rustflags' "$M31_SHIM/.cargo/config.toml" || true)"
assert_ge "the shim's config has a rustflags line at all" 10 "${#RUSTFLAGS_LINE}"
assert_true "…and it selects the unsupported backend" \
  str_has_sub "$RUSTFLAGS_LINE" 'getrandom_backend="unsupported"'
assert_false "…and not wasm_js, which the prose beside it only cites" \
  str_has_sub "$RUSTFLAGS_LINE" 'wasm_js'
# …and the citation IS in the file, so the two greps are not both zero for one reason.
assert_ge "…while the file does discuss wasm_js, so the line grep is the discriminating one" 1 \
  "$(grep -c 'wasm_js' "$M31_SHIM/.cargo/config.toml" || true)"

m31_finish
