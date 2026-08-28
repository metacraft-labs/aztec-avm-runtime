#!/usr/bin/env bash
# m32-mutations.sh — the M32 mutation matrix.
#
#   scratchpad/campaign/m32-mutations.sh [ARM ...]     (default: all)
#   scratchpad/campaign/m32-mutations.sh --restore     (put everything back and stop)
#
# ===========================================================================================
# WHAT THIS IS FOR, AND THE THREE STATES IT HAS TO TELL APART
# ===========================================================================================
#
# `CAMPAIGN-BRIEF.md`: "when a mutation reddens, read WHICH assertions went red. 'the check failed'
# and 'the check saw what I broke' are different statements, and only the second is coverage." And
# M30's review added a third state that is worse than either: a mutation that goes GREEN because the
# harness silently undid it, printed as the arm's result. The remedy generalises to any arm that
# mutates a CACHED MEASUREMENT rather than a source — bring the cache's producer current BEFORE
# mutating it, and assert after the run that the mutation is STILL THERE.
#
# So: every arm names the assertions it expects to redden; M11 (which mutates the arm report rather
# than a source) rebuilds the bundle first and re-checks its own mutation afterwards; and every
# restore is verified byte-identical against a copy this script took, with a control that shows the
# verifier can report a corruption.
#
# ===========================================================================================
# THE MTIME TRAP, WHICH IS THIS REPOSITORY'S CARGO TRAP ONE LEVEL ALONG
# ===========================================================================================
#
# `m27_bundle_newer_inputs` decides whether to rebuild by comparing source mtimes against
# `browser/dist/meta.json`. A restore that PRESERVES mtimes (`cp -p`, a `git checkout` of an
# unchanged blob) leaves the restored source OLDER than the bundle built from the mutated one, no
# rebuild happens, and the next check measures the mutated artefact over restored sources. So every
# restore here is `cp` followed by `touch`, and the same reasoning applies to `$M32_ARMS`.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${M32_MUT_WORK:-$HOME/.cache/aztec-m32-mutations}"
BACKUP="$WORK/original"
mkdir -p "$BACKUP"

M32_WORK="${M32_WORK:-$HOME/.cache/aztec-m32-worker}"
ARMS="$M32_WORK/worker.json"

FILES=(
  browser/src/worker_protocol.ts
  browser/src/entry_worker.ts
  browser/src/worker_client.ts
  browser/demo/worker_main.ts
  tools/run_worker_arms.mjs
)

say() { printf '\n=== %s\n' "$*"; }

# ===========================================================================================
# THE BACKUP IS TAKEN FRESH EVERY RUN, AND THE FIRST VERSION OF THIS FUNCTION WAS A REAL DEFECT.
# ===========================================================================================
#
# It was `[ -f "$BACKUP/$f" ] || cp "$f" "$BACKUP/$f"` — take a copy only if one is not already
# there — which is right for a single run and WRONG across sessions. Measured on this harness: the
# backup was taken during an earlier invocation, two of the five files were improved afterwards, and
# the next run's very first `restore_all` REVERTED those improvements in the working tree. The check
# then reported `MISSING` for a field whose source had been silently undone, which reads as a defect
# in the subject rather than in the harness.
#
# It is `CAMPAIGN-BRIEF.md`'s "a mutated artefact outlived its restored source", INVERTED: a stale
# BACKUP outliving the source it was taken from. The remedy is the same shape — never depend on
# state you did not produce in this run:
#
#   * the backup directory is wiped and re-taken at the start of every run, and
#   * an IN-PROGRESS marker is left while mutations are live, so a run that died mid-mutation is
#     refused rather than silently overwritten by a backup of a MUTATED tree, which would be the
#     same defect with the sign flipped.
# AND THE BACKUP IS TAKEN FROM A TREE GIT AGREES WITH — M32'S REVIEW'S ADDITION, because the two
# remedies above did not cover the case that actually happened.
#
# `rm -rf $BACKUP` fixes a backup that outlived its source, and `.in-progress` fixes a run that died
# with mutations live. Neither covers a source that was left in a mutated state by an EARLIER session
# and then had a fresh backup taken OF IT — which is what happened: `entry_worker.ts` shipped
# `detached: buffer.byteLength === 0`, M2's first substitution could not find its needle, and the arm
# reported the failure it predicted over a subject it had never mutated. A backup is only as good as
# the tree it is taken from, and "never depend on state you did not produce" has to mean the tree too.
#
# So the tree is compared against HEAD before a backup is taken. It is a WARNING and not a refusal,
# because a review that is mid-fix has legitimate modifications — but it prints them, so a residue
# from a previous session cannot be silent. `--force-dirty` acknowledges it explicitly.
warn_if_dirty() {
  local dirty
  dirty="$(cd "$REPO" && git status --porcelain -- "${FILES[@]}" 2>/dev/null)"
  # `git status --porcelain` on an UNTRACKED path prints `?? path`, and on a path git has never heard
  # of prints nothing — `CAMPAIGN-BRIEF.md` lists that second case as a defect that shipped twice. So
  # the tracked-ness of every file is asserted here rather than assumed by the emptiness of the output.
  local f untracked=""
  for f in "${FILES[@]}"; do
    (cd "$REPO" && git ls-files --error-unmatch -- "$f" >/dev/null 2>&1) || untracked="$untracked $f"
  done
  if [ -n "$untracked" ]; then
    printf 'WARNING: not tracked by git, so this guard cannot see a residue in them:%s\n' "$untracked" >&2
  fi
  if [ -n "$dirty" ]; then
    printf 'WARNING: the tree differs from HEAD in files this harness mutates:\n%s\n' "$dirty" >&2
    printf '  A backup taken now records those differences as "original". That is how M32 shipped\n' >&2
    printf '  a mutated `containerBufferState`. Continuing.\n' >&2
  fi
}

snapshot() {
  local f
  warn_if_dirty
  if [ -f "$WORK/.in-progress" ]; then
    printf 'REFUSING TO START: %s says a previous run died with mutations live.\n' "$WORK/.in-progress" >&2
    printf '  The tree may be mutated. Restore from the PREVIOUS backup first:\n' >&2
    printf '    %s --restore-previous\n' "$0" >&2
    exit 2
  fi
  rm -rf "$BACKUP"
  for f in "${FILES[@]}"; do
    mkdir -p "$BACKUP/$(dirname "$f")"
    cp "$f" "$BACKUP/$f"
  done
  : > "$WORK/.in-progress"
}

restore_all() {
  local f
  for f in "${FILES[@]}"; do
    cp "$BACKUP/$f" "$f"
    # TOUCH, NOT `cp -p`. See the header: the bundle's staleness predicate is mtime-based.
    touch "$f"
  done
}

check_restore() {
  local f bad=0
  for f in "${FILES[@]}"; do
    if ! cmp -s "$BACKUP/$f" "$f"; then
      printf 'RESTORE FAILED: %s differs from its pre-mutation copy\n' "$f" >&2
      bad=1
    fi
  done
  [ "$bad" = 0 ] && printf 'restore: every file is byte-identical to its pre-mutation copy\n'
  return "$bad"
}

# THE VERIFIER'S OWN CONTROL. A restore checker that has only ever said "identical" is a restore
# checker nobody has seen work.
verify_restore_control() {
  local probe="$WORK/restore-control.txt"
  cp "$BACKUP/browser/src/worker_protocol.ts" "$probe"
  printf '// corrupted by verify_restore_control\n' >> "$probe"
  if cmp -s "$BACKUP/browser/src/worker_protocol.ts" "$probe"; then
    printf 'restore-control: FAILED — the checker cannot see a one-line corruption\n' >&2
    return 1
  fi
  printf 'restore-control: the checker reports a one-line corruption, so it can say no\n'
}

# ===========================================================================================
# A MUTATION THAT DID NOT APPLY MUST NOT BE RECORDED AS AN ARM THAT BEHAVED.
# ===========================================================================================
#
# The first version printed `MUTATION MISS …` and RETURNED — `set -uo pipefail` without `-e`, so the
# arm went on to rebuild, run the check, and print a result. Measured by M32's review on this
# harness's own log: M2's first substitution missed (its needle was not in the file, because the
# source already carried the thing the mutation was supposed to introduce), the second one applied,
# the arm printed the 1 failure it predicted, and the matrix recorded "M2: detached computed from
# the length — exactly the zero-length control". It had mutated the control and not the subject.
#
# That is `CAMPAIGN-BRIEF.md`'s "a mutation that crashes has not exercised the assertion it was
# written for" with the crash removed: the arm did not crash, it measured something else. So a miss
# is fatal now, and it names the file and the needle.
sub() { # <file> <python-repr-of-old> <python-repr-of-new>
  python3 - "$1" "$2" "$3" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if old not in s:
    sys.stderr.write("MUTATION MISS in %s: %r\n" % (path, old[:120]))
    raise SystemExit(3)
open(path, "w").write(s.replace(old, new, 1))
PY
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'REFUSING TO CONTINUE: the mutation above did not apply, so the arm below would measure\n' >&2
    printf '  an UNMUTATED (or differently mutated) tree and report it as this arm result.\n' >&2
    restore_all
    check_restore
    rm -f "$WORK/.in-progress"
    exit 3
  fi
}

run_checks() { # <check...>
  # THE EXIT STATUS IS TAKEN WITHOUT A `|| true` AFTER THE PIPELINE. `cmd | grep … || true` runs
  # `true`, which is itself a pipeline, and `${PIPESTATUS[0]}` then reports TRUE's status — so every
  # arm printed `rc=0` including the ones whose check reported nine failures. Measured on this
  # harness's own first run; it is `CAMPAIGN-BRIEF.md`'s "a pipe put the counter in a subshell" in
  # its exit-status form. The check's output goes to a file and the file is filtered afterwards.
  local c rc
  for c in "$@"; do
    printf '\n--- %s\n' "$c"
    direnv exec "$REPO" bash -c "verification/$c.sh" > "$WORK/check.log" 2>&1
    rc=$?
    grep -E '^  FAIL|assertion\(s\)|^  --   (the worker|main thread|foundation|largest|before|after|the zero)' \
      "$WORK/check.log" || true
    printf '### rc=%s\n' "$rc"
  done
}

rebuild() {
  direnv exec "$REPO" bash -c 'node browser/build.mjs' >"$WORK/build.log" 2>&1
  printf 'build rc=%s\n' "$?"
}

refresh_arms() {
  direnv exec "$REPO" bash -c "M32_ARMS_REFRESH=1 verification/smoke_worker_chain_survives_main_thread_block.sh" \
    >"$WORK/refresh.log" 2>&1
  printf 'arm refresh rc=%s\n' "$?"
}

# `--restore-previous` uses the EXISTING backup without re-taking one: the escape hatch for a run
# that died with mutations live. `--restore` re-takes first, which is only correct on a clean tree.
if [ "${1:-}" = "--restore-previous" ]; then
  restore_all; check_restore; rc=$?; rm -f "$WORK/.in-progress"; exit "$rc"
fi
snapshot
if [ "${1:-}" = "--restore" ]; then
  restore_all; check_restore; rc=$?; rm -f "$WORK/.in-progress"; exit "$rc"
fi

ARMS_WANTED=("$@")
[ ${#ARMS_WANTED[@]} -eq 0 ] && ARMS_WANTED=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11)
wants() { local a; for a in "${ARMS_WANTED[@]}"; do [ "$a" = "$1" ] && return 0; done; return 1; }

verify_restore_control

# ---------------------------------------------------------------------------------------------
# M1 — THE TRANSFER LIST IS DROPPED. The whole milestone's headline measurement.
#
# Expected: test_worker_transferable_container_not_copied red on the detachment assertions and on
# the pair, and NOT on the byte comparisons — the page still gets the right bytes, more slowly.
# ---------------------------------------------------------------------------------------------
if wants M1; then
  say "M1 — Comlink.transfer replaced by a plain return (the container is COPIED)"
  restore_all
  sub browser/src/entry_worker.ts \
    '  state.transfers += 1;
  return Comlink.transfer(payload, [buffer]);' \
    '  state.transfers += 1;
  return payload;'
  rebuild; refresh_arms
  run_checks test_worker_transferable_container_not_copied
fi

# ---------------------------------------------------------------------------------------------
# M2 — `detached` IS INFERRED FROM THE LENGTH INSTEAD OF READ FROM THE PLATFORM.
#
# ONE substitution, on the ONE reader `containerBufferState` uses for the container's buffer and for
# the zero-length control alike. Expected: exactly ONE failure — the zero-length control, which is
# the only reading an inference cannot produce. Every other `detached` reading in the sequence agrees
# with the platform, because the only zero-length buffer in it IS the transferred one.
#
# THE FIRST VERSION OF THIS ARM WAS TWO SUBSTITUTIONS AND THE FIRST OF THEM MISSED, WHICH IS WHY
# `sub` NOW REFUSES. The subject already read `buffer.byteLength === 0` — the very inference this arm
# claims to introduce — so the needle was absent, the miss was printed and ignored, and only the
# CONTROL was mutated. The arm produced the predicted 1 failure over a subject that was never
# mutated, and the matrix recorded it as coverage of a property nothing covered. Found by M32's
# review; the subject is fixed (`entry_worker.ts`'s `read`) and one reader means one substitution.
#
# THE MUTATION THIS ARM WAS FIRST WRITTEN AS DID NOT WORK, AND THAT IS RECORDED RATHER THAN
# REPLACED QUIETLY. It made the COPY path transfer as well, to collapse the control. Measured: the
# first take then detaches the buffer, the SECOND take throws `ContainerAlreadyTransferred`, the arm
# run exits 1, `m32_require_arms` dies at its precondition, and the check reports **0 assertions,
# 1 failure** — a crash, not coverage. `CAMPAIGN-BRIEF.md`: "when a mutation reddens, read WHICH
# assertions went red; 'the check failed' and 'the check saw what I broke' are different statements."
# The property that arm was meant to exercise — that a structured clone does NOT detach — is
# exercised by M1 from the other side: with `Comlink.transfer` removed, the TRANSFER reading becomes
# the COPY reading and six assertions go red.
# ---------------------------------------------------------------------------------------------
if wants M2; then
  say "M2 — detached is computed from the length rather than read from the platform"
  restore_all
  sub browser/src/entry_worker.ts \
    '    const read = (b: ArrayBuffer) => ({ byteLength: b.byteLength, detached: b.detached === true });' \
    '    const read = (b: ArrayBuffer) => ({ byteLength: b.byteLength, detached: b.byteLength === 0 });'
  rebuild; refresh_arms
  run_checks test_worker_transferable_container_not_copied
fi

# ---------------------------------------------------------------------------------------------
# M3 — THE CONTROL ARM DOES NOT ACTUALLY BLOCK. A `sleep` instead of a spin.
#
# This is the mutation the whole first check exists for: with the main thread never really blocked,
# the main-thread arm produces blocks in its busy window and the 2x2 stops discriminating.
# Expected: smoke_worker_chain_survives_main_thread_block red on "produced NOTHING while the main
# thread was blocked", on the last-block-predates-the-spin assertion, on the spin counter, and on
# the discriminator.
# ---------------------------------------------------------------------------------------------
if wants M3; then
  say "M3 — the main-thread control YIELDS instead of blocking"
  restore_all
  sub browser/demo/worker_main.ts \
    '  const busyOpen = performance.now();
  const spin = blockMainThread(busyMs);
  const busyClose = performance.now();' \
    '  const busyOpen = performance.now();
  await sleep(busyMs);
  const spin = { spun: 0, actualMs: performance.now() - busyOpen };
  const busyClose = performance.now();'
  rebuild; refresh_arms
  run_checks smoke_worker_chain_survives_main_thread_block
fi

# ---------------------------------------------------------------------------------------------
# M4 — THE WORKER'S CHAIN NEVER STARTS.
#
# Expected: red on the worker arm's warm and busy windows, i.e. on the half of the 2x2 that says
# the worker was doing anything at all. A check that only asserted the main thread's zero would be
# green here, which is why the worker's warm cell is an assertion too.
# ---------------------------------------------------------------------------------------------
if wants M4; then
  say "M4 — the worker node's start() does nothing"
  restore_all
  sub browser/src/entry_worker.ts \
    '  async start() {
    requireOpen('"'"'start'"'"').runtime.start();
  },' \
    '  async start() {
    requireOpen('"'"'start'"'"');
  },'
  rebuild; refresh_arms
  run_checks smoke_worker_chain_survives_main_thread_block
fi

# ---------------------------------------------------------------------------------------------
# M5 — `producedAtMs` BECOMES A CONSTANT.
#
# The worker's own monotonic clock is the evidence that the freeze reached the WORKER, and it is the
# thing M32 could not inherit from M27. A constant makes every gap zero.
# Expected: smoke_worker_produces_blocks_while_throttled red on the worker-clock gap and on the
# median-cadence assertion; smoke_worker_chain_survives_main_thread_block red on the worker arm's
# window counts, because a constant timestamp puts every block outside both windows.
# ---------------------------------------------------------------------------------------------
if wants M5; then
  say "M5 — the worker stamps every block with the same producedAtMs"
  restore_all
  sub browser/src/entry_worker.ts \
    '    producedAtMs: performance.now(),' \
    '    producedAtMs: 0,'
  rebuild; refresh_arms
  run_checks smoke_worker_produces_blocks_while_throttled smoke_worker_chain_survives_main_thread_block
fi

# ---------------------------------------------------------------------------------------------
# M6 — THE FREEZE IS NEVER APPLIED.
#
# The runner still CLAIMS it: the mechanism list still records the attempt. What changes is that
# nothing happens to the tab. This is the "a run in which the throttling did not take effect
# produces a perfectly even chain" case, and it is the reason the gap is asserted rather than the
# harness's intent.
# Expected: red on the worker-clock gap, on the host-clock gap, and on the deviation shrinking.
# ---------------------------------------------------------------------------------------------
if wants M6; then
  say "M6 — the harness records the freeze but never sends it"
  restore_all
  sub tools/run_worker_arms.mjs \
    "      await page.send('Page.setWebLifecycleState', { state: 'frozen' });
      applied.push({ mechanism: 'Page.setWebLifecycleState frozen', ok: true });" \
    "      applied.push({ mechanism: 'Page.setWebLifecycleState frozen', ok: true });"
  rebuild; refresh_arms
  run_checks smoke_worker_produces_blocks_while_throttled
fi

# ---------------------------------------------------------------------------------------------
# M7 — THE REPLAY DOES NOT REPLAY.
#
# `importSnapshot` returns the fresh node's state without replaying anything, which is the shape a
# stub has. Expected: test_worker_restart_from_snapshot red on the block number, the archive root
# and the state reference — and NOT on path B, whose two chains would then agree on being empty,
# which is why path B's own numbers are read rather than only compared.
# ---------------------------------------------------------------------------------------------
if wants M7; then
  say "M7 — importSnapshot returns state without replaying"
  restore_all
  sub browser/src/entry_worker.ts \
    '    await o.runtime.importSnapshot(
      snapshot as never,' \
    '    if (snapshot !== null) return nodeState();
    await o.runtime.importSnapshot(
      snapshot as never,'
  rebuild; refresh_arms
  run_checks test_worker_restart_from_snapshot
fi

# ---------------------------------------------------------------------------------------------
# M8 — PATH B STOPS BEING A CONTROL: its token transfer is removed.
#
# Both paths then replay cleanly and the "the roots DIFFER" assertions go red. This is the arm that
# says the unequal half of the pair is a measurement rather than a decoration.
# ---------------------------------------------------------------------------------------------
if wants M8; then
  say "M8 — the unreplayable path stops seeding state behind the facade"
  restore_all
  sub browser/demo/worker_main.ts \
    '  const tokenTransfer = await third.runTokenTransfer(ARTIFACT_URL);' \
    '  const tokenTransfer = await third.state();'
  rebuild; refresh_arms
  run_checks test_worker_restart_from_snapshot
fi

# ---------------------------------------------------------------------------------------------
# M9 — DD-5: AN UNDECLARED CAPABILITY.
#
# A protocol operation whose backing symbol the REFERENCE bundle does not export, with
# `WORKER_TESTING_OPS` left alone. Expected: smoke_worker_chain_survives_main_thread_block red on
# the set equality in both directions, and on the protocol/backing key comparison.
# ---------------------------------------------------------------------------------------------
if wants M9; then
  say "M9 — an operation backed by a symbol only testing.js exports, left undeclared"
  restore_all
  sub browser/src/worker_protocol.ts \
    "  runTokenTransfer: 'runTokenTransfer'," \
    "  runTokenTransfer: 'runTokenTransfer',
  blocks: 'PublicTxSimulationTester',"
  rebuild; refresh_arms
  run_checks smoke_worker_chain_survives_main_thread_block
fi

# ---------------------------------------------------------------------------------------------
# M10 — THE HANG ARM.
#
# The worker never announces readiness, so the page's client waits on a message that never comes.
# `CAMPAIGN-BRIEF.md` names the hang as the third state and the worst: it reports nothing and blocks
# the sweep behind it. Expected: the client's own readiness bound fires, the arm run exits non-zero
# with the failure NAMED, and the check prints a SUMMARY LINE rather than dying silently.
#
# The readiness bound is shortened so the arm is minutes rather than an hour; the property under
# test is that a bound exists and that exceeding it is a named failure, not its size.
# ---------------------------------------------------------------------------------------------
if wants M10; then
  say "M10 — the worker never posts its readiness message (a HANG, bounded)"
  restore_all
  sub browser/src/entry_worker.ts \
    '  (self as unknown as { postMessage: (m: unknown) => void }).postMessage(WORKER_READY);' \
    '  void WORKER_READY;'
  sub browser/src/worker_client.ts \
    "  const readyMs = options.readyTimeoutMs ?? 60_000;" \
    "  const readyMs = options.readyTimeoutMs ?? 20_000;"
  rebuild; refresh_arms
  run_checks smoke_worker_chain_survives_main_thread_block
fi

# ---------------------------------------------------------------------------------------------
# M11 — DIE BEFORE THE SUMMARY.
#
# The arm report is hollowed, so `m32_absent` names the missing fields and `die`s. Expected: a
# SUMMARY LINE all the same, from `m32_summary_on_abnormal_exit` — M22's trap, which exists because
# a check that dies quietly reads as a SMALLER milestone rather than a red one.
#
# M30'S REVIEW'S LESSON IS APPLIED HERE AND IT IS THE REASON FOR THE ORDER BELOW. This arm mutates a
# CACHED MEASUREMENT, not a source. If the bundle were stale, `m32_require_arms` would rebuild and
# re-measure BEFORE the staleness predicate ever looked at the hollow report, the mutation would be
# silently undone, and the arm would print 75 / 0 as its result. So: restore everything, bring the
# bundle and the report fully current FIRST, then hollow the report, then run — and afterwards
# assert the report is STILL hollow, failing by name if it is not.
# ---------------------------------------------------------------------------------------------
if wants M11; then
  say "M11 — the arm report is hollowed: the check must DIE and still print a summary"
  restore_all
  rebuild
  refresh_arms
  cp "$ARMS" "$WORK/worker.json.full"
  python3 - "$ARMS" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["arms"] = {}
json.dump(d, open(sys.argv[1], "w"))
PY
  # Newer than everything the staleness predicate compares against, so the check has no reason to
  # re-measure — which is the state the mutation is about.
  touch "$ARMS"
  run_checks smoke_worker_chain_survives_main_thread_block
  # THE MUTATION MUST STILL BE THERE. A green arm whose mutation was silently undone reads as
  # absent coverage of a property that is in fact covered.
  STILL="$(python3 -c '
import json, sys
print(len(json.load(open(sys.argv[1])).get("arms", {})))' "$ARMS")"
  if [ "$STILL" != "0" ]; then
    printf 'M11 DID NOT HOLD: the report was re-measured under the arm (arms=%s). The result above is\n' "$STILL" >&2
    printf '  a measurement of a DIFFERENT thing and must not be recorded as this arm'"'"'s.\n' >&2
  else
    printf 'M11 held: the report is still hollow after the run\n'
  fi
  cp "$WORK/worker.json.full" "$ARMS"
  touch "$ARMS"
fi

say "restoring"
restore_all
check_restore
rm -f "$WORK/.in-progress"
rebuild
printf '\nRe-measuring the arms so the tree is left as it was found.\n'
refresh_arms
run_checks smoke_worker_chain_survives_main_thread_block test_worker_transferable_container_not_copied \
  smoke_worker_produces_blocks_while_throttled test_worker_restart_from_snapshot
