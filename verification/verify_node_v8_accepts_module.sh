#!/usr/bin/env bash
# verify_node_v8_accepts_module — M17.
#
# THE PINNED NODE'S V8 COMPILES avm.wasm INCLUDING ITS EXCEPTION HANDLING, AND THE GUARD THAT SAYS
# SO IS SHOWN TO BE ABLE TO FAIL.
#
# The milestone's deliverable is "the V8 try_table requirement asserted at load, so a toolchain flag
# regression fails loudly on the pinned Node version", and its verification entry adds "and rejects
# a legacy-encoded build so the guard is known to work".
#
# MEASURED, AND THE PREMISE IS FALSE ON THIS NODE. Node 24.19.0 carries V8 13.6.233.17-node.51,
# whose `--experimental-wasm-legacy-eh` DEFAULTS TO ON: a hand-encoded legacy module both validates
# and RUNS. So the engine as invoked does NOT reject a legacy-encoded build, and a check that
# loaded avm.wasm and concluded "therefore try_table" would be a check that could not fail. Both
# halves are asserted here: the default engine's acceptance of both encodings is recorded as the
# finding it is, and the discriminating run is made with legacy support switched off, where the
# legacy probe is refused BY NAME (`Invalid opcode 0x06`) and avm.wasm still compiles.
#
# TWO REGRESSIONS ARE GUARDED AND THEY ARE NOT THE SAME ONE:
#
#   * exceptions COMPILED OUT — barretenberg's old `BB_NO_EXCEPTIONS` shim, under which every C++
#     throw becomes `std::abort()` and therefore every AVM revert becomes a trap. Observable as the
#     absence of a tag section, and the loader's gate refuses it. A hand-built module with no tag
#     section is the negative control, so the green verdict on the real module is a discrimination.
#   * the LEGACY ENCODING — which works today and would stop working on an engine that has dropped
#     it. Discriminated with legacy support off.
#
# THIS IS ALSO THE CHECK THAT BUILDS. It prepares M12's nine-patch tree inside M17's own work
# directory, builds the wasm and native halves, produces the driver's inputs and the native
# reference transcript, and writes `m17-measured.env`. Every other M17 check reads that record and
# runs this one if it is not there — never invents, defaults or skips.
#
# Run: just verify-node-gate

TEST_NAME="verify_node_v8_accepts_module"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"

note "work directory: $M17_WORK   (override with M17_WORK=...)"

command -v node >/dev/null 2>&1 || note "node comes from the dev shell; the host's is not used"

# ---------------------------------------------------------------------------
echo "== 1. the tree, and both builds, with their statuses asserted separately"
# ---------------------------------------------------------------------------
# NOT `TREE="$(m12_tree)"`: a command substitution runs in a subshell, so `m12_tree`'s own
# `export M12_TREE` would be discarded and every `m12_wasm_bin` afterwards would build a path out of
# an unset variable. M12's own checks call it this way for exactly that reason.
m12_tree >/dev/null
TREE="$M12_TREE"
assert_dir "the nine-patch tree is prepared" "$TREE"

m12_build_wasm "$TREE"
assert_eq "the wasm configure exits 0" 0 "$M12_WASM_CONFIGURE_RC"
assert_eq "the wasm build exits 0" 0 "$M12_WASM_BUILD_RC"
m12_build_native "$TREE"
assert_eq "the native configure exits 0" 0 "$M12_NATIVE_CONFIGURE_RC"
assert_eq "the native build exits 0" 0 "$M12_NATIVE_BUILD_RC"

WASM="$(m12_wasm_bin avm.wasm)"
NATIVE_DRIVER="$(m12_native_bin avm_differential)"
m8_require_artifacts "$WASM" "$NATIVE_DRIVER"

# The driver's own inputs and the native reference transcript. Both come from upstream's msgpack
# packers in C++; this package decodes and never encodes.
m9_run_native "$NATIVE_DRIVER" "$(m17_native_transcript)" "$M17_WORK/native.transcript.err"
assert_eq "the native driver produces its transcript" 0 $?
m9_run_native "$NATIVE_DRIVER" "$(m17_inputs)" "$M17_WORK/reactor-inputs.err" reactorinputs
assert_eq "the native driver's reactorinputs mode runs" 0 $?
assert_ge "the native transcript carries the driver's result lines" 100 \
  "$(grep -c '^program\.' "$(m17_native_transcript)")"

# ---------------------------------------------------------------------------
echo "== 2. the package type-checks, with the nix-pinned compiler and no npm dependency"
# ---------------------------------------------------------------------------
TSC_OUT="$(m17_tsc_project)"
TSC_RC=$?
assert_eq "tsc accepts the whole package" 0 "$TSC_RC"
[ "$TSC_RC" -eq 0 ] || note "$TSC_OUT"
# Not a lint step: `erasableSyntaxOnly` is what makes "it type-checks" imply "node can run it",
# because Node runs these sources by stripping types and cannot erase an enum or a namespace.
assert_contains "the project is configured so that type-checking implies node can run it" \
  '"erasableSyntaxOnly": true' "$(cat "$M17_PKG/tsconfig.json")"
assert_contains "…and there is no emit step whose output could drift from the sources" \
  '"noEmit": true' "$(cat "$M17_PKG/tsconfig.json")"
# No npm dependency at all — the reuse decision's other half.
PKG_JSON="$(cat "$M17_PKG/package.json")"
assert_not_contains "the package declares no dependencies" '"dependencies"' "$PKG_JSON"
assert_not_contains "…and no devDependencies either" '"devDependencies"' "$PKG_JSON"
assert_false "there is no node_modules under the package" test -e "$M17_PKG/node_modules"
# The engine probe is inside the package, so the project type-check above already covered it. That
# it is there rather than beside the checks is asserted, because a probe outside the package would
# be the one file whose type errors nobody sees.
assert_file "the engine probe is inside the package tsc checks" "$M17_ENGINE_PROBE"
assert_true "…and the project include covers it" \
  bash -c 'grep -q "\"src/\*\*/\*.ts\"" "$1"' bash "$M17_PKG/tsconfig.json"

# ---------------------------------------------------------------------------
echo "== 3. the engine, on the plain interpreter: it accepts BOTH encodings"
# ---------------------------------------------------------------------------
run_probe() { # <label> <node-flags>
  # Separate `local` statements: bash expands every word of a single `local a=1 b=$a` BEFORE
  # running it, so `out="$M17_WORK/engine-$label.txt"` on the same line saw an unset `label` and
  # died under `set -u`, leaving no probe output and eighteen downstream failures.
  local label="$1"
  local flags="$2"
  local out="$M17_WORK/engine-$label.txt"
  # `bash -c '<script>' <argv0> <arg1> <arg2>` — $0 is the name, $1 and $2 are the arguments; no
  # `shift` (an earlier draft had one, which silently ran the probe with the module as its argv0).
  ( cd "$FORK_ROOT" && nix develop --command bash -c \
      "node $flags \"\$1\" \"\$2\"" bash "$M17_ENGINE_PROBE" "$WASM" \
  ) >"$out" 2>"$M17_WORK/engine-$label.err"
  printf '%s' "$out"
}

DEFAULT_PROBE="$(run_probe default "")"
assert_eq "the engine probe on the default interpreter is complete" \
  "complete" "$(m17_completeness "$DEFAULT_PROBE" probe)"
note "engine: node $(m17_field "$DEFAULT_PROBE" engine.node), V8 $(m17_field "$DEFAULT_PROBE" engine.v8)"
assert_prefix "the pinned Node is v24" "v24." "$(m17_field "$DEFAULT_PROBE" engine.node)"
assert_eq "the default engine accepts the final try_table encoding" \
  "1" "$(m17_field "$DEFAULT_PROBE" engine.acceptsTryTable)"
# THE FINDING. The deliverable expected this to be 0.
assert_eq "…and it ALSO accepts the legacy encoding, so loading alone proves nothing" \
  "1" "$(m17_field "$DEFAULT_PROBE" engine.acceptsLegacyEh)"
assert_eq "avm.wasm compiles on the default engine" \
  "(compiled)" "$(m17_field "$DEFAULT_PROBE" module.compile)"

# ---------------------------------------------------------------------------
echo "== 4. the discriminating run: legacy support off"
# ---------------------------------------------------------------------------
STRICT_PROBE="$(run_probe strict "$M17_V8_LEGACY_EH_OFF")"
assert_eq "the engine probe with legacy support off is complete" \
  "complete" "$(m17_completeness "$STRICT_PROBE" probe)"
assert_eq "with legacy support off the engine still accepts try_table" \
  "1" "$(m17_field "$STRICT_PROBE" engine.acceptsTryTable)"
assert_eq "…and now REJECTS the legacy encoding" \
  "0" "$(m17_field "$STRICT_PROBE" engine.acceptsLegacyEh)"
# By name, not by "it did not load": a module rejected for a different reason would look the same.
assert_contains "…naming the legacy opcode it refused" \
  "Invalid opcode 0x06" "$(m17_field "$STRICT_PROBE" engine.legacyProbeCompile)"
assert_eq "the try_table probe still compiles there" \
  "(compiled)" "$(m17_field "$STRICT_PROBE" engine.tryTableProbeCompile)"
# THE STATEMENT THIS CHECK IS ENTITLED TO MAKE.
assert_eq "avm.wasm compiles on an engine that refuses the legacy encoding, so it uses try_table" \
  "(compiled)" "$(m17_field "$STRICT_PROBE" module.compile)"
# The two runs differ, or the second one measured the first one again.
assert_true "the two engine runs differ, so the flag did something" \
  test "$(m17_field "$DEFAULT_PROBE" engine.acceptsLegacyEh)" != "$(m17_field "$STRICT_PROBE" engine.acceptsLegacyEh)"
assert_eq "…and they agree about the engine, so the difference is the flag and not the binary" \
  "$(m17_field "$DEFAULT_PROBE" engine.v8)" "$(m17_field "$STRICT_PROBE" engine.v8)"

# ---------------------------------------------------------------------------
echo "== 5. the OTHER regression: exceptions compiled out, with its own control"
# ---------------------------------------------------------------------------
assert_eq "avm.wasm carries an exception tag section, so exceptions are compiled in" \
  "1" "$(m17_field "$DEFAULT_PROBE" module.hasTagSection)"
assert_eq "the loader's gate accepts it" "accepted" "$(m17_field "$DEFAULT_PROBE" gate.onRealModule)"
# The control: a module with no tag section is a VALID module the engine is happy with, and the
# gate must still refuse it. Both halves are asserted, because "the gate refused something the
# engine also refused" would say nothing about the gate.
assert_eq "the control module is one the engine itself accepts" \
  "1" "$(m17_field "$DEFAULT_PROBE" control.noTagModuleCompiles)"
assert_eq "…and it genuinely has no tag section" \
  "0" "$(m17_field "$DEFAULT_PROBE" control.noTagModuleHasTagSection)"
assert_eq "…and the gate refuses it as a toolchain regression" \
  "toolchain-regression" "$(m17_field "$DEFAULT_PROBE" control.gateOnNoTagModule)"

# ---------------------------------------------------------------------------
echo "== 6. the twelve imports, satisfied — read from the ARTEFACT and from the MODULE"
# ---------------------------------------------------------------------------
m17_run imports "$(m17_out imports)" "$(m17_err imports)"
assert_eq "the imports mode runs" 0 $?
assert_eq "…and its transcript is complete" "complete" "$(m17_completeness "$(m17_out imports)" imports)"
assert_eq "the module declares twelve imports" "12" "$(m17_field "$(m17_out imports)" imports.count)"
assert_eq "…eleven of them WASI" "11" "$(m17_field "$(m17_out imports)" imports.wasiCount)"
assert_eq "…and exactly one that is not" "1" "$(m17_field "$(m17_out imports)" imports.nonWasiCount)"

# The eleven names are READ OUT OF REACTOR-ABI.md rather than restated in this check, because the
# milestone says in as many words not to restate M12's list from memory. Both sides are then
# non-empty by assertion, so a comparison of two empty sets cannot pass.
ABI_NAMES="$(m17_reactor_abi_wasi_imports)"
MODULE_NAMES="$(grep -oE '^imports\.[0-9]+ wasi_snapshot_preview1\.[a-z_]+$' "$(m17_out imports)" \
  | sed 's/.*wasi_snapshot_preview1\.//' | LC_ALL=C sort -u)"
assert_eq "REACTOR-ABI.md's own table lists eleven WASI imports" \
  "11" "$(printf '%s\n' "$ABI_NAMES" | grep -c .)"
assert_eq "…and the module declares eleven" "11" "$(printf '%s\n' "$MODULE_NAMES" | grep -c .)"
assert_eq "the module's WASI imports are exactly the artefact's, name for name" \
  "$ABI_NAMES" "$MODULE_NAMES"
assert_eq "the one non-WASI import is env.memory" \
  "env.memory" "$(grep -oE '^imports\.[0-9]+ env\.memory$' "$(m17_out imports)" | awk '{print $2}')"

# The declared minimum, on BOTH sides: the artefact's recorded figure and the module's own header.
ABI_MIN="$(m17_reactor_abi_declares_min_pages)"
assert_eq "REACTOR-ABI.md records the declared minimum" "$M17_DECLARED_MIN_PAGES" "$ABI_MIN"
assert_eq "…and the loader instantiates at exactly that many pages" \
  "$ABI_MIN" "$(m17_field "$(m17_out imports)" imports.pagesAtStart)"
assert_eq "the instance is live, not merely constructed" \
  "1" "$(m17_field "$(m17_out imports)" imports.instantiated)"
assert_ge "…and it answers its own ABI version" 1 "$(m17_field "$(m17_out imports)" imports.abiVersion)"

# ---------------------------------------------------------------------------
echo "== 7. the gate mode's own report, including the memory floor"
# ---------------------------------------------------------------------------
m17_run gate "$(m17_out gate)" "$(m17_err gate)"
assert_eq "the gate mode runs" 0 $?
assert_eq "…and its transcript is complete" "complete" "$(m17_completeness "$(m17_out gate)" gate)"
assert_eq "the gate reads the memory import as env.memory" \
  "env.memory" "$(m17_field "$(m17_out gate)" gate.memory.importedAs)"
assert_eq "…with the declared minimum the artefact records" \
  "$M17_DECLARED_MIN_PAGES" "$(m17_field "$(m17_out gate)" gate.memory.minPages)"
assert_eq "…and it is not a shared memory, so this is not a threads build" \
  "0" "$(m17_field "$(m17_out gate)" gate.memory.shared)"
# A memory below the declared minimum is refused by the LOADER, with a message about the minimum,
# rather than by a LinkError that reads like a toolchain problem.
assert_eq "a memory below the declared minimum is refused by the loader, not by a LinkError" \
  "toolchain-regression" "$(m17_field "$(m17_out gate)" gate.memory.belowMinimumRefusedAs)"

# ---------------------------------------------------------------------------
echo "== 8. the check set is wired into CI, stated precisely"
# ---------------------------------------------------------------------------
WF="$REPO_ROOT/.github/workflows/avm-wasm.yml"
assert_file "the AVM_WASM workflow exists" "$WF"
WF_TXT="$(cat "$WF")"
assert_contains "…and it has a job for the node host" "  node-host:" "$WF_TXT"
assert_contains "…which runs the whole M17 set" "just verify-m17" "$WF_TXT"
assert_contains "…in its own work directory, not M12's" "M17_WORK: " "$WF_TXT"
assert_contains "…after installing the packages the reuse enumeration reads" \
  "the reuse enumeration reads them" "$WF_TXT"
assert_contains "…and asserts M17's own inputs before running anything" \
  "missing M17 input" "$WF_TXT"
# Structure, not text: a job named in a comment is not a job.
YAML_JOBS=""
if command -v yq >/dev/null 2>&1; then
  YAML_JOBS="$(yq -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
elif command -v nix >/dev/null 2>&1; then
  YAML_JOBS="$(nix shell nixpkgs#yq-go --command yq -r '.jobs | keys | join(" ")' "$WF" 2>/dev/null)"
fi
if [ -n "$YAML_JOBS" ]; then
  assert_contains "the workflow parses as YAML and declares the M17 job as a job" "node-host" "$YAML_JOBS"
  assert_contains "…alongside M16's, which it must not have displaced" "fallback-triggers" "$YAML_JOBS"
  assert_contains "…and M12's, which builds the same tree in a different directory" "avm-reactor" "$YAML_JOBS"
  assert_not_contains "…and it does not declare a job M17 never added" "node-host-browser" "$YAML_JOBS"
else
  fail "no YAML parser was available, so the workflow's structure could not be asserted"
fi
# AND WHAT IT DOES NOT MEAN. Neither this job nor any other in this workflow has ever run: they all
# abort at `Generate CI token` on "Input required and not supplied: app-id", which M11 recorded as
# undiagnosed. The job existing means it is wired and names the checks.
assert_contains "the job says plainly that it has never run" "this job has never run" "$WF_TXT"

# ---------------------------------------------------------------------------
# The record every other M17 check reads.
# ---------------------------------------------------------------------------
{
  printf 'M17_TREE=%s\n' "$TREE"
  printf 'M17_WASM=%s\n' "$WASM"
  printf 'M17_ENGINE_V8=%s\n' "$(m17_field "$DEFAULT_PROBE" engine.v8)"
  printf 'M17_ENGINE_NODE=%s\n' "$(m17_field "$DEFAULT_PROBE" engine.node)"
  printf 'M17_DEFAULT_ACCEPTS_LEGACY=%s\n' "$(m17_field "$DEFAULT_PROBE" engine.acceptsLegacyEh)"
  printf 'M17_STRICT_ACCEPTS_LEGACY=%s\n' "$(m17_field "$STRICT_PROBE" engine.acceptsLegacyEh)"
  printf 'M17_IMPORT_COUNT=%s\n' "$(m17_field "$(m17_out imports)" imports.count)"
  printf 'M17_MIN_PAGES=%s\n' "$(m17_field "$(m17_out gate)" gate.memory.minPages)"
} >"$(m17_measured_env)"
note "measurement recorded in $(m17_measured_env)"
assert_file "the measurement record is written" "$(m17_measured_env)"

finish
