#!/usr/bin/env bash
# verify_aztec_constants_codegen_reproducible
#
# M1 verification: running the constants codegen twice from the pinned checkout
# produces byte-identical aztec_constants.hpp.
#
# `aztec_constants.hpp` is generated from the Noir protocol constants by
# `protocol/constants-codegen` and is NOT checked in — that claim is asserted
# here with `git ls-tree` at the pinned anchor rather than taken on trust. The
# generator's final step is `clang-format-20`, invoked by that exact versioned
# name, which is the M0 shell alias; the fork's dev shell provides it, so this
# check runs inside `nix develop` for the fork and FAILS if it cannot.
#
# What is asserted, beyond "twice gives the same bytes" — which two runs of a
# hash-free pure function would satisfy vacuously:
#
#   * the output is non-trivial: hundreds of lines, and it actually contains the
#     constants the runtime reasons about (the three DOM_SEP__* separators);
#   * the two runs are byte-identical AND share a sha256;
#   * a THIRD run into a different directory also matches, so the equality is
#     not an artefact of writing to the same path;
#   * the reproduced header matches the one the fork's own CMake configure step
#     produced in-tree — i.e. we reproduce upstream's build step, not merely our
#     own script;
#   * the generator inputs are the PINNED ones (`git diff` against the anchor),
#     so a reproducible build of the wrong revision cannot pass;
#   * and a NEGATIVE CONTROL: perturbing the Noir input changes the output, so
#     the "identical" result is a property of the input rather than of a
#     generator that ignores it.
#
# Run: just verify-constants-codegen

TEST_NAME="verify_aztec_constants_codegen_reproducible"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v nix >/dev/null 2>&1 || die "nix is required (the codegen needs the fork's dev shell)"
command -v git >/dev/null 2>&1 || die "git is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"
[ -d "$FORK_ROOT/.git" ] || die "the aztec-packages fork is not at $FORK_ROOT"
GEN="$REPO_ROOT/tools/gen_aztec_constants.sh"
[ -x "$GEN" ] || die "tools/gen_aztec_constants.sh is missing or not executable"

ANCHOR="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")" \
  || die "could not read the cpp anchor from pins.json"
assert_eq "the cpp anchor is a full sha1" 40 "${#ANCHOR}"

# ---- the header really is generated, not checked in ------------------------
tracked="$(git -C "$FORK_ROOT" ls-tree --name-only "$ANCHOR" \
  barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp)"
assert_eq "aztec_constants.hpp is NOT tracked at the pinned anchor" "" "$tracked"
assert_true "its generator IS tracked at the pinned anchor" \
  git -C "$FORK_ROOT" cat-file -e "$ANCHOR:protocol/constants-codegen/src/cli.ts"
assert_true "the build step that drives it IS tracked at the pinned anchor" \
  git -C "$FORK_ROOT" cat-file -e "$ANCHOR:barretenberg/cpp/scripts/remake-constants.sh"
remake="$(git -C "$FORK_ROOT" show "$ANCHOR:barretenberg/cpp/scripts/remake-constants.sh")"
assert_contains "the build step invokes clang-format-20 by that exact versioned name" \
  "clang-format-20" "$remake"

# ---- run it three times, into three directories ----------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

run_out="$( cd "$FORK_ROOT" && nix develop --command bash -c "
  set -e
  '$GEN' '$WORK/a/aztec_constants.hpp'
  '$GEN' '$WORK/b/aztec_constants.hpp'
  '$GEN' '$WORK/c/aztec_constants.hpp'
" 2>&1 )"
rc=$?
if [ "$rc" -ne 0 ]; then
  printf '%s\n' "$run_out" | tail -5 | sed 's/^/      /' >&2
  die "the constants codegen did not run (exit $rc)"
fi

assert_file "run 1 produced a header" "$WORK/a/aztec_constants.hpp"
assert_file "run 2 produced a header" "$WORK/b/aztec_constants.hpp"
assert_file "run 3 produced a header" "$WORK/c/aztec_constants.hpp"

lines="$(wc -l < "$WORK/a/aztec_constants.hpp")"
assert_ge "the generated header is substantial" 200 "$lines"

body="$(cat "$WORK/a/aztec_constants.hpp")"
for sym in DOM_SEP__MERKLE_HASH DOM_SEP__NULLIFIER_MERKLE DOM_SEP__PUBLIC_DATA_MERKLE; do
  assert_contains "the generated header carries $sym" "$sym" "$body"
done
assert_contains "the generated header is a C++ header" "#pragma once" "$body"

if cmp -s "$WORK/a/aztec_constants.hpp" "$WORK/b/aztec_constants.hpp"; then
  pass "two runs produce byte-identical output"
else
  fail "two runs differ: $(diff "$WORK/a/aztec_constants.hpp" "$WORK/b/aztec_constants.hpp" | head -3 | tr '\n' ' ')"
fi
if cmp -s "$WORK/a/aztec_constants.hpp" "$WORK/c/aztec_constants.hpp"; then
  pass "a third run into a third directory also matches"
else
  fail "the third run differs from the first"
fi

sha_a="$(sha256sum < "$WORK/a/aztec_constants.hpp" | cut -d' ' -f1)"
sha_b="$(sha256sum < "$WORK/b/aztec_constants.hpp" | cut -d' ' -f1)"
assert_eq "the two runs share a sha256" "$sha_a" "$sha_b"
note "sha256 ${sha_a:0:16}…"

# ---- it reproduces UPSTREAM's build step, not just our script ---------------
INTREE="$FORK_ROOT/barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp"
if [ -f "$INTREE" ]; then
  if cmp -s "$WORK/a/aztec_constants.hpp" "$INTREE"; then
    pass "the reproduced header is byte-identical to the one the fork's CMake configure produced"
  else
    fail "the reproduced header differs from the fork's in-tree generated header"
  fi
else
  fail "the fork has no generated aztec_constants.hpp to compare against; configure it once so this check is not vacuous"
fi

# ---- the inputs are the pinned ones ----------------------------------------
for p in protocol/constants-codegen \
         noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr \
         barretenberg/cpp/scripts/remake-constants.sh; do
  if git -C "$FORK_ROOT" diff --quiet "$ANCHOR" -- "$p"; then
    pass "generator input is at the pinned anchor: $p"
  else
    fail "generator input differs from the pinned anchor: $p"
  fi
done

# ---- negative control -------------------------------------------------------
# Byte-identical output from two runs is worthless if the generator ignores its
# input. Perturb the Noir constants in a COPY and require the output to change.
perturbed="$WORK/constants.nr"
git -C "$FORK_ROOT" show "$ANCHOR:noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr" \
  > "$perturbed"
python3 - "$perturbed" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
# Change one concrete numeric constant. Any one will do; the point is that the
# generator must notice.
s2, n = re.subn(r"(pub global MAX_NOTE_HASHES_PER_TX: u32 = )(\d+)",
                lambda m: m.group(1) + str(int(m.group(2)) + 1), s, count=1)
if n == 0:
    s2, n = re.subn(r"(pub global [A-Z0-9_]+: u32 = )(\d+)",
                    lambda m: m.group(1) + str(int(m.group(2)) + 1), s, count=1)
if n == 0:
    raise SystemExit("could not perturb any constant; the control would be vacuous")
open(p, "w", encoding="utf-8").write(s2)
PY
[ $? -eq 0 ] || die "could not build the negative control's perturbed input"

ctl_out="$( cd "$FORK_ROOT" && nix develop --command bash -c "
  set -e
  node '$FORK_ROOT/protocol/constants-codegen/src/cli.ts' \
    --input '$perturbed' \
    --cpp '$WORK/perturbed.hpp' \
    --selection '$FORK_ROOT/barretenberg/cpp/scripts/constants-codegen/cpp.json'
  clang-format-20 --style='file:$FORK_ROOT/barretenberg/cpp/.clang-format' -i '$WORK/perturbed.hpp'
" 2>&1 )"
if [ ! -s "$WORK/perturbed.hpp" ]; then
  printf '%s\n' "$ctl_out" | tail -3 | sed 's/^/      /' >&2
  fail "the negative control did not produce a header"
elif cmp -s "$WORK/a/aztec_constants.hpp" "$WORK/perturbed.hpp"; then
  fail "perturbing the Noir input produced identical output — the generator ignores its input"
else
  pass "perturbing the Noir input changes the generated header (the reproducibility is a property of the input)"
fi

finish
