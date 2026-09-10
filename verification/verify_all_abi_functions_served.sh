#!/usr/bin/env bash
# verify_all_abi_functions_served
#
# M41 verification: all THIRTY-EIGHT ABI functions are present in BOTH modules and answer, compared
# AS A SET against `ct-host/src/abi.ts`'s four export lists.
#
# THE COUNT IS THIRTY-EIGHT AND IT IS COUNTED THREE WAYS, because the number in circulation was
# wrong. `grep -c 'pub extern "C" fn'` over `ct-writer/src/lib.rs` gives 26 — twelve of the
# thirty-eight are `pub unsafe extern "C" fn` and that needle cannot see them. So the count is
# taken from `#[unsafe(no_mangle)]`, from the sum of `abi.ts`'s four lists, and from the built
# module's own export table, and the three are asserted EQUAL AS SETS rather than as totals: two
# sets of the same size can still differ, and "38 = 38" would not notice.
#
# WHY BOTH MODULES. M41's requirement is that the ABI does not change and consumers do not change.
# A Path B module serving thirty-seven of thirty-eight would be a different ABI wearing the same
# name, and the missing one would surface in a host as `undefined is not a function` a long way
# from here.
#
# THE TWO CONTROLS THE MILESTONE ASKS FOR, both run:
#   * a FABRICATED export name is NOT found — so the search is a search and not a `true`.
#   * a REAL name REMOVED from the set is REPORTED MISSING — so the comparison discriminates in
#     the direction that matters, which is absence rather than presence.
#
# AND THEY ANSWER, not merely appear. Every one of the thirty-eight is CALLED by
# `verification/ct_writer_drive.mjs` on the way to a container, and this check asserts the driver's
# report enumerates them — an export table is a promise and a call is the evidence.
#
# Run: just verify-abi-functions-served

TEST_NAME="verify_all_abi_functions_served"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib_m41_writer.sh"
m41_summary_on_abnormal_exit

command -v node >/dev/null 2>&1 || die "node is required"
command -v python3 >/dev/null 2>&1 || die "python3 is required"

ABI_TS="$M41_HOST/src/abi.ts"
LIB_RS="$M41_CRATE/src/lib.rs"
assert_file "the host's ABI declaration is where it is expected" "$ABI_TS"
assert_file "the module's ABI implementation is where it is expected" "$LIB_RS"

# ---------------------------------------------------------------------------
# 1. The three enumerations.
# ---------------------------------------------------------------------------
TS_NAMES="$(python3 "$REPO_ROOT/verification/_m41_abi_names.py" --typescript "$ABI_TS")" \
  || die "the TypeScript export lists could not be read from $ABI_TS"
RS_NAMES="$(python3 "$REPO_ROOT/verification/_m41_abi_names.py" --rust "$LIB_RS")" \
  || die "the Rust no_mangle functions could not be read from $LIB_RS"

TS_COUNT="$(printf '%s\n' "$TS_NAMES" | grep -c .)"
RS_COUNT="$(printf '%s\n' "$RS_NAMES" | grep -c .)"
assert_eq "abi.ts's four lists sum to thirty-eight distinct names" "38" "$TS_COUNT"
assert_eq "lib.rs declares thirty-eight no_mangle entry points" "38" "$RS_COUNT"
assert_eq "and the two are the SAME set, not merely the same size" "$TS_NAMES" "$RS_NAMES"

# The wrong count, asserted as wrong. Not pedantry: `26` is the number the milestone was drafted
# with, and a check that never showed WHY it is wrong leaves the next reader to rediscover it.
NAIVE="$(grep -c 'pub extern "C" fn' "$LIB_RS" || true)"
assert_false "the naive grep does NOT see all thirty-eight, which is where 26 came from" \
  test "$NAIVE" -eq 38
m41_say "grep 'pub extern \"C\" fn' sees $NAIVE of $RS_COUNT; the other $((RS_COUNT - NAIVE)) are 'pub unsafe extern'"

# ---------------------------------------------------------------------------
# 2. Both modules export exactly those thirty-eight, plus `memory`.
# ---------------------------------------------------------------------------
m41_require_path_a
m41_require_path_b
m41_drive "$M41_PATH_A" path-a
m41_drive "$M41_PATH_B" path-b

# THE THIRTY-EIGHT ARE ASSERTED AS A SUBSET, AND EVERY EXTRA IS NAMED.
#
# `39` was the count until M41 advanced the `trace_format` pin: the writer's compressor became C
# libzstd, and `zstd-sys`'s wasm shim re-exports eight `rust_zstd_wasm_shim_*` symbols that Rust's
# allocator resolved. Path A has them; Path B does not, because its own libc shim is a static C
# archive and archive symbols are resolved without being exported.
#
# So the count is not relaxed — it is DECOMPOSED. Every export is one of the thirty-eight, or
# `memory`, or a shim symbol matched by its prefix, and anything else fails by name. That still
# catches an export appearing, which this campaign holds to be as much a finding as one
# disappearing.
for arm in path-a path-b; do
  EXPORTS="$(m41_report "$arm" moduleExports | python3 -c 'import json,sys; print("\n".join(sorted(json.load(sys.stdin))))')"
  COUNT="$(printf '%s\n' "$EXPORTS" | grep -c .)"
  SHIM="$(printf '%s\n' "$EXPORTS" | grep -c '^rust_zstd_wasm_shim_' || true)"
  m41_say "$arm: $COUNT exports = 38 ABI + memory + $SHIM compressor-shim"
  assert_eq "the $arm module exports the thirty-eight, memory, and $SHIM shim symbols — nothing else" \
    "$(( 39 + SHIM ))" "$COUNT"
  # `LC_ALL=C`, and it is not decoration: the extractor sorts in Python's byte order and a
  # locale-aware `sort` puts `ct_positions` before `ct_position_size` because it collates
  # underscores away. Two identical sets then compare unequal, and the failure reads as a missing
  # export rather than as two orderings.
  MINUS_MEMORY="$(printf '%s\n' "$EXPORTS" | grep -vx 'memory' | grep -v '^rust_zstd_wasm_shim_' | LC_ALL=C sort)"
  assert_eq "and what remains after memory and the shim IS abi.ts's set" "$TS_NAMES" "$MINUS_MEMORY"
done

# ---------------------------------------------------------------------------
# 3. THE TWO CONTROLS.
# ---------------------------------------------------------------------------
EXPORTS_B="$(m41_report path-b moduleExports)"
assert_not_contains "a fabricated export name is NOT found, so the search is a search" \
  '"ct_writer_kind_of_thing_that_does_not_exist"' "$EXPORTS_B"

# The removal control. One real name is taken OUT of the expected set and the comparison must
# report it — in the ABSENCE direction, which is the one a set comparison can get wrong by being
# a subset test.
WITHOUT_ONE="$(printf '%s\n' "$TS_NAMES" | grep -vx 'ct_source_step')"
MODULE_SET="$(m41_report path-b moduleExports | python3 -c 'import json,sys; print("\n".join(sorted(n for n in json.load(sys.stdin) if n != "memory" and not n.startswith("rust_zstd_wasm_shim_"))))')"
assert_false "a set with one real name removed does NOT compare equal to the module's" \
  test "$WITHOUT_ONE" = "$MODULE_SET"
MISSING="$(LC_ALL=C comm -13 <(printf '%s\n' "$WITHOUT_ONE") <(printf '%s\n' "$MODULE_SET"))"
assert_eq "and the difference is named, so the comparison says WHICH one" "ct_source_step" "$MISSING"

# ---------------------------------------------------------------------------
# 4. They ANSWER. The driver calls every one of the thirty-eight; its report is the evidence.
# ---------------------------------------------------------------------------
# The CORE, not the node wrapper. The wrapper reads a file and writes two; every call into the
# module is in the core, which is the module both the node arm and the browser arm import. This
# check pointed at the wrapper until the driver was split, and went red naming all thirty-eight at
# once — which is what a path that has stopped describing the artefact looks like.
DRIVER="$REPO_ROOT/verification/ct_writer_drive_core.mjs"
assert_file "the shared driver core exists" "$DRIVER"
assert_true "and it imports nothing, so a page can load it unchanged" \
  bash -c "! grep -qE \"^import \" '$DRIVER'"
UNCALLED=""
while IFS= read -r name; do
  [ -n "$name" ] || continue
  grep -q "x\.$name(" "$DRIVER" || UNCALLED="$UNCALLED $name"
done <<<"$TS_NAMES"
assert_eq "every one of the thirty-eight is CALLED by the driver, not merely exported" \
  "" "$UNCALLED"

# And the calls really happened in the Path B run, which is what makes the paragraph above a
# measurement rather than a reading of the driver's source.
assert_eq "the nop arms were driven and counted" "2" \
  "$(( $(m41_report path-b nopCallsAfter) - $(m41_report path-b nopCalls) ))"
assert_eq "ct_ingest refuses after the close" "-1" "$(m41_report path-b ingestAfterClose)"
assert_eq "and ct_ingest_control, its byte-for-byte duplicate, refuses identically" \
  "$(m41_report path-b ingestAfterClose)" "$(m41_report path-b ingestControlAfterClose)"
# `ct_free` has no return value, so the only assertable thing about it is that the driver got past
# it: a trap would have killed the process and `m41_drive` would have died naming the drive. The
# field is read WITHOUT a fallback, so a driver that stopped calling it reports an empty string
# here rather than a `True` this check supplied.
assert_eq "ct_free was called and the driver survived it" "True" "$(m41_report path-b freeReturned)"

finish
