#!/usr/bin/env bash
# test_revert_program_does_not_trap_module — M8.
#
# THE REVERT PROGRAM RETURNS revertCode 1 RATHER THAN TRAPPING THE WASM INSTANCE.
#
# This is the fixture behind M4 and it is the one place where a wasm build can be wrong in a way
# that looks like a crash. Under barretenberg's `BB_NO_EXCEPTIONS` shim — `#define try if(true)`,
# which is what a wasi-sdk 27 wasm build gets — any C++ `throw` becomes `std::abort()`. A reverting
# transaction would then not revert: it would kill the instance. So "revertCode 1" is not one more
# equal field in the transcript; it is the observable that separates a wasm build with real C++
# exceptions from one without.
#
# The check therefore asserts three separate things rather than one:
#   * the VALUE — revertCode 1, identical native and wasm, with every other line of the revert
#     program's transcript identical too;
#   * the SURVIVAL — the module exits 0 and the transcript continues past the revert for another
#     five programs and a completion marker, so the instance was not left in a trapped state;
#   * the MECHANISM — the throw/catch path really executed inside wasm: the artefact carries a wasm
#     exception Tag section and `__cxa_throw`/`__cxa_begin_catch`, it is compiled with
#     `-fwasm-exceptions` and not with `-fno-exceptions`, and the AVM's own log records the call
#     "halted via REVERT" rather than the host's abort hook firing.
#
# And a second exceptional path, because a revert is not the only one: the `burn` program exhausts
# its gas and halts via EXCEPTIONAL_HALT, which the module also survives.

TEST_NAME="test_revert_program_does_not_trap_module"
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m8_differential.sh"

command -v python3 >/dev/null 2>&1 || die "python3 is not available"
m8_measured

NATIVE_T="$(m8_native_transcript)"
V8_T="$(m8_v8_transcript)"
V8_ERR="$(m8_v8_stderr)"
WASM_BIN="$(m8_wasm_bin avm_differential)"
m8_require_artifacts "$NATIVE_T" "$V8_T" "$V8_ERR" "$WASM_BIN"

# ---------------------------------------------------------------------------
echo "== 1. the value"
# ---------------------------------------------------------------------------
assert_eq "the revert program reverts under wasm" "1" \
  "$(sed -n 's/^program\.revert\.revertCode //p' "$V8_T")"
assert_eq "…and natively" "1" "$(sed -n 's/^program\.revert\.revertCode //p' "$NATIVE_T")"
# Not a constant: the other six programs must NOT report revertCode 1, or "1" would be what this
# driver always prints.
assert_eq "the add program returns rather than reverting" "0" \
  "$(sed -n 's/^program\.add\.revertCode //p' "$V8_T")"
REVERTING="$(grep -c '^program\.[a-z0-9]*\.revertCode 1$' "$V8_T" || true)"
assert_eq "exactly two of the seven programs end in a non-zero revert code" "2" "$REVERTING"
assert_eq "…and they are revert and burn, named" "burn revert" \
  "$(sed -n 's/^program\.\([a-z0-9]*\)\.revertCode 1$/\1/p' "$V8_T" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')"

# Every line of the revert program's own transcript, per line.
diff <(grep '^program\.revert\.' "$NATIVE_T") <(grep '^program\.revert\.' "$V8_T") \
  >"$M8_WORK/revert.diff" 2>&1 || true
assert_eq "every line of the revert program's transcript is identical native versus wasm" "0" \
  "$(grep -c . "$M8_WORK/revert.diff" || true)"
assert_ge "…and there are enough of them for that to mean something" 30 \
  "$(grep -c '^program\.revert\.' "$V8_T" || true)"

# The revert is a real transaction outcome, not an aborted one: gas was charged, a fee was paid,
# the deployment nullifier is in the effects and the trees moved.
assert_eq "gas was accounted for the two instructions it executed" "2" \
  "$(sed -n 's/^program\.revert\.stat\.total_instructions_executed //p' "$V8_T")"
assert_eq "a transaction fee was charged" \
  "0x0000000000000000000000000000000000000000000000000000000000083de4" \
  "$(sed -n 's/^program\.revert\.txFee //p' "$V8_T")"
assert_eq "the end nullifier root differs from the start one, so the tx committed its effects" "1" \
  "$( [ "$(sed -n 's/^program\.revert\.start\.NULLIFIER_TREE //p' "$V8_T")" \
       != "$(sed -n 's/^program\.revert\.end\.NULLIFIER_TREE //p' "$V8_T")" ] && echo 1 || echo 0 )"

# ---------------------------------------------------------------------------
echo "== 2. the survival"
# ---------------------------------------------------------------------------
# Rerun the wasm module on its own so the exit status belongs to THIS check rather than to a record
# written by another one.
RERUN_T="$M8_WORK/revert-rerun.transcript"
RERUN_E="$M8_WORK/revert-rerun.stderr"
m8_run_v8 "$WASM_BIN" "$RERUN_T" "$RERUN_E"
assert_eq "the wasm module exits 0 with the revert program in the run" "0" "$?"
assert_true "…and reproduces the transcript exactly" cmp -s "$RERUN_T" "$V8_T"
assert_eq "the transcript continues past the revert to the completion marker" "avmDifferential.done 1" \
  "$(tail -1 "$V8_T")"
# Named rather than counted: the five programs the driver runs AFTER the revert must all be there.
for prog in loop sha256 poseidon2 storage burn; do
  assert_true "program $prog ran after the revert" grep -q "^program\.$prog\.revertCode " "$V8_T"
done
# The host's abort hook is what a trapped or aborting guest reaches, and the host exits 6 when it
# fires. It did not fire.
assert_eq "the host's throw_or_abort_impl hook did not fire" "0" \
  "$(grep -c 'throw_or_abort_impl' "$V8_ERR" || true)"
assert_eq "the guest did not trap" "0" "$(grep -c 'unreachable\|RuntimeError' "$V8_ERR" || true)"
# …and the hook exists, so its silence is a measurement.
assert_true "the host does carry an abort hook, so its silence means something" \
  grep -q 'throw_or_abort_impl' "$M7_V8_HOST"

# ---------------------------------------------------------------------------
echo "== 3. the mechanism, inside wasm"
# ---------------------------------------------------------------------------
assert_contains "the AVM's own log records the call halting via REVERT" \
  "halted via REVERT with message: Assertion failed:" "$(cat "$V8_ERR")"
assert_not_contains "…and not via an abort" "std::abort" "$(cat "$V8_ERR")"

# The artefact really carries wasm exception handling. A `Tag` section is the wasm EH construct and
# nothing else emits one; `__cxa_throw` and `__cxa_begin_catch` are the C++ runtime either side of
# it. Both read out of the binary rather than off the flag list, because a flag that is present and
# inert is exactly what a flag list cannot distinguish.
SECTIONS="$M8_WORK/wasm-sections.txt"
m6_in_devshell 'wasm-objdump -h "$1"' "$WASM_BIN" >"$SECTIONS" 2>&1
assert_eq "wasm-objdump read the module" "0" "$?"
assert_ge "the module has a Tag section — the wasm exception-handling construct" 1 \
  "$(grep -cE '^ *Tag start=' "$SECTIONS" || true)"
assert_eq "…declaring exactly one tag" "1" \
  "$(sed -n 's/^ *Tag .*count: \([0-9]*\)$/\1/p' "$SECTIONS")"
NM="$M8_WORK/wasm-nm.txt"
m6_in_devshell 'llvm-nm "$1"' "$WASM_BIN" >"$NM" 2>&1
assert_eq "llvm-nm read the module" "0" "$?"
for sym in __cxa_throw __cxa_begin_catch; do
  assert_ge "$sym is in the wasm artefact" 1 "$(grep -c " $sym\$" "$NM" || true)"
done

# The flags, on the driver AND on the AVM interpreter sources it calls into — the throw happens in
# vm2, not in the driver, so asserting only the driver's flags would be asserting the wrong unit.
FLAG_REPORT="$(python3 - "$(m6_compile_db "$M8_TREE" "$M8_WASM_BUILD")" <<'PY'
import json, sys
db = json.load(open(sys.argv[1], encoding="utf-8"))
own = [e for e in db if "/barretenberg/cpp/src/" in e["file"]]
vm2 = [e for e in own if "/vm2/simulation/" in e["file"]]
out = [
    ("the wasm build has vm2 simulation translation units", len(vm2) >= 30, str(len(vm2))),
    ("every one of them is compiled with -fwasm-exceptions",
     all("-fwasm-exceptions" in e["command"] for e in vm2), str(len(vm2))),
    ("none of them is compiled with -fno-exceptions",
     not any("-fno-exceptions" in e["command"] for e in vm2), ""),
    ("none of barretenberg's own wasm units defines BB_NO_EXCEPTIONS",
     not any("BB_NO_EXCEPTIONS" in e["command"] for e in own), str(len(own))),
    ("and the legacy-EH opt-out is off, as M0's probe established",
     all("-wasm-use-legacy-eh=false" in e["command"] for e in vm2), ""),
]
for name, ok, detail in out:
    print(("PASS" if ok else "FAIL") + "\t" + name + "\t" + detail)
PY
)"
printf '%s\n' "$FLAG_REPORT" >"$M8_WORK/exception-flags.report"
m8_report "$M8_WORK/exception-flags.report"

# ---------------------------------------------------------------------------
echo "== 4. a second exceptional path: out of gas"
# ---------------------------------------------------------------------------
# A revert is a deliberate opcode. An out-of-gas halt is thrown from inside the interpreter loop and
# unwinds further, so it exercises the same machinery from a different place.
assert_contains "the burn program exhausts its gas" "Out of gas exception: Out of gas: total L2 used" \
  "$(cat "$V8_ERR")"
assert_contains "…and the enqueued call halts via EXCEPTIONAL_HALT" "halted via EXCEPTIONAL_HALT" \
  "$(cat "$V8_ERR")"
assert_eq "…and the module still reports the program's full result" "1" \
  "$(sed -n 's/^program\.burn\.revertCode //p' "$V8_T")"
assert_eq "…with the instruction count it reached, identical native and wasm" \
  "$(sed -n 's/^program\.burn\.stat\.total_instructions_executed //p' "$NATIVE_T")" \
  "$(sed -n 's/^program\.burn\.stat\.total_instructions_executed //p' "$V8_T")"
assert_ge "…and that count is a real workload" 30000 \
  "$(sed -n 's/^program\.burn\.stat\.total_instructions_executed //p' "$V8_T")"

# ---------------------------------------------------------------------------
echo "== 5. negative controls"
# ---------------------------------------------------------------------------
# (1) The host CAN report a failing guest. Asserted by running a module the host cannot satisfy,
#     so "exit 0" above is a measurement and not the only thing this host ever returns.
BOGUS="$M8_WORK/not-a-module.wasm"
printf 'not a wasm module at all' >"$BOGUS"
m8_run_v8 "$BOGUS" "$M8_WORK/bogus.transcript" "$M8_WORK/bogus.stderr"
assert_true "control: the host exits non-zero for a module it cannot load" test "$?" -ne 0
assert_eq "control: …and produces no transcript" "0" \
  "$(grep -c . "$M8_WORK/bogus.transcript" || true)"

# (2) The revert program's bytecode really is a REVERT_8, not a RETURN that happens to be labelled
#     "revert". Read from the corpus record, which M2 asserted against upstream's own BytecodeBuilder.
PROGRAMS_JSON="$REPO_ROOT/fixtures/avm-programs/programs.json"
assert_file "the corpus record is present" "$PROGRAMS_JSON"
assert_eq "the revert program is the nine-byte two-instruction one the corpus records" "9" \
  "$(python3 -c "import json;print(json.load(open('$PROGRAMS_JSON'))['programs']['revert']['bytes'])")"
assert_eq "…and the module built the same nine bytes" "9" \
  "$(sed -n 's/^program\.revert\.bytes //p' "$V8_T")"
assert_eq "…at the address the corpus records" \
  "$(python3 -c "import json;print(json.load(open('$PROGRAMS_JSON'))['programs']['revert']['address'])")" \
  "$(sed -n 's/^program\.revert\.address //p' "$V8_T")"
assert_contains "…and the corpus says why it exists" "REVERT_8" \
  "$(python3 -c "import json;print(json.load(open('$PROGRAMS_JSON'))['programs']['revert']['intent'])")"

finish
