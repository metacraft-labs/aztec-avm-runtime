// nested_effect_driver.ts — M25: a nested frame that MAKES a side effect and then REVERTS, with
// the OUTER call going on to succeed.
//
// A DRIVER AND NOT A TEST, the campaign's split since M20: it returns one plain object and every
// assertion lives in `verification/`.
//
// ---------------------------------------------------------------------------------------------
// WHY THIS FILE EXISTS.
// ---------------------------------------------------------------------------------------------
//
// `test_nested_call_reverted_contributes_no_side_effects` was `pending` behind a CORPUS gap, and
// the closeout pass proved it by enumeration rather than asserting it: of the pinned `AvmTest`
// contract's 127 functions, fifteen make a nested call and exactly TWO recover from a failed one,
// and NEITHER nested target makes a side effect. The two halves were covered separately —
// M18's `e2e_ts_wasm_nested_call_fork_merge` has a nested call that fails inside an outer call that
// succeeds, and separately a nested frame that made a side effect and reverted taking the whole
// transaction with it — and what nothing had was BOTH AT ONCE.
//
// So the contract is authored here: `fixtures/transpiler-contracts/nested_effects/`, compiled by
// the nargo M31 builds from the anchor's own `noir` submodule and transpiled to AVM bytecode by
// the transpiler module M31 runs IN CHROMIUM. That is what M30 and M31 are for.
//
// ---------------------------------------------------------------------------------------------
// IT COMPOSES; IT DOES NOT REIMPLEMENT.
// ---------------------------------------------------------------------------------------------
//
// `openWorld`, `runOneBlock` and `registerDirectly` are the closeout pass's own, imported from
// `token_block_driver.ts` rather than copied: a second copy of the block loop is how two checks
// come to disagree about what a block did. The contract class is built the way M31's own execution
// driver builds one — `makeContractClassPublic` over the transpiled `public_dispatch` bytecode —
// because a browser-transpiled artifact has no `constructor` to hash.
//
// ---------------------------------------------------------------------------------------------
// THE THREE INDEPENDENT WITNESSES, AND WHY ONE IS NOT ENOUGH.
// ---------------------------------------------------------------------------------------------
//
//   1. **The transaction's own `TxEffect.nullifiers`.** What the transaction RECORDED. The outer
//      frame's nullifier must be in it and the reverted inner frame's must not.
//   2. **Public storage, read back through the contract itself in a LATER block.** What the tree
//      HOLDS. Slot 1 (the outer's write) survives; slot 2 (the inner's) is zero.
//   3. **A follow-up transaction that re-emits each nullifier.** What the tree ANSWERS. Re-emitting
//      the inner's must SUCCEED (it is still free) and re-emitting the outer's must REVERT (it is
//      taken). Either alone is satisfied by a tree that accepts everything or refuses everything.
//
// And the SUCCEEDING arm is the positive control for all three at once: the same contract, the same
// outer function, the same nested CALL, with the callee not failing. Then slot 2 holds 5151, the
// inner nullifier IS in the effect list, and re-emitting it REVERTS. Without that arm, "the inner
// side effects are absent" is equally satisfied by a nested call that never happened, by an SSTORE
// that does not work, and by a reader that always answers zero.

import { Fr } from '@aztec/foundation/curves/bn254';
import { AztecAddress } from '@aztec/stdlib/aztec-address';
import { PublicKeys } from '@aztec/stdlib/keys';
import { loadContractArtifact } from '@aztec/stdlib/abi';
import { makeContractClassPublic, makeContractInstanceFromClassId } from '@aztec/stdlib/testing';
import { siloNullifier } from '@aztec/stdlib/hash';

import {
  type BlockRecord,
  type ReactorLike,
  openWorld,
  registerDirectly,
  runOneBlock,
} from './token_block_driver.ts';
import { PublicTxSimulationTester } from './vendor/public_tx_simulation_tester.ts';
import { SimpleContractDataSource } from './vendor/simple_contract_data_source.ts';

/** The fixture's own mode numbers. One declaration, used at every call site and in the report. */
export const MODE = {
  outerRevertingCallee: 0,
  innerReverting: 1,
  read: 2,
  emit: 3,
  outerSucceedingCallee: 4,
  innerSucceeding: 5,
} as const;

/**
 * The argument the outer mode forwards to its callee. `1` makes the reverting callee halt BEFORE
 * its two side effects; anything else makes it halt after them.
 *
 * IT IS AN ARGUMENT RATHER THAN A SEVENTH MODE, and the reason is a measurement. The first draft
 * put "revert early" in its own branch, and the outer call then executed **139** instructions
 * against the late-revert's **89** — MORE, because a later branch of an `if`/`else if` chain costs
 * more dispatch comparisons to reach, and that swamped the two opcodes the control exists to count.
 * With `arg` deciding it inside one branch, both arms take the identical dispatch path and the only
 * difference left is where the halt happens.
 */
export const CALLEE_ARG = { revertBeforeEffects: 1, revertAfterEffects: 0 } as const;

/**
 * The three arms, and each one is the same outer function with a different callee.
 *
 *   `revertsAfterEffects`   the SUBJECT: the callee writes, emits, and THEN fails
 *   `succeeds`              the positive control: the same callee without the failure
 *   `revertsBeforeEffects`  the instruction-count control: the same callee with the failure FIRST,
 *                           so "the effects were MADE and discarded" is a comparison rather than a
 *                           reading of the fixture's source
 */
export type NestedEffectVariant = 'revertsAfterEffects' | 'succeeds' | 'revertsBeforeEffects';

const OUTER_FOR: Record<NestedEffectVariant, number> = {
  revertsAfterEffects: MODE.outerRevertingCallee,
  succeeds: MODE.outerSucceedingCallee,
  revertsBeforeEffects: MODE.outerRevertingCallee,
};
const CALLEE_FOR: Record<NestedEffectVariant, number> = {
  revertsAfterEffects: MODE.innerReverting,
  succeeds: MODE.innerSucceeding,
  revertsBeforeEffects: MODE.innerReverting,
};
const OUTER_ARG_FOR: Record<NestedEffectVariant, number> = {
  revertsAfterEffects: CALLEE_ARG.revertAfterEffects,
  succeeds: CALLEE_ARG.revertAfterEffects,
  revertsBeforeEffects: CALLEE_ARG.revertBeforeEffects,
};

/** The fixture's own slots and nullifiers. Read out of the report by the check, never typed there. */
export const SLOT = { outer: 1, inner: 2, calleeVerdict: 3 } as const;
export const NULLIFIER = { outer: 700101n, inner: 700102n } as const;
/** What the fixture writes to `SLOT.calleeVerdict`: 1 if the nested call succeeded, 2 if it failed. */
export const CALLEE_VERDICT = { succeeded: 1, failed: 2 } as const;

/**
 * One arm: register the browser-transpiled contract in a fresh world and run five blocks.
 *
 * `variant` is the arm's ONE variable — it selects which outer mode is called, and the three outer
 * modes differ only in which mode they CALL. Everything else, in all three arms, is identical.
 */
export async function runNestedEffectArm(
  reactor: ReactorLike,
  rawArtifact: unknown,
  opts: { variant: NestedEffectVariant; seed?: number; bytecodeProvenance: string; artifactSha256: string },
): Promise<Record<string, unknown>> {
  const artifact = loadContractArtifact(rawArtifact as never);
  const dispatch = artifact.functions.find(f => f.name === 'public_dispatch');
  if (dispatch === undefined) {
    throw new Error(`${artifact.name} has no public_dispatch; the transpiled artifact is not the fixture`);
  }
  const seed = opts.seed ?? 2500;
  const world = openWorld(reactor);
  try {
    const sender = await AztecAddress.fromNumber(seed + 7);
    const deployer = await AztecAddress.fromNumber(seed + 8);
    const contractClass = await makeContractClassPublic(seed, Buffer.from(dispatch.bytecode));
    const contractInstance = await makeContractInstanceFromClassId(contractClass.id, seed, {
      deployer,
      initializationHash: new Fr(0),
      immutablesHash: new Fr(seed + 3),
      publicKeys: PublicKeys.default(),
    });
    const dataSource = new SimpleContractDataSource();
    await dataSource.addNewContract(artifact, contractClass, contractInstance);
    const registered = await registerDirectly(world, contractClass, contractInstance);

    // M26's merkle tripwire, unchanged in intent and carried by every caller of the vendored
    // builder since: its one removed dependency is `MerkleTreeWriteOperations`, and a proxy that
    // throws on every access executes that claim instead of asserting it.
    const merkleTouches: string[] = [];
    const tripwire = new Proxy(
      {},
      {
        get(_t, p) {
          merkleTouches.push(`get:${String(p)}`);
          throw new Error(`the vendored transaction builder read merkleTree.${String(p)}`);
        },
      },
    );
    const tester = new PublicTxSimulationTester(tripwire as never, dataSource);
    const at = contractInstance.address;

    // `public_dispatch(selector, mode, arg)` — three declared parameters, so the vendored builder
    // puts `[selector, mode, arg]` in calldata and the fixture's own `mode` binds to field 1.
    const call = (mode: number, arg: bigint | number) => ({
      address: at,
      fnName: 'public_dispatch',
      args: [new Fr(mode), new Fr(BigInt(arg)), new Fr(0)],
    });
    const one = (label: string, mode: number, arg: bigint | number): Promise<BlockRecord> =>
      runOneBlock(reactor, world, tester, label, [{ label, sender, appCalls: [call(mode, arg)] }]);

    const outerMode = OUTER_FOR[opts.variant];
    const calleeMode = CALLEE_FOR[opts.variant];
    const outerArg = OUTER_ARG_FOR[opts.variant];

    const blocks: BlockRecord[] = [];
    // 1 — THE SUBJECT. One transaction: an outer frame that writes, emits, CALLs, and recovers.
    blocks.push(await one('outer', outerMode, outerArg));
    // 2 — the state, read back through the contract itself, in a LATER block.
    blocks.push(
      await runOneBlock(reactor, world, tester, 'readBack', [
        { label: 'readOuterSlot', sender, appCalls: [call(MODE.read, SLOT.outer)] },
        { label: 'readInnerSlot', sender, appCalls: [call(MODE.read, SLOT.inner)] },
        { label: 'readCalleeVerdict', sender, appCalls: [call(MODE.read, SLOT.calleeVerdict)] },
      ]),
    );
    // 3 — the tree's own answer. Re-emitting a nullifier that LANDED must revert; re-emitting one
    // that never landed must succeed. Two transactions, two opposite answers.
    blocks.push(await one('reEmitInner', MODE.emit, NULLIFIER.inner));
    blocks.push(await one('reEmitOuter', MODE.emit, NULLIFIER.outer));
    // 4 — a FLAT call that makes no nested call at all, so "the outer executed a second context"
    // is a comparison rather than a floor.
    blocks.push(await one('flatEmit', MODE.emit, 700999n));

    return {
      variant: opts.variant,
      bytecodeProvenance: opts.bytecodeProvenance,
      artifactName: artifact.name,
      artifactSha256: opts.artifactSha256,
      dispatchBytecodeBytes: dispatch.bytecode.length,
      contractAddress: at.toString(),
      contractClassId: contractClass.id.toString(),
      registeredDirectly: registered,
      outerMode,
      calleeMode,
      outerArg,
      slots: SLOT,
      nullifiers: { outer: NULLIFIER.outer.toString(), inner: NULLIFIER.inner.toString(), flat: '700999' },
      // THE VALUES A CHECK COMPARES AGAINST, NAMED RATHER THAN COUNTED. A transaction's
      // `TxEffect.nullifiers` carries SILOED values, so "the inner frame's nullifier is not in the
      // list" is a membership test and needs the siloed form. This is upstream's own
      // `siloNullifier`, the same derivation the AVM performs when it emits one; the two values are
      // asserted DIFFERENT by the check, so a derivation that collapsed would be caught rather than
      // making both memberships agree.
      siloedNullifiers: {
        outer: (await siloNullifier(at, new Fr(NULLIFIER.outer))).toString(),
        inner: (await siloNullifier(at, new Fr(NULLIFIER.inner))).toString(),
      },
      calleeVerdictValues: CALLEE_VERDICT,
      merkleTouches: [...merkleTouches],
      merkleTripwireControl: (() => {
        try {
          void (tester as never as { merkleTree: Record<string, unknown> }).merkleTree['getTreeInfo'];
        } catch (e) {
          return `threw:${e instanceof Error ? e.message : String(e)}`;
        }
        return 'NOT-THROWN';
      })(),
      merkleTouchesAfterControl: merkleTouches.length,
      blocks,
    };
  } finally {
    world.release();
  }
}

/** Both arms, in one world each, against one module instantiation. */
export async function runNestedEffectArms(
  reactor: ReactorLike,
  rawArtifact: unknown,
  meta: { bytecodeProvenance: string; artifactSha256: string },
): Promise<Record<string, unknown>> {
  return {
    reverting: await runNestedEffectArm(reactor, rawArtifact, {
      variant: 'revertsAfterEffects', seed: 2500, ...meta,
    }),
    succeeding: await runNestedEffectArm(reactor, rawArtifact, {
      variant: 'succeeds', seed: 2700, ...meta,
    }),
    revertingEarly: await runNestedEffectArm(reactor, rawArtifact, {
      variant: 'revertsBeforeEffects', seed: 2900, ...meta,
    }),
  };
}
