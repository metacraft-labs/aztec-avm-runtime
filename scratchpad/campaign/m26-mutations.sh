#!/usr/bin/env bash
# M26's mutation matrix. ONE mutation at a time, restored and VERIFIED restored before the next.
#
#   direnv exec <repo> bash scratchpad/campaign/m26-mutations.sh [<arm> ...]
#
# ---------------------------------------------------------------------------
# THE RULES THIS HARNESS EXISTS TO OBEY, each of which is a defect this campaign has shipped:
#
#   * IT RESTORES AND THEN `touch`es. A mutated artefact outliving its restored source has appeared
#     three times in three disguises (`cp -p` mtime, `git archive` timestamps, cargo fingerprinting
#     on mtime). Every restore is followed by a `touch` and by a sha256 comparison against the
#     backup taken before the mutation.
#   * IT NEVER RUNS BESIDE A SWEEP. A mutation harness and a verification sweep are TWO WRITERS
#     over one working copy. This file refuses to start if a `verify-m` process is running.
#   * IT REPORTS WHICH ASSERTIONS WENT RED, not merely that the check failed. "The check failed" and
#     "the check saw what I broke" are different statements and only the second is coverage.
#   * IT INCLUDES A HANG AND A DIE-BEFORE-SUMMARY ARM, because a check that hangs never reddens and
#     a check that dies before its summary reads as a SMALLER milestone rather than a red one.
# ---------------------------------------------------------------------------

set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.." || exit 1
REPO="$PWD"
OUT="${M26_MUT_OUT:-$HOME/.cache/aztec-m26-mut}"
mkdir -p "$OUT" || exit 1

if pgrep -f 'verify-m[0-9]' >/dev/null 2>&1 || pgrep -f 'm2[0-9]-sweep' >/dev/null 2>&1; then
  echo "REFUSING: a verification sweep looks like it is running; two writers over one working copy" >&2
  exit 2
fi

BACKUPS=()
restore_all() {
  local b f
  for b in "${BACKUPS[@]:-}"; do
    [ -n "$b" ] || continue
    f="${b#*::}"
    cp "$OUT/${b%%::*}" "$f" || echo "RESTORE-FAILED $f" >&2
    touch "$f"
  done
  BACKUPS=()
}
trap 'restore_all' EXIT INT TERM

backup() { # <path>
  local key
  key="$(printf '%s' "$1" | tr '/.' '__')"
  cp "$1" "$OUT/$key" || exit 1
  sha256sum "$1" | cut -d' ' -f1 > "$OUT/$key.sha"
  BACKUPS+=("$key::$1")
}

verify_restored() { # <path>
  local key want got
  key="$(printf '%s' "$1" | tr '/.' '__')"
  want="$(cat "$OUT/$key.sha")"
  got="$(sha256sum "$1" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then
    echo "!! NOT RESTORED: $1" >&2
    exit 3
  fi
  printf '   restored-and-verified %s\n' "$1"
}

run_check() { # <arm> <check-basename>
  local arm="$1" check="$2" log="$OUT/$1.log"
  timeout --signal=TERM --kill-after=30 "${M26_MUT_TIMEOUT:-1800}" \
    "verification/$check.sh" > "$log" 2>&1
  local rc=$?
  printf '== %s  check=%s  rc=%s\n' "$arm" "$check" "$rc"
  printf '   summary: %s\n' "$(grep -E '^[A-Za-z_0-9 .-]+: [0-9]+ assertion' "$log" | tail -1)"
  printf '   red assertions:\n'
  grep '^  FAIL' "$log" | sed 's/^/     /' | head -12
  [ "$(grep -c '^  FAIL' "$log" || true)" -gt 12 ] && printf '     … and more\n'
  return 0
}

want="${*:-A B C D E F G H I}"

# ---------------------------------------------------------------------------
# A — a vendored line corrupted IN PLACE, one for one. M22's review's shape.
#     Every count and every shape is unchanged; only the content moves.
# ---------------------------------------------------------------------------
if [[ " $want " == *" A "* ]]; then
  F="$REPO/orchestration/src/vendor/simple_contract_data_source.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    this.contractInstances.set(contractInstance.address.toString(), contractInstance);"
new = "    this.contractInstances.set(contractInstance.address.toString(), contractInstance.address);"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  run_check A verify_tx_builder_vendored_not_reimplemented
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# B — a severed edge comes back: the `lodash.merge` import the trim removed.
#     RI-72's "no new package dependency" sentence does not cover it, which is
#     why the vendoring check asserts it by name.
# ---------------------------------------------------------------------------
if [[ " $want " == *" B "* ]]; then
  F="$REPO/orchestration/src/vendor/avm_fixtures_utils.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "import { strict as assert } from 'assert';"
new = "import { strict as assert } from 'assert';\nimport merge from 'lodash.merge';"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  run_check B verify_tx_builder_vendored_not_reimplemented
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# C — the join record loses its `halves` field. A reader handed one half can no
#     longer tell it from a whole recording, which is the field's whole point.
# ---------------------------------------------------------------------------
if [[ " $want " == *" C "* ]]; then
  F="$REPO/orchestration/src/trace_join.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "  return `join=${r.joinId} half=${r.half} halves=${r.halves} arm=${r.arm} reason=${r.reason}`;"
new = "  return `join=${r.joinId} half=${r.half} arm=${r.arm} reason=${r.reason}`;"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  run_check C test_join_fallback_two_recordings
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# D — the join becomes INFERRED: a half with no record is accepted instead of
#     refused. The one mutation that makes the deliverable's own sentence false.
# ---------------------------------------------------------------------------
if [[ " $want " == *" D "* ]]; then
  F="$REPO/orchestration/src/trace_join.ts"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """  const missing = halves.filter(h => h.record === undefined).map(h => h.label);
  if (missing.length > 0) {"""
new = """  const missing = halves.filter(h => h.record === undefined).map(h => h.label);
  if (false && missing.length > 0) {"""
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  run_check D test_join_fallback_two_recordings
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# E — the frames are FLATTENED: the public calls become siblings of the private
#     toplevel rather than nesting inside it. Names, counts and order are all
#     unchanged, so only a depth computed from the call/return sequence sees it.
#     Requires a probe rebuild, which is seconds on a warm tree.
# ---------------------------------------------------------------------------
if [[ " $want " == *" E "* ]]; then
  F="$REPO/verification/oq7_shared_writer_probe.rs"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = """            write_join_record(&mut sink, "shared", &spec.join_id, "both", 1);
            let public_steps = write_public_half(&mut sink, &spec.public_calls);
            noir_tracer::tracer_glue::finish_trace(&mut sink).expect("finish");"""
new = """            write_join_record(&mut sink, "shared", &spec.join_id, "both", 1);
            // MUTATION E: close every private frame BEFORE the public half, so the public frames
            // are siblings of <toplevel> rather than nested inside it.
            for _ in 0..8 { TraceWriter::register_return(sink.writer, ValueRecord::None { type_id: NONE_TYPE_ID }); }
            let public_steps = write_public_half(&mut sink, &spec.public_calls);
            noir_tracer::tracer_glue::finish_trace(&mut sink).expect("finish");"""
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  ( "$REPO/verification/build_oq7_shared_writer_probe.sh" --force >"$OUT/E.build.log" 2>&1 \
      && rm -f "$HOME/.cache/aztec-m26-join/join.json" ) || echo "   (probe rebuild failed; see $OUT/E.build.log)"
  run_check E test_private_public_frame_nesting
  restore_all; verify_restored "$F"
  "$REPO/verification/build_oq7_shared_writer_probe.sh" --force >"$OUT/E.restore.log" 2>&1
  rm -f "$HOME/.cache/aztec-m26-join/join.json"
fi

# ---------------------------------------------------------------------------
# F — the enqueue ORDER is reversed in the recording. Both frames are present,
#     both are named correctly, both have their steps; only the order moves.
# ---------------------------------------------------------------------------
if [[ " $want " == *" F "* ]]; then
  F="$REPO/tools/run_join_arms.mjs"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "    public_calls: built.enqueuedNames.map((name, callIndex) => ({"
new = "    public_calls: [...built.enqueuedNames].reverse().map((name, callIndex) => ({"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  rm -f "$HOME/.cache/aztec-m26-join/join.json"
  run_check F test_private_public_frame_nesting
  restore_all; verify_restored "$F"
  rm -f "$HOME/.cache/aztec-m26-join/join.json"
fi

# ---------------------------------------------------------------------------
# G — the Noir half's Field rendering reverted. The cross-half property fails
#     and, because the two checkouts must agree, the probe REFUSES to build.
# ---------------------------------------------------------------------------
if [[ " $want " == *" G "* ]]; then
  F="$REPO/../noir/tooling/tracer/src/tracer_glue.rs"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "                ValueRecord::String { text: field_to_hex(field_value), type_id }"
new = "                ValueRecord::Int { i: field_value.to_i128() as i64, type_id }"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  run_check G test_fr_rendering_matches_noir_tracer
  printf '   and the probe build refuses: %s\n' \
    "$("$REPO/verification/build_oq7_shared_writer_probe.sh" --force 2>&1 | tail -1)"
  restore_all; verify_restored "$F"
  "$REPO/verification/build_oq7_shared_writer_probe.sh" >"$OUT/G.restore.log" 2>&1
fi

# ---------------------------------------------------------------------------
# H — A HANG. The frame reporter loops forever. A check that hangs never
#     reddens, so this must come back as a NAMED failure within the bound.
# ---------------------------------------------------------------------------
if [[ " $want " == *" H "* ]]; then
  F="$REPO/verification/_ct_frames.py"
  backup "$F"
  python3 - "$F" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = "def main(path):"
new = "def main(path):\n    import time\n    while True:\n        time.sleep(1)"
assert old in s; open(p, "w").write(s.replace(old, new, 1))
PY
  echo "   (bound lowered to 10 s for this arm so it terminates in a reasonable time)"
  M26_FRAMES_TIMEOUT=10 run_check H test_private_public_frame_nesting
  restore_all; verify_restored "$F"
fi

# ---------------------------------------------------------------------------
# I — DIE BEFORE SUMMARY. A precondition fails part-way. Without M22's
#     abnormal-exit trap this reads as a SMALLER milestone rather than a red
#     one; with it, the summary line is printed WITH a failure counted.
# ---------------------------------------------------------------------------
# A PRECONDITION THAT DIES PART-WAY. `m26_require_arms` refuses an arm report that is not readable
# JSON, and it does so with `die` — which exits WITHOUT reaching `finish`. The first draft of this
# arm pointed `M26_WORK` at an empty directory and the check simply RE-RAN the arms into it and
# passed, which is the harness failing to exercise the thing it is named for; it is recorded here
# rather than quietly replaced. What makes the report un-re-runnable is a `join.json` that is
# NEWER than every declared input and is not JSON: the staleness test is satisfied, the parse is
# not.
if [[ " $want " == *" I "* ]]; then
  W="$OUT/dieworkdir"
  rm -rf "$W"; mkdir -p "$W"
  cp -r "$HOME/.cache/aztec-m26-join/oq7-probe" "$W/" 2>/dev/null
  printf 'this is not json\n' > "$W/join.json"
  # STAMPED INTO THE FUTURE, and that is not a shortcut. `m26_require_arms` RE-RUNS a stale report,
  # so a report merely written last would be regenerated as valid JSON and the precondition would
  # never fire — which is what the first two attempts at this arm did, silently passing 61/0. The
  # arm has to make the report un-re-runnable AND unreadable at once.
  touch -d '+1 hour' "$W/join.json"
  M26_WORK="$W" timeout 600 verification/test_join_fallback_two_recordings.sh > "$OUT/I.log" 2>&1
  printf '== I  check=test_join_fallback_two_recordings  rc=%s\n' "$?"
  printf '   summary:   %s\n' \
    "$(grep -E '^[A-Za-z_0-9 .-]+: [0-9]+ assertion' "$OUT/I.log" | tail -1)"
  printf '   trap line: %s\n' "$(grep -E 'exited \(status' "$OUT/I.log" | tail -1)"
  printf '   die line:  %s\n' "$(grep -E 'cannot run' "$OUT/I.log" | tail -1)"
  rm -rf "$W"
fi

restore_all
echo "all arms done"
