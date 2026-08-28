#!/usr/bin/env bash
# e2e_browser_container_opcodes_match_native
#
# M29's second entry: the same transaction executed NATIVELY and in the BROWSER yields the same step
# stream, byte-identical after the known-divergent fields are excluded — and the exclusion list is
# EMPTY, which is a measurement rather than a convenience.
#
# ===========================================================================================
# WHAT "THE SAME TRANSACTION" MEANS HERE, AND WHY IT IS NOT ASSEMBLED TWICE.
# ===========================================================================================
#
# `avm_differential reactorinputs` — M12's mode — prints, per corpus program, the four msgpack blobs
# that seed the resident DBs and an `AvmFastSimulationInputs` with `collect_execution_steps = true`.
# `avm_differential steps` — M9's mode — prints every `ExecutionStep` the NATIVE x86-64 build
# produced for the same program, one line per record, all five fields.
#
# The page is handed the FIRST and is compared against the SECOND. Both come out of the same binary
# in the same run of this check, so what is left in the difference is the interpreter, the wasm
# target and the msgpack boundary — and not two independent assemblers of a transaction, which is
# what a page that built its own would have made this a test of.
#
# ===========================================================================================
# THE EXCLUSION LIST IS EMPTY, AND M26'S REVIEW IS WHY THAT SENTENCE IS HERE.
# ===========================================================================================
#
# M26's review recorded how an exclusion list hides the bug it excludes. `ExecutionStep` carries
# `(context_id, contract_address, pc, opcode, gas_used)` and the comparison is over the driver's own
# rendering of all five, whole line. There is nothing excluded, so there is no exclusion to keep a
# test alive for; what IS asserted is that the comparator can find a difference, by feeding it one
# altered record and requiring exactly one mismatch.
#
# ===========================================================================================
# AND THE PAGE IS THE SUBJECT. M12 ALREADY DID THIS IN NODE.
# ===========================================================================================
#
# `test_avm_reactor_step_stream_batching` compares the reactor's stream against the native driver's
# per record on NODE. What M29 adds is the browser: a different engine, a different WASI shim
# (`browser/src/wasi.ts` rather than `node:wasi`), a module that arrived over HTTP and was compiled
# by `WebAssembly.compileStreaming`, and a page that has already been asked to do other work. A
# claim about the browser has to be measured in a browser.
#
# Run: just verify-m29-native-parity

TEST_NAME="e2e_browser_container_opcodes_match_native"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m23_chain.sh"
. "$VERIFY_DIR/lib_m27_browser.sh"
. "$VERIFY_DIR/lib_m12_reactor.sh"
. "$VERIFY_DIR/lib_m29_steps.sh"

m29_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m29_require_arms
mkdir -p "$M29_WORK"

echo "== 1. both sides were produced HERE, by the binary this check located"

note "native driver: $M29_NATIVE_BIN (sha256 ${M29_NATIVE_SHA:0:16}…)"
assert_file "the native avm_differential exists" "$M29_NATIVE_BIN"
assert_file "…and it produced a steps transcript in this run" "$(m29_native_steps)"
assert_file "…and the reactor inputs the page was handed" "$(m29_parity_inputs)"
# THE TRANSCRIPT MUST BE COMPLETE, AND THIS IS A REFUSAL RATHER THAN AN ASSERTION.
#
# M9 has a recorded truncation flake — five sightings, four different truncation points — and a
# comparison over a short transcript produces a page of red assertions that each read like a
# discovery about the interpreter when the whole of it is a fact about the run. M21 built
# `require_complete_transcript` for exactly this and pins, by census, that every check comparing one
# transcript against another calls it BEFORE comparing. This check is the sixth such comparer and is
# on that list; the first draft asserted the sentinel by hand, which is the eighth spelling of the
# question M21's milestone set out to unify, and M21's own census caught it in M29's sweep.
require_complete_transcript "$(m29_native_steps)" avmSteps.done "the native driver's"
NATIVE_TXT="$(cat "$(m29_native_steps)")"
assert_true "the native transcript names the observation hook as compiled in" \
  str_has_line "$NATIVE_TXT" 'avmSteps.observerCompiledIn 1'

echo "== 2. the page ran the same program from the same bytes"

PROGRAM="$(m27_arm nativeParity program)"
COUNT="$(m27_arm nativeParity count)"
DECODED="$(m27_arm nativeParity decoded)"
CROSSINGS="$(m27_arm nativeParity crossings)"
BATCH="$(m27_arm nativeParity batchRecords)"
ABI="$(m27_arm nativeParity abiVersion)"
EXECUTED="$(m27_arm nativeParity instructionsExecuted)"
INPUTS="$(m27_arm nativeParity inputs)"
note "the page ran '$PROGRAM': $COUNT record(s), $CROSSINGS crossing(s) of $BATCH, ABI v$ABI"

assert_eq "the page ran the program this check produced inputs for" "$M29_PARITY_PROGRAM" "$PROGRAM"
assert_eq "…from the inputs file this check wrote" "$(m29_parity_inputs)" "$INPUTS"
assert_eq "…and the module answered M9's measured record count for it" "$M29_PARITY_RECORDS" "$COUNT"
assert_eq "…decoding every one of them" "$COUNT" "$DECODED"
assert_eq "…at exactly ceil(count / batch) crossings" "$(( (COUNT + BATCH - 1) / BATCH ))" "$CROSSINGS"
assert_eq "…and the AVM's own statistic agrees with the record count" "$COUNT" "$EXECUTED"
assert_eq "…through the reactor ABI version the driver was built against" "1" "$ABI"
# THE PAGE FETCHED THE MODULE AND THE BLOBS AND NOTHING LARGE, so the differential arm is subject to
# the same DD-11 discipline as every other arm.
assert_eq "…having fetched no barretenberg chunk to do it" "[]" "$(m27_arm nativeParity barretenbergRequests)"
assert_eq "…with no page error" "[]" "$(m27_arm nativeParity pageErrors)"

echo "== 3. THE COMPARISON, PER RECORD, WITH AN EMPTY EXCLUSION LIST"

BROWSER_RECORDS="$M29_WORK/browser-$PROGRAM.records"
python3 - "$M27_ARMS" >"$BROWSER_RECORDS" <<'PY'
import json, sys
for r in json.load(open(sys.argv[1]))['arms']['nativeParity']['records']:
    print(r)
PY
BROWSER_RC=$?
assert_eq "the page's per-record transcript was extracted" "0" "$BROWSER_RC"
BROWSER_LINES="$(grep -c . "$BROWSER_RECORDS" || true)"
assert_eq "…and it is as long as the module's own count" "$COUNT" "$BROWSER_LINES"

NATIVE_RECORDS="$M29_WORK/native-$PROGRAM.records"
m29_records "$(m29_native_steps)" "steps.$PROGRAM." >"$NATIVE_RECORDS"
NATIVE_LINES="$(grep -c . "$NATIVE_RECORDS" || true)"
note "native $NATIVE_LINES record(s) vs browser $BROWSER_LINES record(s)"
assert_eq "the native driver printed the same number of records" "$COUNT" "$NATIVE_LINES"

CMP_OUT="$M29_WORK/compare.txt"
python3 "$VERIFY_DIR/_m29_record_compare.py" "$NATIVE_RECORDS" "$BROWSER_RECORDS" >"$CMP_OUT"
CMP_RC=$?
assert_eq "the comparator ran" "0" "$CMP_RC"
m29_cmp() { awk -F'\t' -v k="$1" '$1 == k { print $2; found = 1 } END { if (!found) print "MISSING" }' "$CMP_OUT"; }

note "$(m29_cmp compared) compared, $(m29_cmp mismatches) mismatch(es), $(m29_cmp excluded) field(s) excluded"
assert_eq "every record was compared" "$COUNT" "$(m29_cmp compared)"
assert_eq "…field for field, with NOTHING excluded" "0" "$(m29_cmp excluded)"
# AND THE COMPARISON IS NOT SHALLOW: the residue is what the parser could not PLACE, and a regex
# too narrow for its input silently shortens both sides equally. It is printed by the comparator
# (`CAMPAIGN-BRIEF.md`'s "write scanners that PRINT the residue") and was read by nothing until
# M29's review; a zero here is what says all 38,903 lines were parsed into six fields each rather
# than dropped into a bucket nobody looked in.
assert_eq "…having placed every line of the native transcript into six fields" "0" "$(m29_cmp leftResidue)"
assert_eq "…and every line of the browser's" "0" "$(m29_cmp rightResidue)"
assert_eq "…and the browser's stream is the native one, record for record" "0" "$(m29_cmp mismatches)"
assert_eq "…including the first" "$(head -1 "$NATIVE_RECORDS")" "$(head -1 "$BROWSER_RECORDS")"
assert_eq "…and the last" "$(tail -1 "$NATIVE_RECORDS")" "$(tail -1 "$BROWSER_RECORDS")"

echo "== 4. THE COMPARATOR'S OWN DISCRIMINATING POWER"

# A per-record comparison that reports zero over a corrupted input is not a comparison. Three
# corruptions, one per class, because a comparator can be blind to one field while seeing another:
# a changed CONTEXT, a changed OPCODE, and a DROPPED record.
#
# THE EXPECTATION IS BASE + 1, NOT 1, AND THAT IS A CORRECTION A MUTATION FORCED. These controls
# corrupt a copy of the SUBJECT, so if the subject is already wrong they inherit its mismatches.
# Written as `== 1` they read as failures of the CONTROL when the real finding is a failure of the
# subject: mutation M4 altered one record in the parity arm and produced four red assertions, of
# which two were these controls reporting 2 where 1 was expected — noise on top of the two that
# actually said what was wrong. `BASE_MM` is the subject's own mismatch count, asserted zero above;
# a control must add EXACTLY one to it, whatever it is.
BASE_MM="$(m29_cmp mismatches)"
CTL_DIR="$M29_WORK/controls"
rm -rf "$CTL_DIR"; mkdir -p "$CTL_DIR"

sed '17s/^ctx=1 /ctx=9 /' "$BROWSER_RECORDS" >"$CTL_DIR/ctx.records"
assert_false "the context control really differs from the subject" cmp -s "$BROWSER_RECORDS" "$CTL_DIR/ctx.records"
python3 "$VERIFY_DIR/_m29_record_compare.py" "$NATIVE_RECORDS" "$CTL_DIR/ctx.records" >"$CTL_DIR/ctx.txt"
assert_eq "one altered context id adds exactly one mismatch" "$((BASE_MM + 1))" \
  "$(awk -F'\t' '$1 == "mismatches" { print $2 }' "$CTL_DIR/ctx.txt")"

# THE EXCLUSION MACHINERY, EXERCISED IN BOTH DIRECTIONS — because until M29's review the assertion
# "with NOTHING excluded" above read `len(sys.argv[3:])` of an invocation THIS FILE makes with no
# arguments, so it reported a property of its own call site and could not fail. An empty exclusion
# list is only a claim worth making if a non-empty one is a thing the instrument can produce and if
# excluding a field demonstrably changes the answer. Both are measured here, over the ctx-corrupted
# copy whose one mismatch is known from the assertion above.
python3 "$VERIFY_DIR/_m29_record_compare.py" "$NATIVE_RECORDS" "$CTL_DIR/ctx.records" ctx \
  >"$CTL_DIR/ctx-excluded.txt"
assert_eq "the comparator reports the SIZE of an exclusion list it is actually given" "1" \
  "$(awk -F'\t' '$1 == "excluded" { print $2 }' "$CTL_DIR/ctx-excluded.txt")"
assert_eq "…naming the excluded field rather than only counting it" "ctx" \
  "$(awk -F'\t' '$1 == "excludedField" { print $2 }' "$CTL_DIR/ctx-excluded.txt")"
assert_eq "…and excluding the field the corruption is IN hides that corruption, which is why the \
list above is asserted empty" "$BASE_MM" \
  "$(awk -F'\t' '$1 == "mismatches" { print $2 }' "$CTL_DIR/ctx-excluded.txt")"

sed '23s/ op=\([0-9]*\) / op=99 /' "$BROWSER_RECORDS" >"$CTL_DIR/op.records"
assert_false "the opcode control really differs from the subject" cmp -s "$BROWSER_RECORDS" "$CTL_DIR/op.records"
python3 "$VERIFY_DIR/_m29_record_compare.py" "$NATIVE_RECORDS" "$CTL_DIR/op.records" >"$CTL_DIR/op.txt"
assert_eq "one altered opcode adds exactly one mismatch" "$((BASE_MM + 1))" \
  "$(awk -F'\t' '$1 == "mismatches" { print $2 }' "$CTL_DIR/op.txt")"

sed '5d' "$BROWSER_RECORDS" >"$CTL_DIR/short.records"
python3 "$VERIFY_DIR/_m29_record_compare.py" "$NATIVE_RECORDS" "$CTL_DIR/short.records" >"$CTL_DIR/short.txt"
assert_eq "a DROPPED record is reported as a length disagreement, not compared away" "1" \
  "$(awk -F'\t' '$1 == "lengthDiffers" { print $2 }' "$CTL_DIR/short.txt")"
assert_ge "…and it is not silently zero mismatches either" 1 \
  "$(awk -F'\t' '$1 == "mismatches" { print $2 }' "$CTL_DIR/short.txt")"

# AND THE COMPARATOR MUST NOT AGREE WITH A DIFFERENT PROGRAM. Zero over the right pairing is only
# evidence if a wrong pairing is not also zero — the "both sides read, both sides degenerate" shape.
OTHER="$M29_WORK/native-other.records"
m29_records "$(m29_native_steps)" "steps.add." >"$OTHER"
assert_ge "another corpus program's transcript is non-empty" 1 "$(grep -c . "$OTHER" || true)"
python3 "$VERIFY_DIR/_m29_record_compare.py" "$OTHER" "$BROWSER_RECORDS" >"$CTL_DIR/other.txt"
assert_eq "…and comparing against the WRONG program is a length disagreement" "1" \
  "$(awk -F'\t' '$1 == "lengthDiffers" { print $2 }' "$CTL_DIR/other.txt")"

m29_finish
