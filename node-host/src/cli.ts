// The node host's command line. One mode per thing M17's checks measure.
//
// Every mode ends by printing a `<mode>.done 1` sentinel and NOTHING is printed after it, so a
// transcript that is missing it was truncated rather than short. That is not decoration: M9's
// review found a V8 run that exited 0 and left a transcript stopping mid-stream, and the four
// assertions that then failed read like findings about the AVM ("oob emitted no events") when they
// were an I/O truncation. A caller can tell the two apart in one line now.
//
// And the process does not exit until its output has drained. `process.exit()` discards output
// that is still queued — the documented Node hazard, and the exact shape of a run that exits 0
// with a short transcript.
//
// Usage:
//   node cli.ts <avm.wasm> <inputs.txt> transcript
//   node cli.ts <avm.wasm> <inputs.txt> gate
//   node cli.ts <avm.wasm> <inputs.txt> traprevert
//   node cli.ts <avm.wasm> <inputs.txt> pool <rounds>
//   node cli.ts <avm.wasm> <inputs.txt> steps <program> <batch>
//   node cli.ts <avm.wasm> <inputs.txt> imports

import { readFile } from 'node:fs/promises';
import process from 'node:process';

import { AvmHostError, AvmInstancePoisoned, AvmTrap } from './errors.ts';
import {
  AvmToolchainRegression,
  LEGACY_EH_PROBE,
  TRY_TABLE_PROBE,
  compileAvm,
  engineAcceptsLegacyEh,
  engineAcceptsTryTable,
  instantiateAvm,
  sectionIds,
} from './loader.ts';
import { InstancePool, ModuleCache } from './pool.ts';
import { hexOf } from './msgpack.ts';
import { drainSteps, expectedCrossings, formatStep, stepCount, stepsFromOutcome } from './steps.ts';
import { Transcript, blobFrom, dumpResult, parseInputs, programNames, runProgram, seedProgram } from './transcript.ts';

const SECTION_TAG = 13;

/** Exits only once stdout and stderr have drained. */
async function exitAfterFlush(code: number): Promise<never> {
  await new Promise<void>((resolve) => process.stdout.write('', () => resolve()));
  await new Promise<void>((resolve) => process.stderr.write('', () => resolve()));
  return process.exit(code);
}

function classify(e: unknown): string {
  if (e instanceof AvmTrap) return 'trap';
  if (e instanceof AvmInstancePoisoned) return 'poisoned';
  if (e instanceof AvmHostError) return 'host-error';
  if (e instanceof AvmToolchainRegression) return 'toolchain-regression';
  return 'other';
}

const [wasmPath, inputsPath, mode, ...rest] = process.argv.slice(2);
if (!wasmPath || !inputsPath || !mode) {
  process.stderr.write('usage: cli.ts <avm.wasm> <inputs.txt> <mode> [args...]\n');
  await exitAfterFlush(2);
}

const t = new Transcript();

try {
  const cache = new ModuleCache();
  const compiled = await cache.get(wasmPath);
  const kv = parseInputs(await readFile(inputsPath, 'utf8'));
  const names = programNames(kv);

  if (mode === 'gate') {
    // The toolchain gate, reported rather than only enforced, so the check can assert on WHICH
    // engine this is and therefore on which statement it is entitled to make.
    t.line('gate.engine.acceptsTryTable', engineAcceptsTryTable() ? 1 : 0);
    t.line('gate.engine.acceptsLegacyEh', engineAcceptsLegacyEh() ? 1 : 0);
    t.line('gate.probe.tryTableBytes', TRY_TABLE_PROBE.length);
    t.line('gate.probe.legacyBytes', LEGACY_EH_PROBE.length);
    t.line('gate.module.hasTagSection', sectionIds(compiled.bytes).includes(SECTION_TAG) ? 1 : 0);
    t.line('gate.module.sectionIds', sectionIds(compiled.bytes).join(','));
    t.line('gate.module.compiled', 1);
    t.line('gate.memory.importedAs', `${compiled.memoryImport.module}.${compiled.memoryImport.name}`);
    t.line('gate.memory.minPages', compiled.memoryImport.min);
    t.line('gate.memory.maxPages', compiled.memoryImport.max ?? -1);
    t.line('gate.memory.shared', compiled.memoryImport.shared ? 1 : 0);
    // A memory BELOW the declared minimum must be refused by the loader rather than by a LinkError.
    let belowMinimum = 'accepted';
    try {
      await instantiateAvm(compiled, { initialPages: compiled.memoryImport.min - 1 });
    } catch (e) {
      belowMinimum = classify(e);
    }
    t.line('gate.memory.belowMinimumRefusedAs', belowMinimum);
    t.line('gate.done', 1);
  } else if (mode === 'imports') {
    // The twelve, as the loader sees them and as the engine links them.
    t.line('imports.count', compiled.declaredImports.length);
    compiled.declaredImports.forEach((n, i) => t.line(`imports.${i}`, n));
    t.line('imports.wasiCount', compiled.declaredImports.filter((n) => n.startsWith('wasi_snapshot_preview1.')).length);
    t.line('imports.nonWasiCount', compiled.declaredImports.filter((n) => !n.startsWith('wasi_snapshot_preview1.')).length);
    // Every one of them is satisfied — instantiation is the proof, not the import list.
    const reactor = await instantiateAvm(compiled);
    t.line('imports.instantiated', 1);
    t.line('imports.abiVersion', reactor.abiVersion());
    t.line('imports.pagesAtStart', reactor.pages);
    t.line('imports.done', 1);
  } else if (mode === 'transcript') {
    const pool = new InstancePool(cache);
    t.line('nodeHost.version', 1);
    t.line('nodeHost.coverage', 'seven-hand-assembled-corpus-programs-through-the-typescript-bindings');
    t.line('nodeHost.programs.count', names.length);
    await pool.withInstance(wasmPath, (reactor) => {
      t.line('nodeHost.abiVersion', reactor.abiVersion());
      const pagesAfter: number[] = [];
      for (const name of names) {
        t.line(`program.${name}.address`, kv.get(`reactorInputs.${name}.address`) ?? '(absent)');
        dumpResult(t, `program.${name}`, runProgram(reactor, kv, name));
        // wasm linear memory never shrinks, so the reading after each program makes "the heaviest
        // corpus program" a measurement rather than a guess, and the last one IS the peak.
        pagesAfter.push(reactor.pages);
      }
      names.forEach((name, i) => t.line(`nodeHost.pagesAfter.${name}`, pagesAfter[i]));
      t.line('nodeHost.pagesAtStart', compiled.memoryImport.min);
      t.line('nodeHost.peakPages', Math.max(...pagesAfter));
      t.line('nodeHost.peakKiB', Math.max(...pagesAfter) * 64);
      t.line('nodeHost.pageSpreadAcrossPrograms', Math.max(...pagesAfter) - Math.min(...pagesAfter));
      t.line('nodeHost.ownedAllocationsAtExit', reactor.ownedAllocations);
      t.line('nodeHost.leakedAtTrap', reactor.leakedAtTrap);
    });
    t.line('nodeHost.moduleCompilations', cache.missCount);
    t.line('nodeHost.done', 1);
  } else if (mode === 'traprevert') {
    // ================================================================================
    // A wasm trap and an AVM revert must never be confused. Five arms, each naming what
    // it produced, so a classification that collapsed two of them shows up as an equality
    // between lines that must differ.
    // ================================================================================
    const reactor = await instantiateAvm(compiled);

    // ARM 1 — a REVERT. `revert` is the corpus program that reverts on purpose.
    const reverted = runProgram(reactor, kv, 'revert');
    t.line('traprevert.revert.kind', reverted.kind);
    t.line('traprevert.revert.revertCode', reverted.revertCode);
    t.line('traprevert.revert.reverted', reverted.reverted ? 1 : 0);
    t.line('traprevert.revert.instanceStillUsable', reactor.poisoned ? 0 : 1);

    // ARM 1b — the CONTROL that makes arm 1 a discrimination: a program that does NOT revert,
    // through the same code path. A boundary that called everything a revert would fail here.
    const succeeded = runProgram(reactor, kv, 'add');
    t.line('traprevert.success.kind', succeeded.kind);
    t.line('traprevert.success.revertCode', succeeded.revertCode);
    t.line('traprevert.success.reverted', succeeded.reverted ? 1 : 0);

    const { contractDb, merkleDb } = seedProgram(reactor, kv, 'add');

    // ARM 2 — a bad DB handle. Status 3: a host error, not a trap and not an outcome.
    let badHandle = 'no-error';
    let badHandleStatus = -1;
    try {
      reactor.callWithHandle('avm_merkle_db_get_tree_roots', 0xdeadbeef);
    } catch (e) {
      badHandle = classify(e);
      if (e instanceof AvmHostError) badHandleStatus = e.status;
    }
    t.line('traprevert.badHandle.classified', badHandle);
    t.line('traprevert.badHandle.status', badHandleStatus);

    // ARM 3 — bytes that are not msgpack, at a VALID pointer. Status 1: still a host error.
    let malformed = 'no-error';
    let malformedStatus = -1;
    let malformedMessage = '';
    try {
      reactor.simulate(new Uint8Array([0xc1, 0xc1, 0xc1, 0xc1]), contractDb, merkleDb);
    } catch (e) {
      malformed = classify(e);
      if (e instanceof AvmHostError) {
        malformedStatus = e.status;
        malformedMessage = e.message.length > 0 ? 'present' : 'empty';
      }
    }
    t.line('traprevert.malformedInput.classified', malformed);
    t.line('traprevert.malformedInput.status', malformedStatus);
    t.line('traprevert.malformedInput.messagePresent', malformedMessage === 'present' ? 1 : 0);
    t.line('traprevert.beforeTrap.instanceUsable', reactor.poisoned ? 0 : 1);

    // ARM 4 — A DELIBERATE TRAP, on the real module. The host hands `avm_simulate` a pointer past
    // the end of linear memory; the module's own reader loads out of bounds, which is a wasm trap
    // and therefore something the C++ `guarded()` cannot catch, because it is not an exception.
    const outOfBounds = reactor.memoryBytes + 0x1000;
    t.line('traprevert.trap.memoryBytes', reactor.memoryBytes);
    t.line('traprevert.trap.pointer', outOfBounds);
    let trapped = 'no-error';
    let trapExport = '';
    let trapWasOutcome = 0;
    // MEASURED off the object that was actually caught, not written down as a constant.
    //
    // An earlier version printed a literal 0 here on the grounds that `errors.ts` declares no
    // `revertCode` on `AvmTrap`. That made the assertion beside it one that could not fail, and a
    // mutation round proved the gap was reachable: a `poison()` that attached a `revertCode` to the
    // trap at RUNTIME — `(trap as Record<string, unknown>).revertCode = 0` — is invisible to the
    // type system, invisible to the class-body grep in the check, and leaves a caught trap that
    // answers 0 to `.revertCode`, i.e. reports a runtime bug as a transaction that succeeded. That
    // is the exact failure this line exists to detect, and only a reading of the caught object
    // detects it.
    let trapHasRevertCode = -1;
    try {
      const o = reactor.simulateAtRawPointer(outOfBounds, 0x1000, contractDb, merkleDb);
      trapWasOutcome = o.kind === 'tx-outcome' ? 1 : 0;
    } catch (e) {
      trapped = classify(e);
      if (e instanceof AvmTrap) {
        trapExport = e.exportName;
        trapHasRevertCode = 'revertCode' in e ? 1 : 0;
      }
    }
    t.line('traprevert.trap.classified', trapped);
    t.line('traprevert.trap.exportName', trapExport || '(none)');
    t.line('traprevert.trap.reportedAsOutcome', trapWasOutcome);
    t.line('traprevert.trap.hasRevertCodeProperty', trapHasRevertCode);
    // The control for the reading above: the SAME `in` test over a value that DOES have one. A
    // probe that answered 0 for everything would satisfy the assertion on the trap by itself.
    t.line('traprevert.revert.hasRevertCodeProperty', 'revertCode' in reverted ? 1 : 0);
    t.line('traprevert.trap.instancePoisoned', reactor.poisoned ? 1 : 0);
    t.line('traprevert.trap.leakedAtTrap', reactor.leakedAtTrap);

    // ARM 5 — the poisoned instance refuses further work rather than answering from a dead memory.
    let afterTrap = 'no-error';
    try {
      reactor.abiVersion();
    } catch (e) {
      afterTrap = classify(e);
    }
    t.line('traprevert.afterTrap.classified', afterTrap);

    // And the pool retires it rather than handing it out again.
    const pool = new InstancePool(cache);
    const first = await pool.withInstance(wasmPath, (r) => {
      // Trap this pooled instance too, so the retirement is MEASURED rather than asserted.
      // The DBs are real ones: with handle 0 the module answers status 3 before it ever reads the
      // pointer, so the arm would swallow a host error and prove nothing about traps.
      const seeded = seedProgram(r, kv, 'add');
      try {
        r.simulateAtRawPointer(r.memoryBytes + 0x1000, 0x1000, seeded.contractDb, seeded.merkleDb);
      } catch {
        /* expected: the trap */
      }
      return r.poisoned ? 1 : 0;
    });
    const second = await pool.withInstance(wasmPath, (r) => (r.poisoned ? 1 : 0));
    t.line('traprevert.pool.firstPoisoned', first);
    t.line('traprevert.pool.secondPoisoned', second);
    t.line('traprevert.pool.retired', pool.stats.retired);
    t.line('traprevert.pool.created', pool.stats.created);
    t.line('traprevert.done', 1);
  } else if (mode === 'pool') {
    const rounds = Number(rest[0] ?? 8);
    if (!Number.isInteger(rounds) || rounds <= 0) throw new Error('rounds must be a positive integer');
    const cache2 = new ModuleCache();
    const pool = new InstancePool(cache2);
    t.line('pool.rounds', rounds);

    // Arm A: many simulations through the pool, ACQUIRING ONCE PER SIMULATION.
    //
    // Per simulation rather than once around the whole loop, and that is the difference between a
    // measurement and a tautology: with one `withInstance` wrapping every round, `instancesCreated`
    // is 1 because the pool was asked once, whatever the pool does. A mutation round proved it — a
    // pool changed to retire its instance on EVERY acquisition still reported one instance created,
    // because it was only ever acquired once.
    const pooled: string[] = [];
    const pagesSeen: number[] = [];
    for (let i = 0; i < rounds; i++) {
      for (const name of names) {
        pooled.push(
          await pool.withInstance(wasmPath, (reactor) => {
            const o = runProgram(reactor, kv, name);
            return `${name}:${o.revertCode}:${digest(o.result)}`;
          }),
        );
      }
      pagesSeen.push(await pool.withInstance(wasmPath, (reactor) => reactor.pages));
    }

    // Arm B: the same simulations, each in a FRESH instance — and each going through the SAME
    // module cache, so the cache's hit count measures what the deliverable asks about: a block of
    // transactions must not recompile the module per transaction.
    const fresh: string[] = [];
    for (let i = 0; i < rounds; i++) {
      for (const name of names) {
        const reactor = await instantiateAvm(await cache2.get(wasmPath));
        const o = runProgram(reactor, kv, name);
        fresh.push(`${name}:${o.revertCode}:${digest(o.result)}`);
      }
    }

    t.line('pool.pooledResults', pooled.length);
    t.line('pool.freshResults', fresh.length);
    let mismatches = 0;
    for (let i = 0; i < pooled.length; i++) if (pooled[i] !== fresh[i]) mismatches++;
    t.line('pool.mismatches', mismatches);
    t.line('pool.pagesFirstRound', pagesSeen[0]);
    t.line('pool.pagesLastRound', pagesSeen[pagesSeen.length - 1]);
    t.line('pool.pageGrowthAcrossRounds', pagesSeen[pagesSeen.length - 1] - pagesSeen[0]);
    t.line('pool.peakBytes', pagesSeen[pagesSeen.length - 1] * 65536);
    t.line('pool.moduleCompilations', cache2.missCount);
    t.line('pool.moduleCacheHits', cache2.hitCount);
    t.line('pool.instancesCreated', pool.stats.created);
    t.line('pool.instancesReused', pool.stats.reused);
    t.line('pool.instancesRetired', pool.stats.retired);
    t.line('pool.done', 1);
  } else if (mode === 'steps') {
    const program = rest[0];
    const batch = Number(rest[1]);
    if (!program || !Number.isInteger(batch) || batch <= 0) {
      throw new Error('usage: ... steps <program> <batch>');
    }
    const reactor = await instantiateAvm(compiled);
    const outcome = runProgram(reactor, kv, program, 'faststeps');
    // MEASURED as a difference of two readings of the boundary's own call counter, not printed as
    // a constant: "the stream inside the result costs no further crossings" is the claim the check
    // asserts, and a zero nothing measured would be an assertion that could not fail.
    const callsBeforeInResult = reactor.moduleCalls;
    const inResult = stepsFromOutcome(outcome);
    const crossingsForInResult = reactor.moduleCalls - callsBeforeInResult;
    const count = stepCount(reactor);
    t.line('steps.program', program);
    t.line('steps.batchSize', batch);
    t.line('steps.count', count);
    t.line('steps.inResultCount', inResult ? inResult.length : -1);
    t.line('steps.crossingsForWholeStreamInResult', crossingsForInResult);
    const callsBeforeDrain = reactor.moduleCalls;
    const drained = drainSteps(reactor, batch, count);
    // The control for the reading above: the SAME counter over the route that DOES cross, so a
    // counter stuck at any constant fails here rather than passing as a zero.
    t.line('steps.moduleCallsDuringDrain', reactor.moduleCalls - callsBeforeDrain);
    t.line('steps.drained', drained.decoded);
    t.line('steps.crossings', drained.crossings);
    t.line('steps.expectedCrossings', expectedCrossings(count, batch));
    if (count > 0) {
      t.line('steps.first', formatStep(drained.steps[0], hexOf));
      t.line('steps.last', formatStep(drained.steps[drained.steps.length - 1], hexOf));
    }
    // The batched stream and the one that arrived inside the result must be the SAME records.
    let diff = -1;
    if (inResult) {
      diff = 0;
      for (let i = 0; i < Math.max(inResult.length, drained.steps.length); i++) {
        const a = inResult[i] ? formatStep(inResult[i], hexOf) : '(absent)';
        const b = drained.steps[i] ? formatStep(drained.steps[i], hexOf) : '(absent)';
        if (a !== b) diff++;
      }
    }
    t.line('steps.resultVersusBatchedDifferences', diff);
    t.line('steps.ownedAllocationsAtExit', reactor.ownedAllocations);
    t.line('steps.done', 1);
  } else {
    process.stderr.write(`cli.ts: unknown mode: ${mode}\n`);
    await exitAfterFlush(2);
  }
} catch (e) {
  process.stdout.write(t.render());
  const err = e as Error;
  process.stderr.write(`cli.ts: ${classify(e)}: ${err && err.stack ? err.stack : String(e)}\n`);
  await exitAfterFlush(5);
}

process.stdout.write(t.render());
await exitAfterFlush(0);

/** A short, order-independent digest of a result, for comparing two runs of the same program. */
function digest(result: unknown): string {
  const r = result as {
    gasUsed: { totalGas: { l2Gas: number; daGas: number } };
    publicTxEffect: { transactionFee: Uint8Array; nullifiers: Uint8Array[]; publicDataWrites: unknown[] };
  };
  return [
    r.gasUsed.totalGas.l2Gas,
    r.gasUsed.totalGas.daGas,
    hexOf(r.publicTxEffect.transactionFee),
    r.publicTxEffect.nullifiers.length,
    r.publicTxEffect.publicDataWrites.length,
  ].join('/');
}
