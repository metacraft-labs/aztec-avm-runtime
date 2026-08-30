#!/usr/bin/env bash
# m36-mutations.sh — M36's mutation matrix.
#
#   scratchpad/campaign/m36-mutations.sh [arm...]        (default: all)
#
# ===========================================================================================
# WHAT THIS HARNESS INHERITS
# ===========================================================================================
#
# It is M35's harness — which is M34's, which is M33's — with M36's subjects and arms. Everything
# it already knew, each of which is a defect this campaign paid for:
#
#  * **A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN.** M32's arm M2 printed
#    `MUTATION MISS` and *returned*, and the arm reported the one failure it had predicted —
#    produced by a SECOND substitution that mutated only the CONTROL.
#  * **THE BACKUP IS WIPED AND RE-TAKEN EVERY RUN**, with an in-progress marker refusing a run
#    started over a tree an earlier session left mutated.
#  * **THE BACKUP'S TREE IS PINNED BY CONTENT** — a sha256 manifest taken before the first mutation
#    and verified after the last restore — because these files are uncommitted by design and a
#    `git status` comparison against HEAD cannot see them.
#  * **`still_there` FAILING RESTORES, VERIFIES AND EXITS 5.** An arm whose mutation was silently
#    undone must FAIL rather than print a result beside a diagnosis (M30's review's third state).
#  * **EVERY ARM READS *WHICH* ASSERTIONS WENT RED.** "The check failed" and "the check saw what I
#    broke" are different statements and only the second is coverage.
#
# **M36 ADDS TWO SUBJECTS TO THE BACKUP SET** — `note_database.ts` and `dev_tagging.ts` — and one
# document, `LOCAL-HISTORY.md`, mutated by an arm of its own so the figure comparer is SHOWN to
# report a stale figure rather than trusted to.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M36_MUT_WORK:-$HOME/.cache/aztec-m36-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"
ARMS_JSON="${M36_WORK:-$HOME/.cache/aztec-m36-notes}/note-discovery.json"

FILES=(
  "browser/src/wallet/private_oracles.ts"
  "browser/src/wallet/note_database.ts"
  "browser/src/wallet/dev_tagging.ts"
  "browser/src/wallet/local_history.ts"
  "browser/demo/wallet_main.ts"
  "LOCAL-HISTORY.md"
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

# THE MARKER IS WRITTEN BEFORE THE BACKUP, NOT PER ARM, AND THAT IS A DEFECT THIS HARNESS SHIPPED.
#
# The refusal above reads the marker at startup; the marker was first written by the ARM LOOP. Two
# runs launched within the same second therefore both passed the refusal, and the second one's
# `rm -rf "$BACKUP"` + re-take ran while the FIRST still had mutations live — so the backup was taken
# OF A MUTATED TREE. That is M32's stale-backup family with a new cause: not a session that died
# mid-mutation, but a second run of the same harness. Measured: M36's own matrix was launched twice
# by accident, the two interleaved into one log, `still_there` correctly reported `M7 DID NOT HOLD`,
# and `--restore-previous` then restored the HANG MUTATION because that is what the backup contained.
#
# Writing the marker here closes it: the second launch sees it and refuses before touching anything.
touch "$MARKER"

rm -rf "$BACKUP"
mkdir -p "$BACKUP"
: > "$MANIFEST"
for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing subject: $f" >&2; exit 2; }
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

# THE MUTATION IS ASSERTED TO BE STILL THERE, AND ITS ABSENCE ENDS THE RUN. See the header.
still_there() { # <file-or-report> <needle> <arm>
  if ! grep -qF -- "$2" "$1"; then
    echo "!! $3 DID NOT HOLD: the mutation is no longer in $1." | tee -a "$LOG" >&2
    echo "   An arm whose mutation was undone must FAIL, not print a result beside a diagnosis." >&2
    restore_all
    verify_restored || true
    exit 5
  fi
}

rebuild() {
  direnv exec "$REPO" bash -c 'node browser/build.mjs' >> "$LOG" 2>&1
}

run_check() { # <check> [env...]
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env "${@:2}" direnv exec "$REPO" bash -c "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
}

arm_header() {
  echo "" | tee -a "$LOG"
  echo "=== $1" | tee -a "$LOG"
}

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12 M13)

: > "$LOG"
echo "M36 mutation matrix, $(date -Is)" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # ---------------------------------------------------------------------------------------
    M1) # THE FABRICATED-NOTE REFUSAL IS REMOVED. `validateAndStoreNotes` stops checking that the
        # unique note hash is among the ones the transaction actually wrote, and stores whatever the
        # contract handed over. **This is the whole security property of a note database**, and the
        # permissive version is not visibly wrong afterwards: the note stores, `getNotes` returns it,
        # and every count in the report is unchanged. Only the control can see it.
        # Predicted: the discovery check's §8 fabricated-note control.
      arm_header "M1 — a note the chain never recorded is stored instead of refused"
      sub browser/src/wallet/note_database.ts \
        '      if (noteIndexInTx === -1) {' \
        '      if (false) {'
      rebuild
      still_there browser/src/wallet/note_database.ts 'if (false) {' M1
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M2) # THE TAG STOPS DISCRIMINATING. The siloed tag drops its app-siloing, so every contract's
        # tag for a (secret, index) pair is the same value. The wallet still finds ITS log — the
        # index still holds it — so a check that only asserted "found" would be green; what changes
        # is that the tag is no longer a function of the contract.
        # Predicted: the two-producer comparison in §4, because the SEALED first field is siloed by
        # the sealer and the wallet's is not.
      arm_header "M2 — the siloed tag drops its app-siloing"
      sub browser/src/wallet/dev_tagging.ts \
        '    const siloed = await SiloedTag.compute({ extendedSecret: secret, index });
    return siloed.value;' \
        '    const t = await Tag.compute({ extendedSecret: secret, index });
    return t.value;'
      rebuild
      still_there browser/src/wallet/dev_tagging.ts 'const t = await Tag.compute' M2
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M3) # THE TAGGING INDEX STOPS ADVANCING — it becomes a getter. Two sends to one recipient would
        # then share a tag, and the recipient would see one log where two were sent. The STRUCTURAL
        # half of the milestone cannot see this: the partition, the sums and the exercised set are
        # all unchanged.
        # Predicted: `test_tagging_index_advances` §1 and §2.
      arm_header "M3 — getNextTaggingIndex stops reserving and becomes a getter"
      sub browser/src/wallet/dev_tagging.ts \
        '    this.#executionCache.setLastUsedIndex(secret, next);
    this.#lastUsedIndex.set(key, next);
    return next;' \
        '    return next;'
      rebuild
      still_there browser/src/wallet/dev_tagging.ts '    return next;
  }' M3
      run_check test_tagging_index_advances M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M4) # AMBIENT ENTROPY IN THE EPHEMERAL SLOT STREAM — the exact thing `PRIVATE-EXECUTION.md` §5
        # measured and M36 exists to answer. The deterministic allocator falls back to upstream's own
        # `Fr.random()`, and the two returns that carry ephemeral arrays start producing slots that
        # do not replay. Nothing about the note database changes.
        # Predicted: `test_tagging_index_advances` §4's same-seed identity and §4b's stream identity.
      arm_header "M4 — the deterministic slot allocator reads ambient entropy"
      sub browser/src/wallet/dev_tagging.ts \
        '        DEV_EPHEMERAL_SLOT_SEPARATOR,
      );' \
        '        DEV_EPHEMERAL_SLOT_SEPARATOR,
      ).then(v => Fr.random() ?? v);'
      rebuild
      still_there browser/src/wallet/dev_tagging.ts 'Fr.random() ?? v' M4
      run_check test_tagging_index_advances M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M5) # THE BOUNDARY STOPS BEING ENFORCED. A query past the produced history returns the prefix
        # that happens to exist instead of refusing — which is an empty result where a missing
        # capability belongs, and is indistinguishable from a range that genuinely held nothing.
        # The DOCUMENT still says the sentence, and the module still declares the constant, so the
        # two halves a grep would check are both untouched.
        # Predicted: `verify_local_history_boundary_declared` §4 and §5.
      arm_header "M5 — the local-history boundary answers instead of refusing"
      sub browser/src/wallet/note_database.ts \
        '    if (upper !== undefined && upper > this.syncedToBlock) {' \
        '    if (false) {'
      rebuild
      still_there browser/src/wallet/note_database.ts 'if (false) {' M5
      run_check verify_local_history_boundary_declared M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M6) # TIER 2's RUNG RETURNS A FABRICATED INSTANCE FOR AN UNREGISTERED ADDRESS. This is the arm
        # for the measurement `LOCAL-HISTORY.md` §2 rests on: a well-formed preimage is not merely
        # useless, it turns a refusal that names its cause into `Cannot satisfy constraint`. The
        # handler's own partition, sums and exercised set are all unchanged.
        # Predicted: the discovery check's §8 unregistered-address control.
      # THE FIRST VERSION OF THIS ARM WAS WRITTEN AGAINST M36's OWN `getContractInstance`, WHICH THE
      # MERGE REPLACED. `sub` printed `MUTATION MISS` and the harness ABORTED with exit 3 rather than
      # rebuilding and printing a predicted result — which is M32's defect, and this is the guard that
      # exists for it working on a shared branch, where the subject of an arm can be replaced by
      # somebody else between one matrix run and the next.
      arm_header "M6 — getContractInstance returns a fabricated preimage instead of refusing"
      sub browser/src/wallet/private_oracles.ts \
        '      const held = instanceDirectory.get(address.toString());
      if (!held) {' \
        '      const held = instanceDirectory.get(address.toString()) ?? [...instanceDirectory.values()][0];
      if (!held) {'
      rebuild
      still_there browser/src/wallet/private_oracles.ts '?? [...instanceDirectory.values()][0]' M6
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M7) # THE HANG, BOUNDED AND NAMED. M35's own arm shape, reused because it took three tries to
        # get right there: a 404 answers in milliseconds and a promise that never settles is
        # collected by V8 in seconds, and BOTH produce `0 / 1` — the shape a hang produces — with
        # only the log saying which. A hang has to be a renderer that does not return.
        # Predicted: the run is KILLED at its bound and the die NAMES the bound and the state.
      arm_header "M7 — THE HANG: the page's renderer never returns"
      sub browser/demo/wallet_main.ts \
        '  const artifact = (await fetchJson(NOTE_GETTER_ARTIFACT_URL)) as { name?: string };' \
        '  for (;;) { /* the hang arm: a renderer that never returns */ }'
      rebuild
      still_there browser/demo/wallet_main.ts 'the hang arm: a renderer that never returns' M7
      # THE BOUND IS SHORTENED FOR THIS ARM AND NOTHING ELSE.
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1 M36_ARMS_TIMEOUT=90
      ;;

    # ---------------------------------------------------------------------------------------
    M8) # DIE BEFORE THE SUMMARY. The arm report is hollowed, so every field the check reads is
        # absent. `m36_absent` names them all in ONE assertion and dies; the abnormal-exit trap
        # prints a summary line, so the milestone reads RED rather than SMALLER.
        #
        # THE ORDERING IS THE WHOLE ARM (M30's review's third state): the bundle must be brought
        # CURRENT before the cache is hollowed, or the first check rebuilds, the fresh bundle is
        # newer than the hollow, and the harness re-measures over it.
      arm_header "M8 — DIE BEFORE THE SUMMARY: the arm report is hollowed"
      rebuild
      sleep 1
      python3 - "$ARMS_JSON" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d['arms'] = {'discovery': {}, 'lazy': {}}
json.dump(d, open(sys.argv[1], 'w'), indent=2)
PY
      touch "$ARMS_JSON"
      still_there "$ARMS_JSON" '"discovery": {}' M8
      run_check e2e_note_discovery_across_blocks
      still_there "$ARMS_JSON" '"discovery": {}' M8
      echo "M8 held: the hollow survived the run" | tee -a "$LOG"
      ;;

    # ---------------------------------------------------------------------------------------
    M9) # A FIGURE IN THE WRITE-UP IS MADE STALE. Predicted: the discovery check's §9 names the
        # figure AND the row.
      arm_header "M9 — a figure in LOCAL-HISTORY.md is made stale"
      sub LOCAL-HISTORY.md \
        '| its solved witness | **3,588** entries |' \
        '| its solved witness | **3,587** entries |'
      still_there LOCAL-HISTORY.md '**3,587** entries' M9
      run_check e2e_note_discovery_across_blocks
      ;;

    # ---------------------------------------------------------------------------------------
    M10) # THE STEALTH ARM, AND THE ONE THE ACTIVE/NULLIFIED PAIR EXISTS FOR. `getNotes` stops
         # filtering nullified notes out — so a note that has been SPENT keeps coming back as
         # ACTIVE, and a contract would spend it again. Every other figure in the report is
         # unchanged: the note is stored, the tag is found, the counts are the same, and the
         # ACTIVE_OR_NULLIFIED reading is right. Only the pair can see it.
      arm_header "M10 — a spent note keeps coming back as ACTIVE"
      sub browser/src/wallet/note_database.ts \
        '        return options.status === NoteStatus.ACTIVE_OR_NULLIFIED ? true : !nullified;' \
        '        void nullified; return true;'
      rebuild
      still_there browser/src/wallet/note_database.ts 'void nullified; return true;' M10
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M11) # A CONTRACT READS ANOTHER CONTRACT'S TAGGED LOGS. Upstream's own first line in
         # `LogService.fetchLogsByTag`, which this handler was missing until upstream's BODY was read
         # against it — while the first sweep ran, which is where M35's three aborts found four of
         # these. The permissive version is invisible downstream: the tag silos with whatever
         # contract the request names and the answer is well-formed either way.
      arm_header "M11 — a contract may read ANOTHER contract's tagged logs"
      sub browser/src/wallet/private_oracles.ts \
        '            if (!request.contractAddress.equals(contract)) {' \
        '            if (false) {'
      rebuild
      still_there browser/src/wallet/private_oracles.ts 'if (false) {' M11
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M12) # A CONTRACT DERIVES ANOTHER ACCOUNT'S TAGGING SECRET. Upstream's
         # `assertAllowedScope(sender, this.scopes)`, likewise missing, likewise found by reading
         # upstream's body. `getNotes`' own scope filter is untouched by this arm, so the note
         # discovery path is unchanged and only the control can see it.
      arm_header "M12 — a contract derives ANOTHER account's tagging secret"
      sub browser/src/wallet/private_oracles.ts \
        '  if (!allowedScopes.some(allowed => allowed.equals(scope))) {' \
        '  if (false) {'
      rebuild
      still_there browser/src/wallet/private_oracles.ts 'if (false) {' M12
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    # ---------------------------------------------------------------------------------------
    M13) # THE SAME NOTE, STORED TWICE. Upstream keys a stored note by its siloed nullifier and
         # UNIONS the scope into it; a table of rows holds two, `getNotes` returns two, and a
         # contract spends one note twice. Nothing about the first validation changes, so the
         # discovery path, the tags, the spend and every other figure are untouched.
         #
         # THE FIRST VERSION OF THIS ARM REDDENED FOR THE WRONG REASON, WHICH IS M24'S FAMILY AND IS
         # WHY THE FAILURES ARE READ RATHER THAN COUNTED. It made `existing` always `undefined`,
         # which removes the scope UNION and leaves the KEYING — so the second validation overwrote
         # the same map entry, the row count stayed 1, `getNotes` still returned 1, and the only
         # assertion that moved was the scope-set non-degeneracy. One failure, the arm "detected",
         # and the two-row failure mode it was written for never happened. Keying by
         # `(nullifier, scope)` is the mutation that actually produces two rows for one note.
      arm_header "M13 — a note validated twice becomes TWO notes"
      sub browser/src/wallet/note_database.ts \
        '      const key = siloed.toString();' \
        '      const key = siloed.toString() + scope.toString();'
      rebuild
      still_there browser/src/wallet/note_database.ts 'siloed.toString() + scope.toString()' M13
      run_check e2e_note_discovery_across_blocks M36_ARMS_REFRESH=1
      ;;

    *) echo "unknown arm: $arm" >&2 ;;
  esac

  restore_all
  verify_restored || exit 4
  rebuild
done

echo "" | tee -a "$LOG"
echo "restored; manifest verified. Log: $LOG" | tee -a "$LOG"
