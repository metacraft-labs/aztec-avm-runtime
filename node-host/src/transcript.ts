// A Node-side transcript runner producing the same output format as the M8 driver.
//
// "The same format" is meant literally: the keys below are the ones `avm_differential`'s own
// `dump_result` prints in C++, so the two transcripts are comparable LINE FOR LINE rather than
// "equivalent". Tree roots are part of it — `start.*` and `end.*` are the four
// `AppendOnlyTreeSnapshot`s of `PublicInputs.{start,end}TreeSnapshots`, rendered root-then-size —
// because M17's verification asks for transcripts "including tree roots" and a transcript that
// agreed on gas and said nothing about the trees would be the weaker claim M8 already made.
//
// THE INPUTS ARE UPSTREAM'S BYTES. Every blob handed to the module is produced by
// `avm_differential reactorinputs`, that is by upstream's own msgpack packers in C++, and arrives
// here as hex. This package decodes and never encodes, for M12's reason: a JavaScript encoder of
// ours would be a second implementation of upstream's schemas and two implementations of an
// encoding are two things that can disagree.

import { hexOf, type MsgpackValue } from './msgpack.ts';
import type { Reactor } from './reactor.ts';
import type { TxOutcome } from './errors.ts';

/** The `<key> <value>` lines of an inputs file. */
export function parseInputs(text: string): Map<string, string> {
  const kv = new Map<string, string>();
  for (const l of text.split('\n')) {
    if (!l) continue;
    const i = l.indexOf(' ');
    if (i < 0) continue;
    kv.set(l.slice(0, i), l.slice(i + 1));
  }
  return kv;
}

/** A hex blob from the inputs file. A missing key is an error, never an empty blob. */
export function blobFrom(kv: Map<string, string>, key: string): Uint8Array {
  const hex = kv.get(key);
  if (hex === undefined) throw new Error(`the inputs file has no ${key}`);
  const n = hex.length / 2;
  const b = new Uint8Array(n);
  for (let i = 0; i < n; i++) b[i] = parseInt(hex.substr(i * 2, 2), 16);
  return b;
}

/** The program names the inputs file declares, cross-checked against its own count. */
export function programNames(kv: Map<string, string>): string[] {
  const declared = Number(kv.get('reactorInputs.programs.count'));
  if (!Number.isInteger(declared) || declared <= 0) throw new Error('the inputs file declares no programs');
  const names: string[] = [];
  for (const k of kv.keys()) {
    const m = /^reactorInputs\.([a-z0-9]+)\.address$/.exec(k);
    if (m) names.push(m[1]);
  }
  if (names.length !== declared) {
    throw new Error(`the inputs file declares ${declared} programs but carries ${names.length}`);
  }
  return names;
}

/** Collects `<key> <value>` lines. */
export class Transcript {
  private readonly lines: string[] = [];

  line(key: string, value: string | number): void {
    this.lines.push(`${key} ${value}`);
  }

  get length(): number {
    return this.lines.length;
  }

  render(): string {
    return this.lines.join('\n') + '\n';
  }
}

type Snapshot = { root: MsgpackValue; nextAvailableLeafIndex: number };
type Snapshots = {
  noteHashTree: Snapshot;
  nullifierTree: Snapshot;
  publicDataTree: Snapshot;
  l1ToL2MessageTree: Snapshot;
};

function snapshotLine(t: Transcript, prefix: string, name: string, snap: Snapshot): void {
  t.line(`${prefix}.${name}`, `${hexOf(snap.root)} size=${snap.nextAvailableLeafIndex}`);
}

/** The four tree roots and sizes, in the driver's own order. */
export function snapshots(t: Transcript, prefix: string, s: Snapshots): void {
  snapshotLine(t, prefix, 'NOTE_HASH_TREE', s.noteHashTree);
  snapshotLine(t, prefix, 'NULLIFIER_TREE', s.nullifierTree);
  snapshotLine(t, prefix, 'PUBLIC_DATA_TREE', s.publicDataTree);
  snapshotLine(t, prefix, 'L1_TO_L2_MESSAGE_TREE', s.l1ToL2MessageTree);
}

interface SimulationResultShape {
  revertCode: number;
  gasUsed: {
    totalGas: { l2Gas: number; daGas: number };
    publicGas: { l2Gas: number; daGas: number };
    billedGas: { l2Gas: number; daGas: number };
  };
  publicTxEffect: {
    transactionFee: MsgpackValue;
    nullifiers: MsgpackValue[];
    noteHashes: MsgpackValue[];
    publicDataWrites: MsgpackValue[];
    publicLogs: MsgpackValue[];
  };
  callStackMetadata: MsgpackValue[];
  publicInputs: { startTreeSnapshots: Snapshots; endTreeSnapshots: Snapshots } | null;
  stats: Record<string, MsgpackValue>;
}

/** `dump_result`'s shape, field for field. */
export function dumpResult(t: Transcript, prefix: string, outcome: TxOutcome<MsgpackValue>): void {
  const r = outcome.result as unknown as SimulationResultShape;
  t.line(`${prefix}.revertCode`, outcome.revertCode);
  t.line(`${prefix}.totalGas`, `${r.gasUsed.totalGas.l2Gas}/${r.gasUsed.totalGas.daGas}`);
  t.line(`${prefix}.publicGas`, `${r.gasUsed.publicGas.l2Gas}/${r.gasUsed.publicGas.daGas}`);
  t.line(`${prefix}.billedGas`, `${r.gasUsed.billedGas.l2Gas}/${r.gasUsed.billedGas.daGas}`);
  t.line(`${prefix}.txFee`, hexOf(r.publicTxEffect.transactionFee));
  t.line(`${prefix}.nullifiers.count`, r.publicTxEffect.nullifiers.length);
  r.publicTxEffect.nullifiers.forEach((n, i) => t.line(`${prefix}.nullifiers.${i}`, hexOf(n)));
  t.line(`${prefix}.noteHashes.count`, r.publicTxEffect.noteHashes.length);
  r.publicTxEffect.noteHashes.forEach((n, i) => t.line(`${prefix}.noteHashes.${i}`, hexOf(n)));
  t.line(`${prefix}.dataWrites.count`, r.publicTxEffect.publicDataWrites.length);
  t.line(`${prefix}.publicLogs.count`, r.publicTxEffect.publicLogs.length);
  t.line(`${prefix}.callFrames.count`, r.callStackMetadata.length);
  if (r.publicInputs) {
    snapshots(t, `${prefix}.start`, r.publicInputs.startTreeSnapshots);
    snapshots(t, `${prefix}.end`, r.publicInputs.endTreeSnapshots);
  } else {
    t.line(`${prefix}.publicInputs`, 'ABSENT');
  }
  for (const k of Object.keys(r.stats).sort()) t.line(`${prefix}.stat.${k}`, String(r.stats[k]));
}

/** Seeds one program's resident DBs out of the inputs file, exactly as M12's host does. */
export function seedProgram(
  reactor: Reactor,
  kv: Map<string, string>,
  name: string,
): { contractDb: number; merkleDb: number } {
  const contractDb = reactor.createContractDb();
  const merkleDb = reactor.createMerkleDb();
  reactor.callWithBlob('avm_contract_db_register_class', contractDb, blobFrom(kv, `reactorInputs.${name}.setup.class`));
  reactor.callWithBlob(
    'avm_contract_db_register_instance',
    contractDb,
    blobFrom(kv, `reactorInputs.${name}.setup.instance`),
  );
  reactor.callWithBlob(
    'avm_merkle_db_insert_indexed_leaves_nullifier_tree',
    merkleDb,
    blobFrom(kv, `reactorInputs.${name}.setup.nullifier`),
  );
  reactor.callWithBlob(
    'avm_merkle_db_insert_indexed_leaves_public_data_tree',
    merkleDb,
    blobFrom(kv, `reactorInputs.${name}.setup.publicdata`),
  );
  return { contractDb, merkleDb };
}

/** Runs one program on the given reactor and returns its outcome. */
export function runProgram(
  reactor: Reactor,
  kv: Map<string, string>,
  name: string,
  inputKey = 'fast',
): TxOutcome<MsgpackValue> {
  const { contractDb, merkleDb } = seedProgram(reactor, kv, name);
  try {
    return reactor.simulate(blobFrom(kv, `reactorInputs.${name}.${inputKey}`), contractDb, merkleDb);
  } finally {
    if (!reactor.poisoned) {
      reactor.destroyContractDb(contractDb);
      reactor.destroyMerkleDb(merkleDb);
    }
  }
}
