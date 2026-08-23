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
# $TMPDIR/aztec-m7-vm2-tests) carrying the four AVM_WASM series patches plus M7's
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
      verification/"$check".sh || rc=1
    done
    if [ "$rc" -ne 0 ]; then
      echo "verify-m9: FAILED" >&2
    else
      echo "verify-m9: all checks passed"
    fi
    exit "$rc"

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
rebase-upstream-patches:
    @python3 tools/rebase_upstream_patches.py --json carry/rebase.json

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
      test_avm_reactor_transcripts_match_driver
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
