// A host for M13's contract DB and checkpoint coordinator, on V8.
//
// It drives the same `avm.wasm` M12 built, with M13's overlay: the raw `ContractDBInterface` behind
// the eight exports is `simulation::MemoryContractDB` from `vm2/simulation/standalone/` instead of
// `TestContractDB` from `vm2/testing/`, and there is a `CheckpointCoordinator` binding one contract
// DB handle to one merkle DB handle.
//
// The msgpack decoder, the module-import reader and the result-buffer protocol come from
// `reactor_lib.mjs`, shared with M12's host. THIS HOST DECODES ONLY; it never encodes. Every blob
// crossing into the module is produced by `avm_differential contractdbinputs`, that is by upstream's
// own msgpack packers in C++, and arrives as hex.
//
// Modes:
//   methods    all EIGHT ContractDBInterface methods against every corpus contract, with a
//              registered and an unregistered argument for each getter so "found" is a
//              discrimination rather than an observation
//   populate   the two population paths — explicit registration and `add_contracts` observing a
//              published-event log during execution — compared answer for answer
//   debugname  names in, names out, and the same name reaching the AVM's own frame label
//   lockstep   the coordinator; an injected desynchronisation; and the wrong state a naive owner
//              produces from the same injection
//   nested     both stacks' checkpoint ids across every corpus program, before and after
//   e2e        register a class and instance DURING execution through `add_contracts`, call into
//              the contract, revert, and check that both stacks unwound together
//
// Exit status is 0 on success and non-zero on any failure. Nothing here can turn a failing run into
// a passing one: every unexpected status throws.

import { readFile } from 'node:fs/promises';
import process from 'node:process';

import { blobFrom, hexOf, instantiateReactor, parseInputs, unpack } from './reactor_lib.mjs';

const out = [];
function line(key, value) { out.push(`${key} ${value}`); }
function flush() { process.stdout.write(out.join('\n') + '\n'); }

const [wasmPath, inputsPath, mode, ...rest] = process.argv.slice(2);
if (!wasmPath || !inputsPath || !mode) {
  console.error('usage: avm_contract_db_host.mjs <avm.wasm> <inputs.txt> <mode> [args...]');
  process.exit(2);
}

const R = await instantiateReactor(wasmPath);
const kv = parseInputs(await readFile(inputsPath, 'utf8'));
const blob = (key) => blobFrom(kv, key);

function programs() {
  const n = Number(kv.get('contractDbInputs.programs.count'));
  if (!Number.isInteger(n) || n <= 0) throw new Error('the inputs file declares no programs');
  const names = [];
  for (const k of kv.keys()) {
    const m = /^contractDbInputs\.([a-z0-9]+)\.address$/.exec(k);
    if (m) names.push(m[1]);
  }
  if (names.length !== n) throw new Error(`the inputs file declares ${n} programs but carries ${names.length}`);
  return names.sort();
}
const names = programs();

// --- handles ---------------------------------------------------------------

function newContractDb() {
  const h = R.e.avm_contract_db_create();
  if (h === 0) throw new Error('avm_contract_db_create returned 0');
  return h;
}
function newMerkleDb() {
  const h = R.e.avm_merkle_db_create();
  if (h === 0) throw new Error('avm_merkle_db_create returned 0');
  return h;
}
function newCoordinator(cdb, mdb) {
  const h = R.e.avm_coordinator_create(cdb, mdb);
  if (h === 0) throw new Error(`avm_coordinator_create(${cdb}, ${mdb}) returned 0`);
  return h;
}

/** The world state and contract DB the program's transaction expects, seeded from upstream blobs. */
function seed(name, { registerContract = true } = {}) {
  const cdb = newContractDb();
  const mdb = newMerkleDb();
  if (registerContract) {
    R.callWithArgs(R.e.avm_contract_db_register_class, 'register_class', cdb, blob(`contractDbInputs.${name}.setup.class`));
    R.callWithArgs(R.e.avm_contract_db_register_instance, 'register_instance', cdb, blob(`contractDbInputs.${name}.setup.instance`));
  }
  R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_nullifier_tree, 'insert_nullifier', mdb, blob(`contractDbInputs.${name}.setup.nullifier`));
  R.callWithArgs(R.e.avm_merkle_db_insert_indexed_leaves_public_data_tree, 'insert_public_data', mdb, blob(`contractDbInputs.${name}.setup.publicdata`));
  return { cdb, mdb };
}

function destroy({ cdb, mdb, coord }) {
  if (coord !== undefined) R.e.avm_coordinator_destroy(coord);
  R.e.avm_contract_db_destroy(cdb);
  R.e.avm_merkle_db_destroy(mdb);
}

function contractCheckpointId(cdb) {
  return R.callNoArgs(R.e.avm_contract_db_get_checkpoint_id, 'contract_db_get_checkpoint_id', cdb);
}
function merkleCheckpointId(mdb) {
  return R.callNoArgs(R.e.avm_merkle_db_get_checkpoint_id, 'merkle_db_get_checkpoint_id', mdb);
}
function coordinatorIds(coord) {
  const [depth, contractId, merkleId] = R.callNoArgs(R.e.avm_coordinator_checkpoint_ids, 'coordinator_checkpoint_ids', coord);
  return { depth, contractId, merkleId };
}
function rootsDigest(mdb) {
  const t = R.callNoArgs(R.e.avm_merkle_db_get_tree_roots, 'get_tree_roots', mdb);
  return [t.noteHashTree, t.nullifierTree, t.publicDataTree, t.l1ToL2MessageTree]
    .map((s) => `${hexOf(s.root)}:${s.nextAvailableLeafIndex}`)
    .join('|');
}

/** A call that is EXPECTED to fail: returns {status, message} instead of throwing. */
function expectFailure(fn, ...args) {
  const status = fn(...args);
  return { status, message: status === 0 ? null : R.errorMessage() };
}

function simulateThrough(entry, name, key, ...handles) {
  const b = blob(`contractDbInputs.${name}.${key}`);
  const ptr = R.put(b);
  let status;
  try {
    status = entry === 'coordinator'
      ? R.e.avm_coordinator_simulate(handles[0], ptr, b.length)
      : R.e.avm_simulate(ptr, b.length, handles[0], handles[1]);
  } finally { R.free(ptr); }
  R.check(status, `${entry}_simulate(${name}, ${key})`);
  return unpack(R.result());
}

try {
  if (mode === 'methods') {
    // ALL EIGHT, against every corpus contract, through the shipped implementation. Each getter is
    // called twice: once with an argument that IS registered and once with one that is not, so a
    // store that answered everything and a store that answered nothing both fail.
    line('methods.programs.count', names.length);
    let calls = 0;
    for (const name of names) {
      const { cdb, mdb } = seed(name);
      const p = `methods.${name}`;
      const c = (fn, key) => { calls++; return R.callWithArgs(R.e[fn], fn, cdb, blob(key)); };

      // 1. get_contract_instance
      const inst = c('avm_contract_db_get_contract_instance', `contractDbInputs.${name}.args.address`);
      line(`${p}.get_contract_instance.classId`, inst === null ? 'nil' : hexOf(inst.currentContractClassId));
      const instMiss = c('avm_contract_db_get_contract_instance', `contractDbInputs.${name}.args.absentAddress`);
      line(`${p}.get_contract_instance.absent`, instMiss === null ? 'nil' : 'FOUND');
      // 2. get_contract_class
      const klass = c('avm_contract_db_get_contract_class', `contractDbInputs.${name}.args.classId`);
      line(`${p}.get_contract_class.id`, klass === null ? 'nil' : hexOf(klass.id));
      line(`${p}.get_contract_class.bytecodeBytes`, klass === null ? 'nil' : klass.packedBytecode.length);
      const klassMiss = c('avm_contract_db_get_contract_class', `contractDbInputs.${name}.args.absentClassId`);
      line(`${p}.get_contract_class.absent`, klassMiss === null ? 'nil' : 'FOUND');
      // 3. get_bytecode_commitment
      const commitment = c('avm_contract_db_get_bytecode_commitment', `contractDbInputs.${name}.args.classId`);
      line(`${p}.get_bytecode_commitment`, commitment === null ? 'nil' : hexOf(commitment));
      const commitmentMiss = c('avm_contract_db_get_bytecode_commitment', `contractDbInputs.${name}.args.absentClassId`);
      line(`${p}.get_bytecode_commitment.absent`, commitmentMiss === null ? 'nil' : 'FOUND');
      // 4. get_debug_function_name — nothing registered yet, then registered.
      const nameBefore = c('avm_contract_db_get_debug_function_name', `contractDbInputs.${name}.args.debugName`);
      line(`${p}.get_debug_function_name.beforeRegistration`, nameBefore === null ? 'nil' : nameBefore);
      c('avm_contract_db_register_debug_function_names', `contractDbInputs.${name}.setup.debugnames`);
      const nameAfter = c('avm_contract_db_get_debug_function_name', `contractDbInputs.${name}.args.debugName`);
      line(`${p}.get_debug_function_name`, nameAfter === null ? 'nil' : nameAfter);
      const nameMiss = c('avm_contract_db_get_debug_function_name', `contractDbInputs.${name}.args.absentDebugName`);
      line(`${p}.get_debug_function_name.absent`, nameMiss === null ? 'nil' : nameMiss);
      // 5. add_contracts — an empty deployment must be accepted and change nothing.
      const idBeforeEmpty = contractCheckpointId(cdb);
      c('avm_contract_db_add_contracts', 'contractDbInputs.args.emptyDeployment');
      const stillThere = c('avm_contract_db_get_contract_class', `contractDbInputs.${name}.args.classId`);
      line(`${p}.add_contracts.empty`, stillThere === null ? 'LOST' : 'ok');
      line(`${p}.add_contracts.checkpointIdUnchanged`, contractCheckpointId(cdb) === idBeforeEmpty ? 1 : 0);
      // 6/7/8. create/commit/revert, observed through the checkpoint id the store now exposes.
      const id0 = contractCheckpointId(cdb);
      R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'contract_db_create_checkpoint'); calls++;
      const id1 = contractCheckpointId(cdb);
      R.check(R.e.avm_contract_db_commit_checkpoint(cdb), 'contract_db_commit_checkpoint'); calls++;
      const id2 = contractCheckpointId(cdb);
      R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'contract_db_create_checkpoint'); calls++;
      R.check(R.e.avm_contract_db_revert_checkpoint(cdb), 'contract_db_revert_checkpoint'); calls++;
      const id3 = contractCheckpointId(cdb);
      line(`${p}.checkpointIds`, `${id0}/${id1}/${id2}/${id3}`);
      // The underflow that both existing in-memory copies do silently.
      const under = expectFailure(R.e.avm_contract_db_commit_checkpoint, cdb);
      line(`${p}.commitUnderflow.status`, under.status);
      line(`${p}.commitUnderflow.message`, under.message ?? '(none)');
      destroy({ cdb, mdb });
    }
    line('methods.calls', calls);
    line('methods.ownedAllocationsAtExit', R.owned.size);
    line('methods.done', '1');
  } else if (mode === 'populate') {
    // The two population paths, on two stores, compared answer for answer. One registers the
    // artifacts a consumer already holds; the other decodes the published-event logs the AVM sees
    // during execution. Neither is allowed to be the definition of the other.
    line('populate.programs.count', names.length);
    for (const name of names) {
      const registered = newContractDb();
      R.callWithArgs(R.e.avm_contract_db_register_class, 'register_class', registered, blob(`contractDbInputs.${name}.setup.class`));
      R.callWithArgs(R.e.avm_contract_db_register_instance, 'register_instance', registered, blob(`contractDbInputs.${name}.setup.instance`));

      const observed = newContractDb();
      R.callWithArgs(R.e.avm_contract_db_add_contracts, 'add_contracts', observed, blob(`contractDbInputs.${name}.args.selfDeployment`));

      const p = `populate.${name}`;
      const ask = (h, fn, key) => R.callWithArgs(R.e[fn], fn, h, blob(key));
      const addr = `contractDbInputs.${name}.args.address`;
      const cid = `contractDbInputs.${name}.args.classId`;

      const ri = ask(registered, 'avm_contract_db_get_contract_instance', addr);
      const oi = ask(observed, 'avm_contract_db_get_contract_instance', addr);
      line(`${p}.instance.registered`, ri === null ? 'nil' : hexOf(ri.currentContractClassId));
      line(`${p}.instance.observed`, oi === null ? 'nil' : hexOf(oi.currentContractClassId));
      line(`${p}.instance.salt.registered`, ri === null ? 'nil' : hexOf(ri.salt));
      line(`${p}.instance.salt.observed`, oi === null ? 'nil' : hexOf(oi.salt));
      line(`${p}.instance.deployer.registered`, ri === null ? 'nil' : hexOf(ri.deployer));
      line(`${p}.instance.deployer.observed`, oi === null ? 'nil' : hexOf(oi.deployer));
      line(`${p}.instance.immutablesHash.registered`, ri === null ? 'nil' : hexOf(ri.immutablesHash));
      line(`${p}.instance.immutablesHash.observed`, oi === null ? 'nil' : hexOf(oi.immutablesHash));
      // The two public keys the fuzzer's decoder never reaches.
      line(`${p}.instance.mspkMHash.registered`, ri === null ? 'nil' : hexOf(ri.publicKeys.mspkMHash));
      line(`${p}.instance.mspkMHash.observed`, oi === null ? 'nil' : hexOf(oi.publicKeys.mspkMHash));
      line(`${p}.instance.fbpkMHash.registered`, ri === null ? 'nil' : hexOf(ri.publicKeys.fbpkMHash));
      line(`${p}.instance.fbpkMHash.observed`, oi === null ? 'nil' : hexOf(oi.publicKeys.fbpkMHash));

      const rc = ask(registered, 'avm_contract_db_get_contract_class', cid);
      const oc = ask(observed, 'avm_contract_db_get_contract_class', cid);
      line(`${p}.class.bytecodeBytes.registered`, rc === null ? 'nil' : rc.packedBytecode.length);
      line(`${p}.class.bytecodeBytes.observed`, oc === null ? 'nil' : oc.packedBytecode.length);
      line(`${p}.class.bytecodeEqual`,
        rc && oc && rc.packedBytecode.length === oc.packedBytecode.length
          && rc.packedBytecode.every((b, i) => b === oc.packedBytecode[i]) ? 1 : 0);
      line(`${p}.class.artifactHash.registered`, rc === null ? 'nil' : hexOf(rc.artifactHash));
      line(`${p}.class.artifactHash.observed`, oc === null ? 'nil' : hexOf(oc.artifactHash));

      // The commitment: registered comes from the tester's own value, observed is COMPUTED from the
      // decoded bytecode by the same function the TypeScript publisher uses.
      const rb = ask(registered, 'avm_contract_db_get_bytecode_commitment', cid);
      const ob = ask(observed, 'avm_contract_db_get_bytecode_commitment', cid);
      line(`${p}.commitment.registered`, rb === null ? 'nil' : hexOf(rb));
      line(`${p}.commitment.observed`, ob === null ? 'nil' : hexOf(ob));

      R.e.avm_contract_db_destroy(registered);
      R.e.avm_contract_db_destroy(observed);
    }
    line('populate.ownedAllocationsAtExit', R.owned.size);
    line('populate.done', '1');
  } else if (mode === 'debugname') {
    // The name goes in as an upstream `DebugFunctionNameHint` and must come back out of
    // `get_debug_function_name`, survive a checkpoint revert, and — the point of the deliverable —
    // reach the AVM's OWN frame label. `TxExecution::get_debug_function_name` reads `calldata[0]`
    // as the selector and falls back to `<selector: …>` when the DB has no name, so the label the
    // simulation logs on fd 2 is the end-to-end evidence. The caller greps that stream.
    // Two arms, selected by the caller, so the frame labels on fd 2 can be counted per arm without
    // the two runs' stderr interleaving:
    //
    //   registered    the names are in the DB; every label must be the function's name
    //   unregistered  nothing is registered; every label must be `<selector: …>`, which is what
    //                 `TxExecution::get_debug_function_name` falls back to and what `TestContractDB`
    //                 would produce for every frame forever
    const arm = rest[0] ?? 'registered';
    if (arm !== 'registered' && arm !== 'unregistered') {
      console.error(`debugname: arm must be 'registered' or 'unregistered', got ${arm}`);
      process.exit(2);
    }
    line('debugname.arm', arm);
    line('debugname.programs.count', names.length);
    for (const name of names) {
      const { cdb, mdb } = seed(name);
      const p = `debugname.${name}`;
      const ask = () => R.callWithArgs(R.e.avm_contract_db_get_debug_function_name, 'get_debug_function_name', cdb, blob(`contractDbInputs.${name}.args.debugName`));
      const register = () => R.callWithArgs(R.e.avm_contract_db_register_debug_function_names, 'register_debug_function_names', cdb, blob(`contractDbInputs.${name}.setup.debugnames`));
      line(`${p}.expected`, kv.get(`contractDbInputs.${name}.functionName`));
      const before = ask();
      line(`${p}.before`, before === null ? 'nil' : before);

      if (arm === 'registered') {
        // Registered INSIDE a checkpoint that is then reverted: the name must go away with it,
        // which is what makes it part of the checkpointed state rather than beside it.
        R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'create_checkpoint');
        register();
        const inside = ask();
        line(`${p}.insideCheckpoint`, inside === null ? 'nil' : inside);
        R.check(R.e.avm_contract_db_revert_checkpoint(cdb), 'revert_checkpoint');
        const afterRevert = ask();
        line(`${p}.afterRevert`, afterRevert === null ? 'nil' : afterRevert);
        // And now for real.
        register();
        const after = ask();
        line(`${p}.after`, after === null ? 'nil' : after);
      } else {
        line(`${p}.after`, 'nil (not registered in this arm)');
      }

      // The simulation, whose frame label the caller reads off fd 2.
      const r = simulateThrough('plain', name, 'fast', cdb, mdb);
      line(`${p}.revertCode`, r.revertCode);
      destroy({ cdb, mdb });
    }
    line('debugname.ownedAllocationsAtExit', R.owned.size);
    line('debugname.done', '1');
  } else if (mode === 'lockstep') {
    const name = rest[0] ?? names[0];
    line('lockstep.program', name);

    // 1. The coordinator drives both, and the three ids agree at every step.
    {
      const { cdb, mdb } = seed(name);
      const coord = newCoordinator(cdb, mdb);
      const at = (label) => {
        const ids = coordinatorIds(coord);
        line(`lockstep.${label}.depth`, ids.depth);
        line(`lockstep.${label}.contractId`, ids.contractId);
        line(`lockstep.${label}.merkleId`, ids.merkleId);
        line(`lockstep.${label}.assert`, R.e.avm_coordinator_assert_lockstep(coord));
      };
      at('initial');
      R.check(R.e.avm_coordinator_create_checkpoint(coord), 'coordinator_create_checkpoint');
      at('afterCreate');
      R.check(R.e.avm_coordinator_create_checkpoint(coord), 'coordinator_create_checkpoint');
      at('afterNestedCreate');
      R.check(R.e.avm_coordinator_revert_checkpoint(coord), 'coordinator_revert_checkpoint');
      at('afterRevert');
      R.check(R.e.avm_coordinator_commit_checkpoint(coord), 'coordinator_commit_checkpoint');
      at('afterCommit');

      // The underflow guard. MemoryMerkleDB pops its stack unguarded, so this is what stands
      // between a host and undefined behaviour there.
      const uc = expectFailure(R.e.avm_coordinator_commit_checkpoint, coord);
      const ur = expectFailure(R.e.avm_coordinator_revert_checkpoint, coord);
      line('lockstep.underflow.commit.status', uc.status);
      line('lockstep.underflow.commit.message', uc.message ?? '(none)');
      line('lockstep.underflow.revert.status', ur.status);
      line('lockstep.underflow.revert.message', ur.message ?? '(none)');
      at('afterUnderflowAttempts');
      destroy({ cdb, mdb, coord });
    }

    // 2. INJECTED DESYNCHRONISATION, merkle side. The per-DB export moves one stack behind the
    // coordinator's back; every coordinated operation from then on must FAIL and name that side.
    {
      const { cdb, mdb } = seed(name);
      const coord = newCoordinator(cdb, mdb);
      R.check(R.e.avm_coordinator_create_checkpoint(coord), 'coordinator_create_checkpoint');
      R.check(R.e.avm_merkle_db_create_checkpoint(mdb), 'INJECT merkle_db_create_checkpoint');
      const ids = coordinatorIds(coord);
      line('lockstep.injectMerkle.depth', ids.depth);
      line('lockstep.injectMerkle.contractId', ids.contractId);
      line('lockstep.injectMerkle.merkleId', ids.merkleId);
      const a = expectFailure(R.e.avm_coordinator_assert_lockstep, coord);
      line('lockstep.injectMerkle.assert.status', a.status);
      line('lockstep.injectMerkle.assert.message', a.message ?? '(none)');
      const c = expectFailure(R.e.avm_coordinator_create_checkpoint, coord);
      line('lockstep.injectMerkle.create.status', c.status);
      const v = expectFailure(R.e.avm_coordinator_revert_checkpoint, coord);
      line('lockstep.injectMerkle.revert.status', v.status);
      const fastBlob = blob(`contractDbInputs.${name}.fast`);
      const fastPtr = R.put(fastBlob);
      let s;
      try { s = expectFailure(R.e.avm_coordinator_simulate, coord, fastPtr, fastBlob.length); }
      finally { R.free(fastPtr); }
      line('lockstep.injectMerkle.simulate.status', s.status);
      destroy({ cdb, mdb, coord });
    }

    // 3. INJECTED DESYNCHRONISATION, contract side. The message must name the OTHER side: "they
    // disagree" sends a reader to both stacks and one of the two is always innocent.
    {
      const { cdb, mdb } = seed(name);
      const coord = newCoordinator(cdb, mdb);
      R.check(R.e.avm_coordinator_create_checkpoint(coord), 'coordinator_create_checkpoint');
      R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'INJECT contract_db_create_checkpoint');
      const a = expectFailure(R.e.avm_coordinator_assert_lockstep, coord);
      line('lockstep.injectContract.assert.status', a.status);
      line('lockstep.injectContract.assert.message', a.message ?? '(none)');
      destroy({ cdb, mdb, coord });
    }

    // 4. THE WRONG STATE, produced deliberately, so "detected rather than producing a
    // plausible-looking wrong state" is a comparison of two runs and not a claim about one.
    //
    // A naive owner drives the two DBs itself. The same injection is applied — one extra merkle
    // checkpoint, with a tree write inside it — and then a transaction-shaped create / write /
    // revert is performed on both stacks by hand. The contract DB unwinds correctly; the merkle DB
    // unwinds to the INJECTED level, so the trees keep a write the contract state has no record of.
    // Every root is well-formed. Nothing throws.
    {
      const { cdb, mdb } = seed(name);
      const before = rootsDigest(mdb);
      line('lockstep.naive.rootsBeforeInjection', before);

      // The injection: one extra merkle checkpoint, with a tree write inside it.
      R.check(R.e.avm_merkle_db_create_checkpoint(mdb), 'INJECT merkle_db_create_checkpoint');
      R.callWithArgs(R.e.avm_merkle_db_append_leaves, 'append_leaves', mdb, blob('contractDbInputs.args.appendOuter'));
      const afterInjection = rootsDigest(mdb);
      line('lockstep.naive.rootsAfterInjection', afterInjection);
      line('lockstep.naive.injectionMovedRoots', afterInjection === before ? 0 : 1);

      // A transaction-shaped create / write / revert, performed on the two stacks BY HAND. This is
      // what a consumer without a coordinating owner writes, and every call in it succeeds.
      R.check(R.e.avm_contract_db_create_checkpoint(cdb), 'contract_db_create_checkpoint');
      R.check(R.e.avm_merkle_db_create_checkpoint(mdb), 'merkle_db_create_checkpoint');
      R.callWithArgs(R.e.avm_merkle_db_append_leaves, 'append_leaves', mdb, blob('contractDbInputs.args.appendInner'));
      R.callWithArgs(R.e.avm_contract_db_add_contracts, 'add_contracts', cdb, blob(`contractDbInputs.${name}.args.deployment`));
      // By ADDRESS: the two contracts share bytecode and therefore share a class id, so the class is
      // present either way and only the instance discriminates.
      const deployedPresent = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.deployedAddress`));
      line('lockstep.naive.deployedInstancePresentInsideTx', deployedPresent === null ? 0 : 1);
      R.check(R.e.avm_contract_db_revert_checkpoint(cdb), 'contract_db_revert_checkpoint');
      R.check(R.e.avm_merkle_db_revert_checkpoint(mdb), 'merkle_db_revert_checkpoint');

      // The contract DB is back where the "transaction" found it. The trees are NOT: they unwound
      // to the injected level and still carry the injected write. Every root is well-formed, no
      // call returned an error, and the two halves now describe different histories.
      const naiveInstance = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.deployedAddress`));
      const afterRevert = rootsDigest(mdb);
      line('lockstep.naive.rootsAfterRevert', afterRevert);
      line('lockstep.naive.contractUnwound', naiveInstance === null ? 1 : 0);
      line('lockstep.naive.rootsMatchPreInjection', afterRevert === before ? 1 : 0);
      line('lockstep.naive.rootsMatchInjectedLevel', afterRevert === afterInjection ? 1 : 0);
      line('lockstep.naive.contractId', contractCheckpointId(cdb));
      line('lockstep.naive.merkleId', merkleCheckpointId(mdb));

      // The same state, seen by a coordinator: it is caught, by name.
      const coord = newCoordinator(cdb, mdb);
      // A freshly created coordinator starts at depth 0 and the merkle DB is at 1, so the very
      // first thing it is asked to do fails.
      const guarded = expectFailure(R.e.avm_coordinator_assert_lockstep, coord);
      line('lockstep.naive.coordinatorDetects.status', guarded.status);
      line('lockstep.naive.coordinatorDetects.message', guarded.message ?? '(none)');
      destroy({ cdb, mdb, coord });
    }
    line('lockstep.ownedAllocationsAtExit', R.owned.size);
    line('lockstep.done', '1');
  } else if (mode === 'nested') {
    // Deeply nested calls with mixed success and revert. Every corpus program is simulated THROUGH
    // the coordinator, which asserts lockstep before and after; the ids before and after must be
    // the ones it started at. `revert` reverts its app logic and `burn` runs out of gas, so the
    // corpus carries both outcomes rather than only the happy one.
    line('nested.programs.count', names.length);
    for (const name of names) {
      const { cdb, mdb } = seed(name);
      const coord = newCoordinator(cdb, mdb);
      const p = `nested.${name}`;
      // An outer checkpoint, as a block-level owner would hold.
      R.check(R.e.avm_coordinator_create_checkpoint(coord), 'coordinator_create_checkpoint');
      const beforeIds = coordinatorIds(coord);
      const beforeRoots = rootsDigest(mdb);
      const r = simulateThrough('coordinator', name, 'fast', coord);
      const afterIds = coordinatorIds(coord);
      line(`${p}.revertCode`, r.revertCode);
      line(`${p}.callFrames`, r.callStackMetadata.length);
      line(`${p}.before`, `${beforeIds.depth}/${beforeIds.contractId}/${beforeIds.merkleId}`);
      line(`${p}.after`, `${afterIds.depth}/${afterIds.contractId}/${afterIds.merkleId}`);
      line(`${p}.assertAfterSimulate`, R.e.avm_coordinator_assert_lockstep(coord));
      // Unwind the outer checkpoint: the roots must be exactly the pre-simulation ones.
      R.check(R.e.avm_coordinator_revert_checkpoint(coord), 'coordinator_revert_checkpoint');
      line(`${p}.rootsRestored`, rootsDigest(mdb) === beforeRoots ? 1 : 0);
      const endIds = coordinatorIds(coord);
      line(`${p}.end`, `${endIds.depth}/${endIds.contractId}/${endIds.merkleId}`);
      destroy({ cdb, mdb, coord });
    }
    line('nested.ownedAllocationsAtExit', R.owned.size);
    line('nested.done', '1');
  } else if (mode === 'e2e') {
    // Registering a class and instance DURING execution, calling into the contract, then reverting.
    //
    // `.fastdeploy` differs from `.fast` in exactly one field:
    // `tx.revertible_contract_deployment_data`, which `TxExecution::insert_revertibles` hands to
    // `contract_db.add_contracts` INSIDE the checkpoint it opened at the end of setup. So on a
    // program whose app logic succeeds the contract survives the transaction, and on one that
    // reverts it must be gone — along with the tree writes, and with both stacks back where they
    // started. Nothing in this host performs the deployment or the revert: upstream's own
    // `TxExecution` does both.
    //
    // This is also the arm `TestContractDB` cannot pass in either direction: its `add_contracts` is
    // a no-op, so the contract would be absent after the succeeding program too.
    line('e2e.programs.count', names.length);
    for (const name of names) {
      const { cdb, mdb } = seed(name);
      const coord = newCoordinator(cdb, mdb);
      const p = `e2e.${name}`;
      const deployedClassId = kv.get(`contractDbInputs.${name}.deployed.classId`);
      const deployedAddress = kv.get(`contractDbInputs.${name}.deployed.address`);
      line(`${p}.deployed.classId`, deployedClassId);
      line(`${p}.deployed.address`, deployedAddress);

      R.check(R.e.avm_coordinator_create_checkpoint(coord), 'coordinator_create_checkpoint');
      const beforeIds = coordinatorIds(coord);
      const beforeRoots = rootsDigest(mdb);
      const beforeDeployed = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.deployedAddress`));
      line(`${p}.deployedInstanceBefore`, beforeDeployed === null ? 0 : 1);

      const r = simulateThrough('coordinator', name, 'fastdeploy', coord);
      line(`${p}.revertCode`, r.revertCode);
      line(`${p}.assertAfterSimulate`, R.e.avm_coordinator_assert_lockstep(coord));
      const afterIds = coordinatorIds(coord);
      line(`${p}.ids.before`, `${beforeIds.depth}/${beforeIds.contractId}/${beforeIds.merkleId}`);
      line(`${p}.ids.after`, `${afterIds.depth}/${afterIds.contractId}/${afterIds.merkleId}`);

      // Was the contract that arrived through `add_contracts` retained? Looked up by ADDRESS: the
      // deployed contract shares its bytecode, and therefore its class id, with the registered one,
      // so only the instance discriminates.
      const deployedInst = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.deployedAddress`));
      line(`${p}.deployedInstancePresent`, deployedInst === null ? 0 : 1);
      const inst = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.address`));
      line(`${p}.registeredInstancePresent`, inst === null ? 0 : 1);
      line(`${p}.rootsAfterSimulate`, rootsDigest(mdb) === beforeRoots ? 'unchanged' : 'moved');

      // Unwind the OUTER checkpoint: everything the transaction did, contract state and trees
      // together, must go.
      R.check(R.e.avm_coordinator_revert_checkpoint(coord), 'coordinator_revert_checkpoint');
      const endIds = coordinatorIds(coord);
      line(`${p}.ids.end`, `${endIds.depth}/${endIds.contractId}/${endIds.merkleId}`);
      line(`${p}.rootsRestored`, rootsDigest(mdb) === beforeRoots ? 1 : 0);
      const deployedEnd = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.deployedAddress`));
      line(`${p}.deployedInstanceAfterOuterRevert`, deployedEnd === null ? 0 : 1);
      const registeredEnd = R.callWithArgs(R.e.avm_contract_db_get_contract_instance, 'get_contract_instance', cdb, blob(`contractDbInputs.${name}.args.address`));
      line(`${p}.registeredInstanceAfterOuterRevert`, registeredEnd === null ? 0 : 1);
      destroy({ cdb, mdb, coord });
    }
    line('e2e.ownedAllocationsAtExit', R.owned.size);
    line('e2e.done', '1');
  } else {
    console.error(`avm_contract_db_host: unknown mode: ${mode}`);
    process.exit(2);
  }
} catch (e) {
  flush();
  console.error(`avm_contract_db_host: ${e && e.stack ? e.stack : e}`);
  process.exit(5);
}

flush();
