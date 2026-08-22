#!/usr/bin/env bash
# Shared machinery for the M4 checks — the prepared upstream patch that moves
# barretenberg's wasm toolchain from wasi-sdk 27 to 33.
#
# The measurements all come from the same two trees, in M3's shape:
#
#   base     — the fork at the patch's base commit, 233d8e0993, unmodified.
#   patched  — the same commit with the prepared format-patch applied by `git am`.
#
# and from two toolchains, both pinned by nix and both built from the recorded
# upstream release tarball hashes (`nix/wasi-sdk.nix`):
#
#   27.0     — what upstream pins today. Here only as evidence: it cannot link
#              C++ exceptions, and it is the "before" half of the artefact
#              comparison.
#   33.0     — what the patch moves to, and what this repo's dev shells ship.
#
# HOW THE TWO ARTEFACT BUILDS ARE MADE COMPARABLE. The UNPATCHED `wasm` preset
# hardcodes `"WASI_SDK_PREFIX": "/opt/wasi-sdk"` inside its own `environment`
# block, so `$env{WASI_SDK_PREFIX}` can never resolve anywhere else — that is one
# of the three things the patch fixes. Rather than work around it on one side and
# not the other (which would make the two builds differ by more than the
# toolchain), BOTH builds run under `bwrap --tmpfs /opt --bind <sdk> /opt/wasi-sdk`
# and invoke the preset verbatim. The compiler command lines are then identical by
# construction and the only difference between the two builds is the toolchain's
# bytes.
#
# Nothing here has a skip path. If a tree cannot be prepared, a toolchain cannot
# be realised or a build fails, the caller's assertion fails or `die` fires.
#
# Not to be executed directly: sourced by verification/*wasi*33*.sh, AFTER lib.sh
# (it uses FORK_ROOT, REPO_ROOT, WORKSPACE_ROOT, die, note).

# The commit the patch is generated against, and the local branch that carries the
# same change. Both are asserted rather than assumed.
M4_BASE_REV=233d8e0993

# The prepared upstream contribution. Named `aztec-wasi-sdk-33`, not
# `aztec-wasi-sdk-33-exceptions`: see the M4 notes in the milestone file for the
# reconciliation. There is exactly one directory for this patch.
M4_PATCH_DIR="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs/aztec-wasi-sdk-33"
M4_PATCH_FILE="$M4_PATCH_DIR/0001-build-move-the-wasm-toolchain-from-wasi-sdk-27-to-33.patch"

# The five files the patch touches. Re-derived from the patch by
# verify_wasi_33_native_builds_unaffected; recorded here so the other checks can
# refer to the same list.
M4_TOUCHED_FILES="barretenberg/cpp/CMakePresets.json barretenberg/cpp/cmake/threading.cmake bootstrap.sh build-images/src/Dockerfile scripts/setup-container.sh"

# Where the two worktrees and their build directories live. Deliberately outside
# both repos so no build artefact can land in a git status. Two full
# `barretenberg.wasm` builds are about 3 GB, so a tmpfs /tmp is the wrong place
# and this defaults under $HOME; require_work_dir makes a work directory that
# cannot hold the build ONE precondition failure rather than a run of wrong
# answers (M9's review, on a quota-limited /tmp).
M4_WORK="${M4_WORK:-$HOME/.cache/aztec-m4-wasi-sdk-33}"
require_work_dir "$M4_WORK" 4

# The exception probe. The same file the prepared contribution ships, so the
# checks and the thing a maintainer would run are not two different programs.
M4_PROBE="$M4_PATCH_DIR/probe/exc.cpp"

# What the probe must print. A throw across a `noinline` boundary, caught BY TYPE,
# with execution continuing afterwards — the last two lines are what makes this a
# statement about catching rather than about aborting.
M4_PROBE_EXPECTED='opcode ok 1
reverted: out of gas
opcode ok 7
survived'

# `ecc_tests` from the `wasm` preset cannot run its WHOLE suite, on either
# toolchain: the ScalarMultiplication* suites call `bb::set_parallel_for_concurrency`,
# which under `MULTITHREADING=OFF` (what the `wasm` preset sets, and what upstream
# sets there) calls `throw_or_abort("Cannot set hardware concurrency when
# multithreading is disabled.")` — `common/thread.cpp:27`. That is upstream's own
# configuration, it aborts identically under 27 and 33, and the checks assert that
# identity BEFORE applying the filter rather than filtering it away quietly.
# Upstream itself only ever runs this binary out of `build-wasm-threads`.
M4_ECC_FILTER="--gtest_filter=-ScalarMultiplication*"
M4_ECC_ABORT_MESSAGE="Cannot set hardware concurrency when multithreading is disabled."
M4_ECC_ABORT_SUITE="ScalarMultiplication"
# What the filtered suite does, measured. Pinned so a silent change in either
# direction is a failure rather than a new baseline.
M4_ECC_RAN=998
M4_ECC_SUITES=72
M4_ECC_PASSED=924

# How long a wasm gtest binary is allowed to take. The filtered suite takes about
# two seconds; this is not a performance budget, it is the difference between
# "hung" and "slow", and one of the two artefacts really does hang.
#
# The kill signal is SIGKILL, not the default SIGTERM, and that is load-bearing:
# node runs the guest SYNCHRONOUSLY, so while the wasm module spins the event loop
# never turns and a SIGTERM is never delivered. `timeout 180 node ...` on the
# hanging binary waits forever.
M4_RUN_TIMEOUT="${M4_RUN_TIMEOUT:-180}"

# The host that runs barretenberg's own `--import-memory` wasm binaries on V8.
# See its header for why it exists (wasmtime 47 removed `-Sthreads`).
M4_WASM_HOST="$REPO_ROOT/verification/wasm_host/run_wasm_test_binary.mjs"

export M4_BASE_REV M4_PATCH_DIR M4_PATCH_FILE M4_WORK M4_PROBE M4_WASM_HOST

# ---------------------------------------------------------------------------
# m4_in_devshell <script-text> [args...]
#
# Runs a script inside the FORK's own `nix develop`. The fork's shell is the
# reproducible definition of cmake / ninja / clang-format-20 / bwrap / wasi-sdk 33;
# running the build outside it would make the numbers depend on the host.
# ---------------------------------------------------------------------------
# The fork's shellHook prints a banner on the dev shell's STDOUT, which would
# otherwise land in the middle of anything the caller parses or compares. The
# sentinel is emitted as the first thing inside the shell and everything up to and
# including it is dropped, so what the caller sees is exactly the script's output.
M4_SENTINEL=$'\001M4OUT'

m4_in_devshell() {
  local script="$1"; shift
  # Streamed, never buffered in a shell variable: some of the things this runs
  # (wasm-objdump -x on a 17 MB module) produce megabytes, and a command
  # substitution around that hits the argument-length limit of whatever the
  # filter is.
  local st; st="$(mktemp)"
  ( cd "$FORK_ROOT" || exit 90
    nix develop --command bash -uo pipefail \
      -c "printf '%s\n' '$M4_SENTINEL'; $script" bash "$@"
    echo $? >"$st" ) \
  | awk -v s="$M4_SENTINEL" 'seen { print } $0 == s { seen = 1 }'
  local rc; rc="$(cat "$st")"; rm -f "$st"
  return "${rc:-1}"
}

# ---------------------------------------------------------------------------
# m4_sdk <27|33>  ->  absolute store path of that wasi-sdk, on stdout
#
# Realised from the fork's flake, so both toolchains come from the recorded
# release tarball hashes rather than from whatever is installed. Dies if the
# toolchain cannot be built: a missing toolchain is a check that cannot run, and
# a check that cannot run must fail.
# ---------------------------------------------------------------------------
m4_sdk() {
  local want="$1" attr path
  case "$want" in
    27) attr=wasi-sdk-27 ;;
    33) attr=wasi-sdk ;;
    *) die "m4_sdk: unknown wasi-sdk major '$want'" ;;
  esac
  path=$( cd "$FORK_ROOT" && nix build --no-link --print-out-paths ".#$attr" 2>/dev/null )
  [ -n "$path" ] && [ -x "$path/bin/clang++" ] \
    || die "could not realise wasi-sdk $want from $FORK_ROOT#$attr"
  # The derivation says which version it is; assert it rather than trusting the
  # attribute name, so a mis-wired flake shows up here and not as a mystery later.
  case "$(head -1 "$path/VERSION")" in
    "$want".*) ;;
    *) die "wasi-sdk $want realised as $(head -1 "$path/VERSION") ($path)" ;;
  esac
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# m4_prepare_trees
#
# Idempotently materialises $M4_WORK/base and $M4_WORK/patched.
# ---------------------------------------------------------------------------
m4_prepare_trees() {
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v nix >/dev/null 2>&1 || die "nix is required (the builds run in the fork's dev shell)"
  [ -e "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT"
  [ -f "$M4_PATCH_FILE" ] || die "the prepared patch is missing: $M4_PATCH_FILE"

  git -C "$FORK_ROOT" rev-parse --verify --quiet "$M4_BASE_REV^{commit}" >/dev/null \
    || die "base commit $M4_BASE_REV is not in $FORK_ROOT"

  mkdir -p "$M4_WORK"

  if [ ! -e "$M4_WORK/base/.git" ]; then
    git -C "$FORK_ROOT" worktree add --detach "$M4_WORK/base" "$M4_BASE_REV" >/dev/null 2>&1 \
      || die "could not create the base worktree at $M4_WORK/base"
  fi
  [ "$(git -C "$M4_WORK/base" rev-parse HEAD)" = "$(git -C "$FORK_ROOT" rev-parse "$M4_BASE_REV")" ] \
    || die "$M4_WORK/base is not at $M4_BASE_REV — remove it and re-run"

  if [ ! -e "$M4_WORK/patched/.git" ]; then
    git -C "$FORK_ROOT" worktree add --detach "$M4_WORK/patched" "$M4_BASE_REV" >/dev/null 2>&1 \
      || die "could not create the patched worktree at $M4_WORK/patched"
    # -3 is deliberately NOT passed: the patch must apply to this base exactly.
    if ! git -C "$M4_WORK/patched" am "$M4_PATCH_FILE" >"$M4_WORK/am.log" 2>&1; then
      git -C "$M4_WORK/patched" am --abort >/dev/null 2>&1 || true
      die "git am of $(basename "$M4_PATCH_FILE") failed on $M4_BASE_REV — see $M4_WORK/am.log"
    fi
  fi
  [ "$(git -C "$M4_WORK/patched" rev-parse HEAD^)" = "$(git -C "$FORK_ROOT" rev-parse "$M4_BASE_REV")" ] \
    || die "$M4_WORK/patched is not $M4_BASE_REV + one patch — remove it and re-run"
}

# ---------------------------------------------------------------------------
# m4_wasm_build <tree-dir> <sdk-path> <preset> <target...>
#
# Configures (once per build dir) and builds, with <sdk-path> bound at
# /opt/wasi-sdk so the preset is used verbatim. Returns cmake's/ninja's exit
# status — callers assert on it, separately from anything they parse out of the
# result. The full log is at <tree-dir>/m4-<preset>-build.log.
# ---------------------------------------------------------------------------
M4_INNER_BUILD="$VERIFY_DIR/wasm_host/_preset_build_inner.sh"

m4_wasm_build() {
  local tree="$1" sdk="$2" preset="$3"; shift 3
  local log="$tree/m4-$preset-build.log"
  [ -x "$M4_INNER_BUILD" ] || die "missing $M4_INNER_BUILD"
  m4_in_devshell '
    inner="$1"; tree="$2"; sdk="$3"; preset="$4"; shift 4
    command -v bwrap >/dev/null 2>&1 || { echo "### bwrap is not on PATH"; exit 91; }
    bwrap --dev-bind / / --tmpfs /opt --bind "$sdk" /opt/wasi-sdk -- \
      "$inner" "$tree" "$preset" "$@"
  ' "$M4_INNER_BUILD" "$tree" "$sdk" "$preset" "$@" >"$log" 2>&1
}

M4_NATIVE_CONFIGURE="$VERIFY_DIR/wasm_host/_native_configure_inner.sh"

# ---------------------------------------------------------------------------
# m4_native_configure <tree-dir>
#
# Configures a NATIVE build through barretenberg's own `default` preset. Returns
# cmake's exit status; the log is at <tree-dir>/m4-native-configure.log. The point
# is the resulting compile_commands.json: if the patch could reach a native build
# at all, it would show up there.
# ---------------------------------------------------------------------------
m4_native_configure() {
  local tree="$1"
  [ -x "$M4_NATIVE_CONFIGURE" ] || die "missing $M4_NATIVE_CONFIGURE"
  m4_in_devshell '"$1" "$2"' "$M4_NATIVE_CONFIGURE" "$tree" \
    >"$tree/m4-native-configure.log" 2>&1
}

# ---------------------------------------------------------------------------
# m4_wasm_imports <module.wasm>   -> "<module>.<name>" per line, sorted
# m4_wasm_c_exports <module.wasm> -> the C-ABI export names, sorted
#
# The C++ mangled exports are deliberately excluded: they are libc++ internal
# template instantiations and they DO differ between LLVM 20 and LLVM 22. What an
# embedder calls is the C-ABI surface, and that is what must not move.
# ---------------------------------------------------------------------------
m4_wasm_imports() {
  m4_in_devshell 'wasm-objdump -x "$1"' "$1" \
    | sed -n '/^Import\[/,/^Function\[/p' \
    | grep -oE '<- [a-zA-Z0-9_.]+\.[a-zA-Z0-9_]+' | sed 's/^<- //' | sort
}

m4_wasm_c_exports() {
  m4_in_devshell 'wasm-objdump -x "$1"' "$1" \
    | sed -n '/^Export\[/,/^Elem\[/p' \
    | grep -oE '\-> "[^"]+"' | sed 's/^-> "//; s/"$//' \
    | grep -v '^_Z' | grep -v '^__' | sort
}

# ---------------------------------------------------------------------------
# m4_run_wasm_gtest <module.wasm> <out-file> [args...]
#
# Runs a wasm gtest binary on V8 through the host shim and prints
# "<exit-status> <ran> <passed>". `ran`/`passed` are `-` when the summary lines
# are absent, so a binary that dies before printing them cannot be mistaken for
# one that ran zero tests. The exit status is reported SEPARATELY from the counts
# on purpose: a binary that prints a full green summary and then exits non-zero
# must not read as a pass.
# ---------------------------------------------------------------------------
m4_run_wasm_gtest() {
  local wasm="$1" out="$2"; shift 2
  local status ran passed
  m4_in_devshell 'timeout --foreground --preserve-status -s KILL "$1" node --no-warnings "$2" "$3" "${@:4}" 2>&1' \
    "$M4_RUN_TIMEOUT" "$M4_WASM_HOST" "$wasm" "$@" >"$out" 2>/dev/null
  status=$?
  ran=$(grep -oE '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran' "$out" \
        | grep -oE '[0-9]+' | head -1)
  passed=$(grep -oE '^\[  PASSED  \] [0-9]+ tests?' "$out" | grep -oE '[0-9]+' | head -1)
  printf '%s %s %s\n' "$status" "${ran:--}" "${passed:--}"
}

# ---------------------------------------------------------------------------
# m4_wasm_gtest_names <module.wasm>
#
# The binary's full "Suite.Test" list, sorted. Equal counts survive a rename or a
# drop-plus-addition; equal name sets do not. M3's lesson, applied to the wasm
# side.
# ---------------------------------------------------------------------------
# The same listing, unparsed. Used for the CENSUS: how many tests the binary
# declares, and how many of them the ScalarMultiplication filter removes. The awk
# in m4_wasm_gtest_names deliberately does not try to handle gtest's
# "Suite.  # TypeParam = ..." suite lines, because it only has to be applied
# identically to both sides; the census does have to be exact, so it is parsed
# separately.
m4_wasm_gtest_list_raw() {
  m4_in_devshell 'timeout --foreground --preserve-status -s KILL "$1" node --no-warnings "$2" "$3" --gtest_list_tests' \
    "$M4_RUN_TIMEOUT" "$M4_WASM_HOST" "$1" 2>/dev/null
}

m4_wasm_gtest_names() {
  m4_in_devshell 'timeout --foreground --preserve-status -s KILL "$1" node --no-warnings "$2" "$3" --gtest_list_tests' \
    "$M4_RUN_TIMEOUT" "$M4_WASM_HOST" "$1" 2>/dev/null \
  | awk '
      /^[A-Za-z_][A-Za-z0-9_\/]*\.$/ { suite=$1; next }
      /^  [A-Za-z_]/ { name=$1; if (suite != "") print suite name }
    ' | sort
}

# ---------------------------------------------------------------------------
# m4_normalise_transcript <file>
#
# A gtest transcript with the tree path and the per-test wall times taken out.
# Those two are the only things that legitimately differ between two builds of
# the same sources in two directories; everything else differing is a finding.
#
# One more line is dropped, and it is OUR OWN output, not the guest's: when a run
# has to be SIGKILLed the calling shell writes a "lib_wasi33.sh: line N: <pid>
# Killed  nix develop ..." notice onto the captured stream. `--preserve-status`
# stops timeout from producing it in the first place, `--foreground` stops it
# from signalling the whole process group (which is what actually reached `nix
# develop`), and the runners merge the GUEST's stderr inside the dev shell — after
# the sentinel — while dropping their own, so nix's "waiting for another Nix
# process ..." can never land in a transcript either. This filter is the belt to
# those braces, because any other signal death would otherwise corrupt a
# comparison in a way that looks like a difference between the two builds.
# ---------------------------------------------------------------------------
m4_normalise_transcript() {
  sed -e "s|$M4_WORK/[a-z]*/|<TREE>/|g" -e 's/([0-9]\+ ms[^)]*)/(T)/g' "$1" \
    | grep -v '^verification/lib_wasi33\.sh: line [0-9]*: [0-9]* Killed'
}

# ---------------------------------------------------------------------------
# m4_run_wasm_gtest_on_wasmtime <module.wasm> <out-file> [args...]
#
# THE CROSS-CHECK ON THE HOST ITSELF. Everything else about the wasm test
# binaries goes through one host (verification/wasm_host/run_wasm_test_binary.mjs
# on V8), and a finding that only one host reports is a finding about that host.
#
# wasmtime cannot supply an imported memory from the command line, which is the
# whole reason the V8 host exists. binaryen's `wasm-merge` can, though: merging a
# two-line module that EXPORTS a memory with the test module under the import
# name `env` satisfies the import statically, and the result runs on wasmtime with
# no host cooperation at all.
#
# The merged module is not byte-identical to the shipped one (wasm-merge renames
# the conflicting `memory` export), so this is a cross-check and never the primary
# measurement. Prints "<exit-status> <ran> <passed>", same shape as
# m4_run_wasm_gtest.
# ---------------------------------------------------------------------------
m4_run_wasm_gtest_on_wasmtime() {
  local wasm="$1" out="$2"; shift 2
  local merged status ran passed
  merged="$(dirname "$out")/$(basename "$out").merged.wasm"
  m4_in_devshell '
    merged="$1"; wasm="$2"; timeout_s="$3"; shift 3
    tmp="$(mktemp -d)"; trap "rm -rf $tmp" EXIT
    printf "%s\n" "(module (memory (export \"memory\") 136 65536))" > "$tmp/envmem.wat"
    wat2wasm "$tmp/envmem.wat" -o "$tmp/envmem.wasm" || exit 90
    wasm-merge "$tmp/envmem.wasm" env "$wasm" main -o "$merged" \
      --rename-export-conflicts --enable-bulk-memory --enable-simd \
      --enable-mutable-globals --enable-sign-ext --enable-nontrapping-float-to-int \
      --enable-multivalue --enable-threads >/dev/null 2>&1 || exit 91
    timeout --foreground --preserve-status -s KILL "$timeout_s" wasmtime run --dir=. "$merged" "$@" 2>&1
  ' "$merged" "$wasm" "$M4_RUN_TIMEOUT" "$@" >"$out" 2>/dev/null
  status=$?
  ran=$(grep -oE '^\[==========\] [0-9]+ tests? from [0-9]+ test suites? ran' "$out" \
        | grep -oE '[0-9]+' | head -1)
  passed=$(grep -oE '^\[  PASSED  \] [0-9]+ tests?' "$out" | grep -oE '[0-9]+' | head -1)
  printf '%s %s %s\n' "$status" "${ran:--}" "${passed:--}"
}

# ---------------------------------------------------------------------------
# m4_is_timeout <status>
#
# True for the two ways m4_run_wasm_gtest reports "it never finished": GNU
# timeout's own 124, and 137 when it had to resort to SIGKILL — which it does
# here, because a synchronously-spinning wasm guest never lets node see a
# SIGTERM, so `timeout` without `-s KILL` would wait forever.
# ---------------------------------------------------------------------------
m4_is_timeout() {
  case "$1" in 124|137) return 0 ;; *) return 1 ;; esac
}
