#!/usr/bin/env bash
# File the AVM / server CMake module split upstream, as a pull request against
# AztecProtocol/aztec-packages, from the branch our fork already carries.
#
# One command, like its four siblings — but this one is NOT standalone, and it
# refuses to run until the three it depends on have been filed.
#
#   * p1 (crypto_merkle_tree / LMDB split) is an APPLY prerequisite: without it
#     `git am` of this patch is rejected, on `crypto/CMakeLists.txt`, whose
#     context p1 owns. Its commit is therefore in this branch and will appear in
#     the pull request's diff.
#   * p2 (wasi-sdk 33) and p3 (widen before shifting) are BUILD prerequisites:
#     this patch applies cleanly without either, and the resulting tree fails to
#     compile. They are in the branch too, so that a reviewer who checks it out
#     can actually build what the patch claims to enable.
#
# That distinction is measured rather than asserted — see
# `just verify-cmake-split-patch-applies`. The stack note below states it in the
# pull request body, with the three prerequisite PR numbers filled in from what
# has actually been filed, so the reviewer is told which commit is the one under
# review rather than left to work it out from a four-commit diff.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$HERE/_lib.sh"

# Build the stack note from recorded submissions. A missing prerequisite URL is a
# hard stop: filing this one first would present a reviewer with three unexplained
# commits and no way to review the fourth.
prereq_url() { # <id>
  local u
  u="$(series_field "$1" ledger.url)"
  if [ -z "$u" ]; then
    die "prerequisite $1 has not been filed yet (no URL in carry/series.json).

    This patch stacks on three others and must be filed last. Run, in order:
      submit/pr1-crypto-merkle-tree-lmdb-split.sh
      submit/pr2-wasi-sdk-33.sh
      submit/pr3-widen-before-shifting.sh
    and then this one."
  fi
  printf '%s\n' "$u"
}

P1_URL="$(prereq_url p1)" || exit 1
P2_URL="$(prereq_url p2)" || exit 1
P3_URL="$(prereq_url p3)" || exit 1

STACK_NOTE="$(cat <<EOF
> **This pull request is stacked.** Four commits are shown; only the last one,
> \`build(wasm): optional AVM_WASM, and separate the AVM modules from the server
> modules\`, is what this pull request is asking you to take. The other three are
> already open on their own:
>
> * $P1_URL — \`refactor(crypto): split crypto_merkle_tree from its LMDB backend\`.
>   An **apply** prerequisite: without it, \`git am\` of this patch is rejected on
>   \`barretenberg/cpp/src/barretenberg/crypto/CMakeLists.txt\`.
> * $P2_URL — \`build: move the wasm toolchain from wasi-sdk 27 to 33\`.
>   A **build** prerequisite: this patch applies without it and the tree does not
>   compile, because the exception flags it adds need a toolchain that has
>   exceptions.
> * $P3_URL — \`fix(vm2): widen before shifting in compute_public_bytecode_first_field\`.
>   Also a **build** prerequisite: without it the wasm build stops on
>   \`vm2/simulation/lib/contract_crypto.cpp\` under \`-Wshift-count-overflow\`,
>   which is an error under \`-Werror\`.
>
> Which of the three is an apply prerequisite and which are build prerequisites
> was established by trying each combination, not by grouping them together.
>
> If those three land first, this branch will be rebased and this note removed.
EOF
)"
export STACK_NOTE

submit_main p5 "$@"
