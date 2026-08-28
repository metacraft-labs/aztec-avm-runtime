#!/usr/bin/env bash
# verify_transpiler_rung1_mapping_survives — M31.
#
#   verification/verify_transpiler_rung1_mapping_survives.sh   (or: just verify-m31)
#
# ============================================================================================
# THE LOAD-BEARING CONSTRAINT, AND WHY LOSING IT WOULD BE SILENT.
# ============================================================================================
#
# M25's OQ-5 verdict is that Aztec's transpiler preserves enough debug information to map an AVM
# program counter back to `(path, line, column)` — rung 1 — because it REWRITES the debug map in
# place (`avm-transpiler/src/transpile.rs:1803`, `patch_debug_info_pcs`), re-keying
# `brillig_locations` from Brillig opcode INDEX to AVM BYTE OFFSET. Everything CodeTracer shows
# for an Aztec contract rests on that.
#
# A wasm build that lost it would not crash and would not print anything. `rungFor` would still be
# handed a map, the map would still have keys, and every pc the executor presented would simply
# fail to resolve — which reads as "this contract has no source", i.e. rung 3, arrived at
# silently. So this check does not ask whether a map exists. It asks:
#
#   * whether the keys MOVED — the input's key set versus the output's, per function;
#   * whether the output's keys are AVM byte offsets — strictly inside the transpiled bytecode;
#   * whether each of them RESOLVES to a `(path, line, column)` in the artifact's own `file_map`;
#   * and, as the control, whether the map that was NOT re-keyed resolves NONE of them.
#
# ============================================================================================
# EVERYTHING HERE IS MEASURED OVER THE BROWSER'S OUTPUT.
# ============================================================================================
#
# `tools/run_transpiler_arms.mjs` decodes `browser-<fixture>.out.json` — the bytes the page
# produced, carried out as base64 — and drives M25's OWN `ct-host/src/source_map.ts`
# (`ContractSourceMap`, `rungFor`) over them, unchanged. "Read it from the artefact" is not
# enough on its own; the campaign's rule is to ask WHICH artefact, and this is the one the
# milestone is about.
#
# The rung-3 CONTROL is the milestone's own words — "a rung-3 artifact is LABELLED rung 3 rather
# than silently accepted" — and one of the three controls is produced by the transpiler ITSELF:
# `private_only` has no public function, so `create_revert_dispatch_fn` appends a `public_dispatch`
# with no debug info at all.

TEST_NAME="verify_transpiler_rung1_mapping_survives"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m31_transpiler.sh"
m31_summary_on_abnormal_exit

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m31_require_arms

# ---------------------------------------------------------------------------
echo "== 0. the rung arm produced data"
# ---------------------------------------------------------------------------
RUNG_ERR="$(m31_arm arms.rungError.message)"
assert_eq "the rung arm did not throw" "MISSING" "$RUNG_ERR"
assert_eq "…and it is not reporting itself unavailable" "MISSING" "$(m31_arm arms.rung.unavailable)"
COUNTER_RUNG="$(m31_arm arms.rung.contracts.counter.functions.public_dispatch.rung)"
COUNTER_PCS="$(m31_arm arms.rung.contracts.counter.functions.public_dispatch.pcCount)"
COUNTER_POS="$(m31_arm arms.rung.contracts.counter.functions.public_dispatch.positioned)"
CTRL_AVM="$(m31_arm arms.rung.controls.notRekeyed.avmPcs)"
CTRL_GOOD="$(m31_arm arms.rung.controls.notRekeyed.positionedByTheRealMap)"
CTRL_STALE="$(m31_arm arms.rung.controls.notRekeyed.positionedByTheStaleMap)"
ABSENT="$(m31_absent rung="$COUNTER_RUNG" pcCount="$COUNTER_PCS" positioned="$COUNTER_POS" \
  ctrlAvmPcs="$CTRL_AVM" ctrlGood="$CTRL_GOOD" ctrlStale="$CTRL_STALE")"
[ -z "$ABSENT" ] || die "the rung arm is missing:$ABSENT — every comparison below would compare
     two absent values. Delete $M31_ARMS and re-run."
assert_eq "the rung arm carries every field this check reads" "" "$ABSENT"

# ---------------------------------------------------------------------------
echo "== 1. every AVM function of every fixture that HAS a map is on rung 1"
# ---------------------------------------------------------------------------
ROWS="$(python3 - "$M31_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for c, v in sorted(d["arms"]["rung"]["contracts"].items()):
    for fn, f in sorted(v["functions"].items()):
        print("\t".join(str(x) for x in [
            c, fn, f["rung"], f["pcCount"], f["positioned"], f["unpositioned"],
            f["bytecodeLength"], (f["pcRange"] or {}).get("min", -1), (f["pcRange"] or {}).get("max", -1),
            len(f["distinctLines"]), f["unrecognisedTreeNodes"], f["missingFileReferences"],
        ]))
PY
)"
ROW_COUNT="$(printf '%s\n' "$ROWS" | grep -c . || true)"
assert_ge "there are AVM functions to judge at all" 6 "$ROW_COUNT"

MAPPED=0
while IFS=$'\t' read -r c fn rung pcs pos unpos bclen mn mx lines badtree badfile; do
  [ -n "$c" ] || continue
  if [ "$pcs" = "0" ]; then
    # The only function with no map at all is the appended revert dispatch — asserted by name in
    # section 3, so a SECOND unmapped function would be a finding rather than a silent pass.
    assert_eq "$c/$fn has no map, and the only function allowed that is private_only's" \
      "private_only" "$c"
    continue
  fi
  MAPPED=$((MAPPED + 1))
  assert_eq "$c/$fn is on rung 1" "1" "$rung"
  assert_ge "$c/$fn has pcs to resolve" 1 "$pcs"
  assert_eq "$c/$fn: every mapped pc resolves to a (path, line, column)" "$pcs" "$pos"
  assert_eq "$c/$fn: and none is left unpositioned" "0" "$unpos"
  assert_eq "$c/$fn: no call-stack node whose shape the resolver could not place" "0" "$badtree"
  assert_eq "$c/$fn: no location naming a file the file_map does not carry" "0" "$badfile"
  # THE KEYS ARE AVM BYTE OFFSETS: strictly inside the transpiled bytecode. A map still keyed by
  # Brillig index would be a small dense range near zero, and `rungFor` refuses a map whose top
  # key is past the end of the bytecode.
  assert_true "$c/$fn: the highest key is inside the transpiled bytecode ($mx < $bclen)" \
    test "$mx" -lt "$bclen"
  assert_ge "$c/$fn: …and the lowest is past the dispatch preamble" 1 "$mn"
done <<<"$ROWS"
assert_ge "at least six AVM functions were judged on rung 1" 6 "$MAPPED"

# ---------------------------------------------------------------------------
echo "== 2. THE KEYS MOVED — the re-keying is a comparison, not a claim"
# ---------------------------------------------------------------------------
# `patch_debug_info_pcs` is what M25's verdict rests on. If it were a no-op the output's key set
# would be the INPUT's. The two are compared per function AS SETS — see the note beside the
# assertion for why a RANGE comparison is the wrong instrument here.
KEYCMP="$(python3 - "$M31_ARMS" <<'PYEOF'
import json, sys
d = json.load(open(sys.argv[1]))
for c, v in sorted(d["arms"]["rung"]["contracts"].items()):
    ink = v.get("inputKeys", {})
    for fn, f in sorted(v["functions"].items()):
        src = list(ink.get(fn, []))
        out = list(f.get("pcKeys", []))
        if not src or not out:
            print("\t".join([c, fn, "SKIP", "0", "0", "0", "0", "0"])); continue
        shared = len(set(src) & set(out))
        print("\t".join(str(x) for x in [
            c, fn, "CMP", len(src), len(out), shared,
            1 if src == out else 0, max(out) - max(src),
        ]))
PYEOF
)"
CMP_ROWS=0
while IFS=$'\t' read -r c fn kind nin nout shared same growth; do
  [ "$kind" = "CMP" ] || continue
  CMP_ROWS=$((CMP_ROWS + 1))
  # SAME COUNT, DIFFERENT VALUES. `patch_debug_info_pcs` re-keys one-to-one, so a lost entry is
  # as much a finding as a key that did not move.
  assert_eq "$c/$fn: the re-keyed map has as many entries as the input's" "$nin" "$nout"
  # THE KEY LIST IS NOT THE INPUT'S. This is the property, and it is a SET comparison rather than
  # a comparison of two RANGES: `branches` has 56 Brillig opcodes and AVM offsets in [64, 489], so
  # 22 input indices sit inside the output's interval while not one of them is the same entry.
  # A range test would call that a failure and it is not one.
  assert_eq "$c/$fn: the key list is NOT the input's" "0" "$same"
  assert_true "$c/$fn: fewer than half the input's keys survive as output keys" \
    test "$shared" -lt "$(( (nin + 1) / 2 ))"
  # DIRECTIONAL: an AVM instruction is several bytes, so byte offsets run further than opcode
  # indices. A map left keyed by index would have growth 0.
  assert_ge "$c/$fn: the key space GREW, which is what bytes-versus-indices means" 1 "$growth"
done <<<"$KEYCMP"
assert_ge "the key comparison ran over several functions" 5 "$CMP_ROWS"

# ---------------------------------------------------------------------------
echo "== 3. THE CONTROLS — three of them, and one the transpiler produced itself"
# ---------------------------------------------------------------------------
# (a) THE FAILURE THIS MILESTONE IS ABOUT. The input's Brillig-index map spliced onto the
# transpiled bytecode — exactly what a build that lost `patch_debug_info_pcs` would emit — asked
# about the AVM pcs an executor presents.
assert_ge "the control has pcs to ask about" 20 "$CTRL_AVM"
assert_eq "the re-keyed map positions every one of them" "$CTRL_AVM" "$CTRL_GOOD"
assert_eq "…and the map that was NOT re-keyed positions NONE of them" "0" "$CTRL_STALE"
STALE_MAX="$(m31_arm arms.rung.controls.notRekeyed.staleKeyRange | python3 -c 'import json,sys; print(json.load(sys.stdin)["max"])')"
COUNTER_MIN="$(m31_arm arms.rung.contracts.counter.functions.public_dispatch.pcRange | python3 -c 'import json,sys; print(json.load(sys.stdin)["min"])')"
assert_true "…and the two key spaces do not even overlap ($STALE_MAX < $COUNTER_MIN)" \
  test "$STALE_MAX" -lt "$COUNTER_MIN"

# (b) A RUNG-3 ARTIFACT THE TRANSPILER ITSELF PRODUCED. `private_only` declares no `abi_public`
# function, so `transpile_contract.rs`'s `create_revert_dispatch_fn` appends a `public_dispatch`
# that reverts, with no debug info. It must be LABELLED, not accepted.
assert_eq "the appended revert dispatch is present" "true" \
  "$(m31_arm arms.rung.controls.appendedRevertDispatch.present)"
assert_eq "…and it is LABELLED rung 3" "3" "$(m31_arm arms.rung.controls.appendedRevertDispatch.rung)"
assert_eq "…with zero mapped pcs" "0" "$(m31_arm arms.rung.controls.appendedRevertDispatch.mappedPcs)"
assert_contains "…and a reason that says why rather than a bare number" "brillig_locations is empty" \
  "$(m31_arm arms.rung.controls.appendedRevertDispatch.reason)"
assert_ge "…and it is real bytecode, so 'no map' is not 'no function'" 20 \
  "$(m31_arm arms.rung.controls.appendedRevertDispatch.bytecodeLength)"

# (c) NO DEBUG SYMBOLS AT ALL.
assert_eq "an artifact with no debug_symbols is labelled rung 3" "3" \
  "$(m31_arm arms.rung.controls.noDebugSymbols.rung)"
assert_contains "…naming the absence" "carries no debug_symbols" \
  "$(m31_arm arms.rung.controls.noDebugSymbols.reason)"

# THE PAIRED POSITIVE for all three: `rungFor` does not answer 3 for everything.
assert_eq "…and the same resolver answers 1 for the browser's counter artifact" "1" "$COUNTER_RUNG"
assert_contains "…with the reason naming the re-keying OQ-5 rests on" "AVM byte offset" \
  "$(m31_arm arms.rung.contracts.counter.functions.public_dispatch.reason)"

# ---------------------------------------------------------------------------
echo "== 4. the positions are real positions, in a file the caller supplied"
# ---------------------------------------------------------------------------
FIRST="$(m31_arm arms.rung.contracts.counter.functions.public_dispatch.firstThree)"
assert_ge "the first resolved positions were recorded" 10 "${#FIRST}"
FIRST_PATH="$(printf '%s' "$FIRST" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["path"])')"
FIRST_LINE="$(printf '%s' "$FIRST" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["line"])')"
FIRST_COL="$(printf '%s' "$FIRST" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["column"])')"
assert_ge "the first position has a line" 1 "$FIRST_LINE"
# A COLUMN, not just a line. Rung 1 is `(path, line, column)`; a resolver that answered column 0
# for everything would still satisfy a line assertion.
assert_ge "…and a column" 1 "$FIRST_COL"
assert_contains "…and the path ends in the fixture's own file" "counter/src/main.nr" "$FIRST_PATH"
# The line is a line of the SOURCE the artifact carries, checked against the file the fixture
# directory holds — so a position that pointed past the end of the file would fail.
FIXTURE_LINES="$(grep -c '' "$M31_FIXTURES/counter/src/main.nr" || true)"
assert_true "…and that line exists in the fixture source ($FIRST_LINE <= $FIXTURE_LINES)" \
  test "$FIRST_LINE" -le "$FIXTURE_LINES"
# Several distinct lines across the corpus, so "resolves" is not "resolves to one constant".
DISTINCT_TOTAL="$(python3 - "$M31_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
seen = set()
for c, v in d["arms"]["rung"]["contracts"].items():
    for fn, f in v["functions"].items():
        for ln in f["distinctLines"]:
            seen.add((c, ln))
print(len(seen))
PY
)"
assert_ge "the corpus resolves to several distinct source lines, not one" 8 "$DISTINCT_TOTAL"

# ---------------------------------------------------------------------------
echo "== 4b. THE OTHER KEY SPACE IN THE SAME DebugInfo, WHICH IS *NOT* RE-KEYED"
# ---------------------------------------------------------------------------
# ADDED BY M31's REVIEW, BECAUSE THE MILESTONE STATED THE OPPOSITE AND NOTHING MEASURED IT.
# The Outstanding item said "None of the seven fixtures has a compiled procedure, so the hole is
# not exercised here either". TWO of the seven do: `branches` and `reverting` each carry one
# `brillig_procedure_locs` entry, and the transpiled artifact carries it BYTE-IDENTICAL to the
# input's — key `11`, a Brillig opcode INDEX, sitting in the same `DebugInfo` whose
# `brillig_locations` were re-keyed to AVM byte offsets in [64, 489].
#
# That is `SOURCE-MAPPING.md` §2.4's residual hole 1 demonstrated EXACTLY, on this milestone's own
# artifacts, where §2.4 could only argue it from a value RANGE over `AvmTest` (procedure values
# topping out at 9,589 against `brillig_locations`' 50,526). It is asserted here rather than
# described, so the day upstream re-keys it this section goes red and the document that says the
# hole is open has to be re-read.
#
# It does NOT touch the rung: `ct-host/src/source_map.ts:40` says `brillig_procedure_locs` is
# deliberately untouched, and §1 above is over `brillig_locations` only.
PROC="$(python3 - "$M31_ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for c, v in sorted(d["arms"]["rung"]["contracts"].items()):
    inp = v.get("inputProcedureLocs", {})
    for fn, f in sorted(v["functions"].items()):
        out = f.get("procedureLocs", "MISSING")
        src = inp.get(fn, "MISSING")
        print("\t".join([c, fn, out, src, "1" if out == src else "0"]))
PY
)"
PROC_ROWS="$(printf '%s\n' "$PROC" | grep -c . || true)"
assert_ge "the procedure-map comparison has rows to judge" 6 "$PROC_ROWS"
NONEMPTY=0
CARRIED=0
while IFS=$'\t' read -r c fn out src same; do
  [ -n "$c" ] || continue
  assert_false "$c/$fn: the output's procedure map was read at all" test "$out" = "MISSING"
  if [ "$src" = "MISSING" ]; then
    # The one function with no counterpart in the INPUT is the appended revert dispatch, and it is
    # named rather than skipped — a second one would be a finding.
    assert_eq "$c/$fn has no input counterpart, and only private_only's may have none" \
      "private_only" "$c"
    continue
  fi
  # THE HOLE: whatever the input had, the output has, unchanged. True of `{}` too, which is why
  # the non-emptiness census below is what stops this being vacuous.
  assert_eq "$c/$fn: brillig_procedure_locs comes through UNCHANGED — hole 1, not re-keyed" \
    "1" "$same"
  if [ "$out" != "{}" ]; then
    NONEMPTY=$((NONEMPTY + 1))
    case "$c" in
      branches|reverting) CARRIED=$((CARRIED + 1)) ;;
      *) assert_eq "$c/$fn carries a procedure map and only branches/reverting should" \
           "branches-or-reverting" "$c" ;;
    esac
  fi
done <<<"$PROC"
# NON-EMPTINESS, so "unchanged" above is not seven comparisons of `{}` with `{}` — the identity
# family this campaign has met with `assert_eq "" ""` and with a deviation field that was zero on
# every row of the arm it was asserted over.
assert_eq "exactly two of the corpus's AVM functions carry a compiled procedure at all" "2" \
  "$NONEMPTY"
assert_eq "…and they are branches' and reverting's" "2" "$CARRIED"
# AND THE KEY IS A BRILLIG INDEX WHILE THE SIBLING MAP'S ARE AVM BYTE OFFSETS — the two key
# spaces in one `DebugInfo`, which is what makes mixing them a silent wrong answer.
BR_PROC="$(m31_arm arms.rung.contracts.branches.functions.public_dispatch.procedureLocs)"
assert_contains "branches' procedure map is keyed by a Brillig opcode index" '"11"' "$BR_PROC"
BR_MIN="$(m31_arm arms.rung.contracts.branches.functions.public_dispatch.pcRange \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["min"])')"
assert_true "…which is below the sibling map's lowest AVM byte offset (11 < $BR_MIN)" \
  test 11 -lt "$BR_MIN"

# ---------------------------------------------------------------------------
echo "== 5. the claim is anchored to the source it rests on"
# ---------------------------------------------------------------------------
# `patch_debug_info_pcs` is read out of the MATERIALISED transpiler tree, at the anchor, so a
# rename upstream turns this red rather than leaving a document quoting a symbol that is gone.
TRANSPILE_RS="$M31_TREE/avm-transpiler/src/transpile.rs"
assert_file "the materialised transpiler carries transpile.rs" "$TRANSPILE_RS"
assert_ge "…and it defines patch_debug_info_pcs" 1 \
  "$(grep -c 'fn patch_debug_info_pcs' "$TRANSPILE_RS" || true)"
assert_ge "…and transpile_contract.rs calls it" 1 \
  "$(grep -c 'patch_debug_info_pcs(' "$M31_TREE/avm-transpiler/src/transpile_contract.rs" || true)"
# The paired zero: the name is NOT in the shim, so the re-keying is upstream's work and not ours.
assert_eq "…and this repository's shim does not mention it" "0" \
  "$(grep -c 'patch_debug_info_pcs' "$M31_SHIM/src/lib.rs" || true)"

m31_finish
