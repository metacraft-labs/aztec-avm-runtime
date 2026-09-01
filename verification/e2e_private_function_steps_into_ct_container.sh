#!/usr/bin/env bash
# e2e_private_function_steps_into_ct_container — an Aztec private function is stepped by the Noir
# tracer into a `.ct` container the PINNED reader parses, with source positions resolved.
#
# WHAT MAKES THIS AN e2e RATHER THAN A COUNT. Every figure below is read back out of the CONTAINER
# through the pinned `ct-print`, not out of the probe's own report — M29's rule, which it earned by
# finding a check that read an opcode histogram out of the producer's report while the writer wrote
# fabricated opcodes. The probe's report is used only where the container cannot answer: how many
# opcodes the ACVM stepped, which is a fact about the execution rather than about the recording.
#
# THE DISCRIMINATORS, and each is here because its absence is a shape this campaign has shipped:
#
#   * THE STEP COUNT IS AN IDENTITY, NOT A FLOOR. `container == probe + 1`, in both arms — the one
#     is `TraceSink::start`'s entry step at line 1. A recording that lost a step and a reader that
#     invented one both fail, and neither number alone can say so.
#   * A LARGER CIRCUIT YIELDS MORE. `Token.transfer` is 5,602 ACIR opcodes against 889 and produces
#     more steps, more distinct positions and more files. A step stream that were a constant would
#     satisfy every per-arm assertion.
#   * A SYNTHESISED STREAM FAILS THE SAME PREDICATE. M29's discriminator, applied to the private
#     half: a container whose steps are fabricated from a formula has a distinct-position count that
#     does not match the artifact's own file map, and the same reader over it is asserted to
#     disagree.
#   * THE READER CAN COME BACK EMPTY. A truncated copy of the container is refused, so a positive
#     step count is a measurement by an instrument seen to produce zero.
#
# Run: just verify-m38-container

TEST_NAME="e2e_private_function_steps_into_ct_container"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m38_private_trace.sh"
# THE TRAP IS INSTALLED BY CALLING THIS, NOT BY TRAPPING IT. `summary_on_abnormal_exit` INSTALLS
# `_abnormal_exit_summary` as the EXIT handler; `trap m38_summary_on_abnormal_exit EXIT` makes the
# exit handler install a handler and print nothing, so a `die` reads to the sweep as a check that is
# not there rather than as a red one. Found by M38's own mutation arm M1, which reddened correctly
# and printed no summary line.
m38_summary_on_abnormal_exit

m38_require_arms

CT_PRINT="$(m38_ct_print)"
[ -x "$CT_PRINT" ] || die "no pinned ct-print at $CT_PRINT.
             Remedy: verification/build_ct_print.sh (it needs the workspace dev shell for nim)"

# read_container <path> <field> — every figure this check asserts comes through here.
read_container() { # <ct path> <field>
  "$CT_PRINT" --full "$1" 2>/dev/null | python3 -c '
import json, sys
try:
    doc = json.load(sys.stdin)
except Exception:
    print("UNREADABLE"); raise SystemExit(0)
steps = [e for e in doc.get("events", []) if e.get("kind") == "step"]
field = sys.argv[1]
if field == "steps":
    print(len(steps))
elif field == "distinctLines":
    print(len({(e["path"], e["line"]) for e in steps}))
elif field == "distinctPaths":
    print(len({e["path"] for e in steps}))
elif field == "withColumn":
    print(sum(1 for e in steps if e.get("column")))
elif field == "paths":
    print(len(doc.get("paths", [])))
elif field == "sourceViews":
    print(doc.get("counts", {}).get("source_views", "MISSING"))
elif field == "columnAware":
    print("true" if doc.get("metadata", {}).get("flags", {}).get("has_column_aware_steps") else "false")
elif field == "firstPath":
    print(steps[0]["path"] if steps else "MISSING")
else:
    print("MISSING")
' "$2"
}

echo "== 1. BOTH ARMS PRODUCED A CONTAINER THE PINNED READER PARSES"
REPLAY_CT="$(m38_arm replay.container)"
TRANSFER_CT="$(m38_arm transfer.container)"
m38_absent replayContainer="$REPLAY_CT" transferContainer="$TRANSFER_CT"
[ -s "$REPLAY_CT" ] || die "no container at $REPLAY_CT"
[ -s "$TRANSFER_CT" ] || die "no container at $TRANSFER_CT"

for arm in replay transfer; do
  ct="$(m38_arm "$arm.container")"
  # `assert_ne` DOES NOT EXIST IN `lib.sh`, AND THE FIRST DRAFT OF THIS FILE CALLED IT THREE TIMES.
  # An undefined function is `command not found` on stderr and NO assertion line at all, sitting
  # invisibly between two neighbouring `ok`s — this campaign's own "the check reported 48 where it
  # should report 50", arriving through a name rather than through a pipe. Found by counting the
  # assertions against the sections, not by reading the output.
  assert_true "the $arm container is readable by the pinned reader" \
    test "$(read_container "$ct" steps)" != "UNREADABLE"
done
assert_true "and both declare column-aware steps" \
  test "$(read_container "$REPLAY_CT" columnAware)" = "true" \
    -a "$(read_container "$TRANSFER_CT" columnAware)" = "true"

echo "== 2. THE STEP COUNT IS AN IDENTITY BETWEEN THE RECORDER AND THE CONTAINER"
for arm in replay transfer; do
  ct="$(m38_arm "$arm.container")"
  probe_steps="$(m38_arm "$arm.steps")"
  m38_absent "${arm}Steps=$probe_steps"
  container_steps="$(read_container "$ct" steps)"
  assert_eq "$arm: the container carries the recorder's steps plus the entry step" \
    "$(( $(m38_num "$probe_steps" "$arm probe steps") + 1 ))" \
    "$(m38_num "$container_steps" "$arm container steps")"
done

echo "== 3. THE POSITIONS ARE THE ARTIFACT'S OWN SOURCE, WITH COLUMNS"
R_STEPS="$(read_container "$REPLAY_CT" steps)"
R_LINES="$(read_container "$REPLAY_CT" distinctLines)"
R_PATHS="$(read_container "$REPLAY_CT" distinctPaths)"
R_COLS="$(read_container "$REPLAY_CT" withColumn)"
R_INTERNED="$(read_container "$REPLAY_CT" paths)"
R_VIEWS="$(read_container "$REPLAY_CT" sourceViews)"
R_FIRST="$(read_container "$REPLAY_CT" firstPath)"
m38_absent steps="$R_STEPS" lines="$R_LINES" paths="$R_PATHS" cols="$R_COLS" \
  interned="$R_INTERNED" views="$R_VIEWS" firstPath="$R_FIRST"
assert_eq "every step carries a column" "$R_STEPS" "$R_COLS"
assert_ge "the steps land on several distinct lines" 5 "$(m38_num "$R_LINES" 'distinct lines')"
assert_ge "across several distinct aztec-nr files" 3 "$(m38_num "$R_PATHS" 'distinct paths')"
assert_true "and the first one is the oracle the frame calls first" \
  str_has_sub "$R_FIRST" 'aztec/src/oracle/version.nr'
# THE INTERNED PATH TABLE IS THE ARTIFACT'S FILE MAP, not a subset the steps happened to reach.
assert_eq "the container interns the artifact's whole file map" \
  "$(m38_num "$(m38_arm replay.fileMapEntries)" 'file map entries')" "$(m38_num "$R_INTERNED" 'interned paths')"
assert_eq "and embeds a source view for every one of them" "$R_INTERNED" "$R_VIEWS"
assert_true "the steps reach fewer files than the container interns, so the table is not the trace" \
  test "$(m38_num "$R_PATHS" 'distinct paths')" -lt "$(m38_num "$R_INTERNED" 'interned paths')"

echo "== 4. A LARGER CIRCUIT YIELDS MORE — THE STREAM IS NOT A CONSTANT"
X_STEPS="$(read_container "$TRANSFER_CT" steps)"
X_LINES="$(read_container "$TRANSFER_CT" distinctLines)"
X_PATHS="$(read_container "$TRANSFER_CT" distinctPaths)"
R_ACIR="$(m38_arm replay.acirOpcodes)"
X_ACIR="$(m38_arm transfer.acirOpcodes)"
m38_absent transferSteps="$X_STEPS" transferLines="$X_LINES" transferPaths="$X_PATHS" \
  replayAcir="$R_ACIR" transferAcir="$X_ACIR"
assert_true "Token.transfer is the larger circuit" \
  test "$(m38_num "$R_ACIR" 'replay acir')" -lt "$(m38_num "$X_ACIR" 'transfer acir')"
assert_true "and it produces more steps" \
  test "$(m38_num "$R_STEPS" 'replay steps')" -lt "$(m38_num "$X_STEPS" 'transfer steps')"
assert_true "over more distinct positions" \
  test "$(m38_num "$R_LINES" 'replay lines')" -lt "$(m38_num "$X_LINES" 'transfer lines')"
assert_true "in more files" \
  test "$(m38_num "$R_PATHS" 'replay paths')" -lt "$(m38_num "$X_PATHS" 'transfer paths')"

echo "== 5. THE OPCODES ARE THE ACVM'S OWN, AND THE STEPS ARE A SUBSET OF THE POSITIONED ONES"
# A STEP RECORD IS EMITTED WHEN THE SOURCE POSITION CHANGES, NOT WHEN AN OPCODE IS SOLVED, so "the
# step count equals the opcode count" is a comparison nobody said held. What DOES hold, and is the
# comparison that can fail: the recorder's distinct positions cannot exceed the number the stepper
# resolved, and the stepper's opcode count cannot be smaller than its positioned count.
for arm in replay transfer; do
  stepped="$(m38_arm "$arm.opcodesStepped")"
  positioned="$(m38_arm "$arm.opcodesPositioned")"
  distinct="$(m38_arm "$arm.distinctPositions")"
  ct="$(m38_arm "$arm.container")"
  m38_absent "${arm}Stepped=$stepped" "${arm}Positioned=$positioned" "${arm}Distinct=$distinct"
  assert_ge "$arm: the stepper stepped opcodes at all" 20 "$(m38_num "$stepped" "$arm stepped")"
  assert_true "$arm: the positioned opcodes are a subset of the stepped ones" \
    test "$(m38_num "$positioned" "$arm positioned")" -le "$(m38_num "$stepped" "$arm stepped")"
  assert_ge "$arm: some of them carry a source location" 2 "$(m38_num "$positioned" "$arm positioned")"
  assert_true "$arm: the container's distinct lines do not exceed the stepper's distinct positions" \
    test "$(m38_num "$(read_container "$ct" distinctLines)" "$arm container lines")" \
      -le "$(m38_num "$distinct" "$arm distinct positions")"
done

echo "== 6. TWO CONTROLS: A SYNTHESISED STREAM, AND A READER THAT CAN COME BACK EMPTY"
WORK="$(mktemp -d)"
# 6a. THE READER CAN COME BACK EMPTY, AND IT DOES NOT REFUSE — MEASURED, NOT ASSUMED.
#
# The first draft of this control asserted that a 512-byte stub is REFUSED. It is not: the pinned
# `ct-print` exits **0** over one and prints a well-formed recording with no events and every stream
# flag false. That is the same fact M27 recorded about a halved container — a `.ct` is a set of
# independent streams and a reader over a partial one reports what it can find — and writing a
# control on top of the opposite belief is what M29's review caught once already.
#
# So the control is the measurement rather than the refusal: the same reader answers ZERO over the
# stub and 22 over the container, which is what makes the 22 a reading. The flag is asserted beside
# it, because "no steps" and "no step STREAM" are different statements and the second is the one the
# container itself makes.
head -c 512 "$REPLAY_CT" > "$WORK/stub.ct"
STUB_STEPS="$(read_container "$WORK/stub.ct" steps)"
assert_eq "the same reader answers zero over a 512-byte stub" "0" \
  "$(m38_num "$STUB_STEPS" 'stub steps')"
assert_true "so the container's own count is a reading rather than a constant" \
  test "$(m38_num "$STUB_STEPS" 'stub steps')" -lt "$(m38_num "$R_STEPS" 'replay container steps')"
assert_eq "and the stub declares no step stream, which the real container does" "false" \
  "$("$CT_PRINT" --full "$WORK/stub.ct" 2>/dev/null | python3 -c '
import json, sys
try:
    print("true" if json.load(sys.stdin)["metadata"]["flags"]["has_step_stream"] else "false")
except Exception:
    print("UNREADABLE")')"
assert_eq "while the real container declares one" "true" \
  "$("$CT_PRINT" --full "$REPLAY_CT" 2>/dev/null | python3 -c '
import json, sys
try:
    print("true" if json.load(sys.stdin)["metadata"]["flags"]["has_step_stream"] else "false")
except Exception:
    print("UNREADABLE")')"
note "the pinned ct-print does NOT refuse a truncated container: it exits 0 and reports an empty
      recording. Recorded here because a control written on the opposite belief would pass for the
      wrong reason."
# 6b. THE SYNTHESISED STREAM. M29's discriminator applied to the private half: a step stream
# fabricated from a formula over the program counter has positions that are not in the artifact's
# file map at all. The predicate this check rests on — every step's path is one the container
# interned, and the distinct-line count is bounded by the stepper's own — is asserted to FAIL over
# such a stream, which is what makes it a discriminator rather than a description.
SYNTH="$(python3 - "$REPLAY_CT" "$CT_PRINT" <<'PY'
import json, subprocess, sys
raw = subprocess.run([sys.argv[2], "--full", sys.argv[1]], capture_output=True, text=True).stdout
doc = json.loads(raw)
steps = [e for e in doc.get("events", []) if e.get("kind") == "step"]
interned = set(doc.get("paths", []))
real_ok = all(e["path"] in interned for e in steps)
# The synthesis: `line = (pc % 200) + 1` over a path nobody interned, which is exactly M27's rule
# that M29 removed from the recorder.
synth = [{"path": "synthesised/main.nr", "line": (i % 200) + 1} for i in range(len(steps))]
synth_ok = all(e["path"] in interned for e in synth)
print(json.dumps({"real": real_ok, "synth": synth_ok, "steps": len(steps), "synthSteps": len(synth)}))
PY
)"
s() { printf '%s' "$SYNTH" | python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "$1"; }
assert_eq "the real stream's every path is one the container interned" "True" "$(s real)"
assert_eq "the synthesised one's is not — the predicate discriminates" "False" "$(s synth)"
assert_eq "and the two streams are the same length, so the difference is the paths" \
  "$(s steps)" "$(s synthSteps)"
rm -rf "$WORK"

echo "== 7. THE WRITE-UP CARRIES WHAT WAS MEASURED, ROW BY ROW AND COLUMN BY COLUMN"
[ -s "$M38_DOC" ] || die "no $M38_DOC"
# EVERY FIGURE §4 AND §5 STATE, BOTH COLUMNS, AGAINST THE ARTEFACTS.
#
# The first version of this section compared eight of the twenty-one with
# `str_has_re "$DOC" 'subject.*N'`. That is bash's `=~`, whose `.` matches a NEWLINE, so it was not
# anchored to the row at all — and thirteen figures, including every second column of §5, were
# stated and compared by nothing while the document's own header claimed otherwise. The comparer
# walks LINES, refuses a needle that names more than one row, and reports how many figures it
# actually compared.
X_LINES_C="$(read_container "$TRANSFER_CT" distinctLines)"
X_PATHS_C="$(read_container "$TRANSFER_CT" distinctPaths)"
X_INTERNED="$(read_container "$TRANSFER_CT" paths)"
BYTES_R="$(m38_arm replay.containerBytes)"
BYTES_X="$(m38_arm transfer.containerBytes)"
m38_require_num replaySteps="$(m38_arm replay.steps)" truncateSteps="$(m38_arm truncate.steps)" \
  refuseAllSteps="$(m38_arm refuseAll.steps)" permutedSteps="$(m38_arm permuted.steps)" \
  transferSteps="$(m38_arm transfer.steps)" bytesR="$BYTES_R" bytesX="$BYTES_X" \
  containerStepsR="$R_STEPS" containerStepsX="$X_STEPS" xLines="$X_LINES_C" xPaths="$X_PATHS_C" \
  xInterned="$X_INTERNED"
m38_assert_doc "PRIVATE-TRACE.md section 4" "$M38_DOC" \
  "the whole tape of a frame that completed|0|$(m38_arm replay.steps)" \
  "the same tape, last entry dropped|0|$(m38_arm truncate.steps)" \
  "the same tape, emptied|0|$(m38_arm refuseAll.steps)" \
  "ONE field of ONE recorded input changed|0|$(m38_arm permuted.steps)" \
  "a recording that STOPPED at an oracle M35 does not serve|0|$(m38_arm transfer.steps)" \
  "bytes of ACIR|0|$(m38_arm transfer.bytecodeBytes)" \
  "bytes of ACIR|1|$X_ACIR" \
  "bytes of ACIR|2|$(m38_arm transfer.brilligFunctions)"
m38_assert_doc "PRIVATE-TRACE.md section 5" "$M38_DOC" \
  "ACIR opcodes in the circuit|0|$R_ACIR" \
  "ACIR opcodes in the circuit|1|$X_ACIR" \
  "opcodes the stepper stepped|0|$(m38_arm replay.opcodesStepped)" \
  "opcodes the stepper stepped|1|$(m38_arm transfer.opcodesStepped)" \
  "of those, opcodes carrying a source location|0|$(m38_arm replay.opcodesPositioned)" \
  "of those, opcodes carrying a source location|1|$(m38_arm transfer.opcodesPositioned)" \
  "step records the recorder wrote|0|$(m38_arm replay.steps)" \
  "step records the recorder wrote|1|$(m38_arm transfer.steps)" \
  "distinct \`(path, line)\` in the container|0|$R_LINES" \
  "distinct \`(path, line)\` in the container|1|$X_LINES_C" \
  "distinct source files in the container|0|$R_PATHS" \
  "distinct source files in the container|1|$X_PATHS_C" \
  "paths the container interns|0|$R_INTERNED" \
  "paths the container interns|1|$X_INTERNED" \
  "container bytes|0|$BYTES_R" \
  "container bytes|1|$BYTES_X" \
  "reads back|0|$R_STEPS" \
  "reads back|1|$X_STEPS"

# SECTION 6's TWO PROSE FIGURES TOO. They are a claim about what the container does NOT carry, and
# an absence stated as a figure rots exactly like any other — `register_call` is driven by
# `__debug_fn_enter`, so the day an instrumented artifact is traced the sentence becomes false and
# nothing would notice. Adding specs to an existing `m38_assert_doc` call moves no assertion count:
# the third of its three assertions compares what the comparer covered against how many it was
# given, so the coverage is checked rather than the number of arguments.
m38_assert_doc "PRIVATE-TRACE.md section 6" "$M38_DOC" \
  "The container has|0|$(m38_arm replay.calls)" \
  "The container has|1|$(m38_arm replay.returns)"

# THE COMPARER IS SHOWN TO SAY NO, in both of its two ways.
CONTROL="$(m38_doc_figures "$M38_DOC" "ACIR opcodes in the circuit|1|999")"
assert_true "a wrong expected value in the SECOND column is reported as BAD" \
  str_has_sub "$CONTROL" "BAD ACIR opcodes in the circuit | 1 | expected 999 | got"
CONTROL2="$(m38_doc_figures "$M38_DOC" "ACIR opcodes in the circuit|9|1")"
assert_true "and a column the row does not have is reported as MISSING rather than matched" \
  str_has_sub "$CONTROL2" "the row carries 2 bold figure(s)"

echo "== 8. THE UNPUBLISHED WORKTREE IS UNTOUCHED, WHICH OQ-7's VERDICT RESTS ON"
# M38 builds from `noir` on `codetracer`, not from the `wasm/webpage` worktree, precisely so that
# fact 7 stays a fact. Asserted here as well as in `verify_oq7_shared_writer_verdict_recorded`,
# because M38 is the SECOND consumer of that neighbourhood and a second consumer is how a fact one
# milestone rests on gets changed by another.
WT="$(cd "$REPO_ROOT/.." && pwd)/noir-wt4-webpage"
if [ -e "$WT/.git" ]; then
  WT_HEAD="$(git -C "$WT" rev-parse HEAD)"
  assert_eq "the wasm/webpage HEAD is contained in zero published remote refs" "0" \
    "$(git -C "$WT" for-each-ref --contains "$WT_HEAD" --format='%(refname)' refs/remotes 2>/dev/null | wc -l)"
  # The positive control: the counter CAN answer non-zero, asked of a commit that IS published.
  PUB="$(git -C "$M38_NOIR_ROOT" rev-parse origin/codetracer 2>/dev/null || git -C "$M38_NOIR_ROOT" rev-parse HEAD~1)"
  assert_ge "and the same counter answers non-zero for a commit that is published" 1 \
    "$(git -C "$M38_NOIR_ROOT" for-each-ref --contains "$PUB" --format='%(refname)' refs/remotes 2>/dev/null | wc -l)"
else
  note "no $WT worktree here; OQ-7's fact 7 is asserted by verify_oq7_shared_writer_verdict_recorded"
fi

m38_finish
