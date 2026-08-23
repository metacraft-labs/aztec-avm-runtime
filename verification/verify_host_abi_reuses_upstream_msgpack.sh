#!/usr/bin/env bash
# M12: the crossed types are encoded with upstream's generated msgpack schemas, and any type we
# encode ourselves is enumerated with the reason no upstream schema covers it.
#
# THE DELIVERABLE IS PHRASED THE RIGHT WAY ROUND — confirm upstream's schemas cover the surface we
# cross, and only THEN define anything of our own — and this check is that confirmation, done by
# EXECUTION rather than by grepping for a macro.
#
# `avm_msgpack_coverage`, built from one translation unit for x86-64 and for wasm32-wasip1, takes
# every type that crosses the reactor boundary, packs a populated instance, unpacks it, re-packs it
# and compares the BYTES; and packs a copy with one field changed and requires the encoding to
# differ. A type with no schema does not fail there — it fails to COMPILE, which is the point of
# asking the question in C++.
#
# The comparison is on re-packed bytes rather than `operator==` because several of the crossed types
# do not declare one at all (`SequentialInsertionResult` is the first), so an equality-based check
# would have silently narrowed the enumeration to the types that happen to have one — and because a
# `convert` that quietly drops a field round-trips equal under a hand-written `operator==` that does
# not read it, and does not round-trip equal on bytes.
#
# THE ONE TYPE THAT IS OURS, AND THE REASON, RE-DERIVED FROM UPSTREAM ON EVERY RUN.
#
# Upstream HAS a msgpack error envelope: `bb::bbapi::ErrorResponse` in `bbapi/bbapi_shared.hpp`,
# with the same single `message` field and the same `SERIALIZATION_FIELDS`. It is not usable in this
# artefact, and the reason is a fact about upstream's build graph rather than a preference: the
# `bbapi` module's own `barretenberg_module(...)` line pulls `chonk`, `dsl`, `ecc` and `srs` — the
# proving stack this module exists to exclude — and the header does not stand alone. Both halves of
# that are read out of the fork at the pinned anchor here, not restated.
#
# The overlap with M6's forbidden list is `srs` and ONLY `srs`. `chonk` is a different module that
# happens to contain the letters of `honk`, and the loop below matches on word boundaries for that
# reason.
#
# And the schemas are shown to CROSS, not merely to exist: the reactor is driven from JavaScript
# through both entry points and through all twenty-two exported DB methods, and everything it
# returns is decoded by a host that knows the msgpack wire format and nothing about the schemas.

set -uo pipefail

TEST_NAME=verify_host_abi_reuses_upstream_msgpack
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"

require_nix
m12_measured
note "tree: $M12_TREE"

NATIVE_COV="$(m12_native_bin avm_msgpack_coverage)"
WASM_COV="$(m12_wasm_bin avm_msgpack_coverage)"
m8_require_artifacts "$NATIVE_COV" "$WASM_COV" "$M12_PATCH_9"

# --- the enumeration, on both targets ---------------------------------------
m9_run_native "$NATIVE_COV" "$(m12_native_coverage)" "$M12_WORK/native.coverage.err"
assert_eq "the enumeration exits 0 natively" 0 $?
m9_run_v8 "$WASM_COV" "$(m12_wasm_coverage)" "$M12_WORK/wasm.coverage.err"
assert_eq "the enumeration exits 0 on V8" 0 $?

for f in "$(m12_native_coverage)" "$(m12_wasm_coverage)"; do
  label="$(basename "$f")"
  assert_eq "$label: $M12_EXPECTED_MSGPACK_CHECKS types enumerated" \
    "$M12_EXPECTED_MSGPACK_CHECKS" "$(m12_field "$f" msgpackCoverage.checks)"
  assert_eq "$label: zero failures" 0 "$(m12_field "$f" msgpackCoverage.failures)"
  assert_eq "$label: every enumerated type round-trips" "$M12_EXPECTED_MSGPACK_CHECKS" \
    "$(grep -c '^msgpack\..* roundTrip=1 ' "$f")"
  assert_eq "$label: and none reports a non-discriminating encoding" 0 \
    "$(grep -c 'encodingDiscriminates 0' "$f")"
  assert_eq "$label: and none reports differing round-trip bytes" 0 \
    "$(grep -c 'roundTripBytesDiffer 1' "$f")"
done

# The two targets must agree on every line except the one that is allowed to differ: a 64-bit and a
# 32-bit target running the same source. Every enumerated encoding must be byte-identical across
# them, which is the thing a wasm host actually depends on.
native_body="$(grep -v '^msgpackCoverage.pointerBits' "$(m12_native_coverage)")"
wasm_body="$(grep -v '^msgpackCoverage.pointerBits' "$(m12_wasm_coverage)")"
assert_eq "native and wasm enumerations agree line for line, including every encoded byte count" \
  "$(printf '%s' "$native_body" | sha256sum | awk '{print $1}')" \
  "$(printf '%s' "$wasm_body" | sha256sum | awk '{print $1}')"
assert_eq "and the one line that differs is the pointer width" "64" \
  "$(m12_field "$(m12_native_coverage)" msgpackCoverage.pointerBits)"
assert_eq "which is 32 on the wasm side" "32" \
  "$(m12_field "$(m12_wasm_coverage)" msgpackCoverage.pointerBits)"

# --- the split: whose schema is whose ---------------------------------------
cov="$(m12_native_coverage)"
ours="$(grep -c 'origin=ours' "$cov")"
upstream="$(grep -c 'origin=upstream' "$cov")"
prepared="$(grep -c 'origin=prepared-patch' "$cov")"
adaptor="$(grep -c 'origin=msgpack-adaptor' "$cov")"
assert_eq "exactly $M12_EXPECTED_MSGPACK_OURS type in the whole crossed surface is OURS" \
  "$M12_EXPECTED_MSGPACK_OURS" "$ours"
assert_eq "and it is $M12_OUR_ONLY_TYPE" "msgpack.$M12_OUR_ONLY_TYPE" \
  "$(grep 'origin=ours' "$cov" | awk '{print $1}')"
assert_eq "the four origins account for every enumerated type" "$M12_EXPECTED_MSGPACK_CHECKS" \
  "$((ours + upstream + prepared + adaptor))"
note "origins: upstream $upstream, msgpack-c adaptor $adaptor, prepared upstream contribution $prepared, ours $ours"

# `origin=upstream` is a claim about a FILE, so it is checked against one: every declaring file must
# exist in the fork at the pinned anchor, and must not be a file M12's overlay touches.
overlay_files="$(m6_patch_files "$M12_PATCH_9")"
checked=0
while IFS= read -r decl; do
  [ -n "$decl" ] || continue
  checked=$((checked + 1))
  probe="$M12_WORK/decl-$(printf '%s' "$decl" | tr '/.' '__')"
  m8_upstream_file "barretenberg/cpp/src/barretenberg/$decl" "$probe"
  assert_ge "the declaring file exists in the fork at the anchor: $decl" 1 "$(wc -c <"$probe")"
  assert_eq "and M12's overlay does not touch it: $decl" 0 \
    "$(printf '%s\n' "$overlay_files" | grep -c "/$decl\$")"
done <<<"$(grep 'origin=upstream' "$cov" | sed -E 's/.*declaredIn=([^ ]+).*/\1/' | LC_ALL=C sort -u)"
assert_ge "at least four distinct upstream headers declare the crossed surface" 4 "$checked"

# The one `origin=prepared-patch` entry is declared by a PREPARED UPSTREAM CONTRIBUTION rather than
# by an overlay of ours, and that is checked against the patch file that would be filed.
assert_eq "exactly one type arrives with a prepared upstream contribution" 1 "$prepared"
assert_eq "and it is ExecutionStep" "msgpack.ExecutionStep" \
  "$(grep 'origin=prepared-patch' "$cov" | awk '{print $1}')"
assert_ge "the prepared observation-hook patch is what adds it" 1 \
  "$(m6_patch_added "$M9_OBSERVER_PATCH" 'vm2/common/avm_io.hpp' | grep -c 'struct ExecutionStep')"
assert_ge "together with the execution_steps field on TxSimulationResult" 1 \
  "$(m6_patch_added "$M9_OBSERVER_PATCH" 'vm2/common/avm_io.hpp' | grep -c 'execution_steps')"
assert_eq "and M12's own overlay adds neither" 0 \
  "$(m6_patch_added "$M12_PATCH_9" | grep -c 'struct ExecutionStep')"

# --- the reason the one type is ours, re-derived from upstream --------------
BBAPI_SHARED="$M12_WORK/bbapi_shared.hpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/bbapi/bbapi_shared.hpp "$BBAPI_SHARED"
assert_ge "upstream HAS an error envelope: bbapi::ErrorResponse" 1 \
  "$(grep -c 'struct ErrorResponse' "$BBAPI_SHARED")"
assert_ge "with the same single message field and the same SERIALIZATION_FIELDS" 1 \
  "$(grep -c 'SERIALIZATION_FIELDS(message)' "$BBAPI_SHARED")"
# And why it cannot be used here.
BBAPI_CMAKE="$M12_WORK/bbapi_cmake.txt"
m8_upstream_file barretenberg/cpp/src/barretenberg/bbapi/CMakeLists.txt "$BBAPI_CMAKE"
bbapi_deps="$(grep -m1 'barretenberg_module(bbapi' "$BBAPI_CMAKE")"
assert_contains "the bbapi module's own dependency line names the proving stack" "chonk" "$bbapi_deps"
for dep in dsl ecc srs; do
  assert_contains "and $dep with it" "$dep" "$bbapi_deps"
done
# And at least one of the modules M6's link-closure check forbids from this artefact is on that
# very line, so "the proving stack" is a named overlap rather than an impression.
# WORD BOUNDARIES, not substrings, and the correction is worth stating: `chonk` CONTAINS `honk`,
# and `honk` is the first name in M6's forbidden list, so an unanchored match reported an overlap at
# `honk` that upstream's line does not have and counted it twice. `chonk` is a different module.
# The genuine overlap is `srs`, alone — which is enough, and is now asserted as the number it is
# rather than as "at least one". M6's and M7's own uses of this list already match with delimiters;
# this was the only unanchored one.
overlap=0
for forbidden in $M6_FORBIDDEN_MODULES; do
  if printf '%s' "$bbapi_deps" | grep -qw -- "$forbidden"; then
    overlap=$((overlap + 1)); note "bbapi depends on '$forbidden', which vm2_sim's closure excludes"
  fi
done
assert_ge "bbapi's dependency line overlaps the modules M6 excludes from this artefact" 1 "$overlap"
assert_eq "and the overlap is exactly one name — srs" 1 "$overlap"
assert_eq "which is srs itself, not chonk read as honk" 1 \
  "$(printf '%s' "$bbapi_deps" | grep -cw -- srs)"
assert_eq "and honk is NOT on that line: only chonk is" 0 \
  "$(printf '%s' "$bbapi_deps" | grep -cw -- honk)"
assert_ge "the line that does contain the substring is chonk" 1 \
  "$(printf '%s' "$bbapi_deps" | grep -cw -- chonk)"
assert_ge "and its header does not stand alone: it names ChonkStepProcessor" 1 \
  "$(grep -c 'ChonkStepProcessor' "$BBAPI_SHARED")"
assert_ge "and acir_format::AcirFormat" 1 "$(grep -c 'acir_format::AcirFormat' "$BBAPI_SHARED")"

# The reactor source declares exactly ONE type with a msgpack schema. A count over the whole file,
# not a search for a name: a second one added later would move this number.
reactor_src="$(m6_patch_added "$M12_PATCH_9" 'vm2/reactor/avm_reactor.cpp')"
assert_eq "the reactor source declares exactly one msgpack schema of its own" 1 \
  "$(printf '%s\n' "$reactor_src" | grep -cE '^\+ *(SERIALIZATION_FIELDS|MSGPACK_CAMEL_CASE_FIELDS|MSGPACK_ADD_ENUM|void msgpack)')"
assert_ge "and it is on AvmReactorError" 1 \
  "$(printf '%s\n' "$reactor_src" | grep -c 'struct AvmReactorError')"
# Anchored to the start of an added line rather than searched for anywhere in it: the file's own
# header comment NAMES `MSGPACK_ADD_ENUM` while listing the upstream schemas it reuses, and an
# unanchored count found that comment and called it a declaration.
assert_eq "the reactor declares no msgpack enum of its own" 0 \
  "$(printf '%s\n' "$reactor_src" | grep -cE '^\+ *MSGPACK_ADD_ENUM')"
assert_ge "and the count is not vacuous: the file does mention the macro, in a comment" 1 \
  "$(printf '%s\n' "$reactor_src" | grep -c 'MSGPACK_ADD_ENUM')"

# --- the schemas actually CROSS ---------------------------------------------
# Existing is not crossing. Both entry points and all twenty-two exported DB methods are driven from
# JavaScript, through a host that knows the msgpack wire format and nothing about the schemas.
m12_run_reactor hinted "$(m12_reactor_hinted)" "$M12_WORK/reactor.hinted.err"
assert_eq "simulate_with_hinted_dbs runs for the whole corpus on V8" 0 $?
assert_eq "and reports the seven programs" "$M12_EXPECTED_PROGRAMS" \
  "$(m12_field "$(m12_reactor_hinted)" reactorHinted.programs.count)"
assert_eq "and finished" "1" "$(m12_field "$(m12_reactor_hinted)" reactorHinted.done)"
assert_eq "the host leaked no allocation" 0 \
  "$(m12_field "$(m12_reactor_hinted)" reactorHinted.ownedAllocationsAtExit)"
# Every program decoded a result: the input blob went in as upstream's AvmProvingInputs and the
# result came back as upstream's TxSimulationResult.
assert_eq "every program returned a decodable result" "$M12_EXPECTED_PROGRAMS" \
  "$(grep -c '^hinted\..*\.revertCode ' "$(m12_reactor_hinted)")"
for p in $M12_PROGRAMS; do
  assert_ge "hinted.$p carried a non-empty input blob" 1000 \
    "$(m12_field "$(m12_reactor_hinted)" "hinted.$p.inputBytes")"
  assert_ge "and returned a non-empty result blob" 100 \
    "$(m12_field "$(m12_reactor_hinted)" "hinted.$p.resultBytes")"
  # The hinted entry point builds its own config internally, so it collects no public inputs. That
  # is upstream's behaviour, it is why M15 has a choice to make, and it is asserted rather than
  # worked around.
  assert_eq "and no public inputs, because avm_sim_api.cpp gives that path a default config" 0 \
    "$(m12_field "$(m12_reactor_hinted)" "hinted.$p.publicInputsPresent")"
done
SIMAPI="$M12_WORK/avm_sim_api.cpp"
m8_upstream_file barretenberg/cpp/src/barretenberg/vm2/avm_sim_api.cpp "$SIMAPI"
assert_ge "upstream's own simulate_with_hinted_dbs is what constructs that default config" 1 \
  "$(grep -c 'const PublicSimulatorConfig config = {}' "$SIMAPI")"

m12_run_reactor iface "$(m12_reactor_iface)" "$M12_WORK/reactor.iface.err"
assert_eq "every exported DB method runs on V8" 0 $?
assert_eq "and the run finished" "1" "$(m12_field "$(m12_reactor_iface)" iface.done)"
assert_eq "with no leaked allocation" 0 "$(m12_field "$(m12_reactor_iface)" iface.ownedAllocationsAtExit)"

# Each of the twenty-two, named. A count would go green for a run that called one method twice.
for m in get_contract_instance get_contract_class get_bytecode_commitment get_debug_function_name \
         add_contracts create_checkpoint commit_checkpoint revert_checkpoint; do
  assert_ge "ContractDBInterface.$m produced a line" 1 \
    "$(grep -c "^iface\.contractDb\.$m " "$(m12_reactor_iface)")"
done
for m in get_low_indexed_leaf get_leaf_value \
         get_leaf_preimage_public_data_tree get_leaf_preimage_nullifier_tree \
         insert_indexed_leaves_public_data_tree insert_indexed_leaves_nullifier_tree \
         append_leaves pad_tree create_checkpoint commit_checkpoint revert_checkpoint; do
  assert_ge "LowLevelMerkleDBInterface.$m produced a line" 1 \
    "$(grep -c "^iface\.merkleDb\.$m " "$(m12_reactor_iface)")"
done
# get_sibling_path returns a vector, so the host prints it as sub-keys (`.depth` and one per
# sibling) rather than as one line. Counted on the prefix it actually emits.
assert_ge "LowLevelMerkleDBInterface.get_sibling_path produced its depth and its siblings" 2 \
  "$(grep -c "^iface\.merkleDb\.get_sibling_path\." "$(m12_reactor_iface)")"
assert_eq "get_tree_roots returned all four trees" 4 \
  "$(grep -c '^iface\.merkleDb\.get_tree_roots\.' "$(m12_reactor_iface)")"
assert_eq "get_checkpoint_id was read three times around a checkpoint cycle" 3 \
  "$(grep -c '^iface\.merkleDb\.get_checkpoint_id\.' "$(m12_reactor_iface)")"

# The values, not just the presence. Each of these is an upstream type decoded from msgpack by a
# host that was never told its shape.
instance_class_id="$(m12_field "$(m12_reactor_iface)" iface.contractDb.get_contract_instance)"
assert_true "get_contract_instance found the deployed instance rather than returning nil" \
  test "$instance_class_id" != "nil"
assert_prefix "and its currentContractClassId decoded as a field element" "0x" "$instance_class_id"
assert_eq "of exactly 32 bytes" 66 "${#instance_class_id}"
assert_false "which is not zero" \
  test "$instance_class_id" = "0x0000000000000000000000000000000000000000000000000000000000000000"
assert_prefix "get_bytecode_commitment decoded as a field element" "0x" \
  "$(m12_field "$(m12_reactor_iface)" iface.contractDb.get_bytecode_commitment)"
assert_eq "get_contract_class returned the deployed bytecode length" "bytecodeBytes=21" \
  "$(m12_field "$(m12_reactor_iface)" iface.contractDb.get_contract_class)"
assert_eq "get_debug_function_name is nil, as TestContractDB's implementation returns nullopt" \
  "nil" "$(m12_field "$(m12_reactor_iface)" iface.contractDb.get_debug_function_name)"
assert_eq "get_sibling_path returned a 42-level path" "42" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.get_sibling_path.depth)"
assert_prefix "and its first sibling decoded as a field element" "0x" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.get_sibling_path.0)"
assert_prefix "get_low_indexed_leaf decoded both of its fields" "present=" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.get_low_indexed_leaf)"
assert_eq "insert_indexed_leaves_nullifier_tree returned one low-leaf and one insertion witness" \
  "lowLeaves=1 insertions=1" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.insert_indexed_leaves_nullifier_tree)"
assert_eq "insert_indexed_leaves_public_data_tree likewise" "lowLeaves=1 insertions=1" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.insert_indexed_leaves_public_data_tree)"
assert_eq "the checkpoint id advances inside a checkpoint" "1" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.get_checkpoint_id.inside)"
assert_eq "and is back where it started after the cycle" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.get_checkpoint_id.before)" \
  "$(m12_field "$(m12_reactor_iface)" iface.merkleDb.get_checkpoint_id.after)"

# The failure arms. A revert is a transaction outcome; a bad handle and a malformed input are not,
# and neither of them may be a trap — a trapped instance and a reverted transaction are different
# things and the boundary has to keep them apart.
assert_eq "an unknown DB handle comes back as a status, not a trap" "3" \
  "$(m12_field "$(m12_reactor_iface)" iface.badHandle.status)"
assert_eq "with the specific message" "no such merkle DB handle" \
  "$(m12_field "$(m12_reactor_iface)" iface.badHandle.message)"
assert_eq "bytes that are not msgpack come back as a status too" "1" \
  "$(m12_field "$(m12_reactor_iface)" iface.malformedInput.status)"
assert_eq "carrying a non-empty message in upstream's ErrorResponse shape" "1" \
  "$(m12_field "$(m12_reactor_iface)" iface.malformedInput.messagePresent)"

# --- the write-up ------------------------------------------------------------
assert_file "the reactor write-up exists" "$M12_WRITEUP"
writeup="$(tr -d ',' <"$M12_WRITEUP" 2>/dev/null)"
assert_contains "it enumerates the schema origins in the enumerator's own vocabulary" \
  "origin=ours" "$writeup"
assert_contains "including the upstream one" "origin=upstream" "$writeup"
assert_contains "and the one that arrives with a prepared contribution" "origin=prepared-patch" "$writeup"
assert_contains "it names the one type that is ours" "$M12_OUR_ONLY_TYPE" "$writeup"
assert_contains "with the reason: upstream's envelope lives in the bbapi module" "bbapi" "$writeup"
# The enumerated total, with enough of the sentence around it to be a claim rather than a digit
# match: "42" alone appears in the write-up as a 42-level sibling path as well. The needle carries
# no comma because `$writeup` is read with thousands separators stripped, and stripping them takes
# the sentence's commas with them.
assert_contains "and the enumerated total, in the sentence that makes it a claim" \
  "$M12_EXPECTED_MSGPACK_CHECKS types 0 failures" "$writeup"

finish
