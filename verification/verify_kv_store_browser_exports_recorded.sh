#!/usr/bin/env bash
# verify_kv_store_browser_exports_recorded — the persistence substrate, as it actually is.
#
# The verification entry: "The available kv-store browser entry points are recorded as they
# actually are at the pinned nightly, including that the IndexedDB export is deprecated, so
# persistence work does not start from the design document's stale list."
#
# THE CORRECTION THIS ENTRY EXISTS TO RECORD IS ITSELF PARTLY WRONG, AND THAT IS THE FINDING. The
# design document said `./indexeddb` and `./sqlite-opfs`; the milestone corrects it to
# `./deprecated/indexeddb` "as of the pinned nightly". Measured, both sentences are true of one
# artefact and false of another:
#
#     npm.current       5.3.0-nightly.20260819   ./deprecated/indexeddb    (drift/)
#     npm.deletion_era  5.0.0-nightly.20260626   ./indexeddb               (spike/, diffsim/, probe-mt/)
#     fork @ cpp anchor 2026-08-19               ./deprecated/indexeddb
#     fork @ ts anchor  2026-06-25               ./indexeddb
#
# and `orchestration/` — the package that would do the persistence work — is on `deletion_era`.
# So the corrected sentence is right about the anchor and about `current`, and wrong about the line
# this package is actually built against, which is the one that decides whether an import resolves.
# This check measures all four and requires `CHAIN-LOOP.md` to record all four, because a
# correction that replaces one artefact-specific claim with another artefact-specific claim has not
# closed the trap, it has moved it.
#
# NOTHING HERE IS READ OUT OF A CACHED LIST. Each `exports` map is parsed from the package.json or
# the blob it belongs to, on every run.
#
# Run: just verify-chain-kv-store

TEST_NAME="verify_kv_store_browser_exports_recorded"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"

m23_summary_on_abnormal_exit
m23_require_anchor

DOC="$(cat "$M23_DOC")"

# The pin values, from the single authority.
PIN_CURRENT="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm"]["current"]["version"])' "$REPO_ROOT/pins.json")"
PIN_DELETION="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm"]["deletion_era"]["version"])' "$REPO_ROOT/pins.json")"
assert_true "pins.json names a current nightly" test -n "$PIN_CURRENT"
assert_true "…and a deletion-era one" test -n "$PIN_DELETION"
assert_true "…and they are different lines" test "$PIN_CURRENT" != "$PIN_DELETION"

# ---------------------------------------------------------------------------
# PART 1 — the INSTALLED packages
# ---------------------------------------------------------------------------
echo "== the installed @aztec/kv-store, at both pinned lines"

read_installed() { # <tree> -> "<version> <subpaths…>" or "ABSENT"
  local pj="$REPO_ROOT/$1/node_modules/@aztec/kv-store/package.json"
  [ -f "$pj" ] || { printf 'ABSENT\n'; return 0; }
  python3 - "$pj" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
subs = sorted(k for k in d.get("exports", {}) if "indexeddb" in k or "opfs" in k)
print(d["version"] + " " + " ".join(subs))
PY
}

DRIFT="$(read_installed drift)"
SPIKE="$(read_installed spike)"
DIFFSIM="$(read_installed diffsim)"
ORCH_KV="$(read_installed orchestration)"

assert_prefix "drift's kv-store is on the CURRENT pin" "$PIN_CURRENT " "$DRIFT"
assert_true "…and it exports ./deprecated/indexeddb" str_has_sub "$DRIFT" "./deprecated/indexeddb"
assert_true "…beside ./sqlite-opfs" str_has_sub "$DRIFT" "./sqlite-opfs"

assert_prefix "spike's kv-store is on the DELETION-ERA pin" "$PIN_DELETION " "$SPIKE"
assert_true "…and it exports the UNdeprecated ./indexeddb" \
  str_has_sub "$SPIKE" " ./indexeddb"
assert_false "…and NOT ./deprecated/indexeddb" str_has_sub "$SPIKE" "./deprecated/indexeddb"
assert_eq "diffsim's kv-store agrees with spike's, so it is the line and not one tree" \
  "$SPIKE" "$DIFFSIM"

# THE PACKAGE THAT WOULD DO THE WORK. `orchestration/` is on `deletion_era` and does not install
# kv-store at all — both facts matter, and the second is why nothing here depends on the spelling
# today.
CONSUMER="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["npm_consumers"]["orchestration"])' "$REPO_ROOT/pins.json")"
assert_eq "orchestration is on the deletion_era line" "deletion_era" "$CONSUMER"
assert_eq "…and does not install @aztec/kv-store at all" "ABSENT" "$ORCH_KV"

# ---------------------------------------------------------------------------
# PART 2 — the FORK, at both anchors
# ---------------------------------------------------------------------------
echo "== the fork's own kv-store, at both anchors"

read_anchor() { # <rev> -> subpaths
  git -C "$FORK_ROOT" show "$1:yarn-project/kv-store/package.json" 2>/dev/null \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(" ".join(sorted(k for k in d.get("exports", {}) if "indexeddb" in k or "opfs" in k)))'
}
CPP_SUBS="$(read_anchor "$M23_CPP_ANCHOR")"
TS_SUBS="$(read_anchor "$M23_TS_ANCHOR")"

assert_eq "at the cpp anchor the subpaths are the deprecated pair" \
  "./deprecated/indexeddb ./sqlite-opfs" "$CPP_SUBS"
assert_eq "…and at the ts anchor they are the undeprecated pair" \
  "./indexeddb ./sqlite-opfs" "$TS_SUBS"
assert_true "…so the two anchors disagree, which is the whole finding" test "$CPP_SUBS" != "$TS_SUBS"

echo "== the FULL export list at the anchor, and every target exists"
ALL_SUBS="$(git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:yarn-project/kv-store/package.json" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
for k, v in sorted(d["exports"].items()):
    print("%s\t%s" % (k, v if isinstance(v, str) else json.dumps(v)))')"
N_SUBS="$(printf '%s\n' "$ALL_SUBS" | grep -c .)"
assert_ge "the package exports several subpaths" 6 "$N_SUBS"
# `dest/x/index.js` is built from `src/x/index.ts`, so the source of each target must be in the
# tree. An export pointing at nothing is the failure this looks for.
BAD=""
while IFS="$(printf '\t')" read -r sub target; do
  [ -n "$target" ] || continue
  src="$(printf '%s' "$target" | sed -e 's|^\./dest/|yarn-project/kv-store/src/|' -e 's|\.js$|.ts|')"
  git -C "$FORK_ROOT" cat-file -e "$M23_CPP_ANCHOR:$src" 2>/dev/null || BAD="$BAD $sub"
done <<EOF
$ALL_SUBS
EOF
assert_eq "every export subpath's source exists in the tree" "" "$BAD"

# ---------------------------------------------------------------------------
# PART 3 — the deprecation is MARKED, in the source and not only in a path name
# ---------------------------------------------------------------------------
echo "== the deprecation is marked in three places, and quoted"

README="$(m23_anchor_file yarn-project/kv-store/README.md)"
assert_true "the README calls it a deprecated browser backend" \
  str_has_sub "$README" "**deprecated** browser backend"
assert_true "…and names sqlite-opfs as what new browser code must use" \
  str_has_sub "$README" "New browser code must use \`@aztec/kv-store/sqlite-opfs\`"

IDB_INDEX="$(m23_anchor_file yarn-project/kv-store/src/deprecated/indexeddb/index.ts)"
assert_true "the entry point carries an @deprecated tag" str_has_sub "$IDB_INDEX" "@deprecated"
IDB_STORE="$(m23_anchor_file yarn-project/kv-store/src/deprecated/indexeddb/store.ts)"
assert_true "…and so does the store class" str_has_sub "$IDB_STORE" "@deprecated"
# THE CONTROL: the LIVE backend is not marked deprecated by the same lookup.
OPFS="$(m23_anchor_file yarn-project/kv-store/src/sqlite-opfs/index.ts)"
assert_false "…while the sqlite-opfs entry point is not" str_has_sub "$OPFS" "@deprecated"

# ---------------------------------------------------------------------------
# PART 4 — sqlite-opfs pulls WASM, not a native addon
# ---------------------------------------------------------------------------
echo "== the live browser store pulls WASM and not a native addon"

WORKER="$(m23_anchor_file yarn-project/kv-store/src/sqlite-opfs/worker.ts)"
assert_true "the sqlite-opfs worker imports @aztec/sqlite3mc-wasm" \
  str_has_sub "$WORKER" "@aztec/sqlite3mc-wasm"
assert_false "…and does not reach @aztec/native" str_has_sub "$WORKER" "@aztec/native"
# @aztec/native IS a dependency of the package — that is not in dispute — and it is reached by the
# LMDB path only. The distinction is what M27 will need.
LMDB2="$(m23_anchor_file yarn-project/kv-store/src/lmdb-v2/store.ts)"
assert_true "the lmdb-v2 store is what reaches @aztec/native" str_has_sub "$LMDB2" "@aztec/native"
KVPJ="$(git -C "$FORK_ROOT" show "$M23_CPP_ANCHOR:yarn-project/kv-store/package.json")"
assert_true "…and @aztec/native is a declared dependency of the package" \
  str_has_sub "$KVPJ" "@aztec/native"

# ---------------------------------------------------------------------------
# PART 5 — all four artefacts are RECORDED
# ---------------------------------------------------------------------------
echo "== CHAIN-LOOP.md records all four, not one"

assert_true "the document names the current pin's spelling" \
  str_has_sub "$DOC" "$PIN_CURRENT\` | \`./deprecated/indexeddb\`"
assert_true "…and the deletion-era pin's" \
  str_has_sub "$DOC" "$PIN_DELETION\` | \`./indexeddb\`"
assert_true "…and the fork at the cpp anchor" str_has_sub "$DOC" "the fork at the \`cpp\` anchor"
assert_true "…and the fork at the ts anchor" str_has_sub "$DOC" "the fork at the \`ts\` anchor"
assert_true "…and names the commit that renamed it" str_has_sub "$DOC" "ffb5fe64bceba54430d207323a0eb03897941cb3"
assert_true "…and says which line orchestration is on" \
  str_has_sub "$DOC" "\`orchestration/package.json\` pins"
assert_true "…and that kv-store is not installed there" \
  str_has_sub "$DOC" "not installed under \`orchestration/\` at all"
assert_true "…and that sqlite-opfs is the live browser store pulling WASM" \
  str_has_sub "$DOC" "pulls WASM, not a native addon"
# THE CONTROL for those needles: a claim the document does not make is not found by the same lookup.
assert_false "…and a claim the document does not make is not found" \
  str_has_sub "$DOC" "the IndexedDB export has been removed"

m23_finish
