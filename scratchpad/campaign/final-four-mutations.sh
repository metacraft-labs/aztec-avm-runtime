#!/usr/bin/env bash
# final-four-mutations.sh — the final-four pass's mutation matrix.
#
#   scratchpad/campaign/final-four-mutations.sh [arm...]        (default: all)
#   scratchpad/campaign/final-four-mutations.sh --restore-previous [arm...]
#   scratchpad/campaign/final-four-mutations.sh --demo-still-there
#
# ===========================================================================================
# WHAT THIS HARNESS INHERITS — each item a defect this campaign has already paid for
# ===========================================================================================
#
#  * **A SUBSTITUTION THAT DOES NOT FIND ITS NEEDLE ABORTS THE RUN** (M32's arm M2).
#  * **THE MARKER IS WRITTEN BEFORE THE BACKUP** (M36: two launches in one second).
#  * **THE BACKUP'S TREE IS PINNED BY CONTENT** — sha256 manifest before the first mutation,
#    verified after the last restore — and the harness REFUSES to back up a dirty subject.
#  * **`still_there` RESTORES, VERIFIES AND EXITS 5** (M30: a mutation silently undone, printed
#    as the arm's result).
#  * **EVERY ARM READS *WHICH* ASSERTIONS WENT RED**, not merely that the check failed.
#  * **THE HANG ARM'S rc MUST BE 124.** Three wrong shapes are on record — rc 13, rc 1 and a
#    bound that never fires. The hang below is a live `setTimeout`, which keeps the loop alive.
#
# TB_WORK / M31_WORK ARE THE HARNESS'S OWN, so a mutated arm run never overwrites the arms the
# real checks read.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

WORK="${FINAL_FOUR_MUT_WORK:-$HOME/.cache/aztec-final-four-mut}"
BACKUP="$WORK/backup"
MARKER="$WORK/.in-progress"
MANIFEST="$WORK/manifest.sha256"
LOG="$WORK/mutations.log"

export TB_WORK="$WORK/tb-arms"

FILES=(
  "orchestration/src/token_block_driver.ts"
  "verification/e2e_ts_wasm_amm.sh"
  "verification/_token_blocks_shape.py"
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

mkdir -p "$WORK" "$TB_WORK"

for f in "${FILES[@]}"; do
  [ -f "$f" ] || { echo "missing subject: $f" >&2; exit 2; }
done
DIRTY="$(git status --porcelain -- "${FILES[@]}" | grep -v '^??' || true)"
if [ -n "$DIRTY" ]; then
  echo "REFUSING: a subject has uncommitted changes, so the backup would freeze them:" >&2
  echo "$DIRTY" >&2
  exit 2
fi

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
    restore_all
    verify_restored || true
    exit 5
  fi
}

MODULE="${AVM_WASM_PATH:-$HOME/.cache/aztec-m15-shapes/m13/barretenberg/cpp/build-wasm-avm/bin/avm.wasm}"

run_check() { # <check> [env=val...]
  echo "--- $1" | tee -a "$LOG"
  ( cd "$REPO" && env AVM_WASM_PATH="$MODULE" TB_WORK="$TB_WORK" "${@:2}" \
      direnv exec "$REPO" bash -c \
      "TMPDIR=\$HOME/.cache/aztec-verification-scratch verification/$1.sh" ) 2>&1 | tee -a "$LOG"
  echo "rc=${PIPESTATUS[0]}" | tee -a "$LOG"
}

arm_header() {
  echo "" | tee -a "$LOG"
  echo "=== $1" | tee -a "$LOG"
}

if [ "${1:-}" = "--demo-still-there" ]; then
  : > "$LOG"
  arm_header "DEMO — still_there over a mutation that was silently undone"
  sub verification/_token_blocks_shape.py \
    'EXPECTED_ARMS = [' \
    'EXPECTED_ARMS = [  # ZZZ_FINAL_FOUR_DEMO'
  cp "$BACKUP/verification/_token_blocks_shape.py" verification/_token_blocks_shape.py
  still_there verification/_token_blocks_shape.py 'ZZZ_FINAL_FOUR_DEMO' DEMO
  echo "UNREACHABLE: still_there returned instead of exiting 5" >&2
  exit 9
fi

ARMS=("$@")
[ ${#ARMS[@]} -eq 0 ] && ARMS=(A1 A2 A3 A4 A5 A6)

: > "$LOG"
echo "final-four mutation matrix, $(date -Is), module $MODULE" | tee -a "$LOG"

for arm in "${ARMS[@]}"; do
  touch "$MARKER"
  case "$arm" in

    # =======================================================================================
    # ENTRY 1 — M18 `e2e_ts_wasm_amm`
    # =======================================================================================

    A1) # THE FOREIGN-SENDER CONTROL IS SELF-SENT AFTER ALL, so `#[only_self]` is never exercised
        # and the control arm succeeds exactly like the subject. This is the arm the whole
        # "each internal call enqueued with `sender` set to the AMM's own address" claim rests on:
        # without it, "the calls were self-sent" is a fact about the driver's own arguments and
        # nothing measures whether the CONTRACT cares.
        # Predicted: the four "with a foreign sender X reverts" assertions, the "four DISTINCT
        # payloads" assertion, the "each carries a revert payload" assertion, the control's
        # empty-pool assertion, and the `selfSender == user` identity. The SUBJECT arm's own
        # assertions stay green.
      arm_header "A1 — the foreign-sender control is self-sent after all"
      sub orchestration/src/token_block_driver.ts \
        '    const selfSender = opts.selfSend ? ammAt : user;' \
        '    const selfSender = ammAt;'
      still_there orchestration/src/token_block_driver.ts '    const selfSender = ammAt;' A1
      run_check e2e_ts_wasm_amm
      ;;

    A2) # THE NO-MINTER CONTROL GRANTS THE MINTER ANYWAY. The same transaction, the same call, with
        # `approve` forced true — so the control stops discriminating and the pool is created in
        # both arms.
        # Predicted: `is_minter` reads 1 where the control expects 0, the control's add_liquidity
        # stops reverting, its liquidity supply stops being 0, and the "two controls fail for
        # DIFFERENT reasons" comparison loses its left-hand side. The foreign-sender control is
        # untouched, which is what says the two controls are two.
      arm_header "A2 — the no-minter control grants the minter anyway"
      sub orchestration/src/token_block_driver.ts \
        "          appCalls: [{ address: lpAt, fnName: 'set_minter', args: [ammAt, opts.setMinter] }]," \
        "          appCalls: [{ address: lpAt, fnName: 'set_minter', args: [ammAt, true] }],"
      still_there orchestration/src/token_block_driver.ts "args: [ammAt, true] }]," A2
      run_check e2e_ts_wasm_amm
      ;;

    A3) # ONE PARTIAL NOTE IS SEEDED AGAINST THE WRONG EMITTING TOKEN. `siloNullifier` binds the
        # validity commitment to the contract that emitted it, so seeding the exact-out swap's
        # OUTPUT note under token1 rather than token0 writes a leaf `token0.finalize_transfer_to_
        # private` will never find. Everything else about the arm is unchanged.
        # Predicted, and NARROW: the fourth entry point — `_swap_tokens_for_exact_tokens` — is the
        # one that reverts, together with the exact-out deltas, its invariant, and the remove
        # deltas that are measured against them. The first three entry points stay green, which is
        # what says the seeding is per-note rather than global.
      arm_header "A3 — the exact-out swap's output note is siloed under the wrong token"
      sub orchestration/src/token_block_driver.ts \
        "    const exactOutOut = await seedPartialNote('swapExactOutOut', t0, NOTE.exactOutOut);" \
        "    const exactOutOut = await seedPartialNote('swapExactOutOut', t1, NOTE.exactOutOut);"
      still_there orchestration/src/token_block_driver.ts "'swapExactOutOut', t1," A3
      run_check e2e_ts_wasm_amm
      ;;

    A4) # THE ARTIFACT SCAN STOPS REQUIRING `abi_only_self`. It then returns every `abi_public`
        # function the AMM declares — which includes `public_dispatch` and `constructor` — so
        # "the four this arm drives are all of them" compares two different sets.
        # This is the arm for the defect this pass found in its OWN first draft: the scan came back
        # EMPTY (it read the LOADED artifact, which drops `custom_attributes`), and an empty set
        # would have made the claim vacuously true.
        # Predicted: exactly the two Part-2 assertions — the scan's size and the set equality.
        # Everything else stays green.
      arm_header "A4 — the abi_only_self scan drops its own predicate"
      sub orchestration/src/token_block_driver.ts \
        "        .filter(f => (f.custom_attributes ?? []).includes('abi_public') && (f.custom_attributes ?? []).includes('abi_only_self'))" \
        "        .filter(f => (f.custom_attributes ?? []).includes('abi_public'))"
      still_there orchestration/src/token_block_driver.ts \
        ".filter(f => (f.custom_attributes ?? []).includes('abi_public'))" A4
      run_check e2e_ts_wasm_amm
      ;;

    A5) # THE ARM RUN HANGS. A live timer, so the event loop stays alive and `timeout` has
        # something to kill — the one shape that produces rc 124. rc 13 (`await new Promise(() =>
        # {})`), rc 1 (an `await` in a sync function) and a bound that never fires are the three
        # recorded WRONG shapes.
        # Predicted: `0 assertion(s), 1 failure(s)` with a summary line at column 0, naming the
        # bound and the command — not silence.
        # ONE LINE, DELIBERATELY. `grep -F` treats a needle containing a newline as two ALTERNATIVE
        # fixed strings, so a multi-line `sub` would report a hit for either half and the miss
        # guard would stop guarding — which is the "a mutation that never applied, printed as the
        # arm's result" family arriving through the harness rather than through the subject.
      arm_header "A5 — the arm run HANGS and the bound must name it"
      sub orchestration/src/token_block_driver.ts \
        '  const tokenArtifact = loadContractArtifact(raw.token as never);' \
        '  await new Promise((r) => setTimeout(r, 1e9)); const tokenArtifact = loadContractArtifact(raw.token as never);'
      still_there orchestration/src/token_block_driver.ts 'setTimeout(r, 1e9)' A5
      run_check e2e_ts_wasm_amm TB_ARMS_BOUND_S=25
      ;;

    A6) # THE ARMS FILE IS TRUNCATED — a run that did not happen, wearing a file that parses as
        # non-empty. Without the shape precondition every accessor below throws one at a time and
        # the check reads as seventy unrelated failures rather than as a re-run.
        # Predicted: `0 assertion(s), 1 failure(s)`, ONE named refusal, under the abnormal-exit
        # trap, naming the missing arms.
      arm_header "A6 — the arms file is truncated: a run that did not happen"
      mkdir -p "$TB_WORK"
      # Bring the arms current FIRST, then hollow them — M30's rule for an arm that mutates a
      # cached measurement rather than a source.
      run_check e2e_ts_wasm_amm >/dev/null 2>&1
      python3 - "$TB_WORK/token-blocks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["arms"] = {k: v for k, v in d["arms"].items() if not k.startswith("amm")}
json.dump(d, open(sys.argv[1], "w"))
PY
      touch "$TB_WORK/token-blocks.json"
      run_check e2e_ts_wasm_amm
      ;;

    *) echo "unknown arm: $arm" >&2 ;;
  esac
  restore_all
  verify_restored && echo "restored; manifest verified" | tee -a "$LOG"
done

restore_all
verify_restored && echo "FINAL: restored; manifest verified" | tee -a "$LOG"
echo "log: $LOG"
