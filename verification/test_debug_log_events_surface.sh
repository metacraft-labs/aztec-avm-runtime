#!/usr/bin/env bash
# test_debug_log_events_surface — M25.
#
# The verification entry: "An Aztec.nr `debug_log` call appears in the trace as a developer-facing
# event with its message and fields."
#
# ===========================================================================================
# WHAT WAS BLOCKING THIS AND WHY IT IS NOT ANY MORE.
# ===========================================================================================
#
# The campaign summary had this pinned as an `@aztec/pxe` question. It never was: `debug_logging`
# is a PUBLIC function and the logs are the AVM's. The residuals pass of 2026-08-31 measured the
# true state and found every piece present and exactly two things missing — nothing anywhere set
# `collectDebugLogs`, so the module ran with upstream's `false` default, and the transaction was
# not built. Both are supplied by `orchestration/src/token_block_driver.ts`, which builds the
# transaction with the vendored builder (RI-72) and opens ONE arm with the flag and one without.
#
# ===========================================================================================
# THE THREE THINGS THIS CHECK ASSERTS, AND THE CONTROL EACH ONE NEEDS.
# ===========================================================================================
#
#   1. THE LOGS SURFACE. Six of them, through `PublicProcessor`'s own `DebugLog[]` return.
#      *The control*: the identical transaction with `collectDebugLogs` false surfaces NONE, and
#      executes the SAME number of instructions — so the flag is what produces them and not some
#      difference in what ran. Without that arm, "six logs surfaced" is equally satisfied by a
#      runtime that surfaces logs for everything.
#
#   2. THE MESSAGES ARE THE CONTRACT'S. Compared against the strings extracted from the AvmTest
#      contract's own Noir SOURCE at the pinned `cpp` anchor, by `_avmtest_debug_logs.py`. A list
#      of expected strings typed into this file would be a constant that drifts away from the
#      contract silently, which is this campaign's most-repeated defect.
#      *The control*: the same extractor asked for `add_args_return`, a function with no logging
#      call, answers with an EMPTY list — so "the messages matched" is a comparison by an
#      instrument that has been seen to produce both answers. And the extractor's own residue
#      (any `logging::` line it could not classify) is asserted empty, so a call shape it cannot
#      place is a red line rather than a silent undercount.
#
#   3. THE FIELDS ARE THE CONTRACT'S. `debug_log_format("second: {1}", [1, 2, 3, 4])` must arrive
#      with those four values. Derived from the same source, converted from the `Fr` hex the
#      boundary carries.
#
# AND THE TRANSACTION IS ASSERTED TO HAVE RUN. A transaction that reverts at its first instruction
# reports `processed` — the campaign's deepest recorded defect — so the revert code, the executed
# instruction count and the fee are all read here. Six logs over a transaction that did nothing
# would be six logs from somewhere else.
#
# Run: just verify-debug-logs

TEST_NAME="test_debug_log_events_surface"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_token_blocks.sh"

tb_summary_on_abnormal_exit
tb_require_arms
tb_note_provenance

CPP_ANCHOR="$(python3 -c '
import json, sys
print(json.load(open(sys.argv[1]))["anchors"]["cpp"]["commit"])' "$REPO_ROOT/pins.json")"
AVMTEST_NR="noir-projects/labs/noir-contracts/contracts/test/avm_test_contract/src/main.nr"

case "$CPP_ANCHOR" in
  [0-9a-f][0-9a-f]*) : ;;
  *) die "pins.json does not name a cpp anchor commit" ;;
esac
SOURCE="$(git -C "$FORK_ROOT" show "$CPP_ANCHOR:$AVMTEST_NR" 2>/dev/null)" \
  || die "the fork at $FORK_ROOT has no $AVMTEST_NR at $CPP_ANCHOR
             (the layout moved; this check's premise is stale)"

note "AvmTest source $AVMTEST_NR at $CPP_ANCHOR"

# ---------------------------------------------------------------------------
# PART 0 — the accessor's own control, and the arms are the ones this check names
# ---------------------------------------------------------------------------

assert_eq "an arm that does not exist reads MISSING" "MISSING" "$(tb_arm noSuchArm collectDebugLogs)"
assert_eq "a block label that does not exist reads MISSING" \
  "MISSING" "$(tb_block debugLogsOn noSuchBlock revertCodes)"
assert_eq "the collecting arm ran exactly the one block this check reads" \
  '["debugLogging"]' "$(tb_block_labels debugLogsOn)"
assert_eq "the control arm ran the same one block" \
  '["debugLogging"]' "$(tb_block_labels debugLogsOff)"
assert_eq "the collecting arm was configured to collect" "true" "$(tb_arm debugLogsOn collectDebugLogs)"
assert_eq "the control arm was configured NOT to collect" "false" "$(tb_arm debugLogsOff collectDebugLogs)"
assert_eq "both arms ran against the same contract address, so the one variable is the flag" \
  "$(tb_arm debugLogsOn contractAddress)" "$(tb_arm debugLogsOff contractAddress)"

# ---------------------------------------------------------------------------
# PART 1 — the transaction RAN. Six logs over a transaction that did nothing are somebody else's.
# ---------------------------------------------------------------------------

assert_eq "the logging transaction was processed" \
  '["debugLogging"]' "$(tb_block debugLogsOn debugLogging processed)"
assert_eq "it did not revert" "0" "$(tb_block debugLogsOn debugLogging revertCodes.debugLogging)"
assert_eq "the module's own four-valued revert code agrees" \
  "0" "$(tb_block debugLogsOn debugLogging rawRevertCodes.0)"
COLLECT_STEPS="$(tb_block debugLogsOn debugLogging instructionsPerSimulation.0)"
assert_ge "the AVM executed a real dispatch rather than halting at instruction one" 100 "$COLLECT_STEPS"
assert_ge "the transaction was charged a fee" 1 "$(tb_block debugLogsOn debugLogging feeByTx.debugLogging)"

# ---------------------------------------------------------------------------
# PART 2 — the logs surface, and the FLAG is what makes them
# ---------------------------------------------------------------------------

SURFACED="$(tb_block debugLogsOn debugLogging debugLogs)"
SURFACED_COUNT="$(printf '%s' "$SURFACED" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"
CONTROL_COUNT="$(tb_block debugLogsOff debugLogging debugLogs \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')"

assert_eq "with collectDebugLogs the processor returned the contract's logs" "6" "$SURFACED_COUNT"
assert_eq "with the flag off the SAME transaction returns none" "0" "$CONTROL_COUNT"
# THE CONTROL'S OTHER HALF, and it is the half that makes the first one mean something: the two
# arms must have done the same WORK. Equal instruction counts say the flag changed what was
# reported and not what was executed.
assert_eq "the control executed exactly the same number of instructions" \
  "$COLLECT_STEPS" "$(tb_block debugLogsOff debugLogging instructionsPerSimulation.0)"
assert_eq "and did not revert either" "0" "$(tb_block debugLogsOff debugLogging revertCodes.debugLogging)"

# ---------------------------------------------------------------------------
# PART 3 — the messages and the fields are the CONTRACT'S, extracted from its own source
# ---------------------------------------------------------------------------

EXTRACT="$(printf '%s' "$SOURCE" | python3 "$VERIFY_DIR/_avmtest_debug_logs.py" debug_logging)" \
  || die "the debug-log extractor failed over the AvmTest source at $CPP_ANCHOR"
DECLARED_MESSAGES="$(printf '%s' "$EXTRACT" \
  | python3 -c 'import json,sys; print(json.dumps([c["message"] for c in json.load(sys.stdin)["calls"]],separators=(",",":")))')"
DECLARED_KINDS="$(printf '%s' "$EXTRACT" \
  | python3 -c 'import json,sys; print(json.dumps([c["kind"] for c in json.load(sys.stdin)["calls"]],separators=(",",":")))')"
DECLARED_FIELDS="$(printf '%s' "$EXTRACT" \
  | python3 -c 'import json,sys; print(json.dumps([c["fields"] for c in json.load(sys.stdin)["calls"]],separators=(",",":")))')"
RESIDUE="$(printf '%s' "$EXTRACT" \
  | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["unclassified"],separators=(",",":")))')"

assert_eq "the extractor placed every logging:: line in the contract's own function" "[]" "$RESIDUE"
assert_eq "the contract emits six logs of four kinds" \
  '["debug_log","debug_log_format","debug_log_format","debug_log","fatal_log","trace_log_format"]' \
  "$DECLARED_KINDS"

SURFACED_MESSAGES="$(printf '%s' "$SURFACED" \
  | python3 -c 'import json,sys; print(json.dumps([d["message"] for d in json.load(sys.stdin)],separators=(",",":")))')"
assert_eq "every message the AVM surfaced is the one the contract emits, in order" \
  "$DECLARED_MESSAGES" "$SURFACED_MESSAGES"

SURFACED_FIELDS="$(printf '%s' "$SURFACED" \
  | python3 -c '
import json, sys
print(json.dumps([[int(f, 16) for f in d["fields"]] for d in json.load(sys.stdin)], separators=(",", ":")))')"
assert_eq "and every field value is the one the contract passed" "$DECLARED_FIELDS" "$SURFACED_FIELDS"

# THE ONE MESSAGE WITH AN ESCAPE IN IT, ASSERTED ON ITS DECODED BYTES.
#
# It is the only one whose surfaced form can show that the boundary carried the BYTES rather than a
# rendering of them, and it has to be read through the accessor rather than out of the JSON list —
# the first version of this assertion compared a real newline against the list's `\n` ESCAPE and
# went red for a reason with nothing to do with the subject. Cheap direction, and it is why the
# assertion is here in its decoded form.
MULTILINE="$(tb_block debugLogsOn debugLogging debugLogs.3.message)"
assert_eq "the fourth log is the multi-line one, selected by position in the contract's own order" \
  "$(printf '%s' "$DECLARED_MESSAGES" | python3 -c 'import json,sys; print(json.load(sys.stdin)[3])')" \
  "$MULTILINE"
assert_eq "and it crossed the boundary as three lines rather than as an escape" \
  "3" "$(printf '%s\n' "$MULTILINE" | wc -l | tr -d ' ')"

# ---------------------------------------------------------------------------
# PART 4 — THE EXTRACTOR'S NEGATIVE CONTROL. It must be able to answer "none".
# ---------------------------------------------------------------------------

EMPTY="$(printf '%s' "$SOURCE" | python3 "$VERIFY_DIR/_avmtest_debug_logs.py" add_args_return)" \
  || die "the debug-log extractor failed over add_args_return"
assert_eq "asked for a function with no logging call, the extractor answers with none" \
  "[]" "$(printf '%s' "$EMPTY" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["calls"],separators=(",",":")))')"
assert_eq "and reports no residue there either" \
  "[]" "$(printf '%s' "$EMPTY" | python3 -c 'import json,sys; print(json.dumps(json.load(sys.stdin)["unclassified"],separators=(",",":")))')"

finish
