#!/usr/bin/env bash
# verify_block_level_gap_audit_complete
#
# M14's audit, and the check that BUILDS. Every world-state operation block production performs is
# classified present / absent / unnecessary, and every classification is re-derived on this run:
# from the fork at the anchor by pattern, from the two builds by execution, and from the probe's
# output. Nothing is read out of WORLD-STATE.md and agreed with; WORLD-STATE.md is held to what this
# check measured, in the other direction.
#
# WHY THIS IS AN AUDIT AND NOT A LIST. This campaign has been wrong six times about whether
# something needed building, most recently in M13, where an enumeration of `vm2/` missed
# `FuzzerContractDB` under `avm_fuzzer/`. So the implementations of `LowLevelMerkleDBInterface` are
# found by ONE regular expression over the WHOLE fork and asserted as an identity — five, and the
# fifth is `WsdbIpcMerkleDB` under `vm2_wsdb/`, a barretenberg subdirectory parallel to `vm2/`. Six
# would fail this and so would four.
#
# THE ONE PLACE THE M13 ANALOGY BREAKS, and the audit's most useful finding: M13 established that
# upstream's shippable raw contract DB is TypeScript and `cdb` is a transport adapter over it. The
# world state has the same shape and the OPPOSITE answer — `wsdb`'s server, `aztec-wsdb`, is C++ and
# links `world_state` — so there is no store on the other side of that boundary to reach for. That
# is asserted off the `target_link_libraries` BLOCK, matched as whole lines, which is M13's review's
# own correction after `"barretenberg"` matched a path component of every include directory.
#
# It builds two trees, the anchor and the anchor plus M14's patch, and it writes measured.env. The
# other five M14 checks read it and never build a tree of their own.
#
# Run: just verify-block-level-audit

TEST_NAME="verify_block_level_gap_audit_complete"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$(dirname "${BASH_SOURCE[0]}")/lib_m14_world_state.sh"

require_nix
command -v python3 >/dev/null 2>&1 || die "python3 is required"
require_work_dir "$M14_WORK" 8

FORK_SHOW() { git -C "$FORK_ROOT" show "$M6_BASE_REV:$1" 2>/dev/null; }

# ===========================================================================
echo "== A. the fork at the anchor: what exists, by pattern over the WHOLE tree =="
# ===========================================================================

assert_eq "the anchor is the pinned one" "233d8e0993" "$M6_BASE_REV"
assert_true "the anchor commit is in the fork" \
  git -C "$FORK_ROOT" rev-parse --verify --quiet "$M6_BASE_REV^{commit}"

# --- the five implementations of LowLevelMerkleDBInterface ------------------
IMPLS="$(git -C "$FORK_ROOT" grep -h -E "$M14_MERKLE_IMPL_REGEX" "$M6_BASE_REV" -- '*.hpp' '*.cpp' >/dev/null 2>&1; \
         git -C "$FORK_ROOT" grep -E "$M14_MERKLE_IMPL_REGEX" "$M6_BASE_REV" -- '*.hpp' '*.cpp' 2>/dev/null \
         | sed -E "s|^$M6_BASE_REV:||" \
         | sed -E 's|^([^:]+):.*class ([A-Za-z0-9_]+) (final )?: public .*|\2 \1|' \
         | sort -u)"
IMPL_COUNT="$(printf '%s\n' "$IMPLS" | grep -c . )"
assert_eq "LowLevelMerkleDBInterface has exactly five implementations at the anchor" \
  "$M14_EXPECTED_MERKLE_IMPL_COUNT" "$IMPL_COUNT"
assert_eq "and they are these five, by name and path (an identity, not a floor)" \
  "$M14_EXPECTED_MERKLE_IMPLS" "$IMPLS"
note "the fifth is under vm2_wsdb/, a barretenberg subdirectory PARALLEL to vm2/"

# The interface is declared once, and its method count is read off the declaration rather than typed.
DB_HPP="$(FORK_SHOW barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/db.hpp)"
assert_eq "LowLevelMerkleDBInterface is declared exactly once" "1" \
  "$(printf '%s\n' "$DB_HPP" | grep -cE '^class LowLevelMerkleDBInterface \{')"
LLM_BLOCK="$(printf '%s\n' "$DB_HPP" | awk '/^class LowLevelMerkleDBInterface \{/{f=1} f{print} f&&/^\};/{exit}')"
# Counted as `virtual` DECLARATIONS minus the virtual destructor, not by anchoring on `) = 0;`:
# two of the fourteen wrap onto a second line, and the anchored form found twelve. The destructor is
# subtracted by name rather than by assuming it is one of them.
LLM_VIRTUALS="$(printf '%s\n' "$LLM_BLOCK" | grep -cE '^[[:space:]]+virtual ')"
LLM_DTORS="$(printf '%s\n' "$LLM_BLOCK" | grep -cE '^[[:space:]]+virtual ~LowLevelMerkleDBInterface\(\)')"
assert_eq "the interface declares exactly one virtual destructor" "1" "$LLM_DTORS"
assert_eq "and fourteen virtual methods beside it" "$M14_MERKLE_DB_METHOD_COUNT" \
  "$((LLM_VIRTUALS - LLM_DTORS))"
assert_eq "NONE of them takes a WorldStateRevision" "0" \
  "$(printf '%s\n' "$LLM_BLOCK" | grep -cE '\bWorldStateRevision\b')"

# --- the enum has ARCHIVE; the reference's State does not -------------------
IDS="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/merkle_tree_id.hpp \
       | awk '/^enum MerkleTreeId \{/{f=1;next} f&&/^\};/{exit} f{print}' \
       | sed -E 's/^\s*([A-Z0-9_]+)\s*=.*/\1/' | grep -E '^[A-Z0-9_]+$' | sort)"
assert_eq "MerkleTreeId names exactly five trees, ARCHIVE among them" "$M14_MERKLE_TREE_IDS" "$IDS"

REF_HPP="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp)"
STATE_BLOCK="$(printf '%s\n' "$REF_HPP" | awk '/^    struct State \{/{f=1;next} f&&/^    \};/{exit} f{print}')"
STATE_MEMBERS="$(printf '%s\n' "$STATE_BLOCK" | sed -E 's/^\s*[A-Za-z0-9_]+ ([a-z0-9_]+);$/\1/' | grep -E '^[a-z0-9_]+$' | sort | tr '\n' ' ')"
assert_eq "at the anchor MemoryMerkleDB::State holds FOUR trees, and they are these" \
  "l1_to_l2_message_tree note_hash_tree nullifier_tree public_data_tree " "$STATE_MEMBERS"
assert_eq "and none of them is the archive" "0" \
  "$(printf '%s\n' "$STATE_BLOCK" | grep -cE '\barchive')"
assert_eq "no method of the reference takes a WorldStateRevision at the anchor" "0" \
  "$(printf '%s\n' "$REF_HPP" | awk '/^class MemoryMerkleDB \{/{f=1} f{print} f&&/^\};/{exit}' | grep -cE '\bWorldStateRevision\b')"

# --- the vocabulary is the reference's, and the sentinel is documented there
assert_eq "WorldStateRevision is DEFINED in the reference component" "1" \
  "$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/merkle_tree_id.hpp | grep -cE '^struct WorldStateRevision \{')"
assert_contains "and its LATEST sentinel is max(uint32) rather than 0" \
  "std::numeric_limits<block_number_t>::max()" \
  "$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state_reference/merkle_tree_id.hpp)"

# --- the AVM does not touch the archive ------------------------------------
VM2_ARCHIVE="$(git -C "$FORK_ROOT" grep -n -E '\bARCHIVE\b' "$M6_BASE_REV" -- \
                 'barretenberg/cpp/src/barretenberg/vm2/*' 2>/dev/null \
               | grep -v '\.test\.cpp' | sed -E "s|^$M6_BASE_REV:||")"
# TWO lines, in ONE file, and they are a `case` label and the `return` under it — the whole of the
# AVM's interest in the archive. Asserted as both counts, because "one occurrence" was the wrong
# claim: `\bARCHIVE\b` matches the label and the string literal it returns.
assert_eq "ARCHIVE appears in vm2/ outside tests in exactly ONE file" "1" \
  "$(printf '%s\n' "$VM2_ARCHIVE" | cut -d: -f1 | sort -u | grep -c .)"
assert_eq "and that file is the raw-DB tree-name formatter" \
  "barretenberg/cpp/src/barretenberg/vm2/simulation/lib/raw_data_dbs.cpp" \
  "$(printf '%s\n' "$VM2_ARCHIVE" | cut -d: -f1 | sort -u)"
assert_eq "on exactly two lines" "2" "$(printf '%s\n' "$VM2_ARCHIVE" | grep -c .)"
assert_eq "a case label" "1" \
  "$(printf '%s\n' "$VM2_ARCHIVE" | grep -c 'case world_state::MerkleTreeId::ARCHIVE:')"
assert_eq "and the string it returns — no read of the tree anywhere" "1" \
  "$(printf '%s\n' "$VM2_ARCHIVE" | grep -c 'return "ARCHIVE";')"

# The AVM's own snapshot type, which is what get_tree_roots() returns across the interface.
TS_BLOCK="$(FORK_SHOW barretenberg/cpp/src/barretenberg/vm2/common/aztec_types.hpp \
            | awk '/^struct TreeSnapshots \{/{f=1;next} f&&/^\};/{exit} f{print}')"
assert_eq "the AVM's TreeSnapshots carries FOUR trees" "4" \
  "$(printf '%s\n' "$TS_BLOCK" | grep -cE '^\s+AppendOnlyTreeSnapshot [a-z0-9_]+;')"
assert_contains "and it is msgpack-serialised over exactly those four" \
  "MSGPACK_CAMEL_CASE_FIELDS(l1_to_l2_message_tree, note_hash_tree, nullifier_tree, public_data_tree)" \
  "$TS_BLOCK"
note "so an archive root cannot travel through LowLevelMerkleDBInterface in EITHER of M15's shapes"

# --- what pad_tree is for, and why its restriction is not a gap -------------
PAD_TREES="$(FORK_SHOW barretenberg/cpp/src/barretenberg/vm2/simulation/standalone/concrete_dbs.cpp \
             | awk '/^void PureMerkleDB::pad_trees\(\)/{f=1} f{print} f&&/^\}/{exit}')"
assert_eq "PureMerkleDB::pad_trees pads exactly two trees" "2" \
  "$(printf '%s\n' "$PAD_TREES" | grep -cE 'raw_merkle_db\.pad_tree\(')"
assert_contains "the note-hash tree" "MerkleTreeId::NOTE_HASH_TREE," "$PAD_TREES"
assert_contains "and the nullifier tree" "MerkleTreeId::NULLIFIER_TREE," "$PAD_TREES"
assert_not_contains "and NOT the L1->L2 message tree" "L1_TO_L2_MESSAGE_TREE" "$PAD_TREES"
L1L2_APPEND="$(FORK_SHOW yarn-project/stdlib/src/messaging/append_l1_to_l2_messages.ts)"
assert_contains "upstream's own block-level L1->L2 append is a bare appendLeaves" \
  "db.appendLeaves(MerkleTreeId.L1_TO_L2_MESSAGE_TREE, l1ToL2Messages)" "$L1L2_APPEND"
assert_not_contains "with no padding of that tree anywhere in it" "padArrayEnd" "$L1L2_APPEND"
note "so pad_tree refusing L1_TO_L2_MESSAGE_TREE is correct and complete, not a shortfall"

# ===========================================================================
echo
echo "== B. disposition 1: does upstream cover the archive elsewhere, and can it reach wasm? =="
# ===========================================================================

WS_CMAKE="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state/CMakeLists.txt)"
assert_contains "world_state is a barretenberg_module over the reference" \
  "barretenberg_module(world_state crypto_merkle_tree crypto_poseidon2 world_state_reference)" "$WS_CMAKE"
WS_STORES="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state/world_state_stores.hpp)"
assert_contains "and it stores its trees in LMDB" \
  '#include "barretenberg/crypto/merkle_tree/lmdb_store/lmdb_tree_store.hpp"' "$WS_STORES"
assert_contains "including the archive" "LMDBTreeStore::SharedPtr archiveStore;" "$WS_STORES"
WS_HPP="$(FORK_SHOW barretenberg/cpp/src/barretenberg/world_state/world_state.hpp)"
assert_contains "and it needs a thread pool" '#include "barretenberg/common/thread_pool.hpp"' "$WS_HPP"
assert_ge "every WorldState constructor takes a thread_pool_size" 4 \
  "$(printf '%s\n' "$WS_HPP" | grep -cE '^\s+WorldState\(uint64_t thread_pool_size,')"
note "lmdb + a thread pool: this is the implementation that cannot reach wasm32-wasip1"

# The wsdb server is C++, which is where the cdb analogy breaks. The link edges are extracted as a
# BLOCK and matched as whole lines: M13's review found `"barretenberg"` matching a path component of
# every include directory, so a substring here would pass for a target linking nothing.
WSDB_CMAKE="$(FORK_SHOW barretenberg/cpp/src/barretenberg/wsdb/CMakeLists.txt)"
WSDB_EXE_BLOCK="$(printf '%s\n' "$WSDB_CMAKE" | awk '/^target_link_libraries\($/{n++} n==2{print} n==2&&/^\)$/{exit}')"
WSDB_EDGES="$(printf '%s\n' "$WSDB_EXE_BLOCK" | sed -E 's/^\s+//' | grep -vE '^(target_link_libraries\(|aztec-wsdb$|PRIVATE$|\)$)' | sort | tr '\n' ' ')"
assert_eq "aztec-wsdb links exactly these, as whole edges" "barretenberg env ipc_runtime world_state " "$WSDB_EDGES"
assert_contains "and aztec-wsdb is built from C++ sources" "wsdb_ipc_server.cpp" "$WSDB_CMAKE"
CDB_SERVER="$(FORK_SHOW yarn-project/simulator/src/public/cdb_ipc_server.ts | head -5)"
assert_true "M13's contrast still holds: cdb's server IS TypeScript" test -n "$CDB_SERVER"
assert_false "and there is no TypeScript wsdb server beside it" \
  git -C "$FORK_ROOT" cat-file -e "$M6_BASE_REV:yarn-project/simulator/src/public/wsdb_ipc_server.ts"
note "cdb: store in TypeScript. wsdb: store in C++. The world state has no other side to reach for"

# ===========================================================================
echo
echo "== C. disposition 2: can M15's boundary put the archive in TypeScript instead? =="
# ===========================================================================

MT_TS="$(FORK_SHOW yarn-project/foundation/src/trees/merkle_tree.ts)"
assert_contains "upstream's only TypeScript MerkleTree materialises every node" \
  "const expectedNodeCount = 2 ** (height + 1) - 1;" "$MT_TS"
assert_contains "and its constructor ENFORCES that count" \
  "if (nodes.length !== expectedNodeCount) {" "$MT_TS"
# From the PROTOCOL source and not from `aztec/aztec_constants.hpp`, which is gitignored and
# generated at configure time — `git show <anchor>:<it>` fails outright, and the first version of
# this check took the resulting empty string into an arithmetic expression and compared 1 against
# 2,147,483,647. The generated header is cross-checked against this in section D, after the build
# that produces it.
ARCHIVE_H="$(m14_noir_constant ARCHIVE_HEIGHT)"
assert_eq "ARCHIVE_HEIGHT is 30, from noir-projects' constants.nr" "30" "$ARCHIVE_H"
assert_eq "so a TypeScript archive tree would be this many nodes" "2147483647" \
  "$(python3 -c "print(2 ** ($ARCHIVE_H + 1) - 1)")"
TS_FULL_HEIGHT="$(git -C "$FORK_ROOT" grep -l -E '^export (class|abstract class) [A-Za-z0-9_]*(Tree|MerkleTree)\b' \
                   "$M6_BASE_REV" -- 'yarn-project/**/*.ts' 2>/dev/null \
                 | sed -E "s|^$M6_BASE_REV:||" | grep -v '\.test\.ts' | sort | tr '\n' ' ')"
note "TypeScript tree classes at the anchor: $TS_FULL_HEIGHT"
assert_not_contains "none of them is a sparse full-height tree" "sparse" "$TS_FULL_HEIGHT"

# ===========================================================================
echo
echo "== D. the two trees, built =="
# ===========================================================================

m14_base_tree >/dev/null
m14_ext_tree >/dev/null
assert_dir "the pristine anchor worktree exists" "$M14_BASE_TREE"
assert_dir "the patched worktree exists" "$M14_TREE"
assert_eq "the base tree carries no commit beyond the anchor" "0" \
  "$(git -C "$M14_BASE_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
assert_eq "the patched tree carries exactly one" "1" \
  "$(git -C "$M14_TREE" rev-list --count "$M6_BASE_REV..HEAD")"
CHANGED="$(git -C "$M14_TREE" diff --name-only "$M6_BASE_REV" HEAD | sort | tr '\n' ' ')"
assert_eq "and it changes exactly three files" \
"barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp " \
  "$CHANGED"
# The contribution is prepared in full — patch, PR.md, verify.sh — and it is NOT in
# codetracer-specs/upstream-bugs/, because that directory is enumerated by verify_carry_set_complete
# and every entry in it must equal a branch published on origin. Both halves are asserted, so
# neither "it was never prepared" nor "it was quietly filed into the carry set" can pass.
assert_file "the contribution's PR.md is prepared beside the patch" "$M14_PR_MD"
assert_file "and its verify.sh" "$M14_PR_VERIFY"
assert_true "verify.sh is executable" test -x "$M14_PR_VERIFY"
assert_contains "PR.md is written for an upstream audience, with a Kind line" \
  "**Kind:**" "$(cat "$M14_PR_MD" 2>/dev/null)"
assert_contains "and says plainly that it is not filed" "not filed" "$(cat "$M14_PR_MD" 2>/dev/null)"
# THE CARRY SET, NOT THE DIRECTORY. This counted `ls -d aztec-*/` and asserted 5, and it went RED
# at HEAD when M20 prepared a SIXTH candidate contribution (`aztec-revert-code-four-values`) and
# deliberately did not enrol it — committed in codetracer-specs `5ec32ac1`, AFTER the sweep that
# reported M14 green. The property this line is for is "M14's contribution did not get filed into
# the carry set", and the carry set is `carry/series.json`'s `patches`, not the contents of a
# directory that also holds candidates nobody carries. Read from the manifest, which is the single
# source `verify_carry_set_complete` holds the directory to.
assert_eq "the carry set still has exactly five patches, so M11 is untouched" "5" \
  "$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))["patches"]))' "$REPO_ROOT/carry/series.json")"
# …and the entries on disk that are NOT in it are declared, one reason each, rather than merely
# uncounted — so "six directories, five patches" is a stated difference and not a discrepancy.
assert_eq "every on-disk entry outside the carry set is declared not-carried" \
  "$(cd "$M6_UPSTREAM_BUGS" && ls -d aztec-*/ 2>/dev/null | wc -l)" \
  "$(python3 -c 'import json,sys
d = json.load(open(sys.argv[1]))
print(len(d["patches"]) + len([k for k in d.get("not_carried", {}) if not k.startswith("_")]))' \
     "$REPO_ROOT/carry/series.json")"
assert_false "and this contribution is NOT among them" \
  test -e "$M6_UPSTREAM_BUGS/aztec-world-state-reference-block-coverage"
assert_contains "the write-up records why it is not, and what promoting it needs" \
  "verify_pr_branches_match_patches" "$(cat "$M14_WRITEUP" 2>/dev/null)"

# --- the carry exposure, MEASURED rather than estimated ---------------------
# The write-up prices the fallback, and the price is a statement about which other prepared patches
# touch the same files. Derived here from the patch files themselves, because prose about a rebase
# is exactly the kind of claim that is true when written and false a milestone later.
M14_FILES="barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp
barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.cpp
barretenberg/cpp/src/barretenberg/world_state/memory_merkle_db.test.cpp"
OTHER_PATCHES="$(ls "$M6_UPSTREAM_BUGS"/aztec-*/0001-*.patch "$REPO_ROOT"/verification/m*/0001-*.patch 2>/dev/null | grep -v '/m14/')"
assert_ge "there are other prepared patches to be compared against" 9   "$(printf '%s\n' "$OTHER_PATCHES" | grep -c .)"
while read -r f; do
  [ -n "$f" ] || continue
  touched="$(for p in $OTHER_PATCHES; do
               grep -q "^+++ b/$f\$" "$p" && basename "$(dirname "$p")"
             done | sort | tr '\n' ' ')"
  case "$f" in
    */world_state_reference/memory_merkle_db.hpp)
      assert_eq "the shared file is shared with exactly one sibling patch, and it is patch 5"         "aztec-avm-wasm-cmake " "$touched" ;;
    *)
      assert_eq "no other prepared patch touches $(basename "$f")" "" "$touched" ;;
  esac
done <<EOF
$M14_FILES
EOF
# And on the one shared file the hunks do not meet. Line numbers out of the two patches' own hunk
# headers; three lines of diff context, so adjacency is what would matter.
hunks() { awk -v want="$2" '
    $0 == "+++ b/" want { f = 1; next }
    f && /^diff --git/ { exit }
    f && /^@@/ { split($2, a, ","); sub(/^-/, "", a[1]); print a[1] }' "$1"; }
SHARED=barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp
P5_HUNKS="$(hunks "$M6_UPSTREAM_BUGS/aztec-avm-wasm-cmake/0001-build-wasm-optional-AVM_WASM-and-separate-the-AVM-mod.patch" "$SHARED" | tr '\n' ' ')"
M14_HUNKS="$(hunks "$M14_PATCH" "$SHARED" | tr '\n' ' ')"
assert_eq "patch 5 changes that file in three places" "3" "$(printf '%s' "$P5_HUNKS" | wc -w)"
assert_ge "and M14 in several" 5 "$(printf '%s' "$M14_HUNKS" | wc -w)"
# `comm` compares LEXICALLY, so `sort -n` is the wrong order for it: it prints
# "file 2 is not in sorted order" on stderr and then answers anyway, which is a wrong answer with a
# warning nobody reads. Both sides sorted the way comm reads them.
assert_eq "and no hunk start is shared between them" "0" \
  "$(comm -12 <(printf '%s\n' $P5_HUNKS | LC_ALL=C sort) <(printf '%s\n' $M14_HUNKS | LC_ALL=C sort) | grep -c .)"
note "patch 5 hunks at [$P5_HUNKS]; M14 hunks at [$M14_HUNKS]"
# The needle must not straddle a line break: WORLD-STATE.md is hard-wrapped, and the first form of
# this looked for "one file shared with one sibling patch at non-adjacent lines" where the file has
# "one\nfile shared with…". Matched against the file line by line instead, and required to occur
# exactly once so it cannot be satisfied by prose that happens to repeat.
assert_eq "the write-up states the exposure it measured, once" "1" \
  "$(grep -c 'one sibling patch at non-adjacent lines' "$M14_WRITEUP")"
assert_eq "and states which sibling patch it is" "1" \
  "$(grep -c 'aztec-avm-wasm-cmake' "$M14_WRITEUP")"

note "building upstream's own world_state_tests and vm2_tests, base"
m14_build_native "$M14_BASE_TREE" world_state_tests vm2_tests
BASE_CONF_RC=$M14_NATIVE_CONFIGURE_RC; BASE_BUILD_RC=${M14_NATIVE_BUILD_RC:-1}
assert_eq "the base configure exited 0" "0" "$BASE_CONF_RC"
assert_eq "the base build exited 0" "0" "$BASE_BUILD_RC"
assert_not_contains "and emitted no compiler diagnostic at all" "error:" "$(m6_build_log "$M14_BASE_TREE" "$M14_NATIVE_BUILD")"

note "building upstream's own world_state_tests and vm2_tests, patched"
m14_build_native "$M14_TREE" world_state_tests vm2_tests
EXT_CONF_RC=$M14_NATIVE_CONFIGURE_RC; EXT_BUILD_RC=${M14_NATIVE_BUILD_RC:-1}
assert_eq "the patched configure exited 0" "0" "$EXT_CONF_RC"
assert_eq "the patched build exited 0" "0" "$EXT_BUILD_RC"
assert_not_contains "and emitted no compiler diagnostic at all" "error:" "$(m6_build_log "$M14_TREE" "$M14_NATIVE_BUILD")"

# The generated constants header exists only after a configure, and it is what the C++ actually
# compiled against. Cross-checked against the protocol source now that it exists.
for t in "$M14_BASE_TREE" "$M14_TREE"; do
  assert_file "the generated constants header exists in $(basename "$t")" \
    "$t/barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp"
  assert_eq "$(basename "$t"): generated ARCHIVE_HEIGHT equals the protocol source's" \
    "$ARCHIVE_H" "$(m14_generated_constant "$t" ARCHIVE_HEIGHT)"
  assert_eq "$(basename "$t"): generated GENESIS_ARCHIVE_ROOT equals the protocol source's" \
    "$(m14_noir_constant GENESIS_ARCHIVE_ROOT)" "$(m14_generated_constant "$t" GENESIS_ARCHIVE_ROOT)"
done
assert_false "and it is NOT in git — it is generated, which is why it is read from the worktree" \
  git -C "$FORK_ROOT" cat-file -e "$M6_BASE_REV:barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp"

for b in world_state_tests vm2_tests; do
  assert_file "base $b exists" "$(m14_bin "$M14_BASE_TREE" "$b")"
  assert_file "patched $b exists" "$(m14_bin "$M14_TREE" "$b")"
done
assert_false "the two world_state_tests are not the same file" \
  cmp -s "$(m14_bin "$M14_BASE_TREE" world_state_tests)" "$(m14_bin "$M14_TREE" world_state_tests)"

# ===========================================================================
echo
echo "== E. the probe: ONE source, both trees, and it is not told which arm it is =="
# ===========================================================================

for arm in base ext; do
  case "$arm" in base) t="$M14_BASE_TREE" ;; *) t="$M14_TREE" ;; esac
  m14_build_probe "$t"
  rc=$?
  assert_eq "the probe compiles against the $arm tree" "0" "$rc"
  [ "$rc" -eq 0 ] || note "$(tail -20 "$t/m14-probe.log")"
done
BASE_OUT="$M14_WORK/probe-base.txt"
EXT_OUT="$M14_WORK/probe-ext.txt"
m14_run_probe "$M14_BASE_TREE" "$BASE_OUT"; assert_eq "the base probe exited 0" "0" "$?"
m14_run_probe "$M14_TREE" "$EXT_OUT";      assert_eq "the patched probe exited 0" "0" "$?"
assert_eq "the base probe ran to completion" "1" "$(m14_key "$BASE_OUT" probe_complete)"
assert_eq "the patched probe ran to completion" "1" "$(m14_key "$EXT_OUT" probe_complete)"
assert_eq "the base probe wrote nothing to stderr" "0" "$(wc -c <"$BASE_OUT.err")"
assert_eq "the patched probe wrote nothing to stderr" "0" "$(wc -c <"$EXT_OUT.err")"

# The compile-time answer, from the same source in both arms.
assert_eq "base: TreeRoots has NO archive_tree" "0" "$(m14_key "$BASE_OUT" archive_in_tree_roots)"
assert_eq "base: MemoryMerkleDB has NO update_archive" "0" "$(m14_key "$BASE_OUT" update_archive_present)"
assert_eq "patched: TreeRoots HAS archive_tree" "1" "$(m14_key "$EXT_OUT" archive_in_tree_roots)"
assert_eq "patched: MemoryMerkleDB HAS update_archive" "1" "$(m14_key "$EXT_OUT" update_archive_present)"
assert_eq "patched: and the genesis header hash is computable from the four snapshots" "1" \
  "$(m14_key "$EXT_OUT" compute_initial_block_header_hash_present)"
assert_ge "the base probe reported a substantial number of keys" 30 "$(m14_key_count "$BASE_OUT")"
assert_ge "the patched probe reported more" "$(m14_key_count "$BASE_OUT")" "$(m14_key_count "$EXT_OUT")"

# ===========================================================================
echo
echo "== F. the classification, and WORLD-STATE.md held to it =="
# ===========================================================================

assert_file "the write-up exists" "$M14_WRITEUP"
DOC="$(cat "$M14_WRITEUP" 2>/dev/null)"

# Every implementation the enumeration found must be NAMED in the write-up.
while read -r cls _path; do
  [ -n "$cls" ] || continue
  assert_contains "the write-up names the implementation $cls" "$cls" "$DOC"
done <<EOF
$IMPLS
EOF

# The thirteen operations, each classified, each with its verdict word present.
for op in "append note hashes" "insert nullifiers" "write public data" "pad note-hash and nullifier" \
          "append L1->L2 messages" "pad the L1->L2 tree" "read the state reference" \
          "read the archive snapshot" "updateArchive" "genesis archive seed" \
          "block-pinned reads" "checkpoint across a block" "commit, rollback, unwind"; do
  assert_contains "the write-up classifies: $op" "$op" "$DOC"
done
for word in "present" "absent" "unnecessary"; do
  assert_contains "the write-up uses the verdict word '$word'" "$word" "$DOC"
done

# The four dispositions, in the milestone's order, all discussed, the one taken stated.
for d in "does upstream already cover it elsewhere" "can M15's boundary shape avoid needing it" \
         "is a named notImplemented throw sufficient" "does it need an extension"; do
  assert_contains "the write-up works the disposition order: $d" "$d" "$DOC"
done
assert_contains "and states the disposition taken for the archive tree" "DECISION: extend" "$DOC"
assert_contains "and the one taken for block-pinned reads" "DECISION: not needed" "$DOC"

# Prose that would go stale silently is bound to a measured number here.
assert_contains "the write-up records the five implementations as a count" \
  "five implementations" "$DOC"
assert_contains "the write-up records that wsdb's server is C++, unlike cdb's" \
  "aztec-wsdb" "$DOC"
assert_contains "the write-up records the TypeScript node count" "2,147,483,647" "$DOC"
assert_contains "the write-up records that the AVM's TreeSnapshots carries four trees" \
  "TreeSnapshots" "$DOC"

# ===========================================================================
echo
echo "== G. measured.env, for the five checks that do not build =="
# ===========================================================================

{
  echo "# written by $TEST_NAME on $(date -Is) — regenerate with 'just verify-block-level-audit'"
  echo "M14_BASE_TREE=$M14_BASE_TREE"
  echo "M14_TREE=$M14_TREE"
  echo "M14_PROBE_BASE=$BASE_OUT"
  echo "M14_PROBE_EXT=$EXT_OUT"
  echo "M14_BASE_WORLD_STATE_TESTS=$(m14_bin "$M14_BASE_TREE" world_state_tests)"
  echo "M14_EXT_WORLD_STATE_TESTS=$(m14_bin "$M14_TREE" world_state_tests)"
  echo "M14_BASE_VM2_TESTS=$(m14_bin "$M14_BASE_TREE" vm2_tests)"
  echo "M14_EXT_VM2_TESTS=$(m14_bin "$M14_TREE" vm2_tests)"
  echo "M14_MERKLE_IMPL_COUNT=$IMPL_COUNT"
} >"$M14_MEASURED"
assert_file "measured.env was written" "$M14_MEASURED"
assert_eq "and it names both trees" "2" "$(grep -cE '^M14_(BASE_)?TREE=' "$M14_MEASURED")"

finish
