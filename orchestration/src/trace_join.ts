// trace_join.ts — M26: what makes two halves of one transaction ONE recording.
//
// ---------------------------------------------------------------------------
// THE JOIN IS RECORDED, NEVER INFERRED, AND THAT IS THE WHOLE DELIVERABLE.
//
// M26's own wording is "two recordings joined in the UI, with the join recorded explicitly rather
// than inferred". The temptation is obvious and this file exists to close it: two `.ct` files that
// sit in one directory, or share a filename stem, or were written within a second of each other,
// LOOK joined, and a reader that decides they are will be right almost every time and wrong on the
// run that matters — two transactions recorded concurrently, a directory a user copied files into,
// a stem that collides. None of those is detectable after the fact, because the evidence a reader
// would need is exactly the evidence nobody wrote down.
//
// So the producer writes a JOIN RECORD into every half, as a `TraceLogEvent` under one metadata
// key, carrying: the join identity, which half this is, and HOW MANY halves the join has. The last
// of those is what makes an incomplete join distinguishable from a complete one — without it, a
// reader handed one half of a two-half join cannot tell it from a whole recording.
//
// `joinRecordings` REFUSES rather than guessing, on five distinguishable grounds, and every refusal
// names the ground. A function that returned a best-effort join would put this file back where it
// started.
// ---------------------------------------------------------------------------
//
// THE SAME KEY AND THE SAME CONTENT GRAMMAR ARE PRODUCED IN TWO LANGUAGES, and that is a hazard
// this campaign has a rule about. `verification/oq7_shared_writer_probe.rs` writes the record from
// Rust; this file writes and reads it from TypeScript. Two literals that happen to match today are
// two literals that diverge tomorrow, so `test_join_fallback_two_recordings` asserts the key and
// the rendered content are IDENTICAL across the two implementations by rendering both and comparing
// the bytes — not by reading one and trusting the other.
//
// M25's `ct.mapping-rung` is the shape being followed: a fixed metadata key a reader greps for, and
// a `key=value` content line, so a rung declaration and a join record are read by the same kind of
// consumer and neither needs a schema negotiation.

/** The metadata key every join record is written under. */
export const JOIN_EVENT_METADATA = 'ct.trace-join';

/**
 * The reason clause, carried in every record.
 *
 * It is a constant rather than free text because it is the sentence a reader of a container needs
 * in order to know that the join in front of them is not a guess somebody's tooling made.
 */
export const JOIN_REASON = 'recorded-by-the-producer-not-inferred-by-a-reader';

/**
 * How the two halves were written.
 *
 * `shared` — one writer instance, two producers, ONE container. The join record still exists, and
 *   its `half` is `both`: a single-container recording that says so is readable by the same
 *   consumer as a two-container one, and the alternative (no record at all when there is one file)
 *   would make "no join record" mean two different things.
 * `split`  — one writer per half, two containers. OQ-7's fallback.
 */
export type JoinArm = 'shared' | 'split';

/** Which half of the transaction a container carries. */
export type TraceHalf = 'private' | 'public' | 'both';

/** What a join record says. */
export interface JoinRecord {
  /** The join identity. Every half of one join carries the same string. */
  readonly joinId: string;
  /** Which half this container is. */
  readonly half: TraceHalf;
  /** How many halves this join has. `1` on the `shared` arm, `2` on `split`. */
  readonly halves: number;
  readonly arm: JoinArm;
  /** Always {@link JOIN_REASON}. Present in the bytes so a reader does not have to know this file. */
  readonly reason: string;
}

/** Build a record. `reason` is not a parameter: there is one reason and it is the constant above. */
export function joinRecord(joinId: string, half: TraceHalf, halves: number, arm: JoinArm): JoinRecord {
  if (joinId.length === 0) {
    throw new RangeError('a join identity must not be empty; a join nobody can name is not a join');
  }
  if (!Number.isInteger(halves) || halves < 1) {
    throw new RangeError(`halves must be a positive integer, got ${String(halves)}`);
  }
  return { joinId, half, halves, arm, reason: JOIN_REASON };
}

/**
 * Render a record as the content of its `TraceLogEvent`.
 *
 * **The field order and the spacing are load-bearing**, because the Rust probe renders the same
 * five fields with a `format!` and the two must produce the same bytes. `format` and its inverse
 * are both here so the grammar has exactly one definition on this side.
 */
export function formatJoinRecord(r: JoinRecord): string {
  return `join=${r.joinId} half=${r.half} halves=${r.halves} arm=${r.arm} reason=${r.reason}`;
}

/**
 * Read a record back. `undefined` when the content is not one — never a partially-filled record.
 *
 * A parser that filled in what it could would reintroduce inference through the back door: a
 * container whose join record lost its `halves` field would come back as a join with a default
 * count, and the default would be right until it was not.
 */
export function parseJoinRecord(content: string): JoinRecord | undefined {
  const fields = new Map<string, string>();
  for (const token of content.trim().split(/\s+/)) {
    const eq = token.indexOf('=');
    if (eq <= 0) return undefined;
    fields.set(token.slice(0, eq), token.slice(eq + 1));
  }
  const joinId = fields.get('join');
  const half = fields.get('half');
  const halves = fields.get('halves');
  const arm = fields.get('arm');
  const reason = fields.get('reason');
  if (joinId === undefined || half === undefined || halves === undefined) return undefined;
  if (arm === undefined || reason === undefined) return undefined;
  if (half !== 'private' && half !== 'public' && half !== 'both') return undefined;
  if (arm !== 'shared' && arm !== 'split') return undefined;
  const n = Number(halves);
  if (!Number.isInteger(n) || n < 1) return undefined;
  return { joinId, half, halves: n, arm, reason };
}

/** Thrown when a set of halves cannot be joined. The `ground` is what to fix. */
export class TraceJoinRefused extends Error {
  readonly kind = 'trace-join-refused' as const;
  /** One of `unrecorded`, `identity-mismatch`, `count-mismatch`, `duplicate-half`, `arm-mismatch`. */
  readonly ground: string;

  constructor(ground: string, detail: string) {
    super(
      `refusing to join these recordings (${ground}): ${detail}. M26: a join is RECORDED by the `
        + `producer, never inferred by a reader — two containers that merely look related are not `
        + `evidence that they belong to one transaction.`,
    );
    this.name = 'TraceJoinRefused';
    this.ground = ground;
  }
}

/** One half, as it arrives at the joiner: the container's bytes and the record read out of it. */
export interface HalfRecording {
  /** Where the container came from, for diagnostics. Not used to decide anything. */
  readonly label: string;
  /** Bytes of the `.ct` container. */
  readonly container: Uint8Array;
  /**
   * The record decoded out of THIS container's own events.
   *
   * `undefined` means the container carries no join record, which is a refusal and not a default.
   * It is a parameter rather than something this function decodes because decoding a CTFS container
   * needs a reader, and `orchestration` has no npm dependencies to bring one in with — the checks
   * decode with the pinned `ct-print` and hand the result here.
   */
  readonly record: JoinRecord | undefined;
}

/** A join that was accepted. */
export interface JoinedRecording {
  readonly joinId: string;
  readonly arm: JoinArm;
  readonly halves: readonly HalfRecording[];
  /** The halves' labels in the order the records declare, so a consumer opens the private one first. */
  readonly order: readonly TraceHalf[];
}

/** The order a consumer should open the halves in: the private half is the outer one. */
const HALF_ORDER: readonly TraceHalf[] = ['both', 'private', 'public'];

/**
 * Join a set of halves, or refuse.
 *
 * Every ground is checked over the RECORDS, never over the filenames, the byte counts or the order
 * the caller happened to pass them in.
 */
export function joinRecordings(halves: readonly HalfRecording[]): JoinedRecording {
  if (halves.length === 0) {
    throw new TraceJoinRefused('unrecorded', 'no halves were supplied');
  }
  const missing = halves.filter(h => h.record === undefined).map(h => h.label);
  if (missing.length > 0) {
    throw new TraceJoinRefused(
      'unrecorded',
      `${missing.length} of ${halves.length} container(s) carry no ${JOIN_EVENT_METADATA} record `
        + `(${missing.join(', ')})`,
    );
  }
  const records = halves.map(h => h.record!);
  const ids = new Set(records.map(r => r.joinId));
  if (ids.size !== 1) {
    throw new TraceJoinRefused(
      'identity-mismatch',
      `the halves declare ${ids.size} different join identities: ${[...ids].join(', ')}`,
    );
  }
  const arms = new Set(records.map(r => r.arm));
  if (arms.size !== 1) {
    throw new TraceJoinRefused('arm-mismatch', `the halves disagree about the arm: ${[...arms].join(', ')}`);
  }
  const declared = new Set(records.map(r => r.halves));
  if (declared.size !== 1) {
    throw new TraceJoinRefused(
      'count-mismatch',
      `the halves disagree about how many halves this join has: ${[...declared].join(', ')}`,
    );
  }
  const want = records[0]!.halves;
  if (want !== halves.length) {
    throw new TraceJoinRefused(
      'count-mismatch',
      `the records declare a ${want}-half join and ${halves.length} container(s) were supplied`,
    );
  }
  const labels = records.map(r => r.half);
  if (new Set(labels).size !== labels.length) {
    throw new TraceJoinRefused('duplicate-half', `two halves claim the same label: ${labels.join(', ')}`);
  }
  const order = [...labels].sort((a, b) => HALF_ORDER.indexOf(a) - HALF_ORDER.indexOf(b));
  return { joinId: records[0]!.joinId, arm: records[0]!.arm, halves, order };
}

/**
 * The {@link PrivateTraceHandle} a joined recording's producer puts on its transaction's provenance.
 *
 * M21 declared `TxProvenance.privateTrace` and left its shape to M26; this is where the two meet.
 * The handle is derived FROM the record that is in the containers rather than assembled beside it,
 * so a handle and its recording cannot disagree about which join they belong to — which is the same
 * property, one level up, that `joinRecordings` enforces between two containers.
 *
 * `id` is the join identity and not a second name for the same thing. M21's field is `id`, a
 * consumer that only knows M21's type still gets something it can use, and `join` is the same
 * string under the name the containers spell it with.
 */
export function privateTraceHandleFor(record: JoinRecord): {
  readonly id: string;
  readonly join: string;
  readonly halves: number;
  readonly arm: JoinArm;
} {
  return { id: record.joinId, join: record.joinId, halves: record.halves, arm: record.arm };
}
