// The msgpack wire format. ONE implementation, for the whole repo.
//
// THIS DECODES; IT NEVER ENCODES. Every blob that crosses INTO the module is produced by
// upstream's own msgpack packers in C++ (`avm_differential reactorinputs` emits them as hex), for
// the reason M12 recorded and this milestone inherits: a JavaScript encoder of ours would be a
// second, independent implementation of upstream's schemas, and two implementations of an encoding
// are two things that can disagree. Decoding is unavoidable — results have to be read — and what
// is decoded here is the WIRE FORMAT, not the schemas: this file knows what a `0xdc` byte means
// and knows nothing about `TxSimulationResult`.
//
// The same argument is why this file, rather than a second copy, is what `verification/wasm_host/
// reactor_lib.mjs` re-exports: M13 already extracted the decoder once so M12's and M13's hosts
// could not disagree, and that argument does not stop applying because the third copy would be in
// TypeScript.
//
// `bin` comes back as a `Uint8Array` because that is what a 32-byte field element is on the wire —
// barretenberg's `field::msgpack_pack` writes `pack_bin(32)` big-endian — and only the transcript
// formatter decides that a 32-byte bin should be rendered as `0x…`.

/** Anything the wire format can carry. */
export type MsgpackValue =
  | null
  | boolean
  | number
  | bigint
  | string
  | Uint8Array
  | MsgpackValue[]
  | { [key: string]: MsgpackValue };

export class Decoder {
  private readonly u8: Uint8Array;
  private readonly dv: DataView;
  private o = 0;

  constructor(bytes: Uint8Array) {
    this.u8 = bytes;
    this.dv = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  }

  /** Bytes consumed so far. `unpack` uses it to refuse a blob with trailing garbage. */
  get offset(): number {
    return this.o;
  }

  private u8at(): number {
    return this.u8[this.o++];
  }

  private bytes(n: number): Uint8Array {
    const s = this.u8.subarray(this.o, this.o + n);
    this.o += n;
    return s;
  }

  private str(n: number): string {
    return new TextDecoder().decode(this.bytes(n));
  }

  private arr(n: number): MsgpackValue[] {
    const a: MsgpackValue[] = new Array(n);
    for (let i = 0; i < n; i++) a[i] = this.next();
    return a;
  }

  private map(n: number): { [key: string]: MsgpackValue } {
    const m: { [key: string]: MsgpackValue } = {};
    for (let i = 0; i < n; i++) {
      const k = this.next();
      m[typeof k === 'string' ? k : String(k)] = this.next();
    }
    return m;
  }

  private u64(): number | bigint {
    const v = this.dv.getBigUint64(this.o, false);
    this.o += 8;
    return v <= BigInt(Number.MAX_SAFE_INTEGER) ? Number(v) : v;
  }

  private i64(): number | bigint {
    const v = this.dv.getBigInt64(this.o, false);
    this.o += 8;
    return v <= BigInt(Number.MAX_SAFE_INTEGER) && v >= BigInt(Number.MIN_SAFE_INTEGER) ? Number(v) : v;
  }

  next(): MsgpackValue {
    const b = this.u8at();
    if (b <= 0x7f) return b;
    if (b >= 0xe0) return b - 0x100;
    if (b >= 0x80 && b <= 0x8f) return this.map(b & 0x0f);
    if (b >= 0x90 && b <= 0x9f) return this.arr(b & 0x0f);
    if (b >= 0xa0 && b <= 0xbf) return this.str(b & 0x1f);
    switch (b) {
      case 0xc0:
        return null;
      case 0xc2:
        return false;
      case 0xc3:
        return true;
      case 0xc4:
        return this.bytes(this.u8at());
      case 0xc5: {
        const n = this.dv.getUint16(this.o, false);
        this.o += 2;
        return this.bytes(n);
      }
      case 0xc6: {
        const n = this.dv.getUint32(this.o, false);
        this.o += 4;
        return this.bytes(n);
      }
      case 0xca: {
        const v = this.dv.getFloat32(this.o, false);
        this.o += 4;
        return v;
      }
      case 0xcb: {
        const v = this.dv.getFloat64(this.o, false);
        this.o += 8;
        return v;
      }
      case 0xcc:
        return this.u8at();
      case 0xcd: {
        const v = this.dv.getUint16(this.o, false);
        this.o += 2;
        return v;
      }
      case 0xce: {
        const v = this.dv.getUint32(this.o, false);
        this.o += 4;
        return v;
      }
      case 0xcf:
        return this.u64();
      case 0xd0: {
        const v = this.dv.getInt8(this.o);
        this.o += 1;
        return v;
      }
      case 0xd1: {
        const v = this.dv.getInt16(this.o, false);
        this.o += 2;
        return v;
      }
      case 0xd2: {
        const v = this.dv.getInt32(this.o, false);
        this.o += 4;
        return v;
      }
      case 0xd3:
        return this.i64();
      case 0xd9:
        return this.str(this.u8at());
      case 0xda: {
        const n = this.dv.getUint16(this.o, false);
        this.o += 2;
        return this.str(n);
      }
      case 0xdb: {
        const n = this.dv.getUint32(this.o, false);
        this.o += 4;
        return this.str(n);
      }
      case 0xdc: {
        const n = this.dv.getUint16(this.o, false);
        this.o += 2;
        return this.arr(n);
      }
      case 0xdd: {
        const n = this.dv.getUint32(this.o, false);
        this.o += 4;
        return this.arr(n);
      }
      case 0xde: {
        const n = this.dv.getUint16(this.o, false);
        this.o += 2;
        return this.map(n);
      }
      case 0xdf: {
        const n = this.dv.getUint32(this.o, false);
        this.o += 4;
        return this.map(n);
      }
      default:
        throw new Error(`msgpack: unsupported type byte 0x${b.toString(16)} at ${this.o - 1}`);
    }
  }
}

/** Decodes exactly one value and refuses a blob with anything after it. */
export function unpack(bytes: Uint8Array): MsgpackValue {
  const d = new Decoder(bytes);
  const v = d.next();
  if (d.offset !== bytes.length) throw new Error(`msgpack: ${bytes.length - d.offset} trailing byte(s)`);
  return v;
}

/** Hex-renders a field element. Refuses anything that is not a `bin`, rather than printing it. */
export function hexOf(bin: MsgpackValue): string {
  if (!(bin instanceof Uint8Array)) throw new Error(`expected a field element (bin), got ${typeof bin}`);
  const HEXDIGITS = '0123456789abcdef';
  let s = '0x';
  for (const b of bin) s += HEXDIGITS[(b >> 4) & 0xf] + HEXDIGITS[b & 0xf];
  return s;
}
