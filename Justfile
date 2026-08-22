# Aztec AVM Runtime — verification entry points.
#
# Every recipe here is a real, runnable check that fails loudly. None of them
# skip: a check that cannot run in the current environment exits non-zero with
# a reason, it never prints "SKIP" and reports success.
#
# The M0 verification set (see
# codetracer-specs/Planned-Work/Aztec-AVM-Runtime.milestones.org):
#
#   just check-repo-hygiene            flake + lock + .envrc + no uncommitted generated files
#   just verify-devshell-runtime       verify_nix_devshell_aztec_avm_runtime
#   just verify-devshell-fork          verify_nix_devshell_aztec_packages_fork
#   just verify-exception-flags        verify_wasi_sdk_33_exception_flags
#   just verify-diffsim                verify_diffsim_runs_in_devshell
#   just verify-workspace-registration verify_workspace_repos_registered
#   just verify-m0                     all six, in order
#
# The M1 verification set:
#
#   just verify-reuse-inventory        verify_reuse_inventory_complete
#   just verify-provenance             verify_provenance_complete
#   just verify-vendor-drift           verify_vendor_drift_clean
#   just verify-constants-codegen      verify_aztec_constants_codegen_reproducible
#   just verify-drift-ledger           test_drift_ledger_has_bitwise_gas_entry
#   just verify-pinned-nightly         verify_pinned_nightly_single_source
#   just verify-m1                     all six, in order
#
# The M2 verification set:
#
#   just verify-fixture-manifest       verify_fixture_corpus_manifest_complete
#   just verify-arm-counts             verify_differential_arm_counts_recorded   (~3 min)
#   just verify-tree-vectors           test_world_state_golden_vectors_regenerate
#   just verify-contract-artifacts     test_contract_artifacts_load
#   just verify-avm-programs           test_seven_avm_programs_assemble
#   just verify-tier-e                 verify_tier_e_authored_fixtures_justified
#   just verify-m2                     all six, in order
#
# M2's working tools:
#
#   just measure-differential          re-measure the per-arm COMPARISON counts
#   just capture-tree-vectors          re-capture the Tier D world-state root vectors
#
# The M3 verification set (the prepared crypto_merkle_tree / LMDB split):
#
#   just verify-merkle-neutral         verify_merkle_lmdb_split_native_neutral   (~5 min)
#   just verify-merkle-link-edge       verify_merkle_lmdb_split_removes_link_edge
#   just verify-merkle-patch-applies   verify_merkle_lmdb_patch_applies_to_upstream
#   just verify-merkle-reproduce       reproduce_aztec_merkle_tree_lmdb_coupling (~3 min)
#   just verify-merkle-pr-md           verify_merkle_lmdb_issue_md_complete
#   just verify-m3                     all five, in order
#
# They build barretenberg twice — once at the patch's base commit and once with
# the patch applied — under $M3_WORK (default $TMPDIR/aztec-m3-merkle-lmdb).
# From an empty work directory that was measured at 7m18s and 1.3 GB with a warm
# ccache; afterwards ninja has nothing to do and the cost is the test binaries.
# Set M3_WORK to keep the trees somewhere persistent.
#
# The M4 verification set (the prepared wasi-sdk 27 -> 33 toolchain bump):
#
#   just verify-wasi27-cannot-link     test_wasi_sdk_27_cannot_link_exceptions
#   just verify-wasi33-catches         test_wasi_sdk_33_catches_inside_wasm
#   just verify-wasi33-targets         verify_wasi_33_existing_wasm_targets_unchanged  (~35 min)
#   just verify-wasi33-native-neutral  verify_wasi_33_native_builds_unaffected         (~4 min)
#   just verify-wasi33-reproduce       reproduce_aztec_wasi_sdk_33_exceptions
#   just verify-m4                     all five, in order
#
# They build barretenberg for wasm FOUR times under $M4_WORK (default
# $TMPDIR/aztec-m4-wasi-sdk-33): the `wasm` preset with wasi-sdk 27 and with 33,
# and the `wasm-threads` preset with 33 both without and with the patch (the
# first of those is a negative control and is meant to fail). Measured at 2.1 GB
# and about 35 minutes cold on 32 cores; afterwards ninja has nothing to do and
# the cost is the test runs. Both toolchains are realised from
# ../aztec-packages#wasi-sdk and #wasi-sdk-27, so neither is "whatever is
# installed", and one of the four builds is a NEGATIVE CONTROL that must fail.
#
# One of the two ecc_tests runs deliberately does not terminate — that is the
# finding, not a hang — so it is SIGKILLed after $M4_RUN_TIMEOUT (default 180s).
#
# The M5 verification set (the prepared widen-before-shift portability fix):
#
#   just verify-bytecode-64bit         test_bytecode_commitment_identical_on_64bit  (~1.5 min)
#   just verify-bytecode-32bit         test_bytecode_commitment_correct_on_32bit    (~10 s)
#   just verify-shift-diagnostic       test_shift_count_overflow_diagnostic         (~6 min)
#   just verify-bytecode-shift-repro   reproduce_aztec_bytecode_size_shift_32bit    (~3 min)
#   just verify-m5                     all four, in order (12m28s cold, 1.5 GB; 9m53s warm)
#
# They configure THREE worktrees of 233d8e0993 under $M5_WORK (default
# $TMPDIR/aztec-m5-bytecode-shift) and build vm2_sim in each: the base commit, the
# base plus the patch, and a DECOY carrying the patch's own added line with the
# shift count changed to 31. The decoy is not decoration — a check that only shows
# "the 64-bit results did not change" goes green for any patch that leaves them
# alone, including one that fixes the expression to something else wrong.
#
# The 32-bit target is real execution: the probes are compiled for wasm32-wasip1
# with the nix-pinned wasi-sdk 33 and RUN on wasmtime. `-m32` was tried and does
# not work, for an unrelated reason recorded in the contribution's PR.md.
#
# The diagnostic check recompiles all 249 non-test vm2 translation units for
# wasm32 twice, which is most of its six minutes and is what backs the claim that
# contract_crypto.cpp:61 is the only place in vm2 that shifts before widening.
#
# The M6 verification set (the AVM_WASM build itself):
#
#   just build-avm-wasm                the reproducible entry point
#   just verify-avm-wasm-build         verify_avm_wasm_build                            (~4 min)
#   just verify-avm-wasm-prefix        verify_avm_wasm_preset_uses_ambient_wasi_prefix  (~2 min)
#   just verify-avm-wasm-default-off   verify_avm_wasm_default_off                      (~25 min)
#   just verify-avm-wasm-gate          test_wasm_exceptions_configure_gate              (~2 min)
#   just verify-avm-wasm-closure       verify_wasm_link_closure_excludes_proving        (~2 min)
#   just verify-avm-wasm-interpreter   verify_no_interpreter_source_change              (~10 s)
#   just verify-avm-wasm-no-hack       verify_wasm_build_uses_module_split_not_hack     (~30 s)
#   just verify-m6                     all seven, in order
#
# They prepare EIGHT worktrees of 233d8e0993 under $M6_WORK (default
# $TMPDIR/aztec-m6-avm-wasm), each differing only by which prepared patches are
# applied: `base` (none), `stack3` (patches 1,2,3), `avm` (+ the AVM_WASM one),
# `hardcoded` (1,3,4 — patch 2 omitted, so its `wasm` preset still hardcodes
# /opt/wasi-sdk), `spike` (the vm2-wasm spike's own change set, which carries the
# three hacks this milestone must not reinstate), `nocast` (the AVM_WASM tree
# with the three narrowing corrections reverted, which must FAIL to build) and
# `nogate` (the gate's FATAL_ERROR removed, which must then configure under
# wasi-sdk 27). The last four are negative controls; three of them are meant to
# fail, and a check goes red if one of them succeeds.
#
# The expensive part is verify-avm-wasm-default-off: it builds barretenberg.wasm
# twice, from the `wasm` preset with and without the patch, and compares the
# artefacts byte for byte. Budget about 5 GB under $M6_WORK.
#
# M1's working tools, which the checks drive:
#
#   just check-drift                   the vendored tree vs its recorded commits
#   just vendor-headers                (re)write every provenance header
#   just regen-drift                   regenerate drift/src from spike/src
#   just repin                         rewrite the @aztec/* versions from pins.json
#   just gen-constants <out>           reproduce aztec_constants.hpp
#
# The sibling fork is expected at ../aztec-packages (a workspace-root sibling,
# the M0 layout decision). The checks fail if it is not there.

set shell := ["bash", "-uc"]

_default:
    @just --list

# Assert each repo has a flake, a lock, an .envrc and no uncommitted generated files.
check-repo-hygiene:
    @verification/check_repo_hygiene.sh

# nix develop provides node 24, yarn 4, wasi-sdk 33, wasmtime, binaryen, wabt, cmake, ninja, clang 20 + the exported variables.
verify-devshell-runtime:
    @verification/verify_nix_devshell_aztec_avm_runtime.sh

# The fork's shell configures the wasm preset and compiles barretenberg C++ to wasm32-wasip1.
verify-devshell-fork:
    @verification/verify_nix_devshell_aztec_packages_fork.sh

# The C++-exceptions-on-wasm flag recipe, with both negative controls.
verify-exception-flags:
    @verification/verify_wasi_sdk_33_exception_flags.sh

# The TypeScript-versus-C++ differential harness runs green inside the shell.
verify-diffsim:
    @verification/verify_diffsim_runs_in_devshell.sh

# Both repos are registered in the workspace and are checkoutable from their resolved coordinates.
verify-workspace-registration:
    @verification/verify_workspace_repos_registered.sh

# ---------------------------------------------------------------------------
# M1 — pinned upstream anchors and the reuse inventory
# ---------------------------------------------------------------------------

# Diff the vendored tree against its recorded commits; only PROVENANCE.md's edits may differ.
check-drift:
    @verification/check_drift.sh

# (Re)write the provenance header in every vendored file, from PROVENANCE.md + pins.json.
vendor-headers:
    @python3 tools/provenance.py headers --apply

# Regenerate drift/src from spike/src by the recorded re-pin transformation.
regen-drift:
    #!/usr/bin/env bash
    set -euo pipefail
    out="$(mktemp -d)"
    trap 'rm -rf "$out"' EXIT
    python3 tools/provenance.py render-drift "$out" >/dev/null
    rm -rf drift/src
    cp -a "$out" drift/src
    python3 tools/provenance.py headers --apply
    echo "regen-drift: drift/src regenerated from spike/src"

# Rewrite every tree's @aztec/* versions from pins.json (a no-op when they agree).
repin:
    @python3 tools/repin.py --apply

# Reproduce barretenberg's generated aztec_constants.hpp. Run inside the fork's nix shell.
gen-constants out:
    @tools/gen_aztec_constants.sh {{out}}

# Every Aztec component has an inventory entry with a decision and a specific reason.
verify-reuse-inventory:
    @verification/verify_reuse_inventory_complete.sh

# Every vendored file's header names a path that exists at the recorded commit.
verify-provenance:
    @verification/verify_provenance_complete.sh

# check-drift reports only PROVENANCE.md's edits, and fails on anything else.
verify-vendor-drift:
    @verification/verify_vendor_drift_clean.sh

# The constants codegen is byte-reproducible from the pinned checkout.
verify-constants-codegen:
    @verification/verify_aztec_constants_codegen_reproducible.sh

# The drift ledger carries the bitwise-gas entry, and it is still a real divergence.
verify-drift-ledger:
    @verification/test_drift_ledger_has_bitwise_gas_entry.sh

# One authority for the pinned nightly, and nothing disagrees with it.
verify-pinned-nightly:
    @verification/verify_pinned_nightly_single_source.sh

# Run the whole M1 verification set; every check runs even if an earlier one fails.
verify-m1:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_reuse_inventory_complete \
      verify_provenance_complete \
      verify_vendor_drift_clean \
      verify_aztec_constants_codegen_reproducible \
      test_drift_ledger_has_bitwise_gas_entry \
      verify_pinned_nightly_single_source
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m1: FAILED" >&2
    else
      echo "verify-m1: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M2 — the upstream fixture corpus
# ---------------------------------------------------------------------------

# Every fixture family has a manifest entry with its source, capture, licence and conclusions.
verify-fixture-manifest:
    @verification/verify_fixture_corpus_manifest_complete.sh

# The manifest's per-arm COMPARISON counts equal a fresh measurement. Takes about three minutes.
verify-arm-counts:
    @verification/verify_differential_arm_counts_recorded.sh

# The Tier D root vectors regenerate byte-for-byte, agree with upstream, and restate nothing of it.
verify-tree-vectors:
    @verification/test_world_state_golden_vectors_regenerate.sh

# All six contract artifacts load and expose every public function the corpus calls.
verify-contract-artifacts:
    @verification/test_contract_artifacts_load.sh

# The seven corpus programs re-assemble to upstream's byte lengths and derived addresses.
verify-avm-programs:
    @verification/test_seven_avm_programs_assemble.sh

# Every Tier E entry's "no upstream equivalent" claim is re-derived from the pinned fork.
verify-tier-e:
    @verification/verify_tier_e_authored_fixtures_justified.sh

# Re-measure what the differential suite actually compares, and rewrite the record.
measure-differential:
    @python3 tools/measure_differential.py --out fixtures/differential-arm-counts.json

# Re-capture the Tier D world-state root vectors from the real NativeWorldStateService.
capture-tree-vectors:
    #!/usr/bin/env bash
    set -euo pipefail
    cd drift && node capture_world_state.mjs > ../fixtures/trees/world-state-vectors.json
    echo "capture-tree-vectors: fixtures/trees/world-state-vectors.json regenerated"

# Run the whole M2 verification set; every check runs even if an earlier one fails.
verify-m2:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_fixture_corpus_manifest_complete \
      verify_differential_arm_counts_recorded \
      test_world_state_golden_vectors_regenerate \
      test_contract_artifacts_load \
      test_seven_avm_programs_assemble \
      verify_tier_e_authored_fixtures_justified
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m2: FAILED" >&2
    else
      echo "verify-m2: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M3 — the prepared upstream patch splitting crypto_merkle_tree from LMDB
# ---------------------------------------------------------------------------

# The same targets and test binaries before and after the split: 132 -> 36 + 96, same names.
verify-merkle-neutral:
    @verification/verify_merkle_lmdb_split_native_neutral.sh

# crypto_merkle_tree no longer depends on lmdblib, and its test binary links no LMDB object.
verify-merkle-link-edge:
    @verification/verify_merkle_lmdb_split_removes_link_edge.sh

# The format-patch applies cleanly to 233d8e0993 and the result configures and builds.
verify-merkle-patch-applies:
    @verification/verify_merkle_lmdb_patch_applies_to_upstream.sh

# The contribution's own verify.sh discriminates: non-zero unpatched, zero patched.
verify-merkle-reproduce:
    @verification/reproduce_aztec_merkle_tree_lmdb_coupling.sh

# PR.md carries what the convention requires, and every claim in it is re-derived.
verify-merkle-pr-md:
    @verification/verify_merkle_lmdb_issue_md_complete.sh

# Run the whole M3 verification set; every check runs even if an earlier one fails.
verify-m3:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_merkle_lmdb_split_native_neutral \
      verify_merkle_lmdb_split_removes_link_edge \
      verify_merkle_lmdb_patch_applies_to_upstream \
      reproduce_aztec_merkle_tree_lmdb_coupling \
      verify_merkle_lmdb_issue_md_complete
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m3: FAILED" >&2
    else
      echo "verify-m3: all checks passed"
    fi
    exit "$rc"

# Run the whole M0 verification set; every check runs even if an earlier one fails.
verify-m0:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      check_repo_hygiene \
      verify_nix_devshell_aztec_avm_runtime \
      verify_nix_devshell_aztec_packages_fork \
      verify_wasi_sdk_33_exception_flags \
      verify_diffsim_runs_in_devshell \
      verify_workspace_repos_registered
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m0: FAILED" >&2
    else
      echo "verify-m0: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M4 — the prepared upstream patch moving the wasm toolchain from wasi-sdk 27 to 33
# ---------------------------------------------------------------------------

# wasi-sdk 27 cannot link a C++ program that throws, and the same program without a throw links.
verify-wasi27-cannot-link:
    @verification/test_wasi_sdk_27_cannot_link_exceptions.sh

# wasi-sdk 33 + the three flags throws, unwinds and catches inside wasm, on wasmtime and V8.
verify-wasi33-catches:
    @verification/test_wasi_sdk_33_catches_inside_wasm.sh

# barretenberg.wasm and ecc_tests, built and RUN with each toolchain and compared.
verify-wasi33-targets:
    @verification/verify_wasi_33_existing_wasm_targets_unchanged.sh

# No native compile command moves: 1009 translation units, byte-identical before and after.
verify-wasi33-native-neutral:
    @verification/verify_wasi_33_native_builds_unaffected.sh

# The contribution's own verify.sh discriminates, and rejects four mutations by name.
verify-wasi33-reproduce:
    @verification/reproduce_aztec_wasi_sdk_33_exceptions.sh

# Run the whole M4 verification set; every check runs even if an earlier one fails.
verify-m4:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      test_wasi_sdk_27_cannot_link_exceptions \
      test_wasi_sdk_33_catches_inside_wasm \
      verify_wasi_33_existing_wasm_targets_unchanged \
      verify_wasi_33_native_builds_unaffected \
      reproduce_aztec_wasi_sdk_33_exceptions
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m4: FAILED" >&2
    else
      echo "verify-m4: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M5 — the prepared upstream patch widening before the shift in the public
# bytecode commitment
# ---------------------------------------------------------------------------

# Upstream's own commitment function, built and run from an unpatched and a patched tree.
verify-bytecode-64bit:
    @verification/test_bytecode_commitment_identical_on_64bit.sh

# The two expressions in barretenberg's own uint256_t, run on x86_64 and on wasm32.
verify-bytecode-32bit:
    @verification/test_bytecode_commitment_correct_on_32bit.sh

# -Wshift-count-overflow on the real file, and the 249-TU scan behind "the only place in vm2".
verify-shift-diagnostic:
    @verification/test_shift_count_overflow_diagnostic.sh

# The contribution's shape, its write-up's numbers, and its own verify.sh under five mutations.
verify-bytecode-shift-repro:
    @verification/reproduce_aztec_bytecode_size_shift_32bit.sh

# Run the whole M5 verification set; every check runs even if an earlier one fails.
verify-m5:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      test_bytecode_commitment_identical_on_64bit \
      test_bytecode_commitment_correct_on_32bit \
      test_shift_count_overflow_diagnostic \
      reproduce_aztec_bytecode_size_shift_32bit
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m5: FAILED" >&2
    else
      echo "verify-m5: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M6 — the AVM_WASM build: vm2_sim and world_state_reference for wasm32-wasip1
# ---------------------------------------------------------------------------

# The reproducible entry point: build the AVM and its in-memory world state for wasm.
build-avm-wasm *TARGETS:
    @verification/build_avm_wasm.sh {{TARGETS}}

# cmake --preset wasm-avm && ninja, from the M0 shell, with the -Werror claim measured.
verify-avm-wasm-build:
    @verification/verify_avm_wasm_build.sh

# The preset follows the shell's WASI_SDK_PREFIX, proven against a tree that hardcodes it.
verify-avm-wasm-prefix:
    @verification/verify_avm_wasm_preset_uses_ambient_wasi_prefix.sh

# Default OFF: identical wasm build and a byte-identical barretenberg.wasm, and what ON adds.
verify-avm-wasm-default-off:
    @verification/verify_avm_wasm_default_off.sh

# wasi-sdk 27 stops at configure naming 33.0; removing only the FATAL_ERROR lets it through.
verify-avm-wasm-gate:
    @verification/test_wasm_exceptions_configure_gate.sh

# vm2_sim's link closure, two ways, with the proving stack present in the same tree.
verify-avm-wasm-closure:
    @verification/verify_wasm_link_closure_excludes_proving.sh

# vm2/simulation/** differs by three named files, and no throw or catch line moves.
verify-avm-wasm-interpreter:
    @verification/verify_no_interpreter_source_change.sh

# No header-only crypto_merkle_tree, no stray lmdb.h, no -Wno-error — against the spike.
verify-avm-wasm-no-hack:
    @verification/verify_wasm_build_uses_module_split_not_hack.sh

# Run the whole M6 verification set; every check runs even if an earlier one fails.
verify-m6:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_avm_wasm_build \
      verify_avm_wasm_preset_uses_ambient_wasi_prefix \
      verify_avm_wasm_default_off \
      test_wasm_exceptions_configure_gate \
      verify_wasm_link_closure_excludes_proving \
      verify_no_interpreter_source_change \
      verify_wasm_build_uses_module_split_not_hack
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m6: FAILED" >&2
    else
      echo "verify-m6: all checks passed"
    fi
    exit "$rc"
