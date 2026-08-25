// roundtrip_cli.ts — the two halves, run together.
//
// NOT exported from index.ts. This is a driver, the way node-host's cli.ts is, and it exists to
// produce one measurement: does the byte stream `avm.wasm` returns satisfy UPSTREAM'S OWN
// TypeScript types?
//
// That is the question M18 is really about. The C++ half and the TypeScript half of this runtime
// have never met: the C++ side has been checked against native C++ (M8), and the TypeScript side
// has been checked against the native NAPI AVM (M2's differential). The claim that they compose
// is, until this runs, an inference from the fact that both sides use msgpack.
//
// Two decoders read the SAME bytes and are compared:
//
//   * `node-host`'s `unpack` — dependency-free, decodes a 32-byte `bin` as a `Uint8Array`, which
//     is what the M17 transcript compares against the native reference.
//   * `@aztec/stdlib/avm`'s `deserializeFromMessagePack` — decodes THROUGH the msgpackr
//     extensions upstream registers, so the same 32 bytes come back as an `Fr`, an address as an
//     `AztecAddress`, and `PublicTxResult.fromPlainObject` will accept the result.
//
// If the second decoder throws, or produces a `PublicTxResult` whose fields disagree with the
// first, then the two halves do not compose and this milestone's premise is wrong. Both
// possibilities are reported as data rather than as an exit status, so the check that reads this
// output can say which one happened.
//
// Every value printed is READ OUT OF A DECODED OBJECT. Nothing here prints a constant that a
// check then asserts — the campaign has now been caught twice by exactly that, most recently by
// a literal `0` standing in for "the trap carries no revert code".
//
//   node src/roundtrip_cli.ts <avm.wasm> <reactor-inputs.txt>

import { PublicTxResult, deserializeFromMessagePack } from '@aztec/stdlib/avm';

import { ModuleCache, InstancePool } from '../../node-host/src/pool.ts';
import { unpack, hexOf, type MsgpackValue } from '../../node-host/src/msgpack.ts';
import { parseInputs, programNames, blobFrom, seedProgram } from '../../node-host/src/transcript.ts';
import type { Reactor } from '../../node-host/src/reactor.ts';

const out: string[] = [];
const line = (k: string, v: string | number | boolean) => out.push(`${k} ${v}`);

function flushAndExit(code: number): void {
  // M9's lesson, applied and then applied AGAIN. The first version of this function wrote with a
  // completion callback that called `process.exit(code)`, and then span-waited on `for (;;) {}`
  // to satisfy a `never` return type. The busy loop OWNS THE EVENT LOOP, so the drain callback
  // can never run: the process printed nothing and hung. Setting `process.exitCode` and
  // returning is the whole fix — Node flushes stdout and exits on its own, which is exactly what
  // M9's finding says to do and what the callback dance was trying to reimplement.
  process.stdout.write(`${out.join('\n')}\n`);
  process.exitCode = code;
}

/**
 * Run one program and hand back the RAW result bytes as well as node-host's decode. `simulate()`
 * decodes for you and the raw buffer is module-owned, so the export is called directly here —
 * the same three calls `Reactor.simulate` makes, with `result()` read before anything else can
 * overwrite the buffer.
 */
function runRaw(reactor: Reactor, kv: Map<string, string>, name: string) {
  const { contractDb, merkleDb } = seedProgram(reactor, kv, name);
  try {
    const input = blobFrom(kv, `reactorInputs.${name}.fast`);
    return reactor.withBlob(input, (ptr, len) => {
      const status = reactor.callGuarded('avm_simulate', () =>
        reactor.exports.avm_simulate(ptr, len, contractDb, merkleDb),
      );
      const bytes = reactor.result();
      return { status, bytes };
    });
  } finally {
    if (!reactor.poisoned) {
      reactor.destroyContractDb(contractDb);
      reactor.destroyMerkleDb(merkleDb);
    }
  }
}

function num(x: unknown): string {
  return typeof x === 'bigint' ? x.toString() : String(x);
}

/** `Fr`, `AztecAddress` and friends all answer `toString()` with a 0x-prefixed field. */
function field(x: unknown): string {
  if (x instanceof Uint8Array) return hexOf(x);
  if (x && typeof (x as { toString: () => string }).toString === 'function') {
    return String(x);
  }
  return String(x);
}

async function main(): Promise<void> {
  const [wasmPath, inputsPath] = process.argv.slice(2);
  if (!wasmPath || !inputsPath) {
    line('roundtrip.usage', 'roundtrip_cli.ts <avm.wasm> <reactor-inputs.txt>');
    flushAndExit(2);
    return;
  }

  const { readFileSync } = await import('node:fs');
  const kv = parseInputs(readFileSync(inputsPath, 'utf8'));
  const names = programNames(kv);
  line('roundtrip.programs.count', names.length);

  const pool = new InstancePool(new ModuleCache());
  let mismatches = 0;
  let decodeFailures = 0;

  for (const name of names) {
    await pool.withInstance(wasmPath, (reactor) => {
      const { status, bytes } = runRaw(reactor, kv, name);
      const p = `roundtrip.${name}`;
      line(`${p}.status`, status);
      if (!bytes) {
        line(`${p}.resultBytes`, 0);
        decodeFailures += 1;
        return;
      }
      line(`${p}.resultBytes`, bytes.length);

      // Decoder A — node-host's, the one M17's transcript is built on.
      const a = unpack(bytes) as unknown as {
        revertCode: number;
        gasUsed: { totalGas: { l2Gas: number; daGas: number } };
        publicTxEffect: { transactionFee: MsgpackValue; nullifiers: MsgpackValue[] };
      };
      line(`${p}.nodeHost.revertCode`, num(a.revertCode));
      line(`${p}.nodeHost.totalGas`, `${num(a.gasUsed.totalGas.l2Gas)}/${num(a.gasUsed.totalGas.daGas)}`);
      line(`${p}.nodeHost.txFee`, hexOf(a.publicTxEffect.transactionFee));
      line(`${p}.nodeHost.nullifiers.count`, a.publicTxEffect.nullifiers.length);

      // Decoder B — upstream's, through the registered msgpackr extensions.
      let b: Record<string, unknown>;
      try {
        b = deserializeFromMessagePack(Buffer.from(bytes)) as Record<string, unknown>;
      } catch (e) {
        line(`${p}.stdlib.decode`, `THREW:${(e as Error).message.slice(0, 80)}`);
        decodeFailures += 1;
        return;
      }
      line(`${p}.stdlib.decode`, 'ok');
      line(`${p}.stdlib.topLevelKeys`, Object.keys(b).sort().join(','));

      const gas = b['gasUsed'] as { totalGas: { l2Gas: unknown; daGas: unknown } };
      const eff = b['publicTxEffect'] as { transactionFee: unknown; nullifiers: unknown[] };
      line(`${p}.stdlib.revertCode`, num(b['revertCode']));
      line(`${p}.stdlib.totalGas`, `${num(gas.totalGas.l2Gas)}/${num(gas.totalGas.daGas)}`);
      line(`${p}.stdlib.txFee`, field(eff.transactionFee));
      line(`${p}.stdlib.nullifiers.count`, eff.nullifiers.length);
      // WHAT THE TWO DECODERS DO WITH A `bin`, MEASURED RATHER THAN ASSUMED — and the first
      // draft of this driver assumed WRONG. It expected upstream's decoder to hand back an `Fr`,
      // because `serializeWithMessagePack` registers an msgpackr extension for that class. The
      // extension's `read` side never fires: the C++ writer emits a PLAIN, UNTAGGED `bin`, and
      // msgpackr dispatches read extensions on a tag that is not there. Upstream says so itself,
      // in @aztec/native's msgpack_channel.ts — "this only works for writes. Unpacking from C++
      // can't create Fr instances because the data is passed as raw, untagged, buffers."
      //
      // So both decoders return raw bytes for a field element, and the agreement below on `bin`
      // fields is NOT independent evidence. It is recorded here as the measured fact it is,
      // rather than as the control it was drafted as.
      line(`${p}.stdlib.txFee.isUint8Array`, eff.transactionFee instanceof Uint8Array);
      line(
        `${p}.stdlib.txFee.ctor`,
        (eff.transactionFee as { constructor?: { name?: string } })?.constructor?.name ?? 'none',
      );
      line(
        `${p}.nodeHost.txFee.ctor`,
        (a.publicTxEffect.transactionFee as { constructor?: { name?: string } })?.constructor
          ?.name ?? 'none',
      );

      // WHERE THEY DO DIFFER, which is what makes `decoders.agree` a comparison of two decoders
      // rather than of one decoder with itself. Upstream's is constructed with
      // `int64AsType: 'bigint'`; node-host's is not, so a 64-bit integer comes back with a
      // different JS type from each. Reported as the two typeof strings, so the check asserts
      // the difference rather than taking it on trust.
      line(`${p}.nodeHost.l2Gas.typeof`, typeof a.gasUsed.totalGas.l2Gas);
      line(`${p}.stdlib.l2Gas.typeof`, typeof gas.totalGas.l2Gas);
      line(
        `${p}.decoders.differInRepresentation`,
        typeof a.gasUsed.totalGas.l2Gas !== typeof gas.totalGas.l2Gas,
      );

      // The comparison. Every field is read off BOTH decoded objects; nothing is printed as a
      // constant and then asserted equal to itself.
      const agree =
        num(a.revertCode) === num(b['revertCode']) &&
        num(a.gasUsed.totalGas.l2Gas) === num(gas.totalGas.l2Gas) &&
        num(a.gasUsed.totalGas.daGas) === num(gas.totalGas.daGas) &&
        hexOf(a.publicTxEffect.transactionFee) === field(eff.transactionFee) &&
        a.publicTxEffect.nullifiers.length === eff.nullifiers.length;
      line(`${p}.decoders.agree`, agree);
      if (!agree) mismatches += 1;

      // And the type upstream's orchestration actually passes around.
      try {
        const typed = PublicTxResult.fromPlainObject(b);
        line(`${p}.publicTxResult`, 'ok');
        line(`${p}.publicTxResult.revertCode.isOK`, typed.revertCode.isOK());
        line(`${p}.publicTxResult.totalGas.l2Gas`, num(typed.gasUsed.totalGas.l2Gas));
        line(
          `${p}.publicTxResult.agreesWithRaw`,
          num(typed.gasUsed.totalGas.l2Gas) === num(gas.totalGas.l2Gas) &&
            typed.revertCode.isOK() === (num(b['revertCode']) === '0'),
        );
      } catch (e) {
        line(`${p}.publicTxResult`, `THREW:${(e as Error).message.slice(0, 120)}`);
        decodeFailures += 1;
      }

      // THE CONTROL THAT MAKES "IT ACCEPTED THE BYTES" MEAN SOMETHING. `fromPlainObject` is a
      // zod parse, and a parse that accepted anything would accept the wasm module's output for
      // no reason at all. The same object with ONE field made the wrong type must be REJECTED.
      // Two corruptions, not one: a field of the wrong primitive type and a whole required
      // subtree removed, because a schema can be lax about one and strict about the other.
      const wrongType = { ...b, revertCode: 'not-a-revert-code' };
      const missing = { ...b };
      delete (missing as Record<string, unknown>)['gasUsed'];
      let rejectedWrongType = false;
      let rejectedMissing = false;
      try {
        PublicTxResult.fromPlainObject(wrongType);
      } catch {
        rejectedWrongType = true;
      }
      try {
        PublicTxResult.fromPlainObject(missing);
      } catch {
        rejectedMissing = true;
      }
      line(`${p}.publicTxResult.rejectsWrongType`, rejectedWrongType);
      line(`${p}.publicTxResult.rejectsMissingField`, rejectedMissing);

      // AND THE THIRD CONTROL, which turned out to be the strongest and was found by mutating
      // this driver rather than by reasoning about it: the two decoders are NOT interchangeable
      // for this type. Handing `PublicTxResult.fromPlainObject` node-host's decode of the SAME
      // bytes fails, because `BaseField`'s constructor accepts a `Buffer` and refuses a plain
      // `Uint8Array` — "Type 'object' with value '0,0,0,…' passed to BaseField ctor". So the
      // Buffer-versus-Uint8Array difference recorded above is not decorative: it is exactly the
      // property that makes upstream's decoder the required one, and "it accepted the module's
      // bytes" is a statement about upstream's decoder specifically.
      let nodeHostDecodeRejected = false;
      let nodeHostRejectionMessage = '';
      try {
        PublicTxResult.fromPlainObject(a as unknown as Record<string, unknown>);
      } catch (e) {
        nodeHostDecodeRejected = true;
        // A TOKEN DERIVED FROM THE MESSAGE, not a truncation of it. The message reads
        // "Type 'object' with value '0,0,0,…,62,11' passed to BaseField ctor." — 32 comma-joined
        // bytes in the middle, so a fixed-length slice cuts off the only part that names the
        // cause, which is what the first version of this line did.
        const msg = (e as Error).message;
        nodeHostRejectionMessage = /\bBaseField\b/.test(msg)
          ? 'BaseField-ctor'
          : msg.replace(/[0-9]+(,[0-9]+){4,}/g, '<bytes>').slice(0, 80);
      }
      line(`${p}.publicTxResult.rejectsNodeHostDecode`, nodeHostDecodeRejected);
      line(`${p}.publicTxResult.nodeHostRejection`, nodeHostRejectionMessage || 'none');
    });
  }

  const stats = pool.stats;
  line('roundtrip.pool.created', stats.created);
  line('roundtrip.pool.reused', stats.reused);
  line('roundtrip.pool.retired', stats.retired);
  line('roundtrip.mismatches', mismatches);
  line('roundtrip.decodeFailures', decodeFailures);
  line('roundtrip.done', 1);
  flushAndExit(mismatches === 0 && decodeFailures === 0 ? 0 : 1);
}

await main();
