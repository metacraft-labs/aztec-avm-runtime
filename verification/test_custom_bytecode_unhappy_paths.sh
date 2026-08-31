#!/usr/bin/env bash
# test_custom_bytecode_unhappy_paths — M18.
#
# The verification entry: "Truncated instructions, invalid opcodes, invalid tags and out-of-range
# program counters produce reverts through the combined stack, not host-side crashes."
#
# ===========================================================================================
# THE STATED BLOCKER WAS THE ASSEMBLER, AND IT IS STILL TRUE — AND STILL NOT IN THE WAY.
# ===========================================================================================
#
# The recorded blocker is that upstream's twelve malformed programs are built by the DELETED
# TypeScript AVM's `encodeToBytecode` and opcode classes, and this repository has no assembler.
# Re-measured 2026-08-31 and asserted below rather than quoted: nothing under `orchestration/src`,
# `browser/src` or `tools/` mentions `encodeToBytecode` or the AVM's opcode modules, and
# `fixtures/avm-programs/programs.json`'s `bytes` field is an integer LENGTH rather than hex.
#
# BUT THE FOUR UNHAPPY PATHS THE ENTRY NAMES DO NOT NEED AN ASSEMBLER, because each of them is
# defined by what the bytes are NOT:
#
#   an INVALID OPCODE          a byte no opcode uses                              1 byte
#   a TRUNCATED INSTRUCTION    a VALID opcode with its operands cut off           1 byte
#   an INVALID TAG             that instruction at full length, tag byte bad      5 bytes
#   an OUT-OF-RANGE PC         a program with nothing at the counter              0 bytes
#
# EVERY CONSTANT IN THEM IS DERIVED FROM THE AVM'S OWN HEADERS AT THE PINNED ANCHOR, TWICE.
# `tools/run_token_block_arms.mjs` reads `WireOpCode` and `ValueTag` out of the fork and hands the
# three numbers to the driver; this check re-derives all three INDEPENDENTLY, with its own parser,
# and asserts they agree — and asserts the invalid opcode byte really is above the enum's sentinel,
# because an eight-bit enum could in principle grow into it and this arm would then be exercising a
# VALID opcode. It also derives SET_8's WIRE LENGTH from upstream's own operand table and requires
# the AVM's truncation diagnostic to name that length, so the arm is pinned to the encoding rather
# than to a message.
#
# THE WELL-FORMED CONTROL IS THE ASSERTION THE OTHER FOUR REST ON. "Malformed bytecode reverts" is
# equally satisfied by an AVM that refuses ALL custom bytecode. So a fifth program is `AvmTest`'s
# own real `public_dispatch` bytecode, registered as a custom-bytecode contract and called with the
# function selector as calldata field 0 — which is exactly what the vendored builder's custom path
# produces, since with no `fnName` it maps the arguments to fields and prepends nothing. It runs
# 179 instructions and returns the function's answer.
#
# AND "NOT HOST-SIDE CRASHES" IS ASSERTED BY THE ARM'S SHAPE RATHER THAN BY AN ABSENCE. All five
# programs run in ONE process, in order, and the control runs LAST — so a host that died on a
# malformed program could not report the control at all. Every malformed program is additionally
# asserted to be `processed` rather than `failed`: a revert is a transaction outcome and a host
# error is not, and upstream's processor puts them in different sets.
#
# Run: just verify-custom-bytecode

TEST_NAME="test_custom_bytecode_unhappy_paths"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

CPP_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
OPCODES_HPP="barretenberg/cpp/src/barretenberg/vm2/common/opcodes.hpp"
TAGS_HPP="barretenberg/cpp/src/barretenberg/vm2/common/tagged_value.hpp"
SERIAL_CPP="barretenberg/cpp/src/barretenberg/vm2/simulation/lib/serialization.cpp"

anchor_file() { git -C "$FORK_ROOT" show "$CPP_ANCHOR:$1" 2>/dev/null \
  || die "the fork at $FORK_ROOT has no $1 at $CPP_ANCHOR (this check's premise is stale)"; }

WORK_HDR="${TB_WORK}/anchor-headers"
mkdir -p "$WORK_HDR" || die "could not create $WORK_HDR"
anchor_file "$OPCODES_HPP" > "$WORK_HDR/opcodes.hpp"
anchor_file "$TAGS_HPP"    > "$WORK_HDR/tagged_value.hpp"
anchor_file "$SERIAL_CPP"  > "$WORK_HDR/serialization.cpp"
note "opcode, tag and serialization sources read at $CPP_ANCHOR"
assert_ge "the opcode header was read rather than left empty" 1000 \
  "$(wc -c < "$WORK_HDR/opcodes.hpp" | tr -d ' ')"
assert_ge "…and the serialization source with it" 5000 \
  "$(wc -c < "$WORK_HDR/serialization.cpp" | tr -d ' ')"

# THE PARSER IS A SECOND IMPLEMENTATION of the one `tools/run_token_block_arms.mjs` performs in
# JavaScript, and the two are compared below. It refuses with `NO-ENUM` rather than answering 0 for
# a declaration it cannot find, so a stale header path fails as itself.
enum_index() { python3 "$VERIFY_DIR/_avm_enum.py" "$1" "$2" "$3"; }
enum_count() { python3 "$VERIFY_DIR/_avm_enum.py" "$1" "$2"; }

OPCODE_DECL='enum class WireOpCode : uint8_t {'
TAG_DECL='enum class ValueTag : uint8_t {'

SET_8="$(enum_index "$WORK_HDR/opcodes.hpp" "$OPCODE_DECL" SET_8)"
SENTINEL="$(enum_index "$WORK_HDR/opcodes.hpp" "$OPCODE_DECL" LAST_OPCODE_SENTINEL)"
OPCODE_COUNT="$(enum_count "$WORK_HDR/opcodes.hpp" "$OPCODE_DECL")"
TAG_COUNT_RAW="$(enum_count "$WORK_HDR/tagged_value.hpp" "$TAG_DECL")"

# THE PARSER'S OWN NEGATIVE CONTROL: asked for a declaration that is not there it must REFUSE, so
# every number above is produced by an instrument that can answer "I could not read this".
assert_eq "the enum parser refuses a declaration it cannot find" \
  "NO-ENUM" "$(enum_count "$WORK_HDR/opcodes.hpp" "enum class NoSuchEnum : uint8_t {")"
assert_eq "…and names a member that is not there rather than inventing an index" \
  "ABSENT" "$(enum_index "$WORK_HDR/opcodes.hpp" "$OPCODE_DECL" NO_SUCH_OPCODE)"

# ---------------------------------------------------------------------------
# PART 0 — the three constants, re-derived here and compared with the tool's
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm blocks)"
assert_eq "the arms were derived against the same anchor this check reads" \
  "$CPP_ANCHOR" "$(tb_arm_meta opcodes.anchor)"
assert_ge "the WireOpCode enum has a substantial number of members" 40 "$OPCODE_COUNT"
assert_eq "this check and the tool agree on how many there are" \
  "$OPCODE_COUNT" "$(tb_arm_meta opcodes.opcodeCount)"
assert_eq "…and on SET_8's index" "$SET_8" "$(tb_arm_meta opcodes.setOpcode)"
assert_eq "…and on the sentinel's" "$SENTINEL" "$(tb_arm_meta opcodes.sentinel)"
assert_true "SET_8 is a real opcode index rather than a parse failure" test "$SET_8" -ge 0
# THE ASSERTION THAT MAKES THE INVALID-OPCODE ARM A MEASUREMENT: an eight-bit enum could grow into
# 0xFF, and then that arm would be exercising a VALID opcode while still reporting a revert.
INVALID_OPCODE="$(tb_arm_meta opcodes.invalidOpcode)"
assert_true "the byte the arm calls invalid really is above the enum's sentinel" \
  test "$INVALID_OPCODE" -gt "$SENTINEL"
INVALID_TAG="$(tb_arm_meta opcodes.invalidTag)"
assert_true "and the byte it calls an invalid tag is above the tag enum" \
  test "$INVALID_TAG" -ge "$TAG_COUNT_RAW"
assert_ge "the tag enum is a real enum" 5 "$TAG_COUNT_RAW"

# SET_8's WIRE LENGTH, from upstream's own operand table, so the truncation arm is pinned to the
# ENCODING and not to a diagnostic string.
SET8_LEN="$(python3 - "$WORK_HDR/serialization.cpp" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
sizes = {"INDIRECT8": 1, "INDIRECT16": 2, "TAG": 1, "UINT8": 1, "UINT16": 2, "UINT32": 4,
         "UINT64": 8, "UINT128": 16, "FF": 32}
m = re.search(r"\{\s*WireOpCode::SET_8,\s*\{([^}]*)\}", src)
if not m:
    print("NO-SPEC"); raise SystemExit(0)
ops = re.findall(r"OperandType::([A-Z0-9]+)", m.group(1))
if not ops:
    print("NO-OPERANDS"); raise SystemExit(0)
print(1 + sum(sizes[o] for o in ops))
PY
)"
assert_eq "SET_8's wire length, derived from upstream's own operand table" "5" "$SET8_LEN"

# ---------------------------------------------------------------------------
# PART 1 — THE ASSEMBLER REALLY IS ABSENT, so the shape of this check is a decision
# ---------------------------------------------------------------------------

# THE SCAN STRIPS COMMENTS, AND THIS CHECK IS ITS OWN WORKED EXAMPLE OF WHY.
# `orchestration/src/token_block_driver.ts` NAMES `encodeToBytecode` in the paragraph explaining
# that nothing calls it — so the first version of this assertion reported the encoder present, in
# the file whose comment says it is absent. That is "a citation is the opposite of a dependency",
# this campaign's own rule, arriving in this pass's own work. The stripper is the string-aware one
# `_import_closure.py` owns, and BOTH halves are asserted: it left code behind, and it removed the
# prose that caused the failure.
RAW_SOURCES="$(cat "$REPO_ROOT"/orchestration/src/*.ts "$REPO_ROOT"/browser/src/*.ts "$REPO_ROOT"/tools/*.mjs 2>/dev/null)"
assert_ge "the shipped sources were read rather than an empty set" 50000 \
  "$(printf '%s' "$RAW_SOURCES" | wc -c | tr -d ' ')"
SHIPPED_SOURCES="$(printf '%s' "$RAW_SOURCES" | python3 -c '
import sys, pathlib
sys.path.insert(0, sys.argv[1])
from _import_closure import strip_comments
sys.stdout.write(strip_comments(sys.stdin.read()))' "$VERIFY_DIR")"
assert_ge "the stripper left the CODE behind" 20000 \
  "$(printf '%s' "$SHIPPED_SOURCES" | wc -c | tr -d ' ')"
assert_true "…and the prose really was there to remove, in this pass\'s own driver" \
  str_has_sub "$RAW_SOURCES" "encodeToBytecode"
assert_false "no shipped source assembles AVM bytecode with upstream's deleted encoder" \
  str_has_sub "$SHIPPED_SOURCES" "encodeToBytecode"
assert_false "…nor imports the deleted TypeScript AVM's serialization module" \
  str_has_sub "$SHIPPED_SOURCES" "bytecode_serialization"
assert_eq "and the pinned program corpus carries LENGTHS rather than hex" "int" \
  "$(python3 -c '
import json
d = json.load(open("'"$REPO_ROOT"'/fixtures/avm-programs/programs.json"))["programs"]
first = next(iter(d.values()))
print(type(first["bytes"]).__name__)')"

# ---------------------------------------------------------------------------
# PART 2 — FOUR MALFORMED PROGRAMS, FOUR REVERTS, FOUR DIFFERENT REASONS
# ---------------------------------------------------------------------------

assert_eq "the arm ran the five programs this check reads, control last" \
  '["invalidOpcode","truncatedInstruction","invalidTag","pcOutOfRange","wellFormed"]' \
  "$(tb_block_labels customBytecode)"

for program in invalidOpcode truncatedInstruction invalidTag pcOutOfRange; do
  assert_eq "$program was PROCESSED — a revert is a transaction outcome, not a host error" \
    "[\"$program\"]" "$(tb_block customBytecode "$program" processed)"
  assert_eq "…and is not in the block's failed set, where a host error would land" \
    "[]" "$(tb_block customBytecode "$program" failed)"
  assert_eq "…and it REVERTED" "1" "$(tb_block customBytecode "$program" "revertCodes.$program")"
  assert_true "…with a reason the AVM supplied" \
    test "$(tb_block customBytecode "$program" "revertReasons.$program")" != "null"
done

# THE FOUR REASONS ARE FOUR REASONS. A single "malformed bytecode" message for all of them would
# satisfy every assertion above while telling a developer nothing about which path was taken.
REASONS="$(for p in invalidOpcode truncatedInstruction invalidTag pcOutOfRange; do
  tb_block customBytecode "$p" "revertReasons.$p"
done)"
assert_eq "the four diagnostics are four DIFFERENT diagnostics" "4" \
  "$(printf '%s\n' "$REASONS" | sort -u | wc -l | tr -d ' ')"

assert_contains "the invalid opcode is named, with the byte the check derived" \
  "$INVALID_OPCODE" "$(tb_block customBytecode invalidOpcode revertReasons.invalidOpcode)"
assert_contains "…as an opcode out of range" \
  "not in the range of valid opcodes" "$(tb_block customBytecode invalidOpcode revertReasons.invalidOpcode)"
assert_contains "the truncated instruction is named as not fitting in the bytecode" \
  "does not fit in bytecode" "$(tb_block customBytecode truncatedInstruction revertReasons.truncatedInstruction)"
assert_contains "…and the size it says it needed is SET_8's derived wire length" \
  "instruction size: $SET8_LEN" \
  "$(tb_block customBytecode truncatedInstruction revertReasons.truncatedInstruction)"
assert_contains "the invalid tag is named as a tag check" \
  "Tag check failed" "$(tb_block customBytecode invalidTag revertReasons.invalidTag)"
assert_contains "the out-of-range counter is named as a program counter" \
  "program counter" "$(tb_block customBytecode pcOutOfRange revertReasons.pcOutOfRange)"

# The one-byte and five-byte programs are the lengths this check believes they are.
assert_eq "the invalid-opcode program is one byte" "1" "$(tb_arm customBytecode registered.invalidOpcode.bytes)"
assert_eq "the truncated program is one byte, which is why it is truncated" \
  "1" "$(tb_arm customBytecode registered.truncatedInstruction.bytes)"
assert_eq "the invalid-tag program is SET_8's full wire length" \
  "$SET8_LEN" "$(tb_arm customBytecode registered.invalidTag.bytes)"
assert_eq "the out-of-range-counter program has no bytes at all" \
  "0" "$(tb_arm customBytecode registered.pcOutOfRange.bytes)"

# ---------------------------------------------------------------------------
# PART 3 — THE WELL-FORMED CONTROL. The path works, so the four reverts are about the bytes.
# ---------------------------------------------------------------------------

assert_eq "the well-formed custom-bytecode program did NOT revert" \
  "0" "$(tb_block customBytecode wellFormed revertCodes.wellFormed)"
assert_eq "…and the module's own four-valued code agrees" \
  "0" "$(tb_block customBytecode wellFormed rawRevertCodes.0)"
assert_ge "…having executed a real dispatch rather than halting at instruction one" 100 \
  "$(tb_block customBytecode wellFormed instructionsPerSimulation.0)"
assert_eq "…and returned the called function's own answer" \
  '["8"]' "$(tb_block customBytecode wellFormed returnValues.0)"
assert_ge "…from a program that is a real contract's bytecode" 1000 \
  "$(tb_arm customBytecode registered.wellFormed.bytes)"

# EVERY MALFORMED PROGRAM HALTED AT ITS FIRST INSTRUCTION, and the control did not — which is what
# separates "the bytes are rejected at fetch" from "the program ran and then failed".
for program in invalidOpcode truncatedInstruction invalidTag pcOutOfRange; do
  assert_eq "$program halted at instruction one, at the fetch" \
    "1" "$(tb_block customBytecode "$program" "instructionsPerSimulation.0")"
done

# ---------------------------------------------------------------------------
# PART 4 — NOT HOST-SIDE CRASHES, asserted by the shape rather than by an absence
# ---------------------------------------------------------------------------
#
# All five programs ran in ONE process, in order, with the control LAST. A host that died on a
# malformed program could not have reported the control at all — so the control's presence IS the
# no-crash claim, and it is a positive one.

assert_eq "all five programs were registered in the module, one class each" "5" \
  "$(tb_arm customBytecode registered \
     | python3 -c 'import json,sys; print(sum(v["classes"] for v in json.load(sys.stdin).values()))')"
assert_eq "and one instance each" "5" \
  "$(tb_arm customBytecode registered \
     | python3 -c 'import json,sys; print(sum(v["instances"] for v in json.load(sys.stdin).values()))')"
# EVERY BLOCK REACHED ITS SEAL, AND THE VALUE IS ASSERTED RATHER THAN THE AGREEMENT. A set of size
# one is equally produced by five blocks that all reported `MISSING`, which is what an arm that
# never ran looks like through the accessor. So the value is named first and the agreement second.
SEAL_VERDICT="$(tb_block customBytecode wellFormed sealRefusal)"
assert_true "the seal verdict is a real one rather than a missing field" \
  test "$SEAL_VERDICT" != "MISSING"
for b in invalidOpcode truncatedInstruction invalidTag pcOutOfRange wellFormed; do
  assert_eq "$b reached its seal and got the same verdict, so it did not abort" \
    "$SEAL_VERDICT" "$(tb_block customBytecode "$b" sealRefusal)"
done
assert_eq "and the contract store's checkpoint depth is zero after the last of them" \
  "0" "$(tb_block customBytecode wellFormed checkpointDepthAfter.contracts)"

finish
