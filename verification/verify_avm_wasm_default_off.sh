#!/usr/bin/env bash
# verify_avm_wasm_default_off — configuring without AVM_WASM reproduces the
# build it would have had, so the option costs existing builds nothing.
#
# THE HOLE THIS CHECK WAS WRITTEN AGAINST
#
# "Nothing changes when the option is off" is a statement that a patch pinning
# entirely the wrong thing also satisfies. M4 shipped a check with exactly that
# shape and it passed a patch that pinned wasi-sdk *18*; M5 pre-empted the same
# hole with a decoy. So this check asserts, in three separate places, what the
# option IS and what turning it ON DOES:
#
#   * the `option()` line is read out of the PATCH's own added lines and its
#     default token asserted to be OFF — not read from a configured cache, which
#     a preset could have set;
#   * the patch is asserted to add exactly one such line and no other default;
#   * and the ON side is asserted by identity: the exact set of ninja targets
#     that `AVM_WASM=ON` adds to a wasm build, and the exact set of archives.
#     A check that only proved the OFF side would go green for an option that
#     does nothing at all.
#
# THE SCOPE, STATED RATHER THAN IMPLIED. "Upstream's build graph" here means the
# build graph of `233d8e0993` + patches 1, 2 and 3 — the three prerequisites
# this one is stacked on. Their own neutrality against the pristine base is M3's,
# M4's and M5's to establish, each with its own check, and is not re-litigated
# here; what is measured here is the cost of THIS milestone's option, with the
# other three held fixed.

set -uo pipefail

TEST_NAME=verify_avm_wasm_default_off
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_avm_wasm.sh"

require_nix
m6_prepare_trees

# ---------------------------------------------------------------------------
# What the option IS, read from the patch that would be filed.
# ---------------------------------------------------------------------------
OPTION_LINES="$(m6_patch_added "$M6_PATCH_4" 'cpp/CMakeLists.txt' | grep -E '^\+option\(AVM_WASM')"
assert_eq "the patch adds exactly one option(AVM_WASM ...) line" \
  "1" "$(printf '%s\n' "$OPTION_LINES" | grep -c '^+option(AVM_WASM' )"
assert_eq "and its default is OFF" \
  "OFF" "$(printf '%s\n' "$OPTION_LINES" | sed -E 's/.*"[[:space:]]*(ON|OFF)\)[[:space:]]*$/\1/')"
# The only place the patch SETS the option on is the new preset's cacheVariables.
# "Default off" cannot be true of a patch that also turns it on somewhere, so
# every construct that could is enumerated: a preset cache variable, a CMake
# `set()`, and the option's own default. The two other added lines that mention
# both tokens are a preset `description` and the gate's diagnostic text; neither
# sets anything, and they are named here so the count above is not mistaken for
# a claim that the string appears once.
assert_eq "the patch sets AVM_WASM ON in exactly one place, the wasm-avm preset" \
  "1" "$(m6_patch_added "$M6_PATCH_4" | grep -c '"AVM_WASM": "ON"')"
assert_eq "it adds no set(AVM_WASM ...) anywhere" \
  "0" "$(m6_patch_added "$M6_PATCH_4" | grep -cE '^\+[[:space:]]*set\(AVM_WASM')"
assert_eq "the other two added lines naming both tokens are prose, not settings" \
  "+      \"description\": \"wasm build with AVM_WASM=ON: adds vm2_sim, and real C++ exceptions (needs wasi-sdk 33)\",
+                \"AVM_WASM is ON, but this wasm toolchain cannot compile and link C++ \"" \
  "$(m6_patch_added "$M6_PATCH_4" | grep 'AVM_WASM.*ON' | grep -v '"AVM_WASM": "ON"')"

# ---------------------------------------------------------------------------
# The OFF side: the `wasm` preset, with and without the patch.
# ---------------------------------------------------------------------------
m6_configure_incremental "$M6_TREE_STACK3" wasm build-wasm
RC_S3=$?
assert_eq "the wasm preset configures without the patch" "0" "$RC_S3"
m6_configure_incremental "$M6_TREE_AVM" wasm build-wasm
RC_AVM=$?
assert_eq "the wasm preset configures with the patch" "0" "$RC_AVM"

assert_eq "without the patch, AVM_WASM is not a cache variable at all" \
  "" "$(m6_cache "$M6_TREE_STACK3" build-wasm AVM_WASM)"
assert_eq "with the patch, it is present and OFF" \
  "OFF" "$(m6_cache "$M6_TREE_AVM" build-wasm AVM_WASM)"

# The target list, as ninja itself reports it.
T_S3="$(m6_ninja_targets "$M6_TREE_STACK3" build-wasm)"
T_AVM="$(m6_ninja_targets "$M6_TREE_AVM" build-wasm)"
N_S3="$(printf '%s\n' "$T_S3" | grep -c .)"
N_AVM="$(printf '%s\n' "$T_AVM" | grep -c .)"
assert_ge "the wasm build declares a substantial target list" 1000 "$N_S3"
assert_eq "and the patched tree declares the same NUMBER of targets" "$N_S3" "$N_AVM"
assert_eq "and the same SET of targets, line for line" \
  "0" "$(diff <(printf '%s\n' "$T_S3") <(printf '%s\n' "$T_AVM") | grep -c '^[<>]')"

# The compile commands. NOT "identical" — this milestone measured that claim and
# it is false, in a way worth stating precisely rather than rounding away.
# `cmake/arch.cmake` turns
#     add_compile_options(-fno-exceptions -fno-slp-vectorize)
# into an if/else that adds `-fno-slp-vectorize` unconditionally and
# `-fno-exceptions` in the else arm, so on a default wasm build the two tokens
# SWAP POSITION on every command line. No flag is added, none removed, the
# multiset is equal on every row, and the artefact is byte-identical — but the
# command strings are not, and asserting that they were would assert something
# untrue. The structural comparison says exactly that, with the difference's
# shape pinned as a single signature so a second, different change could not
# hide inside the same count.
DBCMP="$(python3 "$VERIFY_DIR/_db_compare.py" \
  "$(m6_compile_db "$M6_TREE_STACK3" build-wasm)" "$M6_TREE_STACK3" build-wasm \
  "$(m6_compile_db "$M6_TREE_AVM" build-wasm)" "$M6_TREE_AVM" build-wasm)"
DB_ROWS="$(printf '%s\n' "$DBCMP" | sed -n 's/^rows_a=//p')"
assert_ge "the wasm compile database has the build's translation units in it" 500 "$DB_ROWS"
assert_contains "both builds compile the same number of them" "rows_b=$DB_ROWS" "$DBCMP"
assert_contains "and the same set of (source, object) pairs" "keys_equal=yes" "$DBCMP"
assert_contains "no command has a flag the other does not" "added_or_removed=0" "$DBCMP"
assert_contains "every command's flag multiset is equal" "multiset_equal_rows=$DB_ROWS" "$DBCMP"
assert_eq "the difference is ONE shape, on every row, and this is it" \
  "signature $DB_ROWS -fno-exceptions|-fno-slp-vectorize  -fno-slp-vectorize|-fno-exceptions" \
  "$(printf '%s\n' "$DBCMP" | grep '^signature ')"
note "wasm compile commands: $DB_ROWS rows, flag sets equal, two tokens transposed on each"

# The artefact. The strongest statement available for "additive": not the same
# size, the same bytes.
m6_build "$M6_TREE_STACK3" build-wasm barretenberg.wasm
RC_BS3=$?
assert_eq "barretenberg.wasm builds without the patch" "0" "$RC_BS3"
m6_build "$M6_TREE_AVM" build-wasm barretenberg.wasm
RC_BAVM=$?
assert_eq "barretenberg.wasm builds with the patch" "0" "$RC_BAVM"

WASM_S3="$M6_TREE_STACK3/barretenberg/cpp/build-wasm/bin/barretenberg.wasm"
WASM_AVM="$M6_TREE_AVM/barretenberg/cpp/build-wasm/bin/barretenberg.wasm"
assert_file "the unpatched artefact exists" "$WASM_S3"
assert_file "the patched artefact exists" "$WASM_AVM"
SZ_S3=$(stat -c%s "$WASM_S3" 2>/dev/null); SZ_AVM=$(stat -c%s "$WASM_AVM" 2>/dev/null)
SHA_S3=$(sha256sum "$WASM_S3" 2>/dev/null | cut -d' ' -f1)
SHA_AVM=$(sha256sum "$WASM_AVM" 2>/dev/null | cut -d' ' -f1)
assert_eq "the two artefacts are the same size" "$SZ_S3" "$SZ_AVM"
assert_eq "and byte-identical" "$SHA_S3" "$SHA_AVM"
note "barretenberg.wasm: $SZ_S3 bytes, sha256 $SHA_S3"

# ---------------------------------------------------------------------------
# The ON side, by identity. What does the option ADD?
#
# ISOLATED ON PURPOSE. The `wasm-avm` preset differs from `wasm` in TWO cache
# variables — `AVM_WASM=ON` and `AVM=OFF` — so a `wasm` versus `wasm-avm`
# comparison would attribute `AVM=OFF`'s effect (it drops the `bb-avm`
# executable) to this option. The comparison below is the SAME preset with
# `-DAVM_WASM=OFF` against the same preset unmodified, so the only variable is
# the one the milestone is about.
# ---------------------------------------------------------------------------
assert_eq "the wasm-avm preset sets AVM_WASM ON" \
  "ON" "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
p=next(p for p in d["configurePresets"] if p["name"]=="wasm-avm")
print(p["cacheVariables"].get("AVM_WASM","<absent>"))' "$M6_TREE_AVM/barretenberg/cpp/CMakePresets.json")"
assert_eq "and AVM OFF, which is a separate variable and not this option's doing" \
  "OFF" "$(python3 -c '
import json,sys
d=json.load(open(sys.argv[1]))
p=next(p for p in d["configurePresets"] if p["name"]=="wasm-avm")
print(p["cacheVariables"].get("AVM","<absent>"))' "$M6_TREE_AVM/barretenberg/cpp/CMakePresets.json")"

m6_configure "$M6_TREE_AVM" wasm-avm build-avmon
assert_eq "the wasm-avm preset configures with AVM_WASM on" "0" "$?"
m6_configure "$M6_TREE_AVM" wasm-avm build-avmoff -DAVM_WASM=OFF
assert_eq "and with AVM_WASM forced off" "0" "$?"
assert_eq "the ON build's cache says ON" "ON" "$(m6_cache "$M6_TREE_AVM" build-avmon AVM_WASM)"
assert_eq "the OFF build's cache says OFF" "OFF" "$(m6_cache "$M6_TREE_AVM" build-avmoff AVM_WASM)"

m6_graph "$M6_TREE_AVM" build-avmon  >/dev/null
m6_graph "$M6_TREE_AVM" build-avmoff >/dev/null
GRAPH_ON="$(m6_graph_edges_file "$M6_TREE_AVM" build-avmon)"
GRAPH_OFF="$(m6_graph_edges_file "$M6_TREE_AVM" build-avmoff)"
assert_ge "CMake's own target graph was regenerated with the option on" 500 "$(grep -c . "$GRAPH_ON")"
assert_ge "and with it off" 500 "$(grep -c . "$GRAPH_OFF")"

NODES_ON="$(m6_graph_nodes "$M6_TREE_AVM" build-avmon)"
NODES_OFF="$(m6_graph_nodes "$M6_TREE_AVM" build-avmoff)"
ADDED="$(comm -13 <(printf '%s\n' "$NODES_OFF") <(printf '%s\n' "$NODES_ON") | tr '\n' ' ' | sed 's/ $//')"
REMOVED="$(comm -23 <(printf '%s\n' "$NODES_OFF") <(printf '%s\n' "$NODES_ON") | tr '\n' ' ' | sed 's/ $//')"
assert_eq "turning AVM_WASM ON adds exactly the AVM module set, by identity" \
  "aztec crypto_merkle_tree_test_objects crypto_merkle_tree_tests vm2_sim vm2_sim_objects world_state_reference world_state_reference_objects" \
  "$ADDED"
assert_eq "and removes nothing at all — it is additive in CMake's own model" "" "$REMOVED"

# The merkle-tree module goes from a name something links against to a module
# that is built. cmake's graphviz vocabulary says which: septagon is
# UNKNOWN_LIBRARY, pentagon is INTERFACE_LIBRARY (what M3's split makes it).
assert_eq "with the option off, crypto_merkle_tree is an UNKNOWN library" \
  "septagon" "$(m6_graph_shape "$M6_TREE_AVM" build-avmoff crypto_merkle_tree)"
assert_eq "with it on, it is an INTERFACE library — M3's split, actually built" \
  "pentagon" "$(m6_graph_shape "$M6_TREE_AVM" build-avmon crypto_merkle_tree)"
assert_eq "vm2_sim is a static library in the ON build" \
  "octagon" "$(m6_graph_shape "$M6_TREE_AVM" build-avmon vm2_sim)"
assert_eq "and world_state_reference too" \
  "octagon" "$(m6_graph_shape "$M6_TREE_AVM" build-avmon world_state_reference)"
assert_eq "neither is a node at all with the option off" \
  "" "$(m6_graph_shape "$M6_TREE_AVM" build-avmoff vm2_sim)$(m6_graph_shape "$M6_TREE_AVM" build-avmoff world_state_reference)"

# Non-vacuity: the two configurations really are different builds.
TN_ON="$(m6_ninja_targets "$M6_TREE_AVM" build-avmon | grep -c .)"
TN_OFF="$(m6_ninja_targets "$M6_TREE_AVM" build-avmoff | grep -c .)"
assert_ge "the ON configuration declares more ninja targets than the OFF one" 1 \
  "$((TN_ON - TN_OFF))"
note "ninja targets: AVM_WASM=ON $TN_ON, AVM_WASM=OFF $TN_OFF, wasm preset $N_AVM"

rm -rf "$M6_TREE_AVM/barretenberg/cpp/build-avmoff"

# ---------------------------------------------------------------------------
# And the option cannot reach a NATIVE build. AVM_WASM=ON on the native `default`
# preset must produce the same build as leaving it out — the option's own guard
# is `WASM AND AVM_WASM`, and this is that guard measured rather than read.
# ---------------------------------------------------------------------------
m6_native_configure "$M6_TREE_AVM" build-native-off
RC_NOFF=$?
assert_eq "the native default preset configures with the patch applied" "0" "$RC_NOFF"
m6_native_configure "$M6_TREE_AVM" build-native-on -DAVM_WASM=ON
RC_NON=$?
assert_eq "and configures with AVM_WASM forced ON" "0" "$RC_NON"
assert_eq "AVM_WASM really is ON in that cache" \
  "ON" "$(m6_cache "$M6_TREE_AVM" build-native-on AVM_WASM)"
NT_OFF="$(m6_ninja_targets "$M6_TREE_AVM" build-native-off)"
NT_ON="$(m6_ninja_targets "$M6_TREE_AVM" build-native-on)"
assert_ge "the native build declares a substantial target list" 1000 \
  "$(printf '%s\n' "$NT_OFF" | grep -c .)"
assert_eq "and AVM_WASM=ON changes not one target of it" \
  "0" "$(diff <(printf '%s\n' "$NT_OFF") <(printf '%s\n' "$NT_ON") | grep -c '^[<>]')"
NDBCMP="$(python3 "$VERIFY_DIR/_db_compare.py" \
  "$(m6_compile_db "$M6_TREE_AVM" build-native-off)" "$M6_TREE_AVM" build-native-off \
  "$(m6_compile_db "$M6_TREE_AVM" build-native-on)"  "$M6_TREE_AVM" build-native-on)"
N_ROWS="$(printf '%s\n' "$NDBCMP" | sed -n 's/^rows_a=//p')"
assert_ge "the native compile database is the whole tree" 900 "$N_ROWS"
assert_contains "with the option on it is the same size" "rows_b=$N_ROWS" "$NDBCMP"
assert_contains "and the same set of (source, object) pairs" "keys_equal=yes" "$NDBCMP"
assert_contains "and not one native compile command differs, in flags or in order" \
  "identical_rows=$N_ROWS" "$NDBCMP"
assert_eq "so there is no difference signature at all on the native side" \
  "" "$(printf '%s\n' "$NDBCMP" | grep '^signature ')"
note "native compile commands: $N_ROWS rows, identical with AVM_WASM on and off"

rm -rf "$M6_TREE_AVM/barretenberg/cpp/build-native-on"

# ---------------------------------------------------------------------------
# THE ARTEFACT UPSTREAM READS. A patch's commit message IS the PR body, and M4's
# review found `PR.md` corrected while the commit message still carried the
# overstatement. They are asserted to agree here, on the claims that matter, and
# both are asserted not to carry the two overstatements this milestone removed.
# ---------------------------------------------------------------------------
PR_MD="$M6_PATCH_DIR/PR.md"
assert_file "the contribution's write-up is PR.md, per the non-defect convention" "$PR_MD"
assert_false "and there is no ISSUE.md beside it (that spelling is for defects)" \
  test -e "$M6_PATCH_DIR/ISSUE.md"
assert_file "and a verify.sh, not a reproduce.sh" "$M6_PATCH_DIR/verify.sh"
assert_false "no reproduce.sh either" test -e "$M6_PATCH_DIR/reproduce.sh"

PR_TEXT="$(cat "$PR_MD")"
MSG="$(sed -n '/^Subject:/,/^---$/p' "$M6_PATCH_4")"

# The diffstat, re-derived from the patch itself rather than read from either.
NUMSTAT="$(git -C "$M6_TREE_BASE" apply --numstat "$M6_PATCH_4" 2>/dev/null)"
PF="$(printf '%s\n' "$NUMSTAT" | grep -c .)"
PA="$(printf '%s\n' "$NUMSTAT" | awk '{s+=$1} END{print s+0}')"
PD="$(printf '%s\n' "$NUMSTAT" | awk '{s+=$2} END{print s+0}')"
assert_eq "the patch touches 8 files" "8" "$PF"
assert_contains "and PR.md states that file count and diffstat" \
  "$PF files,
+$PA / −$PD" "$PR_TEXT"

assert_contains "PR.md says the option's default is OFF" "default OFF" "$PR_TEXT"
assert_contains "and names the required toolchain version" "wasi-sdk 33.0" "$PR_TEXT"
assert_contains "the commit message says the option's default is OFF" \
  '`AVM_WASM` option, default OFF' "$MSG"
assert_contains "and names the required toolchain version" "wasi-sdk 33.0" "$MSG"

# The four diagnosed translation units, named in both.
for tu in retrieved_bytecodes_tree_check.cpp written_public_data_slots_tree_check.cpp \
          memory_merkle_db.hpp to_radix.cpp; do
  assert_contains "PR.md names $tu" "$tu" "$PR_TEXT"
  assert_contains "the commit message names $tu" "$tu" "$MSG"
done

# The byte-identity claim, and the actual measurement above, are the same value.
assert_contains "PR.md quotes the artefact's sha256" "$SHA_S3" "$PR_TEXT"
assert_contains "and the commit message quotes its prefix" "${SHA_S3:0:16}" "$MSG"

# The two overstatements this milestone removed, asserted absent from both.
assert_not_contains "PR.md does not claim the interpreter sources are unchanged" \
  "no source change to the interpreter" "$PR_TEXT"
assert_not_contains "nor does the commit message" \
  "no source change to the interpreter" "$MSG"
assert_not_contains "PR.md does not say 'Four narrowing conversions had to be made explicit'" \
  "Four narrowing conversions had to be made explicit" "$PR_TEXT"

# And the reviewer-facing script does not skip.
VERIFY_TEXT="$(cat "$M6_PATCH_DIR/verify.sh")"
assert_eq "verify.sh has no SKIPPED path" "0" \
  "$(printf '%s\n' "$VERIFY_TEXT" | grep -c 'SKIPPED')"
assert_contains "a requested part that cannot run exits 2 naming the variable" \
  'is not set' "$VERIFY_TEXT"
assert_contains "and a run that checked nothing fails" \
  'FAILED: nothing was checked' "$VERIFY_TEXT"

finish
