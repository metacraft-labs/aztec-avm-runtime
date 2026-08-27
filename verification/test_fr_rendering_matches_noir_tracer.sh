#!/usr/bin/env bash
# M25 verification, OQ-4: how a 254-bit field element renders, cross-checked against what the Noir
# tracer does for `Field` so the two halves of a Form B recording agree.
#
#   verification/test_fr_rendering_matches_noir_tracer.sh     (or: just verify-fr-rendering)
#
# ---------------------------------------------------------------------------
# THE NAME PROMISES A CROSS-HALF CONSISTENCY REQUIREMENT, NOT A FORMATTING PREFERENCE, AND WHAT
# THIS CHECK FOUND IS THAT THE TWO HALVES CANNOT AGREE BY IMITATION.
#
# The Noir tracer renders `Field` as `ValueRecord::Int { i: to_i128() as i64 }`, and `to_i128`
# PANICS above 127 bits. An Aztec contract address is a full-width 254-bit field. So "do what the
# Noir tracer does" is not an available answer; the check therefore asserts THREE things, and each
# fails for a different reason:
#
#   1. What the Noir tracer actually does, read out of the Noir checkout. If it changes — and §4.4
#      of SOURCE-MAPPING.md says it must, in M26 — this goes red and the document is what it is
#      disagreeing with. That is the point of pinning it.
#   2. Which renderings the PINNED READERS can decode, by running both readers over five
#      containers that differ in one variable and share a control. This is where the BigInt
#      refusal is a measurement rather than a claim.
#   3. What this runtime emits, decoded out of a container by the reference reader, not read out
#      of the Rust source that wrote it.
#
# A mutation that changes the rendering must therefore fail (3); a mutation that "fixes" the reader
# must fail (2); a change to the Noir half must fail (1). None of the three can cover for another.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=test_fr_rendering_matches_noir_tracer
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m25_trace.sh"

m24_summary_on_abnormal_exit

DOC="$REPO_ROOT/SOURCE-MAPPING.md"
assert_file "the verdict document exists" "$DOC"
DOC_TEXT="$(cat "$DOC" 2>/dev/null)"

# ===========================================================================
# PART 1 — what the NOIR tracer does, read from the Noir checkout
#
# THE OTHER HALF OF A FORM B RECORDING IS A SIBLING REPOSITORY, NOT A DOCUMENT. Its absence is a
# `die` and not a skip: a cross-half consistency check with one half missing is a check about one
# half, and this campaign has met that shape as "an absence asked of a tree that excludes the
# subject by construction".
# ===========================================================================
NOIR="$WORKSPACE_ROOT/noir"
[ -d "$NOIR/tooling/tracer/src" ] || \
  die "no Noir tracer at $NOIR/tooling/tracer/src. OQ-4 is a statement about BOTH halves of a
     Form B recording, and one of them is this checkout. Asserting only what this runtime does
     would be a formatting preference wearing a consistency requirement's name."

GLUE="$(cat "$NOIR/tooling/tracer/src/tracer_glue.rs" 2>/dev/null)"
FIELDEL="$(cat "$NOIR/acvm-repo/acir_field/src/field_element.rs" 2>/dev/null)"
assert_ge "the Noir tracer's value glue reads back" 300 "$(printf '%s\n' "$GLUE" | grep -c . || true)"
assert_ge "…and acir_field's FieldElement reads back" 300 "$(printf '%s\n' "$FIELDEL" | grep -c . || true)"

assert_true "the Noir tracer renders Field as ValueRecord::Int over to_i128() as i64" \
  str_has_sub "$GLUE" 'ValueRecord::Int { i: field_value.to_i128() as i64, type_id }'
assert_true "…under the type (TypeKind::Int, \"Field\"), which is the type this runtime reuses" \
  str_has_sub "$GLUE" 'PrintableType::Field => (TypeKind::Int, "Field".to_string()),'
assert_true "…and to_i128 PANICS rather than truncating, above 127 bits" \
  str_has_sub "$FIELDEL" 'panic!("field element too large for i128");'
assert_true "…gated on fits_in_i128, which is num_bits <= 127" \
  str_has_sub "$FIELDEL" 'num_bits <= 127'
# The negative control for the four above.
assert_false "a needle in neither Noir file does not match" \
  str_has_sub "$GLUE$FIELDEL" 'ValueRecord::BigInt { b: field_value'
# …so the Noir half cannot render a full-width field TODAY, and the document says so.
assert_true "the document records that 'match it exactly' is not available, with its reason" \
  str_has_sub "$DOC_TEXT" 'cannot render a full-width 254-bit field at all today'
assert_true "…and records the change M26 must make, by file and line" \
  str_has_sub "$DOC_TEXT" 'noir/tooling/tracer/src/tracer_glue.rs:148-152'

# ===========================================================================
# PART 2 — WHICH RENDERINGS THE PINNED READERS CAN DECODE
#
# Five containers, one control, one subject each. Both readers over all five, so a reader that
# reads names without decoding values cannot make a broken arm look green — which is exactly what
# `ct-split-probe` does for the BigInt arm, and that fact is asserted rather than worked around.
# ===========================================================================
m24_require_module
m24_require_readers
if [ ! -s "$M25_WORK/oq4-bigint.ct" ] || [ "$VERIFY_DIR/oq4_rendering_probe.rs" -nt "$M25_WORK/oq4-bigint.ct" ]; then
  m24_require_bounded_logged "$M24_BUILD_TIMEOUT" "the OQ-4 rendering probe" \
    "$VERIFY_DIR/build_oq4_rendering_probe.sh" \
    || die "verification/build_oq4_rendering_probe.sh failed; see $M24_WORK/bounded-run.log"
fi

ARMS="int low64 bigint string raw"
READ_OK=0
READ_REFUSED=0
for arm in $ARMS; do
  f="$M25_WORK/oq4-$arm.ct"
  assert_file "the probe produced the $arm arm's container" "$f"
  out="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$f")"
  rc="$(printf '%s\n' "$out" | head -1)"
  body="$(printf '%s\n' "$out" | tail -n +2)"
  # THE CONTROL IS IN EVERY ARM AND IS ASSERTED IN EVERY ARM THAT DECODES. Without it, "this
  # container decoded" would be a statement about a file that opened.
  case "$arm" in
    bigint)
      assert_eq "the $arm arm is REFUSED by ct-print at the pinned reader revision" "1" "$rc"
      READ_REFUSED=$((READ_REFUSED + 1))
      assert_true "…and the refusal names the CBOR major-type mismatch, not a generic failure" \
        str_has_sub "$body" 'cbor: expected byte string (major 2), got major 3'
      # The other reader reads it GREEN, which is the finding rather than a nuisance.
      probe="$(m24_split_probe "$f")"
      assert_true "ct-split-probe reports DONE ok over the SAME refused container" \
        str_has_line "$probe" "$(printf 'DONE\tok')"
      assert_true "…and lists both variables, because it names value records without decoding them" \
        str_has_sub "$probe" 'control,subject'
      ;;
    *)
      assert_eq "the $arm arm is READ by ct-print at the pinned reader revision" "0" "$rc"
      READ_OK=$((READ_OK + 1))
      assert_true "…and its control variable decoded, so the arm is attributable to its subject" \
        str_has_sub "$body" '"i": 42'
      ;;
  esac
done
assert_eq "four of the five renderings are readable" "4" "$READ_OK"
assert_eq "…and exactly one is refused" "1" "$READ_REFUSED"

# The two readable full-precision arms carry all 64 hex characters, which is the property that
# rules out `low64`. Asserted from the DECODED output, not from the probe's source.
FULL_HEX="$(m25_arm 'd["fieldRendering"]["expectedHex"]')"
assert_eq "the expected rendering is 0x plus 64 hex characters" "66" "${#FULL_HEX}"
for arm in string raw; do
  body="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$M25_WORK/oq4-$arm.ct" | tail -n +2)"
  assert_true "the $arm arm decodes to the full 254-bit value, all 64 characters" \
    str_has_sub "$body" "$FULL_HEX"
done
# …and `low64` decodes to something that is NOT it, which is what "lossy" means as a measurement.
LOW_BODY="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$M25_WORK/oq4-low64.ct" | tail -n +2)"
assert_false "the low64 arm does NOT carry the full value" str_has_sub "$LOW_BODY" "$FULL_HEX"
assert_true "…it carries M24's low-64-bit rendering of the same address" \
  str_has_sub "$LOW_BODY" "$(m25_arm 'd["fieldRendering"]["m24LowSixtyFour"]')"

# ===========================================================================
# PART 3 — WHAT THIS RUNTIME EMITS, decoded out of a container
#
# Read back through the reference reader rather than grepped out of `ct-writer/src/lib.rs`. A
# source grep would pass over a module that was never rebuilt, which is a live hazard here: the
# release module embeds panic Locations from that file, so its bytes move when its COMMENTS do.
# ===========================================================================
m25_require_arms
FIELD_CT="$(m25_arm 'd["fieldRendering"]["container"]')"
assert_file "the arms run wrote a field-rendering container" "$FIELD_CT"
FIELD_BODY="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$FIELD_CT")"
assert_eq "the reference reader reads it" "0" "$(printf '%s\n' "$FIELD_BODY" | head -1)"
FIELD_BODY="$(printf '%s\n' "$FIELD_BODY" | tail -n +2)"
assert_true "the variable is named contractAddress, not M24's contractAddressLow" \
  str_has_sub "$FIELD_BODY" '"name": "contractAddress"'
assert_false "…and the placeholder name is gone from the container" \
  str_has_sub "$FIELD_BODY" 'contractAddressLow'
assert_true "it is a String record" str_has_sub "$FIELD_BODY" '"kind": "String"'
assert_true "…carrying the full 254-bit value" str_has_sub "$FIELD_BODY" "$FULL_HEX"
assert_true "…and the type it points at is (tkInt, \"Field\"), the Noir tracer's own type record" \
  str_has_sub "$FIELD_BODY" '"kind": "tkInt",'
assert_true "…named Field" str_has_sub "$FIELD_BODY" '"lang_type": "Field"'
# NON-DEGENERACY: the assertions above would all pass over a container with one step and no
# address if `FULL_HEX` were empty, so the value's own shape is asserted too.
assert_true "the rendering is lowercase hex with no leading-zero stripping" \
  str_has_re "$FULL_HEX" '^0x[0-9a-f]{64}$'
assert_ge "the container is not an empty envelope" 1 "$(m25_arm 'd["fieldRendering"]["containerBytes"]')"

# ===========================================================================
# PART 4 — the document states the decision AND the rejected options' measurements
# ===========================================================================
assert_true "the verdict is stated as String plus the type it uses" \
  str_has_sub "$DOC_TEXT" '`0x` + 64 lowercase big-endian hex, in `ValueRecord::String`'
assert_true "the BigInt refusal's exact message is recorded" \
  str_has_sub "$DOC_TEXT" 'cbor: expected byte string (major 2), got major 3'
assert_true "…with its cause named at the pinned revision" \
  str_has_sub "$DOC_TEXT" 'String::serialize(&base64, s)'
assert_true "the split probe's green-over-a-broken-container finding is recorded" \
  str_has_sub "$DOC_TEXT" 'AND THE SPLIT PROBE READ THE BROKEN ONE GREEN'
assert_true "Raw is rejected with a reason rather than by omission" \
  str_has_sub "$DOC_TEXT" "Noir's escape hatch for values it *cannot* represent"
assert_true "M24's superseded rendering is kept so the change is a delta" \
  str_has_sub "$DOC_TEXT" "$(m25_arm 'd["fieldRendering"]["m24LowSixtyFour"]')"

m24_finish
