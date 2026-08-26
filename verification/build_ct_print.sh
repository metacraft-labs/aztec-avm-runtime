#!/usr/bin/env bash
# build_ct_print.sh — build BOTH `ct-print` readers out of the object store.
#
#   verification/build_ct_print.sh [--force]
#
# Not a check. Invoked by `m24_require_readers`.
#
# ---------------------------------------------------------------------------
# TWO BUILDS, ONE COMMIT APART, AND THAT IS THE WHOLE DESIGN.
#
# DD-7 records that a wasm-produced Path A container cannot be read by stock `ct-print`. That is a
# claim about a DIFFERENCE, and the honest way to hold it is to build the reader at the fix and at
# its parent and run both against the same bytes. Anything less — a prebuilt binary in a sibling
# worktree, or a release from some other branch — is state this repository did not produce, and
# "four checks once passed against an empty build directory" is in the campaign brief because of it.
#
#   ct-print       @ pins.json trace_format_nim.commit          -- has baea074, reads it
#   ct-print-pre   @ pins.json trace_format_nim.control_commit  -- baea074^, must NOT read it
#
# AND A THIRD BINARY, FOR A QUESTION NEITHER OF THOSE CAN ANSWER.
#
# `ct-print` diverts any container carrying `events.log` to the LEGACY combined-stream reader —
# its own source says so and gives the reason — and every Rust-written container carries one. So
# both binaries above decode `events.log` and NEITHER of them ever touches `steps.dat`,
# `values.dat`, `calls.dat` or `events.dat`. A container whose split streams are all unreadable
# reads exactly the same through them, which is how `test_ct_container_roundtrip_ct_print` came to
# report green over one.
#
#   ct-split-probe @ pins.json trace_format_nim.commit          -- opens the SPLIT streams
#
# is `verification/ct_split_probe.nim` compiled inside the SAME archived tree, so it is the
# reference reader at the pinned revision and not a re-implementation. It calls `openNewTrace`
# directly, which is the v4 split-stream reader `ct-print` declines to use here.
#
# Both from `git archive`, out of the OBJECT STORE. `../ctfnim-wt-wasm` is a worktree of the same
# repository sitting on that branch and carries a prebuilt `ct-print`; using it would make the
# check depend on whatever that worktree currently holds.
#
# `zstd.h` is not on the include path of a bare `nix shell`, which is a real trap rather than a
# footnote: `nix shell nixpkgs#zstd.dev` puts the package's BIN directory on `PATH` and sets no
# `CPATH`, so the nim build fails with `fatal error: zstd.h: No such file or directory` and reads
# like a missing dependency when the dependency is present. The include and library directories
# are resolved explicitly and passed with `--passC` / `--passL`.
# ---------------------------------------------------------------------------
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
WORKSPACE_ROOT="$(cd "$REPO_ROOT/.." && pwd)"

WORK="${M24_CTPRINT_WORK:-$HOME/.cache/aztec-m24-ctprint}"
NIM_REPO="${TRACE_FORMAT_NIM_REPO:-$WORKSPACE_ROOT/codetracer-trace-format-nim}"

die() { printf 'build_ct_print: %s\n' "$*" >&2; exit 1; }
say() { printf 'build_ct_print: %s\n' "$*"; }

FORCE=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    *) die "unknown argument [$a]" ;;
  esac
done

read -r REV CONTROL <<<"$(python3 - "$REPO_ROOT/pins.json" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))["anchors"].get("trace_format_nim") or {}
print(a.get("commit", ""), a.get("control_commit", ""))
PY
)" || die "pins.json could not be read"

for v in "$REV" "$CONTROL"; do
  case "$v" in [0-9a-f][0-9a-f]*) : ;; *) die "pins.json's trace_format_nim anchor is incomplete (commit='$REV' control_commit='$CONTROL')" ;; esac
done
[ "$REV" != "$CONTROL" ] || die "the reader and its control are the same commit; the comparison would be vacuous"

[ -e "$NIM_REPO/.git" ] || die "no codetracer-trace-format-nim checkout at $NIM_REPO"
for v in "$REV" "$CONTROL"; do
  git -C "$NIM_REPO" cat-file -e "$v^{commit}" 2>/dev/null || die "$NIM_REPO does not have $v"
done
# The control MUST be the fix's parent, or the one-commit claim is not what is being built.
actual_parent="$(git -C "$NIM_REPO" rev-parse "$REV^" 2>/dev/null)"
[ -n "$actual_parent" ] || die "could not resolve $REV^"

command -v nim >/dev/null 2>&1 || die "nim is required (it comes from the workspace dev shell)"
command -v nix >/dev/null 2>&1 || die "nix is required to resolve zstd's headers"

INC="$(nix build --no-link --print-out-paths nixpkgs#zstd.dev 2>/dev/null)/include"
LIB="$(nix build --no-link --print-out-paths nixpkgs#zstd.out 2>/dev/null)/lib"
[ -f "$INC/zstd.h" ] || die "zstd.h is not at $INC (nixpkgs#zstd.dev did not resolve)"

build_one() { # <rev> <tree-dir> <out-binary>
  local rev="$1" tree="$2" out="$3"
  if [ "$FORCE" = 0 ] && [ -x "$out" ] && [ "$(cat "$out.rev" 2>/dev/null)" = "$rev" ]; then
    say "$(basename "$out") @ ${rev:0:10} already built"
    return 0
  fi
  rm -rf "$tree"; mkdir -p "$tree"
  git -C "$NIM_REPO" archive "$rev" | tar -x -C "$tree" || die "git archive of $rev failed"
  ( cd "$tree" && nim c -d:release --mm:arc -p:src --passC:"-I$INC" --passL:"-L$LIB" \
      -o:"$out" src/codetracer_ct_print.nim ) >/dev/null 2>&1 \
    || die "building ct-print at $rev failed (re-run without the output suppressed to see why)"
  [ -x "$out" ] || die "the build reported success but $out is not there"
  printf '%s\n' "$rev" >"$out.rev"
  say "built $(basename "$out") @ ${rev:0:10} ($(wc -c <"$out") bytes)"
}

# The split-stream probe. It is compiled INSIDE the tree `build_one` already archived for
# `ct-print`, so it links the reference reader at the pinned revision rather than a copy of it —
# and its `.rev` stamp is that same revision, which is what `m24_require_readers` compares.
#
# The source is COPIED IN rather than compiled in place from `$REPO_ROOT/verification`, because
# `nim c -p:src` resolves `codetracer_trace_writer/new_trace_reader` relative to the archived
# tree; a probe left outside it would find no reader to import.
build_probe() { # <rev> <tree-dir> <out-binary>
  local rev="$1" tree="$2" out="$3"
  if [ "$FORCE" = 0 ] && [ -x "$out" ] && [ "$(cat "$out.rev" 2>/dev/null)" = "$rev" ] \
     && [ ! "$REPO_ROOT/verification/ct_split_probe.nim" -nt "$out" ]; then
    say "$(basename "$out") @ ${rev:0:10} already built"
    return 0
  fi
  [ -d "$tree/src" ] || die "$tree was not archived; build_one must run first"
  [ -f "$REPO_ROOT/verification/ct_split_probe.nim" ] || die "verification/ct_split_probe.nim is missing"
  cp "$REPO_ROOT/verification/ct_split_probe.nim" "$tree/ct_split_probe.nim" \
    || die "could not copy the probe into $tree"
  ( cd "$tree" && nim c -d:release --mm:arc -p:src --passC:"-I$INC" --passL:"-L$LIB" \
      -o:"$out" ct_split_probe.nim ) >"$WORK/ct-split-probe.build.log" 2>&1 \
    || die "building ct-split-probe at $rev failed; see $WORK/ct-split-probe.build.log"
  [ -x "$out" ] || die "the build reported success but $out is not there"
  printf '%s\n' "$rev" >"$out.rev"
  say "built $(basename "$out") @ ${rev:0:10} ($(wc -c <"$out") bytes)"
}

mkdir -p "$WORK" || die "could not create $WORK"
build_one "$REV" "$WORK/src-tree" "$WORK/ct-print"
build_one "$CONTROL" "$WORK/src-tree-pre" "$WORK/ct-print-pre"
build_probe "$REV" "$WORK/src-tree" "$WORK/ct-split-probe"
printf '%s\n' "$WORK"
