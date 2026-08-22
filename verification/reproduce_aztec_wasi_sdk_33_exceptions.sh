#!/usr/bin/env bash
# reproduce_aztec_wasi_sdk_33_exceptions
#
# M4 verification. The prepared contribution has to stand on its own, in a
# maintainer's hands, with no part of this repository present. This check drives
# the script that ships with it and holds it to three things:
#
#   IT IS THE RIGHT SHAPE.  upstream-bugs/CLAUDE.md's "non-defect contributions"
#     workflow requires PR.md + verify.sh, and reserves ISSUE.md + reproduce.sh
#     for defects. This is a toolchain bump against a project with no live defect,
#     so PR.md/verify.sh is what exists — and the absence of the other spelling is
#     asserted, not just the presence of this one. There is also exactly ONE
#     directory for this patch.
#
#     (This check's NAME is the one the milestone gives, so it stays greppable;
#     what it drives is `verify.sh`. Same reconciliation M3 recorded.)
#
#   IT DISCRIMINATES.  A verification that passes is only worth what it would have
#     caught. Four mutations are applied and each must be rejected with its own
#     SPECIFIC message, not merely with a non-zero exit:
#
#       M1  a patch file that also touches a .cpp        -> names the file
#       M2  a "27" that is really 33, with its VERSION rewritten so the cheap
#           version assertion cannot be what catches it -> the sysroot contents
#           and the shape of the link failure are what reject it
#       M3  an artefact comparison against a different module -> "import lists
#           DIFFER"
#       M4  a required input simply absent               -> exit 2, "cannot run",
#           and NOT 0
#
#     M2 is the one that matters: the M3 review showed a discriminator made
#     vacuous while verify.sh still exited non-zero, so an exit-status-only check
#     would have gone green.
#
#   IT NEVER SKIPS.  Asserted structurally as well: the script must contain no
#     path that reports success for something it did not run.
#
# Run: just verify-wasi33-reproduce

TEST_NAME="reproduce_aztec_wasi_sdk_33_exceptions"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_wasi33.sh"

require_nix

# ---------------------------------------------------------------------------
# Shape.
# ---------------------------------------------------------------------------
assert_dir "the prepared contribution is at aztec-wasi-sdk-33/" "$M4_PATCH_DIR"
assert_false "and there is no second directory for the same patch" \
  test -d "${M4_PATCH_DIR}-exceptions"
assert_file "PR.md is the write-up (non-defect workflow)" "$M4_PATCH_DIR/PR.md"
assert_false "no ISSUE.md sits beside it — this reports no defect" \
  test -e "$M4_PATCH_DIR/ISSUE.md"
assert_file "verify.sh is the script (non-defect workflow)" "$M4_PATCH_DIR/verify.sh"
assert_false "no reproduce.sh sits beside it" test -e "$M4_PATCH_DIR/reproduce.sh"
assert_true "verify.sh is executable" test -x "$M4_PATCH_DIR/verify.sh"
assert_file "the format-patch file is there" "$M4_PATCH_FILE"
assert_file "and both probes" "$M4_PATCH_DIR/probe/exc.cpp"
assert_file "including the passing neighbour" "$M4_PATCH_DIR/probe/noexc.cpp"

SERIES="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs/SERIES.md"
assert_file "the series index exists" "$SERIES"
assert_contains "and indexes this patch under the directory that exists" \
  "aztec-wasi-sdk-33" "$(cat "$SERIES")"

# Comment lines are stripped first: verify.sh's own header explains WHY it does
# not skip, and matching the word there would make this assertion meaningless.
VS="$(grep -v '^[[:space:]]*#' "$M4_PATCH_DIR/verify.sh")"
assert_not_contains "verify.sh has no SKIPPED path in its code at all" "SKIP" "$VS"
assert_contains "an input it cannot get is a 'cannot run', not a pass" "cannot run:" "$VS"
assert_contains "and that exits 2" "exit 2" "$VS"

# ---------------------------------------------------------------------------
# The inputs. Built by the same machinery the other M4 checks use, so this check
# cannot silently be measuring something else.
# ---------------------------------------------------------------------------
m4_prepare_trees
SDK27="$(m4_sdk 27)"
SDK33="$(m4_sdk 33)"
BASE="$M4_WORK/base"; PATCHED="$M4_WORK/patched"
BB27="$BASE/barretenberg/cpp/build-wasm/bin/barretenberg.wasm"
BB33="$PATCHED/barretenberg/cpp/build-wasm/bin/barretenberg.wasm"
if [ ! -f "$BB27" ] || [ ! -f "$BB33" ]; then
  note "building the two artefacts (this is the expensive part; it is cached under \$M4_WORK)"
  m4_wasm_build "$BASE"    "$SDK27" wasm barretenberg.wasm || die "the wasi-sdk 27 build failed"
  m4_wasm_build "$PATCHED" "$SDK33" wasm barretenberg.wasm || die "the wasi-sdk 33 build failed"
fi
assert_file "the wasi-sdk 27 artefact is available" "$BB27"
assert_file "the wasi-sdk 33 artefact is available" "$BB33"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_verify <label> <verify.sh-arg-string> <ENV=VALUE>...
#
# Writes $WORK/<label>.out and prints verify.sh's exit status on stdout. The
# script's arguments are one string and the environment assignments are the rest,
# because `env` cannot tell the two apart on a single argv.
run_verify() {
  local label="$1" vargs="$2"; shift 2
  m4_in_devshell '
    label="$1"; work="$2"; dir="$3"; vargs="$4"; shift 4
    env "$@" "$dir/verify.sh" $vargs >"$work/$label.out" 2>&1
    echo "@@@ rc=$?"
  ' "$label" "$WORK" "$M4_PATCH_DIR" "$vargs" "$@" | sed -n 's/^@@@ rc=//p'
}

# ---------------------------------------------------------------------------
# The clean run.
# ---------------------------------------------------------------------------
RC_FULL="$(run_verify full "" \
  "WASI27=$SDK27" "WASI33=$SDK33" "WASM27=$BB27" "WASM33=$BB33")"
FULL="$(cat "$WORK/full.out")"
assert_eq "verify.sh exits 0 on the real inputs" "0" "$RC_FULL"
assert_contains "and says OK" "OK" "$FULL"
assert_contains "part A ran" "A. can a native build see any of this?" "$FULL"
assert_contains "part B ran" "B. C++ exceptions, per toolchain" "$FULL"
assert_contains "part C ran" "C. the shipped artefact, built both ways" "$FULL"
assert_not_contains "nothing failed inside it" "FAIL " "$FULL"
N_ASSERT="$(printf '%s\n' "$FULL" | sed -n 's/^\([0-9]*\) assertion(s).*/\1/p' | head -1)"
assert_ge "and it asserted a real number of things" 30 "$N_ASSERT"
note "verify.sh clean run: $N_ASSERT assertions"

# ---------------------------------------------------------------------------
# M4 (taken first because it is the anti-skip assertion): a missing input must
# not be reported as success.
# ---------------------------------------------------------------------------
RC_NOENV="$(run_verify noenv "" "WASI27=" "WASI33=" "WASM27=" "WASM33=")"
if [ "$RC_NOENV" = "2" ]; then
  pass "with no toolchains supplied, verify.sh reports 'cannot run' (exit 2), not success"
else
  fail "verify.sh exited $RC_NOENV with no inputs — a skip that reports success"
fi
assert_contains "and names the variable to set" "cannot run: set WASI27" "$(cat "$WORK/noenv.out")"

# Part A alone is legitimately runnable with nothing installed. It must still
# assert something rather than trivially pass.
RC_A="$(run_verify onlya "--only=A" "WASI27=" "WASI33=" "WASM27=" "WASM33=")"
assert_eq "--only=A runs standalone" "0" "$RC_A"
A_ASSERT="$(sed -n 's/^\([0-9]*\) assertion(s).*/\1/p' "$WORK/onlya.out" | head -1)"
assert_ge "and asserts something" 3 "$A_ASSERT"

# ---------------------------------------------------------------------------
# M1: a patch that also touches a source file.
# ---------------------------------------------------------------------------
MUT="$WORK/mut-patch"; mkdir -p "$MUT/probe"
cp "$M4_PATCH_DIR/probe/"*.cpp "$MUT/probe/"
cp "$M4_PATCH_DIR/verify.sh" "$MUT/verify.sh"
sed 's|^+++ b/bootstrap.sh$|+++ b/barretenberg/cpp/src/barretenberg/common/try_catch_shim.hpp|' \
  "$M4_PATCH_FILE" > "$MUT/0001-mutated.patch"
assert_contains "the mutation really is present in the mutated patch" \
  "+++ b/barretenberg/cpp/src/barretenberg/common/try_catch_shim.hpp" "$(cat "$MUT/0001-mutated.patch")"
RC_M1="$(m4_in_devshell '
  work="$1"; mut="$2"
  env WASI27= WASI33= WASM27= WASM33= "$mut/verify.sh" --only=A >"$work/m1.out" 2>&1
  echo "@@@ rc=$?"' "$WORK" "$MUT" | sed -n 's/^@@@ rc=//p')"
if [ "$RC_M1" != "0" ]; then
  pass "a patch that also touches a header is rejected  [exit $RC_M1]"
else
  fail "the mutated patch was accepted — part A is vacuous"
fi
assert_contains "and it is rejected for the RIGHT reason (the file is named)" \
  "UNEXPECTED file in the patch: barretenberg/cpp/src/barretenberg/common/try_catch_shim.hpp" \
  "$(cat "$WORK/m1.out")"

# ---------------------------------------------------------------------------
# M2: a "wasi-sdk 27" that is really 33. The cheap version assertion is defeated
# on purpose — VERSION is rewritten — so the only thing left to catch it is the
# link behaviour itself.
# ---------------------------------------------------------------------------
FAKE27="$WORK/fake27"
mkdir -p "$FAKE27"
for entry in "$SDK33"/*; do
  base="$(basename "$entry")"
  [ "$base" = VERSION ] && continue
  ln -s "$entry" "$FAKE27/$base"
done
printf '27.0\n' > "$FAKE27/VERSION"
assert_eq "the decoy claims to be 27" "27.0" "$(head -1 "$FAKE27/VERSION")"
assert_true "but its clang++ is 33's" test -x "$FAKE27/bin/clang++"
RC_M2="$(run_verify m2 "--only=B" "WASI27=$FAKE27" "WASI33=$SDK33" "WASM27=" "WASM33=")"
M2_OUT="$(cat "$WORK/m2.out")"
if [ "$RC_M2" != "0" ]; then
  pass "a 33 masquerading as 27 is rejected  [exit $RC_M2]"
else
  fail "the decoy toolchain was accepted — part B's 27 half is vacuous"
fi
# It is caught for the right reason, and the reason is NOT the cheap one: the
# decoy's VERSION says 27.0, so `WASI27 really is wasi-sdk 27` passes. What fails
# is the sysroot's own contents and the shape of the link failure — which is the
# whole substance of the 27 half of this patch's argument.
assert_contains "and for the RIGHT reason: its libc++abi is not the no-exception build" \
  "FAIL 27 libc++abi is the no-exception build" "$M2_OUT"
assert_contains "and it ships an unwinder, which 27 does not" \
  "FAIL 27 ships no unwinder  expected [0], got [20]" "$M2_OUT"
assert_contains "and its link failure does not name the C++ exception runtime" \
  "FAIL 27's failure names __cxa_allocate_exception" "$M2_OUT"
assert_not_contains "the version assertion is NOT what caught it" \
  "FAIL WASI27 really is wasi-sdk 27" "$M2_OUT"

# ---------------------------------------------------------------------------
# M3: the artefact comparison against a module that is not the same program.
# ---------------------------------------------------------------------------
DECOY="$WORK/decoy.wasm"
"$SDK33/bin/clang++" --target=wasm32-wasip1 -O2 -fwasm-exceptions \
  -mllvm -wasm-use-legacy-eh=false "$M4_PATCH_DIR/probe/exc.cpp" -lunwind -o "$DECOY" \
  >"$WORK/decoy.log" 2>&1
assert_file "a decoy module was produced" "$DECOY"
RC_M3="$(run_verify m3 "--only=C" "WASI27=" "WASI33=" "WASM27=$DECOY" "WASM33=$BB33")"
M3_OUT="$(cat "$WORK/m3.out")"
if [ "$RC_M3" != "0" ]; then
  pass "comparing against a different module is rejected  [exit $RC_M3]"
else
  fail "the decoy artefact comparison passed — part C is vacuous"
fi
assert_contains "and for the RIGHT reason: the import lists differ" \
  "import lists DIFFER" "$M3_OUT"

# ---------------------------------------------------------------------------
# PR.md carries what the convention requires.
# ---------------------------------------------------------------------------
PR="$(cat "$M4_PATCH_DIR/PR.md")"
for field in "**Upstream project:**" "**Kind:**" "**Status:**" "**Base commit:**" \
             "**Patch:**" "**Order in the series:**"; do
  assert_contains "PR.md carries the header field $field" "$field" "$PR"
done
assert_contains "PR.md says plainly that upstream has no live defect" "Not a defect report" "$PR"
assert_contains "PR.md discloses our motive at the end" "Why we care" "$PR"
assert_contains "PR.md records the prior-art search" "Prior art searched" "$PR"
assert_contains "PR.md states its known limitations" "Known limitations" "$PR"
assert_contains "PR.md names the base commit the patch was generated against" \
  "$M4_BASE_REV" "$PR"
assert_contains "PR.md is not filed yet, and says so" "not filed" "$PR"

finish
