// node_avm_host.ts — `ReplayAvmHost` over `node-host`'s reactor.
//
// IN `tools/` AND NOT `src/`, FOR L0'S REASON. `verify_client_uses_upstream_schema` asserts that
// nothing in `replay/src` declares a wire type, and this file declares the msgpack SHAPES the
// resident databases take — `{ nullifier }`, `{ slot, value }`, the class map and the instance
// tuple. Those are the C++ structs' own field names, which is exactly the kind of thing that check
// exists to keep out of the client. `settled_fixture.ts` was moved here by the same check for the
// same reason; `tsconfig` includes `tools/`, so this still type-checks.
//
// It is also the right place on the merits: `ReplayAvmHost` is STRUCTURAL, and L4's browser path
// supplies a different implementation over the same wasm. A Node host that imports `node:wasi` has
// no business inside a package DD-9 wants shippable to a browser.
//
// THE SHAPES ARE LIFTED, NOT INVENTED. `avm_merkle_db_insert_indexed_leaves_nullifier_tree` takes a
// MAP `{ nullifier }` and `avm_contract_db_register_instance` takes a TUPLE — there is no house rule
// to fall back on, which is why `orchestration/src/resident_db.ts` says so explicitly. These are
// that file's shapes, re-expressed against this package's `@aztec/stdlib` install because the two
// installs' `Fr` classes are not interchangeable (see `replay_inputs.ts`).

import type { Fr } from '@aztec/foundation/curves/bn254';
import { serializeWithMessagePack } from '@aztec/stdlib/avm';

import { compileAvm, instantiateAvm } from '../../node-host/src/loader.ts';
import type { ReplayAvmHost, ReplayAvmInstance } from '../src/replay_execution.ts';

/** The four resident tree roots, read back as the module has them. */
const TREE_ROOTS_EXPORT = 'avm_merkle_db_get_tree_roots';

/**
 * A host that compiles the module ONCE and instantiates a fresh one per round.
 *
 * The split matters: compilation is the expensive half (a megabyte and a half of wasm) and
 * instantiation is what has to be fresh, because the resident databases have no reset and the
 * hydration loop's whole meaning depends on each round running against exactly its own seed. Twelve
 * rounds therefore cost one compile and twelve instantiations rather than twelve compiles.
 */
export async function createNodeAvmHost(modulePath: string): Promise<ReplayAvmHost> {
  const compiled = await compileAvm(modulePath);
  return {
    async freshInstance(): Promise<ReplayAvmInstance> {
      const reactor = await instantiateAvm(compiled);
      const contractDb = reactor.createContractDb();
      const merkleDb = reactor.createMerkleDb();
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
          return {
            revertCode: outcome.revertCode,
            result: (outcome.result ?? {}) as Record<string, unknown>,
          };
        },
      };
    },
  };
}
