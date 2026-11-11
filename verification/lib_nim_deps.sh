#!/usr/bin/env bash
# lib_nim_deps.sh -- the Nim packages a codetracer-trace-format-nim revision imports, supplied
# rather than found. Sourced by `build_ct_print.sh` and `build_ct_writer_wasm.sh`; needs
# `lib_toolchain.sh` sourced first (for $TC_GCROOTS) and the caller's `die`.
#
# THE DEFECT THIS EXISTS FOR, MEASURED ON A CLEAN HOME 2026-11-11. The writer repository's sources
# import `results` and `stew` (its `.nimble` requires them, and `stew` needs `unittest2`). Nothing in
# an archived tree carries them. On a developer's machine nim finds them anyway, in
# `~/.nimble/pkgs2`, which it searches without being asked; a fresh CI runner has no such directory,
# so every compile died with
#
#     Error: cannot open file: results
#
# -- a message that reads as a broken checkout -- and the only record of it was a log inside a cache
# directory that no job uploads. That is an AMBIENT DEPENDENCY, the one `ct-writer/build.rs`
# documents as `CT_NIM_EXTRA_PATHS`, and the writer repository's own flake names the fix
# (`nimDepPaths`).
#
# The sources come from the `flake.lock` OF THE REVISION BEING BUILT, so each revision is built
# against the dependency revisions its own authors pinned (the reader and its control are different
# commits and may legitimately differ) and this repository holds no second copy of a sha. Each is
# fetched with `nix flake prefetch` and its `narHash` in the reference, so a fetch returning other
# bytes is refused, and rooted under $TC_GCROOTS like every other store path a built binary depends
# on (lib_toolchain.sh item 3).

# nim_deps_resolve <flake.lock>
#
# Sets the global array NIM_DEP_DIRS (store paths, in lock order). A global rather than printed
# output because a `die` inside `$( ... )` kills only the subshell (lib_m24_ct_writer.sh).
NIM_DEP_DIRS=()
nim_deps_resolve() {
  local lock="$1" lines owner repo drev nar json sp err
  [ -f "$lock" ] || die "$lock does not exist, so the revision's Nim dependencies are not pinned"
  lines="$(python3 "$(dirname "${BASH_SOURCE[0]}")/_ct_print_nim_deps.py" "$lock")" \
    || die "$lock does not pin nim-stew, nim-results and nim-unittest2"
  NIM_DEP_DIRS=()
  mkdir -p "$TC_GCROOTS" || die "could not create $TC_GCROOTS"
  err="$(mktemp)" || die "could not create a temporary file"
  while read -r owner repo drev nar; do
    [ -n "$repo" ] || continue
    json="$(nix flake prefetch --json "github:$owner/$repo/$drev?narHash=$nar" 2>"$err")" \
      || die "could not fetch $owner/$repo @ ${drev:0:10} (pinned by $lock):
$(cat "$err")"
    sp="$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["storePath"])')" \
      && [ -d "$sp" ] || die "nix flake prefetch of $owner/$repo gave no store path: $json"
    nix build --out-link "$TC_GCROOTS/nimdep-$repo-${drev:0:12}" "$sp" >/dev/null 2>"$err" \
      || die "could not root $sp:
$(cat "$err")"
    NIM_DEP_DIRS+=("$sp")
  done <<<"$lines"
  rm -f "$err"
  [ "${#NIM_DEP_DIRS[@]}" -ge 2 ] || die "no Nim dependency paths resolved from $lock"
}
