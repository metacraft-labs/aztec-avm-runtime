#!/usr/bin/env bash
# test_msgpack_encode_decode_cost
#
# WHAT THE ENCODING COSTS, SEPARATELY FROM WHAT THE EXECUTION COSTS.
#
# The milestone asks for this so "a crossing-heavy shape is rejected on its real cost rather than a
# guessed one". Three quantities are measured, none of them inferred from another:
#
#   1. THE NULL CROSSING. `avm_abi_version()` is the cheapest export the module has — it returns a
#      constant — so a loop of them measures the fixed cost of a call across the boundary with no
#      payload at all. Divided by the loop count it is nanoseconds per crossing, which is the
#      number every crossing-count estimate has to be multiplied by.
#
#   2. THE TRANSPORT. `avm_alloc` / copy / `avm_free` of a real input blob, at the two sizes the
#      two shapes actually carry: 1,951 bytes for the resident arm's `AvmFastSimulationInputs`
#      and ~187,000 for the chatty arm's `AvmProvingInputs`. Same operation, two sizes, so the
#      difference is the bytes.
#
#   3. THE DECODE. The host decoding the result blob, timed on its own, with no module call in it.
#
#   4. THE MODULE'S DECODE of its INPUT, at both sizes, separated from the simulation it precedes —
#      without a new export. Both entry points decode with upstream's `::from`, which parses the
#      whole buffer and then converts field by field; a field element refuses a non-canonical value
#      by throwing. So a payload whose LAST field element is 0xff..ff is parsed in full, converted to
#      its end, and refused before anything is simulated. Its wall time, less a one-byte payload's
#      (the error path alone), is the decode. Bounded as a FRACTION of a resident transaction timed
#      interleaved in the same process, which barely contains a decode (its input is 1.9 KB) and
#      so is not inflated by a slower one: the host's speed cancels and the decode's does not.
#
# WHY THIS IS NOT ONE NUMBER. A crossing costs a fixed amount plus something per byte, and the two
# shapes differ in BOTH: the resident arm makes few crossings with a small payload, the chatty arm
# makes few crossings with a huge one or many crossings with small ones. Reporting "msgpack costs
# X" would hide exactly the term the decision turns on.
#
# NOTHING HERE IS ASSERTED AS A MICROSECOND BUDGET. Absolute times are a property of this host. The
# assertions are on the SHAPE of the numbers — that a bigger payload costs more than a smaller one,
# that a crossing costs something, that the per-crossing cost is in the range a wasm call can
# plausibly be in — and on the numbers being present at all. The values are recorded for the
# write-up.

set -uo pipefail
TEST_NAME=test_msgpack_encode_decode_cost
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m15_shapes.sh"

M15_TREE="$(m15_tree)"; m6_tree_or_die M15_TREE
TREE="$M15_TREE"
m15_build_wasm "$TREE";   assert_eq "the wasm build succeeded" "0" "$M15_WASM_BUILD_RC"
m15_build_native "$TREE"; assert_eq "the native build succeeded" "0" "$M15_NATIVE_BUILD_RC"
m15_make_inputs "$TREE";  assert_eq "the driver emitted its inputs" "0" "$?"
WASM="$(m15_wasm_module "$TREE")"
INPUTS="$(m15_reactor_inputs)"

N="${M15_NULLCROSSING_N:-200000}"
OUT="$M15_WORK/msgpack.txt"
m15_host "$WASM" "$INPUTS" msgpack "$OUT" "$M15_REPRESENTATIVE" 5 "$N" "${M15_DECODE_ROUNDS:-25}"
assert_eq "the msgpack host exited 0" "0" "$?"
assert_eq "it ran to the end" "1" "$(m15_key "$OUT" msgpack.done)"
assert_eq "and wrote nothing from the failure vocabulary to stderr (D11: the AVM logs there)" "0" "$(m15_stderr_unexpected "$OUT.err")"

# ---------------------------------------------------------------------------
# 1. The null crossing.
# ---------------------------------------------------------------------------
assert_eq "the null crossing was measured over the loop count asked for" "$N" \
  "$(m15_key "$OUT" msgpack.nullCrossing.n)"
assert_eq "three times" "3" "$(grep -c '^msgpack\.nullCrossing\.us\.' "$OUT" || true)"
NS="$(m15_key "$OUT" msgpack.nullCrossing.nsPerCrossing)"
case "$NS" in ''|*[!0-9]*) die "no per-crossing figure (got '$NS')" ;; esac
note "one empty crossing costs about ${NS} ns on this host"
# It costs something, and it is not absurd. A zero would mean the loop was optimised away and the
# measurement is of nothing; a microsecond-plus would mean something other than a wasm call was
# being timed. Both bounds are wide: this is a sanity range, not a budget.
assert_ge "a crossing is not free" 1 "$NS"
assert_true "and it is a wasm call rather than something else being timed" test "$NS" -lt 2000

# ---------------------------------------------------------------------------
# 2. The transport, at the two sizes the two shapes carry.
# ---------------------------------------------------------------------------
FASTB="$(m15_key "$OUT" msgpack.transport.fast.bytes)"
PROVB="$(m15_key "$OUT" msgpack.transport.proving.bytes)"
FASTUS="$(m15_key "$OUT" msgpack.transport.fast.us50)"
PROVUS="$(m15_key "$OUT" msgpack.transport.proving.us50)"
for v in "$FASTB" "$PROVB" "$FASTUS" "$PROVUS"; do
  case "$v" in ''|*[!0-9]*) die "the transport measurement is missing a number (got '$v')" ;; esac
done
note "transport of 50 blobs: $FASTB bytes in ${FASTUS}us, $PROVB bytes in ${PROVUS}us"
assert_eq "the two sizes are the two shapes' actual input sizes" \
  "$(m15_key "$OUT" msgpack.fastInputBytes) $(m15_key "$OUT" msgpack.provingInputBytes)" \
  "$FASTB $PROVB"
assert_ge "the chatty arm's payload is at least fifty times the resident arm's" \
  $((FASTB * 50)) "$PROVB"
# The bigger payload costs more to move. Asserted as a direction, because the factor is a property
# of this host's memcpy and allocator.
assert_true "and moving it costs more" test "$PROVUS" -gt "$FASTUS"

# ---------------------------------------------------------------------------
# 3. The decode, on its own.
# ---------------------------------------------------------------------------
assert_eq "the host decode was timed five times" "5" "$(grep -c '^msgpack\.hostDecode\.us\.' "$OUT" || true)"
DEC="$(m15_key "$OUT" msgpack.hostDecode.medianUs)"
RB="$(m15_key "$OUT" msgpack.resultBytes)"
case "$DEC" in ''|*[!0-9]*) die "no host-decode figure (got '$DEC')" ;; esac
case "$RB" in ''|*[!0-9]*) die "no result size (got '$RB')" ;; esac
note "the host decodes a ${RB}-byte result in ${DEC}us"
assert_ge "the result blob is not empty" 100 "$RB"
assert_ge "and decoding it costs something" 1 "$DEC"

# ---------------------------------------------------------------------------
# 4. THE MODULE'S OWN DECODE of its input, separately from execution.
# ---------------------------------------------------------------------------
assert_eq "the module decode was timed over the rounds asked for, less the warm-up" \
  "$(( $(m15_key "$OUT" msgpack.moduleDecode.rounds) - $(m15_key "$OUT" msgpack.moduleDecode.warmupRounds) ))" \
  "$(m15_key "$OUT" msgpack.moduleDecode.proving.last.samples)"
assert_ge "over at least fifteen timed rounds" 15 "$(m15_key "$OUT" msgpack.moduleDecode.proving.last.samples)"
# The refusal came from the corrupted field, so the decode reached it; the error path's own refusal
# is a different one, so it did not.
for lbl in fast proving; do
  assert_eq "$lbl: the corrupted payload was refused at the field element that was corrupted" \
    '"msgpack field deserialization: non-canonical encoding (value >= modulus)"' \
    "$(m15_key "$OUT" "msgpack.moduleDecode.$lbl.last.message")"
  assert_false "$lbl: and the one-byte payload was refused for something else, before any parse" \
    test "$(m15_key "$OUT" "msgpack.moduleDecode.$lbl.nil.message")" = "$(m15_key "$OUT" "msgpack.moduleDecode.$lbl.last.message")"
done
FF_PROV="$(m15_key "$OUT" msgpack.moduleDecode.proving.fieldElements)"
TAIL_PROV="$(m15_key "$OUT" msgpack.moduleDecode.proving.unconvertedTailBytes)"
assert_ge "the hinted input carries thousands of field elements to convert" 1000 "$FF_PROV"
# What follows the last field element is not converted. It is under one percent of the payload.
assert_true "and what is left unconverted after the last one is under 1% of the payload" \
  test $((TAIL_PROV * 100)) -lt "$PROVB"

um() { m15_key "$OUT" "msgpack.moduleDecode.$1.medianUs"; }
for k in fast.last fast.first fast.nil proving.last proving.first proving.nil fast.simulate proving.simulate; do
  case "$(um "$k")" in ''|*[!0-9.]*) die "no module-decode median for $k (got '$(um "$k")')" ;; esac
done
# decode = refused-at-the-last-field minus the error path alone, in tenths of a microsecond.
DEC_FAST="$(awk -v a="$(um fast.last)" -v b="$(um fast.nil)" 'BEGIN { printf "%d", (a - b) * 10 }')"
DEC_PROV="$(awk -v a="$(um proving.last)" -v b="$(um proving.nil)" 'BEGIN { printf "%d", (a - b) * 10 }')"
SIM_RES="$(awk -v a="$(um fast.simulate)" 'BEGIN { printf "%d", a * 10 }')"
SIM_HINT="$(awk -v a="$(um proving.simulate)" 'BEGIN { printf "%d", a * 10 }')"
note "the module decodes ${FASTB} B in $(um fast.last)us and ${PROVB} B in $(um proving.last)us (error path alone $(um fast.nil)/$(um proving.nil)us);"
note "  a resident transaction takes $(um fast.simulate)us, the hinted one $(um proving.simulate)us"
note "  decode as a share of a resident transaction, in basis points: fast $(m15_ratio_x100 $((DEC_FAST * 100)) "$SIM_RES"), hinted $(m15_ratio_x100 $((DEC_PROV * 100)) "$SIM_RES")"
note "  and the hinted decode is $(m15_ratio_x100 "$DEC_PROV" "$SIM_HINT")% of the hinted simulation it precedes (reported, not bounded)"
# The measurement is of a decode: it is more than the error path, it grows with the payload, and
# conversion really progressed — the first field element corrupted is refused sooner than the last.
assert_true "the hinted decode is at least ten times the error path alone" \
  test "$DEC_PROV" -ge "$(awk -v b="$(um proving.nil)" 'BEGIN { printf "%d", b * 100 }')"
assert_true "and the bigger payload costs more to decode than the smaller" test "$DEC_PROV" -gt "$DEC_FAST"
assert_true "corrupting the FIRST field element is refused sooner than the last, so conversion ran to the end" \
  awk -v a="$(um proving.first)" -v b="$(um proving.last)" 'BEGIN { exit !(a < b) }'
# And it is a PART of the simulation that decodes it, not something larger.
assert_true "the hinted decode is less than the whole hinted simulation" test "$DEC_PROV" -lt "$SIM_HINT"
# THE BOUNDS, as fractions of a resident transaction timed interleaved with them. The shipped shape's
# claim is that its boundary is negligible next to its execution: decoding its own 1.9 KB input is
# under 1% of the transaction. And the chatty-batched arm's 191 KB input — a hundred times the bytes
# — still decodes in under 5% of one; the decode is what that arm pays per byte. Both bounds hold
# with a margin of several times on this host (the notes above give the measured shares), so they
# are crossed by a decode that became several times slower and not by load.
assert_true "the module's decode of the resident input is under 1% of a resident transaction" \
  test $((DEC_FAST * 100)) -lt "$SIM_RES"
assert_true "and its decode of the hinted input is under 5% of a resident transaction" \
  test $((DEC_PROV * 20)) -lt "$SIM_RES"

# ---------------------------------------------------------------------------
# THE COMPOSITION, which is the point of measuring the three separately: the crossing cost of a
# whole transaction in the chatty shape is (crossings x per-crossing) and it is computed here from
# two independently measured numbers rather than asserted from one.
# ---------------------------------------------------------------------------
# Its own file, produced by this run. Reusing a `crossings.txt` another check happened to leave
# behind would be depending on state this check did not produce — which is the defect M15's own
# carried fix is about, one level down.
XOUT="$M15_WORK/crossings-for-msgpack.txt"
m15_host "$WASM" "$INPUTS" crossings "$XOUT"
assert_eq "the crossings host exited 0" "0" "$?"
assert_eq "and ran to the end" "1" "$(m15_key "$XOUT" crossings.done)"
XN="$(m15_key "$XOUT" "crossings.$M15_REPRESENTATIVE.total")"
case "$XN" in ''|*[!0-9]*) die "no crossing count for $M15_REPRESENTATIVE" ;; esac
TOTAL_NS=$((XN * NS))
note "$M15_REPRESENTATIVE: $XN crossings x ${NS} ns = ${TOTAL_NS} ns of pure boundary per transaction"
assert_ge "the composed figure is positive" 1 "$TOTAL_NS"
# The composed figure is REPORTED, not bounded. Its two terms are each bounded already — a crossing
# under 2,000 ns above, and a transaction's hinted crossings under M15's budget of
# 32 (M15_CROSSING_BUDGET) in verify_boundary_crossing_budget — and their product is then below 64 us
# before any bound is written here, so a ceiling of 100 us on it could not be reached by anything
# those two let through. The module's own decode of its input is section 4.
note "the composed per-transaction boundary figure is implied by the two bounds above and is not asserted on its own"

assert_file "the boundary write-up exists" "$M15_WRITEUP"
assert_true "and it separates the encode/decode cost from execution rather than merging them" \
  grep -q 'null crossing' "$M15_WRITEUP"

finish
