// browser_avm_host.ts — `ReplayAvmHost` in a page.
//
// ================================================================================================
// THIS FILE IS THE PAYOFF FOR `ReplayAvmHost` BEING STRUCTURAL, AND IT IS SHORT BECAUSE OF IT.
// ================================================================================================
//
// `replay_execution.ts` declares the host as five methods and a factory, structurally, with the
// reason stated there: "L4's browser host is a DIFFERENT IMPLEMENTATION over the same wasm, not a
// subclass, and a nominal type would make the browser path a rewrite rather than an argument."
//
// This is that different implementation. It differs from `node_avm_host.ts` in ONE expression — the
// loader — because the `Reactor` class both loaders return is the same class from
// `node-host/src/reactor.ts`, so `createContractDb`, `createMerkleDb`, `callWithBlob` and
// `simulate` are identical on both sides. Everything below the loader is a copy of the Node host's
// body for exactly that reason, and the msgpack shapes are the same shapes, cited in the same place.
//
// ================================================================================================
// IT REUSES `browser/src/loader.ts` RATHER THAN RE-IMPLEMENTING IT, AND THAT IS SAFE — MEASURED.
// ================================================================================================
//
// `replay/` and `browser/` are on DIFFERENT npm pins (`npm.current` vs `deletion_era`), and
// `replay/package.json` records what importing across that boundary costs: `serializeWithMessagePack`
// recognises an `Fr` by the class object of its own install. `strict_surface.ts` is re-implemented
// rather than imported for exactly that reason.
//
// **THE HAZARD DOES NOT APPLY HERE, AND IT WAS CHECKED RATHER THAN ASSUMED.** `browser/src/loader.ts`
// imports four modules and NOT ONE OF THEM IS AN `@aztec` PACKAGE:
//
//     ../../node-host/src/gate.ts     ../../node-host/src/memory.ts
//     ../../node-host/src/reactor.ts  ./wasi.ts
//
// `node-host/package.json` declares NO DEPENDENCIES and says that is the point; `wasi.ts` is a WASI
// shim over `WebAssembly` and nothing else. So no `Fr` crosses this edge, no `@aztec` module is
// pulled onto the wrong pin, and re-implementing 570 lines of WASI shim to avoid a hazard that is
// not there would be the sixth copy of a file this repository already has too many of.
//
// **AND `browser/` IS NOT EDITED BY THIS CAMPAIGN.** M36 landed (`status: completed`) and the
// primary checkout is clean, so the read-only constraint L4 imposed on itself has lifted — but
// "importing from it" and "editing it" are different acts, and only the first is done here. The
// replay page is built in `replay/`'s own esbuild pass, so `BROWSER-PACKAGING.md`'s figures do not
// move either.

import type { Fr } from '@aztec/foundation/curves/bn254';
import { serializeWithMessagePack } from '@aztec/stdlib/avm';

import { compileAvmFromUrl, instantiateAvm } from '../../browser/src/loader.ts';
import { createAvmPoseidon2, installPoseidon2 } from '../../browser/src/poseidon.ts';
import { stepsFromOutcome, type ExecutionStep } from '../../node-host/src/steps.ts';
import type { ReplayAvmHost, ReplayAvmInstance } from '../src/replay_execution.ts';

const TREE_ROOTS_EXPORT = 'avm_merkle_db_get_tree_roots';

export type BrowserAvmHostOptions = {
  /** Where `avm.wasm` is served from, same-origin. */
  readonly moduleUrl: string;
  /** DD-4: the guest's clock, from the caller. Defaults to `Date.now`. */
  readonly nowMs?: () => number;
  /** Where the guest's `fd_write` goes. Defaults to nowhere, which is what a page wants. */
  readonly writeLine?: (fd: number, line: string) => void;
};

/**
 * A `ReplayAvmHost` that compiles `avm.wasm` once and instantiates a fresh module per round.
 *
 * The split is the Node host's and the reason is the same: the resident databases have no reset, so
 * each hydration round must run against exactly its own seed, and compilation is the expensive half.
 * Twelve rounds cost one compile and twelve instantiations.
 */
export async function createBrowserAvmHost(
  options: BrowserAvmHostOptions,
): Promise<ReplayAvmHost> {
  const compiled = await compileAvmFromUrl(options.moduleUrl);
  const nowMs = options.nowMs ?? (() => Date.now());

  // ══════════════════════════════════════════════════════════════════════════════════════════════
  // DD-11: POSEIDON IS INSTALLED AT HOST CREATION, BEFORE ANY CALLER CAN HASH.
  // ══════════════════════════════════════════════════════════════════════════════════════════════
  //
  // MEASURED, AND IT IS EARLIER THAN IT LOOKS. Installing it in `freshInstance()` seemed right —
  // that is where the reactor is — and the page died with `Poseidon2NotInstalled` inside
  // `fetchSettledTransaction`, four frames deep in `zod`: upstream's `TxSchema` computes a
  // TRANSACTION HASH while PARSING the recorded response, so the first poseidon2 of the run happens
  // before the replay has an AVM instance at all.
  //
  // So the host instantiates one reactor eagerly, purely as the hash backend, and installs it here.
  // `runtime.ts` makes the same move for the same stated reason: there is deliberately NO lazy
  // fallback to bb.js, so being late is a loud refusal rather than a four-megabyte download nobody
  // notices. The cost is one extra instantiation of a module that is already compiled.
  //
  // ONE BACKEND FOR THE HOST'S LIFETIME. `installPoseidon2` is module-level registration; rebinding
  // it per round would point it at whichever reactor was newest, and a hash issued against a
  // torn-down instance is the kind of wrong answer that looks like a value.
  const hashReactor = (await instantiateAvm(compiled, { nowMs })).reactor;
  installPoseidon2(createAvmPoseidon2(hashReactor, serializeWithMessagePack));
  return {
    async freshInstance(): Promise<ReplayAvmInstance> {
      const { reactor } = await instantiateAvm(compiled, {
        nowMs,
        ...(options.writeLine ? { writeLine: options.writeLine } : {}),
      });
      const contractDb = reactor.createContractDb();
      const merkleDb = reactor.createMerkleDb();
      let lastSteps: readonly ExecutionStep[] | null = null;
      return {
        registerContractClass(fields) {
          reactor.callWithBlob('avm_contract_db_register_class', contractDb,
            serializeWithMessagePack(fields));
        },
        registerContractInstance(address, fields) {
          reactor.callWithBlob('avm_contract_db_register_instance', contractDb,
            serializeWithMessagePack([address, fields]));
        },
        insertNullifier(nullifier: Fr) {
          reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_nullifier_tree', merkleDb,
            serializeWithMessagePack({ nullifier }));
        },
        insertPublicDataLeaf(slot: Fr, value: Fr) {
          reactor.callWithBlob('avm_merkle_db_insert_indexed_leaves_public_data_tree', merkleDb,
            serializeWithMessagePack({ slot, value }));
        },
        treeRoots() {
          return (reactor.callWithHandle(TREE_ROOTS_EXPORT, merkleDb) ?? {}) as Record<string, unknown>;
        },
        simulate(input: Uint8Array) {
          const outcome = reactor.simulate(input, contractDb, merkleDb);
          // The zero-extra-crossing path, as in the Node host — and NOT `avm_steps_count()`, which
          // was measured answering 0 in the same run in which the AVM's own statistic said 345.
          lastSteps = stepsFromOutcome(outcome as never);
          return {
            revertCode: outcome.revertCode,
            result: (outcome.result ?? {}) as Record<string, unknown>,
          };
        },
        executedSteps() {
          return lastSteps;
        },
      };
    },
  };
}
