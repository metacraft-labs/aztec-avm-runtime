#!/usr/bin/env bash
# Shared machinery for the M6 checks — the AVM_WASM build: `vm2_sim` and
# `world_state_reference` compiled for `wasm32-wasip1`.
#
# M6 is the campaign's first build milestone, and everything it measures comes
# out of EIGHT worktrees of the fork, all rooted at the same base commit
# 233d8e0993 and differing only by which prepared patches are applied, or by a
# single deliberate mutation on top of them:
#
#   base       233d8e0993, pristine. The `vm2/simulation/**` baseline.
#   stack3     + patches 1,2,3 (merkle/LMDB split, wasi-sdk 33, widen-shift).
#              The "without AVM_WASM" side of the default-off comparison: it
#              isolates THIS milestone's cost, holding the three prerequisites
#              fixed. Their own neutrality is M3's, M4's and M5's to establish
#              and is not re-litigated here.
#   avm        + patch 4 as well. The tree under test.
#   hardcoded  patches 1,3,4 — patch 2 DELIBERATELY OMITTED. The `wasm` preset
#              there still says `"WASI_SDK_PREFIX": "/opt/wasi-sdk"`, so
#              `wasm-avm`, which inherits it, resolves its toolchain from a
#              hardcoded path. This is the negative control for
#              verify_avm_wasm_preset_uses_ambient_wasi_prefix: both arms fail
#              to configure under a decoy prefix, and only the path NAMED in
#              the failure separates them.
#   spike      233d8e0993 + vm2wasm/spike.patch. The vm2-wasm spike's own change
#              set, carrying the three things M6 must not reinstate: a
#              header-only `crypto_merkle_tree`, a stray `lmdb.h` on the include
#              path, and `-Wno-error`. It is the negative control for
#              verify_wasm_build_uses_module_split_not_hack: every predicate
#              that must be FALSE in the M6 build is asserted TRUE there, so
#              "the hack is absent" is a discrimination rather than a hope.
#   nocast     the AVM_WASM tree with the patch's three narrowing corrections
#              reverted and nothing else. It must FAIL to build, on exactly the
#              four translation units the milestone names.
#   nogate     the AVM_WASM tree with only the exceptions gate's FATAL_ERROR
#              block removed. Under wasi-sdk 27 it must then configure, which is
#              what pins the gate as the cause of the failure beside it.
#   simmut     one throw site edited, to prove the "no throw/catch line moved"
#              measurement can see one when there is one.
#
# Three of those are meant to fail or to differ; a check goes red if one of them
# succeeds or matches.
#
# The trees are produced FROM THE PATCH FILES, not from the fork's local
# branches, because the patch files are what would be filed upstream and what a
# reviewer would apply. The local `p5-avm-wasm` branch is not consulted.
#
# Nothing here has a skip path. If a tree cannot be prepared, a toolchain cannot
# be realised or a build fails, the caller's assertion fails or `die` fires.
#
# Not to be executed directly: sourced by verification/*avm_wasm*.sh and
# verification/*wasm_exceptions*.sh, AFTER lib.sh (it uses FORK_ROOT, REPO_ROOT,
# WORKSPACE_ROOT, VERIFY_DIR, die, note).

M6_BASE_REV=233d8e0993

M6_UPSTREAM_BUGS="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs"

# The four prepared patches, in the order SERIES.md gives them. Patch 4 (the
# AVM_WASM build) is last and is the one under test; 1-3 are its stated
# dependencies and are applied verbatim from their own directories.
M6_PATCH_1="$M6_UPSTREAM_BUGS/aztec-merkle-tree-lmdb-split/0001-refactor-crypto-split-crypto_merkle_tree-from-its-LMD.patch"
M6_PATCH_2="$M6_UPSTREAM_BUGS/aztec-wasi-sdk-33/0001-build-move-the-wasm-toolchain-from-wasi-sdk-27-to-33.patch"
M6_PATCH_3="$M6_UPSTREAM_BUGS/aztec-bytecode-size-shift-32bit/0001-fix-vm2-widen-before-shifting-in-compute_public_bytec.patch"
M6_PATCH_4="$M6_UPSTREAM_BUGS/aztec-avm-wasm-cmake/0001-build-wasm-optional-AVM_WASM-and-separate-the-AVM-mod.patch"
M6_PATCH_DIR="$M6_UPSTREAM_BUGS/aztec-avm-wasm-cmake"

# The spike's own change set, committed in this repo.
M6_SPIKE_PATCH="$REPO_ROOT/vm2wasm/spike.patch"

# Where the eight worktrees and their build directories live. Deliberately
# outside both repos so no build artefact can land in a git status. The two
# `barretenberg.wasm` builds the default-off check needs are about 2 GB and a
# full set is closer to 5 GB, so a tmpfs /tmp is the wrong place and this
# defaults under $HOME; require_work_dir asserts the room is really there, and
# really writable, before the first build rather than after it (M9's review).
M6_WORK="${M6_WORK:-$HOME/.cache/aztec-m6-avm-wasm}"
require_work_dir "$M6_WORK" 8

# The nine archives the AVM_WASM build produces, as a sorted, space-separated
# list. Pinned as an IDENTITY, not a minimum: a tenth archive appearing is as
# much a finding as one of these disappearing.
M6_EXPECTED_ARCHIVES="libcommon.a libcrypto_keccak.a libcrypto_poseidon2.a libcrypto_sha256.a libecc.a libenv.a libnumeric.a libvm2_sim.a libworld_state_reference.a"

# The proving-stack module names the closure must NOT contain. Each is asserted
# to EXIST as a real static-library target IN THE SAME BUILD TREE before its
# absence from vm2_sim's closure is claimed — asserting the absence of a name
# that was never a target is the vacuous version of this check. They do all
# exist there: the `wasm-avm` preset inherits `wasm`, which configures the whole
# proving stack for `barretenberg.wasm`. vm2_sim simply does not reach it.
M6_FORBIDDEN_MODULES="honk polynomials srs flavor stdlib_circuit_builders sumcheck commitment_schemes stdlib_honk_verifier goblin_avm ultra_honk"

# The transitive closure of `vm2_sim` in CMake's own target graph, as an
# identity. `libdeflate_static` and `nlohmann_json` are FetchContent'd and
# produce no lib*.a of barretenberg's own; the nine that do are
# M6_EXPECTED_ARCHIVES.
M6_EXPECTED_CLOSURE="aztec common common_objects crypto_keccak crypto_keccak_objects crypto_merkle_tree crypto_poseidon2 crypto_poseidon2_objects crypto_sha256 crypto_sha256_objects ecc ecc_objects env env_objects libdeflate_static nlohmann_json numeric numeric_objects vm2_sim vm2_sim_objects world_state_reference world_state_reference_objects"

# The four translation units the wasm build diagnoses when the patch's three
# narrowing corrections are removed, and the flag each is diagnosed under.
# Measured (see verify_avm_wasm_build), not quoted.
M6_NARROWING_TUS="world_state_reference/memory_merkle_db.cpp vm2/simulation/gadgets/retrieved_bytecodes_tree_check.cpp vm2/simulation/gadgets/to_radix.cpp vm2/simulation/gadgets/written_public_data_slots_tree_check.cpp"

# The three source files the patch changes to fix them. Two of the four TUs are
# fixed at the DECLARATION site in indexed_memory_tree.hpp rather than with a
# cast in the .cpp, which is why these two lists are different lengths.
M6_NARROWING_FIXES="barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/to_radix.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/lib/indexed_memory_tree.hpp barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"

# The complete set of files under vm2/simulation/** that differ between
# 233d8e0993 and the AVM_WASM tree. contract_crypto.cpp is M5's one-line
# widening; the other two are M6's narrowing corrections. M9's observation hook
# is NOT in this stack (patch 4 of the series is not applied here), so the
# milestone's "only by the M5 shift widening and the M9 observation hook" is
# narrower still in this configuration.
M6_EXPECTED_SIM_DIFF="barretenberg/cpp/src/barretenberg/vm2/simulation/gadgets/to_radix.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/lib/contract_crypto.cpp barretenberg/cpp/src/barretenberg/vm2/simulation/lib/indexed_memory_tree.hpp"

# A path that cannot hold a toolchain, used to prove the preset reads the
# ambient variable. It must be absent, and it is asserted absent before use.
M6_DECOY_PREFIX="${M6_DECOY_PREFIX:-/nonexistent/decoy-wasi-sdk}"

export M6_BASE_REV M6_WORK M6_PATCH_DIR M6_DECOY_PREFIX

# ---------------------------------------------------------------------------
# m6_in_devshell <script-text> [args...]
#
# Runs a script inside the FORK's own `nix develop` — the reproducible
# definition of cmake / ninja / clang-format-20 / wasi-sdk 33 / node. Returns
# the script's exit status.
#
# The fork's shellHook prints a banner on the dev shell's stdout, which would
# otherwise land in the middle of anything the caller parses. A sentinel is
# emitted as the first thing inside the shell and everything up to and including
# it is dropped, so what the caller sees is exactly the script's output. (M4's
# machinery, reused verbatim in shape.)
# ---------------------------------------------------------------------------
M6_SENTINEL=$'\001M6OUT'

m6_in_devshell() {
  local script="$1"; shift
  local st; st="$(mktemp)"
  ( cd "$FORK_ROOT" || exit 90
    nix develop --command bash -uo pipefail \
      -c "printf '%s\n' '$M6_SENTINEL'; $script" bash "$@"
    echo $? >"$st" ) \
  | awk -v s="$M6_SENTINEL" 'seen { print } $0 == s { seen = 1 }'
  local rc; rc="$(cat "$st")"; rm -f "$st"
  return "${rc:-1}"
}

# ---------------------------------------------------------------------------
# m6_sdk <27|33>  ->  absolute store path of that wasi-sdk, on stdout
#
# Realised from the fork's flake, so the toolchain is the recorded release
# tarball and not whatever happens to be installed. The derivation's own VERSION
# file is asserted rather than the attribute name trusted — M4's lesson: a
# wasi-sdk masquerading as another version is exactly the mutation that a check
# reading only the attribute name would miss.
# ---------------------------------------------------------------------------
m6_sdk() {
  local want="$1" attr path
  case "$want" in
    27) attr=wasi-sdk-27 ;;
    33) attr=wasi-sdk ;;
    *) die "m6_sdk: unknown wasi-sdk major '$want'" ;;
  esac
  path=$( cd "$FORK_ROOT" && nix build --no-link --print-out-paths ".#$attr" 2>/dev/null )
  [ -n "$path" ] && [ -x "$path/bin/clang++" ] \
    || die "could not realise wasi-sdk $want from $FORK_ROOT#$attr"
  case "$(head -1 "$path/VERSION")" in
    "$want".*) ;;
    *) die "wasi-sdk $want realised as $(head -1 "$path/VERSION") ($path)" ;;
  esac
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# m6_prepare_tree <name> <patch...>
#
# Idempotently materialises $M6_WORK/<name> as a detached worktree of
# $M6_BASE_REV with the named patch files applied by `git am`, in order.
# `-3` is deliberately NOT passed: each patch must apply to what precedes it
# exactly. Dies on any failure — a tree that cannot be prepared is a check that
# cannot run, and a check that cannot run must fail.
# ---------------------------------------------------------------------------
m6_prepare_tree() {
  local name="$1"; shift
  local dir="$M6_WORK/$name" p

  command -v git >/dev/null 2>&1 || die "git is required"
  command -v nix >/dev/null 2>&1 || die "nix is required (the builds run in the fork's dev shell)"
  [ -e "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT"
  git -C "$FORK_ROOT" rev-parse --verify --quiet "$M6_BASE_REV^{commit}" >/dev/null \
    || die "base commit $M6_BASE_REV is not in $FORK_ROOT"
  for p in "$@"; do
    [ -f "$p" ] || die "prepared patch missing: $p"
  done

  mkdir -p "$M6_WORK"

  if [ ! -e "$dir/.git" ]; then
    git -C "$FORK_ROOT" worktree prune >/dev/null 2>&1
    git -C "$FORK_ROOT" worktree add --detach "$dir" "$M6_BASE_REV" >/dev/null 2>&1 \
      || die "could not create the $name worktree at $dir"
    for p in "$@"; do
      if ! git -C "$dir" am "$p" >>"$M6_WORK/$name-am.log" 2>&1; then
        git -C "$dir" am --abort >/dev/null 2>&1 || true
        die "git am of $(basename "$p") failed on the $name tree — see $M6_WORK/$name-am.log"
      fi
    done
  fi

  # The tree is base + exactly the patches asked for, in order, and nothing else.
  local want="$#" got
  got=$(git -C "$dir" rev-list --count "$M6_BASE_REV..HEAD" 2>/dev/null)
  [ "$got" = "$want" ] \
    || die "$dir is $M6_BASE_REV + $got commit(s), expected $want — remove it and re-run"
  # `nodejs_module/` is excluded, and only that. Its CMakeLists runs
  # `yarn --immutable` at configure time and fails the WHOLE native configure
  # when node-addon-api cannot be resolved, so the native side has to run a
  # plain `yarn install` first — which rewrites `.yarnrc.yml` and `yarn.lock`.
  # M3 scoped its own "no leftovers" assertion the same way and for the same
  # reason. Nothing else under barretenberg/ may differ.
  local dirty
  dirty="$(git -C "$dir" diff --name-only HEAD -- barretenberg \
           | grep -v '^barretenberg/cpp/src/barretenberg/nodejs_module/')"
  [ -z "$dirty" ] \
    || die "$dir has uncommitted changes under barretenberg/: $(printf '%s' "$dirty" | tr '\n' ' ') — remove it and re-run"
  printf '%s\n' "$dir"
}

m6_prepare_trees() {
  M6_TREE_BASE=$(m6_prepare_tree base);                          m6_tree_or_die M6_TREE_BASE
  M6_TREE_STACK3=$(m6_prepare_tree stack3 "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3")
  m6_tree_or_die M6_TREE_STACK3
  M6_TREE_AVM=$(m6_prepare_tree avm "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4")
  m6_tree_or_die M6_TREE_AVM
  export M6_TREE_BASE M6_TREE_STACK3 M6_TREE_AVM
}

m6_prepare_hardcoded_tree() {
  # Patch 2 omitted on purpose: this is the preset control.
  M6_TREE_HARDCODED=$(m6_prepare_tree hardcoded "$M6_PATCH_1" "$M6_PATCH_3" "$M6_PATCH_4")
  m6_tree_or_die M6_TREE_HARDCODED
  export M6_TREE_HARDCODED
}

m6_prepare_spike_tree() {
  M6_TREE_SPIKE=$(m6_prepare_tree spike "$M6_SPIKE_PATCH")
  m6_tree_or_die M6_TREE_SPIKE
  export M6_TREE_SPIKE
}

# m6_reset_tree <name>
#   Discards any working-tree edit under barretenberg/ in a scratch tree. Called
#   explicitly, before and after the narrowing experiment, because m6_prepare_tree
#   refuses a dirty tree on purpose — an unexplained edit under a measurement tree
#   is a reason to stop, not something to clean up silently. The one place an edit
#   is legitimate is the experiment below, which owns this tree and says so.
# `checkout HEAD --`, not `checkout --`: the experiment reverts files with
# `git checkout HEAD^ -- <path>`, which writes the old content into the INDEX as
# well as the worktree. Restoring from the index would restore the mutation.
m6_reset_tree() {
  local dir="$M6_WORK/$1"
  [ -e "$dir/.git" ] || return 0
  git -C "$dir" checkout HEAD -- barretenberg 2>/dev/null || true
}

# m6_tree_or_die <variable-name> — a command substitution swallows `die`, so a
# tree that could not be prepared comes back as an empty string and every later
# `git -C ""` silently runs in the CALLER's repository. This is the guard that
# turns that into a stop.
m6_tree_or_die() {
  local n="$1"
  [ -n "${!n:-}" ] && [ -d "${!n}/.git" -o -f "${!n}/.git" ] \
    || die "$n was not prepared (see $M6_WORK/*-am.log)"
}

# m6_prepare_narrowing_control
#   $M6_WORK/nocast — the AVM_WASM tree with the patch's three narrowing
#   corrections reverted to their pre-patch content and NOTHING else changed.
#   Building it is what turns "the four narrowings are fixed" from a claim about
#   a diff into a measurement: the four translation units the milestone names
#   must fail, each under its own flag, and the build must fail with them.
m6_prepare_narrowing_control() {
  m6_reset_tree nocast
  M6_TREE_NOCAST=$(m6_prepare_tree nocast "$M6_PATCH_1" "$M6_PATCH_2" "$M6_PATCH_3" "$M6_PATCH_4")
  m6_tree_or_die M6_TREE_NOCAST
  export M6_TREE_NOCAST
}

# ---------------------------------------------------------------------------
# m6_configure <tree> <preset> <build-dir-name> [extra cmake args...]
#
# Configures with the named preset, into <tree>/barretenberg/cpp/<build-dir>.
# The build directory is REMOVED first: CMake caches check_cxx_source_compiles
# results and the compiler identity, so a reused directory would answer
# questions about the previous configuration.
#
# Returns cmake's exit status. The complete output — which is what the gate and
# the ambient-prefix checks read — is left at <tree>/m6-<build-dir>.log.
# ---------------------------------------------------------------------------
m6_configure() {
  local tree="$1" preset="$2" bdir="$3"; shift 3
  local log="$tree/m6-$bdir.log"
  m6_in_devshell '
    tree="$1"; preset="$2"; bdir="$3"; shift 3
    cd "$tree/barretenberg/cpp" || exit 90
    rm -rf "$bdir"
    echo "### WASI_SDK_PREFIX=${WASI_SDK_PREFIX:-<unset>}"
    cmake --preset "$preset" -B "$bdir" -DAVM_TRANSPILER_LIB= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "$@"
    rc=$?
    echo "### configure_rc=$rc"
    exit $rc
  ' "$tree" "$preset" "$bdir" "$@" >"$log" 2>&1
}

# m6_configure_incremental <tree> <preset> <build-dir> [extra cmake args...]
#
# The same, WITHOUT removing the build directory first. Used only where the
# directory holds an expensive artefact that nothing in the comparison changes —
# the two `barretenberg.wasm` builds of the default-off check, which are about
# nine minutes each and which ninja has nothing to do to on a re-run. Everywhere
# else the removal is load-bearing (CMake caches the exceptions probe's result
# and the compiler identity), so this is the exception and is named as one.
m6_configure_incremental() {
  local tree="$1" preset="$2" bdir="$3"; shift 3
  local log="$tree/m6-$bdir.log"
  m6_in_devshell '
    tree="$1"; preset="$2"; bdir="$3"; shift 3
    cd "$tree/barretenberg/cpp" || exit 90
    echo "### WASI_SDK_PREFIX=${WASI_SDK_PREFIX:-<unset>}"
    cmake --preset "$preset" -B "$bdir" -DAVM_TRANSPILER_LIB= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "$@"
    rc=$?
    echo "### configure_rc=$rc"
    exit $rc
  ' "$tree" "$preset" "$bdir" "$@" >"$log" 2>&1
}

# m6_configure_with_prefix <prefix> <tree> <preset> <build-dir> ...
# Same, with WASI_SDK_PREFIX / WASI_SDK_PATH forced to <prefix> for the
# configure only. Used by the ambient-prefix check and by the exceptions gate.
m6_configure_with_prefix() {
  local prefix="$1" tree="$2" preset="$3" bdir="$4"; shift 4
  local log="$tree/m6-$bdir.log"
  m6_in_devshell '
    prefix="$1"; tree="$2"; preset="$3"; bdir="$4"; shift 4
    export WASI_SDK_PREFIX="$prefix" WASI_SDK_PATH="$prefix"
    cd "$tree/barretenberg/cpp" || exit 90
    rm -rf "$bdir"
    echo "### WASI_SDK_PREFIX=$WASI_SDK_PREFIX"
    cmake --preset "$preset" -B "$bdir" -DAVM_TRANSPILER_LIB= -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "$@"
    rc=$?
    echo "### configure_rc=$rc"
    exit $rc
  ' "$prefix" "$tree" "$preset" "$bdir" "$@" >"$log" 2>&1
}

# ---------------------------------------------------------------------------
# m6_native_configure <tree> <build-dir> [extra cmake args...]
#
# Configures a NATIVE build through barretenberg's own `default` preset, so the
# comparison exercises CMakePresets.json rather than a hand-written cmake line
# that would route around it. Configure only: what this is for is the resulting
# target list and compile database, which is where a CMake-level change would
# show up if AVM_WASM could reach a native build at all.
#
# Two environment facts are handled here rather than left to bite, both already
# met in M3 and M4: nodejs_module's CMakeLists runs `yarn --immutable` at
# configure time and fails the whole configure if node-addon-api cannot be
# resolved, and gtest discovery wants the host libstdc++ on LD_LIBRARY_PATH.
# ---------------------------------------------------------------------------
m6_native_configure() {
  local tree="$1" bdir="$2"; shift 2
  local log="$tree/m6-$bdir.log"
  m6_in_devshell '
    tree="$1"; bdir="$2"; shift 2
    cd "$tree/barretenberg/cpp" || exit 90
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    if [ ! -d src/barretenberg/nodejs_module/node_modules ]; then
      ( cd src/barretenberg/nodejs_module && yarn install ) || exit 92
    fi
    rm -rf "$bdir"
    cmake --preset default -B "$bdir" -DAVM_TRANSPILER_LIB= \
      -DCMAKE_C_COMPILER="$(command -v clang)" -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "$@"
    rc=$?
    echo "### configure_rc=$rc"
    exit $rc
  ' "$tree" "$bdir" "$@" >"$log" 2>&1
}

# ---------------------------------------------------------------------------
# m6_build <tree> <build-dir> <target...>
#
# `ninja -k 0`, so ONE run reports every failing translation unit rather than
# stopping at the first. That matters here: `src/CMakeLists.txt` compiles with
# `-Wfatal-errors`, so each failing unit emits exactly one `fatal error:` line
# and nothing after it, and the default `ninja` would hide the rest of the set.
#
# Returns ninja's exit status. Log at <tree>/m6-<build-dir>-build.log.
# ---------------------------------------------------------------------------
m6_build() {
  local tree="$1" bdir="$2"; shift 2
  local log="$tree/m6-$bdir-build.log"
  m6_in_devshell '
    tree="$1"; bdir="$2"; shift 2
    cd "$tree/barretenberg/cpp" || exit 90
    ninja -k 0 -C "$bdir" "$@"
    rc=$?
    echo "### ninja_rc=$rc"
    exit $rc
  ' "$tree" "$bdir" "$@" >"$log" 2>&1
}

# ---------------------------------------------------------------------------
# m6_log <tree> <build-dir>  -> the configure log
# m6_build_log <tree> <build-dir> -> the build log
# ---------------------------------------------------------------------------
m6_log()       { cat "$1/m6-$2.log" 2>/dev/null; }
m6_build_log() { cat "$1/m6-$2-build.log" 2>/dev/null; }

# ---------------------------------------------------------------------------
# m6_cache <tree> <build-dir> <var> -> the CMake cache value, or the empty string
# ---------------------------------------------------------------------------
m6_cache() {
  local f="$1/barretenberg/cpp/$2/CMakeCache.txt"
  [ -f "$f" ] || return 1
  sed -n "s|^$3:[^=]*=\(.*\)$|\1|p" "$f" | head -1
}

# ---------------------------------------------------------------------------
# m6_archives <tree> <build-dir> -> the sorted basenames of lib/*.a
# ---------------------------------------------------------------------------
m6_archives() {
  local d="$1/barretenberg/cpp/$2/lib"
  [ -d "$d" ] || return 1
  ( cd "$d" && ls -1 ./*.a 2>/dev/null | sed 's|^\./||' | sort | tr '\n' ' ' | sed 's/ $//' )
}

# ---------------------------------------------------------------------------
# m6_ninja_targets <tree> <build-dir> -> every target ninja declares, sorted
#
# `ninja -t targets all` lists outputs, one "path: rule" per line. The build
# directory prefix is stripped so two trees in different directories are
# comparable, and the `_deps/` subtree (gtest, benchmark, tracy, nlohmann,
# libdeflate — all FetchContent'd) is kept, because a module appearing or
# vanishing there is as much a change to the build graph as one of
# barretenberg's own.
# ---------------------------------------------------------------------------
m6_ninja_targets() {
  local tree="$1" bdir="$2"
  m6_in_devshell '
    tree="$1"; bdir="$2"
    cd "$tree/barretenberg/cpp/$bdir" || exit 90
    ninja -t targets all
  ' "$tree" "$bdir" 2>/dev/null \
  | sed -e 's/: .*$//' -e "s|$tree|<TREE>|g" -e "s|/$bdir/|/<BUILD>/|g" \
  | sort -u
}

# ---------------------------------------------------------------------------
# m6_graph <tree> <build-dir> -> CMake's OWN target graph, "<from> -> <to>" per line
#
# Regenerated from the configured build tree on every call, so it is the build
# system's answer to "what links what" rather than our reading of the CMakeLists
# text. M3's machinery; the same reasoning applies.
# ---------------------------------------------------------------------------
m6_graph() {
  local tree="$1" bdir="$2"
  local out="$tree/m6-graph-$bdir"
  [ -f "$tree/barretenberg/cpp/$bdir/CMakeCache.txt" ] || return 1
  rm -rf "$out"; mkdir -p "$out"
  m6_in_devshell '
    bdir="$1"; out="$2"
    cd "$bdir" && cmake --graphviz="$out/targets.dot" . >/dev/null
  ' "$tree/barretenberg/cpp/$bdir" "$out" >/dev/null 2>&1 || return 1
  [ -f "$out/targets.dot" ] || return 1
  grep -oE '// [A-Za-z0-9_:.-]+ -> [A-Za-z0-9_:.-]+$' "$out/targets.dot" \
    | sed 's|^// ||' | sort -u >"$out/edges"
  cat "$out/edges"
}

# m6_graph_edges_file <tree> <build-dir> -> the path m6_graph wrote its edges to.
# Regenerates if it is not there. Callers want a FILE because the closure walk
# is an awk program over one, and redirecting m6_graph's stdout into a path
# inside its own output directory would have the shell create the file before
# m6_graph removes the directory.
m6_graph_edges_file() {
  local f="$1/m6-graph-$2/edges"
  [ -s "$f" ] || m6_graph "$1" "$2" >/dev/null
  printf '%s\n' "$f"
}

# ---------------------------------------------------------------------------
# m6_graph_nodes <tree> <build-dir> -> every node in the regenerated graph
# m6_graph_shape <tree> <build-dir> <target> -> CMake's shape for that node
#
# The shape is not decoration. cmake's graphviz writer uses a fixed vocabulary,
# and two of its values are exactly the distinction this milestone turns on:
# `septagon` is UNKNOWN_LIBRARY — a name something links against that is not a
# target in this configuration — and `pentagon` is INTERFACE_LIBRARY, which is
# what `crypto_merkle_tree` becomes after M3's split. `crypto_merkle_tree` is a
# septagon in a plain wasm build and a pentagon in an AVM_WASM one, and that
# single character is the difference between "the module is referenced" and
# "the module is built".
# ---------------------------------------------------------------------------
m6_graph_dot() { printf '%s\n' "$1/m6-graph-$2/targets.dot"; }

# Both DIE rather than return empty when the graph has not been generated. The
# cold run caught why: a `grep -c` over an absent file is 0, and an assertion
# that a forbidden name appears 0 times then passes without having looked at
# anything. Every reader of the graph regenerates it if it is missing.
m6_graph_nodes() {
  local dot; dot="$(m6_graph_dot "$1" "$2")"
  [ -f "$dot" ] || { m6_graph "$1" "$2" >/dev/null; }
  [ -f "$dot" ] || die "could not generate the target graph for $1/$2"
  grep -oE '\[ label = "[^"]+", shape' "$dot" | sed -E 's/^\[ label = "([^"]+)", shape$/\1/' | sort -u
}

m6_graph_shape() {
  local dot; dot="$(m6_graph_dot "$1" "$2")"
  [ -f "$dot" ] || { m6_graph "$1" "$2" >/dev/null; }
  [ -f "$dot" ] || die "could not generate the target graph for $1/$2"
  grep -oE "\[ label = \"$3\", shape = [a-z]+" "$dot" \
    | sed -E 's/.*shape = //' | head -1
}

# ---------------------------------------------------------------------------
# m6_graph_closure <graph-file> <root> -> the transitive closure from <root>
#
# The set of targets reachable from <root> through the graph's edges, sorted and
# including <root>. This is the link closure as CMake computes it, and it is
# what "the closure contains X and not Y" is asserted against.
# ---------------------------------------------------------------------------
m6_graph_closure() {
  local graph="$1" root="$2"
  awk -v root="$root" '
    { edge[$1] = edge[$1] " " $3 }
    END {
      n = 1; q[1] = root; seen[root] = 1
      for (i = 1; i <= n; i++) {
        split(edge[q[i]], to, " ")
        for (j in to) if (to[j] != "" && !(to[j] in seen)) { seen[to[j]] = 1; q[++n] = to[j] }
      }
      for (t in seen) print t
    }' "$graph" | sort
}

# ---------------------------------------------------------------------------
# m6_compile_flags <tree> <build-dir> -> every distinct flag on every command
#                                        line in the build's compile database
#
# Read from compile_commands.json, which is the build's own record of what it
# ran. Used to assert that -Werror survives (the spike demoted it with
# -Wno-error) and that no -I resolves to a directory holding lmdb.h.
# ---------------------------------------------------------------------------
m6_compile_db() { printf '%s\n' "$1/barretenberg/cpp/$2/compile_commands.json"; }

m6_include_dirs() { # <tree> <build-dir> -> every -I directory, absolute, sorted
  local db; db="$(m6_compile_db "$1" "$2")"
  [ -f "$db" ] || return 1
  python3 - "$db" <<'PY'
import json, os, sys, shlex
db = json.load(open(sys.argv[1]))
dirs = set()
for e in db:
    args = e.get("arguments") or shlex.split(e.get("command", ""))
    for i, a in enumerate(args):
        if a == "-I" and i + 1 < len(args):
            dirs.add(os.path.normpath(os.path.join(e["directory"], args[i + 1])))
        elif a.startswith("-I") and len(a) > 2:
            dirs.add(os.path.normpath(os.path.join(e["directory"], a[2:])))
for d in sorted(dirs):
    print(d)
PY
}

# m6_normalised_db <tree> <build-dir>
#   Every compile command in the build, with the tree's own path replaced by
#   <TREE> and the entries sorted by file. Two builds of the same sources in two
#   directories differ legitimately only by that path; anything else differing is
#   a finding. M4's "1,009 translation units with byte-identical compile
#   commands" measurement, in the same shape.
m6_normalised_db() {
  local tree="$1" bdir="$2" db; db="$(m6_compile_db "$1" "$2")"
  [ -f "$db" ] || return 1
  python3 - "$db" "$tree" "$bdir" <<'DBPY'
import json, sys, shlex
db = json.load(open(sys.argv[1]))
root = sys.argv[2].rstrip("/"); bdir = sys.argv[3]
def norm(x):
    return x.replace(root, "<TREE>").replace("/" + bdir + "/", "/<BUILD>/")
rows = []
for e in db:
    args = e.get("arguments") or shlex.split(e.get("command", ""))
    rows.append(norm(e["file"]) + "\t" + norm(" ".join(args)))
for r in sorted(rows):
    print(r)
DBPY
}

m6_tu_count() { # <tree> <build-dir> -> number of entries in the compile database
  local db; db="$(m6_compile_db "$1" "$2")"
  [ -f "$db" ] || return 1
  python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1]))))' "$db"
}

# m6_flag_tu_count <tree> <build-dir> <flag> [own|dep|all]
#
# How many translation units carry <flag>. The scope matters and defaults to
# `own`: barretenberg's own sources, under barretenberg/cpp/src/. The rest of
# the compile database is FetchContent'd third party (gtest, benchmark,
# libdeflate, tracy), which barretenberg deliberately does not compile with its
# own warning policy — M4 measured 503/503 of its own carrying -Werror against
# 0/4 of gtest's. Counting the two together would make every such assertion an
# inequality about a mixture.
m6_flag_tu_count() {
  local db; db="$(m6_compile_db "$1" "$2")"
  [ -f "$db" ] || return 1
  python3 - "$db" "$3" "${4:-own}" <<'PY'
import json, sys, shlex
db = json.load(open(sys.argv[1])); flag, scope = sys.argv[2], sys.argv[3]
def keep(e):
    own = "/barretenberg/cpp/src/" in e["file"]
    return own if scope == "own" else (not own) if scope == "dep" else True
n = 0
for e in db:
    if not keep(e):
        continue
    args = e.get("arguments") or shlex.split(e.get("command", ""))
    if flag in args:
        n += 1
print(n)
PY
}

m6_own_tu_count() { # <tree> <build-dir> -> barretenberg's own TUs in the database
  local db; db="$(m6_compile_db "$1" "$2")"
  [ -f "$db" ] || return 1
  python3 -c '
import json,sys
db=json.load(open(sys.argv[1]))
print(sum(1 for e in db if "/barretenberg/cpp/src/" in e["file"]))' "$db"
}

m6_module_tu_count() { # <tree> <build-dir> <path-fragment> -> TUs under it
  local db; db="$(m6_compile_db "$1" "$2")"
  [ -f "$db" ] || return 1
  python3 -c '
import json,sys
db=json.load(open(sys.argv[1]))
print(sum(1 for e in db if sys.argv[2] in e["file"]))' "$db" "$3"
}

# ---------------------------------------------------------------------------
# m6_undefined_mdb <tree> <build-dir> <archive> -> count of undefined mdb_* symbols
#
# `llvm-nm -u` over a wasm archive. Zero on both sides was already true before
# M3's patch (M3 measured it), so this is not evidence that the split removed
# dead calls — it is evidence that nothing in the wasm artefact reaches for LMDB.
# ---------------------------------------------------------------------------
#
# DIES when the archive is not there. `llvm-nm` over a missing file prints
# nothing, `grep -c` then reports 0, and an assertion expecting 0 passes without
# having looked at anything — the same scope-of-validity defect the cold run
# found in the ungenerated `targets.dot`. Callers of this read a build directory
# they did not produce, so the check belongs here.
m6_undefined_mdb() {
  local tree="$1" bdir="$2" archive="$3"
  [ -f "$tree/barretenberg/cpp/$bdir/lib/$archive" ] \
    || die "no $archive under $bdir — there is nothing to count mdb_ references in"
  m6_in_devshell '
    sdk="$WASI_SDK_PREFIX"
    "$sdk/bin/llvm-nm" -u "$1" 2>/dev/null | grep -c "mdb_" || true
  ' "$tree/barretenberg/cpp/$bdir/lib/$archive" 2>/dev/null | tail -1
}

# ---------------------------------------------------------------------------
# m6_archive_formats <tree> <build-dir> <archive> -> the distinct object formats
#
# Every member is extracted and identified by its own magic bytes: a WebAssembly
# object begins `\0asm`, an ELF one `\177ELF`, a Mach-O one with one of the four
# Mach magics. Reading the magic rather than asking a tool is deliberate — the
# question is what the bytes ARE, and `llvm-objdump --file-headers` over an
# archive stops on the first member it cannot dump, which would silently answer
# a question about one object as if it were about all of them.
#
# Prints the sorted distinct set, e.g. `WASM`, or `ELF WASM` for a mixture.
# ---------------------------------------------------------------------------
m6_archive_formats() {
  local tree="$1" bdir="$2" archive="$3"
  local ar="$tree/barretenberg/cpp/$bdir/lib/$archive"
  [ -f "$ar" ] || return 1
  local tmp; tmp="$(mktemp -d)"
  m6_in_devshell 'cd "$1" && "$WASI_SDK_PREFIX/bin/llvm-ar" x "$2"' "$tmp" "$ar" >/dev/null 2>&1
  python3 - "$tmp" <<'PY'
import os, sys
seen = set()
for f in sorted(os.listdir(sys.argv[1])):
    p = os.path.join(sys.argv[1], f)
    if not os.path.isfile(p):
        continue
    with open(p, "rb") as fh:
        magic = fh.read(4)
    if magic == b"\x00asm":
        seen.add("WASM")
    elif magic == b"\x7fELF":
        seen.add("ELF")
    elif magic in (b"\xcf\xfa\xed\xfe", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xfe\xed\xfa\xce"):
        seen.add("MACHO")
    else:
        seen.add("UNKNOWN:" + magic.hex())
print(" ".join(sorted(seen)))
PY
  rm -rf "$tmp"
}

# m6_system_processor <tree> <build-dir>
#   CMake's own record of what it is cross-compiling for. Not a cache entry: the
#   toolchain file sets it, and CMake writes it to CMakeFiles/*/CMakeSystem.cmake.
m6_system_processor() {
  local f
  f=$(find "$1/barretenberg/cpp/$2/CMakeFiles" -name CMakeSystem.cmake 2>/dev/null | head -1)
  [ -n "$f" ] || return 1
  sed -n 's/^set(CMAKE_SYSTEM_PROCESSOR "\(.*\)")$/\1/p' "$f" | head -1
}

# ---------------------------------------------------------------------------
# m6_sim_diff <tree> -> the paths under vm2/simulation/** that differ from base
# ---------------------------------------------------------------------------
# The optional second argument is the diff range, defaulting to the committed
# one. Passing the bare base commit compares it against the WORKING TREE, which
# is how the mutation control makes an edit visible without committing it.
m6_sim_diff() {
  git -C "$1" diff --name-only "${2:-$M6_BASE_REV..HEAD}" \
    -- barretenberg/cpp/src/barretenberg/vm2/simulation/ | sort
}

# m6_sim_diff_throw_catch_lines <tree>
#   Every ADDED or REMOVED line under vm2/simulation/** that mentions `throw` or
#   `catch` as a word. The milestone's claim is that the throw/catch sites are
#   untouched; this is that claim reduced to something with a number, and it does
#   not depend on any census definition.
m6_sim_diff_throw_catch_lines() {
  git -C "$1" diff -U0 "${2:-$M6_BASE_REV..HEAD}" \
    -- barretenberg/cpp/src/barretenberg/vm2/simulation/ \
    | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' \
    | grep -cE '\b(throw|catch)\b' || true
}

# m6_sim_census <tree> -> "<files> <throw> <catch>" over vm2/simulation/**
#   Non-test, non-bench .cpp/.hpp only. The definition is stated here rather
#   than left implicit, because "327 throw/catch sites" is a number whose value
#   depends entirely on which files are counted.
m6_sim_census() {
  local tree="$1/barretenberg/cpp/src/barretenberg/vm2/simulation"
  local files thr cat
  files=$(find "$tree" \( -name '*.cpp' -o -name '*.hpp' \) \
          | grep -v '\.test\.\|\.bench\.' | wc -l)
  thr=$(find "$tree" \( -name '*.cpp' -o -name '*.hpp' \) \
        | grep -v '\.test\.\|\.bench\.' | xargs grep -ohE '\bthrow\b' 2>/dev/null | wc -l)
  cat=$(find "$tree" \( -name '*.cpp' -o -name '*.hpp' \) \
        | grep -v '\.test\.\|\.bench\.' | xargs grep -ohE '\bcatch\b' 2>/dev/null | wc -l)
  printf '%s %s %s\n' "$files" "$thr" "$cat"
}

# ---------------------------------------------------------------------------
# m6_patch_added / m6_patch_removed <patch-file> [path-filter]
#
# The patch's own added / removed lines. Every claim about what the patch SETS
# is re-derived from these rather than from the tree, because a tree can satisfy
# a check while the artefact that would be filed upstream says something else —
# M4's review lesson, and the reason `verify_avm_wasm_default_off` reads the
# `option()` line out of the patch.
# ---------------------------------------------------------------------------
m6_patch_added() {
  if [ -n "${2:-}" ]; then
    awk -v f="$2" '/^diff --git /{inf=($0 ~ f)} inf && /^\+/ && !/^\+\+\+/' "$1"
  else
    grep -E '^\+' "$1" | grep -vE '^\+\+\+'
  fi
}
m6_patch_removed() {
  if [ -n "${2:-}" ]; then
    awk -v f="$2" '/^diff --git /{inf=($0 ~ f)} inf && /^-/ && !/^---/' "$1"
  else
    grep -E '^-' "$1" | grep -vE '^---'
  fi
}

m6_patch_files() { # <patch-file> -> the paths it touches, sorted
  grep -oE '^diff --git a/[^ ]+' "$1" | sed 's|^diff --git a/||' | sort -u
}

# ---------------------------------------------------------------------------
# m6_measured
#
# Reads $M6_WORK/measured.env — the single record of what was built, written by
# verify_avm_wasm_build. Every other M6 check that quotes a build number reads
# it from here, so no two checks can disagree about what was measured.
#
# If the record is not there, the build check is RUN to produce one. It is never
# invented, defaulted or skipped.
# ---------------------------------------------------------------------------
m6_measured() {
  if [ ! -f "$M6_WORK/measured.env" ]; then
    note "no measurement on record — running verify_avm_wasm_build to produce one"
    mkdir -p "$M6_WORK"
    "$VERIFY_DIR/verify_avm_wasm_build.sh" >"$M6_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M6_WORK/build-for-record.log"
  fi
  [ -f "$M6_WORK/measured.env" ] || die "measurement record missing at $M6_WORK/measured.env"
  # shellcheck disable=SC1090
  . "$M6_WORK/measured.env"
}
