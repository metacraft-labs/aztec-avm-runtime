#!/usr/bin/env bash
# verify_avm_wasm_preset_uses_ambient_wasi_prefix — the `wasm-avm` preset
# resolves its toolchain from the shell's WASI_SDK_PREFIX rather than from a
# hardcoded /opt/wasi-sdk.
#
# WHY THIS NEEDS A CONTROL, AND WHY EXIT STATUS IS NOT THE MEASUREMENT
#
# A CMake preset's `environment` block OVERRIDES the ambient variable rather
# than defaulting to it. Upstream's `wasm` preset sets
# `"WASI_SDK_PREFIX": "/opt/wasi-sdk"` there, so a preset inheriting it can only
# ever use that path, whatever the shell says — which is why M4 had to run both
# halves of its artefact comparison under `bwrap --bind <sdk> /opt/wasi-sdk`.
#
# Point either preset at a decoy prefix and BOTH fail to configure. Exit status
# says nothing. What separates them is the path NAMED in the failure, so this
# check asserts that, in both directions, against two trees that differ by
# exactly one patch:
#
#   avm        patches 1,2,3,4 — the tree under test. Must name the decoy.
#   hardcoded  patches 1,3,4, with patch 2 (the wasi-sdk bump, which is what
#              rewrites the preset) DELIBERATELY OMITTED. Must name
#              /opt/wasi-sdk and must NOT name the decoy.
#
# and then a third arm that removes the "any nonexistent path errors somewhere"
# reading entirely: the prefix is pointed at a REAL, DIFFERENT toolchain —
# wasi-sdk 27, realised from the same flake — and the configure is required to
# have followed it there.
#
# The deliverable said M6 must make this change. It does not: M4's prepared
# patch already replaced the hardcode with `$penv{WASI_SDK_PREFIX}`, and
# `wasm-avm` inherits it by declaring no `environment` block of its own. This
# check therefore establishes the property rather than a diff, and asserts the
# inheritance explicitly, because "the parent is fixed" and "the child uses the
# parent's fix" are two different statements.

set -uo pipefail

TEST_NAME=verify_avm_wasm_preset_uses_ambient_wasi_prefix
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

require_nix
m6_prepare_trees
m6_prepare_hardcoded_tree

PRESETS_AVM="$M6_TREE_AVM/barretenberg/cpp/CMakePresets.json"
PRESETS_BASE="$M6_TREE_BASE/barretenberg/cpp/CMakePresets.json"

preset_json() { # <presets-file> <preset-name> <jq-ish path via python>
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
name, path = sys.argv[2], sys.argv[3]
for p in d["configurePresets"]:
    if p["name"] == name:
        cur = p
        for k in path.split("."):
            if k == "":
                continue
            if not isinstance(cur, dict) or k not in cur:
                print("<absent>"); sys.exit(0)
            cur = cur[k]
        print(cur if not isinstance(cur, (dict, list)) else json.dumps(cur, sort_keys=True))
        sys.exit(0)
print("<no-such-preset>")
PY
}

# ---------------------------------------------------------------------------
# What the presets SAY. Read from the file, and from the patch's own added
# lines, so the artefact that would be filed upstream is the one asserted.
# ---------------------------------------------------------------------------
assert_eq "the base commit's wasm preset hardcodes /opt/wasi-sdk (this is what was wrong)" \
  "/opt/wasi-sdk" "$(preset_json "$PRESETS_BASE" wasm environment.WASI_SDK_PREFIX)"
assert_eq "in the AVM_WASM tree it defers to the ambient variable" \
  '$penv{WASI_SDK_PREFIX}' "$(preset_json "$PRESETS_AVM" wasm environment.WASI_SDK_PREFIX)"

assert_eq "a wasm-avm preset exists" \
  "wasm-avm" "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
print(next((p["name"] for p in d["configurePresets"] if p["name"]=="wasm-avm"), "<absent>"))' "$PRESETS_AVM")"
assert_eq "it inherits the wasm preset" \
  "wasm" "$(preset_json "$PRESETS_AVM" wasm-avm inherits)"
assert_eq "and declares NO environment block of its own, so nothing can shadow the parent's" \
  "<absent>" "$(preset_json "$PRESETS_AVM" wasm-avm environment)"
assert_eq "the AVM_WASM preset's binaryDir is build-wasm-avm" \
  "build-wasm-avm" "$(preset_json "$PRESETS_AVM" wasm-avm binaryDir)"

# Everything the preset derives from the prefix, so a partial fix cannot pass.
for k in CC CXX AR RANLIB; do
  assert_eq "the wasm preset's $k derives from \$env{WASI_SDK_PREFIX}" \
    "yes" "$(case "$(preset_json "$PRESETS_AVM" wasm "environment.$k")" in
               '$env{WASI_SDK_PREFIX}'*) echo yes ;; *) echo "no" ;; esac)"
done
assert_prefix "and so does CMAKE_SYSROOT" '$env{WASI_SDK_PREFIX}' \
  "$(preset_json "$PRESETS_AVM" wasm cacheVariables.CMAKE_SYSROOT)"

# The patch under test does not touch the WASI_SDK_PREFIX line — patch 2 does.
# Say so from the patch files rather than from memory.
assert_eq "patch 4 does not touch the WASI_SDK_PREFIX line" \
  "0" "$(m6_patch_added "$M6_PATCH_4" CMakePresets | grep -c 'WASI_SDK_PREFIX')"
assert_eq "patch 2 is where the hardcode is removed" \
  "1" "$(m6_patch_removed "$M6_PATCH_2" CMakePresets | grep -c '"WASI_SDK_PREFIX": "/opt/wasi-sdk"')"
assert_eq "and where \$penv{WASI_SDK_PREFIX} is added" \
  "1" "$(m6_patch_added "$M6_PATCH_2" CMakePresets | grep -cF '"WASI_SDK_PREFIX": "$penv{WASI_SDK_PREFIX}"')"

# ---------------------------------------------------------------------------
# Preconditions for the controls. If either of these is false the controls do
# not measure what they claim, so they are assertions and not a skip.
# ---------------------------------------------------------------------------
assert_false "the decoy prefix does not exist ($M6_DECOY_PREFIX)" test -e "$M6_DECOY_PREFIX"
assert_false "and /opt/wasi-sdk does not exist on this host, so the control arm is meaningful" \
  test -e /opt/wasi-sdk

SDK33="$(m6_sdk 33)"
SDK27="$(m6_sdk 27)"

# ---------------------------------------------------------------------------
# Arm 1 — the real prefix. The positive control: the preset works, and it works
# with the SHELL's toolchain.
# ---------------------------------------------------------------------------
m6_configure_with_prefix "$SDK33" "$M6_TREE_AVM" wasm-avm build-prefix-real
RC_REAL=$?
assert_eq "with WASI_SDK_PREFIX=<wasi-sdk 33>, wasm-avm configures" "0" "$RC_REAL"
assert_eq "and resolves the compiler inside that prefix" \
  "$SDK33/bin/clang++" "$(m6_cache "$M6_TREE_AVM" build-prefix-real CMAKE_CXX_COMPILER)"
assert_eq "and the sysroot inside it" \
  "$SDK33/share/wasi-sysroot" "$(m6_cache "$M6_TREE_AVM" build-prefix-real CMAKE_SYSROOT)"
assert_eq "no /opt/wasi-sdk path survives anywhere in the resulting cache" \
  "0" "$(grep -c '/opt/wasi-sdk' "$M6_TREE_AVM/barretenberg/cpp/build-prefix-real/CMakeCache.txt")"

# ---------------------------------------------------------------------------
# Arm 2 — a REAL but DIFFERENT toolchain. This is the arm that closes the
# "anything nonexistent errors" reading: wasi-sdk 27 is a perfectly good
# directory, and the preset must be seen to have gone there.
# ---------------------------------------------------------------------------
m6_configure_with_prefix "$SDK27" "$M6_TREE_AVM" wasm-avm build-prefix-27
RC_27=$?
LOG_27="$(printf '%s\n' "$(m6_log "$M6_TREE_AVM" build-prefix-27)" | grep -v '^### ')"
assert_contains "with WASI_SDK_PREFIX=<wasi-sdk 27>, the configure names 27's compiler" \
  "$SDK27/bin/clang++" "$LOG_27"
assert_not_contains "and never mentions /opt/wasi-sdk" "/opt/wasi-sdk" "$LOG_27"
# It then fails, but on the exceptions gate rather than on a missing toolchain —
# which is itself evidence that it got far enough to USE 27.
if [ "$RC_27" -ne 0 ]; then
  pass "it then fails the AVM_WASM exceptions gate, as 27 must  [exit $RC_27]"
else
  fail "wasi-sdk 27 configured an AVM_WASM build — the exceptions gate is not doing its job"
fi
assert_contains "and the failure is the gate, naming wasi-sdk 33.0" \
  "AVM_WASM needs wasi-sdk 33.0 or newer" "$LOG_27"

# ---------------------------------------------------------------------------
# Arm 3 — the decoy, on the tree under test. Must name the decoy.
# ---------------------------------------------------------------------------
# The helper writes its own `### WASI_SDK_PREFIX=...` marker as the first line
# of every log, so the counts below are taken over CMAKE's output only. Counting
# our own echo of the variable as evidence that cmake read it would be circular.
cmake_only() { printf '%s\n' "$1" | grep -v '^### '; }

m6_configure_with_prefix "$M6_DECOY_PREFIX" "$M6_TREE_AVM" wasm-avm build-prefix-decoy
RC_DECOY=$?
LOG_DECOY="$(cmake_only "$(m6_log "$M6_TREE_AVM" build-prefix-decoy)")"
if [ "$RC_DECOY" -ne 0 ]; then
  pass "with WASI_SDK_PREFIX=<decoy>, wasm-avm fails to configure  [exit $RC_DECOY]"
else
  fail "wasm-avm configured against a nonexistent toolchain prefix"
fi
assert_contains "and the failure names the DECOY compiler path" \
  "$M6_DECOY_PREFIX/bin/clang++" "$LOG_DECOY"
assert_not_contains "and never mentions /opt/wasi-sdk" "/opt/wasi-sdk" "$LOG_DECOY"

# ---------------------------------------------------------------------------
# Arm 4 — THE CONTROL. The same preset name, the same decoy, on a tree whose
# `wasm` preset still hardcodes the path. Same exit status; different name.
# ---------------------------------------------------------------------------
m6_configure_with_prefix "$M6_DECOY_PREFIX" "$M6_TREE_HARDCODED" wasm-avm build-prefix-decoy
RC_CONTROL=$?
LOG_CONTROL="$(cmake_only "$(m6_log "$M6_TREE_HARDCODED" build-prefix-decoy)")"
assert_eq "the control tree's wasm preset still hardcodes /opt/wasi-sdk" \
  "/opt/wasi-sdk" "$(preset_json "$M6_TREE_HARDCODED/barretenberg/cpp/CMakePresets.json" wasm environment.WASI_SDK_PREFIX)"
assert_eq "and it has the same wasm-avm preset, inheriting it" \
  "wasm" "$(preset_json "$M6_TREE_HARDCODED/barretenberg/cpp/CMakePresets.json" wasm-avm inherits)"
if [ "$RC_CONTROL" -ne 0 ]; then
  pass "the control also fails to configure under the decoy  [exit $RC_CONTROL]"
else
  fail "the control configured — it was supposed to fail on /opt/wasi-sdk"
fi
assert_eq "BOTH arms exit non-zero, which is why exit status is not the measurement" \
  "yes" "$([ "$RC_DECOY" -ne 0 ] && [ "$RC_CONTROL" -ne 0 ] && echo yes || echo no)"
assert_not_contains "the control's failure never mentions the decoy" \
  "$M6_DECOY_PREFIX" "$LOG_CONTROL"
assert_contains "it names /opt/wasi-sdk instead — the ambient variable was ignored" \
  "/opt/wasi-sdk/bin/clang++" "$LOG_CONTROL"

# The two logs differ, and they differ in exactly this way. Counted, not asserted
# to "differ".
assert_eq "cmake names the decoy once in the tree under test" \
  "1" "$(printf '%s\n' "$LOG_DECOY" | grep -c "$M6_DECOY_PREFIX")"
assert_eq "and never in the control" \
  "0" "$(printf '%s\n' "$LOG_CONTROL" | grep -c "$M6_DECOY_PREFIX")"
assert_eq "cmake never names /opt/wasi-sdk in the tree under test" \
  "0" "$(printf '%s\n' "$LOG_DECOY" | grep -c '/opt/wasi-sdk')"
assert_eq "and names it once in the control" \
  "1" "$(printf '%s\n' "$LOG_CONTROL" | grep -c '/opt/wasi-sdk')"

rm -rf "$M6_TREE_AVM/barretenberg/cpp/build-prefix-real" \
       "$M6_TREE_AVM/barretenberg/cpp/build-prefix-27" \
       "$M6_TREE_AVM/barretenberg/cpp/build-prefix-decoy" \
       "$M6_TREE_HARDCODED/barretenberg/cpp/build-prefix-decoy"

finish
