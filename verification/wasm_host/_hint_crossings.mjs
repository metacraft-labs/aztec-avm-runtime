// The boundary-crossing count of the chatty shape, derived from UPSTREAM'S OWN record.
//
// `AvmProvingInputs.hints` is what `AvmSimAPI::simulate_with_hinted_dbs` consumes, and it exists
// because a hinted replay has to be able to answer every DB call the original simulation made —
// so it is, exactly, a per-METHOD tally of those calls. Eighteen of its categories map one-to-one
// onto methods of `ContractDBInterface` and `LowLevelMerkleDBInterface`, and `startingTreeRoots`
// is the one `get_tree_roots`.
//
// That is why M15 does not have to estimate the chatty shape's crossing count: it is a COUNT, read
// out of a blob `avm_differential reactorinputs` already emits, for a simulation that already ran.
//
// THIS FILE OWNS THE MAPPING so the host and the checks cannot disagree about it, and it reports
// what it could NOT map. A hint category this table does not know about is returned in `unmapped`
// rather than silently dropped: a new hint category upstream adds is a new DB method crossing the
// boundary, which is precisely the kind of change this milestone's budget must notice.
//
// THREE METHODS ARE NOT HINTED, AND EACH ABSENCE IS A STATEMENT RATHER THAN A GAP:
//   * `pad_tree`      — no `padTreeHints` category exists, because the AVM never pads; padding is
//                       the BLOCK builder's operation and M14 established that upstream appends
//                       the L1->L2 bundle unpadded and pads exactly two trees.
//   * `add_contracts` — a write the AVM performs when a transaction publishes a class; it changes
//                       host state rather than reading it, so a replay does not need a hint for it
//                       and the hint record does not carry one. It is counted from
//                       `contractInstances` being non-empty only when the corpus exercises it, so
//                       this table does NOT invent a count for it.
//   * `get_checkpoint_id` — an accessor the AVM does not call; the checkpoint hints record the
//                       three operations that move the stack.
// A crossing count from this table is therefore a count of the READS and the STACK MOVES, which is
// what a host-implemented DB is asked for, and it is a lower bound on `add_contracts`-heavy
// transactions. Stated here so a reader does not have to infer it.

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
    // `startingTreeRoots` is one object, not an array: one `get_tree_roots` per simulation.
    const n = Array.isArray(v) ? v.length : 1;
    byOp[op.name] = n;
    total += n;
  }
  const unmapped = Object.keys(hints).filter((k) => !consumed.has(k));
  return { total, byOp, unmapped };
}
