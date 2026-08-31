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
# THE M31 ARM REPORT IS THE HARNESS'S OWN, so a mutated transpile never overwrites the report the
# real checks read. The BUILD directory is deliberately left shared: it holds the rust builds and
# the noir checkout, which cost tens of minutes and which no arm here mutates.
export M31_WORK="$WORK/m31-arms"
# M21's work directory too, so a mutated PXE reference never overwrites the one the real check reads.
export M21_WORK="$WORK/m21-form-b"

FILES=(
  "orchestration/src/token_block_driver.ts"
  "orchestration/src/nested_effect_driver.ts"
  "verification/e2e_ts_wasm_amm.sh"
  "verification/_token_blocks_shape.py"
  "fixtures/transpiler-contracts/nested_effects/src/main.nr"
  "orchestration/src/form_b.ts"
  "pxe-ref/src/build_reference_tx.mjs"
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

mkdir -p "$WORK" "$TB_WORK" "$M31_WORK" "$M21_WORK"

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
  ( cd "$REPO" && env AVM_WASM_PATH="$MODULE" TB_WORK="$TB_WORK" M31_WORK="$M31_WORK" M21_WORK="$M21_WORK" "${@:2}" \
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
[ ${#ARMS[@]} -eq 0 ] && ARMS=(A1 A2 A3 A4 A5 A6 B1 B2 B3 B4 B5 D1 D2 D3 D4)

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

    # =======================================================================================
    # ENTRY 2 — M25 `test_nested_call_reverted_contributes_no_side_effects`
    # =======================================================================================

    B1) # THE POSITIVE CONTROL'S CALLEE REVERTS TOO. The succeeding arm then measures the same thing
        # as the subject, and "the inner side effects are absent" stops being falsifiable by
        # anything: a nested call that never happened, an SSTORE that does not work and a reader
        # that always answers zero all satisfy it again.
        #
        # RE-AIMED AFTER ITS FIRST RUN, AND THE RE-AIMING IS THE FINDING. The first form mutated
        # `CALLEE_FOR.succeeds`, which is a REPORTED field: the callee is compiled into the outer
        # mode's own `call_opcode` argument and the driver cannot change it. The arm reddened
        # exactly ONE assertion — the check's comparison of two of the driver's own fields — and
        # every behavioural assertion stayed green over an unchanged run. That is "a producer's
        # report about itself is not its output" arriving through a mutation arm, and the check now
        # derives the callee mapping from the CONTRACT'S SOURCE and compares it against the
        # declaration. This form changes the OUTER mode, which is what the calldata carries and what
        # therefore decides which callee actually runs.
        # Predicted: the control's inner-slot value, its verdict, its nullifier membership, its
        # list-length identity and its `reEmitInner` revert. The SUBJECT's own assertions stay
        # green, which is what says the pair is two measurements.
      arm_header "B1 — the positive control runs the SUBJECT's outer function"
      sub orchestration/src/nested_effect_driver.ts \
        '  succeeds: MODE.outerSucceedingCallee,' \
        '  succeeds: MODE.outerRevertingCallee,'
      still_there orchestration/src/nested_effect_driver.ts \
        '  succeeds: MODE.outerRevertingCallee,' B1
      run_check test_nested_call_reverted_contributes_no_side_effects
      ;;

    B2) # THE INSTRUCTION-COUNT CONTROL FORWARDS THE SUBJECT'S OWN ARGUMENT, so both arms halt after
        # their side effects and the two counts become equal. This is the arm for the shape the
        # first draft of the fixture actually had — a control that does not separate "no side
        # effects" from "no side effects were ever made".
        # Predicted, and NARROW: the two §5 comparisons that name the early-revert control, plus
        # §2's "they differ only in the argument". Every state assertion stays green, because the
        # two arms' state is identical either way — which is the point of the section.
      arm_header "B2 — the early-revert control forwards the subject's argument"
      sub orchestration/src/nested_effect_driver.ts \
        '  revertsBeforeEffects: CALLEE_ARG.revertBeforeEffects,' \
        '  revertsBeforeEffects: CALLEE_ARG.revertAfterEffects,'
      still_there orchestration/src/nested_effect_driver.ts \
        '  revertsBeforeEffects: CALLEE_ARG.revertAfterEffects,' B2
      run_check test_nested_call_reverted_contributes_no_side_effects
      ;;

    B3) # THE MUTATION THAT REACHES THE CONTRACT. The nested callee stops failing: its assert is
        # made TRUE, so the frame that was supposed to revert returns instead. The Noir source is
        # recompiled by the pinned nargo and re-transpiled in Chromium, so this arm exercises the
        # whole pipeline the entry rests on and not just the driver.
        # Predicted: the subject's inner slot reads the inner value rather than 0, its verdict flips,
        # its nullifier appears in the TxEffect, and `reEmitInner` starts reverting — every one of
        # the three witnesses, which is what says they are three readings of one fact rather than
        # three unrelated assertions.
      arm_header "B3 — the nested callee stops reverting, in the CONTRACT"
      sub fixtures/transpiler-contracts/nested_effects/src/main.nr \
        '                assert(mode == 99, "nested_effects: the inner frame reverts AFTER its side effects");' \
        '                assert(mode == 1, "nested_effects: the inner frame reverts AFTER its side effects");'
      still_there fixtures/transpiler-contracts/nested_effects/src/main.nr \
        'assert(mode == 1, "nested_effects: the inner frame reverts AFTER' B3
      run_check test_nested_call_reverted_contributes_no_side_effects
      ;;

    B4) # WITNESS ONE IS UNWIRED: the transaction's own `TxEffect.nullifiers` are reported EMPTY.
        # The state and the tree are untouched, so this arm is what says the three witnesses are
        # independent rather than three readings of one field.
        # Predicted: exactly §4b — the two membership assertions in the control, the subject's own
        # membership, the non-emptiness floor and the list-length identity. §4a and §4c stay green.
      arm_header "B4 — the transaction's own nullifier list is reported empty"
      sub orchestration/src/token_block_driver.ts \
        "    nullifiersByTx[l] = (p.txEffect.nullifiers ?? []).map(n => n.toString());" \
        "    nullifiersByTx[l] = [];"
      still_there orchestration/src/token_block_driver.ts 'nullifiersByTx[l] = [];' B4
      run_check test_nested_call_reverted_contributes_no_side_effects
      ;;

    B5) # THE ARM RUN HANGS. A live timer inside the nested-effect driver, with M31's own arms bound
        # cut to 40 s. rc 124 is the only shape that is a hang; rc 13 and rc 1 are die-before-summary
        # arms wearing a hang's label.
        # Predicted: `0 assertion(s), 1 failure(s)` with a summary line at column 0, naming the bound.
      arm_header "B5 — the transpiler arm run HANGS and the bound must name it"
      sub orchestration/src/nested_effect_driver.ts \
        '  const artifact = loadContractArtifact(rawArtifact as never);' \
        '  await new Promise((r) => setTimeout(r, 1e9)); const artifact = loadContractArtifact(rawArtifact as never);'
      still_there orchestration/src/nested_effect_driver.ts 'setTimeout(r, 1e9)' B5
      run_check test_nested_call_reverted_contributes_no_side_effects M31_ARMS_TIMEOUT=90
      ;;

    # =======================================================================================
    # ENTRY 4 — M21 `test_form_b_tx_matches_pxe_bytes`
    # =======================================================================================

    D1) # THIS RUNTIME'S SEAM DROPS THE PUBLIC CALLDATA. `publicOnlyPrivateExecution` — `form_b.ts`'s
        # own function, and the one that carries `publicFunctionCalldata` into the transaction —
        # ignores its third parameter. PXE's side is untouched, so the two producers now disagree
        # about a field neither of them reports.
        # Predicted, and NARROW: the two cases that CARRY calldata lose their byte-identity, their
        # byte count and their transaction hash; the `noCalldata` case stays green, because for it
        # the mutation is a no-op — which is what says the failure is about the calldata and not
        # about the seam in general. The check's own "our Tx with the calldata dropped differs from
        # PXE's" control also collapses, because with the mutation live it no longer does.
      arm_header "D1 — this runtime's seam drops the public calldata"
      sub orchestration/src/form_b.ts \
        '  return new PrivateExecutionResult(entrypoint, firstNullifier, publicFunctionCalldata);' \
        '  return new PrivateExecutionResult(entrypoint, firstNullifier, []);'
      still_there orchestration/src/form_b.ts \
        'new PrivateExecutionResult(entrypoint, firstNullifier, []);' D1
      run_check test_form_b_tx_matches_pxe_bytes
      ;;

    D2) # THE NODE STUB STOPS COUNTING. `nodeConsulted` then reads zero whether or not the node was
        # consulted, which is a counter wired to nothing under an assertion whose whole point is
        # that a zero means something.
        # Predicted: exactly the paired positive — "the same stub counts when it IS called" — and
        # nothing else. The `threw:` assertion beside it survives, which is what says the pair is
        # two facts.
      arm_header "D2 — the node stub stops counting, so its zero means nothing"
      sub pxe-ref/src/build_reference_tx.mjs \
        '    nodeConsulted += 1;' \
        '    nodeConsulted += 0;'
      still_there pxe-ref/src/build_reference_tx.mjs 'nodeConsulted += 0;' D2
      run_check test_form_b_tx_matches_pxe_bytes
      ;;

    D3) # THE REFERENCE STOPS USING PXE. The tail becomes the EMPTY tail instead of the one
        # `generateSimulatedProvingResult` produces — which is the state the whole differential
        # exists to rule out, because both halves would then agree about nothing in particular.
        # Predicted: §2 entirely — the tail is the empty tail, the two cases' tails stop differing,
        # and the transactions built from them stop differing. The byte-identity assertions
        # SURVIVE, and that is the finding the arm is for: two producers agreeing about a degenerate
        # input is not the claim, and §2 is what makes the input non-degenerate.
      arm_header "D3 — the reference stops running PXE's step 2"
      sub pxe-ref/src/build_reference_tx.mjs \
        '  const tailBuffer = proving.publicInputs.toBuffer();' \
        '  proving.publicInputs = (await import("@aztec/stdlib/kernel")).PrivateKernelTailCircuitPublicInputs.empty();
  const tailBuffer = proving.publicInputs.toBuffer();'
      still_there pxe-ref/src/build_reference_tx.mjs \
        'PrivateKernelTailCircuitPublicInputs.empty();' D3
      run_check test_form_b_tx_matches_pxe_bytes
      ;;

    D4) # THE REFERENCE PRODUCER HANGS, with its bound cut to 20 s. rc 124 is the only shape that is
        # a hang.
        # Predicted: `0 assertion(s), 1 failure(s)` with a summary line at column 0, naming the bound.
      arm_header "D4 — the reference producer HANGS and the bound must name it"
      sub pxe-ref/src/build_reference_tx.mjs \
        'const sha = b => createHash(' \
        'await new Promise((r) => setTimeout(r, 1e9)); const sha = b => createHash('
      still_there pxe-ref/src/build_reference_tx.mjs 'setTimeout(r, 1e9)' D4
      run_check test_form_b_tx_matches_pxe_bytes M21_PXE_REF_TIMEOUT=20
      ;;

    *) echo "unknown arm: $arm" >&2 ;;
  esac
  restore_all
  verify_restored && echo "restored; manifest verified" | tee -a "$LOG"
done

restore_all
verify_restored && echo "FINAL: restored; manifest verified" | tee -a "$LOG"
echo "log: $LOG"
