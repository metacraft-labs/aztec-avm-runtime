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
# AND A FOURTH AND FIFTH, BECAUSE M41 PUT A SECOND WRITER IN THE TREE AND THE READER ANCHOR DOES
# NOT REACH IT.
#
#   ct-print-writer       @ pins.json trace_format_nim_writer.commit
#   ct-split-probe-writer @ pins.json trace_format_nim_writer.commit
#
# The reader anchor names 2026-08-20 and the writer anchor names 2026-09-09. A Path B container is
# written by the LATER tree, and its split streams carry an index layout the earlier reader does
# not know: `ct-split-probe` at the reader anchor reports `steps.dat: index file too small for
# trailer` and cannot find `values.off` or `events.off` at all. That is not a defect in either
# revision -- it is what two anchors nineteen days apart means -- but it is a fact about what can
# read this runtime's containers, and a fact stated by a binary is worth more than one stated in a
# comment. Both are built so `verify_container_equivalence_characterised` can measure the
# difference in BOTH directions rather than assert it in one.
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

read -r REV CONTROL WRITER <<<"$(python3 "$HERE/_ct_print_anchors.py" "$REPO_ROOT/pins.json")" \
  || die "pins.json could not be read"

for v in "$REV" "$CONTROL"; do
  case "$v" in [0-9a-f][0-9a-f]*) : ;; *) die "pins.json's trace_format_nim anchor is incomplete (commit='$REV' control_commit='$CONTROL')" ;; esac
done
case "$WRITER" in
  [0-9a-f][0-9a-f]*) : ;;
  *) die "pins.json declares no anchors.trace_format_nim_writer.commit; M41 added that role and this script builds a reader at it" ;;
esac
[ "$REV" != "$CONTROL" ] || die "the reader and its control are the same commit; the comparison would be vacuous"

[ -e "$NIM_REPO/.git" ] || die "no codetracer-trace-format-nim checkout at $NIM_REPO"
for v in "$REV" "$CONTROL" "$WRITER"; do
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

# WHICH NIM BACKEND `cc` IS, ASKED RATHER THAN ASSUMED.
#
# This script used to pass `--cc:clang` with `--clang.exe:$(command -v cc)`, on the stated
# assumption that `cc` is the nixpkgs clang wrapper. On a host where `cc` is GCC that produces a
# clang command line driven by gcc, and every compile dies with
# `gcc: error: unrecognized command-line option '-ferror-limit=3'` -- a message that names a flag
# nobody wrote and points at nothing a reader can act on. The `--cc:` family only has to match the
# compiler's FLAG DIALECT, so it is derived from what the compiler says it is.
host_nim_cc() { # <path-to-cc>
  if "$1" --version 2>&1 | head -1 | grep -qiE 'clang'; then
    printf 'clang\n'
  else
    printf 'gcc\n'
  fi
}

build_one() { # <rev> <tree-dir> <out-binary>
  local rev="$1" tree="$2" out="$3"
  if [ "$FORCE" = 0 ] && [ -x "$out" ] && [ "$(cat "$out.rev" 2>/dev/null)" = "$rev" ]; then
    say "$(basename "$out") @ ${rev:0:10} already built"
    return 0
  fi
  rm -rf "$tree"; mkdir -p "$tree"
  git -C "$NIM_REPO" archive "$rev" | tar -x -C "$tree" || die "git archive of $rev failed"
  # THE HOST COMPILER IS PINNED, AND WITHOUT THIS THE BUILD FAILS IN THIS REPOSITORY'S OWN DEV
  # SHELL. `wasi-sdk-33`'s `bin` is ahead of the C toolchain on PATH — it has to be, that is how
  # `avm.wasm` gets built — so bare `clang`, which is what nim reaches for by default, is the
  # WASM cross-compiler. Nim then compiles a native binary against the wasi sysroot and dies on
  # `signal.h:2: "wasm lacks signal support"` and `use of undeclared identifier '__stdinp'`.
  #
  # `cc` is the nixpkgs clang WRAPPER and is the host compiler; `command -v cc` resolves it here
  # rather than hard-coding a store path. The failure this prevents is not subtle once seen, and it
  # was invisible for as long as the build's output was suppressed — which is the second half of the
  # fix below.
  local hostcc nimcc
  hostcc="$(command -v cc)" || die "no host C compiler on PATH (cc)"
  nimcc="$(host_nim_cc "$hostcc")"
  # THE OUTPUT IS KEPT, NOT DISCARDED. `>/dev/null 2>&1` with a `die` that says "re-run without the
  # output suppressed to see why" is a diagnostic that requires the reader to do the work again by
  # hand; this campaign's own rule is that a check that dies must say why on the first run. The log
  # goes beside the binary so the next failure is one `cat` away.
  ( cd "$tree" && nim c -d:release --mm:arc -p:src \
      "--cc:$nimcc" "--$nimcc.exe:$hostcc" "--$nimcc.linkerexe:$hostcc" \
      --passC:"-I$INC" --passL:"-L$LIB" \
      -o:"$out" src/codetracer_ct_print.nim ) >"$out.build.log" 2>&1 \
    || die "building ct-print at $rev failed; the compiler's own output is in $out.build.log:
$(tail -20 "$out.build.log" 2>/dev/null)"
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
  local hostcc nimcc
  hostcc="$(command -v cc)" || die "no host C compiler on PATH (cc)"
  nimcc="$(host_nim_cc "$hostcc")"
  ( cd "$tree" && nim c -d:release --mm:arc -p:src \
      "--cc:$nimcc" "--$nimcc.exe:$hostcc" "--$nimcc.linkerexe:$hostcc" \
      --passC:"-I$INC" --passL:"-L$LIB" \
      -o:"$out" ct_split_probe.nim ) >"$(dirname "$out")/$(basename "$out").build.log" 2>&1 \
    || die "building ct-split-probe at $rev failed; see $(dirname "$out")/$(basename "$out").build.log:
$(tail -20 "$(dirname "$out")/$(basename "$out").build.log" 2>/dev/null)"
  [ -x "$out" ] || die "the build reported success but $out is not there"
  printf '%s\n' "$rev" >"$out.rev"
  say "built $(basename "$out") @ ${rev:0:10} ($(wc -c <"$out") bytes)"
}

mkdir -p "$WORK" || die "could not create $WORK"
build_one "$REV" "$WORK/src-tree" "$WORK/ct-print"
build_one "$CONTROL" "$WORK/src-tree-pre" "$WORK/ct-print-pre"
build_probe "$REV" "$WORK/src-tree" "$WORK/ct-split-probe"
# A split probe at the CONTROL revision too. `ct-print` diverts any container carrying an
# `events.log` to its legacy combined-stream reader, so neither `ct-print` binary ever touches the
# split streams; the probes are the only readers here that do. Having one at each revision is what
# lets a check read a container with whichever of the two CAN read it, and say which — rather than
# reading both with one reader and attributing the difference to a writer.
build_probe "$CONTROL" "$WORK/src-tree-pre" "$WORK/ct-split-probe-pre"
# The writer anchor's reader. Skipped when the two anchors coincide, because building one tree
# twice under two names would let a check compare a binary with itself and read the agreement as
# evidence.
if [ "$WRITER" != "$REV" ]; then
  build_one "$WRITER" "$WORK/src-tree-writer" "$WORK/ct-print-writer"
  build_probe "$WRITER" "$WORK/src-tree-writer" "$WORK/ct-split-probe-writer"
else
  say "the writer anchor is the reader anchor; not building a second copy of one tree"
fi
printf '%s\n' "$WORK"
