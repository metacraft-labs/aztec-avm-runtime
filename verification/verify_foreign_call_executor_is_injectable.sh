#!/usr/bin/env bash
# verify_foreign_call_executor_is_injectable — the seam exists, and it costs nothing where nobody
# uses it.
#
# `noir_tracer::trace_circuit` accepts a foreign-call executor, and every existing caller still gets
# the default it always had. The CONTROL is the half that matters: the default path's event stream
# is byte-identical to the pre-change tracer's on a fixture that exercises `print` and the
# `__debug_*` calls the variable recorder rests on.
#
# WHERE THE EVIDENCE COMES FROM, AND WHY IT IS NOT A GREP. The property is behavioural — two runs
# produce the same stream — so it is established by RUNNING them, in `noir`'s own test suite
# (`tooling/tracer/tests/test_foreign_call_executor.rs`, four tests). This check runs that suite and
# reads its result. A `grep` for the new function's name would be this campaign's own "a citation is
# the opposite of a dependency", in the check whose subject is a seam.
#
# THE FOUR TESTS, AND WHAT EACH WOULD CATCH:
#   1. `the_default_executor_path_is_byte_identical_through_the_new_seam` — the whole recorded
#      stream, not a count, so a reordering fails too.
#   2. `an_injected_executor_sees_the_calls_the_recorder_makes` — the injected one is consulted.
#   3. `an_injected_executor_refuses_an_unserved_oracle_by_name` — and the trace stops short.
#   4. `the_default_executor_answers_an_unimplemented_void_oracle_with_an_empty_result` — the
#      control for 3, and a statement about the tracer worth making on its own.
#
# CONTROLS FOR THIS CHECK ITSELF:
#   * the suite is asserted NON-EMPTY as well as passing — `cargo test` exits 0 over zero tests, and
#     this campaign has already shipped a whole test file nothing executed;
#   * the four test names are asserted PRESENT in the run's own output, by name, so a suite that
#     silently lost one reads as red rather than as a smaller suite;
#   * the seam's two entry points are asserted to exist in the SOURCE as declarations, with the
#     old two asserted to still exist beside them — the compatibility claim is that both are there.
#
# Run: just verify-m38-injectable

TEST_NAME="verify_foreign_call_executor_is_injectable"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m38_private_trace.sh"
trap m38_summary_on_abnormal_exit EXIT

M38_NOIR_TESTS_TIMEOUT="${M38_NOIR_TESTS_TIMEOUT:-1800}"
TRACER="$M38_NOIR_ROOT/tooling/tracer"
SUITE="$TRACER/tests/test_foreign_call_executor.rs"

echo "== 1. THE SEAM IS DECLARED, AND THE OLD ENTRY POINTS ARE STILL THERE"
[ -d "$TRACER" ] || die "no Noir tracer at $TRACER (set M38_NOIR_ROOT)"
LIB="$(cat "$TRACER/src/lib.rs")"
assert_true "trace_circuit_with_executor is declared" \
  str_has_sub "$LIB" 'pub fn trace_circuit_with_executor'
assert_true "TracingContext::with_executor is declared" \
  str_has_sub "$LIB" 'pub fn with_executor('
assert_true "and it takes the executor as the boxed trait object DebugContext already took" \
  str_has_sub "$LIB" "foreign_call_executor: Option<Box<dyn DebugForeignCallExecutor + 'a>>"
# THE COMPATIBILITY CLAIM IS THAT BOTH ARE THERE. A seam that replaced the old signature would
# satisfy every assertion above and break every caller.
assert_true "trace_circuit is still declared with its own name" \
  str_has_sub "$LIB" 'pub fn trace_circuit<B: BlackBoxFunctionSolver<FieldElement>>('
assert_true "and TracingContext::new likewise" str_has_sub "$LIB" 'pub fn new('
# The two in-tree callers are unchanged, which is the "existing caller" half stated over the tree
# rather than over the signature.
CALLERS="$(grep -rln 'trace_circuit(' "$M38_NOIR_ROOT/tooling" --include='*.rs' 2>/dev/null | sort || true)"
assert_true "nargo_cli still calls the old entry point" \
  str_has_sub "$CALLERS" 'nargo_cli/src/cli/trace_cmd.rs'
assert_true "and so does tracer_wasm" str_has_sub "$CALLERS" 'tracer_wasm/src/lib.rs'

echo "== 2. THE SUITE EXISTS AND NAMES ITS FOUR SUBJECTS"
[ -s "$SUITE" ] || die "no $SUITE — the seam's evidence is a test suite, not a grep"
SRC="$(cat "$SUITE")"
DECLARED=0
for t in the_default_executor_path_is_byte_identical_through_the_new_seam \
         an_injected_executor_sees_the_calls_the_recorder_makes \
         an_injected_executor_refuses_an_unserved_oracle_by_name \
         the_default_executor_answers_an_unimplemented_void_oracle_with_an_empty_result; do
  assert_true "the suite declares $t" str_has_sub "$SRC" "fn $t("
  DECLARED=$(( DECLARED + 1 ))
done
assert_eq "four subjects, counted rather than assumed" "4" "$(m38_num "$DECLARED" 'declared tests')"
# IT COMPILES ITS FIXTURES IN PROCESS. A suite that spawned `nargo` would measure whatever binary is
# on disk, because `cargo test -p noir_tracer` does not rebuild it — this campaign's own recorded
# baseline defect. Asserted on the source, with the positive control that the compiler IS reached.
assert_true "and it compiles its fixtures in process" str_has_sub "$SRC" 'noirc_driver::compile_main'
assert_false "rather than spawning a binary" str_has_sub "$SRC" 'Command::new'

echo "== 3. THE SUITE RUNS, AND IT IS NOT EMPTY"
OUT="$(mktemp)"
rc=0
direnv exec "$M38_NOIR_ROOT" true 2>/dev/null || true
timeout -s KILL "$M38_NOIR_TESTS_TIMEOUT" \
  nix shell nixpkgs#rustup nixpkgs#capnproto --command bash -c '
    set -uo pipefail
    export RUSTUP_HOME="${M38_RUSTUP_HOME:-$HOME/.rustup}"
    export CODETRACER_TRACE_FORMAT_NIM_SKIP_NIMBLE_INSTALL=1
    cd "'"$M38_NOIR_ROOT"'" || exit 1
    toolchain="$(sed -n '"'"'s/^channel *= *"\(.*\)"/\1/p'"'"' rust-toolchain.toml | head -1)"
    rustup run "$toolchain" cargo test -p noir_tracer --test test_foreign_call_executor -- --test-threads=1
  ' > "$OUT" 2>&1 || rc=$?

RESULT="$(cat "$OUT")"
case "$rc" in
  124|137)
    die "the noir_tracer executor suite did not finish within ${M38_NOIR_TESTS_TIMEOUT}s and was
             killed (timeout exit $rc). That is a HANG rather than a failure. See $OUT." ;;
esac
assert_eq "the suite exits 0" "0" "$rc"
assert_true "and reports a result line at all" str_has_sub "$RESULT" 'test result:'
# NOT EMPTY. `cargo test` exits 0 over zero tests, and this campaign has shipped a whole test file
# nothing executed — five `#[test]`s over an ABI, none of them ever run, one of them false.
assert_true "with four tests passing and none failing" \
  str_has_sub "$RESULT" 'test result: ok. 4 passed; 0 failed'
# EACH NAME IS READ BACK OUT OF THE RUN. A count of four would be satisfied by four other tests.
for t in the_default_executor_path_is_byte_identical_through_the_new_seam \
         an_injected_executor_sees_the_calls_the_recorder_makes \
         an_injected_executor_refuses_an_unserved_oracle_by_name \
         the_default_executor_answers_an_unimplemented_void_oracle_with_an_empty_result; do
  assert_true "the run reports $t" str_has_sub "$RESULT" "test $t ... ok"
done
rm -f "$OUT"

echo "== 4. THE FIXTURE SUITE THE SEAM MUST NOT MOVE"
# THE OTHER HALF OF "IT COSTS NOTHING". The four tests above establish that the DEFAULT PATH is
# unchanged in process. `test_tracer.rs` establishes it end to end, through a real `nargo trace` and
# the real `ct-print`, over twelve fixtures — and it is the suite that went red when the recorder's
# step rule was first changed on the wrong gate, so it is the instrument that noticed.
FIXTURES="$M38_NOIR_ROOT/tooling/tracer/tests/test_tracer.rs"
[ -s "$FIXTURES" ] || die "no $FIXTURES"
FIXTURE_TESTS="$(grep -c '^fn test_' "$FIXTURES" 2>/dev/null || echo 0)"
assert_ge "the fixture suite has a real number of tests" 12 "$(m38_num "$FIXTURE_TESTS" 'fixture tests')"
assert_true "and it refuses to skip silently by default" \
  str_has_sub "$(cat "$FIXTURES")" 'This is a hard failure on purpose'

m38_finish
