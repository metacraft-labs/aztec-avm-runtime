#!/usr/bin/env bash
# test_observer_disabled_is_free
#
# With `collect_execution_steps` off the seam is one predictable branch per instruction and the
# cost is below measurement noise — which is the native-neutrality evidence the upstream patch
# stands on.
#
# "Below noise" is not a thing a number can say on its own, so this check measures the noise. Three
# binaries are interleaved in a ROTATING order, five timed simulations at a time:
#
#   patched     $M9_WORK/m9's       avm_differential  (the observer patch present, flag off)
#   unpatched   $M9_WORK/m9ref's    avm_differential  (the observer patch absent entirely)
#   control     a byte-for-byte COPY of the patched binary
#
# The control is the point. If two copies of the same bytes, measured the same way, differ by more
# than the patched and unpatched binaries do, then the patched-versus-unpatched reading is noise
# and the check says so with evidence rather than with an adjective. The rotation is there because
# a fixed order gives whichever binary runs last a systematic penalty — measured, about one
# percent on this host.
#
# THE UNIT OF REPLICATION IS THE SESSION, and M9's own review is why. The first version of this
# check took one long rotation and bootstrapped over its samples, which answers "how precisely is
# THIS session's median known?" rather than the question being asked. Run six times over the same
# two binaries it produced six mutually disjoint "95% intervals" spanning -1.03% to +1.48%, and it
# failed on a correct tree.
#
# What varies between sessions was then measured rather than guessed at: where a file's pages
# physically land. It is fixed for a given file and RE-DRAWN BY A COPY, and it is four times larger
# than everything else — over twelve sessions, the same-bytes control's session-to-session sd is
# 0.39pp when the three files are reused and 1.50pp when they are re-copied. So every session here
# gets a fresh copy of all three arms (symmetrically, rotating which is written first), one point
# estimate is taken per session, and the interval goes over the sessions. m9_bench_sessions does
# the copying and the rotation; _timing_compare.py does the interval; both carry the reasoning.
#
# Three assertions keep the design from decaying back: the sample rows must carry as many distinct
# session ids as sessions were asked for, the 3 x sessions copies must be 3 x sessions distinct
# inodes, and a TSV whose rows all claim one session is refused by the comparator outright.
#
# HOW WIDE THE INTERVAL COMES OUT IS A PROPERTY OF THE MACHINE, AND M15 STOPPED CALLING IT A
# REGRESSION. The equivalence claim needs the interval to be at most half the budget wide, or the
# bound is the measurement rather than a bound on it. That requirement failed in M14's sweep at
# 1.05pp against a required 1.00pp — on a correct tree, with the difference itself comfortably
# inside the budget. Nothing an implementation does can widen or narrow it; a busy hour can.
#
# So there are two changes, and neither of them loosens the bound. First, the answer to a
# too-wide interval is MORE SESSIONS: the half-width falls as 1/sqrt(sessions) because the session
# is the unit of replication, so m9_measure_until_precise keeps what it has measured, adds another
# batch of independent sessions — fresh copies of all three arms, so they really are fresh draws —
# and asks again, up to M9_BENCH_SESSION_CAP. Second, reaching that cap is a PRECONDITION with its
# own exit code, 4, distinct from 1 (an assertion failed) and 3 (too busy to measure at all).
#
# The exit vocabulary of this check:
#
#   0  measured, and every assertion held
#   1  an assertion failed
#   3  the machine was too busy to measure on (m9_require_idle_machine)
#   4  measured, the difference is INSIDE the budget, and the interval around it is still too
#      wide to claim at the cap
#
# NEITHER PRECONDITION CAN HIDE A REGRESSION, and both halves of that are asserted rather than
# argued, by pairs of fabricated tables that differ in exactly one thing:
#
#   precision  two tables differing only by a shift. The unshifted one exits 4; the shifted one
#              FAILS the cost assertion at exit 0.
#   control    two tables differing only by whether a +30% regression is present under the same
#              per-session scattering of the control. The one without it exits 4; the one with it
#              exits 0 and reports the regression AND the failed control, as two FAIL rows.
#
# The second pair is M15's correction to itself. The first version of the control precondition
# returned 4 with no rows whenever the control left the budget, on the argument that "the patch
# cannot move the control". That argument is about the patch; the MACHINE moves the control, and
# on a run where it does so while a regression is also present, a bare refusal discarded the
# regression — `just verify-m9` reports 4 as PRECONDITION UNMET, so a measured +30% came out as a
# non-red sweep. A recorded FAIL now outranks both refusals.
#
# AND THE BOUND IS NOT SYMMETRIC ANY MORE, WHICH IS M15'S OTHER CORRECTION HERE. The claim the
# upstream patch stands on is that the DISABLED PATH COSTS NOTHING — a claim about not being
# SLOWER — and that side keeps the tight +2%. The faster side is a different question, "are these
# two builds comparable at all", and it has its own larger bound, because the patched build is
# REPRODUCIBLY FASTER: -1.26%, -1.38%, -1.40%, -1.71% and -1.75% over five measurements of the
# same byte-identical build pair, and the single two-sided bound had been passing that by 0.05pp
# for two milestones. On the sharpest of those readings the interval reaches -2.34%, so the old
# two-sided +/-2% would fail today on a correct build measured on an idle machine.
#
# THE HOIST IS NOT THE EXPLANATION, and that was settled by running the control rather than by
# reasoning about it. `m9nohoist` is this patch with the observe call put back INSIDE the
# interpreter's try block. Timed against `m9ref`, 32 sessions on an idle machine, it reads
# -1.28% CI [-1.71, -0.85] against a same-bytes control of -0.01% [-0.52, +0.50] — beside -1.75%
# CI [-2.34, -1.15] for the hoisted build in the same conditions. The speed-up survives undoing
# the hoist, so the shrunken exception region cannot be what causes it, and it is not an argument
# to offer upstream. What remains is the link-time code layout, which this measurement says up
# front it does not randomise.
#
# Both bounds are exercised, in isolation from each other: a fabricated 30% penalty fails the cost
# assertion and not the comparability one, and a fabricated 20% speed-up fails the comparability
# assertion and not the cost one.
#
# The two trees differ by EXACTLY the observer patch and that is asserted, in both directions:
# the reference tree has no interface header and no `collect_execution_steps` anywhere, and its
# driver binary reports `observerCompiledIn 0` while the patched one reports 1. A comparison of a
# binary with itself is the shape M5 found and closed, and it is the one this check could most
# easily have been.
#
# The SAME driver source builds in both trees. It guards its use of the new API on `__has_include`
# of the interface header, so nothing is rewritten between the two sides. The prepared
# upstream-bugs verify.sh did this with seven `sed` expressions over its own source and, when the
# second tree was not supplied, printed `SKIPPED` and exited 0 — line 79, the fifth such branch in
# this campaign, and the one this milestone owns.

set -uo pipefail
TEST_NAME=test_observer_disabled_is_free
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m9_observer.sh"

m9_measured

# ---------------------------------------------------------------------------
# The unpatched tree, and the assertion that it really is unpatched.
# ---------------------------------------------------------------------------
ref="$(m9_ref_tree)"
assert_dir "the reference worktree exists" "$ref"
assert_eq "the reference tree is the anchor plus exactly seven patches (the observer's is absent)" \
  "7" "$(git -C "$ref" rev-list --count "$(m8_anchor)..HEAD" 2>/dev/null)"
assert_eq "nothing under barretenberg/ is modified in it" "" "$(m9_tree_dirty "$ref")"
assert_false "the reference tree has no ExecutionObserverInterface header" \
  test -f "$ref/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"
assert_false "and no reference collector" \
  test -f "$ref/barretenberg/cpp/src/barretenberg/vm2/simulation/lib/execution_observer.cpp"
assert_eq "and no collect_execution_steps anywhere under vm2/" "0" \
  "$(grep -rl 'collect_execution_steps' "$ref/barretenberg/cpp/src/barretenberg/vm2/" \
     --include='*.hpp' --include='*.cpp' 2>/dev/null | grep -cv '/differential/' || true)"
# The measured tree, by contrast, has all three. Asserted so the difference is established in both
# directions rather than only by absence.
assert_true "the measured tree DOES have the interface header" \
  test -f "$M9_TREE/barretenberg/cpp/src/barretenberg/vm2/simulation/interfaces/execution_observer.hpp"
assert_ge "and does mention collect_execution_steps" 3 \
  "$(grep -rl 'collect_execution_steps' "$M9_TREE/barretenberg/cpp/src/barretenberg/vm2/" \
     --include='*.hpp' --include='*.cpp' 2>/dev/null | grep -cv '/differential/' || true)"

# The two trees differ in EXACTLY the files the patch touches, and in nothing else. That is what
# makes the timing difference attributable.
diffed="$(git -C "$M9_TREE" diff --name-only "$(git -C "$ref" rev-parse HEAD)" HEAD -- barretenberg 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
patch_files="$(grep '^diff --git a/' "$M9_OBSERVER_PATCH" | sed 's|^diff --git a/||; s| b/.*$||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"
assert_true "the patch touches files" test -n "$patch_files"
assert_eq "the two trees differ in exactly the files the observer patch touches" \
  "$patch_files" "$diffed"
assert_eq "which is seven files" "7" "$(printf '%s\n' $patch_files | wc -l)"

# ---------------------------------------------------------------------------
# The driver source is the SAME on both sides. Not "equivalent": identical bytes.
# ---------------------------------------------------------------------------
drv=barretenberg/cpp/src/barretenberg/vm2/differential/avm_differential.cpp
assert_true "the driver source is byte-identical in the two trees" \
  cmp -s "$M9_TREE/$drv" "$ref/$drv"
assert_true "and it decides which API to use with __has_include, not with a rewrite" \
  grep -q '__has_include("barretenberg/vm2/simulation/interfaces/execution_observer.hpp")' \
  "$M9_TREE/$drv"

# ---------------------------------------------------------------------------
# Build the reference driver.
# ---------------------------------------------------------------------------
note "building the unpatched reference driver"
m9_build_native "$ref"
assert_eq "the reference native configure exited 0" "0" "${M9_NATIVE_CONFIGURE_RC:-missing}"
assert_eq "the reference native build exited 0" "0" "${M9_NATIVE_BUILD_RC:-missing}"
m9_build_wasm "$ref"
assert_eq "the reference wasm configure exited 0" "0" "${M9_WASM_CONFIGURE_RC:-missing}"
assert_eq "the reference wasm build exited 0" "0" "${M9_WASM_BUILD_RC:-missing}"

patched_bin="$(m9_native_bin "$M9_TREE")"
ref_bin="$(m9_native_bin "$ref")"
patched_wasm="$(m9_wasm_bin "$M9_TREE")"
ref_wasm="$(m9_wasm_bin "$ref")"
m8_require_artifacts "$patched_bin" "$ref_bin" "$patched_wasm" "$ref_wasm"

# The two binaries are not the same file, and each one SAYS which side it is. Establishing that
# from the binaries themselves rather than from the paths is what stops this being a comparison of
# a build with itself.
assert_false "the two native binaries are not byte-identical" cmp -s "$patched_bin" "$ref_bin"
bench_dir="$M9_WORK/bench"; rm -rf "$bench_dir"; mkdir -p "$bench_dir"
m9_run_native "$patched_bin" "$bench_dir/patched.id" "$bench_dir/patched.id.err" bench burn 1
assert_eq "the patched binary ran" "0" "$?"
m9_run_native "$ref_bin" "$bench_dir/ref.id" "$bench_dir/ref.id.err" bench burn 1
assert_eq "the reference binary ran" "0" "$?"
assert_eq "the patched binary reports the observer compiled in" "1" \
  "$(m9_field "$bench_dir/patched.id" bench.observerCompiledIn)"
assert_eq "the reference binary reports it absent" "0" \
  "$(m9_field "$bench_dir/ref.id" bench.observerCompiledIn)"
assert_eq "both time the same program" "burn" "$(m9_field "$bench_dir/patched.id" bench.program)"
assert_eq "and so does the reference" "burn" "$(m9_field "$bench_dir/ref.id" bench.program)"

# ---------------------------------------------------------------------------
# The measurement. See lib_m9_observer.sh's m9_bench_sessions for why the session — not the
# individual timed simulation — is the unit of replication, and what the per-session re-copy is
# for. In short: where a binary's pages land is fixed for a given file, re-drawn by a copy, and
# larger than the effect being measured, so a measurement that reuses one set of files reports an
# interval two to three times narrower than the quantity it claims to cover.
# ---------------------------------------------------------------------------
# Before the first timed round, and not after: a measurement taken beside someone
# else's build is not a measurement of these binaries. This exits 3 — its own code,
# distinct from an assertion failure — rather than producing a confident wrong
# answer. See m9_require_idle_machine.
m9_require_idle_machine

samples="$bench_dir/native.tsv"
inodes="$bench_dir/native.inodes"
note "timing: $M9_BENCH_SESSIONS sessions of $M9_BENCH_ROUNDS rounds of $M9_BENCH_REPS, three binaries, rotated, re-copied per session"
note "and up to $M9_BENCH_SESSION_CAP if the interval is not sharp enough at that count"
m9_measure_until_precise native "$patched_bin" "$ref_bin" "$bench_dir/native" \
  "$samples" "$inodes" "$bench_dir/native.tsv.report" "$bench_dir/native.tsv.err" \
  "$M9_BENCH_SESSIONS" "$M9_BENCH_SESSION_CAP"
NSESS="$M9_SESSIONS_RUN"

want=$((M9_BENCH_ROUNDS * M9_BENCH_REPS))
for lbl in patched unpatched control; do
  assert_eq "$lbl produced $((want * NSESS)) timed samples" \
    "$((want * NSESS))" "$(awk -F'\t' -v l="$lbl" '$2 == l' "$samples" | grep -c . || true)"
  assert_eq "in $NSESS separate sessions of $want" "$NSESS" \
    "$(awk -F'\t' -v l="$lbl" '$2 == l { print $1 }' "$samples" | LC_ALL=C sort -u | wc -l)"
done
assert_ge "at least the $M9_BENCH_SESSIONS sessions the design calls for were measured" \
  "$M9_BENCH_SESSIONS" "$NSESS"
note "native: $NSESS sessions, $M9_TIMING_EXTENSIONS extension(s), comparator exit $M9_TIMING_RC"
# The sessions are separate DRAWS, not one draw counted N times. Every arm in every session is its
# own file: 3 x sessions copies, all distinct inodes. Without this the design could quietly decay
# into the superseded one — the same three files timed repeatedly — and nothing would say so.
# It also covers the EXTENSION path: an added batch that re-used the previous batch's copies would
# add rows without adding draws, and the inode identity is what refuses that.
assert_eq "every session copied all three arms afresh" "$((3 * NSESS))" \
  "$(grep -c . "$inodes" || true)"
assert_eq "and every copy is its own file, so the sessions are independent draws" \
  "$((3 * NSESS))" "$(awk -F'\t' '{print $3}' "$inodes" | LC_ALL=C sort -u | wc -l)"
assert_eq "the inode ledger names every session exactly once per arm" "$NSESS" \
  "$(awk -F'\t' '{print $1}' "$inodes" | LC_ALL=C sort -u | wc -l)"
assert_true "the control of the last session is still a byte-for-byte copy of the patched binary" \
  cmp -s "$bench_dir/native/s$(printf '%03d' $((NSESS - 1)))/arm_c" "$patched_bin"
assert_true "and its unpatched arm is a byte-for-byte copy of the reference binary" \
  cmp -s "$bench_dir/native/s$(printf '%03d' $((NSESS - 1)))/arm_u" "$ref_bin"

# Exit 4 is the PRECONDITION: the difference is inside the budget and the interval around it is
# not sharp enough to call it a claim, at the session cap. It is not an assertion failure and it
# is not a pass — see M9_PRECISION_PRECONDITION_EXIT and _timing_compare.py's header.
if [ "$M9_TIMING_RC" -eq 4 ]; then
  printf '%s: cannot run: %s\n' "$TEST_NAME" \
    "the timing interval is still not sharp enough after $NSESS sessions" >&2
  sed -n '1,3p' "$bench_dir/native.tsv.err" >&2
  printf '%s: this is a measurement precondition, not a regression: the difference measured is\n' "$TEST_NAME" >&2
  printf '%s: INSIDE the budget and the interval around it is too wide to claim it. Re-run on a\n' "$TEST_NAME" >&2
  printf '%s: quieter machine, or raise M9_BENCH_SESSION_CAP (currently %s).\n' "$TEST_NAME" "$M9_BENCH_SESSION_CAP" >&2
  exit "$M9_PRECISION_PRECONDITION_EXIT"
fi
assert_eq "the timing comparator ran on the native samples" "0" "$M9_TIMING_RC"
[ "$M9_TIMING_RC" -eq 0 ] || die "the timing comparator failed: $(head -3 "$bench_dir/native.tsv.err")"
m8_report "$bench_dir/native.tsv.report"

# ---------------------------------------------------------------------------
# The same, under wasm. A neutrality claim about x86-64 is not a claim about wasm32, and this
# milestone's whole point is the browser.
# ---------------------------------------------------------------------------
wsamples="$bench_dir/wasm.tsv"
winodes="$bench_dir/wasm.inodes"
assert_false "the two wasm modules are not byte-identical" cmp -s "$patched_wasm" "$ref_wasm"
note "timing under V8: $M9_WASM_BENCH_SESSIONS sessions (a process launch costs about 2 s here, which is what caps the count), up to $M9_WASM_BENCH_SESSION_CAP"
m9_measure_until_precise v8 "$patched_wasm" "$ref_wasm" "$bench_dir/wasm" \
  "$wsamples" "$winodes" "$bench_dir/wasm.tsv.report" "$bench_dir/wasm.tsv.err" \
  "$M9_WASM_BENCH_SESSIONS" "$M9_WASM_BENCH_SESSION_CAP"
WSESS="$M9_SESSIONS_RUN"
for lbl in patched unpatched control; do
  assert_eq "wasm: $lbl produced $((want * WSESS)) timed samples" \
    "$((want * WSESS))" "$(awk -F'\t' -v l="$lbl" '$2 == l' "$wsamples" | grep -c . || true)"
  assert_eq "wasm: in $WSESS separate sessions" "$WSESS" \
    "$(awk -F'\t' -v l="$lbl" '$2 == l { print $1 }' "$wsamples" | LC_ALL=C sort -u | wc -l)"
done
assert_ge "wasm: at least the $M9_WASM_BENCH_SESSIONS sessions the design calls for" \
  "$M9_WASM_BENCH_SESSIONS" "$WSESS"
note "wasm: $WSESS sessions, $M9_TIMING_EXTENSIONS extension(s), comparator exit $M9_TIMING_RC"
assert_eq "wasm: every session copied all three modules afresh" \
  "$((3 * WSESS))" "$(awk -F'\t' '{print $3}' "$winodes" | LC_ALL=C sort -u | wc -l)"
assert_true "wasm: the control of the last session is a byte-for-byte copy of the patched module" \
  cmp -s "$bench_dir/wasm/s$(printf '%03d' $((WSESS - 1)))/arm_c.wasm" "$patched_wasm"
if [ "$M9_TIMING_RC" -eq 4 ]; then
  printf '%s: cannot run: %s\n' "$TEST_NAME" \
    "the V8 timing interval is still not sharp enough after $WSESS sessions" >&2
  sed -n '1,3p' "$bench_dir/wasm.tsv.err" >&2
  printf '%s: a measurement precondition, not a regression — see the native arm above.\n' "$TEST_NAME" >&2
  exit "$M9_PRECISION_PRECONDITION_EXIT"
fi
assert_eq "the timing comparator ran on the wasm samples" "0" "$M9_TIMING_RC"
[ "$M9_TIMING_RC" -eq 0 ] || die "the timing comparator failed: $(head -3 "$bench_dir/wasm.tsv.err")"
m8_report "$bench_dir/wasm.tsv.report"

# ---------------------------------------------------------------------------
# The comparator's own discriminating power: a fabricated 30% difference must be REJECTED, and a
# sample set too small to support a comparison must make it refuse rather than agree.
# ---------------------------------------------------------------------------
ctl="$bench_dir/controls"; mkdir -p "$ctl"
# BOTH the patched arm and its same-bytes copy are inflated, and that is the correction that makes
# this control mean what it says. `control` is compared against `patched`, so scaling `patched`
# alone moves the CONTROL ratio too — and with a failed control now a precondition, an inflation of
# `patched` alone would be refused before the cost assertion was ever reached. Scaling the copy with
# it keeps the control at parity, which is what a genuine regression looks like: the patched build
# and a copy of it are equally slow, and both are slower than the unpatched one.
awk -F'\t' 'BEGIN{OFS="\t"} $2=="patched" || $2=="control" { $3 = int($3 * 1.30) } { print }' \
  "$samples" >"$ctl/inflated.tsv"
python3 "$M9_TIMING" --disabled "$ctl/inflated.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/inflated.report" 2>/dev/null
assert_eq "the comparator ran on the inflated samples" "0" "$?"
assert_ge "a fabricated 30% penalty on the patched arm is rejected" 1 \
  "$(grep -c '^FAIL' "$ctl/inflated.report" || true)"
assert_true "and it is rejected by the equivalence assertion, naming the interval" \
  grep -q '^FAIL	the disabled path is not SLOWER than the unpatched build' "$ctl/inflated.report"
assert_eq "a rejection is a RESULT, so the comparator still exits 0 and prints its rows" "0" \
  "$(python3 "$M9_TIMING" --disabled "$ctl/inflated.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" >/dev/null 2>&1; echo $?)"

# ---------------------------------------------------------------------------
# THE PRECISION PRECONDITION, in both directions. This is M15's carried fix and it is the pair of
# cases that make it mean something.
#
# A per-SESSION multiplier alternating +/-3.5% on the patched arm widens the interval without
# moving its centre — which is exactly the shape a noisy machine produces, and exactly the shape
# M14's sweep hit at 1.05pp against a required 1.00pp. The comparator must REFUSE with its own
# exit code rather than report a milestone regression, and must print no PASS row, so a report
# with nothing in it cannot be read as a clean one.
# ---------------------------------------------------------------------------
# The two tables are SYNTHESISED rather than derived from the real samples, and that is the second
# thing this pair had to learn. A first version scaled the measured patched arm, which made the
# control's centre depend on whatever the real measurement happened to be that day: on a build
# whose real reading sat at -1.71%, the "centred" fabrication landed outside the budget and
# exercised the equivalence assertion instead of the precision one. A control whose meaning depends
# on the thing it is controlling for is not a control. These are written from constants.
#
# 32 sessions x 15 samples x 3 arms, base 100000 us with a deterministic jitter and no RNG. The
# patched arm carries a per-SESSION multiplier alternating +/-3.5%, which is the shape a noisy
# machine produces: it widens the interval over sessions without moving its centre. The second
# table is the SAME thing shifted by 2.5%, so the only difference between the two is the shift.
#
# `control` CARRIES THE SAME MULTIPLIER AS `patched`, and that is not a detail. The control IS the
# patched binary, copied, so a fabrication in which the patched arm moves and its own copy does not
# is not a story about anything — and with a failed control now a precondition, such a table would
# be refused before the assertion under test was reached. Every fabrication here keeps the control
# at parity with the patched arm, which is what every real one does.
awk -v W="$ctl/wide.tsv" -v S="$ctl/wideshift.tsv" 'BEGIN{
  OFS="\t"
  for (s = 0; s < 32; s++) {
    f = (s % 2 == 0) ? 0.965 : 1.035
    # A thousandth of a percent of wobble on the control, alternating: enough that its interval is
    # NON-DEGENERATE — an interval of exactly zero width admits nothing and the comparator says so —
    # and three orders of magnitude inside the budget, so it stays a passing control.
    g = (s % 2 == 0) ? 0.999 : 1.001
    for (i = 0; i < 15; i++) {
      base = 100000 + (s * 7 + i * 13) % 200
      print s, "patched",   int(base * f)          > W
      print s, "unpatched", int(base)              > W
      print s, "control",   int(base * f * g)      > W
      print s, "patched",   int(base * f * 1.025)  > S
      print s, "unpatched", int(base)              > S
      print s, "control",   int(base * f * 1.025 * g) > S
    }
  }
}'
assert_eq "the fabricated tables were written, 32 x 15 x 3 rows each" "1440 1440" \
  "$(grep -c . "$ctl/wide.tsv") $(grep -c . "$ctl/wideshift.tsv")"
assert_eq "each carrying 32 sessions" "32 32" \
  "$(awk -F'\t' '{print $1}' "$ctl/wide.tsv" | sort -u | wc -l) $(awk -F'\t' '{print $1}' "$ctl/wideshift.tsv" | sort -u | wc -l)"

python3 "$M9_TIMING" --disabled "$ctl/wide.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/wide.report" 2>"$ctl/wide.err"
assert_eq "an interval too wide to claim, but INSIDE the budget, exits 4" "4" "$?"
assert_eq "and prints no PASS row, so an empty report cannot read as a clean one" "0" \
  "$(grep -c '^PASS' "$ctl/wide.report" || true)"
assert_eq "and no FAIL row either — nothing was rejected" "0" \
  "$(grep -c '^FAIL' "$ctl/wide.report" || true)"
assert_true "the refusal names precision, not a difference" \
  grep -q 'insufficient precision to make the equivalence claim' "$ctl/wide.err"
assert_true "it says the measurement is inside the budget, so a reader cannot mistake it" \
  grep -q 'is INSIDE the budget' "$ctl/wide.err"
assert_true "and it names the remedy in sessions, with a number" \
  grep -qE 'about [0-9]+ sessions would' "$ctl/wide.err"

# THE COMPLEMENT, and the one that makes the precondition safe: the SAME widening, shifted so the
# interval leaves the budget. Imprecision must not buy a refusal when there is a real difference to
# report — the equivalence assertion is evaluated first and a FAIL wins over exit 4.
python3 "$M9_TIMING" --disabled "$ctl/wideshift.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/wideshift.report" 2>"$ctl/wideshift.err"
assert_eq "an interval just as wide, but OUTSIDE the budget, is a failure and not a refusal" "0" "$?"
assert_true "reported by the equivalence assertion" \
  grep -q '^FAIL	the disabled path is not SLOWER than the unpatched build' "$ctl/wideshift.report"
assert_eq "and the precision precondition did not swallow it" "0" \
  "$(grep -c 'insufficient precision' "$ctl/wideshift.err" || true)"
assert_false "and they are not the same table" cmp -s "$ctl/wide.tsv" "$ctl/wideshift.tsv"

# THE FASTER SIDE IS A BOUND TOO, and it is exercised, because a bound nobody can cross is not a
# bound. The same synthetic table with the patched arm 20% FASTER: no branch removed from a hot
# loop explains that, so the comparability assertion must reject it — and the COST assertion must
# not, because nothing here is slower.
awk -v F="$ctl/toofast.tsv" 'BEGIN{
  OFS="\t"
  for (s = 0; s < 32; s++)
    for (i = 0; i < 15; i++) {
      base = 100000 + (s * 7 + i * 13) % 200
      print s, "patched",   int(base * 0.80) > F
      print s, "unpatched", int(base)        > F
      print s, "control",   int(base * 0.80 * ((s % 2 == 0) ? 0.999 : 1.001)) > F
    }
}'
assert_eq "the too-fast fabrication was written" "1440" "$(grep -c . "$ctl/toofast.tsv")"
python3 "$M9_TIMING" --disabled "$ctl/toofast.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/toofast.report" 2>"$ctl/toofast.err"
assert_eq "the comparator ran on it" "0" "$?"
assert_true "a patched arm 20% faster is rejected by the COMPARABILITY assertion" \
  grep -q '^FAIL	and the two builds are comparable at all' "$ctl/toofast.report"
assert_eq "and NOT by the cost assertion, because nothing there is slower" "0" \
  "$(grep -c '^FAIL	the disabled path is not SLOWER' "$ctl/toofast.report" || true)"

# Too few SESSIONS is now the way this measurement can be too small, and it is the specific way
# the superseded estimator was wrong: one session's worth of samples, however many of them there
# are, cannot support the claim. Two sessions of full-size samples must still be refused.
awk -F'\t' '$1 < 2' "$samples" >"$ctl/tiny.tsv"
python3 "$M9_TIMING" --disabled "$ctl/tiny.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/tiny.report" 2>"$ctl/tiny.err"
assert_eq "two sessions make the comparator exit 3 rather than pass vacuously" "3" "$?"
assert_eq "and it produced no PASS rows at all" "0" "$(grep -c '^PASS' "$ctl/tiny.report" || true)"
assert_true "refusing by SESSION count, not by sample count" \
  grep -q 'not enough complete sessions to compare' "$ctl/tiny.err"
assert_ge "even though those two sessions carry plenty of samples" 30 \
  "$(awk -F'\t' '$2 == "patched"' "$ctl/tiny.tsv" | grep -c . || true)"

# The other way this could pass for the wrong reason: a method too noisy to resolve anything would
# call ANY two things equivalent by widening the interval. The control arm is what catches that,
# and it is exercised by scattering it — the same bytes, but with a per-SESSION multiplier, which
# is what hits the estimator this comparator actually uses — at which point the whole comparison
# must be rejected even though the patched-versus-unpatched arms are untouched.
awk -F'\t' 'BEGIN{OFS="\t"; srand(7)}
            $2=="control" { if (!($1 in m)) m[$1] = 0.85 + rand() * 0.3; $3 = int($3 * m[$1]) }
            { print }' "$samples" >"$ctl/noisy.tsv"
python3 "$M9_TIMING" --disabled "$ctl/noisy.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/noisy.report" 2>"$ctl/noisy.err"
# A method that cannot resolve two copies of the same binary is refused with the PRECONDITION code,
# not reported as a difference. Its own evidence has shown it cannot resolve one, so neither a pass
# nor a failure about the patch is supportable from it — which is what M14's review was doing by
# hand when it classified M9's reds as environmental.
assert_eq "a method that cannot resolve two copies of the same binary exits 4" "4" "$?"
assert_eq "and prints no PASS row" "0" "$(grep -c '^PASS' "$ctl/noisy.report" || true)"
assert_eq "and no FAIL row — it makes no claim at all" "0" \
  "$(grep -c '^FAIL' "$ctl/noisy.report" || true)"
assert_true "naming the control, not the patch" \
  grep -q 'could not resolve two copies of the SAME binary' "$ctl/noisy.err"
assert_true "and saying it is a precondition rather than a regression" \
  grep -q 'MEASUREMENT PRECONDITION, not a regression' "$ctl/noisy.err"
assert_eq "and the patched-versus-unpatched arms were left untouched in that control" \
  "$(awk -F'\t' '$2 == "patched"' "$samples" | grep -c .)" "$(awk -F'\t' '$2 == "patched"' "$ctl/noisy.tsv" | grep -c .)"

# AND THE CASE THAT SHOWS THE REFUSAL CANNOT SWALLOW A RESULT: a real regression measured ON a
# machine that had also scattered the control. This is the one the previous version of the
# precondition got wrong, and it got it wrong for a reason worth keeping in view — the argument
# was "the patch cannot move the control, so the control cannot mask the patch", which is true
# about the PATCH and silent about the MACHINE. The machine can scatter the control on a run where
# a regression is present at the same time, and a bare refusal there DISCARDS a measured failure:
# `just verify-m9` maps 4 to PRECONDITION UNMET, so a +30% regression came out as a non-red sweep.
#
# The table is synthesised from constants for the same reason the precision pair is: 32 x 15 x 3
# rows, the patched arm a flat +30% on the unpatched one, and the control scattered +/-10% PER
# SESSION — which is the machine's signature, not the patch's, since a copy of a binary cannot be
# 10% away from the binary it was copied from for any reason but the host.
#
# What must come back is BOTH: exit 0, the cost assertion FAILING and named, and the control's own
# row also FAILING beside it rather than replacing it.
awk -v R="$ctl/regress_noisy.tsv" 'BEGIN{
  OFS="\t"
  for (s = 0; s < 32; s++) {
    c = (s % 2 == 0) ? 0.90 : 1.10
    for (i = 0; i < 15; i++) {
      base = 100000 + (s * 7 + i * 13) % 200
      print s, "patched",   int(base * 1.30)     > R
      print s, "unpatched", int(base)            > R
      print s, "control",   int(base * 1.30 * c) > R
    }
  }
}'
assert_eq "the regression-beside-a-scattered-control fabrication was written" "1440" \
  "$(grep -c . "$ctl/regress_noisy.tsv")"
python3 "$M9_TIMING" --disabled "$ctl/regress_noisy.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/regress_noisy.report" 2>"$ctl/regress_noisy.err"
assert_eq "a real regression measured beside a failed control is a RESULT, not a refusal" "0" "$?"
assert_true "the regression is reported, by name" \
  grep -q '^FAIL	the disabled path is not SLOWER than the unpatched build' "$ctl/regress_noisy.report"
assert_true "and the failed control is reported beside it rather than instead of it" \
  grep -q '^FAIL	the same test calls two copies of the SAME binary equivalent' "$ctl/regress_noisy.report"
assert_ge "so the report is not empty — the run made a claim" 18 \
  "$(grep -c . "$ctl/regress_noisy.report" || true)"
assert_eq "and nothing was written to stderr, because nothing was refused" "0" \
  "$(grep -c . "$ctl/regress_noisy.err" || true)"
# The pair that makes it a discrimination rather than an observation: the SAME scattering with the
# regression removed still refuses, so what changed the outcome is the regression and not the
# scattering. Without this, "it reported" would be consistent with the precondition having been
# deleted outright.
awk -v R="$ctl/noregress_noisy.tsv" 'BEGIN{
  OFS="\t"
  for (s = 0; s < 32; s++) {
    c = (s % 2 == 0) ? 0.90 : 1.10
    p = (s % 2 == 0) ? 0.999 : 1.001
    for (i = 0; i < 15; i++) {
      base = 100000 + (s * 7 + i * 13) % 200
      print s, "patched",   int(base * p)     > R
      print s, "unpatched", int(base)         > R
      print s, "control",   int(base * p * c) > R
    }
  }
}'
python3 "$M9_TIMING" --disabled "$ctl/noregress_noisy.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/noregress_noisy.report" 2>"$ctl/noregress_noisy.err"
assert_eq "the same scattering with NO regression under it still exits 4" "4" "$?"
assert_eq "and prints no row at all, because there is nothing to report" "0" \
  "$(grep -c . "$ctl/noregress_noisy.report" || true)"
assert_true "the refusal says so in as many words" \
  grep -q 'NOTHING ELSE ON THIS RUN FAILED' "$ctl/noregress_noisy.err"
assert_false "and the two tables differ only in the regression" \
  cmp -s "$ctl/regress_noisy.tsv" "$ctl/noregress_noisy.tsv"

# And the defect this redesign exists to remove, exercised directly: collapse every sample into ONE
# session — which is exactly what the superseded comparator was given — and the answer must be a
# refusal rather than a narrower interval.
awk -F'\t' 'BEGIN{OFS="\t"} { $1 = 0; print }' "$samples" >"$ctl/onesession.tsv"
python3 "$M9_TIMING" --disabled "$ctl/onesession.tsv" "$M9_DISABLED_BUDGET_PCT" "$M9_DISABLED_FASTER_BUDGET_PCT" \
  >"$ctl/onesession.report" 2>/dev/null
assert_eq "the superseded shape — every sample in one session — is refused, not narrowed" "3" "$?"
assert_eq "and it too produced no PASS rows" "0" \
  "$(grep -c '^PASS' "$ctl/onesession.report" || true)"

finish
