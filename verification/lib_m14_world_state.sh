#!/usr/bin/env bash
# Shared machinery for the M14 checks — block-level world-state coverage.
#
# WHAT M14 CHANGES, AND WHERE.
#
# TWO worktrees of the fork at the pinned anchor, and the only difference between them is M14's own
# patch:
#
#   m14base   233d8e0993, pristine. The tree where the archive tree is ABSENT, and the tree the
#             absence has to be demonstrated on rather than inferred from a header.
#   m14       233d8e0993 + ONE patch: the archive tree on
#             `world_state_reference::MemoryMerkleDB`, and five more cases in upstream's own
#             canonical-fidelity gate under `world_state/`.
#
# One native build directory in each, `default` preset, upstream's own targets:
#
#   build-native  -> bin/world_state_tests   the real, lmdb-backed WorldState AND the reference,
#                                            driven side by side by upstream's own equivalence gate
#                 -> bin/vm2_tests           1,803 upstream tests, the native-neutrality denominator
#
# WHY THE ANCHOR AND NOT THE AVM_WASM STACK. Every other overlay in this campaign is a downstream
# target that sits on M6's four patches. This one is not: it changes a component the AVM does not
# use — `MerkleTreeId::ARCHIVE` appears in `vm2/` only in a tree-name switch, and the AVM's own
# four-tree `TreeSnapshots` could not carry an archive root without a circuit change — so it is
# prepared against pristine upstream, where it is reviewable on its own terms. Its argument is
# upstream's own: `world_state/memory_merkle_db.test.cpp` constructs a WorldState with FIVE trees
# and compares four, and a fidelity gate that omits a tree the real implementation has is a weaker
# gate.
#
# THE PROBE. `verification/m14/world_state_block_probe.cpp` is ONE source compiled and run against
# BOTH trees. It detects what the tree it was compiled against can do with `requires`-expressions
# and reports it; it is not told which arm it is. That is what makes `archive_in_tree_roots=0` on
# the base tree a statement the compiler made about the base tree's own header rather than an
# `#ifdef` we set. It is compiled with the flags CMake used for the reference's own translation
# unit, read out of that tree's `compile_commands.json`, so the probe is built the way the library
# it links was built rather than with flags typed here.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, or a probe that
# printed no keys is `die` or a failed assertion, never a printed SKIP.
#
# Not to be executed directly: sourced by verification/verify_*.sh and test_*.sh, AFTER lib.sh.

# MEASURED on 32 cores with the compiler cache the dev shells now provide: the two trees together
# are about 2.5 GB and, from an empty $M14_WORK against a cache that already holds the anchor,
# a few minutes. From a cold cache the dominating cost is one `vm2_tests` per tree, measured at
# 327 s each. The 8 GB floor below is a precondition, not a prediction; /tmp is usually a tmpfs and
# is the wrong place, so this defaults under $HOME.
M14_WORK="${M14_WORK:-$HOME/.cache/aztec-m14-archive}"
M6_WORK="$M14_WORK"
export M14_WORK M6_WORK

# shellcheck source=lib_avm_wasm.sh
. "$VERIFY_DIR/lib_avm_wasm.sh"

# M14's own patch, with the PR.md and verify.sh a sixth upstream contribution needs, all three beside
# each other here.
#
# THEY ARE DELIBERATELY NOT IN codetracer-specs/upstream-bugs/. That directory is not a drop box: it
# is ENUMERATED. verify_carry_set_complete does `ls -d aztec-*/` over it and requires every entry to
# be in carry/series.json, and verify_pr_branches_match_patches then requires every carry-set entry
# to equal a branch PUBLISHED on our fork's origin, asserting six branch identities as a count. So
# creating a sixth entry there is a claim that a sixth branch is published, and this milestone
# pushes nothing. Promoting these three files is a person's command and is an Outstanding Task,
# exactly as M13 left MemoryContractDB. The milestone's fourth deliverable asks for the directory
# directly and is mis-specified in that respect; the write-up says so.
M14_PATCH="$REPO_ROOT/verification/m14/0001-feat-world_state_reference-archive-tree-so-the-in-me.patch"
M14_PR_MD="$REPO_ROOT/verification/m14/PR.md"
M14_PR_VERIFY="$REPO_ROOT/verification/m14/verify.sh"

M14_BASE_TREE_NAME=m14base
M14_TREE_NAME=m14
M14_NATIVE_BUILD=build-native

M14_PROBE_SRC="$REPO_ROOT/verification/m14/world_state_block_probe.cpp"

# The write-up whose claims the checks re-derive rather than trust.
M14_WRITEUP="$REPO_ROOT/WORLD-STATE.md"

# Tier D's capture from Aztec's production LMDB world state. Read, never written, by these checks.
M14_TIER_D="$REPO_ROOT/fixtures/trees/world-state-vectors.json"

# The protocol constants, from BOTH of the places they exist, because the first attempt at these
# checks reached for the wrong one and failed loudly rather than quietly:
#
#   `barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp` is NOT IN GIT. It is gitignored
#   (`barretenberg/cpp/.gitignore:32`) and GENERATED at configure time by
#   `scripts/remake-constants.sh` — which is why the fork's dev shell has to provide
#   `clang-format-20` under that exact versioned name. `git show <anchor>:<that path>` fails with
#   "exists on disk, but not in", and a check that read it that way got an empty string and then
#   compared 2 ** (empty + 1) - 1 = 1 against 2,147,483,647.
#
# So: m14_generated_constant reads the artefact the build actually consumed, out of a prepared
# worktree; m14_noir_constant reads the protocol source, which IS in git at the anchor. Where a
# constant is a literal on both sides the checks assert the two AGREE, which is stronger than either.
M14_NOIR_CONSTANTS="noir-projects/fnd/noir-protocol-circuits/crates/types/src/constants.nr"

m14_generated_constant() { # <tree> <NAME>
  awk -v n="$2" '$1 == "#define" && $2 == n { v = $3; gsub(/"/, "", v); print v; exit }' \
    "$1/barretenberg/cpp/src/barretenberg/aztec/aztec_constants.hpp" 2>/dev/null
}

# The right-hand side of a `pub global NAME: type = …;`, with whitespace, the trailing semicolon and
# any trailing comment removed. Declarations wrap, so it accumulates lines until it sees the `;`.
m14_noir_constant() { # <NAME>
  git -C "$FORK_ROOT" show "$M6_BASE_REV:$M14_NOIR_CONSTANTS" 2>/dev/null \
    | awk -v n="$1" '
        index($0, "pub global " n ":") == 1 {
          sub(/^[^=]*=[ \t]*/, "")
          rest = $0
          while (index(rest, ";") == 0) { if ((getline line) <= 0) break; rest = rest line }
          sub(/;.*$/, "", rest)
          gsub(/[ \t]/, "", rest)
          print rest
          exit
        }'
}

# ---------------------------------------------------------------------------
# THE ENUMERATION, as patterns rather than as lists.
#
# `([A-Za-z0-9_]+::)*` and not `([A-Za-z_]+::)*`: M13's review measured that the second finds seven
# implementations where the first finds eight, because `avm2` has a digit in it. `\b` on the
# interface name, because `LowLevelMerkleDBInterface` is a prefix of nothing today and that is
# exactly the kind of thing that stops being true.
# ---------------------------------------------------------------------------
M14_MERKLE_IMPL_REGEX='class [A-Za-z0-9_]+ (final )?: public ([A-Za-z0-9_]+::)*LowLevelMerkleDBInterface\b'

# The five, as an IDENTITY: "class path" per line, sorted. Six would fail this, and so would four.
# `WsdbIpcMerkleDB` is under `vm2_wsdb/`, a barretenberg subdirectory PARALLEL to `vm2/` — the same
# shape as the `avm_fuzzer/` omission M13 found, and the reason this is a pattern over the whole
# fork rather than a walk of `vm2/`.
M14_EXPECTED_MERKLE_IMPLS="HintedRawMerkleDB barretenberg/cpp/src/barretenberg/vm2/simulation/lib/raw_data_dbs.hpp
HintingRawDB barretenberg/cpp/src/barretenberg/vm2/simulation/lib/hinting_dbs.hpp
MemoryMerkleDB barretenberg/cpp/src/barretenberg/vm2/simulation/lib/memory_merkle_db.hpp
MockLowLevelMerkleDB barretenberg/cpp/src/barretenberg/vm2/simulation/testing/mock_dbs.hpp
WsdbIpcMerkleDB barretenberg/cpp/src/barretenberg/vm2_wsdb/wsdb_ipc_merkle_db.hpp"
M14_EXPECTED_MERKLE_IMPL_COUNT=5

# The fourteen methods of LowLevelMerkleDBInterface, taken from the interface's own declaration
# rather than typed here. NONE of them takes a WorldStateRevision, which is the audit's second
# finding and is asserted against the declaration and against the compiled symbol table.
M14_MERKLE_DB_METHOD_COUNT=14

# The five ids in MerkleTreeId. ARCHIVE is one of them at the anchor; what it is not, at the anchor,
# is a member of MemoryMerkleDB::State.
M14_MERKLE_TREE_IDS="ARCHIVE
L1_TO_L2_MESSAGE_TREE
NOTE_HASH_TREE
NULLIFIER_TREE
PUBLIC_DATA_TREE"

# The upstream equivalence gate, by name. SEVEN at the anchor, TWELVE with the patch — asserted as
# two identities and as the difference between them, so "the patch adds five cases" is a measured
# difference rather than a constant.
M14_BASE_GATE_TESTS="AppendNoteHashes
Checkpoints
GenesisMatches
InsertAndUpdatePublicData
InsertNullifiers
MixedSequence
PadNoteHashTree"
M14_BASE_GATE_TEST_COUNT=7
M14_NEW_GATE_TESTS="ArchiveParticipatesInCheckpoints
ArchiveThroughTreeIdDispatch
GenesisArchiveMatchesPublishedConstants
UpdateArchiveMatchesWorldState
UpdateArchiveRejectsMismatchedStateReference"
M14_NEW_GATE_TEST_COUNT=5
M14_GATE_SUITE="MemoryMerkleDBEquivalenceTest"

# Upstream's own block-0 tests in world_state_tests, run by name as the execution evidence that the
# real WorldState honours a view pinned at block 0 while the canonical tip moves. This is the
# regression the LATEST sentinel exists to prevent, and it is upstream's test rather than ours.
M14_BLOCK_ZERO_TESTS="WorldStateTest.ForkingAtBlock0SameState
WorldStateTest.ForkingAtBlock0AndAdvancingFork
WorldStateTest.ForkingAtBlock0AndAdvancingCanonicalState"
M14_BLOCK_ZERO_TEST_COUNT=3

# Upstream's own native vm2 denominator, M9's figure and M7's, re-derived on every run.
M14_VM2_TESTS_DECLARED=1803

# ---------------------------------------------------------------------------
# m14_base_tree / m14_ext_tree  ->  absolute path of the prepared worktree
#
# `m6_tree_or_die` is used the way M12 and M13 use it, and for M6's reason: `tree="$(m14_ext_tree)"`
# would run the function in a SUBSHELL, so the `export` inside it would export into that subshell
# and the caller would get nothing. Call it, discard stdout, read the variable.
# ---------------------------------------------------------------------------
m14_require_patch() {
  [ -f "$M14_PATCH" ] || die "M14's prepared patch is missing: $M14_PATCH"
}

m14_base_tree() {
  M14_BASE_TREE=$(m6_prepare_tree "$M14_BASE_TREE_NAME")
  m6_tree_or_die M14_BASE_TREE
  export M14_BASE_TREE
  printf '%s\n' "$M14_BASE_TREE"
}

m14_ext_tree() {
  m14_require_patch
  M14_TREE=$(m6_prepare_tree "$M14_TREE_NAME" "$M14_PATCH")
  m6_tree_or_die M14_TREE
  export M14_TREE
  printf '%s\n' "$M14_TREE"
}

# ---------------------------------------------------------------------------
# m14_build_native <tree> [target...]
#
# Upstream's own `default` preset and upstream's own targets. Configure and build statuses are kept
# SEPARATELY in M14_NATIVE_CONFIGURE_RC and M14_NATIVE_BUILD_RC and callers assert both, because a
# stale binary from a previous run prints a plausible transcript over a build that did not happen.
#
# FETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER for M7's reason, repeated by M8 and M9:
# cmake/gtest.cmake declares GTest with FIND_PACKAGE_ARGS, so a native configure otherwise prefers
# whatever find_package(GTest) turns up — on this host the system gtest under /usr/lib — and these
# checks run gtest binaries on both sides of a comparison.
# ---------------------------------------------------------------------------
m14_build_native() { # <tree> <target...>
  local tree="$1"; shift
  m6_native_configure "$tree" "$M14_NATIVE_BUILD" -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M14_NATIVE_CONFIGURE_RC=$?
  [ "$M14_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M14_NATIVE_CONFIGURE_RC"
  m6_build "$tree" "$M14_NATIVE_BUILD" "$@"
  M14_NATIVE_BUILD_RC=$?
  return "$M14_NATIVE_BUILD_RC"
}

m14_bin() { printf '%s\n' "$1/barretenberg/cpp/$M14_NATIVE_BUILD/bin/$2"; }

# ---------------------------------------------------------------------------
# m14_build_probe <tree>
#
# Compiles verification/m14/world_state_block_probe.cpp against <tree>, with the compile flags CMake
# used for that tree's OWN world_state_reference/memory_merkle_db.cpp — read out of the build's
# compile database, so the probe is built the way the library it links was built. Copying a flag
# list here would be a second, unmaintained description of a build.
#
# Linking is `--start-group` over every static library the build produced, because the probe pulls
# in world_state_reference, crypto_merkle_tree, crypto_poseidon2, ecc, numeric and common and the
# right order between them is not something worth writing down.
#
# Returns non-zero if the compile failed; the log is <tree>/m14-probe.log.
# ---------------------------------------------------------------------------
m14_build_probe() { # <tree>
  local tree="$1"
  local log="$tree/m14-probe.log"
  m6_in_devshell '
    tree="$1"; src="$2"; bdir="$3"
    cd "$tree/barretenberg/cpp" || exit 90
    flags="$(python3 - "$bdir/compile_commands.json" <<PY
import json, shlex, sys
db = json.load(open(sys.argv[1]))
want = [e for e in db if e["file"].endswith("world_state_reference/memory_merkle_db.cpp")]
if len(want) != 1:
    sys.stderr.write("expected exactly one compile-database entry for the reference, got %d\n" % len(want))
    sys.exit(3)
argv = shlex.split(want[0]["command"])
keep, skip = [], False
for a in argv[1:]:
    if skip:
        skip = False
        continue
    if a in ("-o", "-c", "-MT", "-MF"):
        skip = a in ("-o", "-MT", "-MF")
        continue
    if a == "-MD" or a.endswith("memory_merkle_db.cpp"):
        continue
    keep.append(a)
print(" ".join(shlex.quote(a) for a in keep))
PY
)" || exit 91
    libs=""
    for a in "$bdir"/lib/*.a; do libs="$libs $a"; done
    [ -n "$libs" ] || { echo "### no static libraries in $bdir/lib"; exit 92; }
    # shellcheck disable=SC2086
    clang++ $flags "$src" -o "$bdir/world_state_block_probe" \
      -Wl,--start-group $libs -Wl,--end-group -llmdb -lpthread 2>&1
    rc=$?
    echo "### probe_cc_rc=$rc"
    exit $rc
  ' "$tree" "$M14_PROBE_SRC" "$tree/barretenberg/cpp/$M14_NATIVE_BUILD" >"$log" 2>&1
}

m14_probe_bin() { printf '%s\n' "$1/barretenberg/cpp/$M14_NATIVE_BUILD/world_state_block_probe"; }

# ---------------------------------------------------------------------------
# m14_run_probe <tree> <out-file>
#
# stdout and stderr are kept SEPARATE, because the probe prints its key=value lines on stdout and
# anything on stderr is a diagnostic that must not become a parsed key.
# ---------------------------------------------------------------------------
m14_run_probe() { # <tree> <out-file>
  local tree="$1" out="$2"
  local bin; bin="$(m14_probe_bin "$tree")"
  [ -x "$bin" ] || return 90
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    "$1"
  ' "$bin" >"$out" 2>"$out.err"
}

# m14_key <file> <key> -> the value, or the empty string. Anchored on both sides: a key is matched
# as a WHOLE key, so `genesis.archive_tree.root` cannot be answered by `genesis.archive_tree.root2`
# and `archive_in_tree_roots` cannot be answered by a longer key ending in it.
m14_key() { # <file> <key>
  awk -v k="$2" -F= 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit }
                     END { if (!found) exit 0 }' "$1" 2>/dev/null
}

m14_key_count() { grep -c '=' "$1" 2>/dev/null || echo 0; }

# ---------------------------------------------------------------------------
# measured.env — written by verify_block_level_gap_audit_complete, which is the one check that
# BUILDS, and read by the five that do not. The other checks never invent a figure and never build
# a tree of their own: if the audit has not run, they say so and fail.
# ---------------------------------------------------------------------------
M14_MEASURED="$M14_WORK/measured.env"

m14_measured() {
  [ -f "$M14_MEASURED" ] \
    || die "no $M14_MEASURED — run 'just verify-block-level-audit' first; it is the check that builds"
  # shellcheck disable=SC1090
  . "$M14_MEASURED"
}
