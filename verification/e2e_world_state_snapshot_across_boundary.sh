#!/usr/bin/env bash
# e2e_world_state_snapshot_across_boundary
#
# EXPORT THE WORLD STATE AND IMPORT IT INTO A FRESH INSTANCE — AND THE FINDING IS THAT THE TWO
# SHAPES DO NOT ANSWER IT EQUALLY.
#
# That asymmetry is the deliverable's real content, so it is established by execution rather than
# asserted in prose:
#
#   RESIDENT   There is no carrier. `world_state_reference::MemoryMerkleDB` keeps its `State`
#              private and its only accessor is `get_tree_roots()`, which returns a SUMMARY —
#              `{root, nextAvailableLeafIndex}` per tree, the protocol's `AppendOnlyTreeSnapshot`
#              shape. That is the right vocabulary for a state REFERENCE and it cannot carry a
#              state: two different trees with the same next index and a coincidental root would
#              be indistinguishable, and more to the point nothing can be RECONSTRUCTED from it.
#              M23 already records the distinction; this is where it bites. Asserted three ways:
#              against the header, against the reactor's export list, and against the COMPILED
#              symbol table, because a method that exists and is not exported and a method that
#              does not exist are different findings.
#
#   CHATTY     The carrier is free and needs no upstream change, because the host owns the DB and
#              therefore already holds every operation that built it. An export is the ordered
#              journal of those operations; an import is replaying it into a fresh DB. It is
#              O(changes) rather than O(state), which is the property §6.4 asked of checkpoints and
#              did not get.
#
# WHAT THIS CHECK RUNS is the chatty half, end to end, through the boundary: a world state is built
# by applying the corpus's own upstream-packed operations, the journal is replayed into a fresh DB
# handle, and every tree root and next-available index must match.
#
# THE COMPARISON CANNOT SUCCEED BECAUSE BOTH SIDES ARE EMPTY, and that is asserted rather than
# hoped: the fresh DB's roots BEFORE the import are captured and required to DIFFER from the
# source's, so "they match afterwards" is a statement about the import and not about two genesis
# states agreeing. This campaign has already had two comparisons that passed on emptiness.
#
# WHAT IT DOES NOT COVER, stated because the honest limit is part of the answer: the journal here is
# the operations the HOST applied. The operations the AVM performs INSIDE a simulation are visible
# to a host only in the fully fused chatty arm, which M15 prepares and does not measure. So the
# chatty carrier is demonstrated on host-applied state and is argued — not measured — for
# AVM-applied state. Recorded in BOUNDARY-SHAPE.md as exactly that.

set -uo pipefail
TEST_NAME=e2e_world_state_snapshot_across_boundary
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m15_shapes.sh"

M15_TREE="$(m15_tree)"; m6_tree_or_die M15_TREE
TREE="$M15_TREE"
m15_build_wasm "$TREE";   assert_eq "the wasm build succeeded" "0" "$M15_WASM_BUILD_RC"
m15_build_native "$TREE"; assert_eq "the native build succeeded" "0" "$M15_NATIVE_BUILD_RC"
m15_make_inputs "$TREE";  assert_eq "the driver emitted its inputs" "0" "$?"
WASM="$(m15_wasm_module "$TREE")"
INPUTS="$(m15_reactor_inputs)"

# ---------------------------------------------------------------------------
# 1. THE RESIDENT SHAPE HAS NO CARRIER. Three witnesses, because one of them is a grep.
# ---------------------------------------------------------------------------
REF_HPP="$TREE/barretenberg/cpp/src/barretenberg/world_state_reference/memory_merkle_db.hpp"
assert_file "the reference's header is in this milestone's own tree" "$REF_HPP"
assert_eq "its State is private" "1" \
  "$(awk '/^  private:/{p=1} p && /struct State \{/{print "1"; exit}' "$REF_HPP")"
for n in serialize deserialize to_bytes from_bytes export_state import_state get_state set_state; do
  assert_eq "the reference declares no $n" "0" "$(grep -cE "\b$n\b" "$REF_HPP" || true)"
done
# The needle is not vacuous: the same style of search finds the accessor that DOES exist.
assert_ge "while get_tree_roots is right there" 1 "$(grep -cE '\bget_tree_roots\b' "$REF_HPP" || true)"
# And what it returns is the summary, named field for field. The needle is the C++ SPELLING, which
# is `next_available_leaf_index` — `nextAvailableLeafIndex` is what msgpack's camel-case adaptor
# puts on the WIRE, and a needle taken from the wire instead of from the header finds nothing in
# the header. That is the mistake this campaign has made ten times and it made it here once more.
assert_eq "a TreeSnapshot is exactly two fields — a root and a next index, not a state" "2" \
  "$(sed -n '/^struct TreeSnapshot {/,/^};/p' "$REF_HPP" | grep -cE '^ +(FF root|uint64_t next_available_leaf_index)' || true)"
# The MEMBERS, not the lines. A search for `Tree` over the struct's text matches the struct's own
# NAME and its `operator==` parameter, which is how a needle that was not derived from the thing it
# is about reports two container members in a struct that has none. The member lines are the
# indented declarations that are not the comparison operator, and both of their TYPES are named.
SNAP_MEMBERS="$(sed -n '/^struct TreeSnapshot {/,/^};/p' "$REF_HPP" \
  | grep -E '^ +[A-Za-z_][A-Za-z0-9_:<>]* [a-z_]+ *(=|;)' | grep -v 'operator')"
assert_eq "it has exactly two members" "2" "$(printf '%s\n' "$SNAP_MEMBERS" | grep -c . || true)"
assert_eq "and both of their types are scalars — nothing in it can carry a tree" "2" \
  "$(printf '%s\n' "$SNAP_MEMBERS" | grep -cE '^ +(FF|uint64_t) ' || true)"

# The reactor exports nothing that could carry one either.
# ONE reader, not a fallback chain. A check that tries a second tool when the first produces
# nothing cannot tell "this module exports nothing" from "that tool is not on the path", and the
# assertion below would then be about the reader. `llvm-nm` is in the fork's dev shell by
# construction — the wasi-sdk provides it — and if it is not, this fails.
WASM_EXPORTS="$M15_WORK/exports.txt"
m6_in_devshell 'llvm-nm --defined-only --extern-only "$1" | awk "{print \$3}" | sort -u' \
  "$WASM" >"$WASM_EXPORTS" 2>"$WASM_EXPORTS.err"
assert_eq "the module's export list was read" "0" "$?"
assert_ge "and it is not empty" 20 "$(m15_lines "$WASM_EXPORTS")"
assert_ge "it contains the exports this milestone drives, so the reader worked" 1 \
  "$(grep -c '^avm_merkle_db_get_tree_roots$' "$WASM_EXPORTS" || true)"
for n in avm_merkle_db_export avm_merkle_db_import avm_merkle_db_get_state avm_merkle_db_set_state; do
  assert_eq "and it does not export $n" "0" "$(grep -c "^$n\$" "$WASM_EXPORTS" || true)"
done

# The compiled library, so "not exported" and "does not exist" are told apart. M14 settled the
# block-pinned-reads question the same way and for the same reason.
LIB="$TREE/barretenberg/cpp/$M15_NATIVE_BUILD/lib/libworld_state_reference.a"
assert_file "the native build produced the reference's library" "$LIB"
SYMS="$M15_WORK/ws-symbols.txt"
m6_in_devshell 'llvm-nm --defined-only "$1" | c++filt' "$LIB" >"$SYMS" 2>"$SYMS.err"
assert_eq "the reference's symbol table was read" "0" "$?"
assert_ge "and it is not empty" 5 "$(m15_lines "$SYMS")"
assert_ge "it carries MemoryMerkleDB symbols, so the read worked" 1 \
  "$(grep -c 'MemoryMerkleDB' "$SYMS" || true)"
assert_eq "and no MemoryMerkleDB symbol serialises the state" "0" \
  "$(grep 'MemoryMerkleDB' "$SYMS" | grep -cE '\b(serialize|deserialize|export|import)\b' || true)"

# ---------------------------------------------------------------------------
# 2. THE CHATTY SHAPE'S CARRIER, end to end.
# ---------------------------------------------------------------------------
OUT="$M15_WORK/snapshot.txt"
m15_host "$WASM" "$INPUTS" snapshot "$OUT"
assert_eq "the snapshot host exited 0" "0" "$?"
assert_eq "it ran to the end" "1" "$(m15_key "$OUT" snapshot.done)"
assert_eq "and wrote nothing from the failure vocabulary to stderr (D11: the AVM logs there)" "0" "$(m15_stderr_unexpected "$OUT.err")"
assert_eq "it built the state from all seven corpus programs" "$M15_EXPECTED_PROGRAMS" \
  "$(m15_key "$OUT" snapshot.programs.count)"

ENTRIES="$(m15_key "$OUT" snapshot.journal.entries)"
JBYTES="$(m15_key "$OUT" snapshot.journal.bytes)"
for v in "$ENTRIES" "$JBYTES"; do
  case "$v" in ''|*[!0-9]*) die "the journal did not report a number (got '$v')" ;; esac
done
note "the export journal is $ENTRIES operations, $JBYTES bytes"
assert_ge "the journal is not empty" 14 "$ENTRIES"
assert_ge "and carries real payloads" 100 "$JBYTES"

# The four trees, named, both halves.
assert_eq "four trees were compared" "4" "$(m15_key "$OUT" snapshot.trees.count)"
MATCHED=0
MOVED=0
for t in $(sed -n 's/^snapshot\.match\.\([A-Za-z0-9_]*\) .*/\1/p' "$OUT"); do
  assert_eq "$t: the imported root and next index equal the exported ones" "1" \
    "$(m15_key "$OUT" "snapshot.match.$t")"
  [ "$(m15_key "$OUT" "snapshot.moved.$t")" = "1" ] && MOVED=$((MOVED + 1))
  MATCHED=$((MATCHED + 1))
done
assert_eq "all four trees were checked" "4" "$MATCHED"

# ...and the matches are not two genesis states agreeing with each other. THREE of the four trees
# must have MOVED — the journal inserts nullifiers, writes public data and appends note hashes —
# and the fourth must be the L1->L2 message tree, which the journal does not touch because nothing
# in the corpus injects an L1-to-L2 message. Named rather than counted loosely: "three of four
# moved" would also be satisfied by the wrong three.
assert_eq "three of the four trees were moved by the import" "3" "$MOVED"
assert_eq "and the one that was not is the L1->L2 message tree" "0" \
  "$(m15_key "$OUT" snapshot.moved.l1ToL2MessageTree)"
assert_eq "which the journal does not touch, so it is at genesis on both sides" \
  "$(m15_key "$OUT" snapshot.fresh.before.l1ToL2MessageTree)" \
  "$(m15_key "$OUT" snapshot.after.l1ToL2MessageTree)"
for t in noteHashTree nullifierTree publicDataTree; do
  assert_eq "$t moved: the import put it somewhere the fresh instance was not" "1" \
    "$(m15_key "$OUT" "snapshot.moved.$t")"
  assert_false "$t: and its imported root really differs from genesis" \
    test "$(m15_key "$OUT" "snapshot.fresh.before.$t")" = "$(m15_key "$OUT" "snapshot.after.$t")"
done

# The roots themselves are real values, not empty strings that compared equal.
assert_eq "every reported root is a 0x-prefixed 64-hex value with a size" \
  "$(grep -c '^snapshot\.\(before\|after\|fresh\.before\)\.' "$OUT" || true)" \
  "$(grep -cE '^snapshot\.(before|after|fresh\.before)\.[A-Za-z0-9_]+ 0x[0-9a-f]{64} size=[0-9]+$' "$OUT" || true)"
assert_ge "and there are three sets of them" 12 "$(grep -c '^snapshot\.\(before\|after\|fresh\.before\)\.' "$OUT" || true)"

# ---------------------------------------------------------------------------
# 3. The disposition, recorded.
# ---------------------------------------------------------------------------
assert_file "the boundary write-up exists" "$M15_WRITEUP"
assert_true "it records that the resident shape has no carrier at the anchor" \
  grep -q 'no carrier' "$M15_WRITEUP"
assert_true "and that closing it there is an upstream extension rather than an improvisation" \
  grep -q 'upstream extension' "$M15_WRITEUP"
assert_true "and it states the limit of what was measured here" \
  grep -q 'host-applied state' "$M15_WRITEUP"

finish
