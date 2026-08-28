#!/usr/bin/env bash
# m31-mutations.sh — does each M31 check SEE what it is written for?
#
#   scratchpad/campaign/m31-mutations.sh [ARM …]      # default: all
#
# ==============================================================================================
# WHAT THIS IS FOR, AND THE THREE STATES IT HAS TO TELL APART.
# ==============================================================================================
#
# A green check is not evidence until something has made it red for the right reason. This
# campaign has three recorded failure modes for a harness like this one and all three are guarded
# here:
#
#   1. A MUTATION THAT REDDENS FOR THE WRONG REASON. Every arm records the failing assertion TEXT,
#      not just the count, so "the check failed" and "the check saw what I broke" stay different
#      statements (M24's review).
#   2. A MUTATION SILENTLY UNDONE AND PRINTED AS THE ARM'S RESULT. M30's review measured an arm
#      reporting 67/0 green in sequence and 1/2 alone, with nothing saying the mutation had been
#      reverted underneath it. So every arm ASSERTS AFTER THE RUN that its mutation is still
#      there, and `die`s naming the cause if it is not.
#   3. THE cargo-mtime TRAP, met four times in four disguises. `cp -p` restores an old mtime,
#      cargo declines to recompile, and a build emits a module still carrying the mutation while
#      reporting success. Restores here copy CONTENT and then `touch`, and the build script's own
#      stamp is over the whole materialised tree rather than a file list.
#
# It also carries a HANG arm and a DIE-BEFORE-SUMMARY arm, because a check that never exits
# reports nothing at all and blocks a sweep behind it, and a check that dies before `finish`
# reads as a SMALLER milestone rather than a red one.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="${M31_MUT_WORK:-$HOME/.cache/aztec-m31-mutations}"
SAVE="$WORK/save"
mkdir -p "$SAVE" || { echo "could not create $SAVE" >&2; exit 2; }

BUILD_DIR="${M31_BUILD_DIR:-$HOME/.cache/aztec-m31-transpiler}"
ARMS_WORK="${M31_WORK:-$HOME/.cache/aztec-m31-arms}"

say() { printf '\n=== %s\n' "$*"; }
die() { printf 'm31-mutations: %s\n' "$*" >&2; exit 2; }

# --------------------------------------------------------------------------------------------
# save/restore, by CONTENT with a `touch`, and verified.
# --------------------------------------------------------------------------------------------
FILES=()
save_file() { # <path>
  local f="$1" key
  key="$(printf '%s' "$f" | tr '/' '_')"
  [ -f "$f" ] || die "cannot save $f: it does not exist"
  cp "$f" "$SAVE/$key" || die "could not save $f"
  sha256sum "$f" | sed "s#$f#$SAVE/$key.orig#" >"$SAVE/$key.sha"
  FILES+=("$f")
}
restore_all() {
  local f key rc=0
  for f in "${FILES[@]}"; do
    key="$(printf '%s' "$f" | tr '/' '_')"
    # CONTENT, then `touch`. `cp -p` would put the original mtime back and cargo would decline to
    # rebuild from it — the trap this campaign has now met four times.
    cp "$SAVE/$key" "$f" || rc=1
    touch "$f"
    if [ "$(sha256sum <"$f" | cut -d' ' -f1)" != "$(sha256sum <"$SAVE/$key" | cut -d' ' -f1)" ]; then
      printf 'restore: %s does NOT match its pre-mutation copy\n' "$f" >&2
      rc=1
    fi
  done
  [ "$rc" = 0 ] && printf 'restore: every file is byte-identical to its pre-mutation copy\n'
  return "$rc"
}
# The restore checker's own control: corrupt a scratch copy by one character and the comparison
# must report it. Run on every invocation, so the checker is never trusted unexercised.
verify_restore_control() {
  local a="$WORK/.ctl.a" b="$WORK/.ctl.b"
  printf 'hello world\n' >"$a"; printf 'hello worlx\n' >"$b"
  if [ "$(sha256sum <"$a" | cut -d' ' -f1)" = "$(sha256sum <"$b" | cut -d' ' -f1)" ]; then
    die "the restore checker cannot tell two different files apart"
  fi
  printf 'restore-control: a one-character corruption IS reported\n'
  rm -f "$a" "$b"
}

run_check() { # <check> <label>
  # SPLIT, not `local a=… b=$a`: bash expands every word of a `local` before assigning any of
  # them, so the second form is an unbound-variable error under `set -u`. Met on this harness's
  # first run, which is the cheap direction.
  local check="$1"
  local label="$2"
  local log="$WORK/$label.$check.log"
  ( cd "$REPO" && direnv exec . "verification/$check.sh" ) >"$log" 2>&1
  local rc=$?
  local summary
  summary="$(grep -E "^$check: [0-9]+ assertion" "$log" | tail -1)"
  printf '  %-58s rc=%s  %s\n' "$check" "$rc" "${summary:-<NO SUMMARY LINE>}"
  grep '^  FAIL' "$log" | sed 's/^/      /' | head -12
  return "$rc"
}

# Force the arms to be re-measured after a mutation that changes what the module or the page does.
refresh_arms() { rm -f "$ARMS_WORK/transpiler.json"; }

still_mutated() { # <path> <needle>   — the guard against a mutation silently undone
  grep -q -- "$2" "$1" || die "ARM ABORTED: the mutation in $1 is NO LONGER THERE after the run.
     A green arm printed in this state would read as absent coverage of a property that is in fact
     covered. Refusing to print a result."
}

ARMS=("$@")
[ "${#ARMS[@]}" -gt 0 ] || ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11)
in_arms() { local a; for a in "${ARMS[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }

verify_restore_control

SHIM="$REPO/avm-transpiler-wasm/src/lib.rs"
PAGE="$REPO/verification/m31/page/transpile_page.mjs"
DRIVER="$REPO/orchestration/src/transpiled_contract_driver.ts"
ARMS_MJS="$REPO/tools/run_transpiler_arms.mjs"
LIB="$REPO/verification/lib_m31_transpiler.sh"
FIXTURE="$REPO/fixtures/transpiler-contracts/counter_variant/src/main.nr"

# ---------------------------------------------------------------------------------------------
# M1 — the module returns the INPUT unchanged instead of transpiling it.
#
# The purest form of the thing the identity check exists to catch: a "transpiler" that is a
# pass-through. Both producers would still agree if the NATIVE one did it too — it does not, so
# the browser and node digests must diverge from the native one.
# ---------------------------------------------------------------------------------------------
if in_arms M1; then
  say "M1 — avmt_transpile echoes its input"
  save_file "$SHIM"
  python3 - "$SHIM" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    // The one call. Everything else in this file is marshalling.\n    let mut result = unsafe { avm_transpiler::avm_transpile_bytecode(ptr, len) };"
new = ("    // MUTATION M1: echo the input instead of transpiling it.\n"
       "    let echoed = unsafe { std::slice::from_raw_parts(ptr, len) }.to_vec();\n"
       "    return publish(echoed, true);\n"
       "    #[allow(unreachable_code)]\n"
       "    let mut result = unsafe { avm_transpiler::avm_transpile_bytecode(ptr, len) };")
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check verify_transpiler_wasm_output_identical_to_native M1
  still_mutated "$SHIM" "MUTATION M1"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M2 — the page reports a digest of the INPUT rather than of the output.
#
# "Read it from the artefact" is not enough on its own; the campaign's rule is to ask WHICH
# artefact. This is a producer reporting about itself, and the check must not be satisfied by it.
# ---------------------------------------------------------------------------------------------
if in_arms M2; then
  say "M2 — the page reports the input's digest as the output's"
  save_file "$PAGE"
  python3 - "$PAGE" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "          outputSha256: await sha256Hex(r.bytes),"
new = "          outputSha256: await sha256Hex(inputBytes), // MUTATION M2"
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check verify_transpiler_wasm_output_identical_to_native M2
  still_mutated "$PAGE" "MUTATION M2"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M3 — the debug map is NOT re-keyed: the input's Brillig indices are put back.
#
# THE MILESTONE'S OWN RISK. A wasm build that lost `patch_debug_info_pcs` would look exactly like
# this, and the failure would otherwise be silent: rung 1 degrading to rung 3 with nothing saying
# so. Applied in the ARM RUNNER rather than in the transpiler, because the point is whether the
# CHECK notices, not whether Rust can be edited.
# ---------------------------------------------------------------------------------------------
if in_arms M3; then
  say "M3 — the rung arm is fed the NOT-re-keyed map"
  save_file "$ARMS_MJS"
  python3 - "$ARMS_MJS" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    for (const fn of avmFunctions(artifact)) {\n      const debugInfo = decodeDebugSymbols(fn.debug_symbols).debug_infos[0];"
new = ("    const _m3input = JSON.parse(readFileSync(path.join(ARTIFACTS, `${name}.json`), 'utf8'));\n"
       "    for (const fn of avmFunctions(artifact)) {\n"
       "      // MUTATION M3: the pre-transpile map, as a build that lost patch_debug_info_pcs would emit\n"
       "      const _m3src = avmFunctions(_m3input).find((f) => f.name === fn.name);\n"
       "      const debugInfo = _m3src\n"
       "        ? decodeDebugSymbols(_m3src.debug_symbols).debug_infos[0]\n"
       "        : decodeDebugSymbols(fn.debug_symbols).debug_infos[0];")
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check verify_transpiler_rung1_mapping_survives M3
  still_mutated "$ARMS_MJS" "MUTATION M3"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M4 — the rung-3 control is silently ACCEPTED as rung 1.
#
# "A rung-3 artifact is LABELLED rung 3 rather than silently accepted" is the milestone's own
# sentence. This makes `rungFor`'s verdict a constant 1 in the arm runner.
# ---------------------------------------------------------------------------------------------
if in_arms M4; then
  say "M4 — every artifact is reported as rung 1"
  save_file "$ARMS_MJS"
  python3 - "$ARMS_MJS" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    out.controls.appendedRevertDispatch = {\n      present: true,\n      bytecodeLength,\n      debugInfos: decodeDebugSymbols(fn.debug_symbols).debug_infos.length,\n      rung: verdict.rung,"
new = ("    out.controls.appendedRevertDispatch = {\n      present: true,\n      bytecodeLength,\n"
       "      debugInfos: decodeDebugSymbols(fn.debug_symbols).debug_infos.length,\n"
       "      rung: 1, // MUTATION M4: accept a rung-3 artifact as rung 1\n")
assert old in s
open(p, 'w').write(s.replace(old, new + "      _wasRung: verdict.rung,"))
PY
  refresh_arms
  run_check verify_transpiler_rung1_mapping_survives M4
  still_mutated "$ARMS_MJS" "MUTATION M4"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M5 — the control fixture becomes a COPY of its base.
#
# Section 5's whole job is "a different input must produce a different output". If the two
# fixtures were the same program, that section would be asserting identity twice and reading as a
# control. The check re-derives the source difference for exactly this.
# ---------------------------------------------------------------------------------------------
if in_arms M5; then
  say "M5 — counter_variant becomes a copy of counter"
  save_file "$FIXTURE"
  cp "$REPO/fixtures/transpiler-contracts/counter/src/main.nr" "$FIXTURE"
  printf '// MUTATION M5\n' >>"$FIXTURE"
  touch "$FIXTURE"
  refresh_arms
  run_check verify_transpiler_wasm_output_identical_to_native M5
  still_mutated "$FIXTURE" "MUTATION M5"
  restore_all; touch "$FIXTURE"; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M6 — the executed transaction reverts, and the report still says `processed`.
#
# M29's review's finding, reproduced: a demo transaction that reverts still reports `processed`,
# because that is the BLOCK's verdict. The check must be reading `revertCode`.
# ---------------------------------------------------------------------------------------------
if in_arms M6; then
  say "M6 — the driver reports revertCode 0 whatever happened"
  save_file "$DRIVER"
  python3 - "$DRIVER" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      revertCode: processedTx === undefined ? null : processedTx.revertCode.getCode(),"
new = "      revertCode: 0, // MUTATION M6: the constant that reads like a measurement"
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check test_transpiled_contract_registers_and_executes M6
  still_mutated "$DRIVER" "MUTATION M6"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M7 — the instruction count becomes a constant.
#
# The other field in that check that could be a constant. 41 is `counter`'s real figure, so this
# is the version of the mutation that is hardest to see.
# ---------------------------------------------------------------------------------------------
if in_arms M7; then
  say "M7 — instructionsExecuted is the constant 41"
  save_file "$DRIVER"
  python3 - "$DRIVER" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "      instructionsExecuted = (reactor.exports.avm_steps_count as () => number)();"
new = "      instructionsExecuted = 41; // MUTATION M7: counter's own real figure, as a constant"
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  run_check test_transpiled_contract_registers_and_executes M7
  still_mutated "$DRIVER" "MUTATION M7"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M8 — the neutrality baseline silently carries the patch.
#
# The comparison would then be a comparison of one tree with itself, which is this campaign's
# oldest defect wearing a build script. The build script asserts the baseline is unpatched before
# it builds, so this must be a REFUSAL and not a green run.
# ---------------------------------------------------------------------------------------------
if in_arms M8; then
  say "M8 — the baseline tree is patched too"
  BUILD_SH="$REPO/verification/build_avm_transpiler_wasm.sh"
  save_file "$BUILD_SH"
  python3 - "$BUILD_SH" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """    grep -q 'use libc::{c_char, c_int, size_t};' "$BTREE/avm-transpiler/src/lib.rs" || \\"""
new = """    # MUTATION M8: patch the baseline too, then assert it is pristine
    ( cd "$BTREE" && git apply "$PATCH" ) || true
    grep -q 'use libc::{c_char, c_int, size_t};' "$BTREE/avm-transpiler/src/lib.rs" || \\"""
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  rm -rf "$BUILD_DIR/baseline"
  run_check verify_transpiler_native_build_unaffected M8
  still_mutated "$BUILD_SH" "MUTATION M8"
  # AND THE MUTATION'S EFFECT, not just its text. This arm went GREEN on its first run because
  # `rm -rf` deleted a directory the build was not using (the script read `M31_WORK`, which the
  # check library exports as the ARM REPORT's directory), so the mutated branch was never taken.
  # A mutation whose text is present and whose effect is absent is the state that reads as
  # "not detected" when it is in fact "not applied".
  if [ -f "$BUILD_DIR/baseline/avm-transpiler/src/lib.rs" ] \
     && grep -q 'use libc::{c_char, c_int, size_t};' "$BUILD_DIR/baseline/avm-transpiler/src/lib.rs"; then
    die "ARM ABORTED: the baseline tree is still PRISTINE after an arm whose whole point is to
     patch it. The mutation did not take effect and the result above is meaningless."
  fi
  restore_all
  rm -rf "$BUILD_DIR/baseline"
fi

# ---------------------------------------------------------------------------------------------
# M9 — a JS clock import is PLANTED in the module.
#
# Section 2 of the identity check asserts that no import matches `__wbg_new0`, `__wbg_getTime`,
# `__wbg_now`, `wasi_snapshot_preview1` or the getRandomValues family — M30's blocker by name.
# This plants exactly such an import and calls it, so the census has something to find.
#
# IT IS NOT THE OBVIOUS MUTATION, AND THE OBVIOUS ONE DOES NOT WORK. Flipping
# `getrandom_backend="unsupported"` to `"wasm_js"` does NOT give the module a JS import: that
# value is not in getrandom 0.4.1's backend dispatch at all (`src/backends.rs:10-38` lists
# custom / linux_getrandom / linux_raw / rdrand / rndr / efi_rng / windows_legacy / unsupported /
# extern_impl), so the build falls through to the TARGET arm and hits the same `compile_error!`
# blocker 1 is about — measured: `0 assertion(s), 1 failure(s)`, a build failure, with the import
# census never reached. Recorded because it is also independent evidence for the RI-79 decision:
# `wasm_js` cannot be selected without adding the feature, i.e. without adding a dependency.
#
# THIS IS A BUILD-CHANGING ARM: it rebuilds a 5 MB module.
# ---------------------------------------------------------------------------------------------
if in_arms M9; then
  say "M9 — a __wbg_new0 clock import is planted in the module"
  save_file "$SHIM"
  python3 - "$SHIM" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "/// Byte length of the buffer the last [`avmt_transpile`] call returned."
new = ("""// MUTATION M9: a planted JS clock import, exactly the shape M30's blocker had.
#[link(wasm_import_module = "__wbindgen_placeholder__")]
unsafe extern "C" {
    fn __wbg_new0_planted_by_m9() -> f64;
}
// DECLARED, NEVER CALLED, and kept alive against the linker's dead-code elimination by a `#[used]`
// static holding its address. That is precisely the state the import census is written for:
// `reachedImports` stays EMPTY and the import section grows by one. A version of this arm that
// CALLED the import was detected too, but by the page's throwing recorder taking the arms run
// down — a precondition failure, not the census.
#[used]
static M9_KEEP: unsafe extern "C" fn() -> f64 = __wbg_new0_planted_by_m9;

/// Byte length of the buffer the last [`avmt_transpile`] call returned.""")
assert old in s
s = s.replace(old, new, 1)
old2 = "pub extern \"C\" fn avmt_result_len() -> usize {\n    RESULT_LEN.with(Cell::get)"
new2 = ("pub extern \"C\" fn avmt_result_len() -> usize {\n"
        "    RESULT_LEN.with(Cell::get)")
assert old2 in s
open(p, 'w').write(s.replace(old2, new2, 1))
PY
  refresh_arms
  run_check verify_transpiler_wasm_output_identical_to_native M9
  still_mutated "$SHIM" "MUTATION M9"
  # AND THE MUTATION'S EFFECT ON THE ARTEFACT, not just its text in the source. The first version
  # of this arm guarded the planted call with `if RESULT_LEN == usize::MAX`, which LLVM can prove
  # false — every store into that cell is `0` or a `Vec::len()` — so the call was eliminated, the
  # import never entered the module, the module rebuilt to the SAME 5,196,936 bytes, and the arm
  # reported 120 / 0. A mutation defeated by the optimiser reads exactly like a check that does
  # not notice.
  # The module path is READ from the build script's own `MODULE=` line rather than reassembled
  # here. The first version reassembled it from `$BUILD_DIR`, which is a second declaration of a
  # path the build script already prints, and it did not resolve in this shell — so the guard
  # aborted an arm that had in fact worked. Ask the producer where it put the thing.
  M9_MODULE="$(sed -n 's/^MODULE=//p' "$ARMS_WORK/bounded.log" | tail -1)"
  M9_IMPORTS="$(python3 "$REPO/scratchpad/campaign/m31-wasmwalk.py" "$M9_MODULE" 2>&1 || true)"
  case "$M9_IMPORTS" in
    *__wbg_new0_planted_by_m9*) : ;;
    *)
      restore_all; refresh_arms
      die "ARM ABORTED: the planted import is NOT in the built module [$M9_MODULE]. The mutation
     did not reach the artefact — most likely eliminated — and the result above is meaningless.
     First lines of what the walker saw: $(printf '%s' "$M9_IMPORTS" | head -3 | tr '\n' ' ')" ;;
  esac
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M10 — THE HANG. The page never becomes ready.
#
# A check that never exits reports nothing at all and blocks a sweep behind it, which is worse
# than one that fails. The bound must fire and the failure must NAME the hang.
# ---------------------------------------------------------------------------------------------
if in_arms M10; then
  say "M10 — the page hangs (the HANG state, reported as a failure)"
  save_file "$PAGE"
  python3 - "$PAGE" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  globalThis.avmtDemoReady = true;"
new = "  // MUTATION M10: never become ready\n  await new Promise(() => {});\n  globalThis.avmtDemoReady = true;"
assert old in s
open(p, 'w').write(s.replace(old, new))
PY
  refresh_arms
  ( cd "$REPO" && M31_ARMS_TIMEOUT=120 M31_LOAD_MS=30000 M31_EVAL_MS=30000 \
      direnv exec . verification/verify_transpiler_wasm_output_identical_to_native.sh ) \
    >"$WORK/M10.hang.log" 2>&1
  printf '  rc=%s\n' "$?"
  grep -E 'HANG|did not finish|did not become ready|assertion\(s\)' "$WORK/M10.hang.log" | sed 's/^/      /' | head -6
  still_mutated "$PAGE" "MUTATION M10"
  restore_all; refresh_arms
fi

# ---------------------------------------------------------------------------------------------
# M11 — DIE BEFORE THE SUMMARY.
#
# A check that dies before `finish` prints no summary line and reads as a SMALLER milestone
# rather than a red one — how `verify-m9` once came out 283 assertions short with nothing
# reported. The abnormal-exit trap must print a summary WITH a failure counted.
#
# The mutation is a `die` inside the check itself, deliberately AFTER some assertions have run,
# so the trap's counted state is non-trivial.
# ---------------------------------------------------------------------------------------------
if in_arms M11; then
  say "M11 — the check dies before finish"
  CHK="$REPO/verification/verify_transpiler_rung1_mapping_survives.sh"
  save_file "$CHK"
  python3 - "$CHK" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = 'echo "== 2. THE KEYS MOVED'
new = 'die "MUTATION M11: dying before finish"\necho "== 2. THE KEYS MOVED'
assert old in s
open(p, 'w').write(s.replace(old, new, 1))
PY
  run_check verify_transpiler_rung1_mapping_survives M11
  still_mutated "$CHK" "MUTATION M11"
  restore_all
fi

say "done"
restore_all
