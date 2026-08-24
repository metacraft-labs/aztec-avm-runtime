// The boundary-crossing count of the chatty shape, derived from UPSTREAM'S OWN record.
//
// `AvmProvingInputs.hints` is what `AvmSimAPI::simulate_with_hinted_dbs` consumes, and it exists
// because a hinted replay has to be able to answer every DB call the original simulation made
// WHOSE ANSWER IT CANNOT DERIVE. Eighteen of its categories map one-to-one onto methods of
// `ContractDBInterface` and `LowLevelMerkleDBInterface`, and `startingTreeRoots` is the one
// `get_tree_roots`.
//
// WHAT THIS NUMBER IS, STATED EXACTLY, BECAUSE IT WAS OVERSTATED FOR TWO REVISIONS. It is the sum
// of the LENGTHS of the hint arrays. That makes it a count of the HINTED calls, which is a LOWER
// BOUND on the calls a host-implemented DB would have to answer — not the number of them. It is
// still a measurement rather than an estimate, and it is still read out of a blob
// `avm_differential reactorinputs` already emits for a simulation that already ran; it is simply a
// bound rather than a total, and the checks and BOUNDARY-SHAPE.md say bound.
//
// THE THREE PLACES IT IS KNOWN TO BE SHORT. All three were verified against the fork at the
// pinned anchor, and the first two replace claims that said the opposite:
//   * `merkle.get_tree_roots` is counted as ONE, because `startingTreeRoots` is a single object
//     rather than an array. It is in fact the most-called method on the interface:
//     `HintingRawMerkleDB::get_tree_roots` (`simulation/lib/hinting_dbs.hpp:57`) forwards to the
//     underlying DB and records NOTHING, and `PureMerkleDB::get_tree_state()`
//     (`simulation/standalone/concrete_dbs.cpp:37-41`) calls it on every invocation with no cache,
//     from a dozen call sites — bytecode retrieval, context construction, contract-instance
//     lookup, update checks. M14's own gdb instrumentation counted 104 of 164 calls into the
//     reference DB as `get_tree_roots`.
//   * `pad_tree` IS CALLED, twice per transaction. `TxExecution::simulate` calls `pad_trees()`
//     unconditionally (`simulation/gadgets/tx_execution.cpp:311`, forwarded at `:678`), and
//     `PureMerkleDB::pad_trees()` makes two `raw_merkle_db.pad_tree(...)` calls — the note-hash
//     and nullifier trees (`simulation/standalone/concrete_dbs.cpp:181-187`). What is true is that
//     no `padTreeHints` category exists: a replay can derive the padding from the tree state it
//     already has, so the call needs no hint. "The AVM never pads" was wrong, and it was M14's
//     finding about the BLOCK BUILDER read one level too far.
//   * `get_checkpoint_id` IS CALLED, once per nested call. The `Context` constructor takes it
//     (`simulation/gadgets/context.hpp:45`, into `checkpoint_id_at_creation`) and
//     `simulation/gadgets/execution.cpp:1937` reads it again to assert the stack came back. It is
//     unhinted because a replay recomputes the id from the checkpoint hints it already replays.
//   * `add_contracts` is a WRITE the AVM performs when a transaction publishes a class. It changes
//     host state rather than reading it, so a replay needs no hint for it, and this table does not
//     invent a count for it.
//
// So the honest reading of a total from this table is: at least this many crossings, undercounting
// `get_tree_roots` by however many times the simulation asked for tree state, `pad_tree` by two
// per transaction, and `get_checkpoint_id` by one per nested call. The DECISION does not turn on
// it — even sixty crossings at the measured 19 ns is about a microsecond against milliseconds of
// work — which is why the bound is enough and the exact count was never chased.
//
// THIS FILE OWNS THE MAPPING so the host and the checks cannot disagree about it, and it reports
// what it could NOT map. A hint category this table does not know about is returned in `unmapped`
// rather than silently dropped: a new hint category upstream adds is a new DB method crossing the
// boundary, which is precisely the kind of change this milestone's budget must notice.

// The op table, in the order `vm2/simulation/interfaces/db.hpp` declares the methods —
// `ContractDBInterface`'s eight first, because `AvmSimAPI::simulate` takes it first — with the
// reactor export that implements each and the hint category that counts it.
export const OPS = [
  { name: 'contract.get_contract_instance', exp: 'avm_contract_db_get_contract_instance', args: true, db: 'contract', hint: 'contractInstances' },
  { name: 'contract.get_contract_class', exp: 'avm_contract_db_get_contract_class', args: true, db: 'contract', hint: 'contractClasses' },
  { name: 'contract.get_bytecode_commitment', exp: 'avm_contract_db_get_bytecode_commitment', args: true, db: 'contract', hint: 'bytecodeCommitments' },
  { name: 'contract.get_debug_function_name', exp: 'avm_contract_db_get_debug_function_name', args: true, db: 'contract', hint: 'debugFunctionNames' },
  { name: 'contract.add_contracts', exp: 'avm_contract_db_add_contracts', args: true, db: 'contract', hint: null },
  { name: 'contract.create_checkpoint', exp: 'avm_contract_db_create_checkpoint', args: false, db: 'contract', hint: 'contractDbCreateCheckpointHints' },
  { name: 'contract.commit_checkpoint', exp: 'avm_contract_db_commit_checkpoint', args: false, db: 'contract', hint: 'contractDbCommitCheckpointHints' },
  { name: 'contract.revert_checkpoint', exp: 'avm_contract_db_revert_checkpoint', args: false, db: 'contract', hint: 'contractDbRevertCheckpointHints' },
  { name: 'merkle.get_tree_roots', exp: 'avm_merkle_db_get_tree_roots', args: false, db: 'merkle', hint: 'startingTreeRoots' },
  { name: 'merkle.get_sibling_path', exp: 'avm_merkle_db_get_sibling_path', args: true, db: 'merkle', hint: 'getSiblingPathHints' },
  { name: 'merkle.get_low_indexed_leaf', exp: 'avm_merkle_db_get_low_indexed_leaf', args: true, db: 'merkle', hint: 'getPreviousValueIndexHints' },
  { name: 'merkle.get_leaf_value', exp: 'avm_merkle_db_get_leaf_value', args: true, db: 'merkle', hint: 'getLeafValueHints' },
  { name: 'merkle.get_leaf_preimage_public_data_tree', exp: 'avm_merkle_db_get_leaf_preimage_public_data_tree', args: true, db: 'merkle', hint: 'getLeafPreimageHintsPublicDataTree' },
  { name: 'merkle.get_leaf_preimage_nullifier_tree', exp: 'avm_merkle_db_get_leaf_preimage_nullifier_tree', args: true, db: 'merkle', hint: 'getLeafPreimageHintsNullifierTree' },
  { name: 'merkle.insert_indexed_leaves_public_data_tree', exp: 'avm_merkle_db_insert_indexed_leaves_public_data_tree', args: true, db: 'merkle', hint: 'sequentialInsertHintsPublicDataTree' },
  { name: 'merkle.insert_indexed_leaves_nullifier_tree', exp: 'avm_merkle_db_insert_indexed_leaves_nullifier_tree', args: true, db: 'merkle', hint: 'sequentialInsertHintsNullifierTree' },
  { name: 'merkle.append_leaves', exp: 'avm_merkle_db_append_leaves', args: true, db: 'merkle', hint: 'appendLeavesHints' },
  { name: 'merkle.pad_tree', exp: 'avm_merkle_db_pad_tree', args: true, db: 'merkle', hint: null },
  { name: 'merkle.create_checkpoint', exp: 'avm_merkle_db_create_checkpoint', args: false, db: 'merkle', hint: 'createCheckpointHints' },
  { name: 'merkle.commit_checkpoint', exp: 'avm_merkle_db_commit_checkpoint', args: false, db: 'merkle', hint: 'commitCheckpointHints' },
  { name: 'merkle.revert_checkpoint', exp: 'avm_merkle_db_revert_checkpoint', args: false, db: 'merkle', hint: 'revertCheckpointHints' },
  { name: 'merkle.get_checkpoint_id', exp: 'avm_merkle_db_get_checkpoint_id', args: false, db: 'merkle', hint: null },
];

// The hint categories that are NOT per-call tallies: the simulation's inputs, carried in the same
// struct. Listed so they can be excluded by name rather than by "it was not an array", which would
// also exclude a category that happened to be empty.
const NOT_CALL_TALLIES = new Set(['globalVariables', 'tx', 'protocolContracts']);

/**
 * @param {object} hints the decoded `AvmProvingInputs.hints`
 * @returns {{total:number, byOp:Record<string,number>, unmapped:string[]}}
 */
export function crossingsFromHints(hints) {
  if (!hints || typeof hints !== 'object') throw new Error('crossingsFromHints: no hints object');
  const byOp = {};
  let total = 0;
  const consumed = new Set(NOT_CALL_TALLIES);
  for (const op of OPS) {
    if (!op.hint) continue;
    consumed.add(op.hint);
    const v = hints[op.hint];
    if (v === undefined) throw new Error(`the hint record has no ${op.hint} — the mapping is stale`);
    // `startingTreeRoots` is one object, not an array, so it contributes 1. That is the hint
    // record's shape, not the call count: `get_tree_roots` is unhinted and uncached and is called
    // many times per transaction (see the header). This is where the total becomes a LOWER BOUND.
    const n = Array.isArray(v) ? v.length : 1;
    byOp[op.name] = n;
    total += n;
  }
  const unmapped = Object.keys(hints).filter((k) => !consumed.has(k));
  return { total, byOp, unmapped };
}
