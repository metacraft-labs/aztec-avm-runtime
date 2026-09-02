#!/usr/bin/env bash
# M26 verification: OQ-7 is settled with its EVIDENCE, and the implemented path follows the verdict.
#
#   verification/verify_oq7_shared_writer_verdict_recorded.sh    (or: just verify-oq7)
#
# ---------------------------------------------------------------------------
# "SETTLED" IS NOT A CHECKABLE WORD, SO WHAT IS CHECKED IS THE SEVEN FACTS THE VERDICT RESTS ON —
# each RE-DERIVED here rather than read back out of the document that quotes it.
#
#   1  one wasm instance holds ONE writer            run: a second ct_writer_open answers -7
#   2  two instances do NOT share                    run: two instances, disjoint pcs, two containers
#   3  noir_tracer is writer-AGNOSTIC                read: `&mut dyn TraceSink`, optional nim-writer
#   4  a TraceSink over the pure-Rust writer exists  read: tracer_wasm's CtfsSink
#   5  so one module with both producers WORKS       run: the probe's container, through the reader
#   6  the shipping Noir branch links Path B         read: noir/Cargo.toml
#   7  the branch where both link Path A is UNPUBLISHED   run: for-each-ref --contains
#
# FACTS 6 AND 7 ARE THE VERDICT AND THE OTHERS ARE WHY IT IS INTERESTING. A milestone that asserted
# only "sharing works" would have recorded a capability and called it a decision.
#
# THE PUBLICATION PREDICATE CARRIES ITS OWN NEGATIVE CONTROL, because "zero remote refs contain this
# commit" is an assertion that a broken predicate satisfies for free — and that a directory which is
# not a git repository satisfies for free too, which is how the first draft of the control came to
# agree with its subject. The control is `origin/master` IN THE SAME REPOSITORY.
# ---------------------------------------------------------------------------

set -uo pipefail

TEST_NAME=verify_oq7_shared_writer_verdict_recorded
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
. "$VERIFY_DIR/lib_m24_ct_writer.sh"
. "$VERIFY_DIR/lib_m26_join.sh"

m24_summary_on_abnormal_exit

DOC="$REPO_ROOT/JOIN-SHAPE.md"
assert_file "the OQ-7 verdict document exists" "$DOC"
DOC_TEXT="$(cat "$DOC" 2>/dev/null)"
# TWO VIEWS OF THE DOCUMENT, M24's defect 12: the file for tables and anchored patterns, and a
# whitespace-flattened copy for prose, because a needle that spans this file's 100-column wrap
# matches nothing for a reason that has nothing to do with its subject.
DOC_FLAT="$(printf '%s\n' "$DOC_TEXT" | tr '\n' ' ' | tr -s ' ')"
assert_ge "the document reads back" 100 "$(printf '%s\n' "$DOC_TEXT" | grep -c . || true)"
assert_true "the flattened view is non-empty and is still this document" \
  str_has_sub "$DOC_FLAT" 'Joining the private and public halves — OQ-7, settled'

m24_require_module
m24_require_readers
m26_require_arms

# ===========================================================================
# FACT 1 — one instance, one writer. The module's own answer, run rather than restated.
# ===========================================================================
assert_eq "the first ct_writer_open on a fresh instance succeeds" "0" \
  "$(m26_arm 'd["module"]["secondOpen"]["first"]')"
assert_eq "…and a SECOND on the same instance is refused with CT_ERR_ALREADY_OPEN" "-7" \
  "$(m26_arm 'd["module"]["secondOpen"]["second"]')"
assert_true "…naming the reason rather than returning a bare code" \
  str_has_sub "$(m26_arm 'd["module"]["secondOpen"]["message"]')" \
  'a writer is already open; call ct_writer_close first'
assert_true "the document records fact 1 with the code it measured" \
  str_has_sub "$DOC_FLAT" 'a second `ct_writer_open` returns `CT_ERR_ALREADY_OPEN` (−7)'

# ===========================================================================
# FACT 2 — two instances do NOT share. Disjoint event counts and different containers.
# ===========================================================================
A_EVENTS="$(m26_arm 'd["module"]["twoInstances"]["a"]["events"]')"
B_EVENTS="$(m26_arm 'd["module"]["twoInstances"]["b"]["events"]')"
assert_eq "instance A recorded its own six events and only those" "6" "$A_EVENTS"
assert_eq "instance B recorded its own four events and only those" "4" "$B_EVENTS"
# THE POINT OF THE ASYMMETRY: if either writer had seen the other's events the counts would be 10.
assert_false "…so neither container holds the other's events" \
  test "$A_EVENTS" = "$B_EVENTS"
assert_eq "…and the two containers are not byte-identical" "false" \
  "$(m26_arm 'd["module"]["twoInstances"]["identicalBytes"]')"
# The join record written into A and not into B, which is the same fact from the other side.
assert_eq "the join record A wrote is A's" "1" \
  "$(m26_arm 'd["module"]["twoInstances"]["a"]["logEvents"]')"
assert_eq "…and B, which wrote none, reports none" "0" \
  "$(m26_arm 'd["module"]["twoInstances"]["b"]["logEvents"]')"

# ===========================================================================
# FACT 3 and FACT 4 — the Noir side is writer-agnostic, and an adapter already exists.
#
# Read from the worktree the probe builds from, because that is the tree the claim is about.
# ===========================================================================
TRACER_LIB="$(cat "$OQ7_NOIR_ROOT/tooling/tracer/src/lib.rs" 2>/dev/null)"
TRACER_TOML="$(cat "$OQ7_NOIR_ROOT/tooling/tracer/Cargo.toml" 2>/dev/null)"
SINK_RS="$(cat "$OQ7_NOIR_ROOT/tooling/tracer_wasm/src/ctfs_sink.rs" 2>/dev/null)"
assert_ge "the Noir tracer's lib.rs reads back" 300 "$(printf '%s\n' "$TRACER_LIB" | grep -c . || true)"
assert_ge "…its Cargo.toml reads back" 20 "$(printf '%s\n' "$TRACER_TOML" | grep -c . || true)"
assert_ge "…and tracer_wasm's CtfsSink reads back" 200 "$(printf '%s\n' "$SINK_RS" | grep -c . || true)"
assert_true "trace_circuit takes a TRAIT OBJECT, not a writer type" \
  str_has_sub "$TRACER_LIB" '    tracer: &mut dyn TraceSink,'
assert_true "…and its writer dependency is OPTIONAL" \
  str_has_sub "$TRACER_TOML" 'codetracer_trace_writer = { workspace = true, optional = true }'
assert_true "…behind a feature whose default is off" \
  str_has_line "$TRACER_TOML" 'default = []'
assert_true "…named nim-writer, so what is optional is PATH B specifically" \
  str_has_line "$TRACER_TOML" 'nim-writer = ["dep:codetracer_trace_writer"]'
assert_true "a TraceSink over the PURE-RUST writer already exists" \
  str_has_sub "$SINK_RS" 'use codetracer_trace_writer_rs::ctfs_writer::CtfsTraceWriter;'
assert_true "…and it is what the wasm shell drives" \
  str_has_sub "$SINK_RS" 'impl TraceSink for CtfsSink'
# The negative control for the four reads above: a needle in none of the three files.
assert_false "a needle in none of the three Noir files does not match" \
  str_has_sub "$TRACER_LIB$TRACER_TOML$SINK_RS" 'fn trace_circuit_with_two_writers'

# ===========================================================================
# FACT 5 — one module, two producers, one container. Run, and read back.
# ===========================================================================
SHARED_CT="$M26_WORK/oq7-shared.ct"
assert_file "the probe produced the shared container" "$SHARED_CT"
assert_eq "…and the probe reports ONE container for that arm" "1" \
  "$(m26_arm 'd["shared"]["containers"]')"
SHARED="$(m26_frames "$SHARED_CT")"
assert_false "the pinned reader read it rather than refusing" str_has_sub "$SHARED" 'ERR:'
assert_ge "…and it decoded a substantial number of events" 100 "$(m26_row "$SHARED" EVENTS)"
# BOTH producers are present, by NAME, in one container. Names come from the two sides:
# `main`/`foo`/`bar` are the Noir program's own functions, and `Token.transfer_in_public` is
# upstream's `getDebugFunctionName`, forwarded from the TypeScript side.
FRAME_NAMES="$(m26_rows "$SHARED" FRAME 4)"
assert_true "the private half's frames are in it, by the Noir program's own function names" \
  str_has_sub "$FRAME_NAMES" 'main,foo,bar'
assert_true "…and so is the public half's, by upstream's debug function name" \
  str_has_sub "$FRAME_NAMES" "$(m26_arm 'd["tx"]["debugFunctionName"]')"
# THE IDENTITY, AND IT IS AN IDENTITY RATHER THAN A BOUND. The `split` arm writes the SAME two
# halves into two containers; the `shared` arm writes them into one. So the shared container's step
# count must equal the sum of the two split containers' — a relation neither run can satisfy by
# accident, and one that a shared container silently missing a half would fail.
#
# (The first draft of this block compared `m26_row "$SHARED" STEPS` WITH ITSELF, which is this
# campaign's most degenerate vacuity and is named in its own brief. It is recorded here rather than
# quietly replaced.)
SPLIT_PRIV="$(m26_frames "$M26_WORK/oq7-split.private.ct")"
SPLIT_PUB="$(m26_frames "$M26_WORK/oq7-split.public.ct")"
assert_false "the split private half read back rather than refusing" str_has_sub "$SPLIT_PRIV" 'ERR:'
assert_false "the split public half read back rather than refusing" str_has_sub "$SPLIT_PUB" 'ERR:'
PRIV_STEPS="$(m26_row "$SPLIT_PRIV" STEPS)"
PUB_STEPS="$(m26_row "$SPLIT_PUB" STEPS)"
assert_ge "the split private half has steps of its own" 1 "$PRIV_STEPS"
assert_ge "the split public half has steps of its own" 1 "$PUB_STEPS"
# Guarded: `$(( MISSING + MISSING ))` is an unbound variable under `set -u`, which would kill the
# check here rather than redden it — see `test_private_public_frame_nesting`'s note on the same
# family, found by M26's own mutation matrix.
SUM_STEPS="UNCOMPUTABLE"
case "$PRIV_STEPS$PUB_STEPS" in ''|*[!0-9]*) ;; *) SUM_STEPS="$((PRIV_STEPS + PUB_STEPS))" ;; esac
assert_eq "…and the SHARED container holds exactly the two halves' steps together" \
  "$SUM_STEPS" "$(m26_row "$SHARED" STEPS)"

# ===========================================================================
# FACT 6 — the branch the Noir tracer SHIPS from links a different writer.
#
# THIS IS THE VERDICT'S FIRST HALF AND IT IS READ OUT OF TWO Cargo.tomls, not out of prose.
# ===========================================================================
SHIP_TOML="$(cat "$M26_NOIR_SOURCE/Cargo.toml" 2>/dev/null)"
WEB_TOML="$(cat "$OQ7_NOIR_ROOT/Cargo.toml" 2>/dev/null)"
assert_ge "the shipping Noir checkout's workspace manifest reads back" 100 \
  "$(printf '%s\n' "$SHIP_TOML" | grep -c . || true)"
assert_ge "…and the probe worktree's does too" 100 "$(printf '%s\n' "$WEB_TOML" | grep -c . || true)"
assert_true "the shipping branch resolves codetracer_trace_writer to the NIM writer — DD-7's Path B" \
  str_has_sub "$SHIP_TOML" 'package = "codetracer_trace_writer_nim" }'
assert_false "…and NOT to the pure-Rust writer this runtime links" \
  str_has_sub "$SHIP_TOML" 'codetracer_trace_writer = { path = "../ctf-wt-wasm/codetracer_trace_writer" }'
assert_true "the probe worktree carries the pure-Rust writer under a SECOND alias" \
  str_has_sub "$WEB_TOML" 'codetracer_trace_writer_rs = { path = "../ctf-wt-wasm/codetracer_trace_writer", package = "codetracer_trace_writer" }'
assert_true "…and its own comment says that alias is NOT what nargo trace uses" \
  str_has_sub "$WEB_TOML" 'It is NOT used'
assert_true "…while `codetracer_trace_writer` there is STILL the Nim one" \
  str_has_sub "$WEB_TOML" 'codetracer_trace_writer = { path = "../ctf-wt-wasm/codetracer_trace_writer_nim", package = "codetracer_trace_writer_nim" }'
assert_true "the document records fact 6" \
  str_has_sub "$DOC_FLAT" 'the shipping Noir branch links a **different writer**'

# ===========================================================================
# FACT 7 — that branch is UNPUBLISHED, so the shared path cannot be pinned.
#
# The predicate is M24's `m24_published_refcount`, and it carries its own control HERE as it does
# there: an assertion that some commit is contained in zero remote refs is satisfied by a predicate
# that answers zero to everything.
# ===========================================================================
WEB_HEAD="$(git -C "$OQ7_NOIR_ROOT" rev-parse HEAD 2>/dev/null)"
assert_ge "the probe worktree's HEAD reads back as a sha" 40 "${#WEB_HEAD}"
assert_eq "…and NO published remote ref contains it" "0" \
  "$(m24_published_refcount "$OQ7_NOIR_ROOT" "$WEB_HEAD")"
# THE CONTROL, AND IT IS THE SAME REPOSITORY. An assertion that some commit is contained in zero
# remote refs is satisfied for free by a predicate that answers zero to everything, and by a
# directory that is not a git repository at all — which is exactly what the first draft of this
# control used (`build-wasm-deps/ctf` is a `git archive` extraction, so the predicate short-circuits
# to 0 and the "control" agreed with the subject). Asked of `$OQ7_NOIR_ROOT`'s own
# `refs/remotes/origin/master`, the same predicate over the same object store must answer non-zero.
PUBLISHED_CONTROL="$(git -C "$OQ7_NOIR_ROOT" rev-parse refs/remotes/origin/master 2>/dev/null)"
assert_ge "the control commit reads back as a sha" 40 "${#PUBLISHED_CONTROL}"
assert_false "…and it is NOT the worktree's HEAD, so the two answers are about different commits" \
  test "$PUBLISHED_CONTROL" = "$WEB_HEAD"
assert_ge "…while the SAME predicate over the SAME repository answers NON-ZERO for it" 1 \
  "$(m24_published_refcount "$OQ7_NOIR_ROOT" "$PUBLISHED_CONTROL")"
assert_true "the document records fact 7, and records it as the REASON rather than as a note" \
  str_has_sub "$DOC_FLAT" 'A pin that is not published is not a pin'

# ===========================================================================
# THE VERDICT, AND THAT THE IMPLEMENTED PATH FOLLOWS IT.
#
# The deliverable's own words are "records a verdict with its evidence, and the implemented path
# follows it". The second clause is the one a document cannot satisfy by itself, so it is asserted
# against the SHIPPED CODE and against the containers the runtime produced.
# ===========================================================================
assert_true "the document states the verdict in one place, in both directions" \
  str_has_sub "$DOC_FLAT" 'Sharing is POSSIBLE and is demonstrated on one container. It is NOT SHIPPABLE'
assert_true "…and names the fallback as the shipped path" \
  str_has_sub "$DOC_FLAT" 'is the shipped path'

# The implemented path: the SHIPPED module can write a join record, and does.
assert_eq "the shipped module exports the join surface, in its own list" "6" \
  "$(m26_arm 'd["module"]["exports"]["join"]')"
assert_eq "…and the list is exactly the six names the host requires, by NAME" \
  "ct_log_event,ct_log_event_count,ct_call,ct_return,ct_call_depth,ct_calls_opened" \
  "$(m26_arm 'd["module"]["exports"]["joinNames"]')"
assert_eq "…M24's nineteen are untouched" "19" "$(m26_arm 'd["module"]["exports"]["required"]')"
assert_eq "…M25's eleven are untouched" "11" "$(m26_arm 'd["module"]["exports"]["sourceMapping"]')"
# AND M40's TWO, in a fourth list for the reason this one is in its own: a milestone that appended
# to another's list would move that milestone's assertion count for a change that is not its.
assert_eq "…M40's two source-step exports are beside them" "2" "$(m26_arm 'd["module"]["exports"]["sourceStep"]')"
assert_eq "…and the union is the four lists" "38" "$(m26_arm 'd["module"]["exports"]["all"]')"
# The module REFUSES an empty metadata key, and the refusal does not count as a record.
assert_eq "an empty metadata key is refused with CT_ERR_BAD_LENGTH" "status:-4" \
  "$(m26_arm 'd["module"]["logEventRefusals"]["emptyKey"]')"
assert_eq "…and the session had written none before the first real one" "0" \
  "$(m26_arm 'd["module"]["logEventRefusals"]["beforeAny"]')"
assert_eq "…one after it, counted by the MODULE and not by the host" "1" \
  "$(m26_arm 'd["module"]["logEventRefusals"]["afterOne"]')"
assert_eq "…and still one at close, so the refusal wrote nothing" "1" \
  "$(m26_arm 'd["module"]["logEventRefusals"]["atClose"]')"
# The public half of the fallback is written by the SHIPPED module, which is what makes the
# fallback a deliverable rather than a probe.
assert_eq "the fallback's public half was written by the shipped module, carrying its join record" "1" \
  "$(m26_arm 'd["split"]["public"]["logEvents"]')"
assert_eq "…with the contract's rung declared beside it" "1" \
  "$(m26_arm 'd["split"]["public"]["rungsDeclared"]')"
assert_ge "…and real steps in it" 1 "$(m26_arm 'd["split"]["public"]["events"]')"

# ===========================================================================
# THE DOCUMENT'S OWN FIGURES, RE-DERIVED. A figure nobody re-derives rots.
# ===========================================================================
assert_true "the document quotes the measured private/public event counts of the two instances" \
  str_has_sub "$DOC_FLAT" "**$A_EVENTS** and **$B_EVENTS** events"
SHARED_STEPS="$(m26_row "$SHARED" STEPS)"
assert_true "…and the shared container's MEASURED step count" \
  str_has_sub "$DOC_FLAT" "**$SHARED_STEPS steps**"
assert_true "…and the module's byte cost of the join surface, as TRACE-ABI.md re-derives it" \
  str_has_sub "$DOC_FLAT" "**$(python3 -c 'import sys;print(f"{int(sys.argv[1]):,}")' \
    "$(m26_arm 'd["config"]["moduleBytes"]')") bytes**"

m24_finish
