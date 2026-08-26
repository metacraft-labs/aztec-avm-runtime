#!/usr/bin/env bash
# M23's reproducible entry point: build the `avm.wasm` that CARRIES THE ARCHIVE.
#
#   verification/build_avm_wasm_m23.sh        (or: just avm-wasm-build-m23)
#
# TWELVE COMMITS OVER THE ANCHOR, and the last two are what makes this tree different from M13's:
#
#     233d8e0993
#       + M6's four        the merkle/LMDB split, wasi-sdk 27 -> 33, widen-before-shift, AVM_WASM
#       + M9's observer    the per-instruction observation hook
#       + M7's fifth       AVM_SIM_TESTS
#       + M8's sixth       AVM_DIFFERENTIAL
#       + M9's seventh     the step record
#       + M12's ninth      AVM_REACTOR — thirty-nine exports
#       + M13's tenth      the in-memory contract DB — forty-nine
#       + M14's ELEVENTH   the archive tree on world_state_reference (RI-53), prepared in M14 and
#                          not carried until now
#       + M23's TWELFTH    the archive across the vm2 adapter and out through the reactor (RI-70)
#                          — fifty-one
#
# THIS IS A DIFFERENT ARTEFACT FROM M12'S AND M13'S AND IS MEASURED SEPARATELY, which is exactly
# what M13 did for its tenth overlay. An export APPEARING is as much a finding as one disappearing,
# so no earlier milestone's module is repointed at this tree and no earlier milestone's pinned
# export count moves: M18, M20, M21 and M22 go on measuring the trees they were written against,
# where the archive is absent and `sealBlock` refuses.
#
# It does not skip. A missing patch, an unpreparable tree, a failed configure or a failed build is
# a non-zero exit with the reason on stderr.

set -uo pipefail

TEST_NAME=build_avm_wasm_m23
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

. "$VERIFY_DIR/lib_avm_wasm.sh"
. "$VERIFY_DIR/lib_vm2_tests.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"
. "$VERIFY_DIR/lib_m13_contract_db.sh"
. "$VERIFY_DIR/lib_m14_world_state.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

# M6_WORK is where `m6_prepare_tree` puts its worktrees, and M23 owns its own so this tree cannot
# be confused with M13's — they carry different patch stacks and would otherwise both be "the tree".
#
# IT IS SET AFTER THE SOURCING AND NOT BEFORE, which is not a style choice. Several of those
# libraries repoint `M6_WORK` at their OWN milestone's directory when sourced; setting it first put
# M23's twelve-patch tree under `~/.cache/aztec-m14-archive/` on this script's first run, where
# `m23_find_module` would never have looked for it. Measured, not reasoned about.
M6_WORK="${M23_WORK:-$HOME/.cache/aztec-m23-chain}"
export M6_WORK

require_work_dir "$M6_WORK" 8

[ -f "$M14_PATCH" ] || die "M14's archive patch is missing: $M14_PATCH"
[ -f "$M23_PATCH" ] || die "M23's overlay patch is missing: $M23_PATCH"

note "work directory: $M6_WORK"

M23_TREE=$(m6_prepare_tree m23 \
  "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4" \
  "$M9_OBSERVER_PATCH" "$M7_PATCH_5" "$M8_PATCH_6" "$M9_PATCH_7" "$M12_PATCH_9" "$M13_PATCH_10" \
  "$M14_PATCH" "$M23_PATCH")
# A command substitution swallows `die`, so the tree can come back empty and every later `git -C ""`
# would run in the CALLER's repository. M6 was bitten by exactly this.
m6_tree_or_die M23_TREE
note "tree: $M23_TREE ($(git -C "$M23_TREE" rev-parse --short HEAD), $M6_BASE_REV + 12 patches)"

m6_configure "$M23_TREE" wasm-avm build-wasm-avm -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON -DAVM_SIM_TESTS=ON
cfg=$?
if [ "$cfg" -ne 0 ]; then
  printf '%s: configure failed (exit %d) — see %s\n' \
    "$TEST_NAME" "$cfg" "$M23_TREE/m6-build-wasm-avm.log" >&2
  tail -30 "$M23_TREE/m6-build-wasm-avm.log" >&2
  exit "$cfg"
fi

m6_build "$M23_TREE" build-wasm-avm avm.wasm.gz avm-unpruned.wasm.gz avm-nogc.wasm.gz vm2_sim_tests
bld=$?
if [ "$bld" -ne 0 ]; then
  printf '%s: build failed (exit %d) — see %s\n' \
    "$TEST_NAME" "$bld" "$M23_TREE/m6-build-wasm-avm.log" >&2
  tail -30 "$M23_TREE/m6-build-wasm-avm.log" >&2
  exit "$bld"
fi

WASM="$M23_TREE/barretenberg/cpp/build-wasm-avm/bin/avm.wasm"
[ -s "$WASM" ] || die "the build reported success but produced no $WASM"

# THE TWO EXPORTS ARE THE POINT OF THIS TREE, so the entry point refuses a module without them
# rather than leaving that for a check to discover.
HAVE="$(m23_module_exports "$WASM")"
for want in avm_merkle_db_update_archive avm_merkle_db_get_archive_snapshot; do
  str_has_line "$HAVE" "$want" \
    || die "the build produced a module without $want — the twelfth overlay did not take effect"
done

printf '%s: built %s (%s exports)\n' \
  "$TEST_NAME" "$WASM" "$(printf '%s\n' "$HAVE" | grep -c .)"
printf '%s: set AVM_WASM_PATH=%s, or leave it unset — the M23 checks look here.\n' \
  "$TEST_NAME" "$WASM"
