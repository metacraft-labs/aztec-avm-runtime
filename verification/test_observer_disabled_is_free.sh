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
# The measurement.
# ---------------------------------------------------------------------------
cp "$patched_bin" "$bench_dir/control"
chmod +x "$bench_dir/control"
assert_true "the control is a byte-for-byte copy of the patched binary" \
  cmp -s "$bench_dir/control" "$patched_bin"

samples="$bench_dir/native.tsv"
: >"$samples"
note "timing: $M9_BENCH_ROUNDS rounds of $M9_BENCH_REPS, three binaries, rotated"
i=0
while [ "$i" -lt "$M9_BENCH_ROUNDS" ]; do
  case $((i % 3)) in
    0) order="patched:$patched_bin unpatched:$ref_bin control:$bench_dir/control" ;;
    1) order="unpatched:$ref_bin control:$bench_dir/control patched:$patched_bin" ;;
    *) order="control:$bench_dir/control patched:$patched_bin unpatched:$ref_bin" ;;
  esac
  for entry in $order; do
    lbl="${entry%%:*}"; bin="${entry#*:}"
    m9_run_native "$bin" "$bench_dir/run.out" "$bench_dir/run.err" bench burn "$M9_BENCH_REPS"
    rc=$?
    [ "$rc" -eq 0 ] || die "a timing run of $lbl exited $rc — see $bench_dir/run.err"
    sed -n 's/^bench\.us\.[0-9]* //p' "$bench_dir/run.out" \
      | while read -r v; do printf '%s\t%s\n' "$lbl" "$v"; done >>"$samples"
  done
  i=$((i + 1))
done

want=$((M9_BENCH_ROUNDS * M9_BENCH_REPS))
for lbl in patched unpatched control; do
  assert_eq "$lbl produced $want timed samples" "$want" \
    "$(grep -c "^$lbl	" "$samples" || true)"
done

python3 "$M9_TIMING" --disabled "$samples" "$M9_DISABLED_BUDGET_PCT" \
  >"$bench_dir/native.tsv.report" 2>"$bench_dir/native.tsv.err"
rc=$?
assert_eq "the timing comparator ran on the native samples" "0" "$rc"
[ "$rc" -eq 0 ] || die "the timing comparator failed: $(head -3 "$bench_dir/native.tsv.err")"
m8_report "$bench_dir/native.tsv.report"

# ---------------------------------------------------------------------------
# The same, under wasm. A neutrality claim about x86-64 is not a claim about wasm32, and this
# milestone's whole point is the browser.
# ---------------------------------------------------------------------------
wsamples="$bench_dir/wasm.tsv"
: >"$wsamples"
cp "$patched_wasm" "$bench_dir/control.wasm"
assert_true "the wasm control is a byte-for-byte copy of the patched module" \
  cmp -s "$bench_dir/control.wasm" "$patched_wasm"
assert_false "the two wasm modules are not byte-identical" cmp -s "$patched_wasm" "$ref_wasm"
i=0
while [ "$i" -lt "$M9_BENCH_ROUNDS" ]; do
  case $((i % 3)) in
    0) order="patched:$patched_wasm unpatched:$ref_wasm control:$bench_dir/control.wasm" ;;
    1) order="unpatched:$ref_wasm control:$bench_dir/control.wasm patched:$patched_wasm" ;;
    *) order="control:$bench_dir/control.wasm patched:$patched_wasm unpatched:$ref_wasm" ;;
  esac
  for entry in $order; do
    lbl="${entry%%:*}"; mod="${entry#*:}"
    m9_run_v8 "$mod" "$bench_dir/wrun.out" "$bench_dir/wrun.err" bench burn "$M9_BENCH_REPS"
    rc=$?
    [ "$rc" -eq 0 ] || die "a wasm timing run of $lbl exited $rc — see $bench_dir/wrun.err"
    sed -n 's/^bench\.us\.[0-9]* //p' "$bench_dir/wrun.out" \
      | while read -r v; do printf '%s\t%s\n' "$lbl" "$v"; done >>"$wsamples"
  done
  i=$((i + 1))
done
for lbl in patched unpatched control; do
  assert_eq "wasm: $lbl produced $want timed samples" "$want" \
    "$(grep -c "^$lbl	" "$wsamples" || true)"
done
python3 "$M9_TIMING" --disabled "$wsamples" "$M9_DISABLED_BUDGET_PCT" \
  >"$bench_dir/wasm.tsv.report" 2>"$bench_dir/wasm.tsv.err"
rc=$?
assert_eq "the timing comparator ran on the wasm samples" "0" "$rc"
[ "$rc" -eq 0 ] || die "the timing comparator failed: $(head -3 "$bench_dir/wasm.tsv.err")"
m8_report "$bench_dir/wasm.tsv.report"

# ---------------------------------------------------------------------------
# The comparator's own discriminating power: a fabricated 30% difference must be REJECTED, and a
# sample set too small to support a comparison must make it refuse rather than agree.
# ---------------------------------------------------------------------------
ctl="$bench_dir/controls"; mkdir -p "$ctl"
awk -F'\t' 'BEGIN{OFS="\t"} $1=="patched"{ $2 = int($2 * 1.30) } { print }' "$samples" \
  >"$ctl/inflated.tsv"
python3 "$M9_TIMING" --disabled "$ctl/inflated.tsv" "$M9_DISABLED_BUDGET_PCT" \
  >"$ctl/inflated.report" 2>/dev/null
assert_eq "the comparator ran on the inflated samples" "0" "$?"
assert_ge "a fabricated 30% penalty on the patched arm is rejected" 1 \
  "$(grep -c '^FAIL' "$ctl/inflated.report" || true)"
assert_true "and it is rejected by the equivalence assertion, naming the interval" \
  grep -q '^FAIL	the disabled path is equivalent to the unpatched build within' "$ctl/inflated.report"

head -n 12 "$samples" >"$ctl/tiny.tsv"
python3 "$M9_TIMING" --disabled "$ctl/tiny.tsv" "$M9_DISABLED_BUDGET_PCT" \
  >"$ctl/tiny.report" 2>/dev/null
assert_eq "too few samples make the comparator exit 3 rather than pass vacuously" "3" "$?"
assert_eq "and it produced no PASS rows at all" "0" "$(grep -c '^PASS' "$ctl/tiny.report" || true)"

# The other way this could pass for the wrong reason: a method too noisy to resolve anything would
# call ANY two things equivalent by widening the interval. The control arm is what catches that,
# and it is exercised by making it wildly noisy — the same bytes, but scattered — at which point
# the whole comparison must be rejected even though the patched-versus-unpatched arms are
# untouched.
awk -F'\t' 'BEGIN{OFS="\t"; srand(7)} $1=="control"{ $2 = int($2 * (0.7 + rand())) } { print }' \
  "$samples" >"$ctl/noisy.tsv"
python3 "$M9_TIMING" --disabled "$ctl/noisy.tsv" "$M9_DISABLED_BUDGET_PCT" \
  >"$ctl/noisy.report" 2>/dev/null
assert_eq "the comparator ran on the noisy-control samples" "0" "$?"
assert_true "a method that cannot resolve two copies of the same binary is rejected outright" \
  grep -q '^FAIL	the same test calls two copies of the SAME binary equivalent' "$ctl/noisy.report"
assert_eq "and the patched-versus-unpatched arms were left untouched in that control" \
  "$(grep -c '^patched	' "$samples")" "$(grep -c '^patched	' "$ctl/noisy.tsv")"

finish
