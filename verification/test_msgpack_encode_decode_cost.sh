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
m15_host "$WASM" "$INPUTS" msgpack "$OUT" "$M15_REPRESENTATIVE" 5 "$N"
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
# And it is small: under a hundred microseconds of boundary for a transaction. That is the number
# the decision turns on and it is asserted so a change to either term is caught here.
assert_true "the whole per-transaction boundary cost is under 100 us" test "$TOTAL_NS" -lt 100000

assert_file "the boundary write-up exists" "$M15_WRITEUP"
assert_true "and it separates the encode/decode cost from execution rather than merging them" \
  grep -q 'null crossing' "$M15_WRITEUP"

finish
