#!/usr/bin/env bash
# e2e_vfs_edit_recompile_retrace
#
# M30's third entry: edit a file, recompile, and the `.ct` changes in the predicted way; the
# unedited arm produces an identical container. Without a reload.
#
# ===========================================================================================
# WHAT THE PAGE DOES, AND WHERE THE JOIN IS.
# ===========================================================================================
#
# Two import-free wasm modules are loaded once:
#
#   `noir_wasm.wasm`         M30's. `nv_compile_vfs` reads `Nargo.toml` out of the virtual
#                            filesystem and answers with a PLAN — which files the program is
#                            made of, and which one is its root — plus a compiled artifact.
#   `noir_tracer_wasm.wasm`  M24's and M26's, built read-only from the `wasm/webpage`
#                            worktree. `ct_trace_source_container` compiles and traces a set
#                            of sources and hands back a real `.ct` container.
#
# The tracer is handed `plan.sources` and `plan.entry_point` AND NOTHING ELSE. It never sees
# the page's tree. That is the join, and §4 makes it falsifiable rather than structural:
# `handedFiles` is reported by the page and compared against the plan, so "the tracer traced
# what the resolver resolved" is a comparison of two recorded lists.
#
# ===========================================================================================
# WHAT IS **NOT** CLAIMED, STATED HERE RATHER THAN LEFT FOR A READER TO NOTICE.
# ===========================================================================================
#
# The two modules do not share a compilation. The tracer compiles the sources it is given a
# second time, with the debug instrumenter on and `force_brillig`, because that is what
# tracing needs; its bytecode is therefore not the artifact's bytecode and no assertion here
# says it is. What is asserted is that the two halves agree about the program's FILES and its
# ROOT — which is what the resolver decides — and that both halves move when a file the plan
# names moves, and neither moves when a file it does not name moves.
#
# ===========================================================================================
# SIX PASSES, ONE PAGE LOAD, AND "WITHOUT RELOAD" IS A NUMBER.
# ===========================================================================================
#
#   A   the tree as authored
#   B   `app/src/util.nr` edited, `x * 2` -> `x * 3`
#   A2  the edit reverted
#   D   `app/aaa_decoy.nr` ADDED — a `.nr` file in the tree that the plan does NOT name
#   E   `app/src/util.nr` edited to something that does not compile
#   A3  reverted again, AFTER the refusal
#
# `instantiations` is 2 (one per module) across all six, `navigationsAfter` equals
# `navigationsBefore`, and `wasmRequests` is 2. A deliverable that says "without reload" and
# is verified by reading the source would be a description; these are counters the page keeps.
#
# ===========================================================================================
# THE IDENTITY ARMS ARE COMPARED BY SHA256, NOT BY SIZE.
# ===========================================================================================
#
# Measured on this fixture: A and B produce containers of exactly the SAME LENGTH — 172,032
# bytes each — because a `.ct` is a directory of block-aligned streams and one arithmetic
# operator does not change how many blocks it takes. A byte-count comparison would have
# reported "identical" for the arm whose whole purpose is to differ. Every comparison here is
# over the sha256 of the container bytes, and the byte count is reported as a NOTE.
#
# Run: just verify-m30-retrace

TEST_NAME="e2e_vfs_edit_recompile_retrace"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"
. "$VERIFY_DIR/lib_m30_vfs.sh"

m30_summary_on_abnormal_exit
command -v python3 >/dev/null 2>&1 || die "python3 is required"

m30_require_arms

echo "== 1. the fields every comparison reads are present"

SHA_A="$(m30_arm arms.trace.a.traced.containerSha256)"
SHA_B="$(m30_arm arms.trace.b.traced.containerSha256)"
SHA_A2="$(m30_arm arms.trace.a2.traced.containerSha256)"
SHA_D="$(m30_arm arms.trace.d.traced.containerSha256)"
SHA_A3="$(m30_arm arms.trace.a3.traced.containerSha256)"
HASH_A="$(m30_arm arms.trace.a.artifact.hash)"
HASH_B="$(m30_arm arms.trace.b.artifact.hash)"
HASH_A2="$(m30_arm arms.trace.a2.artifact.hash)"
HASH_D="$(m30_arm arms.trace.d.artifact.hash)"
BYTES_A="$(m30_arm arms.trace.a.traced.containerBytes)"
EVENTS_A="$(m30_arm arms.trace.a.traced.events)"

ABSENT="$(m30_absent "shaA=$SHA_A" "shaB=$SHA_B" "shaA2=$SHA_A2" "shaD=$SHA_D" "shaA3=$SHA_A3" \
                     "hashA=$HASH_A" "hashB=$HASH_B" "hashA2=$HASH_A2" "hashD=$HASH_D" \
                     "bytesA=$BYTES_A" "eventsA=$EVENTS_A")"
assert_eq "every field the comparisons below read is present" "" "$ABSENT"
[ -z "$ABSENT" ] || die "the arm report is missing $ABSENT; the identity comparisons below would be
             between two absences, which compare EQUAL. A failure, not a smaller check."

assert_eq "the page has no uncaught errors" "[]" "$(m30_arm arms.trace.pageErrors)"
assert_eq "and no console errors" "[]" "$(m30_arm arms.trace.consoleErrors)"

echo "== 2. WITHOUT RELOAD: six passes, one page load, one instantiation per module"

assert_eq "the two modules were instantiated once each and never again" "2" \
  "$(m30_arm arms.trace.instantiations)"
assert_eq "the page navigated exactly once" \
  "$(m30_arm arms.trace.navigationsBefore)" "$(m30_arm arms.trace.navigationsAfter)"
assert_eq "…and that once is one" "1" "$(m30_arm arms.trace.navigationsBefore)"
assert_eq "the two .wasm files were fetched once each" "2" "$(m30_arm arms.trace.wasmRequests)"
assert_eq "and neither module reached an import while doing any of it" \
  '{"compiler":[],"tracer":[]}' "$(m30_arm arms.trace.reachedImports)"

echo "== 3. the container is a real recording, not an empty envelope"

note "container A is $BYTES_A bytes with $EVENTS_A events"
assert_ge "the container is not a stub" 65536 "$BYTES_A"
assert_ge "…and it carries events" 5 "$EVENTS_A"
assert_eq "…and it names both of the program's source files" \
  '["app/src/main.nr","app/src/util.nr"]' "$(m30_arm arms.trace.a.traced.paths)"
assert_eq "…with the recording id the page supplied, so identical inputs are comparable" \
  "01949fcc-7d92-7e9c-8000-0000000030a0" "$(m30_arm arms.trace.a.traced.recordingId)"
# HONEST ABOUT WHAT THIS WRITER DOES NOT CARRY. `ctfs_sink.rs`'s own header says the pure-Rust
# CTFS writer has no column-bearing step encoder, so `meta.dat` bits 4/6/7 stay unset and the
# container is not column-aware. The module REPORTS that rather than letting it pass silently,
# and this check reads the report rather than repeating the sentence.
assert_eq "the container is not column-aware, and the module says so" "false" \
  "$(m30_arm arms.trace.a.traced.columnAware)"
assert_eq "…having been ASKED for columns and dropped them, which is the honest signal" "true" \
  "$(m30_arm arms.trace.a.traced.droppedColumnAwareness)"

echo "== 4. THE JOIN: the tracer traced what the resolver resolved"

PLAN_SOURCES="$(m30_arm arms.trace.a.plan.sources)"
HANDED="$(m30_arm arms.trace.a.traced.handedFiles)"
WANT_SOURCES="$(m30_arm arms.modules.expectations.traceSources)"
assert_eq "the plan and the fixture's own derivation agree about the program's files" \
  "$WANT_SOURCES" "$PLAN_SOURCES"
assert_eq "…and the tracer was handed exactly those files" "$PLAN_SOURCES" "$HANDED"
assert_eq "…and exactly the plan's crate root" "$(m30_arm arms.trace.a.plan.entry_point)" \
  "$(m30_arm arms.trace.a.traced.handedEntryPoint)"
assert_eq "…which is what Nargo.toml's package type implies" \
  "$(m30_arm arms.modules.expectations.traceEntryPoint)" "$(m30_arm arms.trace.a.plan.entry_point)"
assert_eq "…and the container's own path list is that same set" "$PLAN_SOURCES" \
  "$(m30_arm arms.trace.a.traced.paths)"
assert_false "…and app/scratch.nr, which is in the tree, is in none of them" \
  str_has_sub "$PLAN_SOURCES" "scratch"

echo "== 5. EDIT, RECOMPILE, RE-TRACE: the .ct changes in the predicted way"

note "A sha ${SHA_A:0:16}  B sha ${SHA_B:0:16}"
assert_false "editing app/src/util.nr changes the compiled artifact" test "$HASH_A" = "$HASH_B"
assert_false "…and changes the container" test "$SHA_A" = "$SHA_B"
# The container B is the same LENGTH as A. Recorded, because a check that compared lengths
# would have reported these two identical — and because it is the reason every comparison
# here is a sha256.
note "container B is $(m30_arm arms.trace.b.traced.containerBytes) bytes — the same length as A"
assert_eq "…and it is a recording of the same program: the same two files" \
  "$(m30_arm arms.trace.a.traced.paths)" "$(m30_arm arms.trace.b.traced.paths)"
assert_eq "…and the same event count, because only an operator changed" \
  "$EVENTS_A" "$(m30_arm arms.trace.b.traced.events)"

echo "== 6. THE IDENTITY CONTROL: the unedited arm reproduces the container byte for byte"

assert_eq "reverting the edit reproduces the artifact hash" "$HASH_A" "$HASH_A2"
assert_eq "…and the container, byte for byte" "$SHA_A" "$SHA_A2"
# And the identity is not the identity of two nothings: A's sha is a real digest of a real
# container, asserted non-degenerate in §3, and B differs from it in §5. Both directions of
# the instrument are exercised in this run.
assert_eq "…of a container that is 64 hex characters of digest" "64" "${#SHA_A}"

echo "== 7. THE SECOND CONTROL: a file the plan does not name changes nothing"

# `app/aaa_decoy.nr` is a `.nr` file ADDED to the entry package's own directory, outside
# `src/`. This is the assertion that says the resolver's `sources` is a DECISION.
#
# IT IS AN ADDITION AND NOT AN EDIT. Editing a file that is not part of the program cannot
# change the artifact whatever the resolver does, so the first version of this section
# compared two things that were equal by construction — and the mutation harness proved it:
# with the resolver swallowing the whole tree (arm M4) these two assertions stayed GREEN while
# §4's did the catching. An added file enters `sources`, enters the `FileManager`, and shifts
# every later `FileId`, which is what the program `hash` is based on.
assert_eq "adding app/aaa_decoy.nr leaves the artifact hash unchanged" "$HASH_A" "$HASH_D"
assert_eq "…and the container byte-identical" "$SHA_A" "$SHA_D"

echo "== 8. A REFUSAL DOES NOT POISON THE MODULE, AND THE PAGE RECOVERS"

assert_eq "an edit that does not compile is refused" "false" "$(m30_arm arms.trace.e.ok)"
assert_eq "…at the compile stage" "compile" "$(m30_arm arms.trace.e.stage)"
# `None` rather than `MISSING`: the page records the field as a JSON `null`, so the key IS
# present and its value says there is no recording. Asserted as the value the page writes
# rather than as an absence, because `m30_arm` prints `MISSING` for a path that is not there
# and an assertion accepting either would also pass for a typo'd path — which is the shape
# that made five of M29's assertions green over fields that did not exist.
assert_eq "…producing no container at all" "None" "$(m30_arm arms.trace.e.traced)"
assert_false "…while the arm beside it did produce one, so that field is read and not absent" \
  test "$(m30_arm arms.trace.a3.traced.containerSha256)" = "None"
assert_eq "…and the refusal is positioned in the file that was edited" "app/src/util.nr" \
  "$(m30_arm arms.trace.e.diagnostics.0.file)"
assert_ge "…at a real line" 1 "$(m30_arm arms.trace.e.diagnostics.0.line)"
assert_ge "…and a real column" 1 "$(m30_arm arms.trace.e.diagnostics.0.column)"
assert_eq "…and the plan survives it: which files the program is made of is an answer either way" \
  "$PLAN_SOURCES" "$(m30_arm arms.trace.e.plan.sources)"
assert_eq "and the pass AFTER the refusal reproduces the original container byte for byte" \
  "$SHA_A" "$SHA_A3"
assert_eq "…in the same module instance, never re-instantiated" "2" \
  "$(m30_arm arms.trace.instantiations)"

echo "== 9. the two modules are the ones this milestone built"

assert_ge "the compiler module is a real compiler" 5000000 "$(m30_arm compilerModule.bytes)"
assert_ge "the tracer module is a real tracer" 5000000 "$(m30_arm tracerModule.bytes)"
assert_false "…and they are two different modules" \
  test "$(m30_arm compilerModule.sha256)" = "$(m30_arm tracerModule.sha256)"
assert_eq "the tracer's C ABI carries the container entry point the page calls" "true" \
  "$(python3 -c '
import json,sys
print("true" if "ct_trace_source_container" in json.loads(sys.argv[1]) else "false")' \
    "$(m30_arm arms.modules.modules.tracer.exportsCt)")"
# The digest on the left is taken by THIS CHECK, not read out of the report: the runner copies
# the fixture into the site and hashes both ends itself, so `trees.sha256 == trees.servedSha256`
# is true by construction and was an assertion that could not fail.
assert_eq "the trees the page was served are the ones on disk now" \
  "$(sha256sum "$M30_TREES" | cut -d' ' -f1)" "$(m30_arm trees.servedSha256)"

m30_finish
