#!/usr/bin/env bash
# Shared machinery for the M17 checks — the Node host driving `avm.wasm` from TypeScript.
#
# WHAT M17 MEASURES, AND WHAT IT DOES NOT.
#
# It measures THE HOST, not the module. The module is M12's, built here from the same nine-patch
# tree and by the same functions, so nothing about `avm.wasm` is re-argued: its twelve imports, its
# thirty-nine exports, its size and its msgpack ABI are M12's numbers and `REACTOR-ABI.md` is where
# they live. What is new here is a TypeScript package a consumer can import — M18's orchestration,
# M24 and M25's tracing — and the properties that package has to have before anything is built on
# it: the twelve imports satisfied from Node's own WASI, a trap that can never be reported as a
# revert, a module compiled once and instances pooled, and a transcript that agrees with the native
# x86-64 driver line for line.
#
# THE TREE IS M12's AND SO IS THE BUILD. `M12_WORK` is pointed at `$M17_WORK` before
# lib_m12_reactor.sh is sourced, which in turn does the same for M9's, M8's, M7's and M6's work
# directories, so every tree, configure and build happens inside M17's own directory and cannot
# touch another milestone's evidence. That is M12's and M13's pattern, unchanged.
#
# Nothing here has a skip path. A tree that cannot be prepared, a build that fails, a runtime that
# is missing or a transcript with no lines in it is `die` or a failed assertion.
#
# Not to be executed directly: sourced by verification/verify_node_*.sh and test_node_*.sh, AFTER
# lib.sh.

# From an empty directory this builds what M12 builds — the wasm and native `avm_differential`, the
# reactor and its controls — because the host has to be driven against a real module and compared
# against a real native reference. /tmp is usually a tmpfs and is the wrong place; require_work_dir
# turns "it filled up" into one precondition failure rather than a run of wrong answers, and holds
# the directory under flock so two runs cannot rebuild the tree under each other.
M17_WORK="${M17_WORK:-$HOME/.cache/aztec-m17-node-host}"
M12_WORK="$M17_WORK"
export M17_WORK M12_WORK

# shellcheck source=lib_m12_reactor.sh
. "$VERIFY_DIR/lib_m12_reactor.sh"

# The package under test.
M17_PKG="$REPO_ROOT/node-host"
M17_CLI="$M17_PKG/src/cli.ts"
M17_DOC="$REPO_ROOT/NODE-HOST.md"

# The three sources the reuse enumeration names, so the check reads them rather than quoting a
# conclusion. All three are in the fork at the anchor.
M17_BBJS_SHIM="barretenberg/ts/bb.js/src/barretenberg_wasm/barretenberg_wasm_base/index.ts"
M17_UPSTREAM_NODE_WASI_HOST="barretenberg/cpp/scripts/run_wasm_bench_node.mjs"

# The engine probe lives inside the package, so `tsc -p tsconfig.json` already covers it.
M17_ENGINE_PROBE="$M17_PKG/src/engine-probe.ts"

# The eleven WASI imports are NOT restated here. They are read out of REACTOR-ABI.md's own table by
# `m17_reactor_abi_wasi_imports`, because M17's deliverable says to read the list from the artefact
# rather than from memory, and a second copy of the list in this file would be exactly the memory
# it warns about.
M17_REACTOR_ABI="$REPO_ROOT/REACTOR-ABI.md"

# bb.js's shim covers these two of the eleven and nothing else. Derived by the check from the fork's
# own file; the identity here is what the check asserts the derivation against.
M17_BBJS_COVERED="clock_time_get proc_exit"
# …and it supplies these three, which `avm.wasm` does not import at all.
M17_BBJS_EXTRA="random_get logstr throw_or_abort_impl"

# The engine. MEASURED on the pinned Node: V8 accepts BOTH exception encodings by default, so the
# gate is only a gate with legacy support switched off. Both facts are asserted.
M17_V8_LEGACY_EH_OFF="--no-experimental-wasm-legacy-eh"

# The peak the node host reaches driving all seven corpus programs through ONE pooled instance,
# measured. The budget is deliberately above it and deliberately below three times it, for M8's
# reason: a budget equal to the measurement fails on any change and gets raised rather than read.
M17_MEASURED_PEAK_PAGES=199
M17_MEASURED_PEAK_KIB=12736
M17_PEAK_PAGE_BUDGET="${M17_PEAK_PAGE_BUDGET:-260}"
# The instance starts at the module's own declared minimum. REACTOR-ABI.md's figure, re-read from
# the module by the loader on every run rather than trusted from here.
M17_DECLARED_MIN_PAGES=130

# The corpus, in the order the driver emits it. M12's list, quoted rather than re-derived.
M17_PROGRAMS="$M12_PROGRAMS"
M17_EXPECTED_PROGRAMS="$M12_EXPECTED_PROGRAMS"

# The step corpus for the batching check. M9's identity, quoted from M12.
M17_STEP_PROGRAM="$M12_STEP_PROGRAM"
M17_STEP_COUNT="$M12_STEP_COUNT"
M17_STEP_BATCH="${M17_STEP_BATCH:-4096}"

export M17_PKG M17_CLI M17_DOC M17_REACTOR_ABI M17_ENGINE_PROBE

# ---------------------------------------------------------------------------
# Artefacts. Written by verify_node_v8_accepts_module, which is the check that BUILDS, and read by
# every other check, so no two of them can disagree about what was measured.
# ---------------------------------------------------------------------------
m17_measured_env()   { printf '%s\n' "$M17_WORK/m17-measured.env"; }
m17_inputs()         { printf '%s\n' "$(m12_reactor_inputs)"; }
m17_native_transcript() { printf '%s\n' "$(m12_native_transcript)"; }
m17_out()            { printf '%s\n' "$M17_WORK/node-host.$1"; }
m17_err()            { printf '%s\n' "$M17_WORK/node-host.$1.err"; }

# ---------------------------------------------------------------------------
# m17_run <mode> [extra node flags via M17_NODE_FLAGS] [args...]
#
# Drives the TypeScript CLI under the fork's dev shell. stdout and stderr are kept APART for M8's
# reason and M9's: `common/log.cpp` sets `bb_log_level = VERBOSE` unconditionally under `__wasm__`,
# so the AVM narrates its own progress on fd 2 and a merged stream would make every comparison a
# comparison of log levels.
#
# Returns the run's exit status; the caller asserts on it.
# ---------------------------------------------------------------------------
m17_run() { # <mode> <out> <err> [args...]
  local mode="$1" out="$2" err="$3"; shift 3
  local wasm; wasm="$(m12_wasm_bin avm.wasm)"
  [ -f "$wasm" ] || die "no reactor module at $wasm — nothing to drive"
  [ -f "$(m17_inputs)" ] || die "no reactor inputs at $(m17_inputs)"
  [ -f "$M17_CLI" ] || die "the node host's CLI is missing: $M17_CLI"
  m6_in_devshell '
    cli="$1"; wasm="$2"; inputs="$3"; mode="$4"; t="$5"; err="$6"; flags="$7"; shift 7
    # shellcheck disable=SC2086
    timeout --foreground --preserve-status -s KILL "$t" node $flags "$cli" "$wasm" "$inputs" "$mode" "$@" 2>"$err"
  ' "$M17_CLI" "$wasm" "$(m17_inputs)" "$mode" "$M7_RUN_TIMEOUT" "$err" "${M17_NODE_FLAGS:-}" "$@" >"$out"
}

# m17_field <file> <key> -> the value of a `<key> <value>` line, or the empty string.
m17_field() {
  [ -f "$1" ] || die "m17_field: no such file: $1"
  awk -v k="$2" '$1 == k { $1 = ""; sub(/^ /, ""); print; exit }' "$1"
}

# ---------------------------------------------------------------------------
# m17_completeness <transcript> <mode>
#
# M9's lesson, applied here from the first commit rather than after an afternoon: every CLI mode
# ends with a `<mode>.done 1` sentinel and prints nothing after it, so a transcript missing it was
# TRUNCATED and not short. Returns `complete` or a token naming the truncation.
# ---------------------------------------------------------------------------
# Delegates to lib.sh's `transcript_completeness`; see the note there on why there is now one
# implementation instead of three. The mode-to-sentinel spelling stays here, because that is M17's
# CLI contract rather than a property of transcripts.
m17_completeness() { transcript_completeness "$1" "$2.done"; }

# ---------------------------------------------------------------------------
# m17_reactor_abi_wasi_imports
#
# The eleven, READ OUT OF REACTOR-ABI.md's own import table rather than restated here. The
# milestone says in as many words not to restate M12's list from memory, and a copy of it in this
# library would be that copy. Prints one bare name per line, sorted.
# ---------------------------------------------------------------------------
m17_reactor_abi_wasi_imports() {
  [ -f "$M17_REACTOR_ABI" ] || die "REACTOR-ABI.md is missing: $M17_REACTOR_ABI"
  sed -n 's/^| `wasi_snapshot_preview1\.\([a-z_]*\)` |.*/\1/p' "$M17_REACTOR_ABI" | LC_ALL=C sort -u
}

# m17_reactor_abi_declares_min_pages -> the declared minimum REACTOR-ABI.md records, or empty.
m17_reactor_abi_declares_min_pages() {
  sed -n 's/.*Declared minimum \([0-9]*\) pages.*/\1/p' "$M17_REACTOR_ABI" | head -1
}

# ---------------------------------------------------------------------------
# m17_tsc <args...> — the nix-pinned TypeScript compiler, inside the dev shell.
#
# The trap/revert distinction is enforced by the TYPE SYSTEM, so the type checker is part of what
# is under test rather than a lint step. It comes from `pkgs.typescript` in this repo's own flake:
# no npm install, no network, and the same compiler on every machine.
# ---------------------------------------------------------------------------
M17_TSC_FLAGS="--noEmit --target ES2022 --lib ES2022,DOM --module nodenext --moduleResolution nodenext --allowImportingTsExtensions --strict --erasableSyntaxOnly --verbatimModuleSyntax --noImplicitOverride"

# The local Node declarations go on the command line too: passing files to `tsc` makes it ignore
# tsconfig.json, so without them `import { WASI } from 'node:wasi'` is an unresolved module and the
# file fails for a reason that has nothing to do with what is being checked.
m17_tsc_file() { # <file> -> tsc's output; status is tsc's
  ( cd "$REPO_ROOT" && nix develop --command bash -c \
      "cd node-host && tsc $M17_TSC_FLAGS types/node-subset.d.ts \"\$1\"" bash "$1" ) 2>&1
}

m17_tsc_project() { # -> tsc's output over the whole package; status is tsc's
  ( cd "$REPO_ROOT" && nix develop --command bash -c 'cd node-host && tsc -p tsconfig.json' ) 2>&1
}

# ---------------------------------------------------------------------------
# m17_prepare — build the tree once and write the artefacts every check reads.
#
# Called by verify_node_v8_accepts_module. Every other check calls m17_measured, which RUNS this
# one if there is no record; it is never invented, defaulted or skipped.
# ---------------------------------------------------------------------------
m17_measured() {
  if [ ! -f "$(m17_measured_env)" ]; then
    note "no measurement on record — running verify_node_v8_accepts_module to produce one"
    mkdir -p "$M17_WORK"
    "$VERIFY_DIR/verify_node_v8_accepts_module.sh" >"$M17_WORK/build-for-record.log" 2>&1 \
      || die "could not produce a measurement: see $M17_WORK/build-for-record.log"
  fi
  [ -f "$(m17_measured_env)" ] || die "measurement record missing at $(m17_measured_env)"
  # shellcheck disable=SC1090
  . "$(m17_measured_env)"
  # `m12_wasm_bin` builds its path out of $M12_TREE, which only the check that PREPARED the tree
  # has in its own shell. Restoring it from the record is what lets every other check name the same
  # artefacts without re-preparing anything — and it is restored from the record rather than
  # re-derived, so two checks cannot disagree about which tree was measured.
  M12_TREE="$M17_TREE"
  export M12_TREE
  [ -d "$M12_TREE/.git" ] || [ -f "$M12_TREE/.git" ] \
    || die "the recorded tree $M12_TREE is not a worktree; re-run verify_node_v8_accepts_module"
  # Every artefact the record NAMES is asserted present before any predicate reads it. M6's review
  # found four assertions passing over a build directory that held nothing, because every predicate
  # returned 0 over a missing path.
  m8_require_artifacts "$(m12_wasm_bin avm.wasm)" "$(m17_inputs)" "$(m17_native_transcript)"
}
