#!/usr/bin/env bash
# Reproduce barretenberg's aztec_constants.hpp as a BUILD STEP.
#
# The header is generated, not checked in — `git ls-tree` at the pinned anchor
# shows only CMakeLists.txt and aztec_hash_policy.hpp in that directory. It is
# produced at CMake configure time by barretenberg/cpp/scripts/remake-constants.sh,
# which runs protocol/constants-codegen over the Noir protocol constants and then
# pipes the result through `clang-format-20` — the exact versioned binary name the
# M0 nix shell provides an alias for.
#
# We reproduce the generation rather than vendoring the output, so a re-pin cannot
# leave us holding stale constants that still compile. See REUSE-INVENTORY.md RI-04.
#
# Usage: tools/gen_aztec_constants.sh <output.hpp>
#
# Exits non-zero, with a reason, on every precondition it cannot satisfy. It never
# skips: a constants header that was not regenerated is not a constants header.

set -uo pipefail

out="${1:-}"
if [ -z "$out" ]; then
  echo "usage: $0 <output.hpp>" >&2
  exit 2
fi

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
fork="$(cd "$repo/.." && pwd)/aztec-packages"

fatal() { echo "gen_aztec_constants: $*" >&2; exit 1; }

[ -d "$fork/.git" ] || fatal "the aztec-packages fork is not at $fork (M0's workspace-root sibling layout)"
command -v python3 >/dev/null 2>&1 || fatal "python3 is required to read pins.json"
command -v node >/dev/null 2>&1 || fatal "node is required (the codegen CLI runs under node's type stripping)"
command -v clang-format-20 >/dev/null 2>&1 || \
  fatal "clang-format-20 is required by that exact versioned name; enter the nix shell (M0 provides the alias)"

anchor="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$repo/pins.json")" \
  || fatal "could not read the cpp anchor from pins.json"

# The generator's inputs must be the PINNED ones. The fork's HEAD carries two
# nix commits on top of the anchor; neither touches these paths, and this is the
# assertion that says so rather than assuming it.
inputs=(
  protocol/constants-codegen
  noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr
  barretenberg/cpp/scripts/remake-constants.sh
  barretenberg/cpp/scripts/constants-codegen/cpp.json
  barretenberg/cpp/.clang-format
)
if ! git -C "$fork" diff --quiet "$anchor" -- "${inputs[@]}"; then
  git -C "$fork" diff --stat "$anchor" -- "${inputs[@]}" >&2
  fatal "the fork's constants-codegen inputs differ from the pinned anchor ${anchor:0:10}"
fi
if ! git -C "$fork" diff --quiet -- "${inputs[@]}"; then
  fatal "the fork has uncommitted changes to the constants-codegen inputs"
fi

# NOT A BARE `mktemp -d`. On this workstation /tmp is a 32 GB tmpfs shared with every build, and a
# write that lands there fails silently in the middle of whatever is writing. `verification/lib.sh`
# repoints TMPDIR for every check, and this script INHERITS that when its own check runs it — but
# `just gen-constants` invokes it directly, where nothing has repointed anything. So it repoints for
# itself, on the same terms: only when TMPDIR is unset or names a RAM-backed filesystem, so an
# explicit choice (the check's included) is left exactly as it was found.
case "${TMPDIR:-/tmp}" in
  /tmp | /tmp/* | /var/tmp | /var/tmp/* | /dev/shm | /dev/shm/*)
    if [ -n "${HOME:-}" ] && mkdir -p "$HOME/.cache/aztec-verification-scratch" 2>/dev/null; then
      export TMPDIR="$HOME/.cache/aztec-verification-scratch"
    fi
    ;;
esac
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Drive the generator exactly as remake-constants.sh does, but into our own
# output path so nothing in the fork's tree is written.
node "$fork/protocol/constants-codegen/src/cli.ts" \
  --input "$fork/noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr" \
  --cpp "$tmp/aztec_constants.hpp" \
  --selection "$fork/barretenberg/cpp/scripts/constants-codegen/cpp.json" \
  || fatal "constants-codegen failed"

[ -s "$tmp/aztec_constants.hpp" ] || fatal "constants-codegen produced an empty header"

clang-format-20 --style="file:$fork/barretenberg/cpp/.clang-format" -i "$tmp/aztec_constants.hpp" \
  || fatal "clang-format-20 failed"

mkdir -p "$(dirname "$out")"
mv "$tmp/aztec_constants.hpp" "$out"
echo "gen_aztec_constants: wrote $out from ${anchor:0:10} ($(wc -l < "$out") lines)"
