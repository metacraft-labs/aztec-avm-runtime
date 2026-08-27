# Shared helpers for M26's checks — joining the private and public halves of one transaction.
#
# IT REUSES M24's AND M25's MACHINERY RATHER THAN COPYING IT, for M25's reason.
# `lib_m24_ct_writer.sh` owns the module build, the bounded runner, the abnormal-exit trap, the
# published-refcount predicate and the pin reader; `lib_m25_trace.sh` owns the source-mapping arms
# and the artifact search. M26 builds the SAME module and reads the SAME arms, so a second
# `m24_require_module` would be a second answer to "is the module current".
#
# ---------------------------------------------------------------------------
# THE ABNORMAL-EXIT TRAP IS M24's, AND M26 IS THE FIFTH MILESTONE TO WANT IT.
#
# M22 built it and said a third milestone wanting it is the point at which it moves into `lib.sh`.
# M23 was the second, M24 declined to move it for M22's own stated reason (changing the
# abnormal-exit behaviour of a hundred and fifty checks does not belong in a commit about a trace
# writer), M25 reused M24's, and M24's review found the FOURTH caller retrospectively — M9, whose
# two refusing checks printed no summary and took `verify-m9` from 807 to 524 with no failure
# attributable to it. M26 does not move it either, for the same reason and with the same debt
# recorded: this milestone's commit is about joining two halves of a recording. `m24_finish` and
# `m24_summary_on_abnormal_exit` are what M26's checks call.
# ---------------------------------------------------------------------------

# The Noir tracer worktree the OQ-7 probe's private half comes from.
#
# NOT A PIN, AND THE DIFFERENCE IS PART OF OQ-7's VERDICT. `pins.json` names commits that are
# reachable from a published remote ref, because a pin nobody else can resolve is a local file
# wearing a pin's clothes (M24's review, `CAMPAIGN-BRIEF.md`). The branch this worktree sits on is
# unpublished, so naming it here as a pin would be exactly that. It is an INPUT to a probe, asserted
# clean and asserted to resolve its writer crates at the same revision `pins.json` pins, and the
# fact that it cannot be pinned is the reason the shared path is not the shipped path.
export OQ7_NOIR_ROOT="${OQ7_NOIR_ROOT:-$WORKSPACE_ROOT/noir-wt4-webpage}"

# The Noir tracer checkout whose `Field` RENDERING M26 changes — a different tree from the one
# above, and deliberately so. `SOURCE-MAPPING.md` §4.4 locates the cross-half divergence at
# `tooling/tracer/src/tracer_glue.rs`, in the Metacraft `noir` repository on the branch this
# campaign's Noir work ships from. `test_fr_rendering_matches_noir_tracer` (M25) already reads that
# tree; M26 reads the same one so the two checks cannot disagree about which file they mean.
export M26_NOIR_SOURCE="${M26_NOIR_SOURCE:-$WORKSPACE_ROOT/noir}"

export M26_WORK="${M26_WORK:-$HOME/.cache/aztec-m26-join}"
export M26_ARMS="$M26_WORK/join.json"
export M26_ARMS_TIMEOUT="${M26_ARMS_TIMEOUT:-1800}"
export M26_PROBE_TIMEOUT="${M26_PROBE_TIMEOUT:-900}"

# The metadata key an explicit join record is written under. One string, in three places that must
# agree: the Rust probe, the TypeScript join module and the checks. Asserted equal in all three by
# `test_join_fallback_two_recordings` rather than left as three literals that happen to match.
export M26_JOIN_METADATA="ct.trace-join"

m26_probe_bin() {
  printf '%s\n' "$M26_WORK/oq7-probe/bin/oq7probe"
}

# Build the OQ-7 probe if it is not current. Sets nothing; prints nothing on success.
#
# `m24_require_bounded_logged` and not a bare call: the build is the Noir compiler, and a build that
# hangs behind a cargo lock another agent holds must be a NAMED failure rather than a sweep that
# stops producing output. The redirection binds to `timeout`, not to this function, so the EXIT
# trap's summary line still reaches stdout — M24's defect 7.
m26_require_probe() {
  if ! m24_require_bounded_logged "$M26_ARMS_TIMEOUT" "build_oq7_shared_writer_probe.sh" \
       "$VERIFY_DIR/build_oq7_shared_writer_probe.sh"; then
    die "the OQ-7 shared-writer probe could not be built"
  fi
  [ -x "$(m26_probe_bin)" ] || die "no OQ-7 probe binary at $(m26_probe_bin)"
}

# Run the join arms if `$M26_ARMS` is stale, then require it to be readable JSON.
#
# Sets globals and prints nothing, because a `die` inside `$( … )` kills only the subshell and a
# redirected `require_*` sends the trap's summary to `/dev/null` — M24's defects 5 and 6.
m26_require_arms() {
  m24_require_module
  m26_require_probe

  local stale=0
  [ -s "$M26_ARMS" ] || stale=1
  local input
  # `join_e2e_driver.ts` WAS MISSING FROM THIS LIST and it is the file that BUILDS the transaction
  # half of the report — M26's review added it. A staleness test that omits the producer of the
  # thing it is testing the staleness of will hand every check a stale report and every assertion
  # about a field the driver has just started emitting will read `MISSING`, which is the campaign's
  # "never depend on state you did not produce" with the dependency edge simply absent.
  for input in "$M24_MODULE" "$(m26_probe_bin)" \
               "$REPO_ROOT/tools/run_join_arms.mjs" \
               "$REPO_ROOT/orchestration/src/trace_join.ts" \
               "$REPO_ROOT/orchestration/src/join_e2e_driver.ts" \
               "$REPO_ROOT/orchestration/src/vendor/public_tx_simulation_tester.ts" \
               "$M24_HOST/src/index.ts" "$M24_HOST/src/writer.ts"; do
    [ -f "$input" ] || die "m26_require_arms: a declared input is missing: $input"
    [ "$input" -nt "$M26_ARMS" ] && stale=1
  done

  if [ "$stale" -eq 1 ]; then
    mkdir -p "$M26_WORK" || die "could not create $M26_WORK"
    if ! m24_require_bounded_logged "$M26_ARMS_TIMEOUT" "run_join_arms.mjs" \
         node --experimental-strip-types "$REPO_ROOT/tools/run_join_arms.mjs" "$M26_WORK"; then
      die "the join arms did not complete"
    fi
  fi
  [ -s "$M26_ARMS" ] || die "the join arms produced no $M26_ARMS"
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$M26_ARMS" >/dev/null 2>&1 \
    || die "$M26_ARMS is not readable JSON"
}

# One value out of the arm report.
#
# Prints the loud string `MISSING` rather than nothing on any failure: `assert_eq "" ""` is this
# campaign's oldest vacuity and an empty answer from a crashed reader is indistinguishable from an
# empty answer from a working one.
m26_arm() {
  python3 - "$M26_ARMS" "$1" <<'PY' 2>/dev/null || printf 'MISSING\n'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    v = eval(sys.argv[2], {"d": d})
except Exception:
    print("MISSING"); raise SystemExit(0)
if v is None:
    print("MISSING")
elif isinstance(v, bool):
    print("true" if v else "false")
elif isinstance(v, list):
    print(",".join(str(x) for x in v))
else:
    print(v)
PY
}

# The Noir tracer's `Field` rendering, read out of the checkout M25's §4.4 names.
#
# `git show` out of the object store would be the campaign's usual discipline, but it is the WRONG
# instrument here and saying so is cheaper than a reader discovering it: M26's change to that file
# is uncommitted by construction (an implementation agent makes no commits), so a check that read
# the object store would be reading the state before the change on every run of the milestone that
# makes it. The working tree is what is asserted, and the check asserts the checkout is the one it
# means before reading it.
m26_tracer_glue() {
  cat "$M26_NOIR_SOURCE/tooling/tracer/src/tracer_glue.rs" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Reading a container back.
# ---------------------------------------------------------------------------

# m26_frames <container> — the FRAME TREE, as `KEY<TAB>VALUE` rows.
#
# The decode goes through the PINNED `ct-print` (`m24_require_readers` must have run) and then
# through `verification/_ct_frames.py`, which computes nesting rather than listing names. A check
# that asserted on names alone would be satisfied by a container in which every frame is a sibling,
# and nesting is the claim M26 makes.
#
# Prints `ERR:<what>` on any failure rather than nothing: an empty answer from a crashed reader is
# indistinguishable from an empty answer from a working one, which is this campaign's oldest
# vacuity in its instrument-shaped form.
m26_frames() { # <container>
  local out rc json
  json="$M26_WORK/$(basename "$1" .ct).ct-print.json"
  out="$(m24_ct_print "$M24_CTPRINT_WORK/ct-print" "$1")"
  rc="$(printf '%s\n' "$out" | head -1)"
  if [ "$rc" != "0" ]; then
    printf 'ERR:ct-print-exit-%s\n' "$rc"
    return 0
  fi
  printf '%s\n' "$out" | tail -n +2 > "$json"
  # BOUNDED, because every subprocess a check waits on needs a bound and exceeding it must be a
  # named failure rather than a hang. M23's review found the state M22's abnormal-exit trap cannot
  # reach — a trap fires on exit, and a process that never exits has no exit — in a check that ran a
  # driver with no timeout and sat at zero bytes of output while the whole sweep queued behind it.
  # A reporter over a container the reader already decoded should take milliseconds; 120 s is three
  # orders of magnitude of headroom and still terminates.
  timeout --signal=TERM --kill-after=10 "${M26_FRAMES_TIMEOUT:-120}" \
    python3 "$VERIFY_DIR/_ct_frames.py" "$json" 2>&1
  local rc=$?
  if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
    printf 'ERR:_ct_frames-timed-out-after-%ss\n' "${M26_FRAMES_TIMEOUT:-120}"
  elif [ "$rc" -ne 0 ]; then
    printf 'ERR:_ct_frames-exit-%s\n' "$rc"
  fi
}

# m26_row <report> <key> [field] — one field of the first row with that key. `MISSING` on absence.
m26_row() { # <report> <key> [field-index, default 2]
  local v
  v="$(printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v f="${3:-2}" '$1==k {print $f; exit}')"
  printf '%s\n' "${v:-MISSING}"
}

# m26_rows <report> <key> <field> — every row's field, comma-joined. `MISSING` when there are none.
m26_rows() { # <report> <key> <field-index>
  local v
  v="$(printf '%s\n' "$1" | awk -F'\t' -v k="$2" -v f="$3" '$1==k {printf "%s%s", sep, $f; sep=","} END {print ""}')"
  printf '%s\n' "${v:-MISSING}"
}
