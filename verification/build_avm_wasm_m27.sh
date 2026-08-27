#!/usr/bin/env bash
# M27's reproducible entry point: build the `avm.wasm` that EXPORTS POSEIDON2.
#
#   verification/build_avm_wasm_m27.sh        (or: just avm-wasm-build-m27)
#
# THIRTEEN COMMITS OVER THE ANCHOR, and the last one is what makes this tree different from M23's:
#
#     233d8e0993
#       + M6's four        the merkle/LMDB split, wasi-sdk 27 -> 33, widen-before-shift, AVM_WASM
#       + M9's observer    the per-instruction observation hook
#       + M7's fifth       AVM_SIM_TESTS
#       + M8's sixth       AVM_DIFFERENTIAL
#       + M9's seventh     the step record
#       + M12's ninth      AVM_REACTOR — thirty-nine exports
#       + M13's tenth      the in-memory contract DB — forty-nine
#       + M14's eleventh   the archive tree on world_state_reference (RI-53)
#       + M23's twelfth    the archive across the vm2 adapter and out through the reactor (RI-70)
#                          — fifty-one
#       + M27's THIRTEENTH poseidon2 and grumpkin out through the reactor (RI-73) — FIFTY-FIVE
#
# WHY THE THIRTEENTH EXISTS, IN ONE PARAGRAPH, BECAUSE IT IS THE MILESTONE'S LOAD-BEARING FACT.
# DD-11 requires that a page which only executes a public transaction never fetches the
# barretenberg proving wasm. Measured before the patch was written: such a page reaches
# `@aztec/foundation`'s `poseidon2Hash` 82 times in one Form A run, and in a browser that function
# calls `BarretenbergSync.initSingleton()`, which downloads 7.9 MB of proving stack. `avm.wasm` is
# itself a barretenberg build and already links `crypto_poseidon2`; exporting it is what makes
# DD-11 satisfiable instead of aspirational.
#
# THIS IS A DIFFERENT ARTEFACT FROM M12'S, M13'S AND M23'S AND IS MEASURED SEPARATELY, which is
# what M13 and M23 each did for their own overlay. An export APPEARING is as much a finding as one
# disappearing, so no earlier milestone's module is repointed at this tree and no earlier
# milestone's pinned export count moves.
#
# It does not skip. A missing patch, an unpreparable tree, a failed configure or a failed build is
# a non-zero exit with the reason on stderr.

set -uo pipefail

TEST_NAME=build_avm_wasm_m27
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

. "$VERIFY_DIR/lib_avm_wasm.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"
. "$VERIFY_DIR/lib_m14_world_state.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"

# M6_WORK is where `m6_prepare_tree` puts its worktrees, and M27 owns its own so this tree cannot
# be confused with M23's — they carry different patch stacks and would otherwise both be "the tree".
#
# SET AFTER THE SOURCING AND NOT BEFORE, which is M23's correction and not a style choice: several
# of those libraries repoint `M6_WORK` at their OWN milestone's directory when sourced.
M6_WORK="${M27_WORK:-$HOME/.cache/aztec-m27-browser}"
export M6_WORK

require_work_dir "$M6_WORK" 8

[ -f "$M14_PATCH" ] || die "M14's archive patch is missing: $M14_PATCH"
[ -f "$M23_PATCH" ] || die "M23's overlay patch is missing: $M23_PATCH"
[ -f "$M27_PATCH" ] || die "M27's overlay patch is missing: $M27_PATCH"

note "work directory: $M6_WORK"

M27_TREE=$(m6_prepare_tree m27 \
  "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
  "$M9_OBSERVER_PATCH" "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7" "$M12_PATCH_9" "$M13_PATCH_10" \
  "$M14_PATCH" "$M23_PATCH" "$M27_PATCH")
# A command substitution swallows `die`, so the tree can come back empty and every later `git -C ""`
# would run in the CALLER's repository. M6 was bitten by exactly this.
m6_tree_or_die M27_TREE
note "tree: $M27_TREE ($(git -C "$M27_TREE" rev-parse --short HEAD), $M6_BASE_REV + 13 patches)"

m6_configure "$M27_TREE" wasm-avm build-wasm-avm -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON -DAVM_SIM_TESTS=ON
cfg=$?
if [ "$cfg" -ne 0 ]; then
  printf '%s: configure failed (exit %d) — see %s\n' \
    "$TEST_NAME" "$cfg" "$M27_TREE/m6-build-wasm-avm.log" >&2
  tail -30 "$M27_TREE/m6-build-wasm-avm.log" >&2
  exit "$cfg"
fi

m6_build "$M27_TREE" build-wasm-avm avm.wasm.gz avm-unpruned.wasm.gz avm-nogc.wasm.gz vm2_sim_tests
bld=$?
if [ "$bld" -ne 0 ]; then
  printf '%s: build failed (exit %d) — see %s\n' \
    "$TEST_NAME" "$bld" "$M27_TREE/m6-build-wasm-avm.log" >&2
  tail -30 "$M27_TREE/m6-build-wasm-avm.log" >&2
  exit "$bld"
fi

WASM="$M27_TREE/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
[ -s "$WASM" ] || die "the build reported success but produced no $WASM"

# THE FOUR CRYPTO EXPORTS ARE THE POINT OF THIS TREE, so the entry point refuses a module without
# them rather than leaving that for a check to discover. The archive pair is checked too: M27's
# tree carries M23's overlay and a module that had lost it would seal nothing.
HAVE="$(m27_module_exports "$WASM")"
for want in avm_poseidon2_hash avm_poseidon2_permutation avm_grumpkin_mul avm_grumpkin_add \
            avm_merkle_db_update_archive avm_merkle_db_get_archive_snapshot; do
  str_has_line "$HAVE" "$want" \
    || die "the build produced a module without $want — the thirteenth overlay did not take effect"
done

printf '%s: built %s (%s exports, %s bytes)\n' \
  "$TEST_NAME" "$WASM" "$(printf '%s\n' "$HAVE" | grep -c .)" "$(stat -c %s "$WASM")"
printf '%s: set AVM_WASM_PATH=%s, or leave it unset — the M27 checks look here.\n' \
  "$TEST_NAME" "$WASM"
