#!/usr/bin/env bash
# verify_wasi_shim_reuse_decision_recorded — M17.
#
# WHETHER bb.js's EXISTING WASI SHIM WAS REUSED OR A NEW ONE WRITTEN IS RECORDED WITH THE REASON —
# AND THE REASON IS RE-DERIVED HERE RATHER THAN READ BACK.
#
# A check that only asserted "NODE-HOST.md contains the word reuse" would be satisfied by a
# paragraph somebody wrote from memory, which is exactly the failure this campaign has had seven
# times. So the enumeration is RUN on every invocation, over the fork at the pinned anchor and over
# the published `@aztec/*` packages, and the document is required to agree with what it finds on
# both sides.
#
# THE ENUMERATION IS OVER THE WHOLE FORK, BY SUBDIRECTORY. Every one of this campaign's reuse misses
# was a directory PARALLEL to the one being searched, so the question asked is not "what is in
# barretenberg/ts/bb.js/" but "which files in the whole tree build a WebAssembly import object or
# instantiate a module". That question finds two candidates a walk of bb.js would not have:
# `barretenberg/cpp/scripts/run_wasm_bench_node.mjs`, which is UPSTREAM'S OWN node:wasi host for a
# --import-memory module and is the precedent this loader follows, and
# `yarn-project/sqlite3mc-wasm/`, whose vendored Emscripten glue covers eight of the eleven.
#
# AND THE ELEVEN ARE READ OUT OF REACTOR-ABI.md, not restated here. The milestone says in as many
# words not to restate M12's list from memory.
#
# Run: just verify-node-reuse

TEST_NAME="verify_wasi_shim_reuse_decision_recorded"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m17_node_host.sh"

[ -d "$FORK_ROOT/.git" ] || die "the fork is not at $FORK_ROOT"
assert_file "the decision is recorded" "$M17_DOC"
DOC="$(cat "$M17_DOC")"

# The pinned anchor, taken from M6's library rather than restated: it is the same commit every
# other milestone reads the fork at, and a second copy of it here could drift from that one.
ANCHOR="${M6_BASE_REV:-}"
[ -n "$ANCHOR" ] || die "the pinned anchor is not defined; lib_avm_wasm.sh should have set M6_BASE_REV"
git -C "$FORK_ROOT" rev-parse --verify --quiet "$ANCHOR^{commit}" >/dev/null \
  || die "the pinned anchor $ANCHOR is not in $FORK_ROOT"
note "enumerating over the fork at $ANCHOR"

# ---------------------------------------------------------------------------
echo "== 1. the eleven, read from the artefact"
# ---------------------------------------------------------------------------
WASI_NAMES="$(m17_reactor_abi_wasi_imports)"
N_WASI="$(printf '%s\n' "$WASI_NAMES" | grep -c .)"
assert_eq "REACTOR-ABI.md's import table lists eleven WASI functions" "11" "$N_WASI"
# The reader is controlled: it must find nothing in a document that has no such table, or "eleven"
# would be a property of the sed expression rather than of the artefact.
assert_eq "the same reader finds no import table in a document that has none" "0" \
  "$(sed -n 's/^| `wasi_snapshot_preview1\.\([a-z_]*\)` |.*/\1/p' "$M17_PKG/package.json" | grep -c .)"
# `random_get` is the one bb.js exists to supply, and REACTOR-ABI.md asserts its ABSENCE by name.
assert_eq "random_get is NOT among them" "0" "$(printf '%s\n' "$WASI_NAMES" | grep -cx random_get)"
assert_true "…and REACTOR-ABI.md says so by name" grep -q 'random_get' "$M17_REACTOR_ABI"

# ---------------------------------------------------------------------------
echo "== 2. the enumeration: every wasm instantiation site in the WHOLE fork, by subdirectory"
# ---------------------------------------------------------------------------
SITES="$M17_WORK/reuse-sites.txt"
mkdir -p "$M17_WORK"
git -C "$FORK_ROOT" grep -lE 'WebAssembly\.(instantiate|Module|compile|Memory)|getImportObject|importObject|instantiateStreaming' \
  "$ANCHOR" -- '*.ts' '*.js' '*.mjs' '*.cjs' 2>/dev/null | sed "s|^$ANCHOR:||" | LC_ALL=C sort >"$SITES"
N_SITES="$(grep -c . "$SITES" || true)"
N_DIRS="$(sed 's|/[^/]*$||' "$SITES" | LC_ALL=C sort -u | grep -c . || true)"
note "$N_SITES file(s) in $N_DIRS director(ies)"
assert_ge "the enumeration found instantiation sites at all" 5 "$N_SITES"
# The two PARALLEL directories a walk of bb.js would have missed, named individually.
assert_true "upstream's own node:wasi host is in the enumeration" \
  grep -qx "$M17_UPSTREAM_NODE_WASI_HOST" "$SITES"
assert_true "…and so is yarn-project/sqlite3mc-wasm, the other parallel candidate" \
  grep -q '^yarn-project/sqlite3mc-wasm/' "$SITES"
assert_true "bb.js's shim is in it too, or the enumeration missed the file the deliverable names" \
  grep -qx "$M17_BBJS_SHIM" "$SITES"
# The enumeration is over more than one directory, which is the whole point of asking it this way.
assert_ge "the sites are spread over several directories" 5 "$N_DIRS"
assert_eq "…and NODE-HOST.md records the same count of directories" \
  "1" "$(printf '%s' "$DOC" | grep -c "Eight files, in eight" || true)"
assert_eq "the enumeration's file count is the one the document records" "8" "$N_SITES"

# ---------------------------------------------------------------------------
echo "== 3. what bb.js's shim actually covers, measured name by name"
# ---------------------------------------------------------------------------
SHIM="$M17_WORK/bbjs-shim.ts"
git -C "$FORK_ROOT" show "$ANCHOR:$M17_BBJS_SHIM" >"$SHIM" 2>/dev/null \
  || die "could not read $M17_BBJS_SHIM out of the fork at $ANCHOR"
assert_ge "the shim was read out of the fork and is not empty" 50 "$(grep -c . "$SHIM")"

COVERED=""
MISSED=""
for n in $WASI_NAMES; do
  if grep -qE "(^|[^a-z_])$n[[:space:]]*:" "$SHIM"; then COVERED="$COVERED $n"; else MISSED="$MISSED $n"; fi
done
COVERED="$(printf '%s' "$COVERED" | tr ' ' '\n' | grep -c . || true)"
MISSED_N="$(printf '%s' "$MISSED" | tr ' ' '\n' | grep -c . || true)"
note "bb.js's shim covers $COVERED of the eleven and misses $MISSED_N"
assert_eq "bb.js's shim covers two of the eleven" "2" "$COVERED"
assert_eq "…and misses nine" "9" "$MISSED_N"
for n in $M17_BBJS_COVERED; do
  assert_true "…and the two it covers are named: $n" grep -qE "(^|[^a-z_])$n[[:space:]]*:" "$SHIM"
done
# And it supplies three imports avm.wasm does not have. That is what makes it the wrong shim rather
# than a partial one: it is a shim for a DIFFERENT module.
for n in $M17_BBJS_EXTRA; do
  assert_true "bb.js's shim supplies $n, which avm.wasm does not import" \
    grep -qE "(^|[^a-z_])$n[[:space:]]*:" "$SHIM"
  assert_eq "…and $n is genuinely absent from avm.wasm's import list" "0" \
    "$(printf '%s\n' "$WASI_NAMES" | grep -cx "$n")"
done
# The shim's own comment says what it is for, and it is not this.
assert_contains "bb.js's shim says in its own comment what it implements" \
  "We literally only need to support random_get" "$(cat "$SHIM")"

# ---------------------------------------------------------------------------
echo "== 4. upstream's own node:wasi precedent, read out of the fork"
# ---------------------------------------------------------------------------
UP="$M17_WORK/upstream-node-wasi.mjs"
git -C "$FORK_ROOT" show "$ANCHOR:$M17_UPSTREAM_NODE_WASI_HOST" >"$UP" 2>/dev/null \
  || die "could not read $M17_UPSTREAM_NODE_WASI_HOST out of the fork at $ANCHOR"
UPTXT="$(cat "$UP")"
assert_contains "upstream drives a WASI barretenberg module from Node with node:wasi" \
  "import { WASI } from 'node:wasi'" "$UPTXT"
assert_contains "…supplying the memory itself, because the module imports it" \
  "imports.env.memory = memory" "$UPTXT"
assert_contains "…and it says the module is built with --import-memory" "--import-memory" "$UPTXT"
# Same shape here, and the shape is what was reused.
LOADER="$(cat "$M17_PKG/src/loader.ts")"
assert_contains "this loader takes its WASI imports from node:wasi" \
  "import { WASI } from 'node:wasi'" "$LOADER"
assert_contains "…and supplies env.memory itself" "env: { memory }" "$LOADER"
# The manifest MENTIONS bb.js, in the comment that records why it is not used; what it must not do
# is DEPEND on it. Asserted on the dependency spelling rather than on the string.
assert_not_contains "…and declares no dependency on bb.js" '"@aztec/bb.js"' "$(cat "$M17_PKG/package.json")"
assert_contains "…while still recording why, in the manifest itself" "bb.js" "$(cat "$M17_PKG/package.json")"
assert_eq "no source in the package imports bb.js or barretenberg_wasm" "0" \
  "$(grep -rl "barretenberg_wasm\|@aztec/bb.js" "$M17_PKG/src" 2>/dev/null | grep -c . || true)"
# The zero above is controlled by the SAME grep over a file that DOES name bb.js, so it is a
# measurement rather than an absence.
assert_ge "the same grep finds bb.js where bb.js is named" 1 \
  "$(grep -rl "barretenberg_wasm\|@aztec/bb.js" "$M17_DOC" 2>/dev/null | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 5. the published @aztec packages"
# ---------------------------------------------------------------------------
NM="$REPO_ROOT/diffsim/node_modules/@aztec"
if [ ! -d "$NM" ]; then
  die "the published @aztec packages are not installed at $NM.
       The reuse enumeration is over them as well as over the fork, and it is a deliverable rather
       than an optional extra. Install them with 'cd diffsim && npm ci' (the lockfile is tracked)
       and re-run."
fi
N_PKGS="$(ls -1 "$NM" | grep -c . || true)"
note "$N_PKGS published @aztec package(s) installed"
assert_ge "enough @aztec packages are installed for the enumeration to mean something" 10 "$N_PKGS"
WITH_WASI="$(grep -rlE 'wasi_snapshot_preview1|node:wasi|proc_exit|fd_prestat_get|environ_sizes_get' \
  "$NM" 2>/dev/null | sed "s|^$NM/||" | cut -d/ -f1 | LC_ALL=C sort -u)"
note "packages mentioning any WASI name: $(printf '%s' "$WITH_WASI" | tr '\n' ' ')"
assert_eq "exactly two published packages mention a WASI name at all" "2" \
  "$(printf '%s\n' "$WITH_WASI" | grep -c .)"
# THESE TWO ASSERTIONS DID NOT EXIST until M21. Written as
# `assert_true "…" printf '%s\n' "$WITH_WASI" | grep -qx 'bb.js'`, the pipe binds to `assert_true`,
# not to `printf`: the helper ran `printf` (which always succeeds), so the assertion could only
# pass, and its own `ok` line went INTO `grep` — so it was not printed either, and the
# `_ASSERTIONS` increment happened in a subshell and was lost. This check reported 48 assertions
# and its transcript went straight from "exactly two published packages mention a WASI name at all"
# to "sqlite3mc-wasm's vendored glue is where its WASI names are". See lib.sh's string predicates.
assert_true "…one of them is bb.js" str_has_line "$WITH_WASI" 'bb.js'
assert_true "…and the other is sqlite3mc-wasm" str_has_line "$WITH_WASI" 'sqlite3mc-wasm'
# sqlite3mc-wasm covers eight of the eleven, which is closer than bb.js and still not it.
SQL="$NM/sqlite3mc-wasm/vendor/jswasm/sqlite3.mjs"
assert_file "sqlite3mc-wasm's vendored glue is where its WASI names are" "$SQL"
SQL_COVERED=0
for n in $WASI_NAMES; do
  if grep -qE "(^|[^a-z_])$n([^a-z_]|$)" "$SQL"; then SQL_COVERED=$((SQL_COVERED + 1)); fi
done
note "sqlite3mc-wasm's vendored Emscripten glue covers $SQL_COVERED of the eleven"
assert_eq "sqlite3mc-wasm covers eight of the eleven" "8" "$SQL_COVERED"
assert_true "…and it is vendored third-party glue rather than an Aztec API" \
  test -d "$NM/sqlite3mc-wasm/vendor"

# ---------------------------------------------------------------------------
echo "== 6. the document records the decision AND the numbers behind it"
# ---------------------------------------------------------------------------
assert_contains "the decision is stated in one line" \
  "Reused: \`node:wasi\`. Not reused: bb.js's shim." "$DOC"
assert_contains "…with bb.js's coverage as measured" "**2 of 11**" "$DOC"
assert_contains "…and node:wasi's" "**11 of 11**" "$DOC"
assert_contains "…and sqlite3mc-wasm's" "8 of 11" "$DOC"
assert_contains "…and the reason bb.js's is the wrong shim rather than a partial one" \
  "random_get" "$DOC"
assert_contains "…and upstream's own precedent, named by path" \
  "run_wasm_bench_node.mjs" "$DOC"
assert_contains "…and what remained ours" "What is ours is one import" "$DOC"
# The document's claim of no dependencies is checked against the package rather than believed.
assert_contains "the document claims the package has no dependencies" "no dependencies at all" "$DOC"
assert_not_contains "…and package.json declares none" '"dependencies"' "$(cat "$M17_PKG/package.json")"
assert_not_contains "…nor devDependencies" '"devDependencies"' "$(cat "$M17_PKG/package.json")"

finish
