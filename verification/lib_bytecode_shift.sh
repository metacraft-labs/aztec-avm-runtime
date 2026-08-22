#!/usr/bin/env bash
# Shared machinery for the M5 checks — the prepared upstream patch that widens
# before shifting in `compute_public_bytecode_first_field`.
#
# Three trees, in M3's and M4's shape, all worktrees of the fork:
#
#   base     — the fork at the patch's base commit, 233d8e0993, unmodified.
#   patched  — the same commit with the prepared format-patch applied by `git am`.
#   decoy    — the same commit with a DELIBERATELY WRONG fix: the widening is
#              there but the shift count is 31. It exists because a check that
#              only establishes "the 64-bit results did not change" would go green
#              for any patch that leaves them alone, including one that fixes the
#              expression to something else wrong. The decoy is what proves the
#              comparison has teeth. (M4's review found exactly this hole: a tree
#              amended to pin the wrong SDK version satisfied every assertion.)
#
# WHY A CONFIGURED TREE IS NEEDED AT ALL. The probes use barretenberg's own
# `uint256_t` and its own `DOM_SEP__PUBLIC_BYTECODE`, not stand-ins, and
# `numeric/uint256/uint256.hpp` reaches `common/serialize.hpp` and `common/mem.hpp`,
# which need the msgpack and tracy headers CMake fetches into `build/_deps`. So the
# checks configure each tree through barretenberg's OWN `default` preset (M4's
# `wasm_host/_native_configure_inner.sh`, reused unchanged) and take the compile
# flags out of the resulting `compile_commands.json` — the same flags CMake gives
# the real translation unit, rather than a hand-written line that could differ from
# it. Configuring costs about 20 seconds per tree; `ninja vm2_sim` about 40.
#
# Nothing here has a skip path. If a tree cannot be prepared, a toolchain cannot be
# realised or a build fails, the caller's assertion fails or `die` fires.
#
# Not to be executed directly: sourced by verification/*bytecode*.sh and
# verification/*shift*.sh, AFTER lib.sh (it uses FORK_ROOT, WORKSPACE_ROOT,
# VERIFY_DIR, die, note).

# The commit the patch is generated against, and the fork branch that carries the
# same change. The branch is only a cross-check: everything is measured from the
# tree `git am` of the patch FILE produces, so the artefact that would be filed
# upstream is the artefact that is measured.
M5_BASE_REV=233d8e0993
M5_PATCH_BRANCH=p3-widen-shift

# The prepared upstream contribution. Named `aztec-bytecode-size-shift-32bit` —
# the name the milestone itself uses and the name `SERIES.md` indexes as patch 3
# of 5. There is exactly one directory for this patch.
M5_PATCH_DIR="$WORKSPACE_ROOT/codetracer-specs/upstream-bugs/aztec-bytecode-size-shift-32bit"
M5_PATCH_FILE="$M5_PATCH_DIR/0001-fix-vm2-widen-before-shifting-in-compute_public_bytec.patch"

# The one file the patch touches, and the line it touches.
M5_TU_REL="barretenberg/cpp/src/barretenberg/vm2/simulation/lib/contract_crypto.cpp"
M5_TU_LINE=61

# The probes. The same files the prepared contribution ships, so the checks and
# the thing a maintainer would run are not two different programs.
M5_PROBE_FIRST_FIELD="$M5_PATCH_DIR/repro/first_field.cpp"
M5_PROBE_DRIVER="$M5_PATCH_DIR/repro/commitment_driver.cpp"
M5_PROBE_SHIFT_C="$M5_PATCH_DIR/repro/shift.c"
M5_CONTRIB_VERIFY="$M5_PATCH_DIR/verify.sh"

# Where the three worktrees and their build directories live. Deliberately outside
# both repos so no build artefact can land in a git status, and under $HOME rather
# than /tmp: it was M5's build that exhausted the /tmp quota in M9's review, after
# which M5, M6, M7 and M8 produced more than a hundred assertion failures whose
# real cause was EDQUOT. require_work_dir turns that into one precondition line.
M5_WORK="${M5_WORK:-$HOME/.cache/aztec-m5-bytecode-shift}"
require_work_dir "$M5_WORK" 6

# The single measurement record. Written by
# test_bytecode_commitment_identical_on_64bit and
# test_bytecode_commitment_correct_on_32bit; read by
# reproduce_aztec_bytecode_size_shift_32bit, which re-derives PR.md's numbers from
# it rather than from PR.md.
M5_MEASURED="$M5_WORK/measured.env"

# The scanner that retargets barretenberg's own compile commands at wasm32.
M5_SCAN="$VERIFY_DIR/wasm_host/_wasm32_syntax_scan.py"

# The native configure, reused from M4 unchanged.
M5_NATIVE_CONFIGURE="$VERIFY_DIR/wasm_host/_native_configure_inner.sh"

export M5_BASE_REV M5_PATCH_DIR M5_PATCH_FILE M5_WORK M5_MEASURED M5_TU_REL

# ---------------------------------------------------------------------------
# m5_in_devshell <script-text> [args...]
#
# Runs a script inside the FORK's own `nix develop`, which is the reproducible
# definition of clang 20, cmake, ninja, wasmtime and wasi-sdk 33.
#
# The fork's shellHook prints a banner on the dev shell's STDOUT, which would
# otherwise land in the middle of anything the caller parses. A sentinel is emitted
# first and everything up to and including it is dropped, so what the caller sees is
# exactly the script's output. Streamed, never buffered in a shell variable.
# ---------------------------------------------------------------------------
M5_SENTINEL=$'\001M5OUT'

m5_in_devshell() {
  local script="$1"; shift
  local st; st="$(mktemp)"
  ( cd "$FORK_ROOT" || exit 90
    nix develop --command bash -uo pipefail \
      -c "printf '%s\n' '$M5_SENTINEL'; $script" bash "$@"
    echo $? >"$st" ) \
  | awk -v s="$M5_SENTINEL" 'seen { print } $0 == s { seen = 1 }'
  local rc; rc="$(cat "$st")"; rm -f "$st"
  return "${rc:-1}"
}

# ---------------------------------------------------------------------------
# m5_sdk  ->  absolute store path of wasi-sdk 33, on stdout
#
# Realised from the fork's flake, so the 32-bit toolchain comes from the recorded
# release tarball hash rather than from whatever is installed. The derivation says
# which version it is; that is asserted rather than trusting the attribute name.
# ---------------------------------------------------------------------------
m5_sdk() {
  local path
  path=$( cd "$FORK_ROOT" && nix build --no-link --print-out-paths ".#wasi-sdk" 2>/dev/null )
  [ -n "$path" ] && [ -x "$path/bin/clang++" ] \
    || die "could not realise wasi-sdk from $FORK_ROOT#wasi-sdk"
  case "$(head -1 "$path/VERSION")" in
    33.*) ;;
    *) die "wasi-sdk realised as $(head -1 "$path/VERSION") ($path), expected 33.x" ;;
  esac
  printf '%s\n' "$path"
}

# ---------------------------------------------------------------------------
# m5_patch_expr minus|plus  ->  the expression inside `return FF( ... );`
#
# Read out of the patch's OWN removed and added lines, so every downstream
# assertion about "the expression upstream has" and "the expression the patch
# installs" is anchored to the artefact that would be filed rather than to a
# string retyped in a check.
# ---------------------------------------------------------------------------
m5_patch_expr() {
  local side="$1" sigil line
  case "$side" in
    minus) sigil='-' ;;
    plus)  sigil='+' ;;
    *) die "m5_patch_expr: expected minus|plus, got '$side'" ;;
  esac
  [ -f "$M5_PATCH_FILE" ] || die "the prepared patch is missing: $M5_PATCH_FILE"
  # Diff body lines only: skip the ---/+++ file headers.
  line=$(grep -E "^[$sigil]" "$M5_PATCH_FILE" \
         | grep -v -E '^(---|\+\+\+) ' \
         | grep -F 'return FF(' | head -1)
  [ -n "$line" ] || die "no '$sigil' line containing 'return FF(' in $(basename "$M5_PATCH_FILE")"
  # "<sigil>    return FF(<expr>);"  ->  "<expr>"
  line="${line#*return FF\(}"
  line="${line%);}"
  printf '%s\n' "$line"
}

# ---------------------------------------------------------------------------
# m5_prepare_trees
#
# Idempotently materialises $M5_WORK/{base,patched,decoy}.
# ---------------------------------------------------------------------------
m5_prepare_trees() {
  command -v git >/dev/null 2>&1 || die "git is required"
  command -v nix >/dev/null 2>&1 || die "nix is required (the builds run in the fork's dev shell)"
  [ -e "$FORK_ROOT/.git" ] || die "no aztec-packages checkout at $FORK_ROOT"
  [ -f "$M5_PATCH_FILE" ] || die "the prepared patch is missing: $M5_PATCH_FILE"

  git -C "$FORK_ROOT" rev-parse --verify --quiet "$M5_BASE_REV^{commit}" >/dev/null \
    || die "base commit $M5_BASE_REV is not in $FORK_ROOT"

  mkdir -p "$M5_WORK"

  local t
  for t in base patched decoy; do
    if [ ! -e "$M5_WORK/$t/.git" ]; then
      git -C "$FORK_ROOT" worktree add --detach "$M5_WORK/$t" "$M5_BASE_REV" >/dev/null 2>&1 \
        || die "could not create the $t worktree at $M5_WORK/$t"
    fi
  done

  [ "$(git -C "$M5_WORK/base" rev-parse HEAD)" = "$(git -C "$FORK_ROOT" rev-parse "$M5_BASE_REV")" ] \
    || die "$M5_WORK/base is not at $M5_BASE_REV — remove it and re-run"

  # A worktree left over from an EARLIER version of the patch file would silently
  # be measured instead of the current one — including its commit message, which
  # is the artefact upstream reads. The patch's own hash decides whether the tree
  # is current.
  local want_sha have_sha
  want_sha="$(sha256sum "$M5_PATCH_FILE" | awk '{print $1}')"
  have_sha="$(cat "$M5_WORK/patched-patch.sha" 2>/dev/null || true)"
  if [ "$want_sha" != "$have_sha" ]; then
    git -C "$M5_WORK/patched" am --abort >/dev/null 2>&1 || true
    git -C "$M5_WORK/patched" reset --hard "$M5_BASE_REV" >/dev/null 2>&1 \
      || die "could not reset $M5_WORK/patched to $M5_BASE_REV"
  fi

  if [ "$(git -C "$M5_WORK/patched" rev-parse HEAD)" = "$(git -C "$FORK_ROOT" rev-parse "$M5_BASE_REV")" ]; then
    # -3 is deliberately NOT passed: the patch must apply to this base exactly.
    if ! git -C "$M5_WORK/patched" am "$M5_PATCH_FILE" >"$M5_WORK/am.log" 2>&1; then
      git -C "$M5_WORK/patched" am --abort >/dev/null 2>&1 || true
      die "git am of $(basename "$M5_PATCH_FILE") failed on $M5_BASE_REV — see $M5_WORK/am.log"
    fi
  fi
  [ "$(git -C "$M5_WORK/patched" rev-parse HEAD^)" = "$(git -C "$FORK_ROOT" rev-parse "$M5_BASE_REV")" ] \
    || die "$M5_WORK/patched is not $M5_BASE_REV + one patch — remove it and re-run"
  printf '%s\n' "$want_sha" >"$M5_WORK/patched-patch.sha"

  # The decoy: the widening IS applied, but with the wrong shift count. Built from
  # the patch's own `+` line so it is the reviewed change with one character
  # changed, not a separately-written expression.
  local plus decoy_expr
  plus="$(m5_patch_expr plus)"
  decoy_expr="${plus/<< 32/<< 31}"
  [ "$decoy_expr" != "$plus" ] || die "could not derive the decoy: no '<< 32' in the patch's + line"
  if ! grep -qF "$decoy_expr" "$M5_WORK/decoy/$M5_TU_REL" 2>/dev/null; then
    git -C "$M5_WORK/decoy" checkout -- "$M5_TU_REL" 2>/dev/null || true
    M5_OLD="$(m5_patch_expr minus)" M5_NEW="$decoy_expr" \
      python3 - "$M5_WORK/decoy/$M5_TU_REL" <<'PY' || die "could not write the decoy source"
import os, sys
path = sys.argv[1]
old, new = os.environ["M5_OLD"], os.environ["M5_NEW"]
text = open(path).read()
assert text.count(old) == 1, f"expected exactly one occurrence of the upstream expression in {path}"
open(path, "w").write(text.replace(old, new))
PY
  fi
}

# ---------------------------------------------------------------------------
# m5_native_configure <tree>
# m5_native_build <tree> <target...>
#
# Both return the tool's exit status; callers assert on it SEPARATELY from
# anything they parse out of the result, because a count read off a stale binary
# is the failure mode this campaign's M2 review found.
# ---------------------------------------------------------------------------
m5_native_configure() {
  local tree="$1"
  [ -x "$M5_NATIVE_CONFIGURE" ] || die "missing $M5_NATIVE_CONFIGURE"
  [ -f "$tree/barretenberg/cpp/build/compile_commands.json" ] && return 0
  m5_in_devshell '"$1" "$2"' "$M5_NATIVE_CONFIGURE" "$tree" \
    >"$tree/m5-native-configure.log" 2>&1
}

m5_native_build() {
  local tree="$1"; shift
  m5_in_devshell 'cd "$1/barretenberg/cpp/build" && shift && ninja "$@"' "$tree" "$@" \
    >"$tree/m5-native-build.log" 2>&1
}

# ---------------------------------------------------------------------------
# m5_tu_cmd <tree> [options...]  ->  a compile command, on stdout
#
# Every compile in the M5 set is barretenberg's OWN command line for
# `vm2/simulation/lib/contract_crypto.cpp`, re-pointed. See
# wasm_host/_tu_command.py for the options and for why each edit is made. Two
# consequences worth stating: the probes use the same headers, macros and standard
# level as the real translation unit by construction rather than by assertion, and
# the compiler is the absolute store path the configure pinned, so these commands
# do not need a dev shell to run.
# ---------------------------------------------------------------------------
M5_TU_CMD_HELPER="$VERIFY_DIR/wasm_host/_tu_command.py"

m5_tu_cmd() {
  [ -x "$M5_TU_CMD_HELPER" ] || die "missing $M5_TU_CMD_HELPER"
  python3 "$M5_TU_CMD_HELPER" "$@"
}

# m5_tu_command <tree>: the recorded command, verbatim and unedited.
m5_tu_command() { m5_tu_cmd "$1"; }

# ---------------------------------------------------------------------------
# m5_measure <key> <value>   append to the measurement record
# m5_measured <key>          read it back, dying if it is not there
# ---------------------------------------------------------------------------
m5_measure() {
  mkdir -p "$M5_WORK"
  printf '%s=%s\n' "$1" "$2" >>"$M5_MEASURED"
}

m5_measured() {
  [ -f "$M5_MEASURED" ] \
    || die "no measurement record at $M5_MEASURED — run test_bytecode_commitment_identical_on_64bit and test_bytecode_commitment_correct_on_32bit first"
  local v
  v=$(grep -E "^$1=" "$M5_MEASURED" | tail -1)
  [ -n "$v" ] || die "no measurement '$1' in $M5_MEASURED — re-run the checks that write it"
  printf '%s\n' "${v#*=}"
}
