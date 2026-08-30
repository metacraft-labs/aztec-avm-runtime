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
# the patch applied — under $M3_WORK (default $HOME/.cache/aztec-m3-merkle-lmdb).
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
# $HOME/.cache/aztec-m4-wasi-sdk-33): the `wasm` preset with wasi-sdk 27 and with 33,
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
# $HOME/.cache/aztec-m5-bytecode-shift) and build vm2_sim in each: the base commit, the
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
# $HOME/.cache/aztec-m6-avm-wasm), each differing only by which prepared patches are
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
# The M11 verification set (patch submission and the downstream carry). It builds
# nothing and needs no work directory beyond a checkout, but it DOES need network:
# it fetches upstream, fetches our fork, and runs each contribution's tracker
# search through `gh`. A search that cannot run fails the check rather than being
# reported as "no prior art found".
#
#   just verify-carry-set          verify_carry_set_complete                     (~5 s)
#   just verify-pr-branches        verify_pr_branches_match_patches              (~2 min)
#   just verify-carry-applies      verify_carry_set_applies_to_upstream_head     (~1 min)
#   just verify-carry-ledger       verify_carry_ledger_complete                  (~5 s)
#   just verify-carry-drop         verify_accepted_patches_dropped_from_carry    (~30 s)
#   just verify-carry-exposure     verify_carry_exposure_measured                (~30 s)
#   just verify-submission-manual  verify_submission_is_a_manual_step            (~3 min)
#   just verify-m11                all seven, in order
#
# M11's working tools:
#
#   just carry-report              the order and the dependency structure
#   just make-fork-branches        rebuild the per-PR and `codetracer` branches
#   just make-fork-branches-push   and push them to OUR fork
#   just rebase-upstream-patches   replay the carry set onto a fresh upstream fetch
#   just carry-exposure            re-measure what the whole set costs if nothing lands
#   just carry-ledger              re-render CARRY-LEDGER.md from the data
#   just record-submission ...     record an upstream outcome in all three places
#
# The M12 verification set (the standalone `avm.wasm` reactor and its host ABI). It
# prepares ONE worktree of 233d8e0993 under $M12_WORK (default
# ~/.cache/aztec-m12-reactor) carrying NINE patches — the four AVM_WASM series
# patches, the prepared observation hook, and M7's, M8's, M9's and M12's overlays —
# and builds TWO trees inside it: the wasm-avm one (which produces `avm.wasm`, its
# unpruned control, the msgpack enumeration, the differential driver, upstream's own
# `vm2_sim_tests` and `barretenberg.wasm` for the size comparison) and a native one
# (the driver whose transcript the reactor is compared against, and the same
# enumeration for x86-64). Measured from empty on 32 cores: about 8 minutes and 1.2 GB
# — with a WARM ccache, so it is a warm figure and not a from-nothing one.
# 585 assertions, 6/6, reproduced from an empty $M12_WORK at a path it had never been
# built in — which is a stronger claim than it sounds, and one an earlier version of
# the size check could not have made.
#
#   just verify-reactor-imports    verify_avm_wasm_import_surface          (the check that BUILDS)
#   just verify-reactor-size       verify_avm_wasm_size_budget
#   just verify-reactor-msgpack    verify_host_abi_reuses_upstream_msgpack
#   just verify-reactor-alloc      test_avm_reactor_alloc_free_roundtrip
#   just verify-reactor-steps      test_avm_reactor_step_stream_batching   (times; needs an idle box)
#   just verify-reactor-transcripts test_avm_reactor_transcripts_match_driver
#   just verify-m12                all six, in order
#
# COVERAGE, because this milestone's numbers must never be quoted as another's: the
# transcript half is the SAME SEVEN corpus programs M8 compares, driven this time
# THROUGH the reactor's msgpack ABI from JavaScript. That is an integration check
# across a boundary, not a breadth claim (M7's 391 upstream tests) and not a semantic
# one (M19's 77-comparison oracle). The step half re-checks `burn`'s 38,903 records,
# which is M9's number and is quoted from there.
#
# `test_avm_reactor_step_stream_batching` TIMES two call patterns and therefore
# asserts its own precondition: it waits for the machine to go idle and exits 3 — a
# code of its own, distinct from 1 for a failed assertion — rather than reporting a
# number measured beside somebody else's build.

# NOTHING in this Justfile files anything upstream. The five `submit/pr<N>-*.sh`
# scripts do that, one pull request each, and a person runs them.
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

# ---------------------------------------------------------------------------
# M7 — upstream's own vm2 test suite under wasm
# ---------------------------------------------------------------------------
# The six checks prepare ONE worktree of 233d8e0993 under $M7_WORK (default
# $HOME/.cache/aztec-m7-vm2-tests) carrying the four AVM_WASM series patches plus M7's
# own AVM_SIM_TESTS overlay (verification/m7/), and build TWO trees inside it:
# the wasm-avm one, and a native one that also builds upstream's OWN vm2_tests —
# the binary with the proving stack and dsl in it. That native binary is the
# denominator: without it the wasm pass rate would be quoted against a suite we
# chose the size of. Budget about 12 GB under $M7_WORK; /tmp is usually a tmpfs
# and is the wrong place.
#
#   just verify-vm2-tests-build         verify_vm2_tests_build_for_wasm              (~25 min cold)
#   just verify-vm2-tests-v8            verify_vm2_tests_pass_under_v8               (~6 min)
#   just verify-vm2-tests-wasmtime      verify_vm2_tests_pass_under_wasmtime         (~2 min)
#   just verify-vm2-tests-parity        verify_vm2_tests_native_wasm_per_test_parity (~1 min)
#   just verify-vm2-tests-exclusions    verify_vm2_tests_exclusions_enumerated       (~1 min)
#   just verify-vm2-tests-world-state   verify_world_state_reference_tests_pass_under_wasm (~2 min)
#   just verify-m7                      all six, in order

# vm2_sim's own test binary compiles and links for wasm32-wasip1, and the narrowings are measured.
verify-vm2-tests-build:
    @verification/verify_vm2_tests_build_for_wasm.sh

# The shipped wasm binary runs on V8, with the two corrections that make it possible as controls.
verify-vm2-tests-v8:
    @verification/verify_vm2_tests_pass_under_v8.sh

# The same suite on wasmtime, with the memory import satisfied statically.
verify-vm2-tests-wasmtime:
    @verification/verify_vm2_tests_pass_under_wasmtime.sh

# Native versus wasm, per test rather than by count, inside upstream's own suite.
verify-vm2-tests-parity:
    @verification/verify_vm2_tests_native_wasm_per_test_parity.sh

# Every excluded test named with a reason derived from the tree, and the partition asserted.
verify-vm2-tests-exclusions:
    @verification/verify_vm2_tests_exclusions_enumerated.sh

# The in-memory world state and the standalone gadgets, and what is linked but not exercised.
verify-vm2-tests-world-state:
    @verification/verify_world_state_reference_tests_pass_under_wasm.sh

# Run the whole M7 verification set; every check runs even if an earlier one fails.
verify-m7:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_vm2_tests_build_for_wasm \
      verify_vm2_tests_pass_under_v8 \
      verify_vm2_tests_pass_under_wasmtime \
      verify_vm2_tests_native_wasm_per_test_parity \
      verify_vm2_tests_exclusions_enumerated \
      verify_world_state_reference_tests_pass_under_wasm
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m7: FAILED" >&2
    else
      echo "verify-m7: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# M19 — the three-way differential: wasm AVM vs native C++ AVM vs TypeScript
# ---------------------------------------------------------------------------
#
# THE HEADLINE IS THE COMPARISON COUNT, NOT THE TEST COUNT, and that is the milestone's own
# deliverable rather than a preference. 758 passing tests in this corpus contain 74 differential
# comparisons; the difference was quoted the wrong way round once already (DRIFT.md D2, D7).
#
#   just report-comparisons          THE HEADLINE: transactions, then pairs, then tests
#   just version-gap                 DD-12: how far behind the C++ oracle is, as numbers
#   just three-way                   run the arm alone (needs AVM_WASM_PATH)
#   just measure-three-way           re-measure the counts and the divergence ledger
#   just verify-m19                  all of M19's checks, in order
#
# AVM_WASM_PATH is a build output (M6). The checks find one in a sibling milestone's work
# directory if it is there and die with the build command if it is not; they never run two-way
# and call it three-way.
report-comparisons:
    @python3 tools/report_comparisons.py

version-gap:
    @python3 tools/version_gap.py

three-way:
    @cd diffsim && RUN_THREE_WAY=1 NODE_NO_WARNINGS=1 node --experimental-vm-modules ./node_modules/.bin/jest src/differential

measure-three-way:
    @python3 tools/measure_three_way.py

verify-three-way:
    @verification/e2e_differential_wasm_vs_native_cpp.sh

verify-m19:
    #!/usr/bin/env bash
    set -uo pipefail
    failed=0
    for check in \
      e2e_differential_wasm_vs_native_cpp \
      e2e_differential_wasm_vs_ts_interpreter \
      verify_differential_comparison_count_reported \
      verify_differential_containment \
      verify_oracle_version_gap_reported \
      test_bitwise_dyn_gas_divergence_detected \
      verify_differential_job_separate_failure_domain ; do
      echo "=== $check ==="
      verification/$check.sh || failed=1
    done
    if [ "$failed" -ne 0 ]; then
      echo "verify-m19: FAILED" >&2
      exit 1
    fi
    echo "verify-m19: all checks passed"

# M8 — the native-versus-wasm differential, including tree roots
# ---------------------------------------------------------------------------
# The seven checks prepare ONE worktree of 233d8e0993 under $M8_WORK (default
# ~/.cache/aztec-m8-differential) carrying SIX patches — the four AVM_WASM series
# patches, M7's AVM_SIM_TESTS overlay and M8's own AVM_DIFFERENTIAL overlay
# (verification/m8/) — and build TWO trees inside it: the wasm-avm one and a
# native one. Both build the SAME differential driver from the SAME translation
# unit; the native one also builds upstream's own world_state_tests, which
# carries the seven MemoryMerkleDBEquivalenceTest cases that are the standing
# reference-versus-real fidelity gate. Measured cold from an empty $M8_WORK on 32
# cores: 4 min 42 s and 792 MB — `ninja avm_differential` builds only the driver's
# own dependency subgraph (131 objects), not all 580 translation units the wasm
# configure declares. /tmp is usually a tmpfs and is the wrong place.
#
# COVERAGE, because this milestone's own deliverable requires the number to be
# quoted with it: the program half is SEVEN hand-assembled corpus programs,
# compared field for field. That is an integration check across two targets and
# NOT a breadth claim — breadth is M7's 391 upstream tests and semantics is M19's
# 77-comparison oracle. Each of the three states its own coverage so none can be
# quoted as another.
#
#   just avm-differential            build both, diff, exit non-zero on divergence
#   just verify-tree-roots           verify_tree_roots_identical_native_wasm       (the check that BUILDS)
#   just verify-roots-vs-world-state test_tree_roots_match_real_world_state
#   just verify-world-state-gate     verify_upstream_world_state_reference_gate_green
#   just verify-transcripts          verify_native_wasm_transcripts_identical
#   just verify-revert-no-trap       test_revert_program_does_not_trap_module
#   just verify-differential-exit    verify_avm_differential_exit_status           (runs the gate 8x)
#   just verify-peak-memory          verify_wasm_peak_memory_budget
#   just verify-m8                   all seven, in order — 510 assertions, ~5 min cold

# AVM_DIFF_INJECT=root|diag|same|swap|truncate injects a deliberate divergence,
# for the checks that measure this gate's own discriminating power.
#
# Build both targets, diff the transcripts, and exit non-zero on any divergence.
avm-differential:
    @verification/run_avm_differential.sh

# Every tree root and size, identical native versus wasm, per line and never by count.
verify-tree-roots:
    @verification/verify_tree_roots_identical_native_wasm.sh

# The roots the wasm module produces, against Tier D's vectors from the REAL WorldState.
verify-roots-vs-world-state:
    @verification/test_tree_roots_match_real_world_state.sh

# Upstream's own reference-versus-real fidelity gate, run at the pinned commit.
verify-world-state-gate:
    @verification/verify_upstream_world_state_reference_gate_green.sh

# Every non-diagnostic line identical on two runtimes, with the diagnostics enumerated.
verify-transcripts:
    @verification/verify_native_wasm_transcripts_identical.sh

# revertCode 1 rather than a trapped instance: the throw/catch path inside wasm.
verify-revert-no-trap:
    @verification/test_revert_program_does_not_trap_module.sh

# `just avm-differential` exits 0 clean and non-zero on each of five injected divergences.
verify-differential-exit:
    @verification/verify_avm_differential_exit_status.sh

# Peak linear memory reported from inside the module, against a recorded budget.
verify-peak-memory:
    @verification/verify_wasm_peak_memory_budget.sh

# Run the whole M8 verification set; every check runs even if an earlier one fails.
verify-m8:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_tree_roots_identical_native_wasm \
      test_tree_roots_match_real_world_state \
      verify_upstream_world_state_reference_gate_green \
      verify_native_wasm_transcripts_identical \
      test_revert_program_does_not_trap_module \
      verify_avm_differential_exit_status \
      verify_wasm_peak_memory_budget
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m8: FAILED" >&2
    else
      echo "verify-m8: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M9 — the per-instruction execution observer, and its upstream patch
# ---------------------------------------------------------------------------
# The seven checks prepare FIVE worktrees of 233d8e0993 under $M9_WORK (default
# ~/.cache/aztec-m9-observer):
#
#   m9         the four AVM_WASM series patches + THE OBSERVER PATCH + M7's
#              AVM_SIM_TESTS overlay + M8's AVM_DIFFERENTIAL overlay + M9's driver
#              overlay. Built for x86-64 AND wasm32-wasip1.
#   m9ref      the same MINUS the observer patch — the unpatched half of the
#              disabled-costs-nothing comparison. The driver source is byte-identical
#              in both: it selects the API with __has_include.
#   m9nohoist  m9 plus ONE commit moving the observer call back inside the try block.
#              The control: burn then records 38,902 of its 38,903 instructions and
#              oob 2 of its 3, while every program that halts normally is unaffected.
#   m9up       233d8e0993 + THE OBSERVER PATCH ALONE. Upstream's own `default` preset
#              and upstream's own vm2_tests target, nothing of ours anywhere.
#   m9upbase   pristine 233d8e0993, the same target, as the before side.
#
# Budget about 20 GB and 45 minutes cold, of which upstream's own native vm2_tests
# (264 MB, and the whole proving stack behind it) built TWICE is most of both.
# Fourteen of those tests need the bn254 CRS: run barretenberg/crs/bootstrap.sh once.
# The work directory defaults under $HOME/.cache and lib.sh's require_work_dir refuses
# to start a build in one that cannot hold it: /tmp is usually a small tmpfs, and a
# quota exhausted mid-build otherwise reports itself as dozens of unrelated failed
# assertions rather than as one precondition.
#
# COVERAGE, because this milestone's numbers must never be quoted as another's: the
# step-record comparison is EIGHT hand-assembled programs — M8's seven plus `oob` —
# compared PER RECORD, 39,086 records carrying context id, pc, opcode, cumulative l2
# and da gas and the contract address. That is an integration check across two targets
# plus an agreement with upstream's own ExecutionEvent seam. It is NOT a breadth claim
# (M7's 391 upstream tests) and NOT a semantic one (M19's 77-comparison oracle).
#
#   just verify-step-records     verify_observation_hook_step_records_identical  (the check that BUILDS)
#   just verify-no-perturbation  test_observer_does_not_perturb
#   just verify-exceptional-halt test_observer_fires_on_exceptional_halt         (builds the control)
#   just verify-overhead         verify_observation_hook_overhead_budget
#   just verify-disabled-free    test_observer_disabled_is_free                  (builds the reference tree)
#   just verify-event-fallback   test_existing_event_emitter_path_still_available
#   just verify-observer-patch   verify_execution_observer_patch_applies_to_upstream (builds vm2_tests twice)
#   just verify-m9               all seven, in order

# Step records, per record, native versus wasm on two runtimes.
verify-step-records:
    @verification/verify_observation_hook_step_records_identical.sh

# The same simulation result with and without an observer attached.
verify-no-perturbation:
    @verification/test_observer_does_not_perturb.sh

# The instruction that throws is the LAST recorded step, not a missing one.
verify-exceptional-halt:
    @verification/test_observer_fires_on_exceptional_halt.sh

# Traced versus untraced with all 38,903 records materialised, per target.
verify-overhead:
    @verification/verify_observation_hook_overhead_budget.sh

# Patched versus unpatched with the flag off, against a measured noise floor.
verify-disabled-free:
    @verification/test_observer_disabled_is_free.sh

# The no-patch fallback, run rather than assumed, and compared record for record.
verify-event-fallback:
    @verification/test_existing_event_emitter_path_still_available.sh

# The prepared patch on the pinned anchor, and upstream's own vm2_tests on both sides.
verify-observer-patch:
    @verification/verify_execution_observer_patch_applies_to_upstream.sh

# Run the whole M9 verification set; every check runs even if an earlier one fails.
verify-m9:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    precond=0
    for check in \
      verify_observation_hook_step_records_identical \
      test_observer_does_not_perturb \
      test_observer_fires_on_exceptional_halt \
      verify_observation_hook_overhead_budget \
      test_observer_disabled_is_free \
      test_existing_event_emitter_path_still_available \
      verify_execution_observer_patch_applies_to_upstream
    do
      echo "=== $check"
      verification/"$check".sh
      st=$?
      case "$st" in
        0) ;;
        # M9's checks spend 3 and 4 on PRECONDITIONS — the machine was too busy to time on, or
        # the interval it managed is inside the budget and still too wide to claim at the session
        # cap. Neither is a milestone regression and neither is a pass, so they are reported
        # under their own name and the target still exits non-zero. Collapsing them into 1 is
        # what made M14's sweep read a measurement threshold as a red.
        3|4) echo "verify-m9: $check exited $st — a measurement PRECONDITION, not a failure" >&2
             precond=1 ;;
        *) rc=1 ;;
      esac
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m9: FAILED" >&2
      exit 1
    elif [ "${precond:-0}" -ne 0 ]; then
      echo "verify-m9: PRECONDITION UNMET — no check failed, and at least one could not measure" >&2
      exit 4
    else
      echo "verify-m9: all checks passed"
    fi
    exit 0

# ---------------------------------------------------------------------------
# M10 — the AVM-module / server-module CMake split, and the AVM_WASM flag.
# ---------------------------------------------------------------------------

# With AVM_WASM off nothing moves: the guard exhaustively, two presets concretely,
# and upstream's own vm2_tests and world_state_tests run on both sides.
verify-cmake-split-neutral:
    @verification/verify_cmake_split_native_neutral.sh

# What the FUZZING_AVM block really demonstrates, and the fuzzing presets unchanged.
verify-cmake-split-fuzzing:
    @verification/verify_cmake_split_fuzzing_preset_unchanged.sh

# AVM_WASM on: the AVM group builds for wasm and no server module is reachable.
verify-cmake-split-wasm-avm:
    @verification/verify_cmake_split_enables_wasm_avm.sh

# The patch applies to the stated base; which prerequisite is an apply one and which a build one.
verify-cmake-split-patch-applies:
    @verification/verify_avm_wasm_module_split_patch_applies.sh

# Run the whole M10 verification set; every check runs even if an earlier one fails.
verify-m10:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_cmake_split_native_neutral \
      verify_cmake_split_fuzzing_preset_unchanged \
      verify_cmake_split_enables_wasm_avm \
      verify_avm_wasm_module_split_patch_applies
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m10: FAILED" >&2
    else
      echo "verify-m10: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M11 — patch submission and the downstream carry.
#
# NOTHING HERE FILES ANYTHING UPSTREAM. Submission is a person's decision and a
# person's command: `submit/pr<N>-*.sh`, one per pull request, run by hand. The
# recipes below build the branches those scripts file from, keep the carry set
# applicable as upstream moves, and hold the ledger to the data.
# ---------------------------------------------------------------------------

# Rebuild the five per-PR branches and the `codetracer` development branch in the fork.
make-fork-branches:
    @python3 tools/make_fork_branches.py --work "${M11_WORK:-$HOME/.cache/aztec-m11-branches}"

# The same, and push them to our fork. Never pushes anywhere but metacraft-labs.
make-fork-branches-push:
    @python3 tools/make_fork_branches.py --work "${M11_WORK:-$HOME/.cache/aztec-m11-branches}" --push

# Print the carry set's order and dependency structure without building anything.
carry-report:
    @python3 tools/make_fork_branches.py --report

# Replay the carry set onto a fresh upstream fetch; non-zero if any patch stops applying.
# The replay CHECKS OUT the whole upstream tree (451 MB), so it takes a work directory
# under ~/.cache like every other multi-hundred-megabyte step. It used to land in
# `tempfile.mkdtemp()`'s default and died there with ENOSPC on a tmpfs /tmp.
rebase-upstream-patches:
    @python3 tools/rebase_upstream_patches.py --json carry/rebase.json \
        --work "${M11_WORK:-$HOME/.cache/aztec-m11-rebase}"

# Re-measure what the whole set costs if upstream accepts none of it.
carry-exposure:
    @python3 tools/measure_carry_exposure.py

# Re-render CARRY-LEDGER.md from carry/series.json, carry/exposure.json and carry/rebase.json.
carry-ledger:
    @python3 tools/render_carry_ledger.py

# Record an upstream outcome: `just record-submission p1 submitted https://.../pull/123`.
record-submission id status url:
    @python3 tools/record_submission.py --id {{id}} --status {{status}} --url {{url}}

# The carry set is complete and traceable to upstream-bugs/, three copies of each title agree.
verify-carry-set:
    @verification/verify_carry_set_complete.sh

# Every per-PR branch is byte for byte what its patch file produces, locally and as published.
verify-pr-branches:
    @verification/verify_pr_branches_match_patches.sh

# The whole set still applies to upstream HEAD, and M6/M10's build evidence still transfers.
verify-carry-applies:
    @verification/verify_carry_set_applies_to_upstream_head.sh

# The ledger is what the data renders to, and every entry is complete for its status.
verify-carry-ledger:
    @verification/verify_carry_ledger_complete.sh

# An accepted patch drops out of the carry set; positive and negative controls.
verify-carry-drop:
    @verification/verify_accepted_patches_dropped_from_carry.sh

# The exposure is measured rather than estimated, and the spike's estimate is corrected.
verify-carry-exposure:
    @verification/verify_carry_exposure_measured.sh

# Filing is a manual step, and nothing else in this repository can file.
verify-submission-manual:
    @verification/verify_submission_is_a_manual_step.sh

# Run the whole M11 verification set; every check runs even if an earlier one fails.
verify-m11:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_carry_set_complete \
      verify_pr_branches_match_patches \
      verify_carry_set_applies_to_upstream_head \
      verify_carry_ledger_complete \
      verify_accepted_patches_dropped_from_carry \
      verify_carry_exposure_measured \
      verify_submission_is_a_manual_step
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m11: FAILED" >&2
    else
      echo "verify-m11: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M12 — the standalone avm.wasm reactor and its host ABI.
# ---------------------------------------------------------------------------

# Eleven WASI imports plus env.memory, thirty-nine exports, and the two link-option controls beside them.
verify-reactor-imports:
    @verification/verify_avm_wasm_import_surface.sh

# The stripped module against a budget BOTH controls fail, and -Oz, exports, gc-sections and strip apart.
verify-reactor-size:
    @verification/verify_avm_wasm_size_budget.sh

# Forty-two crossed types round-tripped on both targets; the one that is ours, with its reason.
verify-reactor-msgpack:
    @verification/verify_host_abi_reuses_upstream_msgpack.sh

# Thirteen sizes round-tripped, and thirty-two simulations through one instance.
verify-reactor-alloc:
    @verification/test_avm_reactor_alloc_free_roundtrip.sh

# ceil(38903 / B) crossings at four batch sizes, and the per-event shape measured rather than assumed.
verify-reactor-steps:
    @verification/test_avm_reactor_step_stream_batching.sh

# The seven corpus programs through the msgpack ABI on V8, against the native driver, roots included.
verify-reactor-transcripts:
    @verification/test_avm_reactor_transcripts_match_driver.sh

# It lives in M12's set because a stale ~/.cache/aztec-m12-reactor is what made it necessary,
# but m6_prepare_tree — the function it guards — is where every milestone from M6 on gets its
# trees, and SEVEN of the campaign's default work trees were stale when this was written.
#
# A prepared work tree is reused only if its ORDERED patch-ids equal the patch files'.
verify-tree-freshness:
    @verification/test_prepared_tree_rejects_stale_inputs.sh

# Run the whole M12 verification set; every check runs even if an earlier one fails.
verify-m12:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_avm_wasm_import_surface \
      verify_avm_wasm_size_budget \
      verify_host_abi_reuses_upstream_msgpack \
      test_avm_reactor_alloc_free_roundtrip \
      test_avm_reactor_step_stream_batching \
      test_avm_reactor_transcripts_match_driver \
      test_prepared_tree_rejects_stale_inputs
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m12: FAILED" >&2
    else
      echo "verify-m12: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M13 — the shippable contract DB and checkpoint coordination.
#
# ONE worktree of 233d8e0993 under $M13_WORK (default ~/.cache/aztec-m13-contractdb)
# carrying TEN patches: M12's nine plus M13's own overlay. Two builds inside it, the
# same two M12 makes.
#
# M13's tree is NOT M12's, on purpose: the overlay takes the export list from
# thirty-nine names to forty-nine, and `verify_avm_wasm_import_surface` holds M12's
# artefact to thirty-nine as an identity — correctly, since an export appearing is as
# much a finding as one disappearing. Both milestones build their own tree in their own
# work directory and both are re-run in the sweep, which is the only way "additive"
# means anything.
#
#   just verify-contract-db-decision  verify_contract_db_reuse_decision_recorded  (the check that BUILDS)
#   just verify-contract-db-methods   test_contract_db_eight_methods_covered
#   just verify-checkpoint-lockstep   test_checkpoint_lockstep_contract_and_merkle
#   just verify-checkpoint-depth      test_checkpoint_depth_balanced_after_nested_reverts
#   just verify-debug-function-name   test_debug_function_name_from_upstream_db
#   just verify-deploy-roundtrip      e2e_deploy_call_revert_roundtrip
#   just verify-m13                   all six, in order
# ---------------------------------------------------------------------------

# Eight ContractDBInterface implementations enumerated from the fork, three dispositions, one taken.
verify-contract-db-decision:
    @verification/verify_contract_db_reuse_decision_recorded.sh

# All eight methods against all seven corpus contracts, each getter with a registered and an absent argument.
verify-contract-db-methods:
    @verification/test_contract_db_eight_methods_covered.sh

# The coordinator, an injected desynchronisation, and the wrong state a naive owner produces from it.
verify-checkpoint-lockstep:
    @verification/test_checkpoint_lockstep_contract_and_merkle.sh

# Every corpus program through the coordinator; both stacks back where they started, roots restored.
verify-checkpoint-depth:
    @verification/test_checkpoint_depth_balanced_after_nested_reverts.sh

# Artifact names in, artifact names out, and the same name on the AVM's own frame label.
verify-debug-function-name:
    @verification/test_debug_function_name_from_upstream_db.sh

# A contract deployed DURING execution: kept when the tx succeeds, gone when it reverts, roots with it.
verify-deploy-roundtrip:
    @verification/e2e_deploy_call_revert_roundtrip.sh

# Run the whole M13 verification set; every check runs even if an earlier one fails.
verify-m13:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_contract_db_reuse_decision_recorded \
      test_contract_db_eight_methods_covered \
      test_checkpoint_lockstep_contract_and_merkle \
      test_checkpoint_depth_balanced_after_nested_reverts \
      test_debug_function_name_from_upstream_db \
      e2e_deploy_call_revert_roundtrip
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m13: FAILED" >&2
    else
      echo "verify-m13: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M14 — block-level world-state coverage, and the compiler cache that made the
# regression sweep runnable again.
#
# TWO worktrees of 233d8e0993 under $M14_WORK (default ~/.cache/aztec-m14-archive):
# the pristine anchor, and the anchor plus M14's one patch. Upstream's own
# `default` preset and upstream's own targets in each — `world_state_tests`,
# which drives the real lmdb-backed WorldState and the in-memory reference side
# by side, and `vm2_tests`, the 1,803-test neutrality denominator.
#
#   just verify-block-level-audit    verify_block_level_gap_audit_complete   (the check that BUILDS)
#   just verify-archive-absence      test_archive_tree_absence_confirmed
#   just verify-genesis-versus-world-state
#                                    test_reference_genesis_roots_versus_real_world_state
#   just verify-archive-roots        test_archive_tree_roots_match_real_world_state
#   just verify-archive-checkpoints  test_archive_tree_participates_in_checkpoints
#   just verify-block-zero-read      test_historical_block_zero_read_returns_genesis
#   just verify-world-state-neutral  verify_world_state_reference_extension_native_neutral
#   just verify-compiler-cache       verify_compiler_cache_effective
#   just verify-m14                  all eight, in order
#
# The audit is the only one that builds. It writes $M14_WORK/measured.env and the
# other seven read it; if it has not run they say so and fail rather than
# building a tree of their own, because the neutrality control in
# verify-compiler-cache needs the SAME pair of trees every other check measured.
#
# THE COMPILER CACHE IS NOT DECORATION AND NOT M14's SUBJECT — it is the reason
# this milestone's regression sweep can be run at all. `pkgs.ccache` was in the
# fork's shell from M0 and nothing invoked it; both shells now export
# CMAKE_C_COMPILER_LAUNCHER, CMAKE_CXX_COMPILER_LAUNCHER, CCACHE_DIR,
# CCACHE_BASEDIR, CCACHE_MAXSIZE and CCACHE_COMPILERCHECK. Measured on 32 cores
# on upstream's own `vm2_tests`, build directory DELETED between the two passes so
# what is measured is the cache and not ninja: 327 s cold with 639 misses and
# 0 hits, 9 s warm with 639 direct hits and 0 misses, and the same sha256 out of
# both. verify-compiler-cache re-measures that on a smaller target (eighteen
# translation units, seconds rather than minutes) and asserts, separately, that
# the cache CANNOT make two different trees look identical: M14's own two trees
# built from different absolute paths against one warm cache give exactly ONE
# miss — the number of changed translation units — with the CHANGED object
# differing by digest and an UNTOUCHED one byte-identical across the trees.
#
# `just verify-m14` measured 459 assertions, 8/8, exit 0, per check
# 130 / 31 / 59 / 53 / 31 / 37 / 59 / 59. The two vm2_tests runs in
# verify-world-state-neutral are the long pole at about 6 minutes each; the whole
# set is about 25 minutes against a warm cache.
# ---------------------------------------------------------------------------

# The audit: five implementations enumerated over the whole fork, thirteen operations classified.
verify-block-level-audit:
    @verification/verify_block_level_gap_audit_complete.sh

# The archive's absence at the anchor, by execution rather than by reading a header.
verify-archive-absence:
    @verification/test_archive_tree_absence_confirmed.sh

# Genesis: the reference, upstream's own constants, and Tier D's production capture.
verify-genesis-versus-world-state:
    @verification/test_reference_genesis_roots_versus_real_world_state.sh

# Archive roots after a sequence of block-header appends, against the real WorldState.
verify-archive-roots:
    @verification/test_archive_tree_roots_match_real_world_state.sh

# Create, revert and commit: the archive comes back and stays with the other four.
verify-archive-checkpoints:
    @verification/test_archive_tree_participates_in_checkpoints.sh

# Block-pinned reads: not needed, and the sentinel executed rather than read.
verify-block-zero-read:
    @verification/test_historical_block_zero_read_returns_genesis.sh

# Upstream's own vm2_tests and world_state_tests, same names and same results.
verify-world-state-neutral:
    @verification/verify_world_state_reference_extension_native_neutral.sh

# The cache fires, and it cannot mask a base-versus-patched or a toolchain difference.
verify-compiler-cache:
    @verification/verify_compiler_cache_effective.sh

# Run the whole M14 verification set; every check runs even if an earlier one fails.
verify-m14:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_block_level_gap_audit_complete \
      test_archive_tree_absence_confirmed \
      test_reference_genesis_roots_versus_real_world_state \
      test_archive_tree_roots_match_real_world_state \
      test_archive_tree_participates_in_checkpoints \
      test_historical_block_zero_read_returns_genesis \
      verify_world_state_reference_extension_native_neutral \
      verify_compiler_cache_effective
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m14: FAILED" >&2
    else
      echo "verify-m14: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M15 — the integration shape across the wasm boundary, and the cost of the
# reference world state's own checkpoints.
#
# ONE worktree of 233d8e0993 under $M15_WORK (default ~/.cache/aztec-m15-shapes)
# carrying M13's TEN patches — M15 adds no eleventh, because the module M12 built
# and M13 completed already contains BOTH candidate entry points and M12's own ABI
# write-up recorded that "the choice between them is M15's". Plus the two
# world-state trees the checkpoint characterisation needs, four trees and five,
# prepared by M14's recipe inside M15's own work directory rather than read out of
# M14's.
#
# A fully fused chatty arm — the two host interfaces over an imported callback — is
# PREPARED under verification/m15/ and is not measured; BOUNDARY-SHAPE.md says so
# rather than leaving it an unstated gap.
#
#   just verify-shapes-identical   test_integration_shape_results_identical
#   just verify-crossing-budget    verify_boundary_crossing_budget
#   just verify-checkpoint-cost    test_checkpoint_cost_characterised
#   just verify-shape-wall-time    test_representative_transaction_wall_time
#   just verify-msgpack-cost       test_msgpack_encode_decode_cost
#   just verify-snapshot-boundary  e2e_world_state_snapshot_across_boundary
#   just verify-m15                all six, in order
# ---------------------------------------------------------------------------

# The two shapes agree field for field on the corpus, so the choice is about cost.
verify-shapes-identical:
    @verification/test_integration_shape_results_identical.sh

# Eighteen to twenty-two DB crossings per transaction, counted from upstream's own hint record.
verify-crossing-budget:
    @verification/verify_boundary_crossing_budget.sh

# What the reference world state's O(state) checkpoints cost, over a decade of population.
verify-checkpoint-cost:
    @verification/test_checkpoint_cost_characterised.sh

# A representative transaction and a full block, timed end to end through both shapes.
verify-shape-wall-time:
    @verification/test_representative_transaction_wall_time.sh

# The null crossing, the transport at both payload sizes, and the decode — separately.
verify-msgpack-cost:
    @verification/test_msgpack_encode_decode_cost.sh

# Export and import, and the finding that the two shapes do not answer it equally.
verify-snapshot-boundary:
    @verification/e2e_world_state_snapshot_across_boundary.sh

# Run the whole M15 verification set; every check runs even if an earlier one fails.
verify-m15:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      test_integration_shape_results_identical \
      verify_boundary_crossing_budget \
      test_checkpoint_cost_characterised \
      test_representative_transaction_wall_time \
      test_msgpack_encode_decode_cost \
      e2e_world_state_snapshot_across_boundary
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m15: FAILED" >&2
    else
      echo "verify-m15: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M16 — the narrowed TypeScript-trees fallback: evaluated, priced, and NOT taken.
#
# THIS MILESTONE BUILDS NOTHING AND TAKES NO WORK DIRECTORY. Its three triggers are
# conjunctions and none of them fires, so the fallback is not executed — but the
# milestone requires the evaluation and the price to be RECORDED either way, so a
# future reader who has to reopen the question does not redo the analysis.
#
# What the two checks measure rather than quote:
#
#   * the price, out of @aztec/merkle-tree@5.0.0-nightly.20260316 as installed under
#     probe-mt/node_modules/ — the last published nightly that ships the package at
#     all, carried in pins.json as a declared npm_exceptions entry for that reason;
#   * the hazard, twice over: the undomained root asked of the PACKAGE's own
#     StandardTree, and the native one produced by the domain-separated recurrence
#     with the separator read out of @aztec/constants and checked against two
#     independent Tier D witnesses and against the fork's own DOM_SEP__MERKLE_HASH.
#
# Where a trigger rests on a number another milestone measured, it BINDS to that
# milestone's document — BOUNDARY-SHAPE.md, WORLD-STATE.md — rather than reading a
# stale artefact out of ~/.cache. Every such figure is asserted present on BOTH
# sides, so a drift fails here instead of passing quietly.
#
#   just verify-fallback-triggers  verify_fallback_triggers_recorded_and_evaluated
#   just verify-fallback-cost      verify_fallback_cost_priced
#   just verify-m16                both, in order
#
# The other four verification entries in M16 are guarded by "If triggered" and stay
# pending: an implementation the milestone says must not be written cannot have a
# passing test, and a check that reported one would be the failure this campaign
# keeps correcting.
# ---------------------------------------------------------------------------

# Each narrowed trigger evaluated conjunct by conjunct, with a negative case per conjunct.
verify-fallback-triggers:
    @verification/verify_fallback_triggers_recorded_and_evaluated.sh

# The switch priced out of the installed package, and the wrong-root hazard re-derived.
verify-fallback-cost:
    @verification/verify_fallback_cost_priced.sh

# Run the whole M16 verification set; every check runs even if an earlier one fails.
verify-m16:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_fallback_triggers_recorded_and_evaluated \
      verify_fallback_cost_priced
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m16: FAILED" >&2
    else
      echo "verify-m16: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M17 — the Node host: driving avm.wasm from Node.js
#
#   just verify-node-gate          verify_node_v8_accepts_module            (BUILDS)
#   just verify-node-transcripts   verify_node_transcripts_match_native
#   just verify-node-trap-revert   test_wasm_trap_vs_avm_revert_distinguished
#   just verify-node-pool          test_node_loader_instance_reuse
#   just verify-node-memory        verify_node_peak_memory_budget
#   just verify-node-reuse         verify_wasi_shim_reuse_decision_recorded
#   just verify-node-steps         test_node_step_stream_batching
#   just verify-exported-name-guard  test_large_assignment_survives_an_exported_name
#   just verify-m17                all of them, in order
#
# `verify-node-gate` is the one that BUILDS: M12's nine-patch tree inside M17's own work
# directory, plus the driver's inputs and the native reference transcript. Every other check
# runs it if there is no measurement on record — never invents, defaults or skips.
#
# `verify-exported-name-guard` is carried from M11 rather than being M17's own: an ambient
# exported `out` put 738 KB into the environment and made every later exec fail E2BIG. It builds
# nothing and takes no work directory.
# ---------------------------------------------------------------------------

# The pinned V8 compiles avm.wasm's try_table, and the guard is shown to be able to fail. BUILDS.
verify-node-gate:
    @verification/verify_node_v8_accepts_module.sh

# Seven corpus programs under Node, transcripts including tree roots, against the native reference.
verify-node-transcripts:
    @verification/verify_node_transcripts_match_native.sh

# A trap and a revert, at run time and in the type system, neither reported as the other.
verify-node-trap-revert:
    @verification/test_wasm_trap_vs_avm_revert_distinguished.sh

# One pooled instance against fresh ones: identical results, no linear-memory growth.
verify-node-pool:
    @verification/test_node_loader_instance_reuse.sh

# Peak linear memory under V8 through the node host, against a recorded budget.
verify-node-memory:
    @verification/verify_node_peak_memory_budget.sh

# Whether bb.js's WASI shim was reused, with the enumeration re-run rather than read back.
verify-node-reuse:
    @verification/verify_wasi_shim_reuse_decision_recorded.sh

# Batched step-stream decoding, and the same records by both routes.
verify-node-steps:
    @verification/test_node_step_stream_batching.sh

# A large assignment to an ambiently-exported name must still be able to exec.
verify-exported-name-guard:
    @verification/test_large_assignment_survives_an_exported_name.sh

# Run the whole M17 verification set; every check runs even if an earlier one fails.
verify-m17:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_node_v8_accepts_module \
      verify_wasi_shim_reuse_decision_recorded \
      verify_node_transcripts_match_native \
      test_wasm_trap_vs_avm_revert_distinguished \
      test_node_loader_instance_reuse \
      test_node_step_stream_batching \
      verify_node_peak_memory_budget \
      test_large_assignment_survives_an_exported_name
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m17: FAILED" >&2
    else
      echo "verify-m17: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M18 — TypeScript orchestration over the wasm interpreter
#
#   just verify-orchestration-reuse  verify_orchestration_reuse_enumerated
#   just verify-no-telemetry         verify_no_telemetry_client_in_import_graph
#   just verify-no-cpp-default       test_public_processor_never_defaults_to_cpp
#   just verify-ts-config            verify_ts_simulator_configuration_named_not_inverted
#   just verify-halves-compose       e2e_ts_wasm_result_decodes_as_upstream_types  (needs avm.wasm)
#   just verify-m18                  all of them, in order
#
# NONE OF THESE BUILDS. `verify-halves-compose` needs `avm.wasm` and M12's reactor inputs, and it
# builds them through M12's own machinery if they are not on record — it never invents, defaults
# or skips. The other four read the fork at the TypeScript anchor, the published @aztec/*
# packages and `orchestration/`, and each dies with the command that fixes it rather than
# reporting zero problems against a tree it could not read.
#
# `orchestration/` needs its packages installed: `cd orchestration && npm ci`. That is a
# precondition on state this repository does not vendor, the same one M17 recorded for diffsim.
# ---------------------------------------------------------------------------

# ForkCheckpoint and telemetry: both justifications enumerated over the whole fork, by subdirectory.
verify-orchestration-reuse:
    @verification/verify_orchestration_reuse_enumerated.sh

# The shipped import graph, walked module by module: no telemetry, no prom-client, no native addon.
verify-no-telemetry:
    @verification/verify_no_telemetry_client_in_import_graph.sh

# DD-9: no public export, and no argument, reaches the C++ AVM.
verify-no-cpp-default:
    @verification/test_public_processor_never_defaults_to_cpp.sh

# The `(TS Simulator)` inversion, re-derived upstream and fixed here as a named configuration.
verify-ts-config:
    @verification/verify_ts_simulator_configuration_named_not_inverted.sh

# The two halves together: avm.wasm's bytes read by upstream's own TypeScript types.
verify-halves-compose:
    @verification/e2e_ts_wasm_result_decodes_as_upstream_types.sh

# Type-check the orchestration package against the nix-pinned tsc.
typecheck-orchestration:
    @cd orchestration && tsc -p tsconfig.json && echo "orchestration: type-checks"

# Run the whole M18 verification set; every check runs even if an earlier one fails.
verify-m18:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_orchestration_reuse_enumerated \
      verify_no_telemetry_client_in_import_graph \
      test_public_processor_never_defaults_to_cpp \
      verify_ts_simulator_configuration_named_not_inverted \
      e2e_ts_wasm_result_decodes_as_upstream_types
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m18: FAILED" >&2
    else
      echo "verify-m18: all checks passed"
    fi
    exit "$rc"

# M20 — Form A, externally-settled transactions
# ---------------------------------------------------------------------------
# Accept a transaction whose private half ran elsewhere and execute only its public half.
#
# THE THREE-PHASE MODEL, THE GAS ACCOUNTING AND THE ASYMMETRIC REVERT MODEL ARE INSIDE `avm.wasm`.
# Upstream moved public transaction execution out of TypeScript between the two anchors:
# `PublicTxContext` no longer exists and `PublicTxSimulator` no longer has a phase loop. So these
# checks read the C++ at the pinned anchor for the model, and RUN the shipped module for the
# behaviour. Nothing of M20's is a reimplementation of any of it.
#
# ONE ARM RUN, SHARED BY SIX CHECKS. `verification/lib_m20_form_a.sh` runs
# `tools/run_form_a_arms.mjs` once into $M20_WORK/arms.json (default ~/.cache/aztec-m20-form-a)
# and every check reads it, so the six cannot come to disagree about a number nothing changed.
# It re-runs when the module, the runner or any orchestration source is newer; M20_ARMS_REFRESH=1
# forces one. It needs a built avm.wasm carrying M13's contract-DB and merkle-DB seeding exports —
# AVM_WASM_PATH, else this milestone's work directory, else M13's/M12's.
#
# COVERAGE, because a number quoted without one is how this campaign has been wrong before: SEVEN
# arms over mock transactions whose calls address contracts that were never registered. That
# reaches the checked-exception path deliberately and cheaply, and it is an INTEGRATION claim, not
# a breadth one. Breadth is M7's 391 upstream tests; semantics is M19's three-way oracle.
#
#   just verify-form-a-roundtrip    e2e_form_a_external_tx_roundtrip
#   just verify-form-a-provenance   test_provenance_not_consulted_during_execution   (DD-1)
#   just verify-form-a-fee          test_fee_juice_debited_and_insufficiency_throws  (DD-2)
#   just verify-form-a-teardown     e2e_form_a_teardown_revert_still_pays_fee
#   just verify-form-a-asymmetry    test_nonrevertible_nullifier_collision_throws_tx_out
#   just verify-form-a-runtime-bug  test_runtime_bug_not_reported_as_revert
#   just verify-m20                 all seven — 237 assertions (62 / 42 / 29 / 35 / 43 / 17 / 9)

# A serialized Tx deserializes, executes its public half on the wasm AVM, and lands its effects.
verify-form-a-roundtrip:
    @verification/e2e_form_a_external_tx_roundtrip.sh

# DD-1: the execution path never observes provenance, proved by a tripwire with a mutation control.
verify-form-a-provenance:
    @verification/test_provenance_not_consulted_during_execution.sh

# DD-2: skipFeeEnforcement defaults to false; a funded payer is debited, an unfunded one thrown out.
verify-form-a-fee:
    @verification/test_fee_juice_debited_and_insufficiency_throws.sh

# A reverting teardown rolls back to post-setup, still lands, and still pays.
verify-form-a-teardown:
    @verification/e2e_form_a_teardown_revert_still_pays_fee.sh

# A revertible-insertion nullifier collision is thrown out, while an APP_LOGIC revert is not.
verify-form-a-asymmetry:
    @verification/test_nonrevertible_nullifier_collision_throws_tx_out.sh

# A trap is a runtime bug and is rethrown unchanged, never converted into a revert.
verify-form-a-runtime-bug:
    @verification/test_runtime_bug_not_reported_as_revert.sh

# Every check this repository NAMES in a comment is a check that exists.
#
# M20's review found FIVE comments naming a verification check to reassure the reader that a
# property was pinned. None of the five existed; THREE of the properties were not pinned at all,
# including this milestone's third deliverable and D14's encoding-delta comparison. All five were
# found by reading, one at a time, which is exactly how a sixth gets missed — so the rule is
# mechanical now, total over `orchestration/src`, `node-host/src`, `verification/` and `tools/`,
# with a declared exceptions list that cannot go dead and a planted name as its control.
verify-named-checks:
    @verification/verify_named_checks_exist.sh

# Run the whole M20 verification set; every check runs even if an earlier one fails.
verify-m20:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      e2e_form_a_external_tx_roundtrip \
      test_provenance_not_consulted_during_execution \
      test_fee_juice_debited_and_insufficiency_throws \
      e2e_form_a_teardown_revert_still_pays_fee \
      test_nonrevertible_nullifier_collision_throws_tx_out \
      test_runtime_bug_not_reported_as_revert \
      verify_named_checks_exist
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m20: FAILED" >&2
    else
      echo "verify-m20: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M21 — Form B: locally-originated transactions
#
#   just verify-oq1                verify_oq1_aztec_node_methods_enumerated
#   just verify-oq2                verify_oq2_pxe_embedding_decision_recorded
#   just verify-form-b-roundtrip   e2e_form_b_local_tx_roundtrip
#   just verify-adapter-surface    test_aztec_node_adapter_surface_minimal
#   just verify-no-node-type       test_no_aztec_node_type_exported
#   just verify-txe-prior-art      verify_txe_private_flow_prior_art_consulted
#   just verify-no-pipe-predicates verify_no_pipeline_predicates
#   just verify-truncation-uniform verify_transcript_truncation_detection_uniform
#   just verify-m21                all of them, in order
#
# NOTHING HERE BUILDS. Form B's steps 3 and 4 are `@aztec/stdlib/tx`, which `orchestration/` already
# depends on, so the probes need no module and no work tree — they run against the published
# packages and against the fork at the pinned anchor. That is a fact about how little of this
# milestone was ours to write, not a gap: the two arms that would need `avm.wasm` are M20's, already
# measured over seven arms twice each, and re-running them here would be a second place for one
# number to live.
#
# `verify-oq2` NEEDS THE NETWORK. It resolves `@aztec/pxe` and `@aztec/simulator` against the
# registry and reads their dependency lists, because the campaign recorded one of them as
# unpublished twice while it was published. Without the registry it FAILS rather than passing on a
# recorded answer.
#
# The last two are not Form B's: they are the two items M20's review left owed, and they belong to
# the whole tree rather than to any one milestone. They are run here because M21 is where they were
# done.
#
# `verify_named_checks_exist` IS DELIBERATELY NOT IN THIS LIST, and the reason is the campaign's own
# counter defect. It is M20's check and `verify-m20` runs it; running it here too would add its 9
# assertions to two milestone totals and to the campaign total twice, which is exactly how M1 came
# out at 316 when it is 141. It still covers M21 — it scans the WHOLE tree, so a comment in
# `form_b.ts` naming a check that does not exist goes red in `verify-m20`, and one did.
# ---------------------------------------------------------------------------

# OQ-1: every node.* call reachable from generateSimulatedProvingResult, re-derived from the anchor.
verify-oq1:
    @verification/verify_oq1_aztec_node_methods_enumerated.sh

# OQ-2: the embed-versus-vendor decision, with its dependency lists measured live. NEEDS NETWORK.
verify-oq2:
    @verification/verify_oq2_pxe_embedding_decision_recorded.sh

# A tail becomes the Tx upstream would have built, and goes through M20's one execution window.
verify-form-b-roundtrip:
    @verification/e2e_form_b_local_tx_roundtrip.sh

# Anything outside the enumerated adapter surface throws, on `get` and on `in`.
verify-adapter-surface:
    @verification/test_aztec_node_adapter_surface_minimal.sh

# §8.4: no exported type named AztecNode, and nothing shaped like one.
verify-no-node-type:
    @verification/test_no_aztec_node_type_exported.sh

# TXE's private-execution-to-Tx flow, and the five things consulting it changed.
verify-txe-prior-art:
    @verification/verify_txe_private_flow_prior_art_consulted.sh

# No `printf … | grep -q` predicate survives anywhere; the five builtin replacements are exercised.
verify-no-pipe-predicates:
    @verification/verify_no_pipeline_predicates.sh

# One implementation of "is this transcript complete", and every comparer refuses on an incomplete one.
verify-truncation-uniform:
    @verification/verify_transcript_truncation_detection_uniform.sh

# Run the whole M21 verification set; every check runs even if an earlier one fails.
verify-m21:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_oq1_aztec_node_methods_enumerated \
      verify_oq2_pxe_embedding_decision_recorded \
      test_no_aztec_node_type_exported \
      test_aztec_node_adapter_surface_minimal \
      e2e_form_b_local_tx_roundtrip \
      verify_txe_private_flow_prior_art_consulted \
      verify_no_pipeline_predicates \
      verify_transcript_truncation_detection_uniform
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m21: FAILED" >&2
    else
      echo "verify-m21: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M22 — block assembly
#
#   just verify-processor-vendored  verify_public_processor_vendored_not_reimplemented
#   just verify-block-failed-tx     test_failed_tx_leaves_no_state
#   just verify-block-limits        test_block_limits_respected
#   just verify-block-guard         test_guarded_merkle_tree_blocks_post_seal_access
#   just verify-m22                 all four, in order — 260 assertions (71 / 44 / 89 / 56)
#
# THE LOOP IS UPSTREAM'S AND THAT IS THE MILESTONE. `PublicProcessor.process` is vendored from the
# `ts` anchor into `orchestration/src/vendor/public_processor/`, with nine other files its import
# closure reaches, and PROVENANCE.md F10..F19 make `just check-drift` compare all ten against that
# commit on every run. What M22 wrote is the two adapters underneath it (RI-67, RI-68) and the seam
# above it; `verify_public_processor_vendored_not_reimplemented` is the check that says so, by
# diffing the copy against the anchor line for line and by requiring that nothing of ours outside
# `vendor/` contains the loop.
#
# ONE BLOCK RUN, SHARED BY THREE CHECKS. `verification/lib_m22_block.sh` runs
# `tools/run_block_arms.mjs` once into $M22_WORK/blocks.json (default ~/.cache/aztec-m22-block) and
# the three behavioural checks read it, so they cannot come to disagree about a number nothing
# changed. FIFTEEN arms: an unlimited block, a stopping and a non-stopping arm for each of the five
# limits, a requeue, a failing transaction and its control, and the guard arm. It re-runs when the module, the runner, any orchestration source or any node-host source
# is newer; M22_ARMS_REFRESH=1 forces one. It needs a built avm.wasm carrying M13's contract-DB and
# merkle-DB exports — AVM_WASM_PATH, else this milestone's work directory, else M13's/M12's.
#
# WHAT THIS MILESTONE DOES NOT DELIVER, said here rather than left to be discovered: the block is
# not SEALED. `sealBlock` is upstream's `makeTXEBlockHeader` and its `getTreeInfo(ARCHIVE)` is the
# one call the shipped module cannot serve, because M14's archive extension (RI-53) is a prepared
# patch that is not carried. The refusal is measured rather than described — see
# `test_guarded_merkle_tree_blocks_post_seal_access` part 4 — and M22's status entry lists the three
# named things that would close it.
# ---------------------------------------------------------------------------

# The loop is upstream's code at the pinned commit, with only the edits PROVENANCE.md declares.
verify-processor-vendored:
    @verification/verify_public_processor_vendored_not_reimplemented.sh

# A thrown-out transaction contributes nothing, and the next transaction sees the pre-failure state.
verify-block-failed-tx:
    @verification/test_failed_tx_leaves_no_state.sh

# Four limits, eight arms, a discriminator per limit, and the unprocessed set shown requeueable.
verify-block-limits:
    @verification/test_block_limits_respected.sh

# DD-3: the guard refuses world-state access after the seal, with the unguarded database as control.
verify-block-guard:
    @verification/test_guarded_merkle_tree_blocks_post_seal_access.sh

# Run the whole M22 verification set; every check runs even if an earlier one fails.
verify-m22:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_public_processor_vendored_not_reimplemented \
      test_failed_tx_leaves_no_state \
      test_block_limits_respected \
      test_guarded_merkle_tree_blocks_post_seal_access
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m22: FAILED" >&2
    else
      echo "verify-m22: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M23 — the chain loop, timer-driven empty blocks, and the AvmRuntime facade
#
#   just avm-wasm-build-m23         build the module that CARRIES THE ARCHIVE (twelve overlays)
#   just verify-chain-enumeration   verify_sequencer_reuse_enumeration_recorded
#   just verify-chain-txe-verdict   verify_txe_reuse_verdict_recorded
#   just verify-chain-facade-map    verify_facade_surface_compared_against_txe
#   just verify-chain-snapshot-vocabulary
#                                   test_tree_snapshot_vocabulary_reused_not_redefined
#   just verify-chain-kv-store      verify_kv_store_browser_exports_recorded
#   just verify-chain-empty-blocks  test_empty_block_advances_number_and_archive
#   just verify-chain-seal          test_block_seal_updates_archive   (M22's entry, closed here)
#   just verify-chain-timestamps    test_timestamps_strictly_monotonic_subsecond
#   just verify-chain-fake-clock    test_fake_clock_hundred_blocks
#   just verify-chain-automine      e2e_automine_seals_on_submission
#   just verify-chain-disclosure    test_receipt_declares_no_proving
#   just verify-chain-no-ambient-clock
#                                   test_no_ambient_clock_or_timer
#   just verify-chain-l1-to-l2      e2e_l1_to_l2_message_injection
#   just verify-chain-snapshot      e2e_chain_snapshot_export_import_roundtrip
#   just verify-m23                 all fourteen, in order
#
# THE MODULE IS A DIFFERENT ARTEFACT FROM M12'S AND M13'S. M23 carries M14's archive extension
# (RI-53) as an eleventh overlay and adds two reactor exports as a twelfth (RI-70), so its
# `avm.wasm` exports FIFTY-ONE names where M13's exports forty-nine and M12's thirty-nine. It is
# measured separately, which is what M13 did for its own tenth overlay: an export appearing is as
# much a finding as one disappearing. Nothing repoints an earlier milestone at this tree — M18,
# M20, M21 and M22 go on measuring the modules they were written against, where the archive is
# absent and `sealBlock` refuses, and their checks are untouched.
#
# ONE ARM RUN, SHARED BY NINE CHECKS. `verification/lib_m23_chain.sh` runs
# `tools/run_chain_arms.mjs` once into $M23_WORK/chain.json (default ~/.cache/aztec-m23-chain) and
# the behavioural checks read it, so they cannot come to disagree about a number nothing changed.
# NINE arms: the archive's identity against upstream's published genesis constants, three empty
# blocks, a run with empty blocks turned OFF, fifteen blocks over a sub-second interval and a
# throttle, a hundred blocks on a fake ticker beside a hundred on upstream's `RunningPromise`,
# automine on and off, an L1-to-L2 message across a block boundary, the §8.4 disclosure, and an
# export/import roundtrip into a second world state. It re-runs when the module, the runner, any
# orchestration source or any node-host source is newer; M23_ARMS_REFRESH=1 forces one.
#
# WHAT THIS MILESTONE DOES NOT DELIVER, said here rather than left to be discovered: the AVM's
# `L1TOL2MSGEXISTS` opcode is not exercised. Doing so needs a transaction that calls a REGISTERED
# CONTRACT, and upstream's only builder of those is `PublicTxSimulationTester`, which constructs a
# `NativeWorldStateService` — DD-9. That is M22's outstanding task, unchanged, and
# `e2e_l1_to_l2_message_injection` asserts the blocker as a fact about the fork rather than leaving
# it to be rediscovered.
# ---------------------------------------------------------------------------

# Build the twelve-overlay module: M13's ten, M14's archive patch, and M23's reactor exports.
avm-wasm-build-m23:
    @verification/build_avm_wasm_m23.sh

# The enumeration, re-derived from the fork rather than read out of CHAIN-LOOP.md.
verify-chain-enumeration:
    @verification/verify_sequencer_reuse_enumeration_recorded.sh

# TXE cannot be declined by omission: its size, surface and dependencies, measured.
verify-chain-txe-verdict:
    @verification/verify_txe_reuse_verdict_recorded.sh

# Every AvmRuntime member mapped to its TXE and AztecNodeDebug counterpart, or to `none`.
verify-chain-facade-map:
    @verification/verify_facade_surface_compared_against_txe.sh

# One state-reference vocabulary, and the export carrier as a distinct recorded decision.
verify-chain-snapshot-vocabulary:
    @verification/test_tree_snapshot_vocabulary_reused_not_redefined.sh

# The kv-store browser entry points, at all four artefacts, because they disagree.
verify-chain-kv-store:
    @verification/verify_kv_store_browser_exports_recorded.sh

# An empty block advances the number, the timestamp and the archive — the milestone's headline.
verify-chain-empty-blocks:
    @verification/test_empty_block_advances_number_and_archive.sh

# Sealing appends the header to the archive, and a header that does not match is refused.
verify-chain-seal:
    @verification/test_block_seal_updates_archive.sh

# Strictly monotonic timestamps under a sub-second interval and a throttled timer.
verify-chain-timestamps:
    @verification/test_timestamps_strictly_monotonic_subsecond.sh

# A hundred blocks on a fake clock, and the same hundred on upstream's RunningPromise.
verify-chain-fake-clock:
    @verification/test_fake_clock_hundred_blocks.sh

# Automine on and off, with the discriminator in both directions.
verify-chain-automine:
    @verification/e2e_automine_seals_on_submission.sh

# §8.4: every receipt declares it, and a discarding sink does not suppress the record.
verify-chain-disclosure:
    @verification/test_receipt_declares_no_proving.sh

# DD-4, structurally: no Date.now, setInterval or setTimeout in the shipped source.
verify-chain-no-ambient-clock:
    @verification/test_no_ambient_clock_or_timer.sh

# An injected L1-to-L2 message is a leaf of the message tree at the next block boundary.
verify-chain-l1-to-l2:
    @verification/e2e_l1_to_l2_message_injection.sh

# Export a chain, reload it into a second world state, and be the same chain.
verify-chain-snapshot:
    @verification/e2e_chain_snapshot_export_import_roundtrip.sh

# Run the whole M23 verification set; every check runs even if an earlier one fails.
verify-m23:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_sequencer_reuse_enumeration_recorded \
      verify_txe_reuse_verdict_recorded \
      verify_facade_surface_compared_against_txe \
      test_tree_snapshot_vocabulary_reused_not_redefined \
      verify_kv_store_browser_exports_recorded \
      test_empty_block_advances_number_and_archive \
      test_block_seal_updates_archive \
      test_timestamps_strictly_monotonic_subsecond \
      test_fake_clock_hundred_blocks \
      e2e_automine_seals_on_submission \
      test_receipt_declares_no_proving \
      test_no_ambient_clock_or_timer \
      e2e_l1_to_l2_message_injection \
      e2e_chain_snapshot_export_import_roundtrip
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m23: FAILED" >&2
    else
      echo "verify-m23: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M24 — the `.ct` writer binding and the trace event ABI.
#
# The build is NOT in either dev shell: the rust wasm toolchain comes from
# `nix shell nixpkgs#rustup nixpkgs#capnproto`, with RUSTUP_HOME and CARGO_HOME
# under ~/.cache. `capnp` is a hard build-time dependency of the writer's
# dependency graph and its absence fails four crates deep with `exit status: 101`.
# ---------------------------------------------------------------------------

# Materialise codetracer-trace-format at pins.json's revision and build ct_writer.wasm.
ct-writer-build:
    @verification/build_ct_writer_wasm.sh --native-tests

# Build BOTH ct-print readers — at the fix and at its parent — out of the object store.
ct-print-build:
    @verification/build_ct_print.sh

# Re-measure the functional arms (roundtrip, equivalence, backpressure, the DD-7 gates).
ct-writer-arms:
    @node --experimental-strip-types tools/run_ct_writer_arms.mjs \
      --module ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm \
      --work "${M24_WORK:-$HOME/.cache/aztec-m24-ct-writer}"

# Re-measure OQ-6. Twelve sessions of six ABBA blocks; about ten minutes. Run it detached.
oq6-measure:
    @node --experimental-strip-types tools/run_oq6_arms.mjs \
      --module ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm \
      --events 100000 --batch 4096 --reps 6 --sessions 12 \
      --out "${M24_OQ6_WORK:-$HOME/.cache/aztec-m24-oq6}/arms.tsv"

# Type-check the ct-host package against the nix-pinned tsc.
typecheck-ct-host:
    @cd ct-host && tsc -p tsconfig.json && echo "ct-host: type-checks"

verify-ct-writer-imports:
    @verification/verify_ct_writer_wasm_zero_imports.sh

verify-ct-roundtrip:
    @verification/test_ct_container_roundtrip_ct_print.sh

verify-oq6:
    @verification/verify_trace_event_abi_batched_faster.sh

verify-ct-dd7:
    @verification/test_dropped_column_awareness_asserted.sh

verify-ct-single-instantiation:
    @verification/test_single_trace_types_instantiation.sh

verify-ct-backpressure:
    @verification/test_trace_writer_backpressure.sh

# Run the whole M24 verification set; every check runs even if an earlier one fails.
# ---------------------------------------------------------------------------
# M25 — step-level tracing: the source-mapping ladder (OQ-5) and field rendering (OQ-4).
#
# IT BUILDS THE SAME `ct_writer.wasm` M24 DOES — one crate, one artefact — so `just ct-writer-build`
# serves both and `lib_m25_trace.sh` sources `lib_m24_ct_writer.sh` rather than copying it.
#
# The arms are driven against a REAL SHIPPED AZTEC CONTRACT, `@aztec/noir-test-contracts.js`'s
# `AvmTest` at the `deletion_era` pin, found under `diffsim/`, `spike/` or `drift/`. OQ-5's verdict
# is a claim about what `avm-transpiler` leaves in an artifact somebody else built, so it is settled
# against one and never against a fixture of ours; a missing artifact is a `die`, not a skip.
#
# ONE ARM RUN, SHARED BY THREE CHECKS. `verification/lib_m25_trace.sh` runs `tools/run_trace_arms.mjs`
# once into $M25_WORK/trace.json (default ~/.cache/aztec-m25-trace) and the checks read it.
#
# WHAT THIS MILESTONE DOES NOT DELIVER, said here rather than left to be discovered: four of its
# seven verification entries need a transaction that CALLS A REGISTERED CONTRACT.
# `verify_transaction_builder_closure_measured` records the closure as a number so the decision is
# takeable — 65 files / 10,421 lines whole, 4 files / 880 lines for the calldata-and-call-request
# half — rather than deferred for a ninth time.
# ---------------------------------------------------------------------------

# Build the five OQ-4 rendering arms (int, low64, bigint, string, raw) out of the pinned writer.
oq4-probe:
    @verification/build_oq4_rendering_probe.sh

# Re-measure the source-mapping arms against the shipped AvmTest artifact.
trace-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    art=""
    for root in diffsim spike drift; do
      if [ -f "$root/node_modules/@aztec/noir-test-contracts.js/artifacts/avm_test_contract-AvmTest.json" ]; then
        art="$root/node_modules/@aztec/noir-test-contracts.js/artifacts/avm_test_contract-AvmTest.json"
        break
      fi
    done
    if [ -z "$art" ]; then
      echo "trace-arms: no shipped AvmTest artifact under diffsim/, spike/ or drift/" >&2
      exit 1
    fi
    node --experimental-strip-types tools/run_trace_arms.mjs \
      --module ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm \
      --artifact "$art" \
      --work "${M25_WORK:-$HOME/.cache/aztec-m25-trace}"

verify-oq5:
    @verification/verify_oq5_source_mapping_verdict_recorded.sh

verify-fr-rendering:
    @verification/test_fr_rendering_matches_noir_tracer.sh

verify-mapping-rung:
    @verification/test_trace_metadata_declares_mapping_rung.sh

verify-tx-builder-closure:
    @verification/verify_transaction_builder_closure_measured.sh

# Run the whole M25 verification set; every check runs even if an earlier one fails.
verify-m25:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_oq5_source_mapping_verdict_recorded \
      test_fr_rendering_matches_noir_tracer \
      test_trace_metadata_declares_mapping_rung \
      verify_transaction_builder_closure_measured
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m25: FAILED" >&2
    else
      echo "verify-m25: all checks passed"
    fi
    exit "$rc"

verify-m24:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_ct_writer_wasm_zero_imports \
      test_ct_container_roundtrip_ct_print \
      test_dropped_column_awareness_asserted \
      test_single_trace_types_instantiation \
      test_trace_writer_backpressure \
      verify_trace_event_abi_batched_faster
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m24: FAILED" >&2
    else
      echo "verify-m24: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M26 — joining the private and public halves of one transaction
#
#   just verify-tx-builder      verify_tx_builder_vendored_not_reimplemented
#   just verify-oq7             verify_oq7_shared_writer_verdict_recorded
#   just verify-frame-nesting   test_private_public_frame_nesting
#   just verify-join-fallback   test_join_fallback_two_recordings
#   just verify-m26             all four
#
# NOTHING IN M26 DEPENDS ON `avm.wasm`. The public half's containers are written by
# `ct-writer/target/.../aztec_ct_writer.wasm` (M24's module, with M26's join and frame exports) and
# the private half by the OQ-7 probe, so the checks build the ct-writer module and the probe and
# nothing else.
#
# THE PROBE IS THE EXPENSIVE INPUT AND IT IS CACHED, NOT SKIPPED. `build_oq7_shared_writer_probe.sh`
# links the real `noir_tracer`, which is a large part of the Noir compiler; it shares the Noir
# worktree's own `target/` and its own toolchain so a warm tree rebuilds in seconds, and its
# staleness stamp hashes `tracer_glue.rs` as well as the worktree HEAD, because M26's edit to that
# file is uncommitted and a HEAD-only stamp would not move for it.
# ---------------------------------------------------------------------------

# Build the OQ-7 shared-writer probe (one CtfsTraceWriter, two producers).
oq7-probe:
    @verification/build_oq7_shared_writer_probe.sh

# Re-measure the join arms into $M26_WORK/join.json (default ~/.cache/aztec-m26-join).
join-arms:
    @node --experimental-strip-types tools/run_join_arms.mjs "${M26_WORK:-$HOME/.cache/aztec-m26-join}"

verify-tx-builder:
    @verification/verify_tx_builder_vendored_not_reimplemented.sh

verify-oq7:
    @verification/verify_oq7_shared_writer_verdict_recorded.sh

verify-frame-nesting:
    @verification/test_private_public_frame_nesting.sh

verify-join-fallback:
    @verification/test_join_fallback_two_recordings.sh

# Run the whole M26 verification set; every check runs even if an earlier one fails.
verify-m26:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_tx_builder_vendored_not_reimplemented \
      verify_oq7_shared_writer_verdict_recorded \
      test_private_public_frame_nesting \
      test_join_fallback_two_recordings
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m26: FAILED" >&2
    else
      echo "verify-m26: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M27 — browser packaging and code splitting
#
#   just avm-wasm-build-m27        build the module that EXPORTS POSEIDON2 AND GRUMPKIN
#                                  (thirteen overlays, fifty-five exports)
#   just browser-build             build the three entry points + the demo, and ENFORCE the budgets
#   just browser-arms              re-measure the browser arms in a real headless Chromium
#   just browser-serve             serve the built demo on a local port, for a person
#
#   just verify-browser-build              verify_browser_bundle_builds
#   just verify-browser-no-barretenberg    verify_public_only_page_never_fetches_barretenberg
#   just verify-browser-chunk-budget       verify_browser_chunk_budget
#   just verify-browser-bbjs-condition     verify_bb_js_browser_condition_honoured
#   just verify-browser-token-transfer     smoke_browser_token_transfer
#   just verify-browser-real-timer         smoke_browser_produces_block_on_real_timer
#   just verify-browser-ct-container       e2e_browser_downloads_ct_container_and_ct_print_parses
#   just verify-browser-crypto             test_browser_crypto_matches_bb_js
#   just verify-browser-entry-points       verify_browser_entry_points_are_dd5_shaped
#   just verify-browser-artifacts-lazy     verify_browser_artifacts_lazy
#   just verify-m27                        all ten, in order
#
# WHAT M27 NEEDS THAT NO EARLIER MILESTONE DID:
#
#   * A MODULE FROM ITS OWN OVERLAY STACK. M23's twelve-patch module has fifty-one exports and no
#     poseidon2; a browser page that used bb.js's instead would download 7.9 MB of proving stack for
#     a hash, which is what DD-11 forbids. `just avm-wasm-build-m27` builds the thirteen-patch tree
#     under $M27_WORK (default ~/.cache/aztec-m27-browser). Budget about 8 GB and a few minutes with
#     a warm ccache.
#   * A REAL BROWSER. The checks drive `/usr/bin/chromium` over the DevTools protocol, because
#     `verify_public_only_page_never_fetches_barretenberg` must be asserted on OBSERVED NETWORK
#     REQUESTS and there is no substitute for that which would be evidence. There is no puppeteer
#     and no playwright: Node 24's global `WebSocket` speaks CDP directly (tools/browser_cdp.mjs).
#     Set M27_CHROMIUM to point at a different binary.
#   * `ct_writer.wasm` AND `ct-print`, M24's, for the product claim. Both are built by their own
#     scripts if absent.
#
# The browser arms are measured ONCE into $M27_WORK/browser.json and shared by every behavioural
# check, which is M20's convention: seven checks each launching a browser is seven browsers and
# seven chances to disagree about a number nothing changed.
# ---------------------------------------------------------------------------

# Build the thirteen-overlay module: poseidon2 and grumpkin out through the reactor.
avm-wasm-build-m27:
    @verification/build_avm_wasm_m27.sh

# Build the browser bundles. FAILS if a chunk exceeds its recorded gzipped budget.
browser-build:
    @node browser/build.mjs

# Re-measure the browser arms into $M27_WORK/browser.json.
browser-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M27_WORK:-$HOME/.cache/aztec-m27-browser}"
    : "${AVM_WASM_PATH:=$work/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm}"
    export AVM_WASM_PATH
    node tools/run_browser_arms.mjs "$work" > "$work/browser.json"
    echo "browser-arms: wrote $work/browser.json"

# Serve the built demo for a person to click. Ctrl-C to stop.
#
# It serves $M27_WORK/site, which `just browser-arms` assembles: the built bundle plus the three
# assets a page fetches at run time. A `file://` page cannot work — ES module imports, dynamic
# imports and `WebAssembly.compileStreaming` are all same-origin, and a `file://` origin is `null`.
browser-serve:
    @node tools/serve_browser_demo.mjs "${M27_WORK:-$HOME/.cache/aztec-m27-browser}/site"

verify-browser-build:
    @verification/verify_browser_bundle_builds.sh

verify-browser-no-barretenberg:
    @verification/verify_public_only_page_never_fetches_barretenberg.sh

verify-browser-chunk-budget:
    @verification/verify_browser_chunk_budget.sh

verify-browser-bbjs-condition:
    @verification/verify_bb_js_browser_condition_honoured.sh

verify-browser-token-transfer:
    @verification/smoke_browser_token_transfer.sh

verify-browser-real-timer:
    @verification/smoke_browser_produces_block_on_real_timer.sh

verify-browser-ct-container:
    @verification/e2e_browser_downloads_ct_container_and_ct_print_parses.sh

verify-browser-crypto:
    @verification/test_browser_crypto_matches_bb_js.sh

verify-browser-entry-points:
    @verification/verify_browser_entry_points_are_dd5_shaped.sh

verify-browser-artifacts-lazy:
    @verification/verify_browser_artifacts_lazy.sh

# Run the whole M27 verification set; every check runs even if an earlier one fails.
verify-m27:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_browser_bundle_builds \
      verify_browser_entry_points_are_dd5_shaped \
      verify_browser_chunk_budget \
      verify_browser_artifacts_lazy \
      verify_bb_js_browser_condition_honoured \
      test_browser_crypto_matches_bb_js \
      verify_public_only_page_never_fetches_barretenberg \
      smoke_browser_token_transfer \
      smoke_browser_produces_block_on_real_timer \
      e2e_browser_downloads_ct_container_and_ct_print_parses
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m27: FAILED" >&2
    else
      echo "verify-m27: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M28 — the browser CI gate: no Node.js dependencies
#
#   just ci-browser-gate           THE GATE. Everything below, in order, locally, exactly as CI
#                                  runs it. It does not warn and there is no flag that skips it.
#   just verify-m28                M28's own six checks (the gate minus M27's DD-5 check, which is
#                                  counted in M27 — see below)
#
#   just verify-browser-no-builtins           verify_browser_bundle_no_node_builtins
#   just verify-browser-no-native             verify_browser_bundle_no_native_deps
#   just verify-npm-pack-no-native            verify_npm_pack_no_optional_native
#   just verify-browser-no-verification-code  verify_verification_code_unreachable_from_browser
#   just verify-browser-full-flow             smoke_browser_headless_full_flow
#   just verify-ci-browser-gate               the gate's own wiring, composition and CI job
#
# WHY THE GATE AND `verify-m28` ARE DIFFERENT LISTS, AND WHY THE DIFFERENCE IS EXACTLY ONE CHECK.
#
# The gate runs `verify_browser_entry_points_are_dd5_shaped` and `verify-m28` does not. That check
# is M27's, its 40 assertions are counted in M27's total, and running it in both would double-count
# it in a campaign sweep — the shape `CAMPAIGN-BRIEF.md` records as "M1 came out at 316 when it is
# 141". It belongs in the GATE because DD-5 — the browser is the reference, Node is the superset —
# is the rule the gate exists to keep true, and M23 marked it unmet precisely because nothing
# enforced it continuously. `verification/ci_browser_gate.sh` asserts that the two lists differ by
# exactly that one name, so they cannot drift apart.
#
# WHAT THE GATE NEEDS, AND WHAT IT COSTS. The full-flow smoke drives a real headless Chromium
# against M27's thirteen-overlay module, so a cold run needs `just avm-wasm-build-m27` first
# (~8 GB, a few minutes warm) and a chromium on PATH or in $M27_CHROMIUM. The four static gates
# need only the built bundle and the installed @aztec packages.
# ---------------------------------------------------------------------------

verify-browser-no-builtins:
    @verification/verify_browser_bundle_no_node_builtins.sh

verify-browser-no-native:
    @verification/verify_browser_bundle_no_native_deps.sh

verify-npm-pack-no-native:
    @verification/verify_npm_pack_no_optional_native.sh

verify-browser-no-verification-code:
    @verification/verify_verification_code_unreachable_from_browser.sh

verify-browser-full-flow:
    @verification/smoke_browser_headless_full_flow.sh

verify-ci-browser-gate:
    @verification/ci_browser_gate.sh

# THE GATE. It fails the build; it does not warn, and there is no flag that skips it.
#
# Every check runs even if an earlier one fails, so one run reports everything that broke — and the
# exit status is the OR of all of them. There is deliberately no `|| true`, no `continue-on-error`
# and no environment variable that turns a failure into a warning: `ci_browser_gate.sh` asserts all
# three of those things about this recipe's own text and about the CI job that invokes it.
ci-browser-gate:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      ci_browser_gate \
      verify_browser_bundle_no_node_builtins \
      verify_browser_bundle_no_native_deps \
      verify_npm_pack_no_optional_native \
      verify_verification_code_unreachable_from_browser \
      verify_browser_entry_points_are_dd5_shaped \
      smoke_browser_headless_full_flow
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "ci-browser-gate: FAILED — the browser gate is a build failure, not a warning" >&2
    else
      echo "ci-browser-gate: all checks passed"
    fi
    exit "$rc"

# M28's own six, for the campaign sweep. The gate minus M27's DD-5 check; see the note above.
verify-m28:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      ci_browser_gate \
      verify_browser_bundle_no_node_builtins \
      verify_browser_bundle_no_native_deps \
      verify_npm_pack_no_optional_native \
      verify_verification_code_unreachable_from_browser \
      smoke_browser_headless_full_flow
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m28: FAILED" >&2
    else
      echo "verify-m28: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M29 — executed steps, not mapped ones
#
#   just verify-m29-executed        test_browser_steps_are_executed_not_mapped
#   just verify-m29-native-parity   e2e_browser_container_opcodes_match_native
#   just verify-m29-step-count      test_trace_step_count_matches_instruction_count
#   just verify-m29                 all three, in order
#
# WHAT THEY NEED. The M27 browser stack (a built bundle, M27's thirteen-overlay module, a chromium)
# AND M12's native `avm_differential`, which `lib_m29_steps.sh` locates through `m12_measured` and
# runs itself — `steps` for the reference transcript and `reactorinputs` for the blobs the page is
# handed, 3.0 s and 0.9 s respectively. Both transcripts are produced in the run that reads them,
# because "never depend on state you did not produce".
#
# THE ARMS ARE M27's, EXTENDED. `run_browser_arms.mjs` gains a sixth arm — one corpus program run in
# the page from the native driver's own bytes — which is present only when `M29_PARITY_INPUTS` is in
# the environment. `m29_require_arms` puts it there and forces one refresh if a previous M27 run
# left a report without it, so a missing arm is a NAMED failure in M29 rather than a silently
# smaller milestone.
# ---------------------------------------------------------------------------

verify-m29-executed:
    @verification/test_browser_steps_are_executed_not_mapped.sh

verify-m29-native-parity:
    @verification/e2e_browser_container_opcodes_match_native.sh

verify-m29-step-count:
    @verification/test_trace_step_count_matches_instruction_count.sh

verify-m29:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      test_browser_steps_are_executed_not_mapped \
      e2e_browser_container_opcodes_match_native \
      test_trace_step_count_matches_instruction_count
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m29: FAILED" >&2
    else
      echo "verify-m29: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# M30 — compiling Noir from a virtual filesystem
#
#   just verify-m30-multifile      test_vfs_multifile_compiles
#   just verify-m30-positions      test_vfs_compile_errors_carry_positions
#   just verify-m30-retrace        e2e_vfs_edit_recompile_retrace
#   just verify-m30-git-refusal    verify_git_dependency_refused_by_name
#   just verify-m30                all four, in order
#
# WHAT THEY NEED. Two wasm modules and a chromium, and `lib_m30_vfs.sh` builds both itself
# because "never depend on state you did not produce":
#
#   `noir_wasm.wasm`         M30's own — `../noir` (branch `blocktracer`), `compiler/wasm`,
#                            built by `verification/build_noir_vfs_wasm.sh` through
#                            `nix shell nixpkgs#rustup`, because neither dev shell carries a
#                            wasm32-unknown-unknown rust std. Stamped on the CONTENT of its
#                            sources rather than on a revision, because the milestone's own
#                            work is uncommitted by construction.
#   `noir_tracer_wasm.wasm`  M24's and M26's — `../noir-wt4-webpage`, built READ-ONLY by
#                            `verification/build_noir_tracer_wasm.sh`, which refuses to build
#                            from a worktree carrying any edit but M26's one tolerated file
#                            and refuses if that worktree's HEAD has become published. It also
#                            needs `nixpkgs#capnproto`: without it the build dies with
#                            `exit status: 101` four crates deep, which reads like a broken
#                            branch rather than a missing tool.
#
# THE ARMS ARE M30's OWN and are not M27's. `tools/run_vfs_arms.mjs` serves
# `verification/m30/page/` with the two modules beside it and drives it through
# `tools/browser_cdp.mjs` — the same dependency-free CDP client M27 uses, and nothing else of
# M27's. There is no bundler in this path: the page fetches two `.wasm` files and calls their
# C ABIs, so if a check finds a compiled Noir program at the end of it, no JavaScript
# compiled it.
#
# A NOTE ON COST. The first run builds two wasm modules and then compiles Noir programs
# eighteen times inside a browser. `M30_ARMS_TIMEOUT` (1800 s) and `M30_BUILD_TIMEOUT`
# (1800 s) bound it; exceeding either is a named failure rather than a hang.
# ---------------------------------------------------------------------------

verify-m30-multifile:
    @verification/test_vfs_multifile_compiles.sh

verify-m30-positions:
    @verification/test_vfs_compile_errors_carry_positions.sh

verify-m30-retrace:
    @verification/e2e_vfs_edit_recompile_retrace.sh

verify-m30-git-refusal:
    @verification/verify_git_dependency_refused_by_name.sh

# Build the two wasm modules M30's page loads, without running a check.
m30-modules:
    #!/usr/bin/env bash
    set -uo pipefail
    verification/build_noir_vfs_wasm.sh
    verification/build_noir_tracer_wasm.sh

# Re-measure the M30 VFS arms into $M30_WORK/vfs.json.
m30-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M30_WORK:-$HOME/.cache/aztec-m30-vfs}"
    mkdir -p "$work"
    noir="$(verification/build_noir_vfs_wasm.sh | tail -1)"
    tracer="$(verification/build_noir_tracer_wasm.sh | tail -1)"
    M30_NOIR_WASM="$noir" M30_TRACER_WASM="$tracer" \
      node tools/run_vfs_arms.mjs "$work" > "$work/vfs.json"
    echo "m30-arms: wrote $work/vfs.json"

verify-m30:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      test_vfs_multifile_compiles \
      test_vfs_compile_errors_carry_positions \
      e2e_vfs_edit_recompile_retrace \
      verify_git_dependency_refused_by_name
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m30: FAILED" >&2
    else
      echo "verify-m30: all checks passed"
    fi
    exit "$rc"

# ==============================================================================================
# M31 — `avm-transpiler` to WebAssembly.
#
#   just verify-m31-identity   verify_transpiler_wasm_output_identical_to_native
#   just verify-m31-execute    test_transpiled_contract_registers_and_executes
#   just verify-m31-rung1      verify_transpiler_rung1_mapping_survives
#   just verify-m31-neutral    verify_transpiler_native_build_unaffected
#   just verify-m31            all four, in order
#
# WHAT THEY NEED, and the first one is not obvious. `aztec-packages/noir/noir-repo` is an EMPTY
# DIRECTORY in this workspace — a submodule pinned at `40d6574f…` (Noir 1.0.0-beta.26) that has
# never been checked out — and all five of `avm-transpiler`'s path dependencies point into it.
# `verification/build_avm_transpiler_wasm.sh` materialises it with `git archive` out of the
# sibling `noir` checkout's object store, which HAS that commit, and then builds nargo from it so
# the fixture contracts are compiled by the version the transpiler's crates expect. The first run
# is a few minutes; it is content-stamped over the whole materialised source tree afterwards.
#
# It also needs a chromium (M31_CHROMIUM, default /usr/bin/chromium) and, for the execution check
# only, a built `avm.wasm` carrying M27's crypto exports — `just avm-wasm-build-m27`, or
# AVM_WASM_PATH. The execution arm REFUSES BY NAME rather than skipping if it is absent.
verify-m31-identity:
    @verification/verify_transpiler_wasm_output_identical_to_native.sh

verify-m31-execute:
    @verification/test_transpiled_contract_registers_and_executes.sh

verify-m31-rung1:
    @verification/verify_transpiler_rung1_mapping_survives.sh

verify-m31-neutral:
    @verification/verify_transpiler_native_build_unaffected.sh

# Build the module, the native binary and the fixture artifacts, without running a check.
m31-build:
    @verification/build_avm_transpiler_wasm.sh

# The same two revisions with the upstream patch NOT applied — the neutrality baseline.
m31-baseline:
    @verification/build_avm_transpiler_wasm.sh --baseline

# Re-measure the M31 transpiler arms into $M31_WORK/transpiler.json.
m31-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M31_WORK:-$HOME/.cache/aztec-m31-arms}"
    mkdir -p "$work"
    eval "$(verification/build_avm_transpiler_wasm.sh 2>/dev/null | grep -E '^(MODULE|NATIVE|ARTIFACTS)=' | sed 's/^/M31_/')"
    M31_MODULE="$M31_MODULE" M31_NATIVE="$M31_NATIVE" M31_ARTIFACTS="$M31_ARTIFACTS" \
      node --experimental-strip-types tools/run_transpiler_arms.mjs "$work" > "$work/transpiler.json"
    echo "m31-arms: wrote $work/transpiler.json"

verify-m31:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_transpiler_wasm_output_identical_to_native \
      test_transpiled_contract_registers_and_executes \
      verify_transpiler_rung1_mapping_survives \
      verify_transpiler_native_build_unaffected
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m31: FAILED" >&2
    else
      echo "verify-m31: all checks passed"
    fi
    exit "$rc"

# ==============================================================================================
# M32 — the worker-hosted dev node.
#
#   just verify-m32-mainthread   smoke_worker_chain_survives_main_thread_block
#   just verify-m32-transferable test_worker_transferable_container_not_copied
#   just verify-m32-throttled    smoke_worker_produces_blocks_while_throttled
#   just verify-m32-restart      test_worker_restart_from_snapshot
#   just verify-m32              all four, in order
#
#   just m32-arms                re-measure the six worker arms into $M32_WORK/worker.json
#   just worker-serve            serve the worker demo page for a person to click
#
# WHAT THEY NEED, and none of it is new: M27's thirteen-overlay `avm.wasm` (`just avm-wasm-build-m27`,
# or AVM_WASM_PATH), M24's `ct_writer.wasm`, the built browser bundle — which now carries two more
# entry points, `worker.js` and `worker-demo.js`, out of the SAME esbuild pass — and a chromium
# (M32_CHROMIUM, default the one M27 finds). The checks reuse M27's module search, bundle predicate
# and chromium discovery unchanged; what M32 adds is its own arm run.
#
# THE ARMS ARE MEASURED ONCE into $M32_WORK/worker.json (default ~/.cache/aztec-m32-worker) and
# shared by all four checks, which is M20's convention. Six arms, each in its own page: `boot`,
# `workerBlocked`, `mainBlocked` (the CONTROL — the same load with the runtime on the main thread),
# `throttled`, `transferable` and `restart`. The whole run is about three minutes.
verify-m32-mainthread:
    @verification/smoke_worker_chain_survives_main_thread_block.sh

verify-m32-transferable:
    @verification/test_worker_transferable_container_not_copied.sh

verify-m32-throttled:
    @verification/smoke_worker_produces_blocks_while_throttled.sh

verify-m32-restart:
    @verification/test_worker_restart_from_snapshot.sh

# Re-measure the M32 worker arms into $M32_WORK/worker.json.
m32-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M32_WORK:-$HOME/.cache/aztec-m32-worker}"
    mkdir -p "$work"
    : "${AVM_WASM_PATH:=${M27_WORK:-$HOME/.cache/aztec-m27-browser}/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm}"
    export AVM_WASM_PATH
    node tools/run_worker_arms.mjs "$work" > "$work/worker.json"
    echo "m32-arms: wrote $work/worker.json"

# Serve the worker demo page for a person to click. Ctrl-C to stop.
worker-serve:
    @node tools/serve_browser_demo.mjs "${M32_WORK:-$HOME/.cache/aztec-m32-worker}/site"

verify-m32:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      smoke_worker_chain_survives_main_thread_block \
      test_worker_transferable_container_not_copied \
      smoke_worker_produces_blocks_while_throttled \
      test_worker_restart_from_snapshot
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m32: FAILED" >&2
    else
      echo "verify-m32: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# L0 — the node client, and what it is allowed to reach
#
# THE FIRST MILESTONE OF A DIFFERENT CAMPAIGN. `codetracer-specs/Planned-Work/
# Aztec-Live-Chain-Replay.milestones.org` produces a CodeTracer `.ct` recording from a transaction
# that has ALREADY SETTLED on a live Aztec chain. It shares this repository, this Justfile and
# CAMPAIGN-BRIEF.md's discipline with Aztec-AVM-Runtime, and almost nothing else: that campaign
# executes transactions it produced itself, this one executes transactions someone else produced.
# The recipes are prefixed `l0`/`l1`/… rather than `m<N>` so the two milestone series cannot be
# confused with each other.
#
#   just verify-l0-surface    verify_node_client_surface_narrow
#   just verify-l0-refusals   test_node_client_refusals_distinguishable
#   just verify-l0-schema     verify_client_uses_upstream_schema
#   just typecheck-replay     tsc over replay/, which is where the seam assertion lives
#   just verify-l0            all three, in order
#
# NOTHING HERE BUILDS AND NOTHING HERE NEEDS A NETWORK. Every arm runs against a fake node built
# out of upstream's OWN JSON-RPC server and upstream's own versioning middleware, over real HTTP on
# a loopback port the harness takes and releases itself. The one external requirement is the
# upstream fork's OBJECT STORE at `../aztec-packages`: the enumerations are re-derived with
# `git show <anchor>:<path>` on every run, which is the deliverable rather than a convenience, so a
# missing fork is a refusal and never a skip.
#
# `replay/node_modules` must be installed — the replay tree is on `npm.current`, NOT on
# `npm.deletion_era` like `orchestration/`, and the two are not interchangeable.
# ---------------------------------------------------------------------------

verify-l0-surface:
    @verification/verify_node_client_surface_narrow.sh

verify-l0-refusals:
    @verification/test_node_client_refusals_distinguishable.sh

verify-l0-schema:
    @verification/verify_client_uses_upstream_schema.sh

# The compiler is a check here: `replay/src/node_client.ts` ends with a type-level assertion that a
# replay client satisfies `MembershipWitnessSource`, the seam this campaign's L2 and the sibling
# campaign's M35 both answer. If one of the five witness methods leaves the permitted surface, this
# fails rather than L2 discovering it.
typecheck-replay:
    @cd replay && tsc -p tsconfig.json && echo "typecheck-replay: replay/ type-checks, seam assertion included"

verify-l0:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_node_client_surface_narrow \
      test_node_client_refusals_distinguishable \
      verify_client_uses_upstream_schema
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-l0: FAILED" >&2
    else
      echo "verify-l0: all checks passed"
    fi
    exit "$rc"

# ==============================================================================================
# M33 — the wallet protocol boundary.
#
#   just verify-m33-protocol     verify_wallet_protocol_is_upstreams
#   just verify-m33-dd9          verify_provider_half_dd9_clean
#   just verify-m33-null-wallet  test_null_wallet_refuses_by_name
#   just verify-m33-handshake    e2e_discovery_keyexchange_session
#   just verify-m33              all four, in order
#
#   just m33-arms                re-measure the seven wallet arms into $M33_WORK/wallet.json
#
# WHAT THEY NEED, AND IT IS LESS THAN M32's: the built browser bundle, which now carries a seventh
# entry point, `wallet.js`, out of the SAME esbuild pass. NO avm.wasm — and CHROMIUM for one arm
# only, which M33's review added. M32's arms had to be in a browser because their subject was a Web
# Worker, CPU throttling and `Page.setWebLifecycleState`; M33's subject is a `MessagePort` and
# WebCrypto, both of which Node 24 implements to the same specifications, so the HANDSHAKE arms
# import the built bundle and run in-process. That is a smaller claim than "it works in Chromium"
# and it is still stated as one in `WALLET-BOUNDARY.md` §5.
#
# WHAT CHROMIUM IS FOR IS THE ONE CLAIM NODE CANNOT MAKE: that a PAGE can evaluate `wallet.js`.
# `verify_provider_half_dd9_clean` §10 loads it in a real page and requires the exports the page
# sees to be the ones Node sees, with a served control whose copy carries one Node-only free
# identifier and must be REPORTED as a `ReferenceError`. It is there because M33 shipped with that
# half asserted on the esbuild metafile, and a free identifier is not an import: with
# `const _nodeOnlyProbe = setImmediate;` planted, `just verify-m33` was 224 / 4-of-4 / exit 0 and
# the same bundle died in Chromium.
#
# THE ARMS ARE MEASURED ONCE into $M33_WORK/wallet.json (default ~/.cache/aztec-m33-wallet) and
# shared by all four checks, which is M20's convention. Seven arms: `handshake`, `refusalsDirect`,
# `served` (the CONTROL that a permitted call reaches through), `wrongAppId`, `wrongWalletId`,
# `noApproval` (the bounded-wait arm) and `verificationHash`. The whole run is a few seconds.
verify-m33-protocol:
    @verification/verify_wallet_protocol_is_upstreams.sh

verify-m33-dd9:
    @verification/verify_provider_half_dd9_clean.sh

verify-m33-null-wallet:
    @verification/test_null_wallet_refuses_by_name.sh

verify-m33-handshake:
    @verification/e2e_discovery_keyexchange_session.sh

# Re-measure the M33 wallet arms into $M33_WORK/wallet.json.
m33-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M33_WORK:-$HOME/.cache/aztec-m33-wallet}"
    mkdir -p "$work"
    node tools/run_wallet_arms.mjs "$work" > "$work/wallet.json"
    echo "m33-arms: wrote $work/wallet.json"

verify-m33:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_wallet_protocol_is_upstreams \
      verify_provider_half_dd9_clean \
      test_null_wallet_refuses_by_name \
      e2e_discovery_keyexchange_session
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m33: FAILED" >&2
    else
      echo "verify-m33: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------
# L1 — fetching a settled transaction
#
#   just verify-l1-fetch       e2e_fetch_settled_transaction
#   just verify-l1-artifact    test_missing_contract_artifact_refused
#   just verify-l1-private     test_private_half_declared_absent
#   just verify-l1             all three, in order
#   just capture-replay-fixture  re-capture a fixture — THE ONE THING HERE THAT NEEDS A NETWORK
#
# NOTHING IN `verify-l1` TOUCHES THE NETWORK. Every arm runs over
# `replay/fixtures/*.json` — recordings of a live Aztec testnet taken at the JSON-RPC transport on
# 2026-08-29 — played back through THE REAL `createAztecNodeClient` over THE REAL
# `AztecNodeApiSchema`, so upstream's zod validates the committed bytes on every run. A fixture is a
# recording of a node, not a mock of one.
#
# `capture-replay-fixture` is the only recipe here that reaches a chain, and it is not part of
# `verify-l1` on purpose: a check that needs a live testnet is a check that goes red when somebody
# else's node is down. Re-capture is a deliberate act, and it must be, because `getTxByHash` on a
# real node PRUNES — see `replay/src/settled_transaction.ts` — so a fixture cannot be re-taken for
# an old transaction at all.
# ---------------------------------------------------------------------------

verify-l1-fetch:
    @verification/e2e_fetch_settled_transaction.sh

verify-l1-artifact:
    @verification/test_missing_contract_artifact_refused.sh

verify-l1-private:
    @verification/test_private_half_declared_absent.sh

# THE ONE RECIPE THAT NEEDS A LIVE CHAIN. `just capture-replay-fixture url=… out=… [tx=…]`
#
# `pin=1` puts the SETTLING BLOCK on the `getContract` wire call, which is how
# `testnet_settled_tx_refblock.json` was taken. WITHOUT this parameter that fixture could not be
# regenerated by any recipe — it would be frozen by an accident of the CLI rather than by the
# retention horizon, which is the only reason a fixture in this campaign is allowed to be frozen.
# L1's two ARE frozen, correctly: their transactions fell out of `getTxByHash` an hour after they
# settled and cannot be re-taken at all.
capture-replay-fixture url='https://aztec-testnet.drpc.org' out='replay/fixtures/testnet_settled_tx.json' tx='' pin='':
    #!/usr/bin/env bash
    set -uo pipefail
    args=(--url "{{url}}" --out "{{justfile_directory()}}/{{out}}")
    [ -n "{{tx}}" ] && args+=(--tx "{{tx}}")
    [ -n "{{pin}}" ] && args+=(--pin-reference-block)
    cd "{{justfile_directory()}}/replay" && node tools/capture_settled_fixture.mjs "${args[@]}"

verify-l1:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      e2e_fetch_settled_transaction \
      test_missing_contract_artifact_refused \
      test_private_half_declared_absent
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-l1: FAILED" >&2
    else
      echo "verify-l1: all checks passed"
    fi
    exit "$rc"

# =================================================================================================
# L2 — HISTORICAL STATE AT A BLOCK (Aztec-Live-Chain-Replay.milestones.org)
#
#   just replay-settled            replay the committed L2 fixture. NO NETWORK.
#   just capture-replay-run        drive a LIVE node and write a new L2 fixture
#
# THE MODULE IS AN ARGUMENT AND NOT A DEFAULT, and the reason is that the wrong one produces a
# named refusal rather than a wrong answer, which is worth keeping. `vm2wasm/avm.wasm` is M6's
# early spike artefact — it OWNS ITS MEMORY, and `node-host`'s loader refuses it by name
# (`AvmToolchainRegression`) because this host is for `--import-memory` modules. The module L2
# needs is a build with M9's execution-observer patch in it, which is what
# `$HOME/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm` is after
# `just ci-browser-gate`; an unpatched build refuses the encoding with
# "Missing field collectExecutionSteps" instead of running without steps.
#
# WHAT `replay-settled` PROVES, AND IT IS THE MILESTONE'S OWN SENTENCE: "re-execution reproducing
# the transaction's own recorded outcome — revertCode, gas consumed, and the side effects in the
# TxEffect the chain published". It exits non-zero when the comparison does not reproduce, so it is
# a check even before a check wraps it.
#
# NOTHING HERE TOUCHES A NETWORK except `capture-replay-run`, for `verify-l1`'s reason: the
# retention horizon means a check that needs a live testnet goes red on somebody else's schedule.
# ---------------------------------------------------------------------------

avm_wasm_default := env_var_or_default('AVM_WASM_PATH', env_var('HOME') + '/.cache/aztec-m27-browser/m27/barretenberg/cpp/build-wasm-avm/bin/avm.wasm')

#   just verify-l2-effects    e2e_replay_matches_published_effects
#   just verify-l2-roots      verify_hydrated_roots_match_state_reference
#   just verify-l2-routes     verify_state_route_decided_on_measurement
#   just verify-l2            all three, in order
#
# UNLIKE verify-l0 AND verify-l1, THESE NEED A BUILT MODULE, because L2 executes. A missing module
# is a `die` with a remedy and NEVER a skip — see lib_l2_replay.sh: a check that skips reads as a
# smaller milestone rather than a red one, which is this campaign's most-repeated defect wearing a
# friendlier word. Nothing here touches a network.

verify-l2-effects:
    @verification/e2e_replay_matches_published_effects.sh

verify-l2-roots:
    @verification/verify_hydrated_roots_match_state_reference.sh

verify-l2-routes:
    @verification/verify_state_route_decided_on_measurement.sh

verify-l2:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      e2e_replay_matches_published_effects \
      verify_hydrated_roots_match_state_reference \
      verify_state_route_decided_on_measurement
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-l2: FAILED" >&2
    else
      echo "verify-l2: all checks passed"
    fi
    exit "$rc"

replay-settled fixture='replay/fixtures/testnet_replay_tx.json' module=avm_wasm_default:
    #!/usr/bin/env bash
    set -uo pipefail
    if [ ! -s "{{module}}" ]; then
      echo "replay-settled: no AVM module at {{module}}." >&2
      echo "  Remedy: just ci-browser-gate (which builds it), or set AVM_WASM_PATH." >&2
      exit 2
    fi
    cd "{{justfile_directory()}}/replay" \
      && node tools/replay_settled_transaction.mjs \
           --fixture "{{justfile_directory()}}/{{fixture}}" --module "{{module}}"

# THE ONE L2 RECIPE THAT NEEDS A LIVE CHAIN. With no `tx=` it walks back from the tip, bounded by
# `getBlockNumber('finalized')` rather than by a guessed depth, and takes the first transaction that
# is FIRST IN ITS BLOCK — `IntraBlockPredecessorsUnavailable` is the refusal for the rest.
#   just verify-l3-steppable   e2e_settled_transaction_produces_steppable_ct
#   just verify-l3-provenance  test_recording_declares_its_provenance
#   just verify-l3             both, in order
#
# THESE NEED THE AVM MODULE, THE CT WRITER AND THE REFERENCE READER, and a missing one is a `die`
# with a remedy rather than a skip. The reader is not optional politeness: it refused three earlier
# forms of L3's own recording — `columns: true` at rung 3, a 23-character recording id, then a
# 36-character one that was UUID-SHAPED and not a UUIDv7 — every one of which the writer had
# happily produced bytes for.
#
# THE THIRD CHECK THE MILESTONE NAMES, `test_reverted_transaction_recorded_as_reverted`, IS NOT
# HERE, and its absence is a measurement rather than an omission: no reverted settled transaction
# exists to write it over. See `just scan-reverted-transactions` and pins.json.

verify-l3-steppable:
    @verification/e2e_settled_transaction_produces_steppable_ct.sh

verify-l3-provenance:
    @verification/test_recording_declares_its_provenance.sh

verify-l3:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      e2e_settled_transaction_produces_steppable_ct \
      test_recording_declares_its_provenance
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-l3: FAILED" >&2
    else
      echo "verify-l3: all checks passed"
    fi
    exit "$rc"

# =================================================================================================
# L4 — THE BROWSER HALF (Aztec-Live-Chain-Replay.milestones.org)
#
#   just build-replay-browser-bundle   the replay client, bundled for a browser
#   just verify-browser-replay-dd9     verify_browser_replay_dd9_clean — ON THE BUILT ARTIFACT
#   just mirror-replay-engine          fetch the published replay engine into a local directory
#   just open-container-in-engine      open an L3 container in a real headless browser AND STEP IT
#
# THE BUNDLE IS BUILT IN ITS OWN esbuild PASS, not added to `browser/build.mjs`'s. Two reasons, and
# the first is about other people: adding an entry to that pass moves every chunk boundary and every
# figure in BROWSER-PACKAGING.md — that document records it happening three times — and doing so
# from a different campaign while that campaign is being worked on is the contention hazard this
# campaign's milestone file warns about. The second is that it COULD NOT share the pass anyway:
# `browser/` resolves @aztec through orchestration's install (deletion_era) and replay is on
# npm.current, and an `Fr` from the wrong install serialises as a plain object.
#
# `open-container-in-engine` MIRRORS THE ENGINE LOCALLY, and that is a constraint rather than a
# convenience: `new Worker(url, {type:'module'})` throws SecurityError on a cross-origin script URL,
# which is why BlockTracer vendors the engine into its own origin, and the same applies to any page
# that wants to drive it.
# ---------------------------------------------------------------------------

#   just verify-l4                 THE OFFLINE FLOOR — the two checks that need no chain
#   just verify-l4-net             THE NETWORK CHECK — needs a live Aztec node, EVERY RUN
#
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# THE SWEEP DECISION, MADE EXPLICITLY RATHER THAN DEFAULTED.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
#
# L4 has checks of two kinds and they must not be summed into one number, because one of them can
# go red for a reason that has nothing to do with this repository.
#
#   OFFLINE, and therefore part of the floor — `just verify-l4`:
#     verify_browser_replay_dd9_clean            builds the bundle from local sources
#     smoke_browser_opens_and_steps_l3_container drives a local browser over a local origin
#
#   NEEDS A LIVE CHAIN ON EVERY RUN, and therefore NOT part of the floor — `just verify-l4-net`:
#     the range over the replayable window
#
# `verify-l1`'s header states the rule this follows: "a check that needs a live testnet is a check
# that goes red on somebody else's schedule". The range check is worse than L1's capture in one
# respect — the WINDOW ITSELF is a property of the chain at the moment it is read, so there is no
# fixture of it that would not be a fixture of a moment, and the transaction count it finds is
# whatever the chain happened to contain. A run that finds zero transactions is not a failure of
# this code.
#
# SO IT IS A SEPARATE RECIPE WITH A SEPARATE NAME, and `verify-l4` does not call it. The wrong
# resolutions, named so they are not re-proposed: folding it in makes the floor depend on a third
# party; making it skip when the network is down makes it read as a smaller milestone; and pinning
# a window fixture makes it assert over a moment that has passed.
#
# ONE MORE PRECONDITION IS A NETWORK ACT AND IT IS A DELIBERATE ONE.
# `smoke_browser_opens_and_steps_l3_container` needs the published replay engine MIRRORED. The
# mirror is `just mirror-replay-engine`, run once; the check DIES with that remedy rather than
# fetching somebody else's deployment behind your back, and rather than skipping.
# ---------------------------------------------------------------------------

verify-l4:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_browser_replay_dd9_clean \
      smoke_browser_opens_and_steps_l3_container
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-l4: FAILED" >&2
    else
      echo "verify-l4: all checks passed"
    fi
    exit "$rc"

# THE NETWORK ONE. Deliberately not in `verify-l4`, and it announces itself so a green line from it
# can never be mistaken for part of the offline floor.
verify-l4-net url='https://aztec-testnet.drpc.org' module=avm_wasm_default:
    #!/usr/bin/env bash
    set -uo pipefail
    echo "=== verify-l4-net: THIS CHECK NEEDS A LIVE AZTEC NODE ({{url}})."
    echo "    It is NOT part of the offline floor. A run that finds no transactions in the"
    echo "    replayable window DIES naming that, because every assertion would be vacuous over"
    echo "    an empty table — it is a fact about the chain, not a failure of this code."
    L4_RANGE_URL="{{url}}" AVM_WASM_PATH="{{module}}" verification/e2e_replay_block_range.sh

verify-browser-opens-and-steps:
    @verification/smoke_browser_opens_and_steps_l3_container.sh

build-replay-browser-bundle:
    @node replay/tools/build_browser_bundle.mjs

verify-browser-replay-dd9:
    @verification/verify_browser_replay_dd9_clean.sh

# The published engine's three files. Recorded with their statuses because "the engine is at that
# path" is a claim about somebody else's deployment: the DIRECTORY itself 404s and only the files
# under it serve, so a probe of the path the page NAMES would conclude the engine is absent.
mirror-replay-engine dir='/tmp/l4engine' base='https://blocktracer.org/replay-engine':
    #!/usr/bin/env bash
    set -uo pipefail
    mkdir -p "{{dir}}/pkg"
    rc=0
    for f in worker.js pkg/db_backend.js pkg/db_backend_bg.wasm; do
      code=$(curl -s -o "{{dir}}/$f" -w '%{http_code}' -m 120 "{{base}}/$f")
      echo "  {{base}}/$f -> $code  $(wc -c <"{{dir}}/$f" | tr -d ' ') bytes"
      [ "$code" = 200 ] || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "mirror-replay-engine: at least one file did not serve" >&2
      exit 1
    fi
    echo "mirror-replay-engine: mirrored into {{dir}}"

# THE ACCEPTANCE CRITERION IS STEPS TAKEN AND POSITIONS REACHED, not that it loaded. Exits non-zero
# when the container loads and cannot be stepped, because that is a finding rather than a pass.
open-container-in-engine container='/tmp/aztec-replay.ct' engine='/tmp/l4engine' steps='400':
    #!/usr/bin/env bash
    set -uo pipefail
    node tools/open_container_in_engine.mjs --container "{{container}}" --engine "{{engine}}" \
      --steps "{{steps}}"

# =================================================================================================
# L4 — RANGE REPLAY (Aztec-Live-Chain-Replay.milestones.org)
#
#   just replay-window                   every replayable transaction, with the outcome table
#   just replay-window url out below=40  …reaching BELOW the finalized tip, which is the CONTROL
#                                        that demonstrates isolation
#
# THE RANGE IS THE REPLAYABLE WINDOW AND IS NOT A PARAMETER. `replay/src/range.ts` says why: the
# window's two ends are `getBlockNumber('finalized') + 1` and `getBlockNumber()`, both already on
# L0's permitted fourteen, and anything older is unreplayable by construction. Measured on
# 2026-08-30: testnet's window was 32 blocks holding 3 transactions, mainnet's 41 holding 1 — so a
# demo-shaped range is tens of blocks and a handful of transactions, which is what the chain
# contains rather than a limitation of this code.
#
# THIS IS THE ONE L4 RECIPE AND IT NEEDS A LIVE CHAIN. The window is a property of the chain at the
# moment it is read; a fixture of it would be a fixture of a moment.
# ---------------------------------------------------------------------------

replay-window url='https://aztec-testnet.drpc.org' module=avm_wasm_default below='' max='':
    #!/usr/bin/env bash
    set -uo pipefail
    if [ ! -s "{{module}}" ]; then
      echo "replay-window: no AVM module at {{module}}. Remedy: just ci-browser-gate" >&2
      exit 2
    fi
    args=(--url "{{url}}" --module "{{module}}")
    [ -n "{{below}}" ] && args+=(--reach-below-finalized "{{below}}")
    [ -n "{{max}}" ] && args+=(--max "{{max}}")
    cd "{{justfile_directory()}}/replay" && node tools/replay_window.mjs "${args[@]}"

# THE MEASUREMENT THAT KEEPS test_reverted_transaction_recorded_as_reverted HONESTLY PENDING.
# It needs a settled transaction that REVERTED, and none exists to be found. Committed so the claim
# is re-runnable rather than quoted: a scan is a measurement of a chain at the moment it ran.
scan-reverted-transactions url='https://aztec-testnet.drpc.org' from='' to='':
    #!/usr/bin/env bash
    set -uo pipefail
    cd "{{justfile_directory()}}/replay" \
      && node ../tools/scan_reverted_transactions.mjs --url "{{url}}" \
           {{ if from == "" { "" } else { "--from " + from } }} \
           {{ if to == "" { "" } else { "--to " + to } }}

# L3 — THE RECORDING. Produces a `.ct` from the committed fixture and, with `read=1`, parses it with
# the REFERENCE READER, which is the standard a container is held to here. `ct-print` refused two
# earlier forms of the recording id — "expected 36 chars, got 23", then "not a UUIDv7" — so "the
# writer returned bytes" is demonstrably not the same claim as "this is a container".
replay-record out='/tmp/aztec-replay.ct' fixture='replay/fixtures/testnet_replay_tx.json' module=avm_wasm_default read='':
    #!/usr/bin/env bash
    set -uo pipefail
    W="{{justfile_directory()}}/ct-writer/target/wasm32-unknown-unknown/release/aztec_ct_writer.wasm"
    if [ ! -s "$W" ]; then
      echo "replay-record: no ct_writer.wasm at $W. Remedy: just ct-writer-build" >&2
      exit 2
    fi
    cd "{{justfile_directory()}}/replay" \
      && node tools/replay_settled_transaction.mjs \
           --fixture "{{justfile_directory()}}/{{fixture}}" --module "{{module}}" \
           --ct "{{out}}" --ct-writer "$W" || exit 1
    if [ -n "{{read}}" ]; then
      R="${HOME}/.cache/aztec-m24-ctprint/ct-print"
      [ -x "$R" ] || { echo "replay-record: no ct-print. Remedy: just ct-print-build" >&2; exit 2; }
      "$R" --full "{{out}}" >/dev/null || { echo "replay-record: the reference reader REFUSED {{out}}" >&2; exit 1; }
      echo "replay-record: the reference reader parsed {{out}}"
    fi

capture-replay-run url='https://aztec-testnet.drpc.org' out='replay/fixtures/testnet_replay_tx.json' tx='' module=avm_wasm_default:
    #!/usr/bin/env bash
    set -uo pipefail
    args=(--url "{{url}}" --capture "{{justfile_directory()}}/{{out}}" --module "{{module}}")
    [ -n "{{tx}}" ] && args+=(--tx "{{tx}}")
    cd "{{justfile_directory()}}/replay" && node tools/replay_settled_transaction.mjs "${args[@]}"

# =================================================================================================
# M34 — THE CODETRACER DEV WALLET (PUBLIC ENTRYPOINTS)
# =================================================================================================
#
#   just verify-m34-transfer     e2e_wallet_public_transfer
#   just verify-m34-keys         test_wallet_keys_deterministic
#   just verify-m34-deployment   test_deployment_through_wallet
#   just verify-m34-trace        verify_wallet_decisions_appear_in_trace
#   just verify-m34              all four, in order
#
# WHAT THEY NEED: the built browser bundle (which now carries an EIGHTH entry point,
# `wallet-demo.js`, out of the same esbuild pass), `avm.wasm` with M27's crypto exports,
# `ct_writer.wasm`, the Token artifact, the PINNED `ct-print`, and CHROMIUM.
#
# CHROMIUM IS NOT OPTIONAL HERE, AND THAT IS THE OPPOSITE OF M33'S CHOICE. M33's arms ran in Node
# because its subject was a `MessagePort` and WebCrypto, which Node 24 implements to the same
# specifications a browser does — and M33's review then measured what that cannot say, by planting
# one Node-only free identifier and getting 224 assertions, 4/4, exit 0 over a bundle that died in
# Chromium. M34 ships a WALLET rather than a protocol, so the wallet is LOADED AND EXERCISED in a
# browser: the handshake, the ECDH, the AES-256-GCM session, the deterministic key derivation
# through `avm.wasm`'s own grumpkin, the vendored transaction builder, the AVM and the `.ct` writer
# all run there, and the container the page downloads is read back by the pinned reader.
#
# THE ARMS ARE MEASURED ONCE into $M34_WORK/wallet-transfer.json (default ~/.cache/aztec-m34-wallet)
# and shared by all four checks, which is M20's convention. Seven arms: `transfer` (the subject),
# `declined` (a wallet that refuses to authorize), `refusals` (every unserved method, by name),
# `keys` (the deterministic derivation), `record` (the container), `suppressed` (the ledger's
# control) and `shortcut` (the direct store write, still working and still labelled).
verify-m34-transfer:
    @verification/e2e_wallet_public_transfer.sh

verify-m34-keys:
    @verification/test_wallet_keys_deterministic.sh

verify-m34-deployment:
    @verification/test_deployment_through_wallet.sh

verify-m34-trace:
    @verification/verify_wallet_decisions_appear_in_trace.sh

# Re-measure the M34 wallet arms into $M34_WORK/wallet-transfer.json.
m34-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M34_WORK:-$HOME/.cache/aztec-m34-wallet}"
    mkdir -p "$work"
    node tools/run_wallet_transfer_arms.mjs "$work" > "$work/wallet-transfer.json"
    echo "m34-arms: wrote $work/wallet-transfer.json"

verify-m34:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      e2e_wallet_public_transfer \
      test_wallet_keys_deterministic \
      test_deployment_through_wallet \
      verify_wallet_decisions_appear_in_trace
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m34: FAILED" >&2
    else
      echo "verify-m34: all checks passed"
    fi
    exit "$rc"

# ---------------------------------------------------------------------------------------------
# M35 — Private Execution Inside the Wallet.
#
# Three checks, all reading ONE browser arm run:
#
#   verify_oracle_coverage_is_measured          the 68-entry registry re-derived from the anchor's
#                                               object store, the vendored copy and the built
#                                               bundle, with the 53-entry `upstream/tsavm` worktree
#                                               as the control that the derivation can tell two
#                                               registries apart; the implemented and refusing sets
#                                               disjoint, summing, and every implemented one
#                                               EXERCISED
#   test_unimplemented_oracle_refuses_by_name   every refused oracle names itself, three ways, the
#                                               third being a real 76,875-byte private circuit that
#                                               stops at the first oracle M35 does not serve
#   e2e_private_function_executes_in_browser    a real private function solving in Chromium, with
#                                               the ACVM's 4.4 MB fetched only when asked for
#
# NEEDS: a built browser bundle (`just browser-build`), `avm.wasm` (`just avm-wasm-build-m27`),
# `ct_writer.wasm`, chromium on PATH, and `@aztec/noir-acvm_js` installed
# (`cd orchestration && npm ci`).
#
# `M35_ARMS_REFRESH=1` forces the arm run even when nothing is newer than the report.
verify-m35-coverage:
    @verification/verify_oracle_coverage_is_measured.sh

verify-m35-refusals:
    @verification/test_unimplemented_oracle_refuses_by_name.sh

verify-m35-executes:
    @verification/e2e_private_function_executes_in_browser.sh

m35-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M35_WORK:-$HOME/.cache/aztec-m35-private}"
    mkdir -p "$work"
    node tools/run_private_execution_arms.mjs "$work" > "$work/private-execution.json"
    echo "m35-arms: wrote $work/private-execution.json"

# M36. Note discovery and tagging, over the dev node's own history.
#
# NEEDS: a built browser bundle (`just browser-build`), `avm.wasm` (`just avm-wasm-build-m27`),
# `ct_writer.wasm`, chromium on PATH, and `@aztec/noir-acvm_js` installed.
#
# `M36_ARMS_REFRESH=1` forces the arm run even when nothing is newer than the report.
m36-arms:
    #!/usr/bin/env bash
    set -uo pipefail
    work="${M36_WORK:-$HOME/.cache/aztec-m36-notes}"
    mkdir -p "$work"
    node tools/run_note_discovery_arms.mjs "$work" > "$work/note-discovery.json"
    echo "m36-arms: wrote $work/note-discovery.json"

verify-m36-discovery:
    @verification/e2e_note_discovery_across_blocks.sh

verify-m36-tagging:
    @verification/test_tagging_index_advances.sh

verify-m36-boundary:
    @verification/verify_local_history_boundary_declared.sh

verify-m36:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      e2e_note_discovery_across_blocks \
      test_tagging_index_advances \
      verify_local_history_boundary_declared
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m36: FAILED" >&2
    else
      echo "verify-m36: all checks passed"
    fi

verify-m35:
    #!/usr/bin/env bash
    set -uo pipefail
    rc=0
    for check in \
      verify_oracle_coverage_is_measured \
      test_unimplemented_oracle_refuses_by_name \
      e2e_private_function_executes_in_browser
    do
      echo "=== $check"
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m35: FAILED" >&2
    else
      echo "verify-m35: all checks passed"
    fi
    exit "$rc"
