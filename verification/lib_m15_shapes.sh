#!/usr/bin/env bash
# Shared machinery for the M15 checks — the integration shape across the wasm boundary, and the
# cost of the reference world state's own checkpoints.
#
# WHAT M15 MEASURES, AND WHAT IT DOES NOT.
#
# M15 is a DESIGN DECISION MADE ON MEASUREMENT. It decides how much of the transaction and block
# loop lives inside wasm, and it constrains M23 (the facade) and M25 (step-level tracing). So both
# candidate shapes are built and run, and the REJECTED one's numbers are kept, because a decision
# whose losing side was never measured cannot be revisited without redoing the work.
#
# ONE WORK DIRECTORY, AND IT IS NOT ANOTHER MILESTONE'S.
#
#   $M15_WORK   default ~/.cache/aztec-m15-shapes. Everything M15 measures is built here: the
#               ten-patch reactor tree both shapes run in (see below), and the
#               two world-state trees the checkpoint characterisation needs — the pinned anchor,
#               four trees, and the anchor plus M14's archive patch, five. Those last two are
#               prepared by M14's own functions with $M14_WORK POINTED AT $M15_WORK, so they are
#               M15's copies built by M14's recipe rather than M14's evidence read from where M14
#               left it. A check must not depend on state it did not produce, and M15's own
#               carried fix is about exactly that.
#
# THE CHECKPOINT MEASUREMENT IS A COMPLEXITY CLAIM, NOT A NUMBER.
#
# `MemoryMerkleDB`'s own header says checkpoints "deep-copy the whole tree state onto a stack and
# restore on revert", and §6.4's design constraint asked for O(changes). Nobody upstream has ever
# timed it: at the pinned anchor there is no benchmark anywhere in the fork that names
# `world_state_reference`, `MemoryMerkleDB` or `memory_merkle_db`, and the only file that exercises
# checkpoints at all — `world_state/memory_merkle_db.test.cpp` — asserts equivalence and times
# nothing. So the number does not exist and this milestone produces it.
#
# It is produced as a RATIO between populations an order of magnitude apart, because the absolute
# microseconds are a property of this host and the growth is a property of the implementation. A
# check that pinned microseconds would fail on a slower machine while a check that pins the growth
# fails only if the implementation changes. The two hypotheses are separated by the ratio and both
# are stated: O(state) predicts the cost grows with the population, O(changes) predicts it does
# not.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, a benchmark
# that produces no keys or a host that exits non-zero is `die` or a failed assertion, never a
# printed SKIP.
#
# Not to be executed directly: sourced by verification/test_*.sh and verify_*.sh, AFTER lib.sh.

# THE TREE IS M13's TEN-PATCH STACK, AND M15 ADDS NO ELEVENTH.
#
# That is the milestone's own finding rather than a shortcut, and it is worth stating plainly
# because the shape of every previous milestone was "prepare an overlay, build it, measure it".
# M15 needs both candidate shapes, and the module M12 built and M13 completed ALREADY CONTAINS
# BOTH:
#
#   resident  `avm_simulate(inputs, contractDbHandle, merkleDbHandle)` — the DBs are in the module.
#   chatty    `avm_simulate_with_hinted_dbs(inputs)` — the module holds NO world state and every
#             answer comes from outside; and the twenty-two exported interface methods, which are
#             the same two interfaces driven one operation at a time from the host.
#
# M12 built both entry points and recorded, in REACTOR-ABI.md, that "the choice between them is
# M15's". So M15's work is measurement and a decision, not construction — which is the answer the
# governing principle asks for whenever it can be had.
#
# A FULLY FUSED CHATTY ARM — the two interfaces implemented over an imported callback, so the AVM
# calls out mid-execution rather than being pre-supplied — IS PREPARED AND IS NOT MEASURED HERE.
# `verification/m15/avm_chatty_dbs.{hpp,cpp}` and `avm_reactor_chatty_exports.inc` carry it,
# written against `WsdbIpcMerkleDB`'s shape (upstream's own chatty implementation of the same
# interface, in `barretenberg/vm2_wsdb/`). It is not needed for the decision, because what the
# decision turns on — how many crossings a transaction makes, and what a crossing costs — is
# measured without it and is measured from upstream's own record. Recorded in BOUNDARY-SHAPE.md as
# prepared-not-measured rather than left as an unstated gap.
#
# M15 still gets its OWN work directory, and that part is not optional: a milestone that reads
# another milestone's build directory is depending on state it did not produce, which is the
# defect M15's own carried fix is about.
M15_WORK="${M15_WORK:-$HOME/.cache/aztec-m15-shapes}"
M13_WORK="$M15_WORK"
export M15_WORK M13_WORK

# shellcheck source=lib_m13_contract_db.sh
. "$VERIFY_DIR/lib_m13_contract_db.sh"

M15_TREE_NAME=m13
M15_WASM_BUILD=build-wasm-avm
M15_NATIVE_BUILD=build-native-avm

M15_HOST="$VERIFY_DIR/wasm_host/avm_shape_host.mjs"
M15_CROSSINGS_LIB="$VERIFY_DIR/wasm_host/_hint_crossings.mjs"
M15_BENCH_SRC="$REPO_ROOT/verification/m15/world_state_checkpoint_bench.cpp"

# The prepared, unmeasured chatty overlay. Its presence is asserted by the checks so it cannot be
# quietly deleted, and its ABSENCE from the build is asserted too, so "prepared" cannot drift into
# "silently shipped".
M15_CHATTY_HPP="$REPO_ROOT/verification/m15/avm_chatty_dbs.hpp"
M15_CHATTY_CPP="$REPO_ROOT/verification/m15/avm_chatty_dbs.cpp"
M15_CHATTY_INC="$REPO_ROOT/verification/m15/avm_reactor_chatty_exports.inc"

# The write-up whose numbers the checks re-derive rather than trust.
M15_WRITEUP="$REPO_ROOT/BOUNDARY-SHAPE.md"

# The corpus. M12's seven hand-assembled programs; the count is asserted so a corpus that shrank is
# visible rather than silently averaged over.
M15_PROGRAMS="add revert loop sha256 poseidon2 storage burn"
M15_EXPECTED_PROGRAMS=7

# The representative transaction the wall-time budget is stated against. `storage` is the one of
# the seven that touches the world state hardest — the largest hinted blob at 191,807 bytes, three
# sibling paths where the others take two, and two public-data preimages where the others take one
# — so a budget stated on it is stated on the corpus's worst case for the boundary rather than on
# its easiest.
M15_REPRESENTATIVE=storage

# THE BOUNDARY-CROSSING BUDGET, per transaction, for the DB surface. Twenty-two is what the corpus
# actually costs (18 for five of the seven, 21 for `storage`, 22 for `revert` and `burn`), so the
# budget is the measured maximum plus the room one more nested call would need. It is a CEILING a
# regression crosses, not a target: a shape change that made the AVM consult the host per memory
# access rather than per tree operation would go through it by three orders of magnitude.
M15_CROSSING_BUDGET="${M15_CROSSING_BUDGET:-32}"

export M15_TREE_NAME M15_WASM_BUILD M15_NATIVE_BUILD M15_HOST M15_BENCH_SRC M15_CROSSINGS_LIB

# ---------------------------------------------------------------------------
# m15_tree -> the prepared worktree, or die. M13's ten patches, in M15's work directory.
# ---------------------------------------------------------------------------
# A command substitution runs in a SUBSHELL, so `TREE=$(m15_tree)` leaves `M15_TREE` unset in the
# caller and the caller's own `m6_tree_or_die M15_TREE` then fails on a tree that was prepared
# perfectly well. Every caller therefore writes `M15_TREE="$(m15_tree)"`, which is the shape M13's
# own checks use — and this comment is here because M15 lost a run to the other one.
m15_tree() {
  local t
  t="$(m13_tree)"
  M15_TREE="$t"
  m6_tree_or_die M15_TREE
  export M15_TREE
  printf '%s\n' "$M15_TREE"
}

# THE CONFIGURES ARE INCREMENTAL, and that is a decision rather than an optimisation.
#
# `m6_configure` and `m6_native_configure` both `rm -rf` the build directory first, which is right
# for a milestone whose subject IS the build. M15's subject is a measurement, and six checks each
# deleting and re-creating the same two builds would cost an hour to produce six byte-identical
# modules. The alternative the campaign has used before — one check builds and the rest read what
# it left — is a check depending on state it did not produce, which is the defect M15's own carried
# fix is about.
#
# So every M15 check configures and builds for itself, INCREMENTALLY: cmake re-runs, ninja finds
# nothing to do, and the check has produced the artefact it then measures. Each check passes the
# same options, so a second configure cannot silently change what the first built; and the tree
# they run in is checked for freshness by `m6_prepare_tree` on every call, so a stale SOURCE is
# caught even though the build is reused.
m15_build_wasm() { # <tree>
  local tree="$1"
  m6_configure_incremental "$tree" wasm-avm "$M15_WASM_BUILD" -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON
  M15_WASM_CONFIGURE_RC=$?
  [ "$M15_WASM_CONFIGURE_RC" -eq 0 ] || return "$M15_WASM_CONFIGURE_RC"
  m6_build "$tree" "$M15_WASM_BUILD" avm.wasm.gz
  M15_WASM_BUILD_RC=$?
  return "$M15_WASM_BUILD_RC"
}

m15_build_native() { # <tree>
  local tree="$1"
  m15_native_configure_incremental "$tree" "$M15_NATIVE_BUILD" -DAVM_DIFFERENTIAL=ON -DAVM_REACTOR=ON \
    -DFETCHCONTENT_TRY_FIND_PACKAGE_MODE=NEVER
  M15_NATIVE_CONFIGURE_RC=$?
  [ "$M15_NATIVE_CONFIGURE_RC" -eq 0 ] || return "$M15_NATIVE_CONFIGURE_RC"
  m6_build "$tree" "$M15_NATIVE_BUILD" avm_differential
  M15_NATIVE_BUILD_RC=$?
  return "$M15_NATIVE_BUILD_RC"
}

# The inputs file both arms are driven from: `avm_differential reactorinputs`, upstream's own
# msgpack packers, emitted by THIS milestone's own native build into THIS milestone's work
# directory.
m15_reactor_inputs() { printf '%s\n' "$M15_WORK/reactor-inputs.txt"; }

m15_make_inputs() { # <tree>
  local tree="$1" out; out="$(m15_reactor_inputs)"
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    "$1" reactorinputs
  ' "$tree/barretenberg/cpp/$M15_NATIVE_BUILD/bin/avm_differential" >"$out" 2>"$out.err"
}

# The native counterpart of `m6_configure_incremental`. `m6_native_configure` deletes; this one
# does not, for the reason above. Everything else about it — the `yarn install` for
# `nodejs_module`, the explicit clang paths, the compile database — is copied from it deliberately
# rather than referenced, because the two must not drift into configuring differently.
m15_native_configure_incremental() { # <tree> <bdir> [args...]
  local tree="$1" bdir="$2"; shift 2
  local log="$tree/m6-$bdir.log"
  m6_in_devshell '
    tree="$1"; bdir="$2"; shift 2
    cd "$tree/barretenberg/cpp" || exit 90
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    if [ ! -d src/barretenberg/nodejs_module/node_modules ]; then
      ( cd src/barretenberg/nodejs_module && yarn install ) || exit 92
    fi
    cmake --preset default -B "$bdir" -DAVM_TRANSPILER_LIB= \
      -DCMAKE_C_COMPILER="$(command -v clang)" -DCMAKE_CXX_COMPILER="$(command -v clang++)" \
      -DCMAKE_EXPORT_COMPILE_COMMANDS=ON "$@"
    rc=$?
    echo "### configure_rc=$rc"
    exit $rc
  ' "$tree" "$bdir" "$@" >"$log" 2>&1
}

m15_wasm_module() { printf '%s\n' "$1/barretenberg/cpp/$M15_WASM_BUILD/bin/avm.wasm"; }

# ---------------------------------------------------------------------------
# m15_host <wasm> <inputs> <mode> <out> [args...]
#
# stdout and stderr are kept SEPARATE, because the host prints `key value` lines on stdout and
# anything on stderr is a diagnostic that must not become a parsed key. Returns the host's status.
# ---------------------------------------------------------------------------
m15_host() { # <wasm> <inputs> <mode> <out> [args...]
  local wasm="$1" inputs="$2" mode="$3" out="$4"; shift 4
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    host="$1"; shift
    node "$host" "$@"
  ' "$M15_HOST" "$wasm" "$inputs" "$mode" "$@" >"$out" 2>"$out.err"
}

# m15_key <file> <key> -> the value, or the empty string. Anchored on BOTH sides: a key is matched
# as a WHOLE key, so `cost.resident.us.0` cannot be answered by `cost.resident.us.01` and
# `snapshot.match.noteHashTree` cannot be answered by a longer key ending in it. M14's own reader
# had this shape and it is copied rather than re-invented.
m15_key() { # <file> <key>
  awk -v k="$2" 'index($0, k " ") == 1 { print substr($0, length(k) + 2); found = 1; exit }
                 END { if (!found) exit 0 }' "$1" 2>/dev/null
}

# m15_stderr_unexpected <file> -> the number of stderr lines that are neither node's own WASI
# warning nor the AVM's own logging.
#
# stdout and stderr are kept apart everywhere in this campaign, and M15 asserts on stderr's CONTENT
# rather than on its emptiness, because a correct run writes to it for two reasons that have
# nothing to do with a failure:
#
#   * node 24 prints "ExperimentalWarning: WASI is an experimental feature" and a
#     `--trace-warnings` hint on every run that uses `node:wasi`;
#   * the AVM itself logs. That is DRIFT D11 — the wasm AVM logs at VERBOSE and the native one at
#     INFO, unconditionally — so `Simulating...`, `[NON_REVERTIBLE] Inserting ...` and their
#     siblings are the module working, not the module complaining.
#
# Asserting emptiness would fail on a correct run; `--no-warnings` or a redirect would suppress a
# real diagnostic along with those. So what is asserted is that stderr carries NOTHING FROM THE
# FAILURE VOCABULARY — the words a C++ exception, a trap, an abort or a node stack trace put there
# — and the tolerated lines are named, so node or the AVM changing what it prints becomes a finding
# rather than a silently widened filter.
m15_stderr_unexpected() { # <file>
  [ -f "$1" ] || { printf '0\n'; return; }
  # `grep -c` prints its count even when that count is zero and exits 1 for it, so the trailing
  # `|| true` swallows the STATUS and not the output — a `|| printf 0` there would print a second
  # zero and every caller would be comparing "0" against "0\n0".
  #
  # ONE exclusion, and it is named rather than folded into the vocabulary: the AVM logs a revert's
  # own message, and the corpus's `revert` program reverts with "Assertion failed:". A REVERT IS A
  # TRANSACTION OUTCOME, NOT A FAILURE — conflating the two is the confusion M17's
  # trap-versus-revert requirement exists to prevent — so the line that reports one is excluded by
  # its own shape (`halted via REVERT with message:`) and the word "Assertion" stays in the
  # vocabulary for every other line.
  grep -v 'halted via REVERT with message:' "$1" \
    | grep -cE '(^|[^A-Za-z])([Ee]rror|Traceback|Assertion|abort|Aborted|terminate called|RuntimeError|LinkError|panicked|Segmentation)([^A-Za-z]|$)' \
    || true
}

# m15_stderr_lines <file> — how much the run wrote to stderr at all, for the record. Reported, not
# asserted: it is a function of the AVM's log level (D11) and of how many transactions ran.
m15_stderr_lines() { grep -c . "$1" 2>/dev/null || true; }

# The number of `key value` lines a host run produced. Non-emptiness is a precondition everywhere
# in this milestone: a comparison between two empty outputs succeeds, and this campaign has already
# had two of those.
m15_lines() { grep -c . "$1" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# THE CHECKPOINT BENCHMARK, built against a tree it does not own.
#
# m15_build_bench <tree> — compiles verification/m15/world_state_checkpoint_bench.cpp with the
# compile flags CMake used for THAT TREE's own world_state_reference/memory_merkle_db.cpp, read out
# of the build's compile database, so the benchmark is built the way the library it links was
# built. This is M14's `m14_build_probe`, generalised over the source file; the flag extraction is
# the same because a second copy of a flag list is a second description of a build.
#
# The binary is named after the SOURCE, not after the tree, and is written into the tree's build
# directory beside M14's probe. It cannot collide with anything M14 builds.
# ---------------------------------------------------------------------------
M15_BENCH_BIN_NAME=world_state_checkpoint_bench

m15_build_bench() { # <tree> <build-dir-name>
  local tree="$1" bdir="${2:-$M14_NATIVE_BUILD}"
  local log="$tree/m15-bench.log"
  m6_in_devshell '
    tree="$1"; src="$2"; bdir="$3"; outname="$4"
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
    clang++ $flags "$src" -o "$bdir/$outname" \
      -Wl,--start-group $libs -Wl,--end-group -llmdb -lpthread 2>&1
    rc=$?
    echo "### bench_cc_rc=$rc"
    exit $rc
  ' "$tree" "$M15_BENCH_SRC" "$tree/barretenberg/cpp/$bdir" "$M15_BENCH_BIN_NAME" >"$log" 2>&1
}

m15_bench_bin() { printf '%s\n' "$1/barretenberg/cpp/${2:-$M14_NATIVE_BUILD}/$M15_BENCH_BIN_NAME"; }

m15_run_bench() { # <tree> <out-file> [reps] [build-dir]
  local tree="$1" out="$2" reps="${3:-9}" bdir="${4:-$M14_NATIVE_BUILD}"
  local bin; bin="$(m15_bench_bin "$tree" "$bdir")"
  [ -x "$bin" ] || return 90
  m6_in_devshell '
    export LD_LIBRARY_PATH="/usr/lib:${LD_LIBRARY_PATH:-}"
    "$1" "$2"
  ' "$bin" "$reps" >"$out" 2>"$out.err"
}

# m15_bkey <file> <key> — the benchmark prints `key=value`, not `key value`, because it is a C++
# program whose sibling (M14's probe) established that shape. Anchored the same way.
m15_bkey() { # <file> <key>
  awk -v k="$2" -F= 'index($0, k "=") == 1 { print substr($0, length(k) + 2); found = 1; exit }
                     END { if (!found) exit 0 }' "$1" 2>/dev/null
}

# ratio_x100 <a> <b> -> round(100 * a / b), or the empty string if b is 0. Integer arithmetic in
# awk rather than bash, because these are microsecond counts that can exceed what `$(( ))` handles
# comfortably once multiplied by 100, and because a division by zero must produce nothing rather
# than a shell error that the caller then compares against a number.
m15_ratio_x100() { # <a> <b>
  awk -v a="$1" -v b="$2" 'BEGIN { if (b + 0 == 0) exit 0; printf "%d\n", (a * 100.0 / b) + 0.5 }'
}
