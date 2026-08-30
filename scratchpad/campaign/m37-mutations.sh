#!/usr/bin/env bash
# m37-mutations.sh — M37's mutation matrix.
#
#   scratchpad/campaign/m37-mutations.sh [arm...]        (default: all)
#   scratchpad/campaign/m37-mutations.sh --restore-previous [arm...]
#   scratchpad/campaign/m37-mutations.sh --demo-still-there
#
# ===========================================================================================
# WHAT THIS HARNESS INHERITS, each item a defect this campaign paid for
# ===========================================================================================
#
#  * **A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN.** M32's arm M2 printed
#    `MUTATION MISS` and *returned*, and the arm reported the one failure it had predicted —
#    produced by a SECOND substitution that mutated only the CONTROL. `sub` restores, verifies
#    and exits 3.
#  * **THE MARKER IS WRITTEN BEFORE THE BACKUP.** M36 launched this harness twice within a
#    second; both runs passed a refusal that reads the marker at startup while the marker was
#    first written by the ARM LOOP, and the second run's wipe-and-re-take took a backup OF A
#    MUTATED TREE.
#  * **THE BACKUP'S TREE IS PINNED BY CONTENT** — a sha256 manifest taken before the first
#    mutation and verified after the last restore.
#  * **`still_there` FAILING RESTORES, VERIFIES AND EXITS 5.** An arm whose mutation was
#    silently undone must FAIL rather than print a result beside a diagnosis. `--demo-still-there`
#    exercises exactly that path, because a guard nobody has seen fire is a guard nobody has
#    seen work.
#  * **EVERY ARM READS *WHICH* ASSERTIONS WENT RED.** "The check failed" and "the check saw what
#    I broke" are different statements and only the second is coverage.
#
# M37'S SUBJECTS ARE CHECKS AND DATA RATHER THAN A RUNTIME. There is nothing to rebuild: every
# M37 check is a question about a revision, answered out of an object store. So the arms mutate
# the instruments and the declarations, and two of them mutate the HARNESS conditions this
# campaign has been bitten by — a check that HANGS and a check that DIES before its summary.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M37_MUT_WORK:-$HOME/.cache/aztec-m37-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

FILES=(
  "verification/_msgpack_schema_compare.py"
  "verification/_carry_overlap.py"
  "verification/lib_m37.sh"
  "verification/verify_noir_base_is_reconciled.sh"
  "verification/verify_aztec_ts_anchor_current.sh"
  "verification/verify_msgpack_schemas_match_field_for_field.sh"
  "verification/verify_m11_carry_set_resolved_or_retired.sh"
  "carry/overlap.json"
)

if [ -f "$MARKER" ] && [ "${1:-}" != "--restore-previous" ]; then
  echo "REFUSING: $MARKER exists, so a previous run died with mutations live." >&2
  echo "Run with --restore-previous to restore from $BACKUP first." >&2
  exit 2
fi
if [ "${1:-}" = "--restore-previous" ]; then
  shift
  for f in "${FILES[@]}"; do
    [ -f "$BACKUP/$f" ] && cp "$BACKUP/$f" "$f"
  done
  rm -f "$MARKER"
  echo "restored from $BACKUP"
fi

mkdir -p "$WORK"

# THE TREE MUST BE THE TREE THAT SHIPS BEFORE A BACKUP IS TAKEN OF IT. A backup is only as good
# as the tree it was taken from, and `git status` cannot see a file left mutated by an earlier
# session if that file is uncommitted by design — which every one of M37's subjects is, because
# M37 makes no commits in this repository. So the tracked-ness of each path is asserted rather
# than inferred from empty output, and a subject that is missing stops the run.
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing subject: $f" >&2; exit 2; }
  git ls-files --error-unmatch "$f" >/dev/null 2>&1 \
    || echo "NOTE: $f is not tracked; the sha256 manifest is the only guard for it" >&2
done

# The marker goes down FIRST — before the wipe and before the backup.
touch "$MARKER"

rm -rf "$BACKUP"
mkdir -p "$BACKUP"
: > "$MANIFEST"
for f in "${FILES[@]}"; do
  mkdir -p "$BACKUP/$(dirname "$f")"
  cp "$f" "$BACKUP/$f"
  sha256sum "$f" >> "$MANIFEST"
done

restore_all() {
  for f in "${FILES[@]}"; do
    cp "$BACKUP/$f" "$f"
  done
  rm -f "$MARKER"
}

verify_restored() {
  if ! sha256sum -c --quiet "$MANIFEST" 2>/dev/null; then
    echo "!! THE RESTORE DID NOT REPRODUCE THE PRE-RUN CONTENT. Compare against $BACKUP." >&2
    return 1
  fi
  return 0
}

sub() { # <file> <from> <to>
  local f="$1" from="$2" to="$3"
  if ! grep -qF -- "$from" "$f"; then
    echo "MUTATION MISS in $f: '$from'" | tee -a "$LOG" >&2
    restore_all
    verify_restored || true
    echo "ABORTED: a substitution that does not apply must not be printed as an arm that behaved." >&2
    exit 3
  fi
  python3 - "$f" "$from" "$to" <<'PY'
import sys
p, a, b = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(p, encoding="utf-8").read()
assert a in s
open(p, "w", encoding="utf-8").write(s.replace(a, b, 1))
PY
}

still_there() { # <file> <needle> <arm>
  if ! grep -qF -- "$2" "$1"; then
    echo "!! $3 DID NOT HOLD: the mutation is no longer in $1." | tee -a "$LOG" >&2
    echo "   An arm whose mutation was undone must FAIL, not print a result beside a diagnosis." >&2
    restore_all
    verify_restored || true
    exit 5
  fi
}

run_check() { # <check> [env...]
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env "${@:2}" direnv exec "$REPO" bash -c \
      "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}

arm_header() {
  echo "" | tee -a "$LOG"
  echo "=== $1" | tee -a "$LOG"
}

# --demo-still-there: the guard, exercised. The mutation is applied and then UNDONE behind the
# harness's back — exactly the state M30's review found, where a green arm read as absent
# coverage of a property that was in fact covered. `still_there` must restore, verify and exit 5.
if [ "${1:-}" = "--demo-still-there" ]; then
  : > "$LOG"
  arm_header "DEMO — still_there over a mutation that was silently undone"
  sub verification/_msgpack_schema_compare.py \
    '            to_upper = True' \
    '            to_upper = True  # ZZZ_M37_DEMO'
  cp "$BACKUP/verification/_msgpack_schema_compare.py" verification/_msgpack_schema_compare.py
  still_there verification/_msgpack_schema_compare.py 'ZZZ_M37_DEMO' DEMO
  echo "UNREACHABLE: still_there returned instead of exiting 5" >&2
  exit 9
fi

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9)

: > "$LOG"
echo "M37 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # THE camelCase TRANSFORM BECOMES AN IDENTITY. Every `MSGPACK_CAMEL_CASE_FIELDS` type is
        # then compared through a function that changes nothing, so the C++ side arrives in
        # snake_case and the schema side in camelCase. This is the mutation the whole comparison
        # rests on: if it passed, the eleven agreements would be an artefact of normalisation.
        # Predicted: the self-test, the not-an-identity assertion, and BOTH pinned sets.
      arm_header "M1 — the camelCase transform is an identity, so the two spellings cannot be told apart"
      sub verification/_msgpack_schema_compare.py \
        '        if to_upper and "a" <= c <= "z":' \
        '        if False and "a" <= c <= "z":'
      still_there verification/_msgpack_schema_compare.py 'if False and "a" <= c <= "z":' M1
      run_check verify_msgpack_schemas_match_field_for_field
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # THE SET DIFFERENCE STOPS DIFFERING. `only_in_schema` is computed as an empty list, so
        # every pair whose C++ side is a superset — and every pair at all, since `only_in_cpp`
        # still fires — hmm: this is the half that decides `DIFFER`, and with it empty the
        # verdict depends on `only_in_cpp` alone. The NEGATIVE CONTROL is what must catch it: a
        # fabricated field planted on the SCHEMA side lands in exactly the list this removes.
        # Predicted: the injected control, and the pinned sets.
      arm_header "M2 — the schema-side residue is always empty, so a planted field is invisible"
      sub verification/_msgpack_schema_compare.py \
        '        only_schema = sorted(set(s_wire) - set(c["wire"]))' \
        '        only_schema = []'
      still_there verification/_msgpack_schema_compare.py 'only_schema = []' M2
      run_check verify_msgpack_schemas_match_field_for_field
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # THE UNWAIVABLE CONJUNCT BECOMES WAIVABLE. A declaration is allowed to excuse a BUILD
        # INPUT under the tree M6 and M10 compile. This is the one thing the M11 narrowing must
        # never permit — it is the difference between narrowing conjunct 1 and retiring it.
        # Predicted: `verify_m11_carry_set_resolved_or_retired`'s arm (a), by name; and
        # `verify_carry_set_applies_to_upstream_head`'s own `build-input-changed` mutation.
      arm_header "M3 — a declaration is allowed to excuse a build input"
      sub verification/_carry_overlap.py \
        '        if path in declared_inputs or path not in declared_non:' \
        '        if False:'
      still_there verification/_carry_overlap.py '        if False:' M3
      run_check verify_m11_carry_set_resolved_or_retired
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # A DECLARATION IS DELETED. One of the five build-root non-inputs loses its entry, so a
        # path upstream changed under the build root is no longer declared at all.
        # Predicted: the M11 outcome check's per-path re-derivation and its count.
      arm_header "M4 — a build-root non-input loses its declaration"
      sub carry/overlap.json \
        '    "barretenberg/cpp/docs/Fuzzing.md": {' \
        '    "barretenberg/cpp/docs/Fuzzing.md.DELETED": {'
      still_there carry/overlap.json 'Fuzzing.md.DELETED' M4
      run_check verify_m11_carry_set_resolved_or_retired
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # A DECLARED BLOB MOVES. The entry stops matching what upstream actually has, which is
        # the mechanism that makes a declaration EXPIRE rather than stand for ever. The
        # re-derivation must catch it, and it must catch it against the FORK rather than against
        # the file it is reading.
        # Predicted: one `post-image blob` assertion, and the "upstream really did change it"
        # partner staying green, because the fork's two ends still differ.
      arm_header "M5 — a declared post-image blob no longer matches upstream"
      sub carry/overlap.json \
        '      "upstream_after": "e111827bc0f5725966e9d75e5df78f262f8cdc63",' \
        '      "upstream_after": "0000000000000000000000000000000000000000",'
      still_there carry/overlap.json '"upstream_after": "0000000000000000000000000000000000000000",' M5
      run_check verify_m11_carry_set_resolved_or_retired
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # THE NOIR CHECK'S CONTROL IS NEUTERED. `PRE` is set to the reconciled base, so the
        # "pre-reconciliation base reports the OLD version" reading becomes a reading of the NEW
        # one and the two ends stop differing. Without that control the check measures a constant
        # — it would pass on a branch that had always said beta.26.
        # Predicted: the beta.18 assertion and the two-ends-differ assertion; and the
        # ancestor-of-PRE assertions, because the merge base moves with it.
      arm_header "M6 — the Noir check's control reads the same revision at both ends"
      sub verification/verify_noir_base_is_reconciled.sh \
        'PRE="4d238163059802877a24250fe6af36f3d1ee3985"' \
        'PRE="f403193bbc5b28aca0cf99f4fc603a1672e2724a"'
      still_there verification/verify_noir_base_is_reconciled.sh \
        'PRE="f403193bbc5b28aca0cf99f4fc603a1672e2724a"' M6
      run_check verify_noir_base_is_reconciled
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # **THE HANG.** The comparer spins instead of returning. `m37_bounded` must kill it at the
        # bound and `die` NAMING the command and the bound; the abnormal-exit trap must then print
        # a summary line at column 0 with a failure counted, so the milestone reads RED and not
        # SMALLER. A trap fires on exit and a process that never exits has no exit — this is the
        # state M23's review found, where a run sat at zero bytes of output and would have blocked
        # the sweep behind it.
        # Predicted: `N assertion(s), N+1 failure(s)` with the bound named, and the run bounded to
        # a few seconds rather than for ever.
      arm_header "M7 — THE HANG: the comparer never returns"
      sub verification/_msgpack_schema_compare.py \
        '    out = compare(inp)' \
        '    import time
    while True:
        time.sleep(1)
    out = compare(inp)'
      sub verification/lib_m37.sh 'M37_BOUND="${M37_BOUND:-300}"' 'M37_BOUND="${M37_BOUND:-8}"'
      still_there verification/_msgpack_schema_compare.py 'while True:' M7
      still_there verification/lib_m37.sh 'M37_BOUND:-8' M7
      run_check verify_msgpack_schemas_match_field_for_field
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # **DIE BEFORE THE SUMMARY.** The comparer is not where the check looks, so the precondition
        # `die`s. Without the trap that is a check contributing ZERO to the sweep with nothing red —
        # the shape that cost this campaign 283 assertions once. With it, the milestone is RED.
        # Predicted: `0 assertion(s), 1 failure(s)` at column 0, and the abnormal-exit line.
      arm_header "M8 — DIE BEFORE THE SUMMARY: the comparer is not where the check looks"
      sub verification/verify_msgpack_schemas_match_field_for_field.sh \
        'CMP="$VERIFY_DIR/_msgpack_schema_compare.py"' \
        'CMP="$VERIFY_DIR/_msgpack_schema_compare_ZZZ_ABSENT.py"'
      still_there verification/verify_msgpack_schemas_match_field_for_field.sh '_ZZZ_ABSENT' M8
      run_check verify_msgpack_schemas_match_field_for_field
      ;;

    # ---------------------------------------------------------------------------------------
    M9) # THE ts→cpp RESIDUE CONTROL IS NEUTERED. The anchor check's byte-identity comparison is
        # given `cpp` on both sides of the control, so the control compares a revision with itself
        # and reports an EMPTY residue. The identity in §4 would then be a comparator that has
        # never been seen to report a difference — which is the whole reason the control exists.
        # Predicted: the "DOES report differences" assertion, and the absent-at-cpp count, since
        # the loop's `b_ts` reading moves with it.
      arm_header "M9 — the anchor check's difference control compares cpp with itself"
      sub verification/verify_aztec_ts_anchor_current.sh \
        '  b_ts="$(blob "$TS" "$p")"; b_cpp="$(blob "$CPP" "$p")"; b_ceil="$(blob "$CEIL" "$p")"' \
        '  b_ts="$(blob "$CPP" "$p")"; b_cpp="$(blob "$CPP" "$p")"; b_ceil="$(blob "$CEIL" "$p")"'
      still_there verification/verify_aztec_ts_anchor_current.sh \
        'b_ts="$(blob "$CPP" "$p")"' M9
      run_check verify_aztec_ts_anchor_current
      ;;

    *) echo "unknown arm: $arm" >&2 ;;
  esac

  restore_all
  if verify_restored; then
    echo "restored; manifest verified" | tee -a "$LOG"
  else
    echo "!! restore FAILED after $arm" | tee -a "$LOG" >&2
    exit 4
  fi
done

rm -f "$MARKER"
echo "" | tee -a "$LOG"
echo "matrix complete; log at $LOG" | tee -a "$LOG"
