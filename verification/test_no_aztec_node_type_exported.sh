#!/usr/bin/env bash
# test_no_aztec_node_type_exported — M21, §8.4.
#
# "The package exports NO type named `AztecNode` and the facade is not shaped like `AztecNode`. The
# narrow adapter Form B needs (§5.4) is internal."
#
# TWO CLAIMS, AND THE SECOND IS THE ONE THAT NEEDS WORK. "No type named `AztecNode`" is a grep.
# "Not shaped like one" is not: TypeScript is structural, so a type that happens to have the right
# members IS an `AztecNode` as far as any consumer's compiler is concerned, whatever it is called.
# Measured at the anchor, `AztecNode` declares sixty-odd methods; what this package exports must not
# be assignable to it, and the sufficient reason is that it has one of them.
#
# WHY §8.4 EXISTS AT ALL, restated because a check whose reason lives elsewhere gets deleted: a
# consumer who receives something called an `AztecNode` may reasonably believe this runtime is a
# node. It is not. It produces no proofs and no blocks anyone else can verify, and §3's fidelity
# contract is "a consumer must not be able to mistake this for a real node".
#
# THE ABSENCE IS ASKED OF A TREE THAT COULD ANSWER THE OTHER WAY, which is the campaign's own rule
# and the defect it has shipped twice. The needle is shown to FIND `AztecNode` where it really
# occurs — in this package's own comments, which cite the type by name deliberately — so a zero here
# is a zero from a working grep and not from a grep that matches nothing.

set -uo pipefail
TEST_NAME="test_no_aztec_node_type_exported"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m21_form_b.sh"

echo "== $TEST_NAME"

SRC="$M21_SRC"
assert_dir "the orchestration sources are present" "$SRC"
INDEX="$(cat "$SRC/index.ts")"
assert_ge "index.ts was read" 100 "$(printf '%s\n' "$INDEX" | grep -c . || true)"

# ---------------------------------------------------------------------------
echo "== 1. no export in this package is named AztecNode, by any spelling"
# ---------------------------------------------------------------------------
EXPORTED="$(printf '%s\n' "$INDEX" | grep -oE '^  (type )?[A-Za-z_][A-Za-z0-9_]*,$' \
            | sed 's/^  //; s/^type //; s/,$//' | LC_ALL=C sort -u || true)"
N_EXPORTED="$(printf '%s\n' "$EXPORTED" | grep -c . || true)"
note "index.ts re-exports $N_EXPORTED name(s)"
assert_ge "the export surface is not empty, so what follows is not vacuous" 30 "$N_EXPORTED"
if str_has_line "$EXPORTED" "AztecNode"; then named=yes; else named=no; fi
assert_eq "…and none of them is AztecNode" "no" "$named"
if str_has_line "$EXPORTED" "SubmittedTx"; then named=yes; else named=no; fi
assert_eq "…while the same lookup DOES find SubmittedTx, which is exported" "yes" "$named"
if str_has_line "$EXPORTED" "SettledLeafIndexSource"; then named=yes; else named=no; fi
assert_eq "…and the adapter's own type, so the surface really was parsed" "yes" "$named"

for spelling in AztecNode AztecNodeApi AztecNodeLike AztecNodeAdapter aztecNode; do
  HITS="$(grep -rhcE "^\s*export (type |interface |class |const |function )?$spelling\b" "$SRC" \
          2>/dev/null | awk '{ s += $1 } END { print s + 0 }')"
  assert_eq "nothing in orchestration/src EXPORTS a $spelling" "0" "$HITS"
done
# The control on that needle SHAPE: it finds an export that is there.
HITS="$(grep -rhcE "^\s*export (type |interface |class |const |function )?ResidentSettledReadSource\b" \
        "$SRC" 2>/dev/null | awk '{ s += $1 } END { print s + 0 }')"
assert_ge "…and the same needle shape finds ResidentSettledReadSource, which IS exported" 1 "$HITS"

# ---------------------------------------------------------------------------
echo "== 2. the adapter is not SHAPED like an AztecNode either"
#
# Structural typing means the name is the easy half. What makes the adapter un-mistakable is that it
# has one method of the sixty-odd, so nothing can pass it where an `AztecNode` is wanted.
# ---------------------------------------------------------------------------
CPP="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' \
       "$REPO_ROOT/pins.json")"
IFACE="$( ( cd "$FORK_ROOT" && git show "$CPP:yarn-project/stdlib/src/interfaces/aztec-node.ts" ) 2>/dev/null )"
assert_ge "upstream's AztecNode declaration was read at the anchor" 200 \
  "$(printf '%s\n' "$IFACE" | grep -c . || true)"
IFACE_METHODS="$(printf '%s\n' "$IFACE" | grep -oE '^ +[a-z][A-Za-z0-9_]*\(' | tr -d ' (' \
                 | LC_ALL=C sort -u || true)"
N_IFACE="$(printf '%s\n' "$IFACE_METHODS" | grep -c . || true)"
note "AztecNode declares $N_IFACE method(s)"
assert_ge "…and it is a large interface, which is the whole reason for §8.4" 30 "$N_IFACE"
assert_true "…the extraction really found methods, not blank lines" \
  str_has_line "$IFACE_METHODS" "findLeavesIndexes"

ADAPTER="$(cat "$SRC/settled_read_source.ts")"
OURS="$(printf '%s\n' "$ADAPTER" \
        | awk '/^export const ALLOWED_SURFACE/{ inside=1; next } inside && /^\];/{ exit } inside { print }' \
        | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'" | tr -d "'" | LC_ALL=C sort -u || true)"
note "the settled-read source's whole surface: [$(printf '%s' "$OURS" | tr '\n' ' ')]"
assert_eq "the adapter's surface is exactly four names" "4" "$(printf '%s\n' "$OURS" | grep -c . || true)"

OVERLAP=0
while IFS= read -r m; do
  [ -n "$m" ] || continue
  if str_has_line "$IFACE_METHODS" "$m"; then OVERLAP=$((OVERLAP + 1)); fi
done <<EOF
$OURS
EOF
assert_eq "exactly one of them is also an AztecNode method" "1" "$OVERLAP"
assert_true "…and it is findLeavesIndexes, the one OQ-1 enumerated" \
  str_has_line "$OURS" "findLeavesIndexes"
assert_ge "so the adapter is missing at least fifty AztecNode methods" 50 "$((N_IFACE - 1))"

# ---------------------------------------------------------------------------
echo "== 3. the needle works, so section 1's absences are real"
#
# `AztecNode` DOES occur in this package — in comments, deliberately, because §8.4 has to be
# explained where it is obeyed. The distinction between a CITATION and a DECLARATION is the one
# M20's review had to make for `verify_differential_job_separate_failure_domain`: a citation is the
# opposite of a dependency.
# ---------------------------------------------------------------------------
CITATIONS="$(grep -rc 'AztecNode' "$SRC" 2>/dev/null | awk -F: '{ s += $2 } END { print s + 0 }')"
note "orchestration/src mentions AztecNode $CITATIONS time(s)"
assert_ge "the name IS present in this package, so a grep for it is not grepping for nothing" 3 \
  "$CITATIONS"
DECLARATIONS="$(grep -rhcE '^\s*(export )?(type|interface|class)\s+AztecNode\b' "$SRC" 2>/dev/null \
                | awk '{ s += $1 } END { print s + 0 }')"
assert_eq "…and not one of those mentions is a declaration" "0" "$DECLARATIONS"
DECL_CONTROL="$(grep -rhcE '^\s*export interface SettledLeafIndexSource\b' "$SRC" 2>/dev/null \
                | awk '{ s += $1 } END { print s + 0 }')"
assert_eq "…while the same needle shape finds SettledLeafIndexSource, which IS declared" "1" \
  "$DECL_CONTROL"

# ---------------------------------------------------------------------------
echo "== 4. and the name it does have says what it answers"
# ---------------------------------------------------------------------------
assert_true "the exported type is named for the question rather than for a node" \
  str_has_sub "$INDEX" "type SettledLeafIndexSource"
assert_true "…and §8.4 is stated where it is obeyed, not only in the spec" \
  str_has_sub "$INDEX" "NO TYPE NAMED"

finish
