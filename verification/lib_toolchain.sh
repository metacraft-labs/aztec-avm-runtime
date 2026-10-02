#!/usr/bin/env bash
# lib_toolchain.sh — the Rust toolchain and the nix packages the build scripts run under, PINNED
# and ROOTED.
#
# Not to be executed directly: sourced by the `build_*.sh` scripts and the checks that run cargo.
# Every function here REPORTS on stderr and RETURNS non-zero rather than exiting, because several
# are called inside `$( … )`; the caller turns a refusal into its own `die`.
#
# ---------------------------------------------------------------------------
# THREE THINGS THIS FILE EXISTS TO STOP, EACH OF WHICH HAPPENED.
#
# 1. `nix shell nixpkgs#rustup` RESOLVES THROUGH THE INVOKING USER'S FLAKE REGISTRY, not through
#    this repository's `flake.lock`. Measured on the host that met it: the registry answered
#    `rustup-1.29.1` and the lock answers `rustup-1.29.0`, and `capnproto` and `zstd` differ the
#    same way. Every package here is resolved with `--inputs-from "$REPO_ROOT"`, the pattern
#    `ct-writer/build.rs` already used, so the answer is the lock's and nobody else's.
#
# 2. `rustup toolchain install stable` FLOATS. `stable` moved from 1.98.1 to 1.99.0 on its own and
#    the shipped `ct-writer` module went from 743,420 to 744,237 bytes, which broke every document
#    figure re-derived from it. The version is `pins.json`'s `toolchain.rust.version`, installed by
#    that exact name, and `rustc --version` is REQUIRED to say it. Crates that carry their own
#    `rust-toolchain.toml` (the Noir trees, avm-transpiler) are held to THAT file's channel instead —
#    forcing the pin on them would silently change which compiler built those artefacts — and are
#    held to it the same way.
#
# 3. RUSTUP FROM NIXPKGS PATCHELFS EVERY TOOLCHAIN IT DOWNLOADS to a nix-store glibc (the
#    interpreter) and zlib (the rpath). Nothing roots those paths, so a host `nix store gc` deleted
#    them and every binary in the toolchain died with `required file not found` or
#    `libz.so.1: cannot open shared object file` — including `rust-lld`, which a HOST link reaches
#    through `gcc-ld/ld.lld`, so the visible symptom was `clang: error: unable to execute command`
#    four layers away. Here every package is built with an `--out-link` under `$TC_GCROOTS`, which
#    makes it an indirect GC root (`/nix/var/nix/gcroots/auto`); every store path a toolchain's ELF
#    files name as interpreter or RUNPATH is rooted the same way; and a toolchain that names a path
#    which is ALREADY gone is removed and reinstalled rather than used.
# ---------------------------------------------------------------------------

TC_REPO_ROOT="${TC_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TC_GCROOTS="${AZTEC_GCROOTS:-$HOME/.cache/aztec-gcroots}"
TC_HOST_TRIPLE="x86_64-unknown-linux-gnu"

_tc_err() { printf 'lib_toolchain: %s\n' "$*" >&2; }

# tc_pinned_rust — pins.json's `toolchain.rust.version`. The only place the version is declared.
tc_pinned_rust() {
  local v
  v="$(python3 - "$TC_REPO_ROOT/pins.json" <<'PY'
import json, sys
p = json.load(open(sys.argv[1], encoding="utf-8"))
print(p.get("toolchain", {}).get("rust", {}).get("version", ""))
PY
)" || { _tc_err "pins.json could not be read"; return 1; }
  case "$v" in
    [0-9]*.[0-9]*.[0-9]*) printf '%s\n' "$v" ;;
    *) _tc_err "pins.json declares no toolchain.rust.version (got '$v')"; return 1 ;;
  esac
}

# tc_toolchain_file_channel <dir> — the `channel` of the nearest rust-toolchain(.toml) at or above
# <dir>, which is what rustup itself would select there.
tc_toolchain_file_channel() {
  local d f ch
  d="$(cd "$1" 2>/dev/null && pwd)" || { _tc_err "no directory $1"; return 1; }
  while :; do
    for f in "$d/rust-toolchain.toml" "$d/rust-toolchain"; do
      if [ -f "$f" ]; then
        ch="$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
        [ -n "$ch" ] || ch="$(grep -v '^\[' "$f" | head -1 | tr -d '[:space:]')"
        [ -n "$ch" ] || { _tc_err "$f names no channel"; return 1; }
        printf '%s\n' "$ch"
        return 0
      fi
    done
    [ "$d" = / ] && break
    d="$(dirname "$d")"
  done
  _tc_err "no rust-toolchain file at or above $1"
  return 1
}

# tc_nixpkg <attr> — realise nixpkgs#<attr> from THIS REPOSITORY'S flake.lock, rooted under
# $TC_GCROOTS, and print its store path. `nix build` names the link `<name>-<output>` for a
# non-default output (`zstd.dev` -> `nixpkgs-zstd.dev-dev`); the printed path is authoritative.
tc_nixpkg() {
  local attr="$1" p
  mkdir -p "$TC_GCROOTS" || { _tc_err "could not create $TC_GCROOTS"; return 1; }
  p="$(nix build --inputs-from "$TC_REPO_ROOT" --out-link "$TC_GCROOTS/nixpkgs-$attr" \
        --print-out-paths "nixpkgs#$attr" 2>/dev/null | head -1)"
  [ -n "$p" ] && [ -e "$p" ] || {
    _tc_err "nixpkgs#$attr did not resolve through $TC_REPO_ROOT/flake.lock"; return 1; }
  printf '%s\n' "$p"
}

# tc_path <attr>... — a PATH prefix carrying each package's bin/, every package rooted.
tc_path() {
  local attr p out=""
  for attr in "$@"; do
    p="$(tc_nixpkg "$attr")" || return 1
    out="${out:+$out:}$p/bin"
  done
  printf '%s\n' "$out"
}

# _tc_patchelf — the rooted patchelf, resolved once per shell. Call `_tc_patchelf >/dev/null` outside
# a command substitution first and every later call is free.
_TC_PATCHELF=""
_tc_patchelf() {
  if [ -z "$_TC_PATCHELF" ] || [ ! -x "$_TC_PATCHELF" ]; then
    _TC_PATCHELF="$(tc_nixpkg patchelf)/bin/patchelf" || return 1
  fi
  printf '%s\n' "$_TC_PATCHELF"
}

# tc_elf_files <dir>... — the ELF files under the given directories.
tc_elf_files() {
  local f
  find "$@" -type f 2>/dev/null | while IFS= read -r f; do
    [ "$(head -c4 "$f" 2>/dev/null | od -An -c | tr -d ' ')" = '177ELF' ] && printf '%s\n' "$f"
  done
}

# tc_elf_store_refs <file>... — every /nix/store path the files name as INTERPRETER or RUNPATH,
# reduced to the top-level store path, one per line, sorted.
tc_elf_store_refs() {
  local pe f
  pe="$(_tc_patchelf)" || return 1
  for f in "$@"; do
    "$pe" --print-interpreter "$f" 2>/dev/null
    "$pe" --print-rpath "$f" 2>/dev/null | tr ':' '\n'
  done | grep -oE '^/nix/store/[a-z0-9]{32}-[^/]+' | LC_ALL=C sort -u
}

# tc_elf_store_refs_present <file> — 0 when every /nix/store path the file names as interpreter or
# RUNPATH still exists. That is exactly what a garbage collection takes away, and it is asked of
# EVERY file, including ones (like `rust-objcopy` without `llvm-tools`) that cannot load anyway.
tc_elf_store_refs_present() {
  local f="$1" pe interp r
  pe="$(_tc_patchelf)" || return 1
  interp="$("$pe" --print-interpreter "$f" 2>/dev/null)" || interp=""
  case "$interp" in
    /nix/store/*) [ -e "$interp" ] || { _tc_err "$f: interpreter $interp is gone"; return 1; } ;;
  esac
  for r in $("$pe" --print-rpath "$f" 2>/dev/null | tr ':' ' '); do
    case "$r" in
      /nix/store/*) [ -d "$r" ] || { _tc_err "$f: RUNPATH entry $r is gone"; return 1; } ;;
    esac
  done
  return 0
}

# tc_elf_loadable <file> — 0 when the file's store references are present AND its own loader
# resolves every library it needs. A missing interpreter is the `required file not found` shape; a
# missing library is the `libz.so.1` shape. Asked of the file's OWN interpreter, not the host `ldd`.
tc_elf_loadable() {
  local f="$1" pe interp listing
  tc_elf_store_refs_present "$f" || return 1
  pe="$(_tc_patchelf)" || return 1
  interp="$("$pe" --print-interpreter "$f" 2>/dev/null)" || interp=""
  if [ -n "$interp" ]; then
    listing="$("$interp" --list "$f" 2>&1)" || {
      _tc_err "$f: $(printf '%s\n' "$listing" | tail -1)"; return 1; }
  else
    listing="$(ldd "$f" 2>&1)" || true
  fi
  # A `case`, not `printf | grep -q`: under pipefail that pipeline's status is printf's SIGPIPE
  # rather than grep's verdict once the listing outgrows the pipe buffer (lib.sh, "STRING
  # PREDICATES THAT ARE NOT PIPELINES"; verify_no_pipeline_predicates refuses the spelling).
  case "$listing" in
    *'not found'*)
      _tc_err "$f: $(printf '%s\n' "$listing" | grep 'not found' | head -1 | sed 's/^[[:space:]]*//')"
      return 1 ;;
  esac
  return 0
}

# tc_root_store_paths <prefix> <store-path>... — root each path as $TC_GCROOTS/<prefix>--<base>,
# and drop any older `<prefix>--*` link the current set no longer names.
tc_root_store_paths() {
  local prefix="$1" p keep="" l
  shift
  mkdir -p "$TC_GCROOTS" || return 1
  for p in "$@"; do
    [ -e "$p" ] || { _tc_err "cannot root $p: it is not in the store"; return 1; }
    nix-store --add-root "$TC_GCROOTS/$prefix--$(basename "$p")" --realise "$p" >/dev/null 2>&1 \
      || { _tc_err "nix-store --add-root failed for $p"; return 1; }
    keep="$keep $prefix--$(basename "$p")"
  done
  for l in "$TC_GCROOTS/$prefix--"*; do
    [ -L "$l" ] || continue
    case " $keep " in *" $(basename "$l") "*) : ;; *) rm -f "$l" ;; esac
  done
}

# tc_root_elf_refs <prefix> <file>... — root everything the files load from.
tc_root_elf_refs() {
  local prefix="$1" refs
  shift
  refs="$(tc_elf_store_refs "$@")" || return 1
  # shellcheck disable=SC2086
  tc_root_store_paths "$prefix" $refs
}

# tc_rust_toolchain_dir <ver> — where rustup keeps <ver> under $RUSTUP_HOME.
tc_rust_toolchain_dir() { printf '%s\n' "$RUSTUP_HOME/toolchains/$1-$TC_HOST_TRIPLE"; }

# _tc_rust_elves <toolchain-dir> — the toolchain's own executables and shared objects: bin/,
# libexec/, lib/*.so*, and the host target's lib/rustlib/<host>/bin (rust-lld and gcc-ld/*, which a
# host link reaches through `-fuse-ld=lld`).
_tc_rust_elves() {
  local dir="$1"
  tc_elf_files "$dir/bin" "$dir/libexec" "$dir/lib/rustlib/$TC_HOST_TRIPLE/bin"
  find "$dir/lib" -maxdepth 1 -type f -name '*.so*' 2>/dev/null
}

# _tc_rust_healthy <ver> — every ELF in the toolchain loads, and rustc says <ver>.
_tc_rust_healthy() {
  local ver="$1" dir f got elves
  dir="$(tc_rust_toolchain_dir "$ver")"
  [ -x "$dir/bin/rustc" ] || { _tc_err "$dir has no bin/rustc"; return 1; }
  elves="$(_tc_rust_elves "$dir")"
  [ "$(printf '%s\n' "$elves" | grep -c .)" -ge 3 ] || { _tc_err "$dir: too few ELF files ($elves)"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    tc_elf_store_refs_present "$f" || return 1
  done <<EOF
$elves
EOF
  # And the ones a build actually executes must LOAD: the compiler, cargo, and the linker a host
  # link reaches through `-fuse-ld=lld` (`gcc-ld/ld.lld` is a wrapper that execs `rust-lld`).
  for f in "$dir/bin/rustc" "$dir/bin/cargo" "$dir/lib/rustlib/$TC_HOST_TRIPLE/bin/rust-lld" \
           "$dir/lib/rustlib/$TC_HOST_TRIPLE/bin/gcc-ld/ld.lld"; do
    [ -e "$f" ] || continue
    tc_elf_loadable "$f" || return 1
  done
  got="$("$dir/bin/rustc" --version 2>/dev/null)" || { _tc_err "$dir/bin/rustc does not run"; return 1; }
  case "$got" in
    "rustc $ver "*) return 0 ;;
    *) _tc_err "$dir/bin/rustc says [$got], not $ver"; return 1 ;;
  esac
}

# tc_rust_ensure <ver> [<crate-dir>] — install exactly <ver> into $RUSTUP_HOME with the ROOTED
# rustup, with the wasm32 target; repair a toolchain whose store references are gone by removing
# and reinstalling it; root what it loads from; and REFUSE unless `rustc --version` says <ver>.
# With <crate-dir>, the crate's rust-toolchain file must name <ver> as well, and its components
# are installed too (rustup installs the file's toolchain when asked with no argument).
#
# Prints the PATH prefix to run cargo under (rustup's proxies and capnp).
tc_rust_ensure() {
  local ver="$1" crate="${2:-}" tcpath dir ch
  [ -n "${RUSTUP_HOME:-}" ] || { _tc_err "RUSTUP_HOME is not set"; return 1; }
  [ -n "${CARGO_HOME:-}" ] || { _tc_err "CARGO_HOME is not set"; return 1; }
  if [ -n "$crate" ]; then
    ch="$(tc_toolchain_file_channel "$crate")" || return 1
    [ "$ch" = "$ver" ] || { _tc_err "$crate's rust-toolchain names $ch, the caller asked for $ver"; return 1; }
  fi
  tcpath="$(tc_path rustup capnproto)" || return 1
  _tc_patchelf >/dev/null || return 1
  dir="$(tc_rust_toolchain_dir "$ver")"
  if [ -d "$dir" ] && ! _tc_rust_healthy "$ver"; then
    _tc_err "toolchain $ver at $dir references store paths that are gone; removing and reinstalling it"
    rm -rf "$dir" "$RUSTUP_HOME/update-hashes/$ver-$TC_HOST_TRIPLE" \
      || { _tc_err "could not remove $dir"; return 1; }
  fi
  (
    export PATH="$tcpath:$PATH"
    rustup -q toolchain install "$ver" --profile minimal >/dev/null 2>&1 || exit 1
    if [ -n "$crate" ]; then
      cd "$crate" && env -u RUSTUP_TOOLCHAIN rustup -q toolchain install >/dev/null 2>&1 || exit 1
    fi
    rustup -q target add --toolchain "$ver" wasm32-unknown-unknown >/dev/null 2>&1 || exit 1
  ) || { _tc_err "rustup could not install toolchain $ver"; return 1; }
  _tc_rust_healthy "$ver" || { _tc_err "toolchain $ver is not usable after installing it"; return 1; }
  # shellcheck disable=SC2046
  tc_root_elf_refs "rust-$ver-$(printf '%s' "$RUSTUP_HOME" | sha256sum | cut -c1-8)" $(_tc_rust_elves "$dir") \
    || { _tc_err "could not root the store paths toolchain $ver loads from"; return 1; }
  # And through the proxy, which is the path cargo itself takes.
  local got
  got="$(PATH="$tcpath:$PATH" RUSTUP_TOOLCHAIN="$ver" rustc --version 2>/dev/null)"
  case "$got" in
    "rustc $ver "*) : ;;
    *) _tc_err "RUSTUP_TOOLCHAIN=$ver rustc --version says [$got]"; return 1 ;;
  esac
  printf '%s\n' "$tcpath"
}
