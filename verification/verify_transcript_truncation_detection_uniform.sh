#!/usr/bin/env bash
# verify_transcript_truncation_detection_uniform — M21
#
# THE FLAKE HAS TWO SIGHTINGS AND NO ESTABLISHED TRIGGER, SO THE DETECTION IS WHAT MUST BE UNIFORM.
#
# Sighting 1 (M9): the V8 step transcript stopped inside `burn` at record 16,719 of 38,915, `oob`
# produced no records, the terminal `avmSteps.done` sentinel never arrived, and the check emitted
# 32 red assertions with names like "oob recorded no steps" and "burn's last record is not the
# instruction that exhausted the gas".
# Sighting 2 (M8, found during M20's review): `revert-rerun.transcript` held 259 lines of 1,318,
# its first 259 byte-identical to the reference, and the check said "the module does not reproduce
# its own transcript".
# In both, stderr was COMPLETE and the next run passed. Both are facts about the RUN.
#
# WHAT THIS MILESTONE FOUND: the question was being asked in SEVEN different spellings.
#
#   1. `m9_completeness`                        lib_m9_observer.sh      (seven lines)
#   2. `m17_completeness`                       lib_m17_node_host.sh    (the same seven lines)
#   3. two `tail -1` comparisons                test_revert_program_does_not_trap_module.sh
#   4. `assert_contains "roundtrip.done 1"`     e2e_ts_wasm_result_decodes_as_upstream_types.sh
#   5. `assert_eq … "$(tail -1 "$WT_T")"`       verify_native_wasm_transcripts_identical.sh
#   6. `assert_eq … "$(m9_field … avmSteps.done)"`   test_observer_does_not_perturb.sh
#   7. `assert_eq … "$(m12_field … reactor.done)"`   test_avm_reactor_transcripts_match_driver.sh
#
# Seven spellings is seven chances for the eighth transcript check to be written without one, and
# only two of the seven REFUSED — the other five asserted, which produces a red line among other
# red lines and is how the M9 sighting got written up as a finding about the interpreter.
#
# All seven now reach `transcript_completeness` in `lib.sh`, and every check that goes on to
# COMPARE transcripts calls `require_complete_transcript` first, which dies naming the truncation.
#
# What this check asserts, and — as carefully — what it does NOT.
#
#   * There is exactly ONE implementation, and the two milestone-named helpers delegate to it.
#   * Every check that COMPARES one transcript against another REFUSES on an incomplete one, which
#     is different from asserting about it: an assertion adds a red line to the thirty-two, and
#     that is how M9's sighting came to be written up as a finding about the interpreter.
#   * The implementation is exercised on a deliberately truncated copy, on an empty one, on a
#     missing one and on one that MENTIONS the sentinel in a value — four distinguishable answers.
#   * A declared exception that no longer matches a real file FAILS, the shape
#     `verify_named_checks_exist` uses.
#
# It does NOT assert that the tree is clean. 30 checks depend on a transcript having finished and
# 22 of them still ask the question in their own spelling or not at all. That number is PINNED,
# exactly and in both directions, so it cannot drift while nobody is looking — but converting the
# 22 moves ten milestones' assertion counts and is an Outstanding Task, not something to half-do
# behind a green check.

set -uo pipefail
TEST_NAME="verify_transcript_truncation_detection_uniform"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "== $TEST_NAME"

V="$REPO_ROOT/verification"
SHARED='transcript_completeness'
REFUSAL='require_complete_transcript'

# ---------------------------------------------------------------------------
# 1. THERE IS EXACTLY ONE IMPLEMENTATION, AND IT IS IN lib.sh
# ---------------------------------------------------------------------------
LIB="$(cat "$V/lib.sh")"
assert_true "lib.sh declares transcript_completeness" \
  str_has_line_re "$LIB" "^transcript_completeness\(\) \{"
assert_true "…and require_complete_transcript, which is the refusal" \
  str_has_line_re "$LIB" "^require_complete_transcript\(\) \{"

# The two milestone-named helpers survive as one-line delegations — the campaign's prose and M9's
# and M17's own comments cite them by name, so deleting the names would break citations. What must
# not survive is a SECOND BODY: a `wc -l` / `truncated-after` construction outside lib.sh.
# This file is excluded because the needle below IS in it — it is the needle. The exclusion is
# asserted rather than assumed, two lines down.
SELF_NAME='verify_transcript_truncation_detection_uniform.sh'
BODIES="$(grep -rlF "printf 'truncated-after-" "$V" --include='*.sh' --exclude="$SELF_NAME" \
          2>/dev/null | sort || true)"
assert_eq "the 'truncated-after-' token is CONSTRUCTED in exactly one file" "$V/lib.sh" "$BODIES"
# Mentioning it is a different thing from constructing it — this check and M8's both quote the
# token — so the needle is the printf, and that distinction is asserted rather than assumed.
MENTIONS="$(grep -rlF 'truncated-after-' "$V" --include='*.sh' 2>/dev/null | grep -c . || true)"
assert_ge "…while more than one file MENTIONS it, so the needle above is discriminating" 3 "$MENTIONS"
assert_true "…and this check is one of them, so its own exclusion is load-bearing" \
  grep -qF "printf 'truncated-after-" "$V/$SELF_NAME"
for helper in m9_completeness m17_completeness; do
  DECL="$(grep -h "^${helper}() " "$V"/lib_*.sh || true)"
  assert_contains "$helper is a one-line delegation to the shared implementation" \
    "$SHARED" "$DECL"
done

# ---------------------------------------------------------------------------
# 2. EVERY CHECK THAT READS A TRANSCRIPT REACHES THE SHARED IMPLEMENTATION
#
# The population is derived, not listed: any check that names a `.done` sentinel key, or that runs
# one of the transcript comparators, is a check whose conclusions depend on the run having
# finished. Deriving it is the point — a listed population cannot grow, and the eighth transcript
# check is exactly the one this is for.
# ---------------------------------------------------------------------------
POP="$(grep -rlE '[A-Za-z]+\.done\b|_TRANSCRIPT_COMPARE|_STEPS_COMPARE' "$V" --include='*.sh' 2>/dev/null \
       | grep -vE '/(lib|lib_[a-z0-9_]+)\.sh$' | grep -v 'verify_transcript_truncation_detection_uniform.sh' \
       | sort || true)"
N_POP="$(printf '%s\n' "$POP" | grep -c . || true)"
note "$N_POP check(s) depend on a transcript having finished"
# M29 ADDED THE THIRTY-FIRST, AND IT REACHES THE SHARED IMPLEMENTATION.
# `e2e_browser_container_opcodes_match_native` compares the native x86-64 driver's per-record
# transcript against the same program run in a browser, so it is a comparer in this section's sense
# and is on section 3's list. Its first draft asserted `avmSteps.done 1` by hand — the eighth
# spelling of the question this milestone unified — and THIS CENSUS is what caught it, in M29's own
# sweep, before anything was declared. 30 -> 31 with the reaching set 8 -> 9 and the not-reaching
# set unchanged at 22, which is the split that says the new member did not join the backlog.
assert_eq "the derived population is exactly the recorded size, in both directions" "31" "$N_POP"

# Declared exceptions, each with a reason. An exception that no longer matches a real file FAILS,
# which is what stops this list from silently outliving what it excuses.
EXCEPTIONS="$(cat <<'EOF'
verify_node_v8_accepts_module.sh|it BUILDS the module and its own runs are the subject; it already calls the shared helper four times
run_avm_differential.sh|a runner rather than a check — it has its own exit-status vocabulary and hands transcripts to the checks that compare them
EOF
)"

# A CITATION IS NOT A CALL, and this check was one comment away from not knowing the difference.
#
# Found by M21's review, by mutation: delete every `require_complete_transcript` CALL from
# `verify_native_wasm_transcripts_identical.sh` and leave ONE mention of the name in a comment, and
# both this census and section 3's refusal list stayed green — 36 assertions, 0 failures. The
# comparer no longer refused, and nothing said so. Deleting the name outright WAS caught, so the
# needle worked exactly until somebody wrote the word down.
#
# That is the campaign's "a citation counted as a call", and M21 met it twice in one session: the
# other instance is `Tx.create` in `form_b.ts`, which WAS narrowed to a call shape. This is the
# sibling that was not. `test_no_aztec_node_type_exported`'s own description states the rule — "a
# citation is the opposite of a dependency" — so the rule was written down here and applied there.
#
# The needle is therefore comment-stripped and call-shaped: the name must begin a command, or be
# the first word of a command substitution, and it must be followed by whitespace or a quote rather
# than by more identifier characters. Section 2's control below plants both directions.
#
# Measured before the narrowing and after: the census was 30 / 22 / 8 either way, because all eight
# reaching files call it as well as mentioning it. The fix closes the hole without moving a number,
# which is the only way to tell a narrowing from a re-pin.
# Written with `lib.sh`'s builtin line predicate rather than as `grep -v … | grep -q …`, and that
# is this milestone's OWN rule rather than style: `verify_no_pipeline_predicates` pins the number of
# surviving `| grep -q` lines in the tree at exactly five, by name. The first draft of these two
# helpers used the pipe and would have taken that count to seven — a check written in this session
# breaking the check written beside it in the same session. Caught by re-reading the rule, and the
# proof is that both checks are green together.
uncommented() { # <file> -> its lines with whole-line comments removed
  grep -vE '^[[:space:]]*#' "$1" || true
}
# THE PREFIX THAT MAKES THIS CALL-SHAPED, AND IT DID NOT USED TO.
#
# Until 2026-08-31 both predicates matched the name after ANY non-word character —
# `(^|[^A-Za-z0-9_])NAME` — while the paragraph above them said, in as many words, "the name must
# begin a command, or be the first word of a command substitution". It did not: a name in a
# TRAILING comment satisfied it, because `uncommented` strips WHOLE-LINE comments only. So
# `: # unwired: require_complete_transcript "$t"` counted as a call.
#
# That is this file's own subject — a citation counted as a call — surviving in the file that
# records it, and it is also the campaign's commonest shape: a description claiming a property the
# comparison cannot make. FOUND BY MUTATION, not by reading: unwiring both refusals in
# `test_observer_fires_on_exceptional_halt` while leaving the name in a trailing comment left this
# check at 48 assertions, 0 failures. Section 2's `mention_in_trailing_comment` probe is the
# control that would have caught it and is now here.
#
# Command position: start of line, or after a separator (`;` `&&` `||` `|` `(` `{` `}`), or the
# first word of a `$(…)` or a backtick substitution.
CALL_PREFIX='(^[[:space:]]*|[;&|(){}][[:space:]]*|\$\(|`)'
reaches_shared() { # <file> -> true if it CALLS transcript_completeness or require_complete_transcript
  str_has_line_re "$(uncommented "$1")" "$CALL_PREFIX($REFUSAL|$SHARED)([[:space:]\"']|\$)"
}
reaches_refusal() { # <file> -> true if it CALLS require_complete_transcript
  str_has_line_re "$(uncommented "$1")" "$CALL_PREFIX$REFUSAL([[:space:]\"']|\$)"
}

MISSING=""
N_MISSING=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if reaches_shared "$f"; then continue; fi
  MISSING="$MISSING $(basename "$f")"
  N_MISSING=$((N_MISSING + 1))
done <<EOF
$POP
EOF
# THIS IS A CENSUS PINNED AS A NUMBER, NOT A CLAIM THAT THE TREE IS CLEAN.
#
# 20 of the 30 do not reach the shared implementation. They are not all defects — several read one
# field from a driver's output and never compare anything, so a truncation there produces one
# missing value rather than a page of false divergences — but several DO read thirty fields after a
# sentinel assertion of their own spelling, and those are the eighth, ninth and tenth spellings of
# the question this milestone set out to unify. Converting them touches ten milestones' assertion
# counts and is recorded as an Outstanding Task rather than half-done here.
#
# **22 -> 20 ON 2026-08-31, AND THE TWO THAT MOVED ARE THE CAMPAIGN'S OLDEST OPEN ITEM.**
# `test_observer_fires_on_exceptional_halt` and `test_existing_event_emitter_path_still_available`
# are the two checks `m9_completeness` was never wired into, open since M24 and named in the brief
# at every truncation sighting since — they contributed eleven and one misattributing red
# assertions, with names like "[v8] oob recorded a step for every one of them, expected [3],
# got []", every time the V8/WASI flake fired. They call `require_complete_transcript` now, before
# the assertions that misattribute rather than beside them, and M9's four transcript checks install
# the abnormal-exit trap so the refusal reads as a RED milestone instead of a 283-assertion
# silent shrink. This check going red is what it is FOR: the count could not drift without somebody
# looking, and it did not.
#
# What IS pinned is the NUMBER, exactly, in both directions: a new check written without the shared
# helper makes this fail, and converting one of the 20 makes it fail too. A census that is only
# printed is what M20's review found and named.
#
# AND THE TWO CONVERTED ARE NAMED AS WELL AS COUNTED, because a size is not a composition — this
# campaign's own rule, from M28's review, where replacing one row of a table with a different check
# that exists also passed a size comparison. Naming them means unwiring one of the two is a failure
# that says WHICH, rather than a number that moved by one for an unstated reason.
note "not reaching the shared implementation:$MISSING"
assert_eq "the set that does not reach it is exactly the recorded size" "20" "$N_MISSING"
assert_eq "…and the eleven that DO are the six comparers, the node-host runs, M21's two probes and M9's two" \
  "11" "$((N_POP - N_MISSING))"
for _m9_converted in test_observer_fires_on_exceptional_halt \
                     test_existing_event_emitter_path_still_available; do
  assert_true "$_m9_converted reaches the shared refusal (open from M24 to 2026-08-31)" \
    reaches_refusal "$REPO_ROOT/verification/$_m9_converted.sh"
  # …and it is in the POPULATION, or the assertion above is about a file this census never looks
  # at — the "an absence asked of a tree that excludes the subject" shape, inverted.
  assert_true "…and it is in this census's own population" \
    str_has_line "$POP" "$REPO_ROOT/verification/$_m9_converted.sh"
done

# THE NEEDLE IS A THING UNDER TEST, in both directions. A file that only MENTIONS the name must not
# count as reaching it, and a file that CALLS it must. Without the first of these, the census above
# is satisfied by a comment — measured, on this very check, before the narrowing.
NEEDLE_PROBE="$REPO_ROOT/verification/.m21-needle-probe"
rm -rf "$NEEDLE_PROBE"; mkdir -p "$NEEDLE_PROBE"
trap 'rm -rf "$NEEDLE_PROBE"' EXIT
{ printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "# NOTE: this check used to call $REFUSAL before comparing."
  printf '%s\n' 'echo avmSteps.done'; } >"$NEEDLE_PROBE/mention_only.sh"
{ printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "$REFUSAL \"\$OUT\" avmSteps.done \"the run's\""; } >"$NEEDLE_PROBE/calls_it.sh"
{ printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "V=\"\$($SHARED \"\$OUT\" avmSteps.done)\""; } >"$NEEDLE_PROBE/calls_shared.sh"
{ printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "${REFUSAL}_disabled \"\$OUT\" avmSteps.done"; } >"$NEEDLE_PROBE/renamed_away.sh"
assert_false "a file that only MENTIONS the refusal in a comment does NOT count as reaching it" \
  reaches_shared "$NEEDLE_PROBE/mention_only.sh"
# …AND THE SAME MENTION IN A **TRAILING** COMMENT, which is the case that was open until
# 2026-08-31 and the one a mutation actually produces. `uncommented` removes whole-line comments,
# so this file's code survives stripping and only the call-shape prefix can reject it.
{ printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' ": # unwired: $REFUSAL \"\$OUT\" avmSteps.done"; } >"$NEEDLE_PROBE/trailing_comment.sh"
assert_false "…and a mention in a TRAILING comment does not count either" \
  reaches_shared "$NEEDLE_PROBE/trailing_comment.sh"
# The positive control for that negative: the same line WITHOUT the comment does count, so the
# rejection is about the comment and not about the spelling.
{ printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' "$REFUSAL \"\$OUT\" avmSteps.done"; } >"$NEEDLE_PROBE/trailing_control.sh"
assert_true "…while the identical call with the comment removed DOES count" \
  reaches_shared "$NEEDLE_PROBE/trailing_control.sh"
assert_true "…while one that CALLS it does" reaches_shared "$NEEDLE_PROBE/calls_it.sh"
assert_true "…and so does one that calls the shared implementation directly" \
  reaches_shared "$NEEDLE_PROBE/calls_shared.sh"
assert_false "…and a longer identifier that merely STARTS with the name does not" \
  reaches_shared "$NEEDLE_PROBE/renamed_away.sh"
assert_false "the refusal needle likewise refuses a comment" \
  reaches_refusal "$NEEDLE_PROBE/mention_only.sh"
assert_true "…and accepts a call" reaches_refusal "$NEEDLE_PROBE/calls_it.sh"
assert_false "…and the shared implementation alone is not the refusal" \
  reaches_refusal "$NEEDLE_PROBE/calls_shared.sh"
rm -rf "$NEEDLE_PROBE"; trap - EXIT

# Both directions on the exception list.
while IFS= read -r row; do
  [ -n "$row" ] || continue
  name="${row%%|*}"; why="${row##*|}"
  assert_file "the declared exception $name still exists" "$V/$name"
  assert_ge "…and its reason is stated, not implied" 20 "${#why}"
done <<EOF
$EXCEPTIONS
EOF

# ---------------------------------------------------------------------------
# 3. THE REFUSAL PRECEDES EVERY COMPARISON
#
# Asserting completeness is not the same as refusing on it: an assertion produces one more red line
# among the thirty-two, which is how the M9 sighting was written up as a finding about the AVM.
# Every check that compares one transcript against another must REFUSE first.
# ---------------------------------------------------------------------------
COMPARERS="verify_native_wasm_transcripts_identical.sh
test_revert_program_does_not_trap_module.sh
verify_observation_hook_step_records_identical.sh
test_avm_reactor_transcripts_match_driver.sh
e2e_ts_wasm_result_decodes_as_upstream_types.sh
e2e_browser_container_opcodes_match_native.sh"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  assert_true "$name refuses on an incomplete transcript rather than asserting about it" \
    reaches_refusal "$V/$name"
done <<EOF
$COMPARERS
EOF

# ---------------------------------------------------------------------------
# 4. THE IMPLEMENTATION IS EXERCISED, ON A DELIBERATELY TRUNCATED COPY
#
# Three distinguishable answers, because a missing file is a broken run and a short file is this
# flake, and a check that collapsed them would report the wrong one.
# ---------------------------------------------------------------------------
P="$REPO_ROOT/verification/.m21-transcript-probe"
rm -rf "$P"; mkdir -p "$P"
trap 'rm -rf "$P"' EXIT
{
  printf 'run.programs 3\n'
  for i in $(seq 1 200); do printf 'steps.burn.%d ctx=0 pc=%d op=1\n' "$i" "$i"; done
  printf 'run.crossProgramEqualPairs 0\n'
  printf 'avmSteps.done 1\n'
} >"$P/full.steps"
head -n 100 "$P/full.steps" >"$P/short.steps"
: >"$P/empty.steps"

assert_eq "a complete transcript reads complete" "complete" \
  "$(transcript_completeness "$P/full.steps" avmSteps.done)"
assert_eq "a truncated one names the truncation, the line count and the last key that arrived" \
  "truncated-after-100-lines-last-key-steps.burn.99" \
  "$(transcript_completeness "$P/short.steps" avmSteps.done)"
# `empty`, NOT `truncated-after-0-lines`. Found by this check's own sibling: a probe that could not
# resolve a module left a zero-byte transcript and the refusal told the reader about the V8/WASI
# flake, which is the misattribution this whole mechanism exists to stop. A process that produced no
# stdout at all did not START; one that produced some did not FINISH; and those send the next reader
# to different places.
assert_eq "an EMPTY transcript is its own answer, not a truncation at zero" "empty" \
  "$(transcript_completeness "$P/empty.steps" avmSteps.done)"
assert_eq "a MISSING file is a different answer from a truncated one" "absent" \
  "$(transcript_completeness "$P/no-such-file.steps" avmSteps.done)"
# The sentinel is looked for as a KEY, not as a substring: a transcript that merely MENTIONS the
# sentinel in a value must not read as complete, or a step record naming it would excuse a
# truncation.
{ printf 'steps.a.1 note=avmSteps.done\n'; printf 'steps.a.2 x=1\n'; } >"$P/mention.steps"
assert_eq "a transcript that mentions the sentinel in a VALUE is still truncated" \
  "truncated-after-2-lines-last-key-steps.a.2" \
  "$(transcript_completeness "$P/mention.steps" avmSteps.done)"
# …and the same file with the sentinel as a key IS complete, so the discrimination is two-sided.
{ cat "$P/mention.steps"; printf 'avmSteps.done 1\n'; } >"$P/mention2.steps"
assert_eq "…and the same file with it as a KEY is complete" "complete" \
  "$(transcript_completeness "$P/mention2.steps" avmSteps.done)"

# The refusal itself, run in a child so its `die` can be observed.
REF_PROBE="$P/refuse.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'TEST_NAME=refusal_probe'
  printf '%s\n' ". \"$V/lib.sh\""
  printf '%s\n' "require_complete_transcript \"$P/short.steps\" avmSteps.done \"the re-run\" \"$P/full.steps\""
  printf '%s\n' 'echo REACHED-THE-COMPARISON'
} >"$REF_PROBE"
REF_OUT="$(bash "$REF_PROBE" 2>&1)"; REF_RC=$?
assert_eq "the refusal exits non-zero on a truncated transcript" "1" "$REF_RC"
assert_not_contains "…and nothing after it runs, so no comparison is reported" \
  "REACHED-THE-COMPARISON" "$REF_OUT"
assert_contains "…and it names the truncation" "truncated-after-100-lines" "$REF_OUT"
assert_contains "…and the reference's length, so the two are comparable at a glance" \
  "203 line(s)" "$REF_OUT"
assert_contains "…and says stderr is normally complete, which is the signature" \
  "stderr is normally COMPLETE" "$REF_OUT"
# THE CONTROL: on a COMPLETE transcript the refusal must let the run continue, or "it refuses" is
# just "it always dies".
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'TEST_NAME=refusal_probe'
  printf '%s\n' ". \"$V/lib.sh\""
  printf '%s\n' "require_complete_transcript \"$P/full.steps\" avmSteps.done \"the re-run\""
  printf '%s\n' 'echo REACHED-THE-COMPARISON'
} >"$REF_PROBE"
REF_OUT="$(bash "$REF_PROBE" 2>&1)"; REF_RC=$?
assert_eq "…while a complete transcript passes straight through" "0" "$REF_RC"
assert_contains "…and the comparison after it runs" "REACHED-THE-COMPARISON" "$REF_OUT"

rm -rf "$P"; trap - EXIT

# ---------------------------------------------------------------------------
# 5. WHAT IS STILL NOT KNOWN, RECORDED AS AN ASSERTION RATHER THAN AS A COMMENT
#
# THE TRIGGER IS ESTABLISHED AS OF 2026-08-31, AND THIS BLOCK CHANGED SIDES.
#
# It used to assert that DRIFT.md "records the trigger as UNESTABLISHED rather than fixed",
# because "the failure mode here is a future agent reading a uniform detection as a fix". That was
# right for three months and it is now FALSE OF THE WORLD — a check pinning a sentence that a later
# measurement falsified, which is the shape this campaign's residuals pass exists to find, arriving
# in the check that guards the entry.
#
# What must be pinned now is the opposite and it is stricter: that the entry records the trigger, a
# REPRODUCTION and a CONTROL — not merely the word "fixed". A fix asserted by a document that
# states no experiment is exactly the reading the old assertion was protecting against, one step
# along.
# ---------------------------------------------------------------------------
DRIFT="$(cat "$REPO_ROOT/DRIFT.md")"
assert_true "DRIFT.md carries the truncation entry" str_has_sub "$DRIFT" "D19"
assert_true "…and records the trigger as ESTABLISHED, naming the pipe" \
  str_has_sub "$DRIFT" "THE TRIGGER IS THE PIPE"
assert_false "…and no longer says the trigger is unestablished, which was true until 2026-08-31" \
  str_has_sub "$DRIFT" "the trigger is still unestablished"
assert_true "…and carries the REPRODUCTION's decisive figure, not just the claim" \
  str_has_sub "$DRIFT" "53,186"
assert_true "…and the CONTROL that makes it a measurement: the same starve with no pipe" \
  str_has_sub "$DRIFT" "byte-identical to the clean baseline"
assert_true "…and names both original sightings, so a ninth is recognised as a ninth" \
  str_has_sub "$DRIFT" "16,719"
assert_true "…including the M8 one" str_has_sub "$DRIFT" "259 lines of 1,318"

finish
