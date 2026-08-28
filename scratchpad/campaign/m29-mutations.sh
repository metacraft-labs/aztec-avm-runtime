#!/usr/bin/env bash
# M29's mutation harness. EIGHT ARMS, each breaking one thing the three checks claim to catch.
#
#   scratchpad/campaign/m29-mutations.sh [arm ...]
#
# ===========================================================================================
# WHAT THIS IS FOR, AND WHAT "THE CHECK FAILED" IS NOT.
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`: "when a mutation reddens, read WHICH assertions went red. 'The check failed'
# and 'the check saw what I broke' are different statements, and only the second is coverage." So
# every arm below records the failing assertion NAMES, not just the count, and the log is the
# artefact.
#
# TWO ARMS ARE THE STATES A COUNT CANNOT SEE. M6 makes a check DIE before `finish` — the abnormal
# exit that once took M1 from 151 to 141 with nothing reported as failing — and M5 makes the browser
# arm HANG, which is the state a trap cannot reach because a process that never exits has no exit.
# Both are expected to produce `0 assertion(s), 1 failure(s)` with a named diagnostic.
#
# ===========================================================================================
# SERIALISATION, AND THE `touch`.
# ===========================================================================================
#
# A mutation harness and a verification sweep are two writers. This runs to completion, restores,
# and verifies the restore BEFORE any sweep starts. Every restored file is `touch`ed, because a
# mutated artefact outliving its restored source has appeared three times in three disguises — and
# `m27_bundle_newer_inputs` is mtime-based, so a restore that preserved mtimes would leave
# `browser/dist` describing a tree that is no longer there.

set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO" || exit 2

LOG_DIR="${M29_MUT_LOG:-$HOME/.cache/aztec-m29-mutations}"
mkdir -p "$LOG_DIR"
BAK="$LOG_DIR/backups"
mkdir -p "$BAK"

CT_DOWNLOAD="browser/src/ct_download.ts"
EXECUTED="browser/src/executed_steps.ts"
PARITY="browser/src/native_parity.ts"
DEMO="browser/demo/main.ts"
LIB29="verification/lib_m29_steps.sh"

FILES="$CT_DOWNLOAD $EXECUTED $PARITY $DEMO $LIB29"

save() { local f; for f in $FILES; do cp -p "$f" "$BAK/$(echo "$f" | tr / _)"; done; }
restore() {
  local f
  for f in $FILES; do cp "$BAK/$(echo "$f" | tr / _)" "$f"; done
  # TOUCHED, NOT `cp -p`. See the header.
  touch $FILES
}

say() { printf '\n=== %s\n' "$*"; }

# run_check <arm> <check> [env=...] — run one check with the bundle and arms forced to refresh, and
# record the failing assertion NAMES.
run_check() {
  local arm="$1" check="$2"; shift 2
  local out="$LOG_DIR/$arm.$check.log"
  env M27_BUNDLE_REFRESH=1 M27_ARMS_REFRESH=1 "$@" \
    verification/"$check".sh >"$out" 2>&1
  local rc=$?
  printf '  %-52s rc=%d  %s\n' "$check" "$rc" \
    "$(grep -E "^${check}: [0-9]+ assertion" "$out" | tail -1)"
  grep -E '^  FAIL' "$out" | sed 's/^/      /' | head -12
  grep -E "^${check}: FAIL — exited" "$out" | sed 's/^/      /'
}

save
trap 'restore' EXIT

ARMS="${*:-M1 M2 M3 M4 M5 M6 M7 M8}"

for arm in $ARMS; do
case "$arm" in

# ---------------------------------------------------------------------------------------------
M1) say "M1 — THE SYNTHESISED PATH RETURNS: the opcode is (pc % 200) + 1 again"
    # The exact rule M27 shipped, put back into the recorder. Everything else — the pcs, the gas,
    # the frames — stays REAL, which is the hard case: only the opcodes IN THE CONTAINER can see it.
    #
    # IT MUTATES THE EVENT AND NOT THE LOCAL `opcode`, DELIBERATELY. Changing `const opcode` would
    # also move `written`, and therefore the recorder's own `distinctOpcodes` — so the check would
    # catch it in section 6 without ever reading the container, which is the coverage this arm
    # exists to measure. This changes ONLY what crosses into the writer.
    restore
    python3 - <<'PY'
p='browser/src/ct_download.ts'
s=open(p).read()
old="      pc: step.pc,\n      opcode,"
new="      pc: step.pc,\n      opcode: (step.pc % 200) + 1, // MUTATION"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M1 test_browser_steps_are_executed_not_mapped
    ;;

# ---------------------------------------------------------------------------------------------
M2) say "M2 — THE DRAIN LOSES THE LAST RECORD: one decoded record is dropped"
    # THE FIRST VERSION OF THIS ARM WAS A NO-OP AND SAYING SO IS THE POINT. It passed `count - 1`
    # as `drainSteps`' `total`, which only bounds the LOOP: with a 4,096-record batch and 516
    # records there is one iteration either way, and `avm_steps_batch(0, 4096)` returns the module's
    # whole window regardless. Both checks came out green. "The check failed" and "the check saw
    # what I broke" are different statements, and so are "the check passed" and "the mutation did
    # anything". This drops a record from what the host DECODED, which is the thing under test.
    restore
    python3 - <<'PY'
p='browser/src/executed_steps.ts'
s=open(p).read()
old="      steps: drained.steps,"
new="      steps: drained.steps.slice(0, -1), // MUTATION"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M2 test_browser_steps_are_executed_not_mapped
    run_check M2 test_trace_step_count_matches_instruction_count
    ;;

# ---------------------------------------------------------------------------------------------
M3) say "M3 — COLLECTION OFF: the demo page stops asking for the observation hook"
    # The recorder must REFUSE, by name, rather than substituting anything. The refusal happens
    # inside the page, so the arm run fails and the checks die with the runner's own diagnosis.
    restore
    python3 - <<'PY'
p='browser/demo/main.ts'
s=open(p).read()
old="    collectExecutionSteps: true,"
new="    collectExecutionSteps: false, // MUTATION"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M3 test_browser_steps_are_executed_not_mapped
    ;;

# ---------------------------------------------------------------------------------------------
M4) say "M4 — ONE ALTERED RECORD IN THE PARITY ARM: pc + 1 on the first record"
    restore
    python3 - <<'PY'
p='browser/src/native_parity.ts'
s=open(p).read()
old="      records: drained.steps.map((s: ExecutionStep) => formatExecutedStep(s)),"
new="      records: drained.steps.map((s: ExecutionStep, i: number) => i === 0 ? formatExecutedStep({ ...s, pc: s.pc + 1 }) : formatExecutedStep(s)), // MUTATION"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M4 e2e_browser_container_opcodes_match_native
    ;;

# ---------------------------------------------------------------------------------------------
M5) say "M5 — THE HANG: the parity arm never returns"
    # A page that never settles a promise. The arm run must exceed its bound and be reported as a
    # NAMED failure rather than sitting there — the third state, worse than red.
    restore
    # A SPIN, NOT AN UNSETTLED PROMISE, AND THE DIFFERENCE WAS MEASURED. The first version awaited
    # a promise nothing resolves; V8 COLLECTS it and the DevTools protocol answers
    # `{"code":-32000,"message":"Promise was collected"}` in seconds, so the arm failed fast for a
    # reason that has nothing to do with a hang. That is M24's review's finding — "a mutation that
    # crashes has not exercised the assertion it was written for" — reproduced. A busy loop blocks
    # the renderer, so `Runtime.evaluate` never answers and the bound is what ends it.
    python3 - <<'PY'
p='browser/demo/main.ts'
s=open(p).read()
old="  const result = runNativeParity(o.reactor, {"
new="  while (true) { /* MUTATION: the renderer never yields */ }\n  const result = runNativeParity(o.reactor, {"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    M27_ARMS_TIMEOUT=90 run_check M5 e2e_browser_container_opcodes_match_native
    ;;

# ---------------------------------------------------------------------------------------------
M6) say "M6 — DIE BEFORE SUMMARY: the native driver is not where the library looks"
    restore
    python3 - <<'PY'
p='verification/lib_m29_steps.sh'
s=open(p).read()
old='  M29_NATIVE_BIN="$(m12_native_bin avm_differential)"'
new='  M29_NATIVE_BIN="$(m12_native_bin avm_differential)-MUTATION"'
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M6 test_trace_step_count_matches_instruction_count
    ;;

# ---------------------------------------------------------------------------------------------
M7) say "M7 — THE RUNG IS ROUNDED UP: rung 1 declared over an executed stream with holes"
    # M25's ladder must refuse the container. The refusal is `MappingRungDegraded` at close, so the
    # page throws and the arm run fails — which is the enforcement working, from M29's side.
    restore
    python3 - <<'PY'
p='browser/src/ct_download.ts'
s=open(p).read()
old="  const declaredRung: MappingRung = complete ? RUNG_SOURCE : RUNG_FUNCTION;"
new="  const declaredRung: MappingRung = RUNG_SOURCE; // MUTATION: rounded up"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M7 test_trace_step_count_matches_instruction_count
    ;;

# ---------------------------------------------------------------------------------------------
M8) say "M8 — THE UNPOSITIONED STEPS ARE DROPPED: the tempting way to reach rung 1"
    # A producer that discarded the steps it could not place would declare rung 1 honestly and
    # silently lose a quarter of the execution. `positioned + unpositioned == events` is the
    # assertion that sees it, and so is the count identity against the AVM's statistic.
    restore
    python3 - <<'PY'
p='browser/src/ct_download.ts'
s=open(p).read()
old="    if (at === null) writer.push(event);\n    else writer.push(event, at);"
new="    if (at === null) continue; // MUTATION: drop what cannot be placed\n    writer.push(event, at);"
assert old in s
open(p,'w').write(s.replace(old,new,1))
PY
    run_check M8 test_trace_step_count_matches_instruction_count
    run_check M8 e2e_browser_downloads_ct_container_and_ct_print_parses
    ;;

*) echo "unknown arm: $arm" >&2 ;;
esac
done

say "RESTORE, and the verification that it took"
restore
# COMPARED AGAINST THE COPY THIS HARNESS TOOK, not against the index. Two of the five files are
# NEW in M29 and therefore untracked, and `git status --porcelain -- <untracked path>` prints
# nothing whatever the probe did — the exact defect `CAMPAIGN-BRIEF.md` records two checks having
# shipped. The comparison carries its own control: a deliberately corrupted copy must be reported.
bad=0
for f in $FILES; do
  if cmp -s "$f" "$BAK/$(echo "$f" | tr / _)"; then
    printf '  restored  %s\n' "$f"
  else
    printf '  DIFFERS   %s\n' "$f" >&2; bad=1
  fi
done
printf '%s\n' 'corrupted-control' >> "$LOG_DIR/control-copy"
cp "$BAK/$(echo "$CT_DOWNLOAD" | tr / _)" "$LOG_DIR/control-copy.ts"
printf '// CONTROL\n' >> "$LOG_DIR/control-copy.ts"
if cmp -s "$CT_DOWNLOAD" "$LOG_DIR/control-copy.ts"; then
  echo "restore-control: FAILED — the comparison cannot tell two different files apart" >&2; bad=1
else
  echo "  restore-control: a one-line difference IS reported, so the comparison above can fail"
fi
[ "$bad" -eq 0 ] && echo "restore: every file is byte-identical to the pre-mutation copy" \
  || echo "restore: FAILED" >&2
echo "logs: $LOG_DIR"
